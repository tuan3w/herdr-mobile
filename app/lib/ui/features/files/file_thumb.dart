import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/services/remote_files.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/tokens.dart';
import 'file_kind.dart';

/// Images over this are never fetched for a thumbnail (a phone photo is
/// several MB: reading it over SSH to draw 32 pixels is the wrong trade).
const thumbMaxBytes = 512 * 1024;

/// Reads of thumbnails running at once, per [ThumbLoader].
const thumbParallel = 3;

/// Fetches the bytes behind thumbnails: at most [parallel] reads in flight,
/// rows that scrolled away before their turn are skipped, and the last few
/// megabytes are kept so scrolling back does not read again.
///
/// Reads are SFTP through the transport isolate like every file read; this
/// only decides how many and which.
class ThumbLoader {
  ThumbLoader({this.parallel = thumbParallel, this.budgetBytes = 6 * 1024 * 1024});

  /// The one used by the browser.
  static final shared = ThumbLoader();

  final int parallel;
  final int budgetBytes;

  final _queue = Queue<_Job>();
  final _cache = <String, Uint8List>{}; // insertion order: oldest first
  var _cached = 0;
  var _running = 0;

  /// Reads in flight right now (for tests).
  int get running => _running;

  /// Waiting for their turn (for tests).
  int get waiting => _queue.length;

  /// Whether [e] is a picture worth fetching: a small raster image. (SVG has
  /// nothing here to draw it.)
  static bool eligible(RemoteEntry e) {
    final size = e.size;
    return e.isFile &&
        size != null &&
        size > 0 &&
        size <= thumbMaxBytes &&
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
  /// row is gone by the time its turn comes.
  Future<Uint8List?> load(RemoteFiles files, RemoteEntry e, {required bool Function() cancelled}) {
    final hit = cached(e);
    if (hit != null) return Future.value(hit);
    final job = _Job(files, e, cancelled);
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
      final size = job.entry.size!;
      final read = await job.files.read(job.entry.path, length: size);
      // A file that grew past the limit since it was listed is not a thumb.
      if (read.isNotEmpty && read.length <= thumbMaxBytes) bytes = read;
    } on Object {
      bytes = null;
    }
    if (bytes != null) _remember(_key(job.entry), bytes);
    _running--;
    job.done.complete(bytes);
    _pump();
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

class _Job {
  _Job(this.files, this.entry, this.cancelled);

  final RemoteFiles files;
  final RemoteEntry entry;
  final bool Function() cancelled;
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
      _loader.load(widget.files, e, cancelled: () => _gone || widget.entry != asked).then((bytes) {
        if (!mounted || bytes == null || widget.entry != asked) return;
        setState(() => _bytes = bytes);
      }),
    );
  }

  @override
  void dispose() {
    _gone = true;
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
          borderRadius: BorderRadius.circular(Radii.tile),
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
          frameBuilder: (context, child, frame, sync) => sync || Motion.reduced(context)
              ? child
              : AnimatedOpacity(
                  opacity: frame == null ? 0 : 1,
                  duration: Motion.fade,
                  curve: Motion.easeOut,
                  child: child,
                ),
          // Bytes the engine cannot decode: back to the glyph.
          errorBuilder: (context, error, stack) => Icon(LucideIcons.fileImage, size: size * 0.56, color: ds.textSecondary),
        ),
      ),
    );
  }
}
