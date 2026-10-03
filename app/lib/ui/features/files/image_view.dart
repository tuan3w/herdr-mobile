import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/tokens.dart';
import 'file_viewer_view_model.dart';

/// A decoded image you can pinch, pan and double-tap.
///
/// "Fit" shows the whole picture; "actual size" shows one image pixel per
/// device pixel (what other viewers call 100%). [actualSize] is the toggle's
/// state: changing it animates to that zoom, and later pinching is free.
class ImageView extends StatefulWidget {
  const ImageView({super.key, required this.image, required this.actualSize});

  final DecodedImage image;
  final bool actualSize;

  @override
  State<ImageView> createState() => _ImageViewState();
}

class _ImageViewState extends State<ImageView> with SingleTickerProviderStateMixin {
  final _controller = TransformationController();
  late final AnimationController _anim = AnimationController(vsync: this, duration: Motion.standard);
  Animation<Matrix4>? _tween;
  Size _viewport = Size.zero;
  Offset _doubleTapAt = Offset.zero;

  @override
  void initState() {
    super.initState();
    _anim.addListener(() {
      final t = _tween;
      if (t != null) _controller.value = t.value;
    });
  }

  @override
  void didUpdateWidget(ImageView old) {
    super.didUpdateWidget(old);
    if (old.actualSize != widget.actualSize) {
      _zoomTo(widget.actualSize ? _actualScale : 1, _viewport.center(Offset.zero));
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    _controller.dispose();
    super.dispose();
  }

  Size get _fit => applyBoxFit(
        BoxFit.contain,
        Size(widget.image.width.toDouble(), widget.image.height.toDouble()),
        _viewport,
      ).destination;

  /// Scale of the fitted picture that shows one image pixel per device pixel.
  double get _actualScale {
    final fit = _fit;
    if (fit.width == 0) return 1;
    return (widget.image.width / MediaQuery.devicePixelRatioOf(context)) / fit.width;
  }

  /// Animates to [scale] keeping the viewport point [focus] where it is.
  void _zoomTo(double scale, Offset focus) {
    final current = _controller.value;
    // Point of the child under [focus] now; it must stay under it after.
    final scene = _controller.toScene(focus);
    final target = Matrix4.identity()
      ..translateByDouble(focus.dx - scene.dx * scale, focus.dy - scene.dy * scale, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
    if (scale == 1) target.setIdentity();
    if (Motion.reduced(context)) {
      _controller.value = target;
      return;
    }
    _tween = Matrix4Tween(begin: current, end: target)
        .animate(CurvedAnimation(parent: _anim, curve: Motion.easeOut));
    _anim
      ..reset()
      ..forward();
  }

  void _onDoubleTap() {
    final zoomed = _controller.value.getMaxScaleOnAxis() > 1.05;
    _zoomTo(zoomed ? 1 : math.max(2.5, math.min(_actualScale, 6)), _doubleTapAt);
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return LayoutBuilder(
      builder: (context, box) {
        _viewport = box.biggest;
        final fit = _fit;
        final upscale = fit.width > widget.image.image.width * 1.5;
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
                onDoubleTap: _onDoubleTap,
                child: InteractiveViewer(
                  transformationController: _controller,
                  minScale: 0.6,
                  maxScale: math.max(8, _actualScale * 3),
                  child: SizedBox(
                    width: box.maxWidth,
                    height: box.maxHeight,
                    child: Center(
                      child: RawImage(
                        image: widget.image.image,
                        width: fit.width,
                        height: fit.height,
                        fit: BoxFit.contain,
                        // Small pictures scaled way up stay crisp (pixel art, icons).
                        filterQuality: upscale ? FilterQuality.none : FilterQuality.medium,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (widget.image.downscaled)
              Positioned(
                left: Gap.gutter,
                bottom: Gap.lg + MediaQuery.paddingOf(context).bottom,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: ds.surface,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: ds.hairline),
                    ),
                    child: Text(
                      'Preview at reduced resolution',
                      style: Type.caption.copyWith(color: ds.textSecondary),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
