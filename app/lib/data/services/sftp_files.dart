import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../models/remote_file.dart';

/// The slice of dartssh2's [SftpClient] that file browsing needs, so the
/// mapping and caching in [SftpFiles] can be tested without a server.
abstract interface class SftpApi {
  Future<SftpFileAttrs> stat(String path, {bool followLink = true});
  Future<List<SftpName>> listdir(String path);
  Future<String> absolute(String path);
  Future<String> readlink(String path);

  /// Up to [length] bytes of the file at [offset]; fewer at end of file.
  Future<Uint8List> readBytes(String path, int offset, int length);

  /// Opens [path] for writing (created, or truncated when it exists). The file
  /// is made readable by its owner only when the server allows it.
  Future<SftpUploadFile> openForWrite(String path);

  /// Creates one folder, readable by its owner only.
  Future<void> mkdir(String path);

  /// Deletes a file (never a folder).
  Future<void> remove(String path);

  Future<void> close();
}

/// A remote file open for writing: one WRITE request per [write].
abstract interface class SftpUploadFile {
  /// Stores [data] at [offset]. The request is encoded within a few
  /// microtasks of the call, but [data] must stay untouched until the future
  /// completes (the caller reuses its buffers after that).
  Future<void> write(int offset, Uint8List data);

  Future<void> close();
}

class _DartUploadFile implements SftpUploadFile {
  _DartUploadFile(this._file);

  final SftpFile _file;

  @override
  Future<void> write(int offset, Uint8List data) =>
      _file.writeBytes(data, offset: offset, chunkSize: data.length, maxPendingRequests: 1);

  @override
  Future<void> close() => _file.close();
}

/// Owner read/write (0600) and owner-only folder (0700) permission bits.
const _fileMode = 0x180;
const _dirMode = 0x1C0;

/// [SftpApi] over a live [SftpClient].
class DartSftp implements SftpApi {
  DartSftp(this._client);

  final SftpClient _client;

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) =>
      _client.stat(path, followLink: followLink);

  @override
  Future<List<SftpName>> listdir(String path) => _client.listdir(path);

  @override
  Future<String> absolute(String path) => _client.absolute(path);

  @override
  Future<String> readlink(String path) => _client.readlink(path);

  @override
  Future<Uint8List> readBytes(String path, int offset, int length) async {
    final file = await _client.open(path);
    try {
      return await file.readBytes(length: length, offset: offset);
    } finally {
      unawaited(file.close().then((_) {}, onError: (Object _) {}));
    }
  }

  @override
  Future<SftpUploadFile> openForWrite(String path) async {
    final file = await _client.open(
      path,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
    );
    try {
      // The open call cannot carry a mode in dartssh2, and a file that already
      // existed keeps its own: narrow it before any byte is written. A server
      // that refuses leaves the umask's mode, still inside a 0700 folder.
      await file.setStat(SftpFileAttrs(mode: const SftpFileMode.value(_fileMode)));
    } on SftpStatusError {
      // see above
    }
    return _DartUploadFile(file);
  }

  @override
  Future<void> mkdir(String path) =>
      _client.mkdir(path, SftpFileAttrs(mode: const SftpFileMode.value(_dirMode)));

  @override
  Future<void> remove(String path) => _client.remove(path);

  @override
  Future<void> close() => _client.close();
}

/// File access over one lazily opened, cached SFTP session.
///
/// [open] makes a fresh session (SshTransport hands it the authenticated SSH
/// client). A session whose channel died is dropped and reopened once, so a
/// phone that slept and reconnected does not need the screen to be reopened.
/// Everything is SFTP binary packets: there is no remote shell and so nothing
/// to quote.
class SftpFiles {
  SftpFiles({
    required this.open,
    this.metaTimeout = const Duration(seconds: 20),
    this.readTimeout = const Duration(seconds: 60),
    this.uploadBlock = 32 * 1024,
    this.uploadWindow = 32,
    this.uploadStartWindow = 8,
    this.browseWindow = 4,
    this.progressInterval = const Duration(milliseconds: 100),
    this.stallTimeout = const Duration(seconds: 30),
  });

  /// Opens a session. Throws [RemoteFileException] (unsupported when the host
  /// has no SFTP) or lets a `HerdrTransportException` through when the SSH
  /// connection itself is down.
  final Future<SftpApi> Function() open;
  final Duration metaTimeout;
  final Duration readTimeout;

  /// Bytes in one WRITE request (32 KB is what every SFTP server accepts) and
  /// the most requests an upload leaves unanswered: it starts at
  /// [uploadStartWindow] and follows the link's bandwidth delay product (see
  /// [_Window]) up to [uploadWindow] (`32 x 32 KB` = 1 MB in flight). The
  /// pipeline never waits for one answer before sending the next; a window
  /// no bigger than the link needs keeps the queue a listing waits behind
  /// short. Set [uploadStartWindow] to [uploadWindow] for a fixed window.
  final int uploadBlock;
  final int uploadWindow;
  final int uploadStartWindow;

  /// The window while a browse request is waiting on the same channel (see
  /// [_windowCap]), and the spacing of progress callbacks.
  final int browseWindow;
  final Duration progressInterval;

  /// An upload that hears no answer to any write for this long has lost its
  /// link.
  final Duration stallTimeout;

  /// Uploads running and browse/metadata requests in flight on the one SFTP
  /// channel.
  int _uploads = 0;
  int _browsing = 0;

  /// The most requests an upload may leave unanswered right now. Everything
  /// shares ONE SFTP channel (and one SSH connection: sshd's MaxSessions is
  /// spent), so a listing sent behind a full window waits for that window to
  /// drain over the wire. Browsing therefore wins: while any browse request
  /// is in flight the window drops to [browseWindow] (128 KB ahead); several
  /// uploads split the full window between them.
  int get _windowCap => _browsing > 0
      ? browseWindow
      : math.max(browseWindow, uploadWindow ~/ math.max(1, _uploads));

  /// Links resolved at once while listing a directory.
  static const _linkBatch = 24;

  Future<SftpApi>? _session;

  /// The opened session behind [_session], so a dead one can be dropped
  /// synchronously (the retry must not find it again).
  SftpApi? _live;

  /// Drops the session (the connection it rode on is gone or being closed).
  void discard() {
    final s = _session;
    _session = null;
    _live = null;
    if (s != null) {
      unawaited(s.then((api) => api.close()).then((_) {}, onError: (Object _) {}));
    }
  }

  Future<RemoteStat> stat(String path) => _run(path, metaTimeout, (s) async {
        final attrs = await s.stat(path);
        return _statOf(path, attrs);
      });

  Future<String> realPath(String path) => _run(path, metaTimeout, (s) => s.absolute(path));

  Future<List<RemoteEntry>> list(String path) => _run(path, metaTimeout, (s) async {
        final names = await s.listdir(path);
        final entries = <RemoteEntry>[];
        final links = <int>[];
        for (final n in names) {
          if (n.filename == '.' || n.filename == '..') continue;
          final kind = _kindOf(n.attr.mode?.type);
          entries.add(RemoteEntry(
            name: n.filename,
            path: RemotePath.join(path, n.filename),
            kind: kind,
            resolvedKind: kind == RemoteEntryKind.link ? null : kind,
            size: n.attr.size,
            modified: _time(n.attr.modifyTime),
            mode: n.attr.mode?.value,
          ));
          if (kind == RemoteEntryKind.link) links.add(entries.length - 1);
        }
        for (var i = 0; i < links.length; i += _linkBatch) {
          final batch = links.sublist(i, math.min(i + _linkBatch, links.length));
          await Future.wait([for (final at in batch) _resolveLink(s, entries, at)]);
        }
        return entries;
      }, onFailure: (s, e) => _notADirectoryIfFile(s, path, e));

  Future<Uint8List> read(String path, int offset, int length) {
    final from = math.max(0, offset);
    final n = length.clamp(0, remoteReadCap);
    if (n == 0) return Future.value(Uint8List(0));
    return _run(path, readTimeout, (s) => s.readBytes(path, from, n),
        onFailure: (s, e) => _notAFileIfDirectory(s, path, e));
  }

  /// `mkdir -p`, new folders readable by their owner only. A folder that is
  /// already there is left alone, whatever its mode.
  Future<void> makeDirs(String path) async {
    if (!RemotePath.isAbsolute(path)) {
      throw RemoteFileException(RemoteFileErrorKind.failed, 'Not an absolute path', path: path);
    }
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    await _run(path, metaTimeout, (s) async {
      // The common case is one round trip: the folder is there.
      var have = parts.length; // folders known to exist: parts[0..have)
      while (have > 0) {
        final dir = '/${parts.take(have).join('/')}';
        try {
          final attrs = await s.stat(dir);
          if (attrs.mode?.type != SftpFileType.directory) {
            throw RemoteFileException(RemoteFileErrorKind.notADirectory,
                '${RemotePath.basename(dir)} is not a folder',
                path: dir);
          }
          break;
        } on SftpStatusError catch (e) {
          if (e.code != 2) rethrow;
          have--;
        }
      }
      for (var i = have; i < parts.length; i++) {
        final dir = '/${parts.take(i + 1).join('/')}';
        try {
          await s.mkdir(dir);
        } on SftpStatusError catch (refused) {
          // Made by someone else meanwhile (or refused): the next stat tells.
          // When there is still nothing there, the refusal is the answer
          // ("permission denied"), not the stat's "no such file".
          final SftpFileAttrs attrs;
          try {
            attrs = await s.stat(dir);
          } on SftpStatusError {
            throw refused;
          }
          if (attrs.mode?.type != SftpFileType.directory) rethrow;
        }
      }
    });
  }

  Future<void> remove(String path) => _run(path, metaTimeout, (s) => s.remove(path));

  /// Starts copying [localPath] to [remotePath] now (see [_SftpUpload]).
  UploadJob upload(
    String localPath,
    String remotePath, {
    void Function(int sent, int total)? onProgress,
  }) => _SftpUpload(this, localPath, remotePath, onProgress).._start();

  /// A session to open an upload's file on: one fresh session after a dead
  /// channel, like [_run].
  Future<(SftpApi, SftpUploadFile)> _openForWrite(String path) async {
    for (var attempt = 0;; attempt++) {
      final SftpApi session;
      try {
        session = await (_session ??= open());
      } on Object {
        _session = null;
        rethrow;
      }
      _live = session;
      try {
        return (session, await session.openForWrite(path).timeout(metaTimeout));
      } on SftpAbortError {
        _forget(session);
        if (attempt == 0) continue;
        rethrow;
      } on TimeoutException {
        _forget(session);
        rethrow;
      }
    }
  }

  /// What an upload failure looks like to callers.
  Object _uploadError(Object e, StackTrace st, SftpApi? session, String path) {
    switch (e) {
      case RemoteFileException():
        return e;
      case SftpAbortError():
        if (session != null) _forget(session);
        return RemoteFileException(RemoteFileErrorKind.network, 'The connection was lost',
            path: path);
      case TimeoutException():
        if (session != null) _forget(session);
        return RemoteFileException(RemoteFileErrorKind.network, 'The machine did not answer in time',
            path: path);
      case SftpStatusError():
        if ((e.code == 6 || e.code == 7) && session != null) _forget(session);
        return _mapStatus(e, path);
      case SftpError():
        return RemoteFileException(RemoteFileErrorKind.failed, e.message, path: path);
      case FileSystemException():
        final code = e.osError?.errorCode;
        return RemoteFileException(
          code == 2
              ? RemoteFileErrorKind.notFound
              : code == 13
                  ? RemoteFileErrorKind.permission
                  : RemoteFileErrorKind.failed,
          code == 2 ? 'The file is gone' : 'Cannot read the file: ${e.message}',
        );
      default:
        return e;
    }
  }

  /// Fills in what link [at] points to; a broken link stays unresolved.
  Future<void> _resolveLink(SftpApi s, List<RemoteEntry> entries, int at) async {
    final e = entries[at];
    String? target;
    try {
      target = await s.readlink(e.path);
    } on Object {
      // Not fatal: the row just will not show where the link goes.
    }
    try {
      final attrs = await s.stat(e.path);
      final kind = _kindOf(attrs.mode?.type);
      entries[at] = RemoteEntry(
        name: e.name,
        path: e.path,
        kind: RemoteEntryKind.link,
        resolvedKind: kind == RemoteEntryKind.link ? null : kind,
        size: attrs.size ?? e.size,
        modified: _time(attrs.modifyTime) ?? e.modified,
        mode: e.mode,
        linkTarget: target,
      );
    } on SftpStatusError {
      entries[at] = RemoteEntry(
        name: e.name,
        path: e.path,
        kind: RemoteEntryKind.link,
        size: e.size,
        modified: e.modified,
        mode: e.mode,
        linkTarget: target,
      );
    }
  }

  RemoteStat _statOf(String path, SftpFileAttrs attrs) {
    final kind = _kindOf(attrs.mode?.type);
    return RemoteStat(
      path: path,
      // `stat` follows links, so a link here means the server did not; treat
      // what it could not classify as a plain file only when it has no type.
      kind: kind == RemoteEntryKind.link ? RemoteEntryKind.other : kind,
      size: attrs.size,
      modified: _time(attrs.modifyTime),
      mode: attrs.mode?.value,
    );
  }

  static RemoteEntryKind _kindOf(SftpFileType? type) => switch (type) {
        SftpFileType.directory => RemoteEntryKind.dir,
        SftpFileType.symbolicLink => RemoteEntryKind.link,
        SftpFileType.regularFile || SftpFileType.unknown || null => RemoteEntryKind.file,
        _ => RemoteEntryKind.other,
      };

  static DateTime? _time(int? seconds) =>
      seconds == null ? null : DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);

  /// opendir answers "no such file" (or a bare failure) for a regular file.
  Future<RemoteFileException?> _notADirectoryIfFile(SftpApi s, String path, Object e) async {
    if (e is! SftpStatusError || (e.code != 2 && e.code != 4)) return null;
    try {
      final attrs = await s.stat(path);
      if (_kindOf(attrs.mode?.type) != RemoteEntryKind.dir) {
        return RemoteFileException(RemoteFileErrorKind.notADirectory,
            '${RemotePath.basename(path)} is not a folder', path: path);
      }
    } on Object {
      // the original error stands
    }
    return null;
  }

  /// A read of a directory comes back as a bare failure.
  Future<RemoteFileException?> _notAFileIfDirectory(SftpApi s, String path, Object e) async {
    if (e is! SftpStatusError || e.code != 4) return null;
    try {
      final attrs = await s.stat(path);
      if (_kindOf(attrs.mode?.type) != RemoteEntryKind.file) {
        return RemoteFileException(RemoteFileErrorKind.notAFile,
            '${RemotePath.basename(path)} is not a regular file', path: path);
      }
    } on Object {
      // the original error stands
    }
    return null;
  }

  Future<T> _run<T>(
    String path,
    Duration timeout,
    Future<T> Function(SftpApi s) op, {
    Future<RemoteFileException?> Function(SftpApi s, Object error)? onFailure,
  }) async {
    for (var attempt = 0;; attempt++) {
      final SftpApi session;
      try {
        session = await (_session ??= open());
      } on Object {
        _session = null;
        rethrow;
      }
      _live = session;
      _browsing++;
      try {
        return await op(session).timeout(timeout);
      } on RemoteFileException {
        rethrow;
      } on SftpAbortError {
        _forget(session);
        // The channel died under us (the phone slept, the link flapped): one
        // fresh session, then give up.
        if (attempt == 0) continue;
        throw RemoteFileException(RemoteFileErrorKind.network, 'The connection was lost', path: path);
      } on TimeoutException {
        _forget(session);
        throw RemoteFileException(RemoteFileErrorKind.network, 'The machine did not answer in time',
            path: path);
      } on SftpStatusError catch (e) {
        if (e.code == 6 || e.code == 7) _forget(session);
        final refined = await onFailure?.call(session, e);
        throw refined ?? _mapStatus(e, path);
      } on SftpError catch (e) {
        throw RemoteFileException(RemoteFileErrorKind.failed, e.message, path: path);
      } finally {
        _browsing--;
      }
    }
  }

  void _forget(SftpApi session) {
    if (identical(_live, session)) {
      _live = null;
      _session = null;
    }
    unawaited(session.close().then((_) {}, onError: (Object _) {}));
  }

  static RemoteFileException _mapStatus(SftpStatusError e, String path) => switch (e.code) {
        2 => RemoteFileException(RemoteFileErrorKind.notFound, 'No such file or directory', path: path),
        3 => RemoteFileException(RemoteFileErrorKind.permission, 'Permission denied', path: path),
        8 => RemoteFileException(RemoteFileErrorKind.unsupported,
            'The server does not support this operation',
            path: path),
        6 || 7 => RemoteFileException(RemoteFileErrorKind.network, 'The connection was lost', path: path),
        _ => RemoteFileException(
            RemoteFileErrorKind.failed,
            e.message.isEmpty ? 'The server could not complete the request' : e.message,
            path: path,
          ),
      };
}


/// How many WRITE requests an upload keeps unanswered. Every 100 ms it takes
/// the rate the host acknowledged and the shortest answer time seen (the
/// round trip with nothing queued ahead), multiplies them into the bandwidth
/// delay product (the requests it takes to keep the link busy) and keeps 1.5x
/// that plus two: the link is full, and the queue a browse request waits
/// behind stays about half a round trip long, not the whole [max]. It starts
/// at [start], grows 1.5x a period while the link is not yet full (the rate
/// rises with the window) and never passes [max]. [start] >= [max] is a fixed
/// window.
class _Window {
  _Window(int start, this.max, this.block)
      : size = math.min(start, max),
        _fixed = start >= max;

  final int max;
  final int block;
  final bool _fixed;
  int size;
  final _clock = Stopwatch()..start();
  int _minRttUs = 1 << 40;
  int _bytes = 0;
  int _periodStartUs = 0;

  int get nowUs => _clock.elapsedMicroseconds;

  /// A request of [bytes] was answered [latencyUs] after it was sent.
  void acked(int bytes, int latencyUs) {
    if (_fixed) return;
    if (latencyUs < _minRttUs) _minRttUs = latencyUs;
    _bytes += bytes;
    final now = nowUs;
    if (now - _periodStartUs < 100000) return;
    final rate = _bytes / (now - _periodStartUs); // bytes per microsecond
    final target = (1.5 * rate * _minRttUs / block).ceil() + 2;
    size = target.clamp(math.min(4, max), max);
    _bytes = 0;
    _periodStartUs = now;
  }
}

/// A settled future: neither a value nor an error escapes unobserved.
Future<({T? value, Object? error, StackTrace? trace})> _settle<T>(Future<T> f) => f.then(
      (v) => (value: v as T?, error: null, trace: null),
      onError: (Object e, StackTrace st) => (value: null, error: e, trace: st),
    );

/// One file going to the host on [SftpFiles]' channel.
///
/// The disk is read in [SftpFiles.uploadBlock] pieces into a small ring of
/// buffers; each piece is one WRITE request sent at once, up to the window of
/// unanswered requests ([SftpFiles._uploadWindow]), and a buffer is refilled
/// only after its request was answered (the request is encoded long before
/// that). So nothing is allocated per piece and the link never waits for a
/// round trip. The remote file is opened while the local one is measured.
/// A failure or [cancel] stops sending, completes [done] at once and closes and
/// removes the half-written file in the background; nothing is resumed.
class _SftpUpload implements UploadJob {
  _SftpUpload(this._files, this._localPath, this._remotePath, this._onProgress);

  final SftpFiles _files;
  final String _localPath;
  final String _remotePath;
  final void Function(int sent, int total)? _onProgress;

  final _done = Completer<void>();
  bool _cancelled = false;
  Completer<void>? _wake;
  SftpApi? _session;

  @override
  Future<void> get done => _done.future;

  @override
  void cancel() {
    if (_done.isCompleted) return;
    _cancelled = true;
    _done.completeError(UploadCancelled(path: _remotePath));
    _wake?.complete();
  }

  void _start() {
    // Observed by the caller or not, a failure never escapes as unhandled.
    _done.future.then((_) {}, onError: (Object _) {});
    _files._uploads++;
    unawaited(_run());
  }

  void _progress(int sent, int total) {
    try {
      _onProgress?.call(sent, total);
    } on Object {
      // A listener's bug must not end the upload.
    }
  }

  Future<void> _run() async {
    RandomAccessFile? local;
    SftpUploadFile? remote;
    var failed = false;
    try {
      final localF = _settle(File(_localPath).open());
      final remoteF = _settle(_files._openForWrite(_remotePath));
      final l = await localF;
      final r = await remoteF;
      local = l.value;
      if (r.value != null) {
        _session = r.value!.$1;
        remote = r.value!.$2;
      }
      final firstError = l.error ?? r.error;
      if (firstError != null) {
        Error.throwWithStackTrace(firstError, l.error != null ? l.trace! : r.trace!);
      }
      final total = await local!.length();
      if (total > uploadMaxBytes) {
        throw RemoteFileException(
            RemoteFileErrorKind.tooLarge, 'The file is bigger than 200 MB', path: _remotePath);
      }
      await _pump(local, remote!, total);
      if (_cancelled) return;
      await remote.close().timeout(_files.stallTimeout);
      remote = null;
      _progress(total, total);
      if (!_done.isCompleted) _done.complete();
    } on Object catch (e, st) {
      failed = true;
      if (!_done.isCompleted) {
        _done.completeError(_files._uploadError(e, st, _session, _remotePath));
      }
    } finally {
      _files._uploads--;
      if (failed || _cancelled) {
        unawaited(_cleanup(local, remote));
      } else {
        unawaited(local?.close().then((_) {}, onError: (Object _) {}));
      }
    }
  }

  /// Sends the file; returns early (after an error is stored in [_done]) or
  /// when cancelled.
  Future<void> _pump(RandomAccessFile local, SftpUploadFile remote, int total) async {
    final block = math.min(_files.uploadBlock, math.max(total, 1));
    final slots = <Uint8List>[];
    final free = Queue<Uint8List>();
    var offset = 0;
    var acked = 0;
    var inflight = 0;
    Object? error;
    StackTrace? errorTrace;
    final clock = Stopwatch()..start();
    var lastReport = -1;
    final window = _Window(_files.uploadStartWindow, _files.uploadWindow, block);

    void wake() {
      final w = _wake;
      _wake = null;
      if (w != null && !w.isCompleted) w.complete();
    }

    Future<void> nextAnswer() {
      final w = _wake ??= Completer<void>();
      return w.future.timeout(_files.stallTimeout);
    }

    _progress(0, total);
    while (offset < total || inflight > 0) {
      if (_cancelled) return;
      if (error != null) {
        Error.throwWithStackTrace(error!, errorTrace!);
      }
      if (offset >= total || inflight >= math.min(window.size, _files._windowCap)) {
        await nextAnswer();
        continue;
      }
      Uint8List buf;
      if (free.isNotEmpty) {
        buf = free.removeFirst();
      } else {
        buf = Uint8List(block);
        slots.add(buf);
      }
      final want = math.min(block, total - offset);
      var got = 0;
      while (got < want) {
        final n = await local.readInto(buf, got, want);
        if (n == 0) break;
        got += n;
      }
      if (_cancelled) return;
      if (got < want) {
        throw RemoteFileException(RemoteFileErrorKind.failed, 'The file changed while sending',
            path: _remotePath);
      }
      final at = offset;
      offset += got;
      inflight++;
      final sentAt = window.nowUs;
      remote.write(at, Uint8List.sublistView(buf, 0, got)).then((_) {
        acked += got;
        window.acked(got, window.nowUs - sentAt);
        if (_cancelled || error != null) return;
        final ms = clock.elapsedMilliseconds;
        if (lastReport < 0 || ms - lastReport >= _files.progressInterval.inMilliseconds) {
          lastReport = ms;
          _progress(acked, total);
        }
      }, onError: (Object e, StackTrace st) {
        error ??= e;
        errorTrace ??= st;
      }).whenComplete(() {
        inflight--;
        free.add(buf);
        wake();
      });
    }
    // A write that failed while it was the last one in flight ended the loop
    // (nothing left in flight) before the check at its top saw the error:
    // without this the upload reported success with a hole in the file.
    if (error != null) Error.throwWithStackTrace(error!, errorTrace!);
  }

  /// Closes what is open and removes the half-written remote file. Best
  /// effort: a dead link cannot do it (the 14-day inbox cleanup collects such
  /// leftovers).
  Future<void> _cleanup(RandomAccessFile? local, SftpUploadFile? remote) async {
    try {
      await local?.close();
    } on Object {
      // nothing to do
    }
    try {
      await remote?.close().timeout(const Duration(seconds: 10));
    } on Object {
      // the link is gone; removing will say so
    }
    if (remote == null && _session == null) return; // never created
    try {
      await _files.remove(_remotePath);
    } on Object {
      // best effort
    }
  }
}
