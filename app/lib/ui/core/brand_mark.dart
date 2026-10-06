import 'package:flutter/material.dart';

import 'motion.dart';
import 'tokens.dart';

/// How long a [BrandMark] takes to draw itself.
const brandMarkDuration = Duration(milliseconds: 420);

/// herdr's mark: a lowercase h whose stem rises into a shepherd's crook, and
/// in the crook the one agent that needs you (the orange dot). herdr is the
/// one who herds; the person holding the phone keeps the herd, and the app's
/// job is the one that needs them. It is the launcher icon, the notification
/// icon and the first-run mark, all drawn from this one geometry (the icon
/// files are rendered from it by `screenshot_test/brand_assets_test.dart`).
///
/// Coordinates are on Android's 108-unit adaptive-icon canvas: the launcher
/// shows the central 72 units through its mask, and everything here stays
/// inside the 66-unit safe circle, so no launcher mask (circle, squircle,
/// teardrop) clips it. Why the crook curls outward: curling over the shoulder
/// made the h read as an R at 56 dp.
abstract final class BrandGeometry {
  static const canvas = 108.0;

  /// The part of [canvas] a launcher shows (centred).
  static const visible = 72.0;

  static const stroke = 6.2;

  // The h: a stem at [stemX] from [foot] up to [top], where the crook curls
  // out (radius [curl]) to [crookX] and drops to its tip at [tipY]; the
  // shoulder leaves the stem at [shoulderY] and the leg stands at [legX].
  static const stemX = 54.0;
  static const foot = 74.0;
  static const top = 43.0;
  static const curl = 9.0;
  static const crookX = 36.0;
  static const tipY = 48.5;
  static const shoulderY = 60.0;
  static const legX = 72.0;

  /// The stem, from its foot up into the crook, ending at the crook's tip.
  static Path get crook => Path()
    ..moveTo(stemX, foot)
    ..lineTo(stemX, top)
    ..arcToPoint(const Offset(crookX, top), radius: const Radius.circular(curl), clockwise: false)
    ..lineTo(crookX, tipY);

  /// The h's shoulder and leg.
  static Path get shoulder => Path()
    ..moveTo(stemX, shoulderY)
    ..arcToPoint(const Offset(legX, shoulderY), radius: const Radius.circular(curl))
    ..lineTo(legX, foot);

  /// The agent that needs you, held in the crook.
  static const dot = Offset(45, 45);
  static const dotRadius = 3.3;

  /// The background of every coloured form: the ink page.
  static Color get tile => Ds.ink.bg;
  static Color get ink => Ds.ink.text;

  /// The needs-you colour of the ink theme: the dot is the one agent that
  /// needs you.
  static Color get needsYou => Ds.ink.blocked;

  /// Paints the mark on the [canvas]-unit grid (scale the canvas first).
  /// [crookDrawn], [shoulderDrawn] and [dotIn] run 0..1 for the draw-in; 1 is
  /// the finished mark. [mono] paints every part in one colour (themed
  /// launcher icon, notification icon).
  static void paint(
    Canvas canvas, {
    Color? mono,
    double crookDrawn = 1,
    double shoulderDrawn = 1,
    double dotIn = 1,
  }) {
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = mono ?? ink;
    _stroke(canvas, crook, crookDrawn, line);
    _stroke(canvas, shoulder, shoulderDrawn, line);
    if (dotIn > 0) {
      final color = mono ?? needsYou;
      canvas.drawCircle(
        dot,
        dotRadius,
        Paint()..color = dotIn >= 1 ? color : color.withValues(alpha: color.a * dotIn),
      );
    }
  }

  /// The first [fraction] of [path]'s length.
  static void _stroke(Canvas canvas, Path path, double fraction, Paint paint) {
    if (fraction <= 0) return;
    if (fraction >= 1) {
      canvas.drawPath(path, paint);
      return;
    }
    for (final metric in path.computeMetrics()) {
      canvas.drawPath(metric.extractPath(0, metric.length * fraction), paint);
    }
  }
}

/// The app icon as a widget: the mark on its ink tile, as the launcher shows
/// it. On first build it draws itself once, the way a hand would write it:
/// the stem rises into the crook, the shoulder follows, the dot lands. For
/// the first-run screen only (a moment that happens about once); reduced
/// motion, or [animate] false, shows the finished mark. No loop: the ticker
/// stops at the end. Decorative: the words beside it carry the meaning.
class BrandMark extends StatefulWidget {
  const BrandMark({super.key, this.size = 64, this.animate = true});

  final double size;
  final bool animate;

  @override
  State<BrandMark> createState() => _BrandMarkState();
}

class _BrandMarkState extends State<BrandMark> with SingleTickerProviderStateMixin {
  // Linear; each part applies its own curve (see the painter).
  late final AnimationController _controller = AnimationController(vsync: this, duration: brandMarkDuration);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!widget.animate || Motion.reduced(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: RepaintBoundary(
          child: CustomPaint(
            size: Size.square(widget.size),
            painter: _BrandMarkPainter(_controller),
          ),
        ),
      );
}

class _BrandMarkPainter extends CustomPainter {
  _BrandMarkPainter(this.progress) : super(repaint: progress);

  final Animation<double> progress;

  // The parts overlap so the mark reads as one gesture, not three steps.
  static const _crook = (0.0, 0.6);
  static const _shoulder = (0.35, 0.8);
  static const _dot = (0.65, 1.0);

  static double _part(double t, (double, double) span) {
    final f = ((t - span.$1) / (span.$2 - span.$1)).clamp(0.0, 1.0);
    return f >= 1 ? 1 : Motion.easeOut.transform(f);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    // The tile has the empty-state tile's shape, scaled (Radii.emptyTile on 52).
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(Radii.emptyTile * size.width / 52)),
      Paint()..color = BrandGeometry.tile,
    );
    const crop = (BrandGeometry.canvas - BrandGeometry.visible) / 2;
    canvas.scale(size.width / BrandGeometry.visible);
    canvas.translate(-crop, -crop);
    BrandGeometry.paint(
      canvas,
      crookDrawn: _part(t, _crook),
      shoulderDrawn: _part(t, _shoulder),
      dotIn: _part(t, _dot),
    );
  }

  @override
  bool shouldRepaint(_BrandMarkPainter old) => old.progress != progress;
}
