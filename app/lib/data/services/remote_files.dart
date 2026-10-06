import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../models/remote_file.dart';
import 'herdr_transport.dart';

export '../models/remote_file.dart' show UploadCancelled, UploadJob, uploadMaxBytes;

/// A flag a caller raises to stop a long read between pieces.
class ReadCancel {
  bool cancelled = false;

  void cancel() => cancelled = true;
}

/// A read stopped by its [ReadCancel]: not a failure, nobody is waiting.
class ReadCancelled implements Exception {
  const ReadCancelled();

  @override
  String toString() => 'The read was cancelled';
}

/// Reads a machine's files through its transport (SFTP over the machine's SSH
/// connection). Every failure surfaces as a [RemoteFileException], including a
/// dropped connection, so screens handle one error type.
class RemoteFiles {
  /// [maxUploads] files go to the host at once; the rest wait their turn in
  /// the order they were asked for. Uploads share the machine's one SFTP
  /// channel with browsing, so two is the most that leaves it responsive.
  RemoteFiles(this._transport, {this.maxUploads = 2});

  final HerdrTransport _transport;
  final int maxUploads;
  Future<String>? _home;
  var _uploading = 0;
  final _waiting = Queue<_Upload>();

  /// False when the transport has no file channel at all (nothing to show).
  bool get supported => _transport.supportsFiles;

  /// The login directory, which is where relative and `~` paths start. Asked
  /// once; a failed ask is not remembered.
  Future<String> home() {
    final cached = _home;
    if (cached != null) return cached;
    final ask = _guard('~', () => _transport.realPath('.'));
    _home = ask;
    ask.then((_) {}, onError: (Object _) {
      if (identical(_home, ask)) _home = null;
    });
    return ask;
  }

  /// Follows links. Throws notFound / permission.
  Future<RemoteStat> stat(String path) => _guard(path, () => _transport.statFile(path));

  /// Entries of [path] in server order. Throws notFound / permission /
  /// notADirectory.
  Future<List<RemoteEntry>> list(String path) => _guard(path, () => _transport.listDirectory(path));

  /// Up to [length] bytes from [offset] (the transport caps one call at
  /// [remoteReadCap]); fewer at end of file.
  Future<Uint8List> read(String path, {int offset = 0, int length = remoteReadCap}) =>
      _guard(path, () => _transport.readFile(path, offset: offset, length: length));

  /// All [size] bytes of a file, fetched in pieces of at most [chunk] bytes
  /// (never more than [remoteReadCap]). For files the caller has already
  /// decided are small enough to hold in memory.
  ///
  /// [onProgress] hears the bytes held after every piece (a viewer shows
  /// "4.2 of 11 MB"); a [cancel] that fires stops before the next piece with
  /// [ReadCancelled], so a screen that moved on does not keep a link busy.
  Future<Uint8List> readAll(
    String path, {
    required int size,
    int chunk = remoteReadCap,
    void Function(int received)? onProgress,
    ReadCancel? cancel,
  }) async {
    final piece = chunk.clamp(1, remoteReadCap);
    if (size <= piece && onProgress == null && cancel == null) return read(path, length: size);
    final out = Uint8List(size);
    var at = 0;
    while (at < size) {
      if (cancel?.cancelled ?? false) throw const ReadCancelled();
      final got = await read(path, offset: at, length: piece < size - at ? piece : size - at);
      if (got.isEmpty) break; // the file shrank since it was measured
      out.setRange(at, at + got.length, got);
      at += got.length;
      onProgress?.call(at);
    }
    if (cancel?.cancelled ?? false) throw const ReadCancelled();
    return at == size ? out : Uint8List.sublistView(out, 0, at);
  }

  /// `mkdir -p`: [path] and any missing parents, owner-only (0700). An existing
  /// folder is left as it is. Throws permission / notADirectory.
  Future<void> makeDirs(String path) => _guard(path, () => _transport.makeDirs(path));

  /// Deletes the file (or link) at [path]; never a folder. Throws notFound /
  /// permission.
  Future<void> remove(String path) => _guard(path, () => _transport.removeFile(path));

  /// Copies the local file [localPath] to [remotePath] over SFTP (created or
  /// overwritten, mode 0600), starting within the same event-loop turn when
  /// fewer than [maxUploads] are running, else when one ends.
  ///
  /// Never throws: every failure arrives as the job's `done` error, a
  /// [RemoteFileException] (`tooLarge` above [uploadMaxBytes], checked before
  /// anything connects; [UploadCancelled] after [UploadJob.cancel]; `network` when
  /// the link is lost, with no resume). [onProgress] hears the bytes the host
  /// has stored, at most every 100 ms, ending with `total`/`total`. The file
  /// is read and sent inside the transport's isolate; bytes never come here.
  UploadJob upload({
    required String localPath,
    required String remotePath,
    void Function(int sent, int total)? onProgress,
  }) {
    final job = _Upload(this, localPath, remotePath, onProgress);
    final refusal = _refuse(localPath, remotePath);
    if (refusal != null) {
      job.fail(refusal);
    } else if (_uploading < maxUploads) {
      job.start();
    } else {
      _waiting.add(job);
    }
    return job;
  }

  /// Why [localPath] cannot be sent, found with one local stat (no bytes read,
  /// no connection).
  RemoteFileException? _refuse(String localPath, String remotePath) {
    if (!_transport.supportsFiles) {
      return RemoteFileException(RemoteFileErrorKind.unsupported,
          'Files are not available on this machine.', path: remotePath);
    }
    final FileStat stat;
    try {
      stat = File(localPath).statSync();
    } on FileSystemException {
      return RemoteFileException(RemoteFileErrorKind.notFound, 'The file is gone');
    }
    if (stat.type != FileSystemEntityType.file) {
      return RemoteFileException(
          stat.type == FileSystemEntityType.notFound
              ? RemoteFileErrorKind.notFound
              : RemoteFileErrorKind.notAFile,
          stat.type == FileSystemEntityType.notFound ? 'The file is gone' : 'Not a regular file');
    }
    if (stat.size > uploadMaxBytes) {
      return RemoteFileException(RemoteFileErrorKind.tooLarge,
          'The file is bigger than ${uploadMaxBytes ~/ (1024 * 1024)} MB',
          path: remotePath);
    }
    return null;
  }

  void _uploadEnded() {
    _uploading--;
    while (_uploading < maxUploads && _waiting.isNotEmpty) {
      _waiting.removeFirst().start();
    }
  }

  /// Canonical absolute path (links resolved when the target exists).
  Future<String> realpath(String path) => _guard(path, () => _transport.realPath(path));

  /// Absolute, normalised form of [raw]: `~` expands to the login directory and
  /// a relative path is taken against [cwd] (home when there is none). A
  /// trailing `:line:col` is NOT removed here, see [RemotePath.splitLocation].
  Future<String> resolve(String raw, {String? cwd}) async {
    final text = raw.trim();
    if (text.isEmpty) {
      throw RemoteFileException(RemoteFileErrorKind.notFound, 'No path given');
    }
    final needsHome = RemotePath.usesHome(text) ||
        (!RemotePath.isAbsolute(text) && !(cwd != null && RemotePath.isAbsolute(cwd)));
    final resolved = RemotePath.resolve(
      text,
      cwd: cwd,
      home: needsHome ? await home() : null,
    );
    if (resolved == null) {
      throw RemoteFileException(RemoteFileErrorKind.notFound, 'Cannot place $text', path: text);
    }
    return resolved;
  }

  Future<T> _guard<T>(String path, Future<T> Function() op) async {
    if (!_transport.supportsFiles) {
      throw RemoteFileException(
        RemoteFileErrorKind.unsupported,
        'Files are not available on this machine.',
        path: path,
      );
    }
    try {
      return await op();
    } on RemoteFileException {
      rethrow;
    } on HerdrTransportException catch (e) {
      throw RemoteFileException(RemoteFileErrorKind.network, e.message, fatal: e.fatal, path: path);
    } on Object catch (e) {
      throw RemoteFileException(RemoteFileErrorKind.network, '$e', path: path);
    }
  }
}

/// One upload of [RemoteFiles.upload]: waiting for a turn, running, or over.
class _Upload implements UploadJob {
  _Upload(this._files, this._localPath, this._remotePath, this._onProgress) {
    _done.future.then((_) {}, onError: (Object _) {});
  }

  final RemoteFiles _files;
  final String _localPath;
  final String _remotePath;
  final void Function(int sent, int total)? _onProgress;
  final _done = Completer<void>();
  UploadJob? _inner;
  var _running = false;

  @override
  Future<void> get done => _done.future;

  void start() {
    _running = true;
    _files._uploading++;
    try {
      final inner = _inner = _files._transport.uploadFile(
        localPath: _localPath,
        remotePath: _remotePath,
        onProgress: _onProgress,
      );
      inner.done.then((_) => _settle(null), onError: (Object e) => _settle(e));
    } on Object catch (e) {
      _settle(e);
    }
  }

  void _settle(Object? error) {
    if (_done.isCompleted) return;
    if (error == null) {
      _done.complete();
    } else {
      fail(error);
    }
    _release();
  }

  void fail(Object error) {
    if (_done.isCompleted) return;
    _done.completeError(switch (error) {
      RemoteFileException() => error,
      HerdrTransportException(:final message, :final fatal) =>
        RemoteFileException(RemoteFileErrorKind.network, message, fatal: fatal, path: _remotePath),
      _ => RemoteFileException(RemoteFileErrorKind.network, '$error', path: _remotePath),
    });
    _release();
  }

  void _release() {
    if (!_running) return;
    _running = false;
    _files._uploadEnded();
  }

  @override
  void cancel() {
    if (_done.isCompleted) return;
    _files._waiting.remove(this);
    _inner?.cancel();
    fail(UploadCancelled(path: _remotePath));
  }
}
