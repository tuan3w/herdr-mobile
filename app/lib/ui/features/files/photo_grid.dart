import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/services/remote_files.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../core/tokens.dart';
import 'file_format.dart';
import 'photo_thumbs.dart';

/// A folder's pictures as a grid of square thumbnails: three columns, a 2 dp
/// gap, each picture centre-cropped.
///
/// A sliver, so a `CustomScrollView` can hold it among other slivers. Only the
/// tiles near the screen exist, and each asks [thumbs] for its picture when it
/// is built and lets go when it is scrolled away, which is what stops the
/// reads of tiles nobody sees. [entries] are the pictures in display order
/// (see `photoEntries`); [onOpen] hears the index of the tile tapped.
class PhotoGrid extends StatelessWidget {
  const PhotoGrid({
    super.key,
    required this.files,
    required this.entries,
    required this.onOpen,
    this.thumbs,
  });

  /// Tiles per row.
  static const columns = 3;

  /// Space between tiles, in both directions.
  static const gap = 2.0;

  final RemoteFiles files;
  final List<RemoteEntry> entries;
  final ValueChanged<int> onOpen;

  /// Defaults to [PhotoThumbs.shared].
  final PhotoThumbs? thumbs;

  @override
  Widget build(BuildContext context) {
    final cache = thumbs ?? PhotoThumbs.shared;
    return SliverGrid.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: gap,
        crossAxisSpacing: gap,
      ),
      itemCount: entries.length,
      // A tile scrolled away is released at once; its picture stays in the
      // cache, not in the widget tree.
      addAutomaticKeepAlives: false,
      itemBuilder: (context, i) => _PhotoTile(
        key: ValueKey(entries[i].path),
        files: files,
        entry: entries[i],
        thumbs: cache,
        onTap: () => onOpen(i),
      ),
    );
  }
}

class _PhotoTile extends StatefulWidget {
  const _PhotoTile({
    super.key,
    required this.files,
    required this.entry,
    required this.thumbs,
    required this.onTap,
  });

  final RemoteFiles files;
  final RemoteEntry entry;
  final PhotoThumbs thumbs;
  final VoidCallback onTap;

  @override
  State<_PhotoTile> createState() => _PhotoTileState();
}

class _PhotoTileState extends State<_PhotoTile> with SingleTickerProviderStateMixin {
  late ThumbEntry _held;
  late ThumbPhase _seen;

  /// Fades a picture in over its placeholder, once, when it arrives while the
  /// tile is on screen. Null at rest (and for pictures already cached).
  AnimationController? _fade;

  @override
  void initState() {
    super.initState();
    _hold();
  }

  void _hold() {
    _held = widget.thumbs.acquire(widget.files, widget.entry)..addListener(_changed);
    _seen = _held.phase;
  }

  void _let() {
    _held.removeListener(_changed);
    widget.thumbs.release(_held);
  }

  @override
  void didUpdateWidget(_PhotoTile old) {
    super.didUpdateWidget(old);
    if (!identical(old.thumbs, widget.thumbs) || !_held.matches(widget.entry) || !identical(old.files, widget.files)) {
      // The listing changed under this tile (a refresh found a new size or
      // time): its old thumbnail is not this picture's.
      final fresh = widget.thumbs.acquire(widget.files, widget.entry);
      _held.removeListener(_changed);
      old.thumbs.release(_held);
      _held = fresh..addListener(_changed);
      _seen = _held.phase;
      _fade?.dispose();
      _fade = null;
    }
  }

  void _changed() {
    if (!mounted) return;
    final arrived = _seen != ThumbPhase.ready && _held.phase == ThumbPhase.ready;
    _seen = _held.phase;
    if (arrived && !Motion.reduced(context)) {
      _fade?.dispose();
      _fade = AnimationController(vsync: this, duration: Motion.fade)
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed && mounted) {
            setState(() {
              _fade?.dispose();
              _fade = null;
            });
          }
        })
        ..forward();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _fade?.dispose();
    _let();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final e = widget.entry;
    final size = formatBytes(e.size);
    final phase = _held.phase;
    final image = phase == ThumbPhase.ready ? _held.image : null;
    return PressBuilder(
      onTap: widget.onTap,
      haptic: true,
      // The name is only ever read out, never drawn: it can be any length.
      semanticLabel: '${e.name}, $size',
      builder: (context, pressed) => Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: ds.fill,
            child: switch (phase) {
              ThumbPhase.tooBig => _Note(icon: LucideIcons.image, text: e.size == null ? null : size),
              ThumbPhase.failed => const _Note(icon: LucideIcons.imageOff),
              _ => image == null ? const _Note(icon: LucideIcons.image, faint: true) : null,
            },
          ),
          if (image != null)
            _fade == null
                ? _Picture(image)
                : FadeTransition(opacity: CurvedAnimation(parent: _fade!, curve: Motion.easeOut), child: _Picture(image)),
          if (pressed) ColoredBox(color: ds.text.withValues(alpha: 0.12)),
        ],
      ),
    );
  }
}

/// The thumbnail, centre-cropped to the tile. Hands the render object its own
/// clone: it disposes what it is given, the cache keeps the original.
class _Picture extends StatelessWidget {
  const _Picture(this.image);

  final ui.Image image;

  @override
  Widget build(BuildContext context) => RawImage(
        image: image.clone(),
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
      );
}

/// A glyph (and a size) on a quiet tile: a picture on its way, one too big to
/// fetch for a thumbnail, or one that could not be read.
class _Note extends StatelessWidget {
  const _Note({required this.icon, this.text, this.faint = false});

  final IconData icon;
  final String? text;
  final bool faint;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xs),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24, color: faint ? ds.textTertiary.withValues(alpha: 0.6) : ds.textMuted),
            if (text != null) ...[
              const SizedBox(height: Gap.xs),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(text!, maxLines: 1, style: Type.caption.copyWith(color: ds.textMuted)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
