// A real upload over SFTP to this machine's own sshd (loopback), through the
// production path: IsolateTransport -> SshTransport -> SftpFiles -> dartssh2.
//
//   flutter test benchmark/upload_real_bench.dart
//
// Needs sshd on localhost accepting ~/.ssh/herdr-mobile for $USER. Checks the
// bytes arrived intact, the modes (folder 0700, file 0600), that a cancel
// removes the partial file, and prints throughput and the latency of a
// folder listing issued while the upload runs. Loopback has no latency, but
// dartssh2's pure-Dart encryption costs what it costs on a phone's CPU (a
// desktop core is several times faster), so the MB/s is an upper bound for a
// phone. Never quote it as a phone number.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/transport_factory.dart';

Uint8List _pattern(int n) {
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = (i * 31 + (i >> 8) + (i >> 17)) & 0xFF;
  }
  return b;
}

void main() {
  test('upload over a real sshd', () async {
    final home = Platform.environment['HOME']!;
    final user = Platform.environment['USER'] ?? Platform.environment['LOGNAME']!;
    final keyFile = File('$home/.ssh/herdr-mobile');
    if (!keyFile.existsSync()) {
      markTestSkipped('no ~/.ssh/herdr-mobile');
      return;
    }
    final tmp = Directory.systemTemp.createTempSync('upload_real');
    final remoteDir = '$home/.herdr-upload-bench-$pid/inbox/abc123def456';
    addTearDown(() {
      tmp.deleteSync(recursive: true);
      final root = Directory('$home/.herdr-upload-bench-$pid');
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    final HerdrTransport transport = createSshTransport(
      MachineProfile(id: 'bench', label: 'bench', host: '127.0.0.1', username: user),
      MachineSecrets(privateKeyPem: keyFile.readAsStringSync()),
      (_) {},
      (_) {},
    );
    addTearDown(transport.close);

    // Folders: 0700, one call.
    await transport.makeDirs(remoteDir);
    expect(Directory(remoteDir).statSync().mode & 0x1FF, 448, reason: 'folder is 0700');
    await transport.makeDirs(remoteDir); // already there: nothing happens

    // 50 MB, intact, 0600.
    const size = 50 * 1024 * 1024;
    final src = File('${tmp.path}/50mb.bin')..writeAsBytesSync(_pattern(size));
    final seen = <int>[];
    var sw = Stopwatch()..start();
    final job = transport.uploadFile(
      localPath: src.path,
      remotePath: '$remoteDir/50mb.bin',
      onProgress: (s, t) => seen.add(s),
    );
    // A listing issued while it runs.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final lat = <int>[];
    for (var i = 0; i < 5 && seen.isNotEmpty && seen.last < size; i++) {
      final l = Stopwatch()..start();
      await transport.listDirectory(remoteDir);
      lat.add(l.elapsedMilliseconds);
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    await job.done;
    final secs = sw.elapsedMicroseconds / 1e6;
    // ignore: avoid_print
    print('REAL 50 MB upload: ${(size / (1 << 20) / secs).toStringAsFixed(1)} MB/s in '
        '${secs.toStringAsFixed(2)} s; ${seen.length} progress callbacks; '
        'listing during upload: ${lat.isEmpty ? 'n/a' : lat.join('/')} ms');
    final stored = File('$remoteDir/50mb.bin');
    expect(stored.lengthSync(), size);
    expect(stored.statSync().mode & 0x1FF, 384, reason: 'file is 0600');
    expect(stored.readAsBytesSync(), orderedEquals(src.readAsBytesSync()));
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
    }
    expect(seen.last, size);

    // Cancel: returns at once, the partial file goes.
    final big = File('${tmp.path}/300mb.bin');
    final raf = big.openSync(mode: FileMode.write)..truncateSync(190 * 1024 * 1024);
    raf.closeSync();
    final cancelled = transport.uploadFile(localPath: big.path, remotePath: '$remoteDir/partial.bin');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(File('$remoteDir/partial.bin').existsSync(), isTrue, reason: 'the partial file is there');
    sw = Stopwatch()..start();
    cancelled.cancel();
    await expectLater(cancelled.done, throwsA(isA<UploadCancelled>()));
    // ignore: avoid_print
    print('REAL cancel returned in ${sw.elapsedMilliseconds} ms');
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (File('$remoteDir/partial.bin').existsSync() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(File('$remoteDir/partial.bin').existsSync(), isFalse, reason: 'partial removed');

    // Cleanup of a stored file through the same channel.
    await transport.removeFile('$remoteDir/50mb.bin');
    expect(stored.existsSync(), isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
