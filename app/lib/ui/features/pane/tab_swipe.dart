import 'package:flutter/widgets.dart';

/// Turns a quick, clearly horizontal one-finger swipe into a step to the
/// neighbouring tab (+1 = next, for a swipe to the left).
///
/// It listens to raw pointer events and never joins the gesture arena, so it
/// can sit over the terminal without taking anything from it: vertical
/// scrolling, taps on links, long-press selection and pinch zoom all behave as
/// before. It only decides, from the finger's own path, whether to ALSO switch:
///
/// * one finger the whole time (a second finger is a pinch: cancelled);
/// * horizontal travel of at least [distance] within [window] of touching down
///   (selection starts at 500 ms, so a selection drag is never a swipe);
/// * vertical travel under 40% of the horizontal one when it crosses; a finger
///   that has gone clearly vertical first is a scroll for the rest of the touch;
/// * not starting within [edge] of the sides (the system back gesture).
///
/// Fires once per touch, as soon as the swipe is recognised.
class TabSwipeDetector extends StatefulWidget {
  const TabSwipeDetector({
    super.key,
    required this.enabled,
    required this.onSwipe,
    required this.child,
    this.distance = 64,
    this.window = const Duration(milliseconds: 450),
    this.edge = 12,
  });

  final bool enabled;
  final ValueChanged<int> onSwipe;
  final Widget child;
  final double distance;
  final Duration window;
  final double edge;

  @override
  State<TabSwipeDetector> createState() => _TabSwipeDetectorState();
}

class _TabSwipeDetectorState extends State<TabSwipeDetector> {
  int? _pointer;
  Offset _start = Offset.zero;
  Duration _startedAt = Duration.zero;

  /// This touch can no longer be a swipe (second finger, vertical, too slow,
  /// started at an edge, or it already fired).
  bool _dead = true;

  void _down(PointerDownEvent e) {
    if (_pointer != null) {
      _dead = true;
      return;
    }
    _pointer = e.pointer;
    _start = e.localPosition;
    _startedAt = e.timeStamp;
    final width = context.size?.width ?? 0;
    _dead =
        !widget.enabled ||
        _start.dx < widget.edge ||
        _start.dx > width - widget.edge;
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer || _dead) return;
    final dx = e.localPosition.dx - _start.dx;
    final dy = e.localPosition.dy - _start.dy;
    if (e.timeStamp - _startedAt > widget.window) {
      _dead = true;
      return;
    }
    if (dy.abs() > 24 && dy.abs() > dx.abs()) {
      _dead = true;
      return;
    }
    if (dx.abs() >= widget.distance && dy.abs() <= dx.abs() * 0.4) {
      _dead = true;
      widget.onSwipe(dx < 0 ? 1 : -1);
    }
  }

  void _end(PointerEvent e) {
    if (e.pointer == _pointer) {
      _pointer = null;
      _dead = true;
    } else if (_pointer == null) {
      _dead = true;
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _down,
    onPointerMove: _move,
    onPointerUp: _end,
    onPointerCancel: _end,
    child: widget.child,
  );
}
