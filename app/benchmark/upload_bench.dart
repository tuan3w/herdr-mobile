// Upload throughput of SftpFiles against an in-memory SFTP server with a
// modelled link (round trip + serialised wire): how the window of unanswered
// WRITE requests turns into MB/s, and what a folder listing waits behind it.
//
//   dart run benchmark/upload_bench.dart
//
// A window of 1 is the old write-wait-write loop; adaptive is the default. The numbers are the model's:
// real sshd/dartssh2 adds per-packet crypto (pure Dart, ~29 MB/s on the
// recommended cipher, see ssh_algorithms_test.dart), which caps the right-hand
// column on a phone whatever the window is.
import 'dart:io';

import 'package:herdr_mobile/data/services/sftp_files.dart';

import '../test/support/fake_sftp_server.dart';

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('upload_bench');
  try {
    const size = 50 * 1024 * 1024;
    final file = File('${dir.path}/50mb.bin');
    final raf = file.openSync(mode: FileMode.write)..truncateSync(size);
    raf.closeSync();

    final links = <(String, Duration, int)>[
      ('LAN   (2 ms rtt, 100 MB/s)', const Duration(milliseconds: 2), 100 << 20),
      ('Wi-Fi (15 ms rtt, 20 MB/s)', const Duration(milliseconds: 15), 20 << 20),
      ('LTE   (60 ms rtt, 5 MB/s)', const Duration(milliseconds: 60), 5 << 20),
    ];
    stdout.writeln('50 MB upload, MB/s by window of unanswered 32 KB writes');
    final windows = [1, 4, 16, 32, 0]; // 0: adaptive (the default), capped at 32
    stdout.writeln('${'link'.padRight(30)}${windows.map((w) => (w == 0 ? 'adaptive' : 'win $w').padLeft(10)).join()}');
    for (final (name, rtt, bw) in links) {
      final row = StringBuffer(name.padRight(30));
      for (final window in windows) {
        final server = FakeSftpServer(rtt: rtt, bytesPerSecond: bw, keepBytes: false)..dirs['/d'] = 0x41C0;
        final files = SftpFiles(
          open: () async => server,
          uploadWindow: window == 0 ? 32 : window,
          uploadStartWindow: window == 0 ? 8 : window,
          browseWindow: window == 0 ? 4 : window,
        );
        // The 5 MB/s link would take 10 s per cell at best: use a 10 MB slice.
        final slice = bw < (10 << 20) ? 10 * 1024 * 1024 : size;
        final part = File('${dir.path}/slice$slice.bin');
        if (!part.existsSync()) {
          final r = part.openSync(mode: FileMode.write)..truncateSync(slice);
          r.closeSync();
        }
        final sw = Stopwatch()..start();
        await files.upload(part.path, '/d/f').done;
        row.write((slice / (1 << 20) / (sw.elapsedMicroseconds / 1e6)).toStringAsFixed(1).padLeft(10));
      }
      stdout.writeln(row);
    }

    stdout.writeln('\nlisting latency while a 50 MB upload is running (Wi-Fi link), ms');
    for (final (label, fixed, browse) in [
      ('fixed window 32, no priority', true, 32),
      ('adaptive + browsing wins', false, 4),
    ]) {
      final server = FakeSftpServer(
          rtt: const Duration(milliseconds: 15), bytesPerSecond: 20 << 20, keepBytes: false)
        ..dirs['/d'] = 0x41C0;
      final files = SftpFiles(
        open: () async => server,
        uploadWindow: 32,
        uploadStartWindow: fixed ? 32 : 8,
        browseWindow: browse,
      );
      final job = files.upload(file.path, '/d/f');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final lat = <int>[];
      for (var i = 0; i < 5; i++) {
        final sw = Stopwatch()..start();
        await files.stat('/d');
        lat.add(sw.elapsedMilliseconds);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      await job.done;
      lat.sort();
      stdout.writeln('${label.padRight(30)} median ${lat[2]} ms, worst ${lat.last} ms');
    }
  } finally {
    dir.deleteSync(recursive: true);
  }
}
