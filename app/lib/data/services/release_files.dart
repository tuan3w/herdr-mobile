import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../models/release_info.dart';
import 'release_feed.dart';

/// A download in progress: [done] completes with the verified APK, or fails
/// with an [UpdateException]; [cancel] stops it (which fails [done] with
/// [UpdateCancelled]) and keeps what was already received.
class UpdateDownload {
  UpdateDownload(this.done, void Function() cancel) : _cancel = cancel;

  final Future<File> done;
  final void Function() _cancel;

  void cancel() => _cancel();
}

/// The person cancelled the download.
class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

/// Where release APKs are kept, and how they get there.
abstract interface class ReleaseFiles {
  /// The verified APK of [release] when it is already on the phone (a
  /// download that finished before, and is the file [release] names), else
  /// null. A quick check (size and the recorded hash): [intact] reads the file.
  Future<File?> verified(ReleaseInfo release);

  /// Whether [apk] still holds the bytes that were verified: it is read again
  /// and hashed, because Android may have cleared or cut the cache since.
  Future<bool> intact(ReleaseInfo release, File apk);

  /// Downloads [release]'s APK, continuing a partial file when there is one,
  /// and checks it against its published SHA-256. [onProgress] gets the bytes
  /// received so far, a few times a second at most.
  UpdateDownload download(ReleaseInfo release, void Function(int received) onProgress);

  /// Deletes every downloaded file except [keep]'s (all of them for null):
  /// an older version, or one that is installed now, is 50 MB of nothing.
  Future<void> prune({ReleaseInfo? keep});
}

/// [ReleaseFiles] over HTTPS into the app's cache directory (`updates/`, the
/// one folder the install FileProvider shares: `res/xml/update_paths.xml`).
///
/// The file is written as `<name>.part` and renamed only once its SHA-256 has
/// matched; the hash is then recorded next to it (`<name>.sha256`). A broken
/// connection leaves the `.part`, and the next try asks for the rest with a
/// `Range` request. Bytes are streamed straight to the file (nothing is held
/// in memory); the hash is computed in another isolate. Anything that makes
/// the bytes not the release's (a different hash, more bytes than the
/// release has, a range the file cannot satisfy) deletes the `.part` and is a
/// [StaleRelease].
class HttpReleaseFiles implements ReleaseFiles {
  HttpReleaseFiles({
    Future<Directory> Function()? directory,
    HttpClient Function()? client,
    this.stall = const Duration(seconds: 30),
  })  : _directory = directory ?? _defaultDirectory,
        _client = client ?? HttpClient.new;

  final Future<Directory> Function() _directory;
  final HttpClient Function() _client;

  /// How long a download may go without a byte before it fails (and can be
  /// continued).
  final Duration stall;

  static Future<Directory> _defaultDirectory() async =>
      Directory('${(await getApplicationCacheDirectory()).path}/updates');

  static const _progressEvery = Duration(milliseconds: 250);
  static final _hex = RegExp(r'^[0-9a-f]{64}$');

  @override
  Future<File?> verified(ReleaseInfo release) async {
    final file = File('${(await _directory()).path}/${release.fileName}');
    try {
      if (await file.length() != release.size) return null;
      final recorded = await _recorded(file);
      if (recorded == null || (release.sha256 != null && recorded != release.sha256)) return null;
      return file;
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<bool> intact(ReleaseInfo release, File apk) async {
    try {
      final recorded = await _recorded(apk);
      if (recorded == null || await apk.length() != release.size) return false;
      if (release.sha256 != null && recorded != release.sha256) return false;
      final path = apk.path;
      return await Isolate.run(() => _sha256Of(path)) == recorded;
    } on FileSystemException {
      return false;
    }
  }

  Future<String?> _recorded(File apk) async {
    final text = (await File('${apk.path}.sha256').readAsString()).trim();
    return _hex.hasMatch(text) ? text : null;
  }

  @override
  Future<void> prune({ReleaseInfo? keep}) async {
    final dir = await _directory();
    if (!dir.existsSync()) return;
    try {
      await for (final entry in dir.list()) {
        final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (keep != null &&
            (name == keep.fileName || name == '${keep.fileName}.part' || name == '${keep.fileName}.sha256')) {
          continue;
        }
        await entry.delete(recursive: true);
      }
    } on FileSystemException {
      // Nothing here is needed; what cannot be deleted now is tried again later.
    }
  }

  @override
  UpdateDownload download(ReleaseInfo release, void Function(int received) onProgress) {
    final client = _client()..connectionTimeout = const Duration(seconds: 15);
    var cancelled = false;
    final done = _run(release, client, onProgress, () => cancelled).catchError((Object e) {
      if (cancelled) throw const UpdateCancelled();
      throw updateFailure(e, doing: 'download the update');
    }).whenComplete(() => client.close(force: true));
    return UpdateDownload(done, () {
      cancelled = true;
      client.close(force: true);
    });
  }

  Future<File> _run(
    ReleaseInfo release,
    HttpClient client,
    void Function(int received) onProgress,
    bool Function() cancelled,
  ) async {
    final dir = await _directory();
    await dir.create(recursive: true);
    final part = File('${dir.path}/${release.fileName}.part');
    final target = File('${dir.path}/${release.fileName}');

    // The checksum first: nothing is worth downloading that cannot be checked.
    final want = release.sha256 ?? await _publishedSum(release, client);

    var have = part.existsSync() ? part.lengthSync() : 0;
    if (have > release.size) {
      part.deleteSync();
      have = 0;
    }
    if (have < release.size) {
      final response = await openGet(
        client,
        Uri.parse(release.apkUrl),
        headers: {if (have > 0) HttpHeaders.rangeHeader: 'bytes=$have-'},
      );
      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        await response.drain<void>();
        part.deleteSync();
        throw const StaleRelease('The partial download did not fit the release. Try again.');
      }
      final resumed = have > 0 && response.statusCode == HttpStatus.partialContent;
      if (response.statusCode != HttpStatus.ok && !resumed) {
        await response.drain<void>();
        throw httpFailure(response.statusCode);
      }
      if (resumed && !(response.headers.value(HttpHeaders.contentRangeHeader) ?? 'bytes $have-').startsWith('bytes $have-')) {
        await response.drain<void>();
        part.deleteSync();
        throw const StaleRelease('The partial download did not fit the release. Try again.');
      }
      if (!resumed) have = 0;
      final sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
      final clock = Stopwatch()..start();
      var lastReport = Duration.zero;
      onProgress(have);
      var oversize = false;
      try {
        await for (final chunk in failWhenStalled(response, stall)) {
          sink.add(chunk);
          have += chunk.length;
          if (have > release.size) {
            oversize = true;
            break;
          }
          if (clock.elapsed - lastReport >= _progressEvery) {
            lastReport = clock.elapsed;
            onProgress(have);
          }
        }
      } finally {
        await sink.close();
      }
      if (oversize) {
        part.deleteSync();
        throw StaleRelease('The file on GitHub is larger than version ${release.version} says. Try again.');
      }
      onProgress(have);
    }
    if (have != release.size) {
      throw UpdateException(
        'The download stopped at ${megabytes(have)} of ${megabytes(release.size)}. '
        'It continues from there when you try again.',
      );
    }

    if (cancelled()) throw const UpdateCancelled();
    final partPath = part.path;
    final got = await Isolate.run(() => _sha256Of(partPath));
    if (got != want) {
      part.deleteSync();
      throw const StaleRelease('The download did not match its checksum, so it was thrown away. Try again.');
    }
    await File('${target.path}.sha256').writeAsString(got);
    await part.rename(target.path);
    return target;
  }

  /// The APK's line of the release's `SHA256SUMS` (`sha256sum` output: the hex,
  /// two spaces, the name).
  Future<String> _publishedSum(ReleaseInfo release, HttpClient client) async {
    final response = await openGet(client, Uri.parse(release.sumsUrl!));
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw httpFailure(response.statusCode);
    }
    final text = await readLimited(failWhenStalled(response, stall), 64 * 1024);
    for (final line in text.split('\n')) {
      final m = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$').firstMatch(line);
      if (m != null && m[2] == release.fileName) return m[1]!.toLowerCase();
    }
    throw UpdateException(
      'Version ${release.version} has no checksum for its APK, so herdr will not install it.',
    );
  }
}

Future<String> _sha256Of(String path) async => (await sha256.bind(File(path).openRead()).first).toString();
