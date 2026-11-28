import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/isolate_transport.dart';

import 'support/no_files.dart';

// What crosses the isolate boundary for an upload: counters and typed errors,
// never a byte; a cancel reaches the worker's job; the inbox calls and the
// file watch are answered from the worker. The worker's transport is a script:
// the real upload (hash, resume, credit) is host_transfer_test.dart.

const _size = 100 * 1024 * 1024;

/// Runs inside the worker isolate; the inbox path picks the behaviour.
class _UploadProbe with NoFiles implements HerdrTransport {
  var cancels = 0;

  @override
  bool get supportsFiles => true;

  @override
  Future<String> reserveInboxFile({required String key, required String name}) async => '/inbox/$key/$name';

  /// How many of its uploads the worker was told to cancel.
  @override
  Future<int> sweepInbox() async => cancels;

  @override
  UploadJob uploadFile({
    required String localPath,
    required String inboxPath,
    void Function(int sent, int total)? onProgress,
  }) {
    final job = _Scripted(this);
    switch (inboxPath) {
      case '/inbox/ok':
        onProgress?.call(0, _size);
        onProgress?.call(_size ~/ 2, _size);
        onProgress?.call(_size, _size);
        job.finish();
      case '/inbox/hang':
        onProgress?.call(1, _size);
      case '/inbox/changed':
        job.fail(RemoteFileChanged('The file changed while it was being sent', path: inboxPath));
      case '/inbox/unsupported':
        job.fail(RemoteFileException(RemoteFileErrorKind.unsupported, 'Needs the agent helper on this machine.'));
      case '/inbox/gone':
        job.fail(RemoteFileException(RemoteFileErrorKind.notFound, 'The file is gone'));
      default:
        job.fail(const HerdrTransportException('down', fatal: true));
    }
    return job;
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('${invocation.memberName}');
}

class _Scripted implements UploadJob {
  _Scripted(this._probe);

  final _UploadProbe _probe;
  final _done = Completer<void>();

  void finish() => _done.complete();
  void fail(Object e) => _done.completeError(e);

  @override
  Future<void> get done => _done.future;

  @override
  void cancel() => _probe.cancels++;
}

HerdrTransport _build(Object? config, void Function(String) onPin, void Function(String) onNotice) => _UploadProbe();

void main() {
  late IsolateTransport transport;
  final seen = <List<Object?>>[];

  setUp(() {
    seen.clear();
    IsolateTransport.debugOnMessage = seen.add;
    transport = IsolateTransport(builder: _build, config: () => null, onPin: (_) {});
  });
  tearDown(() async {
    IsolateTransport.debugOnMessage = null;
    await transport.close();
  });

  List<List<Object?>> uploadMessages() => seen.where((m) => const {'uprog', 'udone', 'uerr'}.contains(m[0])).toList();

  test('the UI isolate hears counters in order and never a byte', () async {
    final progress = <(int, int)>[];
    final job = transport.uploadFile(
      localPath: '/tmp/ignored',
      inboxPath: '/inbox/ok',
      onProgress: (s, t) => progress.add((s, t)),
    );
    await job.done;

    expect(progress, [(0, _size), (_size ~/ 2, _size), (_size, _size)]);
    expect(transport.uploadProgressMessages, 3);
    final msgs = uploadMessages();
    expect(msgs.where((m) => m[0] == 'udone'), hasLength(1));
    // Nothing but small numbers and strings crossed: no bytes, no big lists.
    for (final m in msgs) {
      expect(m.length, lessThanOrEqualTo(4), reason: '$m');
      for (final part in m) {
        expect(
          part is int || part is String || part is bool || part == null,
          isTrue,
          reason: '${part.runtimeType} in $m',
        );
        expect(part is TypedData, isFalse);
        expect(part is TransferableTypedData, isFalse);
      }
    }
  });

  test('cancel is immediate on this side and reaches the worker\'s job', () async {
    final job = transport.uploadFile(localPath: '/tmp/ignored', inboxPath: '/inbox/hang');
    final progress = Completer<void>();
    // The first counter proves the worker has the job.
    final probe = transport.uploadFile(
      localPath: '/tmp/ignored',
      inboxPath: '/inbox/hang',
      onProgress: (_, _) => progress.isCompleted ? null : progress.complete(),
    );
    await progress.future;
    expect(await transport.sweepInbox(), 0);

    job.cancel();
    await expectLater(job.done, throwsA(isA<UploadCancelled>()));
    probe.cancel();
    await expectLater(probe.done, throwsA(isA<UploadCancelled>()));
    // The worker answers ops in order: by the time it answers, it has seen both cancels.
    expect(await transport.sweepInbox(), 2);
    expect(uploadMessages().where((m) => m[0] == 'udone'), isEmpty);
  });

  test('a cancel before the worker is up never starts the upload', () async {
    final job = transport.uploadFile(localPath: '/tmp/ignored', inboxPath: '/inbox/hang')..cancel();
    await expectLater(job.done, throwsA(isA<UploadCancelled>()));
    expect(await transport.sweepInbox(), 0, reason: 'the worker never had a job to cancel');
    expect(uploadMessages(), isEmpty);
  });

  test('errors cross typed: changed, unsupported, not found, and a lost connection', () async {
    await expectLater(
      transport.uploadFile(localPath: '/x', inboxPath: '/inbox/changed').done,
      throwsA(isA<RemoteFileChanged>().having((e) => e.path, 'path', '/inbox/changed')),
    );
    await expectLater(
      transport.uploadFile(localPath: '/x', inboxPath: '/inbox/unsupported').done,
      throwsA(
        isA<RemoteFileException>()
            .having((e) => e.kind, 'kind', RemoteFileErrorKind.unsupported)
            .having((e) => e.message, 'message', 'Needs the agent helper on this machine.'),
      ),
    );
    await expectLater(
      transport.uploadFile(localPath: '/x', inboxPath: '/inbox/gone').done,
      throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.notFound)),
    );
    await expectLater(
      transport.uploadFile(localPath: '/x', inboxPath: '/inbox/down').done,
      throwsA(isA<HerdrTransportException>().having((e) => e.fatal, 'fatal', isTrue)),
    );
  });

  test('the inbox is reserved through the worker', () async {
    expect(await transport.reserveInboxFile(key: 'k', name: 'a b.txt'), '/inbox/k/a b.txt');
  });
}
