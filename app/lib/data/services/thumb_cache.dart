import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'phone_gallery.dart';

/// Thumbnails of the gallery, in memory: an LRU capped by bytes and by count,
/// and the queue that fills it.
///
/// - **Bytes only.** What is kept are the small JPEGs MediaStore made (<= 240
///   px, ~10-25 KB). The engine decodes them off the UI thread when a tile
///   paints them (`Image.memory` with `cacheWidth`).
/// - **At most [parallel] loads at once**, newest request first among tiles
///   that are on screen (a fling's skipped tiles cancel before they start),
///   and [prefetch] work only when nothing on screen waits.
/// - **[paused]** holds the queue during a fast fling; a tile asks again when
///   it is built, so nothing is lost.
/// - **Cancelling** a tile that scrolled away removes its request if it has
///   not started. A load already running is not interrupted (it is a few ms
///   of the plugin's thread, and its bytes land in the cache for the way back).
class ThumbCache {
  ThumbCache({
    required this.load,
    this.onEvict,
    this.maxBytes = 60 * 1024 * 1024,
    this.maxEntries = 200,
    this.parallel = 4,
  });

  final Future<Uint8List?> Function(GalleryAsset asset) load;

  /// Told when a thumbnail leaves the cache, so whoever decoded it can give
  /// the bitmap back (the image cache would otherwise keep ~230 KB of pixels
  /// per thumbnail long after its bytes are gone).
  final void Function(String id, Uint8List bytes)? onEvict;
  final int maxBytes;
  final int maxEntries;
  final int parallel;

  final _lru = <String, Uint8List>{}; // oldest first
  var _bytes = 0;
  final _reqs = <String, _Req>{};
  final _high = Queue<_Req>();
  final _low = Queue<_Req>();
  final _failed = <String>{};
  var _running = 0;
  var _paused = false;

  /// Loads started (for tests and the benchmark).
  var started = 0;

  /// The most loads that ran at the same time.
  var peakRunning = 0;

  int get length => _lru.length;
  int get bytes => _bytes;
  int get waiting => _high.length + _low.length;
  bool get paused => _paused;

  set paused(bool value) {
    if (_paused == value) return;
    _paused = value;
    if (!value) _pump();
  }

  /// The bytes if they are in memory (and marks them recently used).
  Uint8List? peek(String id) {
    final hit = _lru.remove(id);
    if (hit != null) _lru[id] = hit;
    return hit;
  }

  /// Whether the picture is known to have no thumbnail.
  bool failed(String id) => _failed.contains(id);

  /// The thumbnail of [asset]; null if it cannot be made. Callers that stop
  /// caring (the tile left the screen) call [cancel].
  Future<Uint8List?> request(GalleryAsset asset) {
    final hit = peek(asset.id);
    if (hit != null) return Future.value(hit);
    if (_failed.contains(asset.id)) return Future.value();
    var req = _reqs[asset.id];
    if (req == null) {
      req = _Req(asset);
      _reqs[asset.id] = req;
      _high.addLast(req);
    } else if (req.low && !req.started) {
      // A prefetch that turned out to be needed now.
      _low.remove(req);
      req.low = false;
      _high.addLast(req);
    }
    req.refs++;
    _pump();
    return req.done.future;
  }

  /// Gives up a [request]: a request nobody waits for and that has not started
  /// is dropped.
  void cancel(String id) {
    final req = _reqs[id];
    if (req == null) return;
    if (req.refs > 0) req.refs--;
    if (req.refs == 0 && !req.started && !req.low) {
      _high.remove(req);
      _reqs.remove(id);
      req.done.complete(null);
    }
  }

  /// Warms [assets] when nothing on screen is waiting. Replaces the previous
  /// prefetch list (the person scrolled elsewhere).
  void prefetch(Iterable<GalleryAsset> assets) {
    for (final r in _low) {
      if (r.refs == 0) {
        _reqs.remove(r.asset.id);
        r.done.complete(null);
      }
    }
    _low.removeWhere((r) => r.refs == 0);
    for (final a in assets) {
      if (_lru.containsKey(a.id) || _reqs.containsKey(a.id) || _failed.contains(a.id)) continue;
      final req = _Req(a)..low = true;
      _reqs[a.id] = req;
      _low.addLast(req);
    }
    _pump();
  }

  /// Forgets every thumbnail (memory pressure, a permission change). Requests
  /// still queued are dropped.
  void clear() {
    final gone = Map.of(_lru);
    _lru.clear();
    _bytes = 0;
    gone.forEach((id, b) => onEvict?.call(id, b));
    _failed.clear();
    for (final r in [..._high, ..._low]) {
      if (!r.started) {
        _reqs.remove(r.asset.id);
        r.done.complete(null);
      }
    }
    _high.clear();
    _low.clear();
  }

  void _pump() {
    while (!_paused && _running < parallel) {
      final _Req req;
      if (_high.isNotEmpty) {
        req = _high.removeFirst();
      } else if (_low.isNotEmpty) {
        req = _low.removeFirst();
      } else {
        return;
      }
      req.started = true;
      _running++;
      if (_running > peakRunning) peakRunning = _running;
      started++;
      unawaited(_run(req));
    }
  }

  Future<void> _run(_Req req) async {
    Uint8List? bytes;
    try {
      bytes = await load(req.asset);
    } on Object {
      bytes = null;
    }
    _running--;
    _reqs.remove(req.asset.id);
    if (bytes == null || bytes.isEmpty) {
      _failed.add(req.asset.id);
      if (_failed.length > 1000) _failed.remove(_failed.first);
      bytes = null;
    } else {
      _remember(req.asset.id, bytes);
    }
    req.done.complete(bytes);
    _pump();
  }

  void _remember(String id, Uint8List bytes) {
    final old = _lru.remove(id);
    if (old != null) _bytes -= old.length;
    _lru[id] = bytes;
    _bytes += bytes.length;
    while ((_bytes > maxBytes || _lru.length > maxEntries) && _lru.length > 1) {
      final oldest = _lru.keys.first;
      final gone = _lru.remove(oldest)!;
      _bytes -= gone.length;
      onEvict?.call(oldest, gone);
    }
  }
}

class _Req {
  _Req(this.asset);

  final GalleryAsset asset;
  final done = Completer<Uint8List?>();
  var refs = 0;
  var started = false;
  var low = false;
}
