import 'dart:async';

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';

import 'motion.dart';
import 'theme.dart';

/// A press must last this long before it counts as a hold: a tap and the start
/// of a scroll look the same until then, so nothing fills, buzzes or changes
/// its words before it.
const holdIntent = Duration(milliseconds: 150);

/// How long the fill takes to reach the end once the press counts as a hold.
/// Intent plus fill is the ~700 ms the finger stays down: slow where the
/// person decides, nothing to wait for after they do.
const holdFill = Duration(milliseconds: 550);

/// How long the fill takes to go back when the finger lets go early.
const holdSnapBack = Duration(milliseconds: 200);

/// How long "Hold to send · why" stays after a tap or an early release. Shorter
/// than the confirm window of the two-step (assistive) flow.
const holdHintWindow = Duration(milliseconds: 2400);

/// What a [HoldToConfirm] child draws.
class HoldState {
  const HoldState({required this.holding, required this.hint, required this.fill});

  /// The finger is down and the press counts as a hold: the fill is moving.
  final bool holding;

  /// A tap or an early release just happened: say how to send it.
  final bool hint;

  /// The fill layer, left to right. A `Positioned.fill`: the child puts it as
  /// the first entry of a `Stack`, under its content, inside its own
  /// background. Painted only (transform-only, no layout).
  final Widget fill;

  /// The chip should say "Hold to send".
  bool get showsHold => holding || hint;
}

/// The danger tint the fill is drawn in.
Color holdFillColor(Ds ds) => ds.danger.withValues(alpha: 0.30);

/// Press-and-hold for an answer that should not go out by accident: the finger
/// has to stay on it until [builder]'s fill reaches the end ([onConfirmed]).
///
/// - A tap, or letting go early, sends nothing: the fill snaps back
///   ([holdSnapBack], instantly under reduced motion) and [HoldState.hint]
///   asks the child to say how to send (for [holdHintWindow]).
/// - Only the first finger counts. The hold is dropped when it leaves the
///   chip, drifts further than a touch slop (a scroll), is cancelled, or the
///   widget is disabled or replaced mid-hold; after that no confirmation can
///   come from it. One press confirms at most once.
/// - A finger cannot hold, and switch or screen-reader users cannot either:
///   the accessibility activation calls [onActivate], which owns the two-step
///   flow (the first activation primes, the second sends).
class HoldToConfirm extends StatefulWidget {
  const HoldToConfirm({
    super.key,
    required this.builder,
    required this.onConfirmed,
    required this.onActivate,
    this.enabled = true,
    this.semanticLabel,
    this.scale = 0.985,
  });

  final Widget Function(BuildContext context, HoldState hold) builder;

  /// The hold reached the end.
  final VoidCallback onConfirmed;

  /// Assistive-technology activation (never a pointer).
  final VoidCallback onActivate;
  final bool enabled;

  /// Replaces the content's own text for assistive technology; null lets the
  /// visible text merge into the label.
  final String? semanticLabel;

  /// Scale while held (1 = none; skipped under reduced motion).
  final double scale;

  @override
  State<HoldToConfirm> createState() => _HoldToConfirmState();
}

class _HoldToConfirmState extends State<HoldToConfirm> with SingleTickerProviderStateMixin {
  late final AnimationController _fill = AnimationController(vsync: this, duration: holdFill);

  int? _pointer;
  Offset _origin = Offset.zero;
  Timer? _intent;
  Timer? _hintTimer;

  /// The press counts as a hold (past [holdIntent], finger still down).
  bool _holding = false;
  bool _hint = false;

  /// This press already confirmed; the rest of it does nothing.
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _fill.addStatusListener(_onStatus);
  }

  @override
  void didUpdateWidget(HoldToConfirm old) {
    super.didUpdateWidget(old);
    if (!widget.enabled) {
      _drop();
      if (_hint) {
        _hintTimer?.cancel();
        setState(() => _hint = false);
      }
    }
  }

  @override
  void dispose() {
    // A finger still down on a chip that went away (a new request, a sent
    // answer) lifts onto nothing: its later events find no pointer to track.
    _pointer = null;
    _intent?.cancel();
    _hintTimer?.cancel();
    _fill.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus s) {
    if (s != AnimationStatus.completed || !_holding || _done) return;
    _done = true;
    _holding = false;
    // The fill goes back whatever the owner does with it: a sent answer
    // replaces the chip, a refused one (an unread command) leaves it as it was.
    _rewind();
    setState(() {});
    widget.onConfirmed();
  }

  void _rewind() {
    _fill.stop();
    if (_fill.value == 0) return;
    if (Motion.reduced(context)) {
      _fill.value = 0;
    } else {
      unawaited(_fill.animateBack(0, duration: holdSnapBack, curve: Motion.easeOut));
    }
  }

  /// Forgets the press without a hint (the finger left, a scroll began, the
  /// chip was disabled or cancelled).
  void _drop() {
    _intent?.cancel();
    _pointer = null;
    if (!_holding) return;
    _holding = false;
    _rewind();
    if (mounted) setState(() {});
  }

  void _down(PointerDownEvent e) {
    if (!widget.enabled || _pointer != null) return;
    _pointer = e.pointer;
    _origin = e.position;
    _done = false;
    _intent?.cancel();
    _intent = Timer(holdIntent, _begin);
  }

  void _begin() {
    if (!mounted || _pointer == null || !widget.enabled) return;
    _hintTimer?.cancel();
    Haptics.armed();
    _fill.forward(from: 0);
    setState(() {
      _holding = true;
      _hint = false;
    });
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    final size = context.size;
    final outside = size == null || !(Offset.zero & size).contains(e.localPosition);
    if (outside || (e.position - _origin).distance > kTouchSlop) _drop();
  }

  void _up(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    _intent?.cancel();
    if (_done) {
      // The press already confirmed; lifting only ends it.
      _done = false;
      return;
    }
    // A tap, or too early: nothing was sent.
    Haptics.tick();
    final wasHolding = _holding;
    _holding = false;
    if (wasHolding) {
      _fill.stop();
      _rewind();
    }
    _hintTimer?.cancel();
    _hintTimer = Timer(holdHintWindow, () {
      if (mounted) setState(() => _hint = false);
    });
    setState(() => _hint = true);
  }

  void _cancel(PointerCancelEvent e) {
    if (e.pointer != _pointer) return;
    _drop();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    Widget child = widget.builder(
      context,
      HoldState(
        holding: _holding,
        hint: _hint,
        fill: Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              key: holdFillKey,
              painter: HoldFillPainter(progress: _fill, color: holdFillColor(ds), radius: Radii.chip),
            ),
          ),
        ),
      ),
    );
    if (widget.scale != 1 && !Motion.reduced(context)) {
      child = AnimatedScale(
        scale: _holding ? widget.scale : 1,
        duration: Motion.pressing(_holding),
        curve: Motion.easeOut,
        child: child,
      );
    }
    final label = widget.semanticLabel;
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: label,
      excludeSemantics: label != null,
      // The pointer path below is the hold; assistive technology gets the
      // two-step activation.
      onTap: widget.enabled ? widget.onActivate : null,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: _cancel,
        child: child,
      ),
    );
  }
}

/// The fill layer's paint, found by tests (they read [HoldFillPainter.progress]).
const holdFillKey = ValueKey<String>('holdFill');

/// Paints the fill: the left [progress] of the chip, clipped to its corners.
class HoldFillPainter extends CustomPainter {
  HoldFillPainter({required this.progress, required this.color, required this.radius}) : super(repaint: progress);

  final Animation<double> progress;
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final v = progress.value;
    if (v <= 0) return;
    canvas
      ..save()
      ..clipRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)))
      ..drawRect(Rect.fromLTWH(0, 0, size.width * v, size.height), Paint()..color = color)
      ..restore();
  }

  @override
  bool shouldRepaint(HoldFillPainter old) => old.color != color || old.radius != radius || old.progress != progress;
}
