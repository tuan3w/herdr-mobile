import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/services/image_decode.dart';
import '../../../data/services/remote_files.dart';

/// Where one thumbnail is.
enum ThumbPhase {
  /// Waiting for a free slot (or for its tile to be built).
  queued,

  /// The file is being read or decoded.
  loading,

  /// [ThumbEntry.image] can be drawn.
  ready,

  /// Bigger than [PhotoThumbs.autoLimit]: never fetched on its own, the photo
  /// opens on tap.
  tooBig,

  /// Unreadable, or not a picture the engine can decode.
  failed,
}

/// One folder photo's thumbnail: its state and, once [phase] is
/// [ThumbPhase.ready], the decoded pixels.
///
/// Tiles hold an entry with [PhotoThumbs.acquire] and let go with
/// [PhotoThumbs.release]; the cache only disposes the pixels of an entry nobody
/// holds. Listen to hear [phase] change.
class ThumbEntry extends ChangeNotifier {
  ThumbEntry._(this._files, this.path, this.size, this.modified, this._phase);

  final RemoteFiles _files;
  final String path;

  /// Size and modification time the listing gave: with [path] they say which
  /// file this thumbnail is of, so a changed file is never served stale.
  final int? size;
  final DateTime? modified;

  ThumbPhase _phase;
  ui.Image? _image;
  var _refs = 0;
  var _queued = false;
  _Load? _load;
  var _gone = false;

  ThumbPhase get phase => _phase;

  /// The thumbnail, owned by the cache: draw a `clone()` of it (RawImage takes
  /// ownership of what it is given), never dispose it.
  ui.Image? get image => _image;

  bool matches(RemoteEntry e) => e.path == path && e.size == size && e.modified == modified;

  void _changed() => notifyListeners();

  void _finish(ThumbPhase phase, ui.Image? image) {
    _phase = phase;
    _image = image;
    notifyListeners();
  }

  void _drop() {
    if (_gone) return;
    _gone = true;
    _image?.dispose();
    _image = null;
    dispose();
  }
}

class _Load {
  final cancel = ReadCancel();

  /// Abandoned: its result is thrown away.
  var dead = false;

  /// Its slot has been given back.
  var freed = false;
}

/// Thumbnails of the photos in a folder grid.
///
/// Reads go through [RemoteFiles] (SFTP), at most [maxConcurrent] at a time,
/// smallest file first, and only for files up to [autoLimit] bytes. A tile asks
/// for its thumbnail when it is built ([acquire]) and lets go when it leaves
/// the screen ([release]): a load nobody is waiting for any more is dropped from
/// the queue, or cancelled and its slot given back at once. Decoded pictures
/// (shrunk to [side] pixels while they decode) are kept for the last
/// [capacity] entries nobody holds, so scrolling back is instant, and disposed
/// when pushed out.
class PhotoThumbs {
  PhotoThumbs({
    this.maxConcurrent = 3,
    this.autoLimit = 2 * 1024 * 1024,
    this.capacity = 120,
    this.side = 240,
    this._decoder = decodeImageFit,
  });

  /// The cache the folder grid and the photo viewer's placeholders share.
  static final PhotoThumbs shared = PhotoThumbs();

  /// Reads in flight at once.
  final int maxConcurrent;

  /// Files bigger than this are not fetched for a thumbnail.
  final int autoLimit;

  /// Entries kept once nothing holds them.
  final int capacity;

  /// Longest side of a thumbnail's bitmap, in pixels.
  final int side;

  final FitDecoder _decoder;

  /// By path, least recently used first.
  final _entries = <String, ThumbEntry>{};
  final _queue = <ThumbEntry>[];
  var _running = 0;
  var _pumpScheduled = false;
  var _disposed = false;

  /// Reads (and decodes) under way.
  int get inFlight => _running;

  /// Entries waiting for a slot.
  int get queued => _queue.length;

  /// Entries kept, held or not.
  int get length => _entries.length;

  /// A clone of the cached thumbnail for [path] (the caller owns it and
  /// disposes it), or null when none is ready. Cheap and synchronous: the
  /// photo viewer shows it while the real picture loads.
  ui.Image? peek(String path) => _entries[path]?._image?.clone();

  /// Holds the thumbnail of [entry] for a tile and (re)starts its load when it
  /// has none. Pair with [release].
  ThumbEntry acquire(RemoteFiles files, RemoteEntry entry) {
    var e = _entries.remove(entry.path);
    if (e != null && !e.matches(entry)) {
      _detach(e);
      e = null;
    }
    e ??= ThumbEntry._(files, entry.path, entry.size, entry.modified, _firstPhase(entry.size));
    _entries[e.path] = e;
    e._refs++;
    if (e._phase == ThumbPhase.failed && (e.size == null || e.size! > 0) && e._load == null) {
      // A failure may have been the link: scrolling back tries again. (A file
      // the listing says is empty has nothing to try.)
      e._phase = ThumbPhase.queued;
    }
    if (e._phase == ThumbPhase.queued && !e._queued) {
      e._queued = true;
      _queue.add(e);
      _schedulePump();
    }
    _trim();
    return e;
  }

  /// What the listing's [size] already says: empty files have no picture, big
  /// ones are not fetched. An unknown size has to be tried.
  ThumbPhase _firstPhase(int? size) {
    if (size == null) return ThumbPhase.queued;
    if (size <= 0) return ThumbPhase.failed;
    return size > autoLimit ? ThumbPhase.tooBig : ThumbPhase.queued;
  }

  /// Lets go of what [acquire] returned. The last holder leaving dequeues the
  /// load, or cancels it and frees its slot at once.
  void release(ThumbEntry e) {
    if (e._refs == 0) return;
    e._refs--;
    if (e._refs > 0) return;
    _dequeue(e);
    _abandon(e);
    if (!identical(_entries[e.path], e)) {
      e._drop();
      return;
    }
    // Last used now.
    _entries
      ..remove(e.path)
      ..[e.path] = e;
    _trim();
  }

  /// Cancels every load and frees every picture (tests, and a cache that is
  /// replaced). Tiles must be gone.
  void dispose() {
    _disposed = true;
    _queue.clear();
    for (final e in _entries.values.toList()) {
      _abandon(e);
      e._drop();
    }
    _entries.clear();
  }

  void _dequeue(ThumbEntry e) {
    if (!e._queued) return;
    e._queued = false;
    _queue.remove(e);
  }

  /// Stops [e]'s load, if any: the slot is free now, the result (if the read
  /// still lands) is thrown away, and the entry waits to be asked for again.
  void _abandon(ThumbEntry e) {
    final load = e._load;
    if (load == null) return;
    load.dead = true;
    load.cancel.cancel();
    e._load = null;
    e._phase = ThumbPhase.queued;
    _free(load);
  }

  /// [e] was replaced by a newer entry for the same path.
  void _detach(ThumbEntry e) {
    _dequeue(e);
    _abandon(e);
    if (e._refs == 0) e._drop();
  }

  void _free(_Load load) {
    if (load.freed) return;
    load.freed = true;
    _running--;
    _schedulePump();
  }

  /// Starts loads on the next microtask, so the tiles built in one frame are
  /// all queued (and ordered) before the first read begins.
  void _schedulePump() {
    if (_pumpScheduled) return;
    _pumpScheduled = true;
    scheduleMicrotask(() {
      _pumpScheduled = false;
      _pump();
    });
  }

  void _pump() {
    while (!_disposed && _running < maxConcurrent && _queue.isNotEmpty) {
      var best = 0;
      for (var i = 1; i < _queue.length; i++) {
        if (_sizeKey(_queue[i]) < _sizeKey(_queue[best])) best = i;
      }
      final e = _queue.removeAt(best);
      e._queued = false;
      _start(e);
    }
  }

  /// Smallest first; an unknown size goes last.
  int _sizeKey(ThumbEntry e) => e.size ?? autoLimit + 1;

  void _start(ThumbEntry e) {
    final load = _Load();
    e._load = load;
    e._phase = ThumbPhase.loading;
    _running++;
    e._changed();
    unawaited(_run(e, load));
  }

  Future<void> _run(ThumbEntry e, _Load load) async {
    ThumbPhase phase;
    ui.Image? image;
    try {
      final bytes = await _fetch(e, load);
      if (load.dead) return;
      if (bytes == null) {
        phase = ThumbPhase.tooBig;
      } else if (bytes.isEmpty) {
        phase = ThumbPhase.failed;
      } else {
        final decoded = await _decoder(bytes, maxWidth: side, maxHeight: side);
        image = decoded.image;
        phase = image.width > 0 && image.height > 0 ? ThumbPhase.ready : ThumbPhase.failed;
        if (phase == ThumbPhase.failed) {
          image.dispose();
          image = null;
        }
      }
    } on Object {
      phase = ThumbPhase.failed;
    }
    if (load.dead) {
      // Abandoned while decoding: the slot is already free.
      image?.dispose();
      return;
    }
    e._load = null;
    _free(load);
    e._finish(phase, image);
  }

  /// The file's bytes, or null when it turned out to be over [autoLimit]
  /// (only possible when the listing gave no size).
  Future<Uint8List?> _fetch(ThumbEntry e, _Load load) async {
    final size = e.size;
    if (size == null) {
      final bytes = await e._files.read(e.path, length: autoLimit + 1);
      return bytes.length > autoLimit ? null : bytes;
    }
    // One call: the file is at most autoLimit bytes. readAll checks the cancel
    // flag around it.
    return e._files.readAll(e.path, size: size, chunk: size, cancel: load.cancel);
  }

  /// Keeps at most [capacity] entries nobody holds, dropping the least
  /// recently used first (their pixels are disposed).
  void _trim() {
    if (_entries.length <= capacity) return;
    var idle = 0;
    for (final e in _entries.values) {
      if (e._refs == 0) idle++;
    }
    if (idle <= capacity) return;
    final drop = <ThumbEntry>[];
    for (final e in _entries.values) {
      if (idle <= capacity) break;
      if (e._refs == 0) {
        drop.add(e);
        idle--;
      }
    }
    for (final e in drop) {
      _entries.remove(e.path);
      e._drop();
    }
  }
}
