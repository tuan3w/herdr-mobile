import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'motion.dart';
import 'sheet_position.dart';
import 'sheets.dart' show SheetGrabber;
import 'tokens.dart';

/// The route of every sheet in the app: a scrim, and a [SheetFrame] that rises
/// over it. Not a Material bottom sheet: that one resizes its content while it
/// is dragged, closes on a fixed timer whatever the speed of the throw, stops
/// dead at full height and cannot be caught once it starts to close.
///
/// The route's own animation only times the route; what is on screen is
/// driven by the frame's [SheetPosition], so a drag, a spring and a close from
/// code always start from where the sheet is.
class SheetRoute<T> extends PopupRoute<T> {
  SheetRoute({required this.reduced, required this.builder, this.fill = false, this.pinnedReserve = 0, super.settings});

  /// Reduced motion was on when the sheet was opened: it appears and goes
  /// without sliding (dragging still follows the finger).
  final bool reduced;

  /// The sheet's content, under the grabber.
  final WidgetBuilder builder;

  /// The content takes the sheet's full height (the attach sheet's tabs)
  /// rather than its own.
  final bool fill;

  /// Height of what the content pins over its bottom edge ([SheetPinned]
  /// bars); a scrolling body keeps it clear ([SheetScope.bottomClearance]).
  final double pinnedReserve;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  @override
  Duration get transitionDuration => reduced ? Duration.zero : Motion.sheetIn;

  @override
  Duration get reverseTransitionDuration => reduced ? Duration.zero : Motion.sheetOut;

  /// A gesture already took the sheet off the screen: pop with nothing left to
  /// animate, so what was under it answers at once.
  void _popGone() {
    if (!isCurrent) return;
    controller?.reverseDuration = Duration.zero;
    navigator?.pop();
  }

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      SheetFrame(route: this);
}

/// The scrim, the sheet's surface and its gestures.
///
/// The content is laid out once ([fill]: at full height; otherwise at its own
/// height, capped below the status bar) and moved with a paint offset, so a
/// drag never lays it out or rebuilds it. A sheet whose content fills all the
/// room it may take ([SheetMath.tall]) opens at half height and is dragged (or
/// scrolled) up to see the rest. The scrim's darkness is derived from where
/// the sheet is, so it is always exactly as faded as the sheet is closed,
/// mid-gesture included.
class SheetFrame extends StatefulWidget {
  const SheetFrame({super.key, required this.route});

  final SheetRoute<Object?> route;

  /// The widest a content-sized sheet grows (Material 3's sheet width): on a
  /// landscape phone it stays a column instead of a strip across the screen.
  /// A [SheetRoute.fill] sheet (the attach sheet's grid) takes the whole width:
  /// capped, its landscape empty state grew taller than the screen.
  static const maxWidth = 640.0;

  /// The gap kept between a full-height sheet and the status bar.
  static const topGap = Gap.sm;

  /// The tallest a sheet grows in [room] with [top] taken by the status bar.
  static double fullHeight({required double room, required double top}) => math.max(200.0, room - top - topGap);

  @override
  State<SheetFrame> createState() => _SheetFrameState();
}

class _SheetFrameState extends State<SheetFrame> with SingleTickerProviderStateMixin {
  late final SheetPosition _position = SheetPosition(
    vsync: this,
    reduced: () => widget.route.reduced,
    onDismiss: widget.route._popGone,
  );
  late final SheetScrollController _scroll = SheetScrollController()..sheet = _position;
  Animation<double>? _animation;

  @override
  void initState() {
    super.initState();
    _animation = widget.route.animation?..addStatusListener(_onRoute);
  }

  @override
  void dispose() {
    _animation?.removeStatusListener(_onRoute);
    _scroll.dispose();
    _position.dispose();
    super.dispose();
  }

  /// Back, a button's `pop` or a tap on the scrim: the sheet slides off from
  /// where it is, as fast as the route closes.
  void _onRoute(AnimationStatus status) {
    if (status == AnimationStatus.reverse) _position.close();
  }

  void _tapScrim() {
    if (_position.settledIn) unawaited(Navigator.of(context).maybePop());
  }

  /// A finger landing stops whatever moves the sheet, where it is.
  void _down(PointerDownEvent _) => _position.grab();

  /// ...and lifting it without a drag puts the sheet back on a stop.
  void _up(PointerEvent _) {
    if (_position.needsSettle) _position.release(0);
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final route = widget.route;
    var clearance = 0.0;
    if (route.fill) {
      final room = media.size.height - keyboard;
      final full = SheetFrame.fullHeight(room: room, top: media.padding.top);
      clearance = full - SheetMath.half(room: room, full: full) + route.pinnedReserve + media.padding.bottom;
    }
    if (keyboard > 0 && _position.restHalf > 0 && !_position.expanded.value) {
      // The keyboard needs the room: the sheet goes to full height.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _position.expand();
      });
    }
    final position = _position;
    // A Material ancestor for text fields and the default text style (the
    // route is not one); it paints nothing.
    return Material(
      type: MaterialType.transparency,
      child: SheetScope(
        position: position,
        scroll: _scroll,
        bottomClearance: clearance,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Semantics(
              label: 'Close',
              button: true,
              onTap: _tapScrim,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _tapScrim,
                excludeFromSemantics: true,
                child: CustomPaint(painter: _ScrimPainter(position, ds.scrim)),
              ),
            ),
            _SheetPlace(
              position: position,
              keyboard: keyboard,
              top: media.padding.top,
              fill: route.fill,
              skirt: ds.surface,
              onFirstLayout: () => position.enter(route.animation!),
              child: RepaintBoundary(
                child: Listener(
                  onPointerDown: _down,
                  onPointerUp: _up,
                  onPointerCancel: _up,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragStart: (_) => position.grab(),
                    onVerticalDragUpdate: (d) => position.dragBy(d.primaryDelta ?? 0),
                    onVerticalDragEnd: (d) => position.release(d.primaryVelocity ?? 0),
                    onVerticalDragCancel: () {
                      if (position.dragging) position.release(0);
                    },
                    child: SheetSurface(
                      fill: route.fill,
                      child: MediaQuery.removePadding(
                        context: context,
                        removeTop: true,
                        child: Builder(builder: route.builder),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The sheet itself: the raised surface with its rounded top and the
/// [SheetGrabber] above [child]. The grabber is the drag handle; so is every
/// part of the sheet that does not scroll.
class SheetSurface extends StatelessWidget {
  const SheetSurface({super.key, required this.fill, required this.child});

  final bool fill;
  final Widget child;

  /// The grabber strip at the sheet's top (its gap and the bar), above [child].
  static const grabberSpace = Gap.sm + SheetGrabber.height;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: context.ds.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(Radii.lg)),
    ),
    child: Column(
      mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
      children: [
        const SizedBox(height: Gap.sm),
        const SheetGrabber(),
        if (fill) Expanded(child: child) else Flexible(child: child),
      ],
    ),
  );
}

/// Keeps [child] (the bottom of a sheet's content: its buttons, the attach
/// sheet's bars) on the screen's bottom edge while a tall sheet rests at half
/// height or is dragged between half and full; below half it leaves with the
/// sheet. Without it the buttons of a tall sheet would hang below the screen
/// until the sheet is dragged up: a dead end. With [color], it also fills
/// below itself, so the content it covers does not peek out under it.
class SheetPinned extends SingleChildRenderObjectWidget {
  const SheetPinned({super.key, this.color, required super.child});

  final Color? color;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderSheetPinned(
    position: SheetScope.maybeOf(context)?.position,
    color: color,
    reach: MediaQuery.sizeOf(context).height,
  );

  @override
  void updateRenderObject(BuildContext context, RenderSheetPinned renderObject) => renderObject
    ..position = SheetScope.maybeOf(context)?.position
    ..color = color
    ..reach = MediaQuery.sizeOf(context).height;
}

/// The render object of [SheetPinned].
class RenderSheetPinned extends RenderProxyBox {
  RenderSheetPinned({this._position, this._color, required this._reach});

  SheetPosition? _position;
  set position(SheetPosition? value) {
    if (value == _position) return;
    if (attached) _position?.offset.removeListener(markNeedsPaint);
    _position = value;
    if (attached) _position?.offset.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  Color? _color;
  set color(Color? value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  /// How far below itself the fill goes: to the screen's edge from anywhere.
  double _reach;
  set reach(double value) {
    if (value == _reach) return;
    _reach = value;
    markNeedsPaint();
  }

  /// How far up it is moved: as far as the sheet hangs below its full place,
  /// down to half height.
  double get _lift {
    final p = _position;
    if (p == null) return 0;
    return p.offset.value.clamp(0.0, p.restHalf);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _position?.offset.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _position?.offset.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final at = offset.translate(0, -_lift);
    final color = _color;
    if (color != null) {
      context.canvas.drawRect(at & Size(size.width, size.height + _reach), Paint()..color = color);
    }
    super.paint(context, at);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) => result.addWithPaintOffset(
    offset: Offset(0, -_lift),
    position: position,
    hitTest: (result, position) => super.hitTest(result, position: position),
  );

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) => transform.translateByDouble(0, -_lift, 0, 1);
}

/// The scrim: as dark as the sheet is open, from its lowest resting place to
/// off the screen.
class _ScrimPainter extends CustomPainter {
  _ScrimPainter(this.position, this.color) : super(repaint: position.offset);

  final SheetPosition position;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rest = position.restHalf;
    final away = position.dismissAt;
    final open = away <= rest ? 1.0 : 1 - ((position.offset.value - rest) / (away - rest)).clamp(0.0, 1.0);
    if (open <= 0) return;
    canvas.drawRect(Offset.zero & size, Paint()..color = Color.lerp(color.withAlpha(0), color, open)!);
  }

  @override
  bool shouldRepaint(_ScrimPainter old) => old.position != position || old.color != color;
}

/// Lays the sheet out once, at the bottom of the room above the keyboard, and
/// moves it by [SheetPosition.offset] when it paints.
class _SheetPlace extends SingleChildRenderObjectWidget {
  const _SheetPlace({
    required this.position,
    required this.keyboard,
    required this.top,
    required this.fill,
    required this.skirt,
    required this.onFirstLayout,
    required super.child,
  });

  final SheetPosition position;
  final double keyboard;
  final double top;
  final bool fill;
  final Color skirt;
  final VoidCallback onFirstLayout;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSheetPlace(
    position: position,
    keyboard: keyboard,
    top: top,
    fill: fill,
    skirt: skirt,
    onFirstLayout: onFirstLayout,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderSheetPlace renderObject) => renderObject
    ..keyboard = keyboard
    ..top = top
    ..fill = fill
    ..skirt = skirt;
}

class _RenderSheetPlace extends RenderBox with RenderObjectWithChildMixin<RenderBox> {
  _RenderSheetPlace({
    required this.position,
    required this._keyboard,
    required this._top,
    required this._fill,
    required this._skirt,
    required this.onFirstLayout,
  });

  final SheetPosition position;
  final VoidCallback onFirstLayout;
  var _laidOut = false;

  /// Where the sheet's top-left is when it rests at full height.
  var _base = Offset.zero;

  double _keyboard;
  set keyboard(double value) {
    if (value == _keyboard) return;
    _keyboard = value;
    markNeedsLayout();
  }

  double _top;
  set top(double value) {
    if (value == _top) return;
    _top = value;
    markNeedsLayout();
  }

  bool _fill;
  set fill(bool value) {
    if (value == _fill) return;
    _fill = value;
    markNeedsLayout();
  }

  /// The surface's colour, painted under the sheet while it is stretched
  /// above full height, so no gap opens at the bottom edge.
  Color _skirt;
  set skirt(Color value) {
    if (value == _skirt) return;
    _skirt = value;
    markNeedsPaint();
  }

  Offset get _childOffset => _base.translate(0, position.offset.value);

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    position.offset.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    position.offset.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    final child = this.child;
    if (child == null) return;
    final room = size.height - _keyboard;
    final cap = SheetFrame.fullHeight(room: room, top: _top);
    final width = _fill ? size.width : math.min(size.width, SheetFrame.maxWidth);
    child.layout(
      BoxConstraints.tightFor(width: width).copyWith(minHeight: _fill ? cap : 0, maxHeight: cap),
      parentUsesSize: true,
    );
    final full = child.size.height;
    final tall = _fill || SheetMath.tall(full: full, cap: cap);
    position.layout(
      full: full,
      half: tall ? SheetMath.half(room: room, full: full) : null,
    );
    _base = Offset((size.width - width) / 2, room - full);
    if (!_laidOut) {
      _laidOut = true;
      onFirstLayout();
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final at = offset + _childOffset;
    final stretched = -position.offset.value;
    if (stretched > 0) {
      context.canvas.drawRect(
        // From a pixel inside the sheet (it paints over it), so no seam shows.
        Rect.fromLTWH(at.dx, at.dy + child.size.height - 1, child.size.width, stretched + 1),
        Paint()..color = _skirt,
      );
    }
    context.paintChild(child, at);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintOffset(
      offset: _childOffset,
      position: position,
      hitTest: (result, position) => child.hitTest(result, position: position),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final o = _childOffset;
    transform.translateByDouble(o.dx, o.dy, 0, 1);
  }
}
