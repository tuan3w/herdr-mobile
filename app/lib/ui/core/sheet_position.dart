import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show Drag, DragStartDetails;
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import 'gesture_math.dart';
import 'motion.dart';

/// Where a released sheet goes, free of widgets so it can be tested on its own.
///
/// Offsets are translations down from the sheet's full height: 0 is full,
/// `rest` the lower resting place (0 when the sheet has one stop), `away` off
/// the screen.
abstract final class SheetMath {
  /// A release at least this fast (dp/s) is a flick: it moves a stop in its
  /// direction, however short the drag was. A distance-only threshold makes a
  /// quick flick feel ignored.
  static const flick = 500.0;

  /// How far below its lowest stop a slow release has to project, as a share of
  /// the travel left, to close the sheet.
  static const dismissShare = 0.45;

  /// How far the sheet can be stretched above its full height (dp). It gives,
  /// with resistance ([rubberBand]), and never more than this.
  static const stretch = 32.0;

  /// The sheet's lower resting place, as its visible height: about half the
  /// room, never under 420 dp unless the sheet is shorter.
  static double half({required double room, required double full}) =>
      math.min(full, math.max(room * 0.55, math.min(full, 420.0)));

  /// Whether a sheet [full] tall, in a frame that lets it grow to [cap], opens
  /// at [half] and is dragged up to see the rest: only when its content fills
  /// all the room it may take (a file, a long list: it would scroll). A sheet
  /// sized to a share of the screen (the Made sheet's 60%) opens whole: hiding
  /// part of what it was sized to show hid the rows a test tapped.
  static bool tall({required double full, required double cap}) => full >= cap - 1;

  /// The stop a release at [y] moving at [velocity] (dp/s, positive down) goes
  /// to: `0`, [rest], or [away] (close).
  ///
  /// A flick up always goes to full height. A flick down goes to [rest] from
  /// above it, and closes from at or below it (a flick down from full lands on
  /// rest, as a sheet's detents do; the second one closes). Otherwise the
  /// target is picked from where the sheet would stop if it kept going
  /// (Apple's projection), so a quick short throw still counts.
  static double target({required double y, required double velocity, required double rest, required double away}) {
    if (velocity <= -flick) return 0;
    if (velocity >= flick) return y < rest ? rest : away;
    final projected = y + velocity * Springs.projectSheet;
    if (projected > rest + (away - rest) * dismissShare) return away;
    return projected < rest / 2 ? 0 : rest;
  }

  /// What is shown for the logical offset [raw]: past full height it is
  /// rubber-banded, and it never goes below [away].
  static double shown(double raw, double away) => raw < 0 ? -rubberBand(-raw, stretch) : math.min(raw, away);
}

/// Where a sheet is, and the physics that move it.
///
/// [offset] is the translation from the sheet's full-height place, in dp:
/// 0 is full height, [restHalf] the lower resting place (a tall sheet's half
/// height; 0 when the sheet has one stop), [dismissAt] off the screen. The
/// content is laid out once and moved with a transform, so a drag never lays
/// it out again.
///
/// Every movement starts from what is on screen and can be caught by a finger:
///
/// * The entrance is a timed ease out (the person did not throw it, so no
///   bounce), and a finger can grab the sheet while it rises.
/// * While the finger is down the sheet IS the finger (1:1, the grab offset
///   kept), rubber-banded above full height.
/// * A release hands the finger's speed to a spring ([Springs.carry]) aimed at
///   [SheetMath.target]. Closing is the same spring off the screen: the sheet
///   leaves at the speed it was thrown, and can be caught on the way and
///   dragged back. Only once it is gone does [onDismiss] pop the route.
/// * A close from code (Back, a button, the scrim) is [close]: the timed
///   [Motion.sheetOut] from wherever the sheet is, with no bounce.
class SheetPosition {
  SheetPosition({required TickerProvider vsync, required this.reduced, required this.onDismiss}) {
    _controller = AnimationController.unbounded(vsync: vsync)..addListener(_tick);
  }

  /// Reduced motion: every move lands at once; dragging still follows the finger.
  final bool Function() reduced;

  /// A gesture took the sheet off the screen: pop the route with nothing left
  /// to animate.
  final VoidCallback onDismiss;

  late final AnimationController _controller;

  /// What is shown: the translation from the full-height place, in dp.
  final offset = ValueNotifier<double>(0);

  /// The sheet rests at full height rather than at [restHalf]. Read it; it is
  /// not meant to be listened to (layout does not notify it).
  final expanded = ValueNotifier<bool>(false);

  /// The logical offset, before the rubber band ([SheetMath.shown]).
  var _raw = 0.0;
  var _full = 0.0;
  var _half = 0.0;
  var _laidOut = false;
  var _entering = false;
  var _dragging = false;
  var _leaving = false;
  var _closing = false;
  var _dismissed = false;

  /// The sheet's height at its lower resting place, and its full height.
  double get halfHeight => _half;
  double get fullHeight => _full;

  /// How far down the lower resting place is (0: the sheet has one stop).
  double get restHalf => math.max(0, _full - _half);
  double get dismissAt => _full;
  bool get dragging => _dragging;

  /// The entrance is over (or was cut short by a finger): a tap on the scrim
  /// may close the sheet. The second tap of a double tap on whatever opened it
  /// lands on the scrim while it is still coming up.
  bool get settledIn => _laidOut && !_entering;

  /// Called from layout with the sheet's heights; [half] is null for a sheet
  /// with one stop. The first call puts the sheet at its resting place; later
  /// ones keep its stop when the room or the content changes (the keyboard, a
  /// list that grows). Only paint listens to [offset], so it may change here.
  void layout({required double full, double? half}) {
    _full = full;
    _half = half == null ? full : math.min(half, full);
    if (!_laidOut) {
      _laidOut = true;
      _set(restHalf);
    } else if (_entering) {
      // The content changed while the sheet rises: it rises to the new stop.
      _entryTo = expanded.value ? 0.0 : restHalf;
    } else if (!_dragging && !_controller.isAnimating && !_dismissed && !_closing) {
      final target = expanded.value ? 0.0 : restHalf;
      if (_raw != target) _set(target);
    }
  }

  /// Rises from below the screen to the resting place with [route] (the
  /// route's own animation, through [Motion.easeOut]), so the sheet moves on
  /// the frame the route starts. [expand] retargets it from where it is; a
  /// finger or a close takes over from where it is. Call once, after the first
  /// [layout].
  void enter(Animation<double> route) {
    if (reduced() || !_laidOut || route.isCompleted) return;
    _entering = true;
    _entrance = route..addListener(_onEntrance);
    _set(dismissAt);
    _aimEntrance(restHalf);
    _onEntrance();
  }

  Animation<double>? _entrance;

  /// Where the entrance runs from and to, and the route's progress (curved)
  /// when it set out: an [expand] while the sheet rises retargets it from
  /// where it is, without a jump.
  var _entryFrom = 0.0;
  var _entryTo = 0.0;
  var _entryAt = 0.0;

  void _aimEntrance(double target) {
    _entryFrom = _raw;
    _entryTo = target;
    _entryAt = Motion.easeOut.transform(_entrance!.value);
  }

  void _onEntrance() {
    final route = _entrance!;
    final t = Motion.easeOut.transform(route.value);
    final share = _entryAt >= 1 ? 1.0 : ((t - _entryAt) / (1 - _entryAt)).clamp(0.0, 1.0);
    _set(_entryFrom + (_entryTo - _entryFrom) * share);
    if (route.isCompleted) _endEntrance();
  }

  void _endEntrance() {
    _entrance?.removeListener(_onEntrance);
    _entrance = null;
    _entering = false;
  }

  void _tick() {
    if (!_controller.isAnimating && _controller.value == _raw) return;
    _set(_controller.value);
    if (_leaving && _raw >= dismissAt - Springs.pixel.distance) _gone();
  }

  void _set(double raw) {
    _raw = raw;
    offset.value = SheetMath.shown(raw, dismissAt);
  }

  /// A finger caught the sheet: whatever was moving it stops where it is.
  void grab() {
    if (_closing || _dismissed) return;
    _controller.stop();
    _endEntrance();
    _leaving = false;
  }

  /// Follows the finger by [dy] (positive: down).
  void dragBy(double dy) {
    if (_closing || _dismissed) return;
    if (!_dragging) grab();
    _dragging = true;
    _set(math.min(_raw + dy, dismissAt));
  }

  /// The sheet was stopped between its stops (a finger caught it and lifted
  /// without dragging, a scroll took over): [release] puts it on one. Never
  /// true while something moves it.
  bool get needsSettle {
    if (_dragging || _entering || _controller.isAnimating || _closing || _dismissed || !_laidOut) return false;
    return _raw != 0 && _raw != restHalf;
  }

  /// The finger lifted at [velocity] dp/s (positive: downwards).
  void release(double velocity) {
    _dragging = false;
    if (_closing || _dismissed) return;
    final target = SheetMath.target(y: _raw, velocity: velocity, rest: restHalf, away: dismissAt);
    if (target >= dismissAt) {
      _leave(velocity);
    } else {
      _goTo(target, velocity, Springs.carry);
    }
  }

  /// Moves to full height (a field took focus, a tab wants room).
  void expand() {
    if (_closing || _dismissed || _dragging) return;
    if (_entering) {
      expanded.value = true;
      _aimEntrance(0);
      return;
    }
    _goTo(0, 0, Springs.settle);
  }

  /// The route is closing from code (Back, a button, a tap on the scrim): the
  /// sheet slides off over [Motion.sheetOut], as fast as the route goes.
  void close() {
    if (_closing || _dismissed) return;
    _closing = true;
    _dragging = false;
    _controller.stop();
    _endEntrance();
    if (reduced()) {
      _set(dismissAt);
      return;
    }
    _controller.value = _raw;
    unawaited(_controller.animateTo(dismissAt, duration: Motion.sheetOut, curve: Motion.easeOut));
  }

  void _goTo(double target, double velocity, SpringDescription spring) {
    _endEntrance();
    expanded.value = target == 0;
    if (reduced()) {
      _controller.stop();
      _set(target);
      return;
    }
    _controller.value = _raw;
    unawaited(
      _controller
          .animateWith(SpringSimulation(spring, _raw, target, velocity, snapToEnd: true, tolerance: Springs.pixel))
          .orCancel
          .catchError((Object _) {}),
    );
  }

  /// Off the screen at the speed it was thrown; caught, it comes back.
  void _leave(double velocity) {
    if (reduced()) {
      _set(dismissAt);
      _gone();
      return;
    }
    _leaving = true;
    _controller.value = _raw;
    unawaited(
      _controller
          .animateWith(
            SpringSimulation(Springs.carry, _raw, dismissAt, velocity, snapToEnd: true, tolerance: Springs.pixel),
          )
          .orCancel
          .catchError((Object _) {}),
    );
  }

  void _gone() {
    _leaving = false;
    _dismissed = true;
    _controller.stop();
    onDismiss();
  }

  void dispose() {
    _endEntrance();
    _controller.dispose();
    offset.dispose();
    expanded.dispose();
  }
}

/// A scroll controller that shares its drags with the sheet around it, so a
/// sheet with a scrolling body feels like one surface:
///
/// * Finger up: the sheet rises to full height first, then the body scrolls.
/// * Finger down: the body scrolls back to its top first, then the sheet
///   follows the finger down.
/// * Lifting after the sheet moved hands the finger's speed to the sheet.
///
/// [sheet] is set by whoever builds the scroll view inside the sheet
/// ([SheetScroll], [SheetScope]); without one it is a plain controller.
class SheetScrollController extends ScrollController {
  SheetScrollController({super.debugLabel});

  SheetPosition? sheet;

  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics, ScrollContext context, ScrollPosition? oldPosition) =>
      _SheetScrollPosition(
        owner: this,
        physics: physics,
        context: context,
        initialPixels: initialScrollOffset,
        keepScrollOffset: keepScrollOffset,
        oldPosition: oldPosition,
        debugLabel: debugLabel,
      );
}

class _SheetScrollPosition extends ScrollPositionWithSingleContext {
  _SheetScrollPosition({
    required this.owner,
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  final SheetScrollController owner;

  /// The sheet took part of the current drag.
  var _moved = false;

  @override
  Drag drag(DragStartDetails details, VoidCallback dragCancelCallback) {
    _moved = false;
    owner.sheet?.grab();
    return super.drag(details, dragCancelCallback);
  }

  @override
  void applyUserOffset(double delta) {
    final sheet = owner.sheet;
    if (sheet == null) return super.applyUserOffset(delta);
    var rest = delta;
    if (rest < 0) {
      // Finger up: the sheet to full height first.
      final below = sheet.offset.value;
      if (below > 0) {
        final take = math.min(-rest, below);
        sheet.dragBy(-take);
        _moved = true;
        rest += take;
      }
      if (rest < 0) super.applyUserOffset(rest);
    } else if (rest > 0) {
      // Finger down: the body back to its top first, then the sheet.
      final scrolled = pixels - minScrollExtent;
      if (scrolled > 0) {
        final take = math.min(rest, scrolled);
        super.applyUserOffset(take);
        rest -= take;
      }
      if (rest > 0) {
        sheet.dragBy(rest);
        _moved = true;
      }
    }
  }

  @override
  void goBallistic(double velocity) {
    final sheet = owner.sheet;
    if (sheet != null && (_moved || sheet.needsSettle)) {
      _moved = false;
      // The scroll's velocity is the content's (positive: towards the end, a
      // finger moving up); the sheet's is the finger's (positive: down).
      sheet.release(-velocity);
      super.goBallistic(0);
      return;
    }
    super.goBallistic(velocity);
  }
}

/// What the content of a sheet needs from the sheet around it.
class SheetScope extends InheritedWidget {
  const SheetScope({super.key, required this.position, this.scroll, this.bottomClearance = 0, required super.child});

  final SheetPosition position;

  /// The controller for the body's one scroll view (a [SheetScrollController]
  /// already tied to [position]); null in tests that build content alone.
  final SheetScrollController? scroll;

  /// Room a scrolling body keeps at its end for what is pinned over it: the
  /// part that hangs below the screen at half height, plus the pinned bars.
  final double bottomClearance;

  static SheetScope of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SheetScope>()!;

  static SheetScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SheetScope>();

  @override
  bool updateShouldNotify(SheetScope old) =>
      old.position != position || old.scroll != scroll || old.bottomClearance != bottomClearance;
}

/// A scroll view that belongs to the sheet: its drags are shared with the
/// sheet ([SheetScrollController]). Pass [controller] when the view needs its
/// own (to read its position); otherwise one is made.
class SheetScroll extends StatefulWidget {
  const SheetScroll({super.key, required this.builder, this.controller});

  /// Builds the scroll view with the controller to use.
  final Widget Function(BuildContext context, ScrollController controller) builder;

  final SheetScrollController? controller;

  @override
  State<SheetScroll> createState() => _SheetScrollState();
}

class _SheetScrollState extends State<SheetScroll> {
  late final SheetScrollController _own = SheetScrollController();
  SheetScrollController get _controller => widget.controller ?? _own;

  @override
  void dispose() {
    _own.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller..sheet = SheetScope.maybeOf(context)?.position;
    return widget.builder(context, controller);
  }
}
