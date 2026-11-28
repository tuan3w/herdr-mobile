import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';

// What RemoteFiles decides about uploads before and around the transport: the
// local checks that need no connection, how many run at once and in which
// order, what a failure looks like, and what a machine without the agent helper
// says. The bytes' journey (hash, resume, credit) is host_transfer_test.dart.

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('remote_files_upload'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File local(String name, int size, {bool sparse = false}) {
    final f = File('${tmp.path}/$name');
    final raf = f.openSync(mode: FileMode.write)..truncateSync(size);
    raf.closeSync();
    return f;
  }

  late FakeTransport transport;
  late RemoteFiles files;
  final running = <_Manual>[];

  setUp(() {
    running.clear();
    transport = FakeTransport()
      ..fs = FakeFs()
      ..onUpload = (l, inbox, p) => _Manual(inbox, p)..also(running.add);
    files = RemoteFiles(transport);
  });

  test('refuses a file over 200 MB before connecting, accepts exactly 200 MB', () async {
    final big = local('big.bin', uploadMaxBytes + 1);
    final job = files.uploadToInbox(localPath: big.path, inboxPath: '/x');
    await expectLater(
      job.done,
      throwsA(
        isA<RemoteFileException>()
            .having((e) => e.kind, 'kind', RemoteFileErrorKind.tooLarge)
            .having((e) => e.fatal, 'fatal', isTrue),
      ),
    );
    expect(transport.uploads, isEmpty, reason: 'nothing was asked of the connection');

    final edge = local('edge.bin', uploadMaxBytes);
    files.uploadToInbox(localPath: edge.path, inboxPath: '/y');
    expect(transport.uploads, hasLength(1));
  });

  test('a missing file and a folder fail typed', () async {
    await expectLater(
      files.uploadToInbox(localPath: '${tmp.path}/nope', inboxPath: '/x').done,
      throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.notFound)),
    );
    await expectLater(
      files.uploadToInbox(localPath: tmp.path, inboxPath: '/x').done,
      throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.notAFile)),
    );
    expect(transport.uploads, isEmpty);
  });

  test('a machine without files fails typed, for the upload and for the inbox calls', () async {
    final none = RemoteFiles(FakeTransport());
    await expectLater(
      none.uploadToInbox(localPath: local('k.bin', 1).path, inboxPath: '/x').done,
      throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.unsupported)),
    );
    await expectLater(
      none.reserveInboxFile(key: 's', name: 'a.txt'),
      throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.unsupported)),
    );
    await expectLater(
      none.sweepInbox(),
      throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.unsupported)),
    );
  });

  test('the inbox calls go to the transport as asked', () async {
    transport.sweepRemoved = 4;
    expect(await files.reserveInboxFile(key: 'session', name: 'Report.pdf'), endsWith('/session/Report.pdf'));
    expect(transport.reserved, ['session -> Report.pdf']);
    expect(await files.sweepInbox(), 4);
  });

  test('starts inside the call; at most two run, the rest wait in order', () async {
    final a = files.uploadToInbox(localPath: local('1', 1).path, inboxPath: '/1');
    final b = files.uploadToInbox(localPath: local('2', 1).path, inboxPath: '/2');
    final c = files.uploadToInbox(localPath: local('3', 1).path, inboxPath: '/3');
    final d = files.uploadToInbox(localPath: local('4', 1).path, inboxPath: '/4');
    expect(running.map((u) => u.inbox), ['/1', '/2'], reason: 'started within the call, two at most');

    running[0].finish();
    await a.done;
    expect(running.map((u) => u.inbox), ['/1', '/2', '/3']);

    // A waiting upload that is cancelled never starts and frees nothing.
    d.cancel();
    await expectLater(d.done, throwsA(isA<UploadCancelled>()));
    expect(running, hasLength(3));

    // Cancelling a running one frees its place at once.
    final e = files.uploadToInbox(localPath: local('5', 1).path, inboxPath: '/5');
    expect(running, hasLength(3));
    b.cancel();
    await expectLater(b.done, throwsA(isA<UploadCancelled>()));
    expect(running[1].cancelled, isTrue);
    expect(running.map((u) => u.inbox), ['/1', '/2', '/3', '/5']);

    // A failure frees its place too.
    running[2].fail(const HerdrTransportException('down', fatal: true));
    await expectLater(
      c.done,
      throwsA(
        isA<RemoteFileException>()
            .having((x) => x.kind, 'kind', RemoteFileErrorKind.network)
            .having((x) => x.fatal, 'fatal', isTrue),
      ),
    );
    running[3].finish();
    await e.done;
  });

  test('progress reaches the caller', () async {
    final seen = <(int, int)>[];
    final job = files.uploadToInbox(
      localPath: local('p', 1).path,
      inboxPath: '/p',
      onProgress: (s, t) => seen.add((s, t)),
    );
    running.single.progress(5, 10);
    running.single.finish();
    await job.done;
    expect(seen, [(5, 10)]);
  });
}

/// An upload the test finishes by hand.
class _Manual implements UploadJob {
  _Manual(this.inbox, this._onProgress);

  final String inbox;
  final void Function(int, int)? _onProgress;
  final _done = Completer<void>();
  bool cancelled = false;

  void also(void Function(_Manual) f) => f(this);

  void progress(int s, int t) => _onProgress?.call(s, t);
  void finish() => _done.complete();
  void fail(Object e) => _done.completeError(e);

  @override
  Future<void> get done => _done.future;

  @override
  void cancel() {
    cancelled = true;
    if (!_done.isCompleted) _done.completeError(UploadCancelled());
  }
}
