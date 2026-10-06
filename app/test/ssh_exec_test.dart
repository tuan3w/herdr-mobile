import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/ssh_transport.dart';

/// A session the test plays both ends of.
class _Session implements ExecSession {
  final _stdout = StreamController<Uint8List>();
  final _stderr = StreamController<Uint8List>();
  final _stdin = StreamController<Uint8List>();
  final _done = Completer<void>();
  final written = <int>[];
  var closeCalls = 0;
  @override
  int? exitCode;

  _Session() {
    _stdin.stream.listen((chunk) => written.addAll(chunk));
  }

  String get stdinText => utf8.decode(written);
  bool get stdinClosed => _stdin.isClosed;

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  StreamSink<Uint8List> get stdin => _stdin.sink;

  @override
  Future<void> get done => _done.future;

  @override
  void close() {
    closeCalls++;
    finish(null);
  }

  void err(String text) => _stderr.add(Uint8List.fromList(utf8.encode(text)));

  void out(String text) => _stdout.add(Uint8List.fromList(utf8.encode(text)));

  /// The remote command ends with [code] and the channel closes.
  void finish(int? code, {bool linkDied = false}) {
    if (_done.isCompleted) return;
    exitCode = code;
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    if (linkDied) {
      _done.completeError(StateError('connection lost'));
    } else {
      _done.complete();
    }
  }
}

/// An [SSHClient] that only counts how it was used.
class _Client implements SSHClient {
  _Client(this.onExecute);

  final Future<SSHSession> Function(String command) onExecute;
  var closed = false;
  var executes = 0;

  @override
  bool get isClosed => closed;

  @override
  Future<SSHSession> execute(
    String command, {
    SSHPtyConfig? pty,
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) {
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
      connectClient: () async {
        final client = make();
        clients.add(client);
        return client;
      },
    );

void main() {
  group('a host that refuses another channel', () {
    test('fails that channel with words for a person and keeps the connection', () async {
      final clients = <_Client>[];
      final t = _transportOver(
        clients,
        () => _Client((_) => Future.error(SSHChannelOpenError(1, 'open failed'))),
      );

      for (var i = 0; i < 3; i++) {
        await expectLater(
          t.openExec('keeper attach'),
          throwsA(isA<HerdrTransportException>()
              .having((e) => e.fatal, 'fatal', isFalse)
              .having((e) => e.message, 'message', contains('Too many sessions'))),
        );
      }

      expect(clients, hasLength(1), reason: 'no reconnect after a refusal');
      expect(clients.single.closed, isFalse, reason: 'the connection and its channels stay');
      expect(clients.single.executes, 3);
    });

    test('resource shortage means the same, and other refusals keep the host\'s reason', () {
      expect(channelRefusal(SSHChannelOpenError(4, 'no resources'))?.message,
          contains('Too many sessions'));
      expect(channelRefusal(SSHChannelOpenError(3, 'unknown channel type'))?.message,
          contains('unknown channel type'));
      expect(channelRefusal(SSHChannelOpenError(3, 'x'))?.fatal, isFalse);
    });

    test('any other failure still drops the connection, and the next call reconnects', () async {
      final clients = <_Client>[];
      final t = _transportOver(
        clients,
        () => _Client((_) => Future.error(StateError('socket closed'))),
      );

      await expectLater(
        t.openExec('x'),
        throwsA(isA<HerdrTransportException>()
            .having((e) => e.message, 'message', contains('Cannot open channel'))),
      );
      expect(clients.single.closed, isTrue);

      await expectLater(t.openExec('x'), throwsA(isA<HerdrTransportException>()));
      expect(clients, hasLength(2));
    });

    test('channelRefusal ignores everything that is not a refusal', () {
      expect(channelRefusal(StateError('x')), isNull);
      expect(channelRefusal(SSHAuthFailError('x')), isNull);
    });
  });

  group('SshExecChannel', () {
    late _Session session;
    late SshExecChannel channel;
    setUp(() {
      session = _Session();
      channel = SshExecChannel(session);
    });

    test('stderrTail keeps the end of what the command said, capped', () async {
      for (var i = 0; i < 20; i++) {
        session.err('${'x' * 999}\n');
      }
      session.err('the last words');
      await Future<void>.delayed(Duration.zero);

      final tail = channel.stderrTail;

      expect(utf8.encode(tail).length, lessThanOrEqualTo(SshExecChannel.tailBytes));
      expect(tail, endsWith('the last words'));
      expect(tail.length, greaterThan(1500), reason: 'a good part of the tail is kept');
    });

    test('a short stderr is kept whole and trimmed', () async {
      session.err('  herdr-mobile: no python3\n');
      await Future<void>.delayed(Duration.zero);

      expect(channel.stderrTail, 'herdr-mobile: no python3');
    });

    test('a multi-byte character cut by the cap does not break the text', () async {
      session.err('${'é' * 3000}x'); // 6001 bytes: the cut falls inside a character
      await Future<void>.delayed(Duration.zero);

      final tail = channel.stderrTail;

      expect(tail, endsWith('éx'));
      expect(tail, startsWith('\uFFFD'), reason: 'the torn character is replaced, not thrown on');
      expect(utf8.encode(tail).length, lessThanOrEqualTo(SshExecChannel.tailBytes + 2));
    });

    test('send writes the line and a newline', () async {
      channel.send('{"a":1}');
      channel.send('two');
      await Future<void>.delayed(Duration.zero);

      expect(session.stdinText, '{"a":1}\ntwo\n');
    });

    test('send after close throws, and nothing more is written', () async {
      channel.send('before');
      await channel.close();

      expect(() => channel.send('after'), throwsStateError);
      expect(session.stdinText, 'before\n');
    });

    test('send after the command ended does nothing', () async {
      session.finish(0);
      await channel.exitCode;

      channel.send('late');
      await Future<void>.delayed(Duration.zero);

      expect(session.stdinText, isEmpty);
    });

    test('close sends end of input, then closes the channel once, however often it is called',
        () async {
      await Future.wait([channel.close(), channel.close()]);
      await channel.close();

      expect(session.stdinClosed, isTrue);
      expect(session.closeCalls, 1);
    });

    test('closeInput ends stdin but leaves the channel open to read the answer', () async {
      final got = <String>[];
      channel.lines.listen(got.add);
      channel.send('payload');

      await Future.wait([channel.closeInput(), channel.closeInput()]);
      session.out('{"ok":true}\n');
      session.finish(0);

      expect(session.stdinClosed, isTrue);
      expect(session.closeCalls, 0, reason: 'the channel is still there');
      expect(await channel.exitCode, 0);
      expect(got, ['{"ok":true}']);
      expect(session.stdinText, 'payload\n');
      expect(() => channel.send('more'), throwsStateError);
    });

    test('close after closeInput still closes the channel, once', () async {
      await channel.closeInput();

      await channel.close();
      await channel.close();

      expect(session.closeCalls, 1);
    });

    test('close on a command that already ended does not touch stdin', () async {
      session.finish(0);
      await channel.exitCode;

      await channel.close();

      expect(session.stdinClosed, isFalse);
      expect(session.closeCalls, 1);
    });

    test('the exit status is the command\'s', () async {
      session.finish(67);

      expect(await channel.exitCode, 67);
    });

    test('a command killed by a signal has no status', () async {
      session.finish(null);

      expect(await channel.exitCode, isNull);
    });

    test('a connection that died ends the channel with no status, not an error', () async {
      session.finish(null, linkDied: true);

      expect(await channel.exitCode, isNull);
    });

    test('the status is not reported before stderr has been read to its end', () async {
      var reported = false;
      unawaited(channel.exitCode.then((_) => reported = true));
      session.exitCode = 1;
      session._done.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(reported, isFalse, reason: 'stderr is still open');

      session.err('late words');
      await session._stderr.close();

      expect(await channel.exitCode, 1);
      expect(channel.stderrTail, 'late words');
    });

    test('lines are split on newlines across chunks', () async {
      final got = <String>[];
      channel.lines.listen(got.add);

      session.out('{"a":');
      session.out('1}\n{"b"');
      session.out(':2}\n');
      await Future<void>.delayed(Duration.zero);

      expect(got, ['{"a":1}', '{"b":2}']);
    });
  });
}
