import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../models/remote_file.dart';
import '../models/remote_search.dart';
import 'herdr_transport.dart';

export '../models/remote_file.dart' show UploadCancelled, UploadJob, uploadMaxBytes;

/// A flag a caller raises to stop a long read between pieces.
class ReadCancel {
  bool _cancelled = false;
  final _done = Completer<void>();

  bool get cancelled => _cancelled;

  /// Completes when [cancel] is called, for work that can stop at once instead
  /// of between pieces (a thumbnail the host is still making).
  Future<void> get whenCancelled => _done.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _done.complete();
  }
}

/// A read stopped by its [ReadCancel]: not a failure, nobody is waiting.
class ReadCancelled implements Exception {
  const ReadCancelled();

  @override
  String toString() => 'The read was cancelled';
}

/// Reads a machine's files through its transport (the agent helper's `fs` when
/// the machine has it, SFTP otherwise) and sends phone files to its inbox
/// (helper only). Every failure surfaces as a [RemoteFileException], including
/// a dropped connection, so screens handle one error type.
class RemoteFiles {
  /// [maxUploads] files go to the host at once; the rest wait their turn in
  /// the order they were asked for.
  ///
  /// [machineId] names the machine in the keys of the disk cache, which
  /// must not mix two machines' files; empty means "do not use the cache".
  RemoteFiles(this._transport, {this.maxUploads = 2, this.machineId = ''});

  final HerdrTransport _transport;
  final int maxUploads;
  final String machineId;
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
    ask.then(
      (_) {},
      onError: (Object _) {
        if (identical(_home, ask)) _home = null;
      },
    );
    return ask;
  }

  /// Follows links. Throws notFound / permission.
  Future<RemoteStat> stat(String path) => _guard(path, () => _transport.statFile(path));

  /// Entries of [path] in server order. Throws notFound / permission /
  /// notADirectory.
  Future<List<RemoteEntry>> list(String path) => _guard(path, () => _transport.listDirectory(path));

  /// Up to [length] bytes from [offset] (the transport caps one call at
  /// [remoteReadCap]); fewer at end of file. With [ifMatch] (the file as it was
  /// seen) a machine with the agent helper refuses a file that is no longer
  /// that one with [RemoteFileChanged]; SFTP cannot check and reads whatever is
  /// there.
  Future<Uint8List> read(String path, {int offset = 0, int length = remoteReadCap, RemoteStat? ifMatch}) =>
      _guard(path, () => _transport.readFile(path, offset: offset, length: length, ifMatch: ifMatch));

  /// [path] now (null when nothing is there) and again whenever it changes, for
  /// as long as the subscription lives: the viewer's "changed on disk". The
  /// stream errors with a [RemoteFileException] and closes when the machine
  /// cannot be asked; listen again to start over.
  Stream<RemoteStat?> watch(String path) {
    if (!_transport.supportsFiles) {
      return Stream.error(
        RemoteFileException(RemoteFileErrorKind.unsupported, 'Files are not available on this machine.', path: path),
      );
    }
    return _transport
        .watchFile(path)
        .transform(
          StreamTransformer.fromHandlers(
            handleError: (error, stack, sink) => sink.addError(_asFileError(error, path), stack),
          ),
        );
  }

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

  /// A small JPEG of the picture at [path], its longest side [maxPx], made on
  /// the machine (agent helper only), or null when none can be had: SFTP, an
  /// older helper, a file that is not a picture the host reads, one too large
  /// or changed since [expect] (the file as it was listed), a lost connection,
  /// or [cancel] firing first. Never throws: the caller does what it did
  /// before thumbnails existed (reads the file itself when it is small).
  Future<Uint8List?> thumbnail(String path, {int maxPx = 256, RemoteStat? expect, ReadCancel? cancel}) async {
    if (!_transport.supportsFiles || (cancel?.cancelled ?? false)) return null;
    try {
      return await _transport.thumbnailFile(path, maxPx: maxPx, expect: expect, cancelled: cancel?.whenCancelled);
    } on Object {
      return null;
    }
  }

  /// The matches of [spec] below its root as the machine finds them: batches,
  /// then one [FileSearchDone] (its `truncated` says a limit was hit and more
  /// may exist). Cancelling the subscription stops the search on the machine.
  /// Errors with a [RemoteFileException] (`notFound`/`permission`/
  /// `notADirectory` for the root, `network` for a lost connection).
  Stream<FileSearchEvent> search(FileSearchSpec spec) {
    if (!_transport.supportsFiles) {
      return Stream.error(
        RemoteFileException(
          RemoteFileErrorKind.unsupported,
          'Files are not available on this machine.',
          path: spec.root,
        ),
      );
    }
    return _transport
        .searchFiles(spec)
        .transform(
          StreamTransformer.fromHandlers(
            handleError: (error, stack, sink) => sink.addError(_asFileError(error, spec.root), stack),
          ),
        );
  }

  /// Picks the inbox path on the host for the phone file [name] of the session
  /// [key] (the host makes the folders and the name safe and unique): see
  /// [HerdrTransport.reserveInboxFile]. Throws [RemoteFileException]
  /// (`unsupported` without the agent helper, `permission`, `network`).
  Future<String> reserveInboxFile({required String key, required String name}) =>
      _guard('inbox', () => _transport.reserveInboxFile(key: key, name: name));

  /// Removes the old files from the host's inbox; returns how many went.
  Future<int> sweepInbox() => _guard('inbox', _transport.sweepInbox);

  /// Copies the local file [localPath] to the inbox path [inboxPath] (from
  /// [reserveInboxFile]) through the agent helper, starting within the same
  /// event-loop turn when fewer than [maxUploads] are running, else when one
  /// ends.
  ///
  /// Never throws: every failure arrives as the job's `done` error, a
  /// [RemoteFileException] (`tooLarge` above [uploadMaxBytes], checked before
  /// anything connects; [UploadCancelled] after [UploadJob.cancel]; `network`
  /// when the link is lost; `unsupported` without the helper). A lost link or a
  /// cancel keeps what the host received: the same file to the same
  /// [inboxPath] continues there. [onProgress] hears the bytes sent, at most
  /// every 100 ms, ending with `total`/`total`. The file is hashed, read and
  /// sent inside the transport's isolate; bytes never come here.
  UploadJob uploadToInbox({
    required String localPath,
    required String inboxPath,
    void Function(int sent, int total)? onProgress,
  }) {
    final job = _Upload(this, localPath, inboxPath, onProgress);
    final refusal = _refuse(localPath, inboxPath);
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
  RemoteFileException? _refuse(String localPath, String inboxPath) {
    if (!_transport.supportsFiles) {
      return RemoteFileException(
        RemoteFileErrorKind.unsupported,
        'Files are not available on this machine.',
        path: inboxPath,
      );
    }
    final FileStat stat;
    try {
      stat = File(localPath).statSync();
    } on FileSystemException {
      return RemoteFileException(RemoteFileErrorKind.notFound, 'The file is gone');
    }
    if (stat.type != FileSystemEntityType.file) {
      return RemoteFileException(
        stat.type == FileSystemEntityType.notFound ? RemoteFileErrorKind.notFound : RemoteFileErrorKind.notAFile,
        stat.type == FileSystemEntityType.notFound ? 'The file is gone' : 'Not a regular file',
      );
    }
    if (stat.size > uploadMaxBytes) {
      return RemoteFileException(
        RemoteFileErrorKind.tooLarge,
        'The file is bigger than ${uploadMaxBytes ~/ (1024 * 1024)} MB',
        path: inboxPath,
      );
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
    final needsHome =
        RemotePath.usesHome(text) || (!RemotePath.isAbsolute(text) && !(cwd != null && RemotePath.isAbsolute(cwd)));
    final resolved = RemotePath.resolve(text, cwd: cwd, home: needsHome ? await home() : null);
    if (resolved == null) {
      throw RemoteFileException(RemoteFileErrorKind.notFound, 'Can’t place $text', path: text);
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
    } on Object catch (e) {
      throw _asFileError(e, path);
    }
  }

  /// [error] as the one exception screens handle: a connection problem or
  /// anything unexpected is `network` (retryable unless the transport says not).
  static RemoteFileException _asFileError(Object error, String path) => switch (error) {
    RemoteFileException() => error,
    HerdrTransportException(:final message, :final fatal) => RemoteFileException(
      RemoteFileErrorKind.network,
      message,
      fatal: fatal,
      path: path,
    ),
    _ => RemoteFileException(RemoteFileErrorKind.network, '$error', path: path),
  };
}

/// One upload of [RemoteFiles.uploadToInbox]: waiting for a turn, running, or over.
class _Upload implements UploadJob {
  _Upload(this._files, this._localPath, this._inboxPath, this._onProgress) {
    _done.future.then((_) {}, onError: (Object _) {});
  }

  final RemoteFiles _files;
  final String _localPath;
  final String _inboxPath;
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
        inboxPath: _inboxPath,
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
      HerdrTransportException(:final message, :final fatal) => RemoteFileException(
        RemoteFileErrorKind.network,
        message,
        fatal: fatal,
        path: _inboxPath,
      ),
      _ => RemoteFileException(RemoteFileErrorKind.network, '$error', path: _inboxPath),
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
    fail(UploadCancelled(path: _inboxPath));
  }
}
