import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'motion.dart';

/// How long a [DrawCheck] takes to draw itself.
const drawCheckDuration = Duration(milliseconds: 320);

/// A circle and a check that stroke themselves in once, like Lucide's
/// `circleCheck` being written by hand, then stay. For a rare moment worth a
/// little ceremony (a connection test that passed); lists and frequent states
/// keep a still icon.
///
/// The circle is drawn first, clockwise from the top, and the check follows
/// before the circle closes; each stroke eases out on its own ([Motion.easeOut]
/// over the whole mark would finish both in the first few frames). No loop: the
/// ticker stops at the end. With reduced motion (or [animate] false) the
/// finished mark is shown at once. Decorative: the words beside it carry the
/// meaning.
class DrawCheck extends StatefulWidget {
  const DrawCheck({super.key, required this.color, this.size = 18, this.animate = true});

  final Color color;
  final double size;

  /// False draws the finished mark without motion.
  final bool animate;

  @override
  State<DrawCheck> createState() => _DrawCheckState();
}

class _DrawCheckState extends State<DrawCheck> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: drawCheckDuration);
  // Linear; each stroke applies its own curve (see the painter).
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
            painter: _DrawCheckPainter(_controller, widget.color),
          ),
        ),
      );
}

class _DrawCheckPainter extends CustomPainter {
  _DrawCheckPainter(this.progress, this.color) : super(repaint: progress);

  final Animation<double> progress;
  final Color color;

  // Lucide `circleCheck` on its 24 unit grid: circle r10 at 12,12; check
  // `m9 12 2 2 4-4`.
  static const _grid = 24.0;
  static const _circleEnd = 0.6;
  static const _checkStart = 0.45;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    final scale = size.width / _grid;
    canvas.scale(scale);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final circle = Path()
      ..moveTo(12, 2)
      // Two halves: a single arc of a full turn can come out empty.
      ..arcTo(const Rect.fromLTWH(2, 2, 20, 20), -math.pi / 2, math.pi, false)
      ..arcTo(const Rect.fromLTWH(2, 2, 20, 20), math.pi / 2, math.pi, false);
    _stroke(canvas, circle, (t / _circleEnd).clamp(0.0, 1.0), paint);

    final check = Path()
      ..moveTo(9, 12)
      ..lineTo(11, 14)
      ..lineTo(15, 10);
    _stroke(canvas, check, ((t - _checkStart) / (1 - _checkStart)).clamp(0.0, 1.0), paint);
  }

  /// The first [fraction] of [path]'s length.
  void _stroke(Canvas canvas, Path path, double fraction, Paint paint) {
    if (fraction <= 0) return;
    if (fraction >= 1) {
      canvas.drawPath(path, paint);
      return;
    }
    final eased = Motion.easeOut.transform(fraction);
    for (final metric in path.computeMetrics()) {
      canvas.drawPath(metric.extractPath(0, metric.length * eased), paint);
    }
  }

  @override
  bool shouldRepaint(_DrawCheckPainter old) => old.color != color || old.progress != progress;
}
