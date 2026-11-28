import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/ssh_transport.dart';

/// An [SSHClient] that only counts how it was used.
class _Client implements SSHClient {
  _Client(this.onExecute);

  final Future<SSHSession> Function(String command) onExecute;
  var closed = false;
  var executes = 0;

  @override
  bool get isClosed => closed;

  @override
  Future<SSHSession> execute(String command, {SSHPtyConfig? pty, SSHX11Config? x11, Map<String, String>? environment}) {
    executes++;
    return onExecute(command);
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_done.isCompleted) _done.complete();
  }

  final _done = Completer<void>();

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> ping() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _profile = MachineProfile(id: 'm', label: 'm', host: 'h', username: 'u');

SshTransport _transportOver(List<_Client> clients, _Client Function() make) => SshTransport(
  profile: _profile,
  secrets: const MachineSecrets(),
  onPinHostKey: (_) {},
  connectClient: (_) async {
    final client = make();
    clients.add(client);
    return client;
  },
);

void main() {
  group('a host that refuses another channel', () {
    test('fails that channel with words for a person and keeps the connection', () async {
      final clients = <_Client>[];
      final t = _transportOver(clients, () => _Client((_) => Future.error(SSHChannelOpenError(1, 'open failed'))));

      for (var i = 0; i < 3; i++) {
        await expectLater(
          t.hostCall('keeper', 'probe'),
          throwsA(
            isA<HerdrTransportException>()
                .having((e) => e.fatal, 'fatal', isFalse)
                .having((e) => e.message, 'message', contains('Too many sessions')),
          ),
        );
      }

      expect(clients, hasLength(1), reason: 'no reconnect after a refusal');
      expect(clients.single.closed, isFalse, reason: 'the connection and its channels stay');
      expect(clients.single.executes, 3);
    });

    test('resource shortage means the same, and other refusals keep the host’s reason', () {
      expect(channelRefusal(SSHChannelOpenError(4, 'no resources'))?.message, contains('Too many sessions'));
      expect(channelRefusal(SSHChannelOpenError(3, 'unknown channel type'))?.message, contains('unknown channel type'));
      expect(channelRefusal(SSHChannelOpenError(3, 'x'))?.fatal, isFalse);
    });

    test('any other failure still drops the connection, and the next call reconnects', () async {
      final clients = <_Client>[];
      final t = _transportOver(clients, () => _Client((_) => Future.error(StateError('socket closed'))));

      await expectLater(
        t.hostCall('keeper', 'probe'),
        throwsA(isA<HerdrTransportException>().having((e) => e.message, 'message', contains('Can’t open channel'))),
      );
      expect(clients.single.closed, isTrue);

      await expectLater(t.hostCall('keeper', 'probe'), throwsA(isA<HerdrTransportException>()));
      expect(clients, hasLength(2));
    });

    test('channelRefusal ignores everything that isn’t a refusal', () {
      expect(channelRefusal(StateError('x')), isNull);
      expect(channelRefusal(SSHAuthFailError('x')), isNull);
    });
  });
}
