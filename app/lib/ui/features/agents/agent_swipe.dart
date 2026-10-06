import 'dart:async';

import 'package:flutter/widgets.dart';

/// Turns a quick, clearly horizontal one-finger swipe into a step to the
/// neighbouring agent (+1 = next, for a swipe to the left).
///
/// It listens to raw pointer events and never joins the gesture arena, so it
/// can sit over a terminal or a transcript without taking anything from it:
/// vertical scrolling, taps on links, long-press selection and pinch zoom all
/// behave as before. It only decides, from the finger's own path, whether to
/// ALSO step:
///
/// * one finger the whole time (a second finger is a pinch: cancelled);
/// * horizontal travel of at least [distance] within [window] of touching down
///   (selection starts at 500 ms, so a selection drag is never a swipe);
/// * vertical travel under 40% of the horizontal one when it crosses; a finger
///   that has gone clearly vertical first is a scroll for the rest of the touch;
/// * not starting within [edge] of the screen's sides (the back gestures);
/// * nothing under the finger scrolled sideways during the touch (a code
///   block, a table, a terminal wider than the screen): that swipe is theirs.
///   A scrollable that has room to scroll claims the drag well before
///   [distance], and the step waits for the end of the pointer event that
///   recognised it, so a scroll claimed by that same event still wins.
///
/// Fires once per touch, as soon as the swipe is recognised.
class AgentSwipeDetector extends StatefulWidget {
  const AgentSwipeDetector({
    super.key,
    required this.enabled,
    required this.onSwipe,
    required this.child,
    this.distance = 64,
    this.window = const Duration(milliseconds: 450),
    this.edge = 24,
  });

  final bool enabled;
  final ValueChanged<int> onSwipe;
  final Widget child;
  final double distance;
  final Duration window;
  final double edge;

  @override
  State<AgentSwipeDetector> createState() => _AgentSwipeDetectorState();
}

class _AgentSwipeDetectorState extends State<AgentSwipeDetector> {
  int? _pointer;
  Offset _start = Offset.zero;
  Duration _startedAt = Duration.zero;

  /// This touch can no longer be a swipe (second finger, vertical, too slow,
  /// started at an edge, something scrolled sideways, or it already fired).
  bool _dead = true;

  /// Something under the finger scrolled sideways during this touch.
  bool _sideways = false;

  void _down(PointerDownEvent e) {
    if (_pointer != null) {
      _dead = true;
      return;
    }
    _pointer = e.pointer;
    _start = e.position;
    _startedAt = e.timeStamp;
    _sideways = false;
    final width = MediaQuery.sizeOf(context).width;
    _dead = !widget.enabled || _start.dx < widget.edge || _start.dx > width - widget.edge;
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer || _dead) return;
    final dx = e.position.dx - _start.dx;
    final dy = e.position.dy - _start.dy;
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
      final step = dx < 0 ? 1 : -1;
      // The gesture arena sees this event after this listener: a scrollable
      // that claims the drag on it says so before the microtask runs.
      scheduleMicrotask(() {
        if (mounted && !_sideways && widget.enabled) widget.onSwipe(step);
      });
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

  bool _onScroll(ScrollNotification n) {
    if (_pointer != null && n.metrics.axis == Axis.horizontal && n is! ScrollEndNotification) {
      _sideways = true;
      _dead = true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _down,
    onPointerMove: _move,
    onPointerUp: _end,
    onPointerCancel: _end,
    child: NotificationListener<ScrollNotification>(onNotification: _onScroll, child: widget.child),
  );
}
