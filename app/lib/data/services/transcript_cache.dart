import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../acp/transcript_log.dart';

/// Runs `job(argument)` off the UI thread. [job] is a top-level function and
/// [argument] plain data (strings, numbers, lists, records of them): both are
/// copied to the worker isolate, which is why no job is a closure over the
/// cache. A test passes [inlineOffload] to run it in place.
typedef Offload = Future<R> Function<A, R>(R Function(A argument) job, A argument);

Future<R> isolateOffload<A, R>(R Function(A argument) job, A argument) => Isolate.run<R>(() => job(argument));

Future<R> inlineOffload<A, R>(R Function(A argument) job, A argument) async => job(argument);

/// The last known transcript of each agent session, so a session opens on its
/// conversation at once (after a restart too) while the keeper is still being
/// reached. What it keeps is the window of `session/update` lines the client
/// received, which are folded again through the reducer that folds a replay
/// ([replayCachedTranscript]); the keeper's replay then replaces it.
///
/// Keys are session keys (`<machineId>/<keeperId>`).
abstract interface class TranscriptCache {
  /// The stored transcript of [key], or null when there is none or it cannot be
  /// trusted (damaged, from another version, too large): such a file is
  /// deleted. Reading marks the entry as the most recently opened.
  Future<CachedTranscript?> read(String key);

  /// Asks for [snapshot] to be written for [key]: after the cache's debounce,
  /// or at once with [now]. Calls that come within the wait are one write, of
  /// the newest [snapshot].
  void save(String key, TranscriptSnapshot snapshot, {bool now = false});

  /// Forgets [key] (a pending write too).
  Future<void> delete(String key);

  /// Forgets every session of machine [machineId].
  Future<void> deleteMachine(String machineId);

  /// Forgets the sessions of [machineId] whose keeper is not in [keeperIds]:
  /// the host no longer has them.
  Future<void> retain(String machineId, Set<String> keeperIds);
}

/// [TranscriptCache] in files under one private directory (the app's own
/// storage: a transcript may hold secrets, so never preferences, never shared
/// storage).
///
/// One file per session, `<machine>~<keeper>.tr`, versioned: line one is a JSON
/// header (version, key, session id, time, whether lines were left out, how
/// many lines follow, the `session/load` answer) and the lines follow
/// verbatim. A write goes to `<file>.tmp` and is renamed over the file, so a
/// reader sees the old file or the new one. Writes run in a worker isolate,
/// are debounced (a burst is one write) and happen when a turn ends, when the
/// screen lets go and when the app goes to the background, never per chunk.
/// Each file is bounded by [maxSessionBytes], header included (older lines go
/// first; a larger file is not one this cache wrote and is not read) and the
/// whole directory by [maxTotalBytes] (the entry opened longest ago goes
/// first).
class FileTranscriptCache implements TranscriptCache {
  FileTranscriptCache(
    this._directory, {
    this.maxSessionBytes = 1 << 20,
    this.maxTotalBytes = 5 << 20,
    this.debounce = const Duration(seconds: 3),
    this.offload = isolateOffload,
  });

  /// The cache in the app's private cache directory (`transcripts/` under it:
  /// no other app reads it, and on Android it is outside the files that Auto
  /// Backup uploads, which a transcript with secrets must not be in; the OS may
  /// clear it when space is short, which a cache survives). The directory is
  /// looked up when first needed.
  factory FileTranscriptCache.inAppStorage() => FileTranscriptCache(
    () async => Directory('${(await getApplicationCacheDirectory()).path}/transcripts'),
  );

  /// Where the files go; looked up when first needed.
  final Future<Directory> Function() _directory;

  /// A file larger than this is cut to it, oldest lines first.
  final int maxSessionBytes;

  /// All files together stay under this.
  final int maxTotalBytes;

  /// How long a save waits for more to come.
  final Duration debounce;

  final Offload offload;

  /// Files written so far (for tests and diagnostics).
  int writes = 0;

  final _wanted = <String, TranscriptSnapshot>{};
  final _timers = <String, Timer>{};
  final _chains = <String, Future<void>>{};
  Future<String>? _path;

  Future<String> _dir() => _path ??= _directory().then((d) => d.path);

  Future<T> _after<T>(String key, Future<T> Function() op) {
    final previous = _chains[key] ?? Future<void>.value();
    final result = previous.then((_) => op());
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _chains[key] = tail;
    unawaited(tail.then((_) {
      if (identical(_chains[key], tail)) _chains.remove(key);
    }));
    return result;
  }

  @override
  Future<CachedTranscript?> read(String key) => _after(key, () async {
        try {
          final path = '${await _dir()}/${_fileName(key)}';
          final result = await offload(readTranscriptFile, (path: path, key: key, maxBytes: maxSessionBytes));
          if (result == null) return null;
          return CachedTranscript(
            sessionId: result.sessionId,
            asOf: DateTime.fromMillisecondsSinceEpoch(result.asOfMs),
            updates: result.updates,
            setup: result.setup,
            partial: result.partial,
          );
        } on Object {
          return null;
        }
      });

  @override
  void save(String key, TranscriptSnapshot snapshot, {bool now = false}) {
    _wanted[key] = snapshot;
    if (now) {
      _timers.remove(key)?.cancel();
      unawaited(_write(key));
      return;
    }
    _timers[key] ??= Timer(debounce, () {
      _timers.remove(key);
      unawaited(_write(key));
    });
  }

  Future<void> _write(String key) {
    final snapshot = _wanted.remove(key);
    if (snapshot == null) return Future<void>.value();
    final job = TranscriptWriteJob(
      name: _fileName(key),
      key: key,
      sessionId: snapshot.sessionId,
      asOfMs: snapshot.asOf.millisecondsSinceEpoch,
      lines: snapshot.lines,
      setup: snapshot.setup,
      partial: snapshot.partial,
      maxSessionBytes: maxSessionBytes,
      maxTotalBytes: maxTotalBytes,
    );
    return _after(key, () async {
      try {
        final path = await _dir();
        await offload(writeTranscriptFile, (dir: path, job: job));
        writes++;
      } on Object {
        // A cache that cannot be written is a cache that is not there.
      }
    });
  }

  @override
  Future<void> delete(String key) {
    _wanted.remove(key);
    _timers.remove(key)?.cancel();
    return _after(key, () async {
      try {
        final path = '${await _dir()}/${_fileName(key)}';
        await offload(deleteTranscriptFiles, path);
      } on Object {
        // Already gone.
      }
    });
  }

  @override
  Future<void> deleteMachine(String machineId) async {
    final prefix = '${_safe(machineId)}~';
    for (final key in _wanted.keys.toList()) {
      if (_fileName(key).startsWith(prefix)) {
        _wanted.remove(key);
        _timers.remove(key)?.cancel();
      }
    }
    await _sweep(prefix, const {});
  }

  @override
  Future<void> retain(String machineId, Set<String> keeperIds) =>
      _sweep('${_safe(machineId)}~', {for (final id in keeperIds) '${_safe(machineId)}~${_safe(id)}$_suffix'});

  Future<void> _sweep(String prefix, Set<String> keep) async {
    try {
      final path = await _dir();
      // Behind every write already under way, so none brings a file back.
      await Future.wait(_chains.values.toList());
      await offload(sweepTranscriptFiles, (dir: path, prefix: prefix, keep: keep));
    } on Object {
      // Nothing to sweep.
    }
  }

  /// Waits for every write that is under way or due (a test; shutdown).
  Future<void> flush() async {
    for (final key in _wanted.keys.toList()) {
      _timers.remove(key)?.cancel();
      await _write(key);
    }
    await Future.wait(_chains.values.toList());
  }

  static const _suffix = '.tr';
  static const _version = 1;

  static String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  /// `m1/k1` is `m1~k1.tr`. Two ids that differ only by characters outside
  /// `[A-Za-z0-9_-]` would share a file: the header names the real key, and a
  /// file for another key is dropped when read.
  static String _fileName(String key) {
    final slash = key.indexOf('/');
    final machine = slash < 0 ? key : key.substring(0, slash);
    final keeper = slash < 0 ? '' : key.substring(slash + 1);
    return '${_safe(machine)}~${_safe(keeper)}$_suffix';
  }

  /// The header's version field.
  static int get version => _version;
}

// -- the work that runs in the worker isolate ----------------------------------

class TranscriptWriteJob {
  const TranscriptWriteJob({
    required this.name,
    required this.key,
    required this.sessionId,
    required this.asOfMs,
    required this.lines,
    required this.setup,
    required this.partial,
    required this.maxSessionBytes,
    required this.maxTotalBytes,
  });

  final String name;
  final String key;
  final String sessionId;
  final int asOfMs;
  final List<String> lines;
  final Object? setup;
  final bool partial;
  final int maxSessionBytes;
  final int maxTotalBytes;
}

/// What a file held (times as milliseconds: plain data for an isolate).
class TranscriptFileRead {
  const TranscriptFileRead(this.sessionId, this.asOfMs, this.updates, this.setup, this.partial);

  final String sessionId;
  final int asOfMs;
  final List<Map<Object?, Object?>> updates;
  final Object? setup;
  final bool partial;
}

const _newline = 10;

/// Writes [job] into [dir] atomically (temp file, then rename), cut to the
/// session bound with the oldest lines first, then trims the directory to its
/// bound. A job with no line left removes the file.
void writeTranscriptFile(({String dir, TranscriptWriteJob job}) args) {
  final (:dir, :job) = args;
  final directory = Directory(dir);
  if (!directory.existsSync()) directory.createSync(recursive: true);
  final target = '$dir/${job.name}';

  // From the newest line back, keep what fits.
  final chunks = <Uint8List>[];
  var bytes = 0;
  const headerRoom = 4096;
  final setupText = job.setup == null ? null : jsonEncode(job.setup);
  final reserved = headerRoom + (setupText?.length ?? 0) * 3;
  for (var i = job.lines.length - 1; i >= 0; i--) {
    final encoded = utf8.encode(job.lines[i]);
    if (bytes + encoded.length + 1 + reserved > job.maxSessionBytes) break;
    chunks.add(encoded);
    bytes += encoded.length + 1;
  }
  if (chunks.isEmpty) {
    deleteTranscriptFiles(target);
    return;
  }
  final partial = job.partial || chunks.length < job.lines.length;
  final header = utf8.encode(
    jsonEncode({
      'v': FileTranscriptCache.version,
      'key': job.key,
      'sid': job.sessionId,
      'asOf': job.asOfMs,
      'partial': partial,
      'lines': chunks.length,
      if (setupText != null) 'setup': job.setup,
    }),
  );
  final out = BytesBuilder(copy: false)
    ..add(header)
    ..addByte(_newline);
  for (var i = chunks.length - 1; i >= 0; i--) {
    out
      ..add(chunks[i])
      ..addByte(_newline);
  }

  final temp = File('$target.tmp');
  try {
    temp.writeAsBytesSync(out.takeBytes(), flush: true);
    temp.renameSync(target);
  } on Object {
    try {
      if (temp.existsSync()) temp.deleteSync();
    } on Object {
      // Left for the next sweep.
    }
    rethrow;
  }
  trimDirectory(dir, job.maxTotalBytes);
}

/// Deletes the oldest-opened files until all together fit in [maxTotal];
/// temp files left by a write that died go too.
void trimDirectory(String dir, int maxTotal) {
  final entries = <(File, int, DateTime)>[];
  var total = 0;
  for (final e in Directory(dir).listSync(followLinks: false)) {
    if (e is! File) continue;
    if (e.path.endsWith('.tmp')) {
      // A write of another session may be under way: only an old one is a
      // leftover.
      try {
        if (DateTime.now().difference(e.statSync().modified) > const Duration(minutes: 1)) e.deleteSync();
      } on Object {
        // Gone already.
      }
      continue;
    }
    if (!e.path.endsWith('.tr')) continue;
    final stat = e.statSync();
    entries.add((e, stat.size, stat.modified));
    total += stat.size;
  }
  if (total <= maxTotal) return;
  entries.sort((a, b) => a.$3.compareTo(b.$3));
  for (final (file, size, _) in entries) {
    if (total <= maxTotal) break;
    try {
      file.deleteSync();
      total -= size;
    } on Object {
      // Gone already.
    }
  }
}

void deleteTranscriptFiles(String target) {
  for (final path in [target, '$target.tmp']) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } on Object {
      // Nothing to do for a file that will not go.
    }
  }
}

/// Removes files named with [prefix] that are not in [keep] (file names).
void sweepTranscriptFiles(({String dir, String prefix, Set<String> keep}) args) {
  final (:dir, :prefix, :keep) = args;
  final directory = Directory(dir);
  if (!directory.existsSync()) return;
  for (final e in directory.listSync(followLinks: false)) {
    if (e is! File) continue;
    final name = e.uri.pathSegments.last;
    if (!name.startsWith(prefix) || !name.endsWith('.tr') || keep.contains(name)) continue;
    try {
      e.deleteSync();
    } on Object {
      // Gone already.
    }
  }
}

/// Reads and checks one file; null (and the file deleted) when it is damaged,
/// from another version, for another key or larger than [maxBytes]. The lines
/// are decoded here, off the UI thread.
TranscriptFileRead? readTranscriptFile(({String path, String key, int maxBytes}) args) {
  final (:path, :key, :maxBytes) = args;
  final file = File(path);
  if (!file.existsSync()) return null;
  try {
    if (file.lengthSync() > maxBytes) throw const FormatException('too large');
    final text = utf8.decode(file.readAsBytesSync());
    if (!text.endsWith('\n')) throw const FormatException('truncated');
    final rows = text.substring(0, text.length - 1).split('\n');
    final header = jsonDecode(rows.first);
    if (header is! Map || header['v'] != FileTranscriptCache.version || header['key'] != key) {
      throw const FormatException('not ours');
    }
    final sid = header['sid'];
    final asOf = header['asOf'];
    final count = header['lines'];
    if (sid is! String || sid.isEmpty || asOf is! int || count is! int || count != rows.length - 1) {
      throw const FormatException('header');
    }
    final updates = <Map<Object?, Object?>>[];
    for (var i = 1; i < rows.length; i++) {
      final message = jsonDecode(rows[i]);
      final params = message is Map && message['method'] == 'session/update' ? message['params'] : null;
      if (params is! Map) throw const FormatException('line');
      updates.add(params);
    }
    try {
      file.setLastModifiedSync(DateTime.now());
    } on Object {
      // Recency is best effort.
    }
    return TranscriptFileRead(sid, asOf, updates, header['setup'], header['partial'] == true);
  } on Object {
    deleteTranscriptFiles(path);
    return null;
  }
}
