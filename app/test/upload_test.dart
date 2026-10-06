import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';
import 'package:herdr_mobile/data/services/sftp_files.dart';

import 'support/fake_fs.dart';
import 'support/fake_sftp_server.dart';
import 'support/fake_transport.dart';

/// Content that depends on the position, so a lost, shifted or overwritten
/// block shows.
Uint8List pattern(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) (i * 31 + (i >> 8)) & 0xFF]);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('upload_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File local(String name, int size, {bool sparse = false}) {
    final f = File('${tmp.path}/$name');
    if (sparse) {
      final raf = f.openSync(mode: FileMode.write)..truncateSync(size);
      raf.closeSync();
    } else {
      f.writeAsBytesSync(pattern(size));
    }
    return f;
  }

  const remote = '/home/dev/inbox/up.bin';

  group('SftpFiles.upload', () {
    late FakeSftpServer server;
    late SftpFiles files;
    var opens = 0;

    SftpFiles make({FakeSftpServer? s, Duration stall = const Duration(seconds: 30), bool adaptive = false}) {
      server = s ?? FakeSftpServer();
      server.dirs['/home/dev/inbox'] = 0x41C0;
      opens = 0;
      return files = SftpFiles(
        open: () async {
          opens++;
          return server;
        },
        stallTimeout: stall,
        uploadStartWindow: adaptive ? 8 : 32, // fixed by default: most tests count requests
      );
    }

    setUp(() => make());

    test('stores every byte in order, 0600, progress monotonic and ending at total', () async {
      const size = 1 * 1024 * 1024 + 17; // not a multiple of the block
      final src = local('a.bin', size);
      final seen = <(int, int)>[];
      final job = files.upload(src.path, remote, onProgress: (s, t) => seen.add((s, t)));
      await job.done;

      final stored = server.files[remote]!;
      expect(stored.content, orderedEquals(src.readAsBytesSync()));
      expect(stored.mode, 0x8180);
      expect(stored.closed, isTrue);
      expect(seen.first, (0, size));
      expect(seen.last, (size, size));
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i].$1, greaterThanOrEqualTo(seen[i - 1].$1), reason: 'progress went back');
        expect(seen[i].$2, size);
      }
    });

    test('keeps 32 requests in flight instead of write-wait-write', () async {
      server.ackGate = Completer<void>();
      final job = files.upload(local('b.bin', 4 * 1024 * 1024).path, remote);
      await eventually(() => server.outstanding == 32, reason: 'a full window');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(server.maxOutstanding, 32, reason: 'the window is a ceiling too');
      server.ackGate!.complete();
      await job.done;
      expect(server.files[remote]!.length, 4 * 1024 * 1024);
    });

    test('browsing wins: while a stat waits on the channel the window is 4 requests', () async {
      server.statGate = Completer<void>();
      server.ackGate = Completer<void>();
      final browse = files.stat('/home/dev');
      await eventually(() => server.calls.contains('stat /home/dev'));
      final job = files.upload(local('c.bin', 2 * 1024 * 1024).path, remote);
      await eventually(() => server.outstanding == 4);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(server.maxOutstanding, 4);
      server.statGate!.complete();
      await browse;
      server.ackGate!.complete();
      await job.done;
      // With nothing browsing the next one opens up again.
      server.maxOutstanding = 0;
      server.ackGate = Completer<void>();
      final next = files.upload(local('c2.bin', 2 * 1024 * 1024).path, '/home/dev/inbox/up2.bin');
      await eventually(() => server.outstanding == 32);
      server.ackGate!.complete();
      await next.done;
    });

    test('two uploads split the window between them', () async {
      server.ackGate = Completer<void>();
      final a = files.upload(local('d1.bin', 3 * 1024 * 1024).path, '/home/dev/inbox/1');
      final b = files.upload(local('d2.bin', 3 * 1024 * 1024).path, '/home/dev/inbox/2');
      await eventually(() => server.outstanding == 32);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(server.maxOutstanding, 32);
      server.ackGate!.complete();
      await Future.wait([a.done, b.done]);
      expect(server.files['/home/dev/inbox/1']!.length, 3 * 1024 * 1024);
      expect(server.files['/home/dev/inbox/2']!.length, 3 * 1024 * 1024);
    });

    test('cancel returns at once, stops sending and removes the partial', () async {
      server.ackGate = Completer<void>();
      final job = files.upload(local('e.bin', 8 * 1024 * 1024).path, remote);
      await eventually(() => server.outstanding == 32);
      final partial = server.files[remote]!;
      final sentBefore = server.writeCount;

      job.cancel();
      await expectLater(job.done, throwsA(isA<UploadCancelled>()));

      server.ackGate!.complete();
      await eventually(() => !server.files.containsKey(remote), reason: 'partial removed');
      expect(partial.closed, isTrue);
      expect(server.writeCount, sentBefore, reason: 'no write after cancel');
      job.cancel(); // harmless again
    });

    test('cancel while the remote file is still opening leaves nothing', () async {
      final slow = FakeSftpServer(rtt: const Duration(milliseconds: 40));
      make(s: slow);
      final job = files.upload(local('f.bin', 100 * 1024).path, remote);
      job.cancel();
      await expectLater(job.done, throwsA(isA<UploadCancelled>()));
      await eventually(() => slow.calls.any((c) => c.startsWith('remove')) || !slow.files.containsKey(remote));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(slow.files, isEmpty);
      expect(slow.writeCount, 0);
    });

    test('a link lost mid-way is an error, the partial goes, the next call reconnects', () async {
      server.dieAfterWrites = 10;
      final job = files.upload(local('g.bin', 4 * 1024 * 1024).path, remote);
      await expectLater(
        job.done,
        throwsA(isA<RemoteFileException>()
            .having((e) => e.kind, 'kind', RemoteFileErrorKind.network)
            .having((e) => e is UploadCancelled, 'cancelled', isFalse)),
      );
      await eventually(() => !server.files.containsKey(remote), reason: 'partial removed');
      expect(opens, 2, reason: 'the dead session was dropped for the removal');
      expect(server.closeCount, greaterThanOrEqualTo(1));
    });

    test('a link that goes silent fails after the stall timeout', () async {
      make(stall: const Duration(milliseconds: 200));
      server.hangAfterWrites = 5;
      final sw = Stopwatch()..start();
      final job = files.upload(local('h.bin', 2 * 1024 * 1024).path, remote);
      await expectLater(
        job.done,
        throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.network)),
      );
      expect(sw.elapsedMilliseconds, lessThan(3000));
      await eventually(() => !server.files.containsKey(remote), reason: 'partial removed');
    });

    test('an empty file is created and reported 0 of 0', () async {
      final seen = <(int, int)>[];
      await files
          .upload(local('empty.bin', 0).path, remote, onProgress: (s, t) => seen.add((s, t)))
          .done;
      expect(server.files[remote]!.length, 0);
      expect(seen.last, (0, 0));
      expect(server.writeCount, 0);
    });

    test('a refused open (no permission) maps and creates nothing to clean', () async {
      server.openError = SftpStatusError(3, 'Permission denied');
      await expectLater(
        files.upload(local('i.bin', 10).path, remote).done,
        throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.permission)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(server.calls.where((c) => c.startsWith('remove')), isEmpty);
    });

    test('a local file that vanished fails and the empty remote file is removed', () async {
      await expectLater(
        files.upload('${tmp.path}/missing.bin', remote).done,
        throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.notFound)),
      );
      await eventually(() => !server.files.containsKey(remote));
    });

    test('the window follows the link: short on a near link, growing to the cap on a long fat one', () async {
      // ~2 requests fill this link; the window must not balloon to 32.
      make(
        s: FakeSftpServer(rtt: const Duration(milliseconds: 2), bytesPerSecond: 10 << 20, keepBytes: false),
        adaptive: true,
      );
      await files.upload(local('near.bin', 4 * 1024 * 1024, sparse: true).path, remote).done;
      expect(server.maxOutstanding, lessThanOrEqualTo(8));

      // ~75 requests would fill this one: the window climbs to the cap.
      make(
        s: FakeSftpServer(rtt: const Duration(milliseconds: 60), bytesPerSecond: 40 << 20, keepBytes: false),
        adaptive: true,
      );
      await files.upload(local('far.bin', 32 * 1024 * 1024, sparse: true).path, remote).done;
      expect(server.maxOutstanding, 32);
    });

    test('progress is reported at most every 100 ms', () async {
      make(s: FakeSftpServer(rtt: const Duration(milliseconds: 2), bytesPerSecond: 40 << 20, keepBytes: false));
      final stamps = <int>[];
      final sw = Stopwatch()..start();
      await files
          .upload(local('j.bin', 24 * 1024 * 1024, sparse: true).path, remote,
              onProgress: (s, t) => stamps.add(sw.elapsedMilliseconds))
          .done;
      expect(stamps.length, lessThanOrEqualTo(sw.elapsedMilliseconds ~/ 100 + 3),
          reason: '${stamps.length} callbacks in ${sw.elapsedMilliseconds} ms');
    });
  });

  group('SftpFiles folders', () {
    late FakeSftpServer server;
    late SftpFiles files;
    setUp(() {
      server = FakeSftpServer();
      files = SftpFiles(open: () async => server);
    });

    test('makeDirs creates the missing folders 0700 and leaves existing ones', () async {
      server.dirs['/home/dev/.herdr-mobile'] = 0x41ED;
      await files.makeDirs('/home/dev/.herdr-mobile/inbox/abc123');
      expect(server.dirs['/home/dev/.herdr-mobile'], 0x41ED);
      expect(server.dirs['/home/dev/.herdr-mobile/inbox'], 0x41C0);
      expect(server.dirs['/home/dev/.herdr-mobile/inbox/abc123'], 0x41C0);
      expect(server.calls.where((c) => c.startsWith('mkdir')).length, 2);

      server.calls.clear();
      await files.makeDirs('/home/dev/.herdr-mobile/inbox/abc123');
      expect(server.calls, ['stat /home/dev/.herdr-mobile/inbox/abc123'], reason: 'one round trip');
    });

    test('makeDirs refuses a file in the way and relative paths', () async {
      server.files['/home/dev/x'] = FakeRemote(0x81A4);
      await expectLater(files.makeDirs('/home/dev/x/y'),
          throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.notADirectory)));
      await expectLater(files.makeDirs('relative/dir'), throwsA(isA<RemoteFileException>()));
    });

    test('remove deletes a file and says notFound for a missing one', () async {
      server.files['/home/dev/old'] = FakeRemote(0x8180);
      await files.remove('/home/dev/old');
      expect(server.files, isEmpty);
      await expectLater(files.remove('/home/dev/old'),
          throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.notFound)));
    });
  });

  group('RemoteFiles.upload', () {
    late FakeTransport transport;
    late RemoteFiles remoteFiles;
    final running = <_Manual>[];

    setUp(() {
      running.clear();
      transport = FakeTransport()
        ..fs = FakeFs()
        ..onUpload = (l, r, p) => _Manual(r, p)..also(running.add);
      remoteFiles = RemoteFiles(transport);
    });

    test('refuses a file over 200 MB before connecting, accepts exactly 200 MB', () async {
      final big = local('big.bin', uploadMaxBytes + 1, sparse: true);
      final job = remoteFiles.upload(localPath: big.path, remotePath: '/x');
      await expectLater(
        job.done,
        throwsA(isA<RemoteFileException>()
            .having((e) => e.kind, 'kind', RemoteFileErrorKind.tooLarge)
            .having((e) => e.fatal, 'fatal', isTrue)),
      );
      expect(transport.uploads, isEmpty, reason: 'nothing was asked of the connection');

      final edge = local('edge.bin', uploadMaxBytes, sparse: true);
      remoteFiles.upload(localPath: edge.path, remotePath: '/y');
      expect(transport.uploads, hasLength(1));
    });

    test('a missing file and a folder fail typed', () async {
      await expectLater(remoteFiles.upload(localPath: '${tmp.path}/nope', remotePath: '/x').done,
          throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.notFound)));
      await expectLater(remoteFiles.upload(localPath: tmp.path, remotePath: '/x').done,
          throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.notAFile)));
      expect(transport.uploads, isEmpty);
    });

    test('a machine without files fails typed', () async {
      final f = RemoteFiles(FakeTransport());
      await expectLater(f.upload(localPath: local('k.bin', 1).path, remotePath: '/x').done,
          throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.unsupported)));
    });

    test('starts inside the call; at most two run, the rest wait in order', () async {
      final a = remoteFiles.upload(localPath: local('1', 1).path, remotePath: '/1');
      final b = remoteFiles.upload(localPath: local('2', 1).path, remotePath: '/2');
      final c = remoteFiles.upload(localPath: local('3', 1).path, remotePath: '/3');
      final d = remoteFiles.upload(localPath: local('4', 1).path, remotePath: '/4');
      expect(running.map((u) => u.remote), ['/1', '/2'], reason: 'started within the call, two at most');

      running[0].finish();
      await a.done;
      expect(running.map((u) => u.remote), ['/1', '/2', '/3']);

      // A waiting upload that is cancelled never starts and frees nothing.
      d.cancel();
      await expectLater(d.done, throwsA(isA<UploadCancelled>()));
      expect(running, hasLength(3));

      // Cancelling a running one frees its place at once.
      final e = remoteFiles.upload(localPath: local('5', 1).path, remotePath: '/5');
      expect(running, hasLength(3));
      b.cancel();
      await expectLater(b.done, throwsA(isA<UploadCancelled>()));
      expect(running[1].cancelled, isTrue);
      expect(running.map((u) => u.remote), ['/1', '/2', '/3', '/5']);

      // A failure frees its place too.
      running[2].fail(const HerdrTransportException('down', fatal: true));
      await expectLater(
        c.done,
        throwsA(isA<RemoteFileException>()
            .having((x) => x.kind, 'kind', RemoteFileErrorKind.network)
            .having((x) => x.fatal, 'fatal', isTrue)),
      );
      running[3].finish();
      await e.done;
    });

    test('progress reaches the caller', () async {
      final seen = <(int, int)>[];
      final job = remoteFiles.upload(
          localPath: local('p', 1).path, remotePath: '/p', onProgress: (s, t) => seen.add((s, t)));
      running.single.progress(5, 10);
      running.single.finish();
      await job.done;
      expect(seen, [(5, 10)]);
    });
  });
}

/// An upload the test finishes by hand.
class _Manual implements UploadJob {
  _Manual(this.remote, this._onProgress);

  final String remote;
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
