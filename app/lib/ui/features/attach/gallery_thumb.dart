import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../data/services/phone_gallery.dart';
import '../../../data/services/thumb_cache.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';

/// Thumbnails are decoded at their own size (MediaStore made them <= 240 px).
/// The grid tile and the attachment chip build the SAME provider from the same
/// bytes, so the chip finds the picture already decoded in the image cache.
const galleryThumbPx = 240;

ImageProvider galleryThumbProvider(Uint8List bytes) => ResizeImage(MemoryImage(bytes), width: galleryThumbPx, allowUpscaling: false);

/// One picture's thumbnail: a flat tinted tile until its bytes arrive (never a
/// spinner), then the picture, faded in over `Motion.fade` when it arrived
/// after the tile was built (not when it was already in memory, and not under
/// reduced motion). A tile that leaves the screen before its thumbnail is
/// loaded cancels the request.
class GalleryThumb extends StatefulWidget {
  const GalleryThumb({super.key, required this.asset, required this.cache});

  final GalleryAsset asset;
  final ThumbCache cache;

  @override
  State<GalleryThumb> createState() => _GalleryThumbState();
}

class _GalleryThumbState extends State<GalleryThumb> with SingleTickerProviderStateMixin {
  Uint8List? _bytes;
  AnimationController? _fade;
  var _waiting = false;

  @override
  void initState() {
    super.initState();
    _bytes = widget.cache.peek(widget.asset.id);
    if (_bytes == null) _ask();
  }

  @override
  void didUpdateWidget(GalleryThumb old) {
    super.didUpdateWidget(old);
    if (old.asset.id != widget.asset.id) {
      _release();
      _fade?.dispose();
      _fade = null;
      _bytes = widget.cache.peek(widget.asset.id);
      if (_bytes == null) _ask();
    }
  }

  void _ask() {
    _waiting = true;
    final id = widget.asset.id;
    unawaited(
      widget.cache.request(widget.asset).then((bytes) {
        _waiting = false;
        if (!mounted || bytes == null || widget.asset.id != id) return;
        final reduced = Motion.reduced(context);
        if (!reduced) {
          final c = AnimationController(vsync: this, duration: Motion.fade);
          _fade = c;
          c.addStatusListener((s) {
            if (s != AnimationStatus.completed) return;
            // At rest the picture is drawn bare: no opacity layer per tile.
            scheduleMicrotask(() {
              if (!mounted || !identical(_fade, c)) return;
              setState(() => _fade = null);
              c.dispose();
            });
          });
          unawaited(c.forward().catchError((Object _) {}));
        }
        setState(() => _bytes = bytes);
      }),
    );
  }

  void _release() {
    if (_waiting) {
      _waiting = false;
      widget.cache.cancel(widget.asset.id);
    }
  }

  @override
  void dispose() {
    _release();
    _fade?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return ColoredBox(color: context.ds.fill);
    final image = Image(
      image: galleryThumbProvider(bytes),
      fit: BoxFit.cover,
      filterQuality: FilterQuality.low,
      gaplessPlayback: true,
      excludeFromSemantics: true,
      errorBuilder: (_, _, _) => ColoredBox(color: context.ds.fill),
    );
    final fade = _fade;
    return fade == null ? image : FadeTransition(opacity: fade, child: image);
  }
}
