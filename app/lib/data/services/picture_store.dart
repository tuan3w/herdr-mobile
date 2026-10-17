import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// The one small on-disk picture cache: the photo viewer, both folder
/// thumbnail loaders and the terminal-log chat share it, so a picture the
/// person already looked at is not downloaded again.
///
/// It only keeps what the person asked to see; nothing prefetches into it.
/// One file per key, named by the SHA-1 of the key, in one flat private
/// directory (a picture may be private: the app's own cache directory, never
/// shared storage). A write goes to a temp file that is renamed over the
/// file, so a reader sees the old picture or the new one. The directory is
/// bounded by [maxBytes]: past it the least recently used files go until
/// [lowWater] is left (the gap keeps it from trimming on every put). Recency
/// on disk is the file's modified time, so an app restart keeps the order.
///
/// A store failure is never the caller's problem: [get] answers null and
/// [put] does nothing, and the caller goes to the network. A corrupt or short
/// file cannot be told apart here; callers check what they know (a length, or
/// the codec).
class PictureStore {
  PictureStore(
    this._directory, {
    this.maxBytes = 192 << 20,
    this.lowWater = 160 << 20,
    this.maxEntryBytes = 12 << 20,
  });

  /// The store in the app's private cache directory (`pictures/` under it; the
  /// OS may clear it when space is short, which a cache survives). The
  /// directory is looked up when first needed.
  factory PictureStore.inAppStorage() =>
      PictureStore(() async => Directory('${(await getApplicationCacheDirectory()).path}/pictures'));

  /// The store the app uses. Not final: tests replace it, like
  /// `ImagePreviewCache.shared`.
  static PictureStore shared = PictureStore.inAppStorage();

  /// Everything kept stays under this; going past it trims to [lowWater].
  final int maxBytes;
  final int lowWater;

  /// A picture larger than this is not kept (the same bound as the decode
  /// limit and the viewer's preload limit).
  final int maxEntryBytes;

  final Future<Directory> Function() _directory;

  // -- keys: what identifies the bytes goes into the key, so a changed file is a
  // miss and never served stale; one spelling for every caller ----------------

  /// A whole file on a machine, as the photo viewer reads it.
  static String fileKey(String machineId, String path, int size, int modifiedMs) =>
      'f:$machineId\u0000$path\u0000$size\u0000$modifiedMs';

  /// The 240 px thumbnail of a file, shared by the folder list and grid.
  static String thumbKey(String machineId, String path, int size, int modifiedMs) =>
      't:$machineId\u0000$path\u0000$size\u0000$modifiedMs';

  /// A picture of a Claude or Codex log, by the keeper's content hash.
  static String logKey(String hash16) => 'l:$hash16';

  /// An omp blob, by its sha256.
  static String ompKey(String sha256hex) => 'o:$sha256hex';

  static String _name(String key) => sha1.convert(utf8.encode(key)).toString();

  // -- state -------------------------------------------------------------------

  final _index = <String, _Entry>{};
  int _total = 0;
  int _seq = 0;
  int _tmpCounter = 0;
  String? _path;
  Future<void>? _loaded;
  Future<void>? _chain;

  /// The index is loaded (one directory listing). Safe to await repeatedly.
  Future<void> get ready => _loaded ??= _load();

  /// Whether [key] is stored, as of now and without touching the disk. False
  /// until [ready].
  bool knows(String key) => _index.containsKey(_name(key));

  Future<T> _after<T>(Future<T> Function() op) {
    // The first operation starts at once, in the caller's zone: a chain that
    // begins with an already completed future would run it in the zone that
    // made the store.
    final previous = _chain;
    final result = previous == null ? Future<T>.sync(op) : previous.then((_) => op());
    _chain = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _load() async {
    try {
      final dir = await _directory();
      await dir.create(recursive: true);
      _path = dir.path;
      final found = <({String name, int bytes, DateTime used})>[];
      final now = DateTime.now();
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        try {
          final stat = await entity.stat();
          if (name.contains('.tmp')) {
            // A write that died; a fresh one may still be running.
            if (now.difference(stat.modified) > const Duration(minutes: 1)) await entity.delete();
          } else {
            found.add((name: name, bytes: stat.size, used: stat.modified));
          }
        } on Object {
          continue;
        }
      }
      found.sort((a, b) => a.used.compareTo(b.used));
      for (final f in found) {
        _index[f.name] = _Entry(f.bytes, _seq++);
        _total += f.bytes;
      }
    } on Object {
      _path = null;
    }
  }

  /// The bytes kept for [key], or null on a miss or any IO error. A hit counts
  /// as use.
  Future<Uint8List?> get(String key) async {
    await ready;
    return _after(() async {
      final path = _path;
      if (path == null) return null;
      final name = _name(key);
      final entry = _index[name];
      if (entry == null) return null;
      try {
        final file = File('$path/$name');
        final bytes = await file.readAsBytes();
        entry.seq = _seq++;
        try {
          await file.setLastModified(DateTime.now());
        } on Object {
          // Best effort: only the order after a restart depends on it.
        }
        return bytes;
      } on Object {
        // Gone or unreadable: forget it, so [knows] stops saying yes.
        if (identical(_index[name], entry)) {
          _index.remove(name);
          _total -= entry.bytes;
        }
        return null;
      }
    });
  }

  /// Keeps [bytes] under [key]. Dropped silently when empty, larger than
  /// [maxEntryBytes] or on any IO error.
  Future<void> put(String key, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maxEntryBytes) return;
    await ready;
    return _after(() async {
      final path = _path;
      if (path == null) return;
      final name = _name(key);
      final temp = File('$path/$name.tmp$pid-${_tmpCounter++}');
      try {
        await temp.writeAsBytes(bytes, flush: true);
        await temp.rename('$path/$name');
      } on Object {
        try {
          await temp.delete();
        } on Object {
          // Nothing more to do.
        }
        return;
      }
      final old = _index[name];
      if (old != null) _total -= old.bytes;
      _index[name] = _Entry(bytes.length, _seq++);
      _total += bytes.length;
      if (_total > maxBytes) await _trim(path);
    });
  }

  Future<void> _trim(String path) async {
    final oldestFirst = _index.entries.toList()..sort((a, b) => a.value.seq.compareTo(b.value.seq));
    for (final e in oldestFirst) {
      if (_total <= lowWater) break;
      try {
        await File('$path/${e.key}').delete();
      } on PathNotFoundException {
        // Already gone: still not kept.
      } on Object {
        continue;
      }
      _index.remove(e.key);
      _total -= e.value.bytes;
    }
  }

  /// Bytes kept.
  Future<int> totalBytes() async {
    await ready;
    return _after(() async => _total);
  }

  /// Deletes every file; returns the bytes freed.
  Future<int> clear() async {
    await ready;
    return _after(() async {
      final path = _path;
      if (path == null) return 0;
      var freed = 0;
      try {
        await for (final entity in Directory(path).list(followLinks: false)) {
          if (entity is! File) continue;
          try {
            final size = await entity.length();
            await entity.delete();
            freed += size;
          } on Object {
            continue;
          }
        }
      } on Object {
        // A directory that cannot be listed has nothing the index can trust.
      }
      _index.clear();
      _total = 0;
      return freed;
    });
  }
}

class _Entry {
  _Entry(this.bytes, this.seq);
  final int bytes;
  int seq;
}
