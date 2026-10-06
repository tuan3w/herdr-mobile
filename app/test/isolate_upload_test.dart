import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/isolate_transport.dart';
import 'package:herdr_mobile/data/services/sftp_files.dart';

import 'support/fake_sftp_server.dart';

/// Runs the REAL upload code ([SftpFiles]) inside the worker isolate against
/// an in-memory SFTP server with a 100 MB/s wire and a 5 ms round trip.
HerdrTransport _build(Object? config, void Function(String) onPin, void Function(String) onNotice) =>
    _SftpOnly();

class _SftpOnly implements HerdrTransport {
  _SftpOnly() {
    server = FakeSftpServer(rtt: const Duration(milliseconds: 5), bytesPerSecond: 100 << 20, keepBytes: false)
      ..dirs['/home/dev/inbox'] = 0x41C0;
    files = SftpFiles(open: () async => server);
  }

  late final FakeSftpServer server;
  late final SftpFiles files;

  @override
  bool get supportsFiles => true;

  @override
  Future<void> makeDirs(String path) => files.makeDirs(path);

  @override
  Future<void> removeFile(String path) => files.remove(path);

  @override
  UploadJob uploadFile({
    required String localPath,
    required String remotePath,
    void Function(int sent, int total)? onProgress,
  }) => files.upload(localPath, remotePath, onProgress: onProgress);

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('${invocation.memberName}');
}

void main() {
  late Directory tmp;
  late IsolateTransport transport;
  final seen = <(int, List<Object?>)>[];
  final clock = Stopwatch();

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('isolate_upload');
    seen.clear();
    clock
      ..reset()
      ..start();
    IsolateTransport.debugOnMessage = (m) => seen.add((clock.elapsedMilliseconds, m));
    transport = IsolateTransport(builder: _build, config: () => null, onPin: (_) {});
  });
  tearDown(() async {
    IsolateTransport.debugOnMessage = null;
    await transport.close();
    tmp.deleteSync(recursive: true);
  });

  File sparse(String name, int size) {
    final f = File('${tmp.path}/$name');
    final raf = f.openSync(mode: FileMode.write)..truncateSync(size);
    raf.closeSync();
    return f;
  }

  List<(int, List<Object?>)> uploadMessages() =>
      seen.where((m) => const {'uprog', 'udone', 'uerr'}.contains(m.$2[0])).toList();

  test('100 MB upload: the UI isolate hears ~10 counters a second and never a byte', () async {
    const size = 100 * 1024 * 1024;
    final progress = <(int, int)>[];
    final sw = Stopwatch()..start();
    final job = transport.uploadFile(
      localPath: sparse('big.bin', size).path,
      remotePath: '/home/dev/inbox/big.bin',
      onProgress: (s, t) => progress.add((s, t)),
    );
    await job.done;
    final seconds = sw.elapsedMilliseconds / 1000;

    final msgs = uploadMessages();
    final counters = msgs.where((m) => m.$2[0] == 'uprog').toList();
    expect(counters.length, lessThanOrEqualTo(seconds * 10 + 3),
        reason: '${counters.length} progress messages in ${seconds}s');
    expect(transport.uploadProgressMessages, counters.length);
    expect(msgs.where((m) => m.$2[0] == 'udone'), hasLength(1));

    // Nothing but small numbers and strings crossed: no bytes, no big lists.
    for (final (_, m) in msgs) {
      expect(m.length, lessThanOrEqualTo(4), reason: '$m');
      for (final part in m) {
        expect(part is int || part is String || part is bool || part == null, isTrue,
            reason: 'payload ${part.runtimeType} in $m');
        expect(part is TypedData, isFalse);
        expect(part is TransferableTypedData, isFalse);
      }
    }

    expect(progress.first.$1, 0);
    expect(progress.last, (size, size));
    for (var i = 1; i < progress.length; i++) {
      expect(progress[i].$1, greaterThanOrEqualTo(progress[i - 1].$1));
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('cancel is immediate on this side and stops the counters from the worker', () async {
    final job = transport.uploadFile(
      localPath: sparse('c.bin', 100 * 1024 * 1024).path,
      remotePath: '/home/dev/inbox/c.bin',
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final sw = Stopwatch()..start();
    final cancelAt = clock.elapsedMilliseconds;
    job.cancel();
    await expectLater(job.done, throwsA(isA<UploadCancelled>()));
    expect(sw.elapsedMilliseconds, lessThan(50));

    // The upload would run ~0.6 s more; the worker must not report any of it.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(uploadMessages().where((m) => m.$2[0] == 'uprog' && m.$1 > cancelAt + 150), isEmpty,
        reason: 'the worker kept sending counters after the cancel');
    expect(uploadMessages().where((m) => m.$2[0] == 'udone'), isEmpty);
  });

  test('errors cross typed; folders and removal go through the worker too', () async {
    await expectLater(
      transport.uploadFile(localPath: '${tmp.path}/missing', remotePath: '/home/dev/inbox/m').done,
      throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.notFound)),
    );
    await transport.makeDirs('/home/dev/inbox/sub/deeper');
    await expectLater(
      transport.removeFile('/home/dev/inbox/nothing'),
      throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.notFound)),
    );
    final small = File('${tmp.path}/s.txt')..writeAsBytesSync([1, 2, 3]);
    await transport.uploadFile(localPath: small.path, remotePath: '/home/dev/inbox/s.txt').done;
    await transport.removeFile('/home/dev/inbox/s.txt');
  });

  test('a cancel before the worker is up never starts the upload', () async {
    final job = transport.uploadFile(
      localPath: sparse('d.bin', 1024).path,
      remotePath: '/home/dev/inbox/d.bin',
    )..cancel();
    await expectLater(job.done, throwsA(isA<UploadCancelled>()));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(uploadMessages(), isEmpty);
  });
}
