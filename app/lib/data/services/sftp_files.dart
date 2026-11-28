import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../models/remote_file.dart';
import '../models/remote_search.dart';
import 'file_walk_search.dart';
import 'remote_file_backend.dart';

/// The slice of dartssh2's [SftpClient] that file browsing needs, so the
/// mapping in [SftpFiles] can be tested without a server. Read-only: the
/// phone writes to a host only through the agent helper's inbox.
abstract interface class SftpApi {
  Future<SftpFileAttrs> stat(String path, {bool followLink = true});
  Future<List<SftpName>> listdir(String path);
  Future<String> absolute(String path);
  Future<String> readlink(String path);

  /// Up to [length] bytes of the file at [offset]; fewer at end of file.
  Future<Uint8List> readBytes(String path, int offset, int length);

  Future<void> close();
}

/// [SftpApi] over a live [SftpClient].
class DartSftp implements SftpApi {
  DartSftp(this._client);

  final SftpClient _client;

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) => _client.stat(path, followLink: followLink);

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
  Future<void> close() => _client.close();
}

/// File access over one lazily opened, cached SFTP session: the fallback for a
/// machine that has no agent helper (`HostFiles` is used when it has one).
///
/// [open] makes a fresh session (SshTransport hands it the authenticated SSH
/// client). A session whose channel died is dropped and reopened once, so a
/// phone that slept and reconnected does not need the screen to be reopened.
/// Everything is SFTP binary packets: there is no remote shell and so nothing
/// to quote.
class SftpFiles implements RemoteFileBackend {
  SftpFiles({
    required this.open,
    this.metaTimeout = const Duration(seconds: 20),
    this.readTimeout = const Duration(seconds: 60),
    this.watchInterval = const Duration(seconds: 15),
  });

  /// Opens a session. Throws [RemoteFileException] (unsupported when the host
  /// has no SFTP) or lets a `HerdrTransportException` through when the SSH
  /// connection itself is down.
  final Future<SftpApi> Function() open;
  final Duration metaTimeout;
  final Duration readTimeout;

  /// How often [watch] asks the machine again: SFTP has no change events, and
  /// every ask is a radio wake-up.
  final Duration watchInterval;

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

  @override
  Future<RemoteStat> stat(String path) => _run(path, metaTimeout, (s) async {
    final attrs = await s.stat(path);
    return _statOf(path, attrs);
  });

  @override
  Future<String> realPath(String path) => _run(path, metaTimeout, (s) => s.absolute(path));

  @override
  Future<List<RemoteEntry>> list(String path) => _run(path, metaTimeout, (s) async {
    final names = await s.listdir(path);
    final entries = <RemoteEntry>[];
    final links = <int>[];
    for (final n in names) {
      if (n.filename == '.' || n.filename == '..') continue;
      final kind = _kindOf(n.attr.mode?.type);
      entries.add(
        RemoteEntry(
          name: n.filename,
          path: RemotePath.join(path, n.filename),
          kind: kind,
          resolvedKind: kind == RemoteEntryKind.link ? null : kind,
          size: n.attr.size,
          modified: _time(n.attr.modifyTime),
          mode: n.attr.mode?.value,
        ),
      );
      if (kind == RemoteEntryKind.link) links.add(entries.length - 1);
    }
    for (var i = 0; i < links.length; i += _linkBatch) {
      final batch = links.sublist(i, math.min(i + _linkBatch, links.length));
      await Future.wait([for (final at in batch) _resolveLink(s, entries, at)]);
    }
    return entries;
  }, onFailure: (s, e) => _notADirectoryIfFile(s, path, e));

  @override
  Future<Uint8List> read(String path, int offset, int length, {RemoteStat? ifMatch}) {
    final from = math.max(0, offset);
    final n = length.clamp(0, remoteReadCap);
    if (n == 0) return Future.value(Uint8List(0));
    return _run(
      path,
      readTimeout,
      (s) => s.readBytes(path, from, n),
      onFailure: (s, e) => _notAFileIfDirectory(s, path, e),
    );
  }

  /// SFTP reads at an offset but cannot say "only if it is still this file":
  /// [read] ignores `ifMatch`.
  @override
  bool get checksIdentity => false;

  /// SFTP cannot make a thumbnail where the file is: the caller reads the
  /// file itself when it is small enough, and shows a glyph when it is not.
  @override
  Future<Uint8List?> thumbnail(String path, {int maxPx = 256, RemoteStat? expect, Future<void>? cancelled}) async =>
      null;

  /// A bounded walk over [list] (see [walkSearch]): SFTP has no search, and
  /// every folder is a round trip.
  @override
  Stream<FileSearchEvent> search(FileSearchSpec spec) => walkSearch(list, spec);

  /// Polls [stat] every [watchInterval] while listened to and tells when what
  /// it finds differs from the last answer. A path that is not there is null;
  /// any other failure ends the stream with it.
  @override
  Stream<RemoteStat?> watch(String path) {
    Timer? timer;
    var busy = false;
    var first = true;
    RemoteStat? last;
    late final StreamController<RemoteStat?> out;
    Future<void> look() async {
      if (busy || out.isClosed) return;
      busy = true;
      try {
        RemoteStat? now;
        try {
          now = await stat(path);
        } on RemoteFileException catch (e) {
          if (e.kind != RemoteFileErrorKind.notFound) rethrow;
        }
        if (out.isClosed) return;
        if (first || now != last) out.add(now);
        first = false;
        last = now;
      } on Object catch (e) {
        if (out.isClosed) return;
        out.addError(e);
        timer?.cancel();
        await out.close();
      } finally {
        busy = false;
      }
    }

    out = StreamController<RemoteStat?>(
      onListen: () {
        unawaited(look());
        timer = Timer.periodic(watchInterval, (_) => unawaited(look()));
      },
      onCancel: () => timer?.cancel(),
    );
    return out.stream;
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
        return RemoteFileException(
          RemoteFileErrorKind.notADirectory,
          '${RemotePath.basename(path)} isn’t a folder',
          path: path,
        );
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
        return RemoteFileException(
          RemoteFileErrorKind.notAFile,
          '${RemotePath.basename(path)} isn’t a regular file',
          path: path,
        );
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
    for (var attempt = 0; ; attempt++) {
      final SftpApi session;
      try {
        session = await (_session ??= open());
      } on Object {
        _session = null;
        rethrow;
      }
      _live = session;
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
        throw RemoteFileException(RemoteFileErrorKind.network, 'The machine didn’t answer in time', path: path);
      } on SftpStatusError catch (e) {
        if (e.code == 6 || e.code == 7) _forget(session);
        final refined = await onFailure?.call(session, e);
        throw refined ?? _mapStatus(e, path);
      } on SftpError catch (e) {
        throw RemoteFileException(RemoteFileErrorKind.failed, e.message, path: path);
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
    8 => RemoteFileException(RemoteFileErrorKind.unsupported, 'The server doesn’t support this operation', path: path),
    6 || 7 => RemoteFileException(RemoteFileErrorKind.network, 'The connection was lost', path: path),
    _ => RemoteFileException(
      RemoteFileErrorKind.failed,
      e.message.isEmpty ? 'The server couldn’t complete the request' : e.message,
      path: path,
    ),
  };
}
