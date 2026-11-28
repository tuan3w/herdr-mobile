import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../models/remote_file.dart';
import '../models/remote_search.dart';
import '../services/file_walk_search.dart';
import '../services/herdr_transport.dart' show HerdrTransportException;
import '../services/remote_file_backend.dart';
import 'host_link.dart';

/// A machine's files through the agent helper's read-only `fs` service, over the
/// machine's one [HostLink]: one request and one answer per `stat`, a listing
/// in one stream, a read with the file's identity checked, and a real watch
/// (the host looks, the phone only hears changes).
///
/// A host failure becomes what screens already handle: `not_found`,
/// `permission`, `not_a_file`, `not_a_directory` and `too_large` map one to
/// one onto [RemoteFileErrorKind]; `changed` is [RemoteFileChanged]; a dropped
/// link and whatever else can pass by retrying is a `HerdrTransportException`
/// (a connection problem, which `RemoteFiles` shows as `network`).
class HostFiles implements RemoteFileBackend {
  HostFiles(
    this.link, {
    this.callTimeout = const Duration(seconds: 20),
    this.readTimeout = const Duration(seconds: 60),
    this.watchInterval = const Duration(seconds: 2),
  });

  final HostLink link;
  final Duration callTimeout;
  final Duration readTimeout;

  /// How often the host looks at a watched file.
  final Duration watchInterval;

  /// Links resolved at once while listing a folder: each is two short requests
  /// and the link has 64 streams to share with everything else.
  static const _linkBatch = 12;

  /// The path as the host takes it: absolute or `~`-led. SFTP started in the
  /// login folder, so `.`, `` and a relative path mean "from home" here too.
  static String wirePath(String path) {
    if (path.isEmpty || path == '.') return '~';
    if (path.startsWith('/') || path == '~' || path.startsWith('~/')) return path;
    return '~/${path.startsWith('./') ? path.substring(2) : path}';
  }

  @override
  Future<RemoteStat> stat(String path) async {
    final m = await _call('stat', path, {'path': wirePath(path)}) as Map;
    return _statOf(path, m);
  }

  @override
  Future<String> realPath(String path) async {
    final m = await _call('real_path', path, {'path': wirePath(path)}) as Map;
    return m['path']! as String;
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final s = _open('list', path, {'path': wirePath(path)});
    final entries = <RemoteEntry>[];
    final links = <int>[];
    // The failure arrives on `done` too; the listener only has to exist so an
    // error event is not unhandled.
    final sub = s.messages.listen((m) {
      for (final e in ((m! as Map)['entries']! as List).cast<Map<Object?, Object?>>()) {
        final kind = RemoteEntryKind.parse(e['kind'] as String?);
        entries.add(
          RemoteEntry(
            name: e['name']! as String,
            path: RemotePath.join(path, e['name']! as String),
            kind: kind,
            resolvedKind: kind == RemoteEntryKind.link ? null : kind,
            size: e['size'] as int?,
            modified: _time(e['mtime_ms'] as int?),
            mode: e['mode'] as int?,
          ),
        );
        if (kind == RemoteEntryKind.link) links.add(entries.length - 1);
      }
    }, onError: (Object _) {});
    final HostEnd end;
    try {
      end = await s.done.timeout(callTimeout, onTimeout: () => _timedOut(s, 'list', path));
    } finally {
      await sub.cancel();
    }
    final error = end.error;
    if (error != null) throw failure(error, path);
    for (var i = 0; i < links.length; i += _linkBatch) {
      final batch = links.sublist(i, math.min(i + _linkBatch, links.length));
      await Future.wait([for (final at in batch) _resolveLink(entries, at)]);
    }
    return entries;
  }

  /// Fills in what link [at] points to and where; a broken link stays
  /// unresolved. Only a refusal to answer is "broken": a blip leaves the row as
  /// it was listed.
  Future<void> _resolveLink(List<RemoteEntry> entries, int at) async {
    final e = entries[at];
    RemoteStat? target;
    String? where;
    try {
      target = await stat(e.path);
      where = await realPath(e.path);
    } on Object {
      // not fatal: the row just shows what it knows
    }
    final kind = target?.kind;
    entries[at] = RemoteEntry(
      name: e.name,
      path: e.path,
      kind: RemoteEntryKind.link,
      resolvedKind: kind,
      size: target?.size ?? e.size,
      modified: target?.modified ?? e.modified,
      mode: e.mode,
      linkTarget: where,
    );
  }

  @override
  Future<Uint8List> read(String path, int offset, int length, {RemoteStat? ifMatch}) async {
    final n = length.clamp(0, remoteReadCap);
    if (n == 0) return Uint8List(0);
    final size = ifMatch?.size;
    final mtime = ifMatch?.modified?.millisecondsSinceEpoch;
    final s = _open('read', path, {
      'path': wirePath(path),
      'offset': math.max(0, offset),
      'length': n,
      if (size != null && mtime != null) 'if_match': {'size': size, 'mtime_ms': mtime},
    });
    final sub = s.messages.listen((_) {}, onError: (Object _) {});
    final out = BytesBuilder(copy: false);
    try {
      return await (() async {
        for (var c = await s.read(); c != null; c = await s.read()) {
          out.add(c);
        }
        final error = (await s.done).error;
        if (error != null) throw failure(error, path);
        return out.takeBytes();
      })().timeout(readTimeout, onTimeout: () => _timedOut(s, 'read', path));
    } finally {
      await sub.cancel();
    }
  }

  @override
  bool get checksIdentity => true;

  /// `fs.thumb`: the host decodes, shrinks and encodes; the phone receives the
  /// JPEG (a few tens of KB) instead of the file. An older helper without the
  /// method, a picture the host cannot read, a file that changed or is too
  /// large, a lost link: all the same answer, null.
  @override
  Future<Uint8List?> thumbnail(String path, {int maxPx = 256, RemoteStat? expect, Future<void>? cancelled}) async {
    final size = expect?.size;
    final mtime = expect?.modified?.millisecondsSinceEpoch;
    final HostStream s;
    try {
      s = link.open('fs', 'thumb', {
        'path': wirePath(path),
        'max_px': maxPx.clamp(32, 1024),
        if (size != null && mtime != null) 'if_match': {'size': size, 'mtime_ms': mtime},
      });
    } on HostException {
      return null;
    }
    var stopped = false;
    if (cancelled != null) {
      unawaited(
        cancelled.then((_) {
          stopped = true;
          s.reset('cancelled', 'the thumbnail is not needed any more');
        }, onError: (Object _) {}),
      );
    }
    final sub = s.messages.listen((_) {}, onError: (Object _) {});
    final out = BytesBuilder(copy: false);
    try {
      return await (() async {
        for (var c = await s.read(); c != null; c = await s.read()) {
          out.add(c);
        }
        final end = await s.done;
        if (end.error != null || stopped) return null;
        final bytes = out.takeBytes();
        return bytes.isEmpty ? null : bytes;
      })().timeout(
        readTimeout,
        onTimeout: () {
          s.reset('timeout', 'fs.thumb did not answer in time');
          return null;
        },
      );
    } on HostException {
      return null;
    } finally {
      await sub.cancel();
    }
  }

  /// `fs.search`: the host walks and sends matches as it finds them. An older
  /// helper that does not know the method is walked from here instead.
  @override
  Stream<FileSearchEvent> search(FileSearchSpec spec) {
    HostStream? stream;
    StreamSubscription<Object?>? sub;
    StreamSubscription<FileSearchEvent>? walk;
    var cancelled = false;
    // One batch at a time, in order: links are looked at (a second request each)
    // before the next batch is sent on.
    var chain = Future<void>.value();
    late final StreamController<FileSearchEvent> out;

    Future<void> fail(Object e, StackTrace st) async {
      if (cancelled || out.isClosed) return;
      out.addError(e is HostException ? failure(e, spec.root) : e, st);
      await out.close();
    }

    Future<void> batch(Object? message) async {
      final entries = <RemoteEntry>[];
      final links = <int>[];
      for (final e in ((message! as Map)['entries']! as List).cast<Map<Object?, Object?>>()) {
        final kind = RemoteEntryKind.parse(e['kind'] as String?);
        entries.add(
          RemoteEntry(
            name: e['name']! as String,
            path: e['path']! as String,
            kind: kind,
            resolvedKind: kind == RemoteEntryKind.link ? null : kind,
            size: e['size'] as int?,
            modified: _time(e['mtime_ms'] as int?),
          ),
        );
        if (kind == RemoteEntryKind.link) links.add(entries.length - 1);
      }
      for (var i = 0; i < links.length && !cancelled; i += _linkBatch) {
        final part = links.sublist(i, math.min(i + _linkBatch, links.length));
        await Future.wait([for (final at in part) _resolveLink(entries, at)]);
      }
      if (!cancelled && !out.isClosed && entries.isNotEmpty) out.add(FileSearchBatch(entries));
    }

    Future<void> finish(HostEnd end) async {
      if (cancelled || out.isClosed) return;
      final error = end.error;
      if (error == null) {
        out.add(
          FileSearchDone(
            scanned: end.result['scanned'] as int? ?? 0,
            truncated: end.result['truncated'] == true,
            skippedDirs: end.result['skipped_dirs'] as int? ?? 0,
          ),
        );
        await out.close();
      } else if (error.code == 'unknown_method' || error.code == 'unknown_service') {
        walk = walkSearch(list, spec).listen(out.add, onError: out.addError, onDone: out.close);
      } else {
        await fail(error, StackTrace.current);
      }
    }

    out = StreamController<FileSearchEvent>(
      onListen: () {
        final HostStream s;
        try {
          s = stream = link.open('fs', 'search', {
            'root': wirePath(spec.root),
            if (spec.query.trim().isNotEmpty) 'query': spec.query.trim(),
            'kind': spec.kind.name,
            if (spec.modifiedWithin != null) 'modified_within_s': spec.modifiedWithin!.inSeconds,
            'max_results': spec.maxResults,
            'max_depth': spec.maxDepth,
            'hidden': spec.hidden,
            'ignore': spec.ignore,
          });
        } on Object catch (e, st) {
          unawaited(fail(e, st));
          return;
        }
        sub = s.messages.listen(
          (m) => chain = chain.then((_) => batch(m)).catchError(fail),
          // The failure arrives on `done` too.
          onError: (Object _) {},
        );
        unawaited(s.done.then((end) => chain = chain.then((_) => finish(end)).catchError(fail)));
      },
      onCancel: () async {
        cancelled = true;
        await sub?.cancel();
        await walk?.cancel();
        stream?.reset();
      },
    );
    return out.stream;
  }

  @override
  Stream<RemoteStat?> watch(String path) {
    HostStream? stream;
    StreamSubscription<Object?>? sub;
    var cancelled = false;
    // One event at a time, in order: what the host saw changing is looked at
    // again (the watch only knows size and time) before the next is handled.
    var chain = Future<void>.value();
    late final StreamController<RemoteStat?> out;
    Future<void> changed() async {
      RemoteStat? now;
      try {
        now = await stat(path);
      } on RemoteFileException catch (e) {
        if (e.kind != RemoteFileErrorKind.notFound) rethrow;
      }
      if (!cancelled && !out.isClosed) out.add(now);
    }

    Future<void> fail(Object e, StackTrace st) async {
      if (cancelled || out.isClosed) return;
      out.addError(e is HostException ? failure(e, path) : e, st);
      await out.close();
    }

    out = StreamController<RemoteStat?>(
      onListen: () {
        final HostStream s;
        try {
          s = stream = link.open('fs', 'watch', {
            'paths': [wirePath(path)],
            'interval_ms': watchInterval.inMilliseconds,
          });
        } on Object catch (e, st) {
          unawaited(fail(e, st));
          return;
        }
        sub = s.messages.listen(
          (_) => chain = chain.then((_) => changed()).catchError(fail),
          onError: fail,
          onDone: () => chain = chain.whenComplete(() async {
            if (!cancelled && !out.isClosed) await out.close();
          }),
        );
      },
      onCancel: () async {
        cancelled = true;
        await sub?.cancel();
        stream?.reset();
      },
    );
    return out.stream;
  }

  Future<Object?> _call(String method, String path, Map<String, Object?> args) async {
    try {
      return await link.call('fs', method, args, callTimeout);
    } on HostException catch (e) {
      throw failure(e, path);
    }
  }

  /// Opens `fs.[method]`; a link that is already closed is a connection
  /// problem like any other.
  HostStream _open(String method, String path, Map<String, Object?> args) {
    try {
      return link.open('fs', method, args);
    } on HostException catch (e) {
      throw failure(e, path);
    }
  }

  Never _timedOut(HostStream s, String method, String path) {
    s.reset('timeout', 'fs.$method did not answer in time');
    throw const HerdrTransportException('The machine didn’t answer in time');
  }

  RemoteStat _statOf(String path, Map<Object?, Object?> m) {
    final kind = RemoteEntryKind.parse(m['kind'] as String?);
    return RemoteStat(
      path: path,
      kind: kind == RemoteEntryKind.link ? RemoteEntryKind.other : kind,
      size: m['size'] as int?,
      modified: _time(m['mtime_ms'] as int?),
      mode: m['mode'] as int?,
    );
  }

  static DateTime? _time(int? ms) => ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

  /// [e] as the exception a caller of a file backend handles. The host words
  /// its errors for a person, with the path as it was sent.
  static Object failure(HostException e, String? path) {
    final said = e.message.isEmpty ? null : e.message;
    switch (e.code) {
      case 'not_found':
        return RemoteFileException(RemoteFileErrorKind.notFound, said ?? 'No such file or directory', path: path);
      case 'permission':
        return RemoteFileException(RemoteFileErrorKind.permission, said ?? 'Permission denied', path: path);
      case 'not_a_file':
        return RemoteFileException(RemoteFileErrorKind.notAFile, said ?? 'Not a regular file', path: path);
      case 'not_a_directory':
        return RemoteFileException(RemoteFileErrorKind.notADirectory, said ?? 'Not a folder', path: path);
      case 'too_large':
        return RemoteFileException(RemoteFileErrorKind.tooLarge, said ?? 'The file is too big', path: path);
      case 'changed':
        return RemoteFileChanged(said ?? 'The file changed', path: path);
      case 'unavailable':
        return HerdrTransportException(said ?? 'The agent helper is not available on this machine.');
      default:
        // The link dropped, a request timed out, the host is busy: trying again
        // can work. Anything else is the host refusing or failing.
        if (e is HostLinkLost || e.retryable) return HerdrTransportException(said ?? 'The connection was lost');
        return RemoteFileException(
          RemoteFileErrorKind.failed,
          said ?? 'The machine couldn’t complete the request',
          path: path,
        );
    }
  }
}
