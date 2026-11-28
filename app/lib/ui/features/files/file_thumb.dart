import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/services/image_decode.dart';
import '../../../data/services/image_sniff.dart';
import '../../../data/services/disk_cache.dart';
import '../../../data/services/remote_files.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'file_kind.dart';

/// Images over this are never READ for a thumbnail (a phone photo is several
/// MB: reading it over SSH to draw 32 pixels is the wrong trade). A machine
/// with the agent helper makes the thumbnail itself, up to [thumbHostMaxBytes].
const thumbMaxBytes = 512 * 1024;

/// The biggest picture a machine is asked to make a thumbnail of (the helper's
/// own limit is 64 MiB).
const thumbHostMaxBytes = 64 * 1024 * 1024;

/// The longest side asked of the machine, in pixels (the 240 px the app has
/// always shrunk to, rounded up to a multiple of 128). Fixed, not scaled by the
/// screen: the thumbnails are kept on disk under one key per picture (shared by
/// the list and the grid), so one size has to serve both, and a 32 dp row and
/// a 120 dp tile both look right from it.
const thumbRequestPx = 256;

/// Reads of thumbnails running at once, per [ThumbLoader].
const thumbParallel = 3;

/// Fetches the bytes behind thumbnails: at most [parallel] reads in flight,
/// rows that scrolled away before their turn are skipped, and the last few
/// megabytes are kept so scrolling back does not read again.
///
/// Reads are SFTP through the transport isolate like every file read; this
/// only decides how many and which.
///
/// What it hands out is a small thumbnail (about 15-60 KB), not the file: the
/// first time the file is read and shrunk, the thumbnail is kept in the
/// [DiskCache] under the key the folder grid ([PhotoThumbs]) uses too, so
/// a row seen again (after a restart too) costs no read, and the memory budget
/// holds many more rows. A file the engine cannot shrink is handed out as it
/// is.
class ThumbLoader {
  ThumbLoader({
    this.parallel = thumbParallel,
    this.budgetBytes = 6 * 1024 * 1024,
    DiskCache? store,
    Thumbnailer? thumbnailer,
  }) : _store = store ?? DiskCache.shared,
       _thumbnailer = thumbnailer ?? makeThumbnail;

  /// The one used by the browser.
  static final shared = ThumbLoader();

  final int parallel;
  final int budgetBytes;
  final DiskCache _store;
  final Thumbnailer _thumbnailer;

  final _queue = Queue<_Job>();
  final _cache = <String, Uint8List>{}; // insertion order: oldest first
  var _cached = 0;

  /// Big pictures the machine could not make a thumbnail of (oldest first).
  final _noThumb = <String>{};
  var _running = 0;

  /// Reads in flight right now (for tests).
  int get running => _running;

  /// Waiting for their turn (for tests).
  int get waiting => _queue.length;

  /// Whether [e] is a picture worth fetching: a small raster image, or any
  /// raster image up to [thumbHostMaxBytes] for a machine that makes thumbnails
  /// itself (one that cannot is asked once per picture and then left alone).
  /// (SVG has nothing here to draw it.)
  static bool eligible(RemoteEntry e) {
    final size = e.size;
    return e.isFile &&
        size != null &&
        size > 0 &&
        size <= thumbHostMaxBytes &&
        typeForName(e.name).kind == FileKind.image;
  }

  static String _key(RemoteEntry e) => '${e.path}\u0000${e.modified?.millisecondsSinceEpoch}\u0000${e.size}';

  /// The bytes already in memory for [e], or null.
  Uint8List? cached(RemoteEntry e) {
    final key = _key(e);
    final bytes = _cache.remove(key);
    if (bytes != null) _cache[key] = bytes; // most recent last
    return bytes;
  }

  /// Fetches [e]; completes null on any failure, or when [cancelled] says the
  /// row is gone by the time its turn comes. [cancel] firing stops a thumbnail
  /// the host is still making.
  Future<Uint8List?> load(RemoteFiles files, RemoteEntry e, {required bool Function() cancelled, ReadCancel? cancel}) {
    final hit = cached(e);
    if (hit != null) return Future.value(hit);
    final job = _Job(files, e, () => cancelled() || (cancel?.cancelled ?? false), cancel ?? ReadCancel());
    _queue.add(job);
    _pump();
    return job.done.future;
  }

  void _pump() {
    while (_running < parallel && _queue.isNotEmpty) {
      final job = _queue.removeFirst();
      if (job.cancelled()) {
        job.done.complete(null);
        continue;
      }
      _running++;
      unawaited(_run(job));
    }
  }

  Future<void> _run(_Job job) async {
    Uint8List? bytes;
    try {
      final entry = job.entry;
      final size = entry.size!;
      final modified = entry.modified;
      final key = modified == null || job.files.machineId.isEmpty
          ? null
          : DiskCache.thumbKey(job.files.machineId, entry.path, size, modified.millisecondsSinceEpoch);
      bytes = key == null ? null : await _store.get(key);
      if (bytes == null && !job.cancelled()) {
        // The machine makes the thumbnail when it can (agent helper): a few
        // tens of KB cross the radio instead of the picture.
        final fromHost = await _hostThumbnail(job, size, modified);
        if (fromHost != null) {
          bytes = fromHost;
          if (key != null) unawaited(_store.put(key, fromHost));
        } else if (size <= thumbMaxBytes && !job.cancelled()) {
          final read = await job.files.read(entry.path, length: size);
          // A file that grew past the limit since it was listed is not a thumb.
          if (read.isNotEmpty && read.length <= thumbMaxBytes) {
            // A thumbnail is only made to be kept: without a key it would be
            // work for nothing.
            Uint8List? thumb;
            if (key != null) {
              try {
                thumb = await _thumbnailer(read);
              } on Object {
                thumb = null;
              }
            }
            bytes = thumb ?? read;
            if (thumb != null && key != null) unawaited(_store.put(key, thumb));
          }
        }
      }
    } on Object {
      bytes = null;
    }
    if (bytes != null) _remember(_key(job.entry), bytes);
    _running--;
    job.done.complete(bytes);
    _pump();
  }

  /// The host's thumbnail of [job]'s picture, or null (SFTP, an older helper, a
  /// picture it cannot read, a file that changed, the row gone). A big picture
  /// the host could not do is remembered, so a row that scrolls back does not
  /// ask again.
  Future<Uint8List?> _hostThumbnail(_Job job, int size, DateTime? modified) async {
    final entry = job.entry;
    final key = _key(entry);
    if (_noThumb.contains(key)) return null;
    final bytes = await job.files.thumbnail(
      entry.path,
      maxPx: thumbRequestPx,
      expect: modified == null
          ? null
          : RemoteStat(path: entry.path, kind: RemoteEntryKind.file, size: size, modified: modified),
      cancel: job.cancel,
    );
    if (bytes == null && !job.cancelled() && size > thumbMaxBytes) {
      if (_noThumb.length >= 512) _noThumb.remove(_noThumb.first);
      _noThumb.add(key);
    }
    return bytes;
  }

  void _remember(String key, Uint8List bytes) {
    final old = _cache.remove(key);
    if (old != null) _cached -= old.length;
    _cache[key] = bytes;
    _cached += bytes.length;
    while (_cached > budgetBytes && _cache.length > 1) {
      final oldest = _cache.keys.first;
      _cached -= _cache.remove(oldest)!.length;
    }
  }
}

/// The thumbnail bytes of a small picture file, or null when it cannot be made.
typedef Thumbnailer = Future<Uint8List?> Function(Uint8List original);

/// Shrinks [original] to 240 px and encodes it (see [encodeThumbnail]).
Future<Uint8List?> makeThumbnail(Uint8List original) async {
  // design-lint: allow(raw-size) image pixels for the thumbnail file, not a layout size
  final decoded = await decodeImageFit(original, maxWidth: 240, maxHeight: 240);
  try {
    return await encodeThumbnail(decoded.image, png: mayHaveTransparency(original));
  } finally {
    decoded.dispose();
  }
}

class _Job {
  _Job(this.files, this.entry, this.cancelled, this.cancel);

  final RemoteFiles files;
  final RemoteEntry entry;
  final bool Function() cancelled;
  final ReadCancel cancel;
  final done = Completer<Uint8List?>();
}

/// The 32-pixel tile of a file row: a small picture of the image when the file
/// is one and is small enough, the file-type glyph otherwise (and while the
/// picture is still on its way, or failed). Pictures are read lazily, only for
/// rows that are on screen, three at a time ([ThumbLoader]).
class FileThumb extends StatefulWidget {
  const FileThumb({
    super.key,
    required this.files,
    required this.entry,
    required this.icon,
    this.size = 32,
    this.loader,
  });

  final RemoteFiles files;
  final RemoteEntry entry;

  /// The glyph shown instead of a picture.
  final IconData icon;
  final double size;

  /// Defaults to [ThumbLoader.shared].
  final ThumbLoader? loader;

  @override
  State<FileThumb> createState() => _FileThumbState();
}

class _FileThumbState extends State<FileThumb> {
  Uint8List? _bytes;
  var _gone = false;
  var _cancel = ReadCancel();

  ThumbLoader get _loader => widget.loader ?? ThumbLoader.shared;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(FileThumb old) {
    super.didUpdateWidget(old);
    if (old.entry != widget.entry) {
      // The picture of the old entry is not wanted any more: a thumbnail the
      // host is still making for it stops.
      _cancel.cancel();
      _cancel = ReadCancel();
      _bytes = null;
      _start();
    }
  }

  void _start() {
    final e = widget.entry;
    if (!ThumbLoader.eligible(e)) return;
    final hit = _loader.cached(e);
    if (hit != null) {
      _bytes = hit;
      return;
    }
    final asked = e;
    unawaited(
      _loader.load(widget.files, e, cancelled: () => _gone || widget.entry != asked, cancel: _cancel).then((bytes) {
        if (!mounted || bytes == null || widget.entry != asked) return;
        setState(() => _bytes = bytes);
      }),
    );
  }

  @override
  void dispose() {
    _gone = true;
    // A row that scrolled away: its thumbnail stops being made on the host.
    _cancel.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final size = widget.size;
    final bytes = _bytes;
    final glyph = IconTile(icon: widget.icon, size: size);
    if (bytes == null) return glyph;
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.xs),
          border: Border.all(color: ds.hairline, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Image(
          image: ResizeImage(MemoryImage(bytes), width: px, policy: ResizeImagePolicy.fit),
          width: size,
          height: size,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, sync) =>
              sync || Motion.reduced(context) ? child : _FadeIn(shown: frame != null, child: child),
          // Bytes the engine cannot decode: back to the glyph.
          errorBuilder: (context, error, stack) =>
              Icon(LucideIcons.fileImage, size: size * 0.56, color: ds.textSecondary),
        ),
      ),
    );
  }
}

/// Fades [child] in once, when [shown] turns true, then draws it with no
/// opacity layer: a thumbnail at rest is not an animation.
class _FadeIn extends StatefulWidget {
  const _FadeIn({required this.shown, required this.child});

  final bool shown;
  final Widget child;

  @override
  State<_FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<_FadeIn> with SingleTickerProviderStateMixin {
  AnimationController? _fade;

  @override
  void didUpdateWidget(_FadeIn old) {
    super.didUpdateWidget(old);
    if (widget.shown && !old.shown && _fade == null) {
      _fade = AnimationController(vsync: this, duration: Motion.fade)
        ..addStatusListener((s) {
          if (s != AnimationStatus.completed || !mounted) return;
          setState(() {
            _fade?.dispose();
            _fade = null;
          });
        })
        ..forward();
    }
  }

  @override
  void dispose() {
    _fade?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fade = _fade;
    return fade == null ? widget.child : FadeTransition(opacity: Motion.curved(fade), child: widget.child);
  }
}
