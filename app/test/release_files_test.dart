import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/release_info.dart';
import 'package:herdr_mobile/data/services/release_files.dart';

/// A local server standing in for GitHub: the APK (with Range), SHA256SUMS.
class _Server {
  _Server(this.apk);

  final List<int> apk;
  late final HttpServer http;
  final ranges = <String?>[];

  /// Cut the APK after this many bytes, once, to break a download.
  int? breakAfter;

  /// Answer a Range request with the whole file and 200, as a server may.
  bool ignoreRange = false;

  /// Answer a Range request with 416.
  bool refuseRange = false;

  /// Send this many bytes more than the file has.
  int extra = 0;

  /// Send this many bytes, then say nothing and keep the connection open.
  int? goQuietAfter;

  /// Answer the APK request with a redirect to this address.
  String? redirectTo;

  Future<void> start() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(http.forEach((req) async {
      final res = req.response;
      if (req.uri.path.endsWith('SHA256SUMS')) {
        res.write('${sha256.convert(apk)}  herdr-mobile-0.1.7.apk\n');
        await res.close();
        return;
      }
      final range = req.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      if (redirectTo != null) {
        res.statusCode = HttpStatus.found;
        res.headers.set(HttpHeaders.locationHeader, redirectTo!);
        await res.close();
        return;
      }
      var from = 0;
      if (range != null && refuseRange) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await res.close();
        return;
      }
      if (range != null && !ignoreRange) {
        from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $from-${apk.length - 1}/${apk.length}');
      }
      final body = [...apk.sublist(from), ...List<int>.filled(extra, 0)];
      res.contentLength = body.length;
      final cut = breakAfter;
      if (cut != null) {
        breakAfter = null;
        final socket = await res.detachSocket();
        socket.add(body.sublist(0, cut));
        await socket.flush();
        socket.destroy();
        return;
      }
      final quiet = goQuietAfter;
      if (quiet != null) {
        res.add(body.sublist(0, quiet));
        await res.flush();
        return; // never closed: the connection stalls
      }
      res.add(body);
      await res.close();
    }));
  }

  ReleaseInfo release({String? sha}) => ReleaseInfo(
        version: '0.1.7',
        apkUrl: 'http://127.0.0.1:${http.port}/herdr-mobile-0.1.7.apk',
        size: apk.length,
        pageUrl: 'https://github.com/tuan3w/herdr-mobile/releases/tag/v0.1.7',
        notes: '',
        sha256: sha,
        sumsUrl: sha == null ? 'http://127.0.0.1:${http.port}/SHA256SUMS' : null,
      );
}

void main() {
  late Directory dir;
  late HttpReleaseFiles files;
  late _Server server;
  final apk = List<int>.generate(200000, (i) => i % 251);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('release_files_test');
    files = HttpReleaseFiles(directory: () async => dir, stall: const Duration(milliseconds: 400));
    server = _Server(apk);
    await server.start();
  });

  tearDown(() async {
    await server.http.close(force: true);
    await dir.delete(recursive: true);
  });

  File part() => File('${dir.path}/herdr-mobile-0.1.7.apk.part');

  test('downloads the APK, checks it against SHA256SUMS and keeps it under its final name', () async {
    final release = server.release();
    final progress = <int>[];
    final file = await files.download(release, progress.add).done;
    expect(file.path, endsWith('herdr-mobile-0.1.7.apk'));
    expect(await file.readAsBytes(), apk);
    expect(part().existsSync(), isFalse);
    expect(progress.last, apk.length);
    expect(await files.verified(release), isNotNull);
    expect(await files.intact(release, file), isTrue);
  });

  test('a download that breaks continues from where it stopped', () async {
    final release = server.release();
    server.breakAfter = 70000;
    await expectLater(files.download(release, (_) {}).done, throwsA(isA<UpdateException>()));
    final kept = part().lengthSync();
    expect(kept, greaterThan(0));
    expect(kept, lessThan(apk.length));

    final file = await files.download(release, (_) {}).done;
    expect(server.ranges.last, 'bytes=$kept-');
    expect(await file.readAsBytes(), apk);
  });

  test('a server that answers a Range request with the whole file does not corrupt the file', () async {
    final release = server.release();
    server.breakAfter = 50000;
    await expectLater(files.download(release, (_) {}).done, throwsA(isA<UpdateException>()));
    server.ignoreRange = true;
    final file = await files.download(release, (_) {}).done;
    expect(await file.readAsBytes(), apk);
  });

  test('a range the file cannot satisfy discards the part and is a stale release', () async {
    final release = server.release();
    server.breakAfter = 50000;
    await expectLater(files.download(release, (_) {}).done, throwsA(isA<UpdateException>()));
    server.refuseRange = true;
    await expectLater(files.download(release, (_) {}).done, throwsA(isA<StaleRelease>()));
    expect(part().existsSync(), isFalse);
  });

  test('more bytes than the release has stops the download and discards it', () async {
    server.extra = 5000;
    await expectLater(files.download(server.release(), (_) {}).done, throwsA(isA<StaleRelease>()));
    expect(dir.listSync(), isEmpty);
  });

  test('bytes that do not match the published checksum are thrown away, never installed', () async {
    final tampered = _Server([...apk]..[100] = apk[100] ^ 0xff);
    await tampered.start();
    addTearDown(() => tampered.http.close(force: true));
    // The release's checksum is that of the real file; the server serves other bytes.
    final release = tampered.release(sha: sha256.convert(apk).toString());
    await expectLater(files.download(release, (_) {}).done, throwsA(isA<StaleRelease>()));
    expect(dir.listSync(), isEmpty);
    expect(await files.verified(release), isNull);
  });

  test('a SHA256SUMS without the APK refuses the download before any byte of it', () async {
    final release = server.release();
    final other = ReleaseInfo(
      version: '0.1.8',
      apkUrl: release.apkUrl,
      size: release.size,
      pageUrl: release.pageUrl,
      notes: '',
      sumsUrl: release.sumsUrl,
    );
    await expectLater(files.download(other, (_) {}).done, throwsA(isA<UpdateException>()));
    expect(server.ranges, isEmpty);
  });

  test('a connection that goes quiet fails, keeps what arrived, and can be continued', () async {
    final release = server.release();
    server.goQuietAfter = 60000;
    await expectLater(files.download(release, (_) {}).done, throwsA(isA<UpdateException>()));
    expect(part().lengthSync(), greaterThan(0));
    server.goQuietAfter = null;
    final file = await files.download(release, (_) {}).done;
    expect(await file.readAsBytes(), apk);
  });

  test('a redirect to a host that is not GitHub is refused', () async {
    server.redirectTo = 'https://evil.example/herdr-mobile-0.1.7.apk';
    await expectLater(files.download(server.release(), (_) {}).done, throwsA(isA<UpdateException>()));
    expect(dir.listSync(), isEmpty);
  });

  test('cancelling mid-download stops it with UpdateCancelled and keeps the part', () async {
    final release = server.release();
    server.goQuietAfter = 60000;
    // A long stall limit: this test cancels, the limit must not fire first.
    final patient = HttpReleaseFiles(directory: () async => dir, stall: const Duration(seconds: 30));
    final job = patient.download(release, (_) {});
    unawaited(job.done.then((_) {}, onError: (_) {}));
    // Bytes arrive, then nothing: cancel once some are on disk.
    for (var i = 0; i < 200 && !(part().existsSync() && part().lengthSync() > 0); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    job.cancel();
    await expectLater(job.done, throwsA(isA<UpdateCancelled>()));
    expect(part().existsSync(), isTrue);
  });

  test('a file that was cut or replaced after it was verified is not intact', () async {
    final release = server.release();
    final file = await files.download(release, (_) {}).done;
    await file.writeAsBytes(apk.sublist(0, apk.length - 1));
    expect(await files.verified(release), isNull, reason: 'size no longer matches');
    await file.writeAsBytes([...apk]..[7] = apk[7] ^ 1);
    expect(await files.intact(release, file), isFalse, reason: 'same size, other bytes');
    await file.delete();
    expect(await files.intact(release, file), isFalse);
  });

  test('a file whose recorded hash is not the one the release now publishes is not offered', () async {
    final file = await files.download(server.release(), (_) {}).done;
    final republished = server.release(sha: 'b' * 64);
    expect(await files.verified(republished), isNull);
    expect(file.existsSync(), isTrue);
  });

  test('prune keeps the one release asked for and deletes the rest', () async {
    File('${dir.path}/herdr-mobile-0.1.5.apk').writeAsStringSync('old');
    File('${dir.path}/herdr-mobile-0.1.7.apk.part').writeAsStringSync('half');
    await files.prune(keep: server.release());
    expect(dir.listSync().map((e) => e.uri.pathSegments.last), ['herdr-mobile-0.1.7.apk.part']);
    await files.prune();
    expect(dir.listSync(), isEmpty);
  });
}
