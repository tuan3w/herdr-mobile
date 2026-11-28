// A real upload through the agent helper to this machine's own sshd (loopback),
// through the production path: IsolateTransport -> SshTransport -> HostLink ->
// `herdr-host serve` -> `transfer.put`.
//
//   flutter test benchmark/upload_real_bench.dart
//
// Needs sshd on localhost accepting ~/.ssh/herdr-mobile for $USER, and the
// helper for this app version installed on that machine
// (`~/.herdr-mobile/bin/herdr-host-<version>`: `tool/install-host.sh`, see
// docs/DEVELOPMENT.md; the transport installs it itself when it can download
// it). Checks the bytes arrived intact (sha256), the mode (file 0600), that a
// cancel keeps the partial upload and the next try continues from it, and prints
// throughput and the latency of a folder listing issued while the upload runs.
// Loopback has no latency, but dartssh2's pure-Dart encryption costs what it
// costs on a phone's CPU (a desktop core is several times faster), so the MB/s
// is an upper bound for a phone. Never quote it as a phone number.
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
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
  test('upload through the helper over a real sshd', () async {
    final home = Platform.environment['HOME']!;
    final user = Platform.environment['USER'] ?? Platform.environment['LOGNAME']!;
    final keyFile = File('$home/.ssh/herdr-mobile');
    if (!keyFile.existsSync()) {
      markTestSkipped('no ~/.ssh/herdr-mobile');
      return;
    }
    final tmp = Directory.systemTemp.createTempSync('upload_real');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final HerdrTransport transport = createSshTransport(
      MachineProfile(id: 'bench', label: 'bench', host: '127.0.0.1', username: user),
      MachineSecrets(privateKeyPem: keyFile.readAsStringSync()),
      (_) {},
      (_) {},
    );
    addTearDown(transport.close);

    final String inbox;
    try {
      inbox = await transport.reserveInboxFile(key: 'upload-real-bench-$pid', name: '50mb.bin');
    } on RemoteFileException catch (e) {
      markTestSkipped('no agent helper on this machine: ${e.message}');
      return;
    }
    addTearDown(() {
      final dir = File(inbox).parent;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    // 50 MB, intact, 0600.
    const size = 50 * 1024 * 1024;
    final bytes = _pattern(size);
    final src = File('${tmp.path}/50mb.bin')..writeAsBytesSync(bytes);
    final seen = <int>[];
    final sw = Stopwatch()..start();
    final job = transport.uploadFile(localPath: src.path, inboxPath: inbox, onProgress: (s, t) => seen.add(s));
    // A listing issued while it runs (hashing comes first, so wait for bytes).
    final lat = <int>[];
    while (seen.isEmpty || seen.last == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    for (var i = 0; i < 5 && seen.last < size; i++) {
      final l = Stopwatch()..start();
      await transport.listDirectory(File(inbox).parent.path);
      lat.add(l.elapsedMilliseconds);
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    await job.done;
    final secs = sw.elapsedMicroseconds / 1e6;
    // ignore: avoid_print
    print(
      'REAL 50 MB upload: ${(size / (1 << 20) / secs).toStringAsFixed(1)} MB/s in '
      '${secs.toStringAsFixed(2)} s (hashing included); ${seen.length} progress callbacks; '
      'listing during upload: ${lat.isEmpty ? 'n/a' : lat.join('/')} ms',
    );
    final stored = File(inbox);
    expect(stored.lengthSync(), size);
    expect(stored.statSync().mode & 0x1FF, 384, reason: 'file is 0600');
    expect(sha256.convert(stored.readAsBytesSync()), sha256.convert(bytes));
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
    }
    expect(seen.last, size);

    // Cancel: returns at once, the partial upload stays and the next try
    // continues from it.
    final bigInbox = await transport.reserveInboxFile(key: 'upload-real-bench-$pid', name: 'big.bin');
    final big = File('${tmp.path}/big.bin')..writeAsBytesSync(_pattern(120 * 1024 * 1024));
    final part = File('$bigInbox.part');
    var sent = 0;
    final cancelled = transport.uploadFile(localPath: big.path, inboxPath: bigInbox, onProgress: (s, t) => sent = s);
    while (sent < 8 * 1024 * 1024) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final stop = Stopwatch()..start();
    cancelled.cancel();
    await expectLater(cancelled.done, throwsA(isA<UploadCancelled>()));
    // ignore: avoid_print
    print('REAL cancel returned in ${stop.elapsedMilliseconds} ms');
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (!part.existsSync() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(part.existsSync(), isTrue, reason: 'the host keeps what it received');
    final kept = part.lengthSync();
    final resumed = <int>[];
    await transport.uploadFile(localPath: big.path, inboxPath: bigInbox, onProgress: (s, t) => resumed.add(s)).done;
    // ignore: avoid_print
    print('REAL resume: the host had $kept bytes; the second try started at ${resumed.first}');
    expect(resumed.first, greaterThan(0), reason: 'continued, did not start over');
    expect(File(bigInbox).lengthSync(), big.lengthSync());
    expect(part.existsSync(), isFalse);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
