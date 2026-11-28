import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import '../models/remote_file.dart';
import '../services/herdr_transport.dart' show HerdrTransportException;
import 'host_files.dart';
import 'host_link.dart';

/// What the phone says when an upload has no helper to go to.
const needsHostHelper = 'Needs the agent helper on this machine.';

/// Files from the phone to the host's inbox, through the agent helper's
/// `transfer` service: the only way anything is written to a host. The helper
/// picks the path ([reserve]), checks and keeps what arrives ([put]) and clears
/// old files ([sweep]); this side only moves bytes and says how far it got.
class HostTransfer {
  HostTransfer(this.link, {this.callTimeout = const Duration(seconds: 20)});

  final HostLink link;
  final Duration callTimeout;

  /// The absolute inbox path for the phone file [name] of the session [key]:
  /// the host makes the folders (owner-only) and the name safe and unique.
  Future<String> reserve({required String key, required String name}) async {
    final Object? result;
    try {
      result = await link.call('transfer', 'reserve', {'key': key, 'name': name}, callTimeout);
    } on HostException catch (e) {
      throw uploadFailure(e, null);
    }
    return (result! as Map)['path']! as String;
  }

  /// Removes the inbox's old files on the host (14 days, at most 200 a sweep:
  /// the host's rule); returns how many went.
  Future<int> sweep() async {
    final Object? result;
    try {
      result = await link.call('transfer', 'sweep', const {}, callTimeout);
    } on HostException catch (e) {
      throw uploadFailure(e, null);
    }
    return (result! as Map)['removed']! as int;
  }

  /// The failure of a `transfer` call as the exception callers handle.
  static RemoteFileException uploadFailure(HostException e, String? path) {
    switch (e.code) {
      case 'changed':
        return RemoteFileChanged('The file changed while it was being sent', path: path);
      case 'too_large':
        return RemoteFileException(RemoteFileErrorKind.tooLarge, 'The host takes files up to 2 GB', path: path);
      case 'bad_request':
        return RemoteFileException(
          RemoteFileErrorKind.failed,
          e.message.isEmpty ? 'The machine refused that file name' : e.message,
          fatal: true,
          path: path,
        );
      case 'unavailable':
        return RemoteFileException(RemoteFileErrorKind.unsupported, needsHostHelper, path: path);
    }
    final failure = HostFiles.failure(e, path);
    return failure is RemoteFileException
        ? failure
        : RemoteFileException(
            RemoteFileErrorKind.network,
            failure is HerdrTransportException ? failure.message : '$failure',
            path: path,
          );
  }
}

/// One file going to the host's inbox through `transfer.put` on [HostLink]: its
/// sha256 is taken first (off the transport's isolate), the host says how much
/// of this exact file it already holds ([put]'s `have`), the rest is sent as
/// DATA as fast as the host's credit allows, and the host checks the size and
/// the digest before it keeps the file. A dropped connection or [cancel] leaves
/// what arrived on the host: the same file to the same path continues there.
///
/// Progress counts what has left for the host: it never runs more than the
/// stream's window (1 MiB) ahead of what the host stored, and it never claims
/// the end before the host did.
class HostUpload implements UploadJob {
  HostUpload({
    required this._link,
    required this.localPath,
    required this.inboxPath,
    this.onProgress,
    this.progressInterval = const Duration(milliseconds: 100),
    this.piece = 256 * 1024,
  }) {
    // Observed by the caller or not, a failure never escapes as unhandled
    // (nor does a link that could not be had while the file was being hashed).
    _done.future.then((_) {}, onError: (Object _) {});
    _link.then((_) {}, onError: (Object _) {});
    unawaited(_run());
  }

  final Future<HostLink> _link;
  final String localPath;
  final String inboxPath;
  final void Function(int sent, int total)? onProgress;
  final Duration progressInterval;

  /// Bytes read from the disk and handed to the stream at a time.
  final int piece;

  final _done = Completer<void>();
  HostStream? _stream;
  var _cancelled = false;

  @override
  Future<void> get done => _done.future;

  @override
  void cancel() {
    if (_done.isCompleted) return;
    _cancelled = true;
    _done.completeError(UploadCancelled(path: inboxPath));
    _stream?.reset();
  }

  void _progress(int sent, int total) {
    try {
      onProgress?.call(sent, total);
    } on Object {
      // A listener's bug must not end the upload.
    }
  }

  void _fail(Object error) {
    if (_done.isCompleted) return;
    _done.completeError(switch (error) {
      RemoteFileException() => error,
      HostException() => HostTransfer.uploadFailure(error, inboxPath),
      HerdrTransportException(:final message, :final fatal) => RemoteFileException(
        RemoteFileErrorKind.network,
        message,
        fatal: fatal,
        path: inboxPath,
      ),
      FileSystemException(:final osError, :final message) => RemoteFileException(
        osError?.errorCode == 2
            ? RemoteFileErrorKind.notFound
            : osError?.errorCode == 13
            ? RemoteFileErrorKind.permission
            : RemoteFileErrorKind.failed,
        osError?.errorCode == 2 ? 'The file is gone' : 'Can’t read the file: $message',
      ),
      _ => RemoteFileException(RemoteFileErrorKind.network, '$error', path: inboxPath),
    });
  }

  Future<void> _run() async {
    RandomAccessFile? file;
    try {
      final measured = await _measure();
      if (_cancelled) return;
      final (:size, :sha) = measured;
      if (size > uploadMaxBytes) {
        throw RemoteFileException(
          RemoteFileErrorKind.tooLarge,
          'The file is bigger than ${uploadMaxBytes ~/ (1024 * 1024)} MB',
          path: inboxPath,
        );
      }
      final link = await _link;
      if (_cancelled) return;
      if (!link.hello.has('transfer')) {
        throw RemoteFileException(RemoteFileErrorKind.unsupported, needsHostHelper, path: inboxPath);
      }
      final stream = _stream = link.open('transfer', 'put', {'path': inboxPath, 'size': size, 'sha256': sha});
      final have = Completer<int>();
      final sub = stream.messages.listen((m) {
        if (!have.isCompleted && m is Map && m['have'] is int) have.complete(m['have']! as int);
      }, onError: (Object _) {});
      try {
        // The host answers `have` first, or ends the stream with its refusal.
        final held = await Future.any([
          have.future,
          stream.done.then<int>((end) {
            throw end.error ?? const HostException('bad_response', 'the host ended the upload before answering');
          }),
        ]);
        if (_cancelled) return;
        file = await File(localPath).open();
        var sent = math.min(held, size);
        await file.setPosition(sent);
        final clock = Stopwatch()..start();
        // The start is the first report; the next waits for the interval.
        var reported = 0;
        _progress(sent, size);
        while (sent < size) {
          final bytes = await file.read(math.min(piece, size - sent));
          if (_cancelled) return;
          if (bytes.isEmpty) {
            stream.reset();
            throw RemoteFileChanged('The file changed while it was being sent', path: inboxPath);
          }
          await stream.write(bytes);
          sent += bytes.length;
          if (_cancelled) return;
          if (sent < size && clock.elapsedMilliseconds - reported >= progressInterval.inMilliseconds) {
            reported = clock.elapsedMilliseconds;
            _progress(sent, size);
          }
        }
        stream.end();
        final end = await stream.done;
        if (_cancelled) return;
        final error = end.error;
        if (error != null) throw error;
      } finally {
        await sub.cancel();
      }
      _progress(size, size);
      if (!_done.isCompleted) _done.complete();
    } on Object catch (e) {
      if (!_cancelled) {
        // A send that failed because the stream was closed under it says so;
        // how the stream ended says why (a lost link, the host's refusal).
        final cause = e is HostException && e.code == 'cancelled' ? ((await _stream?.done)?.error ?? e) : e;
        // The host keeps what it has; this side just stops sending.
        _stream?.reset();
        _fail(cause);
      }
    } finally {
      unawaited(file?.close().then((_) {}, onError: (Object _) {}));
    }
  }

  /// The size and sha256 of the file, read in an isolate of its own (a file of
  /// 100 MB takes seconds of hashing, which the transport must not spend).
  Future<({int size, String sha})> _measure() async {
    final path = localPath;
    final type = (await File(path).stat()).type;
    if (type != FileSystemEntityType.file) {
      throw RemoteFileException(
        type == FileSystemEntityType.notFound ? RemoteFileErrorKind.notFound : RemoteFileErrorKind.notAFile,
        type == FileSystemEntityType.notFound ? 'The file is gone' : 'Not a regular file',
      );
    }
    return Isolate.run(() async {
      var size = 0;
      final digest = await sha256
          .bind(
            File(path).openRead().map((c) {
              size += c.length;
              return c;
            }),
          )
          .first;
      return (size: size, sha: digest.toString());
    });
  }
}
