import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';

/// Where the sheet is: a translation `offset` from its full-height position
/// (0 = full, [restHalf] = half height, [dismissAt] = off the screen).
///
/// The sheet's content is laid out ONCE at full height; dragging and
/// snapping move it with a transform, so a drag never lays out the grid
/// again. The half-height resting place is simply the full layout pushed
/// down; the bars pinned to the bottom do not follow that part of the move
/// (see [SheetFrame]).
///
/// A release hands the finger's velocity to a spring ([_spring]); the target
/// is picked from where the sheet would end up if it kept going
/// ([_project]), so a flick goes one stop further than a slow drag.
class SheetPosition {
  SheetPosition({required TickerProvider vsync, required this.reduced, required this.onDismiss}) {
    _controller = AnimationController.unbounded(vsync: vsync)..addListener(_tick);
  }

  final bool Function() reduced;
  final VoidCallback onDismiss;

  late final AnimationController _controller;

  /// Translation from the full-height place, in dp.
  final offset = ValueNotifier<double>(0);

  /// The sheet rests at full height (the content may scroll) rather than half.
  final expanded = ValueNotifier<bool>(false);

  var _full = 0.0;
  var _half = 0.0;
  var _dragging = false;
  var _dismissed = false;
  var _laidOut = false;

  static final _spring = SpringDescription.withDampingRatio(mass: 1, stiffness: 420, ratio: 0.88);

  /// The sheet's height at half, and its full height.
  double get halfHeight => _half;
  double get fullHeight => _full;

  /// How far down the half-height place is.
  double get restHalf => math.max(0, _full - _half);
  double get dismissAt => _full;
  bool get dragging => _dragging;

  /// Called from layout with the sheet's sizes. The first call puts the sheet
  /// at half height; later ones keep its stop when the room changes (the
  /// keyboard).
  void layout({required double full, required double half}) {
    _full = full;
    _half = math.min(half, full);
    if (!_laidOut) {
      _laidOut = true;
      offset.value = restHalf;
    } else if (!_dragging && !_controller.isAnimating && !_dismissed) {
      final target = expanded.value ? 0.0 : restHalf;
      if (offset.value != target && offset.value < dismissAt) offset.value = target;
    }
  }

  void _tick() {
    if (_controller.isAnimating || _controller.value != offset.value) offset.value = math.max(0, _controller.value);
  }

  /// Follows the finger.
  void dragBy(double dy) {
    if (_dismissed) return;
    _controller.stop();
    _dragging = true;
    final next = offset.value + dy;
    // A little give past full height, none past the screen's edge.
    offset.value = next < 0 ? next * 0.25 : math.min(next, dismissAt);
  }

  /// The finger lifted at [velocity] dp/s (positive = downwards).
  ///
  /// Between full and half height the choice is one of those two stops (a hard
  /// flick down from full lands on half, as a sheet's detents do: the second
  /// flick closes). Below half height the sheet either goes away or comes
  /// back to half, or to full on a flick up.
  void release(double velocity) {
    _dragging = false;
    if (_dismissed) return;
    final y = offset.value;
    final projected = y + _project(velocity);
    final half = restHalf;
    final double target;
    if (y <= half) {
      if (velocity > 500) {
        target = half;
      } else if (velocity < -500) {
        target = 0;
      } else {
        target = projected < half / 2 ? 0 : half;
      }
    } else if (velocity < -500) {
      target = 0;
    } else if (projected > half + (dismissAt - half) * 0.45) {
      target = dismissAt;
    } else {
      target = half;
    }
    _goTo(target, velocity);
  }

  /// Moves to full height (a field took focus; a tab wants room).
  void expand() {
    if (_dismissed) return;
    _goTo(0, 0);
  }

  /// Closes: the route slides the sheet away from where it is.
  void dismiss() {
    if (_dismissed) return;
    _dismissed = true;
    _controller.stop();
    onDismiss();
  }

  void _goTo(double target, double velocity) {
    if (target >= dismissAt) {
      dismiss();
      return;
    }
    expanded.value = target == 0;
    if (reduced()) {
      _controller.stop();
      offset.value = target;
      return;
    }
    _controller.value = offset.value;
    unawaited(_controller.animateWith(SpringSimulation(_spring, offset.value, target, velocity)).catchError((Object _) {}));
  }

  /// Apple's projection of a fling: where it would stop with the usual
  /// deceleration.
  static double _project(double velocity) => velocity * 0.25;

  void dispose() {
    _controller.dispose();
    offset.dispose();
    expanded.dispose();
  }
}

/// What a tab needs from the sheet around it.
class SheetScope extends InheritedWidget {
  const SheetScope({super.key, required this.position, required this.bottomClearance, required super.child});

  final SheetPosition position;

  /// Room a scrolling tab keeps at its end: the half-height shift that
  /// hangs below the screen, plus the bars.
  final double bottomClearance;

  static SheetScope of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SheetScope>()!;

  static SheetScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SheetScope>();

  @override
  bool updateShouldNotify(SheetScope old) => old.position != position || old.bottomClearance != bottomClearance;
}

/// A scroll view that belongs to the sheet: it scrolls only at full height
/// (at half height a drag on it moves the sheet), and a drag down from its top
/// pulls the sheet down with the finger, then hands the release to the spring.
class SheetScroll extends StatefulWidget {
  const SheetScroll({super.key, required this.builder, this.controller});

  /// Builds the scroll view with the controller and physics to use.
  final Widget Function(BuildContext context, ScrollController controller, ScrollPhysics physics) builder;

  /// A controller of the tab's own (the gallery tracks its position).
  final ScrollController? controller;

  @override
  State<SheetScroll> createState() => _SheetScrollState();
}

class _SheetScrollState extends State<SheetScroll> {
  late final ScrollController _own = ScrollController();
  ScrollController get _controller => widget.controller ?? _own;

  @override
  void dispose() {
    _own.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    final position = SheetScope.maybeOf(context)?.position;
    if (position == null || n.depth != 0) return false;
    if (n is OverscrollNotification && n.dragDetails != null && n.overscroll < 0) {
      position.dragBy(-n.overscroll);
    } else if (n is ScrollEndNotification && position.offset.value > 0 && position.expanded.value) {
      position.release(n.dragDetails?.velocity.pixelsPerSecond.dy ?? 0);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final position = SheetScope.of(context).position;
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: ValueListenableBuilder<bool>(
        valueListenable: position.expanded,
        builder: (context, expanded, _) => widget.builder(
          context,
          _controller,
          expanded ? const ClampingScrollPhysics() : const NeverScrollableScrollPhysics(),
        ),
      ),
    );
  }
}

/// The route of the attach sheet: a scrim, and a [SheetFrame] that rises over
/// it. Not a Material bottom sheet, because that one resizes its content while
/// it is dragged.
class AttachSheetRoute<T> extends PopupRoute<T> {
  AttachSheetRoute({required this.reduced, required this.content, required this.bars}) : super();

  /// Reduced motion was on when the sheet was opened: it appears and goes
  /// without sliding.
  final bool reduced;

  /// The sheet's body, laid out at full height.
  final WidgetBuilder content;

  /// The tab bar and the action bar, pinned to the bottom edge.
  final WidgetBuilder bars;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => 'Close';

  @override
  Duration get transitionDuration => reduced ? Duration.zero : Motion.sheetIn;

  @override
  Duration get reverseTransitionDuration => reduced ? Duration.zero : Motion.sheetOut;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      SheetFrame(route: this, animation: animation, content: content, bars: bars);
}

/// The scrim, the surface and the pinned bars, moved by [SheetPosition] and
/// the route's animation with transforms only.
class SheetFrame extends StatefulWidget {
  const SheetFrame({super.key, required this.route, required this.animation, required this.content, required this.bars});

  final AttachSheetRoute<Object?> route;
  final Animation<double> animation;
  final WidgetBuilder content;
  final WidgetBuilder bars;

  @override
  State<SheetFrame> createState() => _SheetFrameState();
}

/// Height of the bars region's reserve (the tab bar and the action bar);
/// tabs add it to their end padding via [SheetScope.bottomClearance].
const sheetBarsReserve = 56.0 + 12 + 12 + 56.0;

class _SheetFrameState extends State<SheetFrame> with SingleTickerProviderStateMixin {
  late final SheetPosition _position = SheetPosition(
    vsync: this,
    reduced: () => widget.route.reduced,
    onDismiss: () {
      if (mounted) unawaited(Navigator.of(context).maybePop());
    },
  );

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  /// A tap on the scrim closes the sheet, once it has finished coming up: the
  /// second tap of a double tap on the paperclip lands on the scrim.
  void _tapScrim() {
    if (widget.animation.status == AnimationStatus.completed) _position.dismiss();
  }

  /// The route's progress with the app's curve, both ways: the sheet leaves
  /// fast and settles slowly in either direction.
  double _enter() {
    final a = widget.animation;
    if (a.status == AnimationStatus.reverse) return 1 - Motion.easeOut.transform(1 - a.value);
    return Motion.easeOut.transform(a.value);
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    return LayoutBuilder(
      builder: (context, box) {
        final avail = box.maxHeight - keyboard;
        final full = math.max(200.0, avail - media.padding.top - 8);
        final half = math.min(full, math.max(avail * 0.55, math.min(full, 420.0)));
        _position.layout(full: full, half: half);
        if (keyboard > 0 && !_position.expanded.value) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _position.expand();
          });
        }
        final restHalf = _position.restHalf;
        final clearance = restHalf + sheetBarsReserve + media.padding.bottom;
        // A Material ancestor for the text fields and the default text style
        // (the route is not one); it paints nothing.
        return Material(
          type: MaterialType.transparency,
          child: SheetScope(
          position: _position,
          bottomClearance: clearance,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Scrim: fades with the route and with the sheet's drop.
              AnimatedBuilder(
                animation: Listenable.merge([widget.animation, _position.offset]),
                builder: (context, _) {
                  final drop = (1 - ((_position.offset.value - restHalf) / math.max(1, full - restHalf)).clamp(0.0, 1.0));
                  final alpha = _enter() * drop;
                  return Semantics(
                    label: 'Close',
                    button: true,
                    onTap: _tapScrim,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _tapScrim,
                      excludeFromSemantics: true,
                      child: ColoredBox(color: ds.scrim.withValues(alpha: ds.scrim.a * alpha)),
                    ),
                  );
                },
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: keyboard,
                height: full,
                child: _Body(frame: this, full: full, restHalf: restHalf),
              ),
            ],
          ),
        ),
        );
      },
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.frame, required this.full, required this.restHalf});

  final _SheetFrameState frame;
  final double full;
  final double restHalf;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final position = frame._position;
    final animation = frame.widget.animation;
    // The surface and its content move with the sheet; the bars keep to the
    // screen's bottom edge while the sheet is between half and full height.
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: ds.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
        border: Border(top: BorderSide(color: ds.hairline)),
      ),
      child: Column(
        children: [
          // The grabber is the drag handle everywhere; the whole header is
          // too (a vertical drag on non-scrolling content reaches the frame).
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(color: ds.textTertiary.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(2)),
          ),
          Expanded(child: Builder(builder: frame.widget.content)),
        ],
      ),
    );
    final bars = Builder(builder: frame.widget.bars);
    final moving = Listenable.merge([animation, position.offset]);
    // Entering: from below the screen to where the sheet rests; leaving: from
    // wherever it was to below the screen.
    double sheetY() {
      final enter = frame._enter();
      return position.offset.value + (1 - enter) * (full - position.offset.value);
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: (d) => position.dragBy(d.delta.dy),
      onVerticalDragEnd: (d) => position.release(d.velocity.pixelsPerSecond.dy),
      onVerticalDragCancel: () => position.release(0),
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedBuilder(
            animation: moving,
            child: surface,
            builder: (context, child) => Transform.translate(offset: Offset(0, sheetY()), child: child),
          ),
          AnimatedBuilder(
            animation: moving,
            child: bars,
            builder: (context, child) =>
                Transform.translate(offset: Offset(0, math.max(0.0, sheetY() - restHalf)), child: child),
          ),
        ],
      ),
    );
  }
}
