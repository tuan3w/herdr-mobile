import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'motion.dart';
import 'tokens.dart';

/// Smallest comfortable touch target (dp). Controls that paint smaller than
/// this still hit-test at least this big.
const kMinTap = 44.0;

/// Where chrome bars stop growing with the system text size: their blocks
/// are fixed height, and the batch bar's three cells hold their names at
/// 320 dp at this.
const kBarTextScale = 1.15;

/// Press handling shared by every control: feedback on pointer-down, at once
/// (the gesture arena would hold `onTapDown` for 100 ms inside a list, and a tap
/// quicker than that would report its down and up together and show nothing),
/// commit on up, cancel by dragging away. A scroll that takes over cancels the
/// press, so a list shows at most a faint tint for the first moments of a
/// scroll. No ripple. Optional press scale.
///
/// Keyboard (a hardware keyboard on a tablet, Chromebook or desktop): a control
/// with an [onTap] takes a place in the Tab order, Enter and Space press it, and
/// a 2 dp accent ring marks it while the person is using the keyboard (never
/// after a touch). A hold ([onLongPress]) has no key, so a control with only a
/// hold is not a stop. Nothing about touch changes.
///
/// Semantics (one node per control, never duplicated):
/// - [semanticLabel] null (default): the visible text inside [builder] merges
///   into one label. Use this wherever the child already says what it is.
/// - [semanticLabel] set: it REPLACES everything inside, so icon-only controls
///   and rows with a hand-composed label say it exactly once.
/// - The button role is announced only when the control can be tapped (or
///   [button] says so, for dimmed buttons). A plain label stays plain text.
/// - [selected] adds the selected state (tabs, segments, filter chips).
class PressBuilder extends StatefulWidget {
  const PressBuilder({
    super.key,
    required this.builder,
    this.onTap,
    this.onLongPress,
    this.scale = 1,
    this.haptic = false,
    this.semanticLabel,
    this.selected,
    this.button,
    this.minTapSize = 0,
  });

  final Widget Function(BuildContext context, bool pressed) builder;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Scale while pressed (1 = none). Small controls use ~0.96, rows none.
  final double scale;

  /// Selection haptic on tap.
  final bool haptic;
  final String? semanticLabel;

  /// Selected state for toggles, tabs and segments; null for plain buttons.
  final bool? selected;

  /// Announce as a button. Defaults to "can be tapped"; a disabled
  /// [AppButton] passes true so it reads as a dimmed button.
  final bool? button;

  /// Minimum width and height of the touch target. The painted child keeps its
  /// size and is centred inside it.
  final double minTapSize;

  /// Keys the focus ring's paint box, for tests to find it by.
  static const focusRingKey = ValueKey<String>('press.focusRing');

  @override
  State<PressBuilder> createState() => _PressBuilderState();
}

class _PressBuilderState extends State<PressBuilder> {
  bool _down = false;

  /// Reachable by keyboard only when a tap does something: a control with no
  /// action (or only a hold, which has no key) would be a dead stop.
  late final FocusNode _node = FocusNode(
    debugLabel: 'PressBuilder',
    canRequestFocus: widget.onTap != null,
    onKeyEvent: _key,
  )..addListener(_focusChanged);

  /// The ring is drawn: this control has the focus AND the person is using a
  /// keyboard. A touch flips the highlight mode back, and the ring goes with it.
  bool _ring = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_highlightModeChanged);
  }

  @override
  void didUpdateWidget(PressBuilder old) {
    super.didUpdateWidget(old);
    _node.canRequestFocus = widget.onTap != null;
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_highlightModeChanged);
    _node
      ..removeListener(_focusChanged)
      ..dispose();
    super.dispose();
  }

  void _focusChanged() => _showRing();

  void _highlightModeChanged(FocusHighlightMode mode) => _showRing();

  void _showRing() {
    final next = _node.hasPrimaryFocus && FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    if (next != _ring && mounted) setState(() => _ring = next);
  }

  void _tap() {
    if (widget.haptic) Haptics.tick();
    widget.onTap!();
  }

  /// Enter and Space press the control. Only while it holds the focus itself:
  /// the same key from a field inside it (a space typed) bubbles up here and
  /// is not ours. A key held down presses once, not once per repeat.
  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (!node.hasPrimaryFocus || widget.onTap == null) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter && key != LogicalKeyboardKey.numpadEnter && key != LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) _tap();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    final active = _down && enabled;
    Widget child = widget.builder(context, active);
    if (widget.scale != 1 && !Motion.reduced(context)) {
      child = AnimatedScale(
        scale: active ? widget.scale : 1,
        duration: Motion.pressing(_down),
        curve: Motion.easeOut,
        child: child,
      );
    }
    // Always in the tree, painting only while focused by keyboard: adding it
    // on focus would remount the child (and restart its animations).
    child = CustomPaint(
      key: PressBuilder.focusRingKey,
      foregroundPainter: _ring
          ? _FocusRing(Theme.of(context).extension<Ds>() ?? Ds.paper, context.findRenderObject)
          : null,
      child: child,
    );
    if (widget.minTapSize > 0) {
      child = ConstrainedBox(
        constraints: BoxConstraints(minWidth: widget.minTapSize, minHeight: widget.minTapSize),
        child: Align(widthFactor: 1, heightFactor: 1, child: child),
      );
    }
    final isButton = widget.button ?? enabled;
    final label = widget.semanticLabel;
    // `includeSemantics: false`: the focus node adds no semantics of its own,
    // so the control stays the one node it was.
    return Focus(
      focusNode: _node,
      includeSemantics: false,
      child: Semantics(
        button: isButton,
        enabled: isButton ? enabled : null,
        selected: widget.selected,
        label: label,
        excludeSemantics: label != null,
        // Assistive-tech activation goes straight to the callbacks; the gesture
        // detector below is pointer-only so it adds no second semantics node.
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: enabled ? (_) => _set(true) : null,
          onPointerUp: enabled ? (_) => _set(false) : null,
          onPointerCancel: enabled ? (_) => _set(false) : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTapCancel: enabled ? () => _set(false) : null,
            onTap: widget.onTap == null ? null : _tap,
            onLongPress: widget.onLongPress == null
                ? null
                : () {
                    Haptics.hold();
                    widget.onLongPress!();
                  },
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The keyboard focus ring: 2 dp in the accent, inside the painted shape and
/// following its corners, so it never reaches into a neighbour or past a
/// scroll edge. The shape is the control's own: the first rounded, decorated
/// box inside it that fills most of it (a row's highlight, a chip's pill, a
/// key's cap), found while painting because a control builds anything. With
/// none, it is the whole child with the small radius. On a filled accent
/// control (the primary button) the ring would vanish into the fill, so it
/// takes `onAccent`.
class _FocusRing extends CustomPainter {
  _FocusRing(this.ds, this.root);

  final Ds ds;

  /// The control's render object, to look its painted shape up in.
  final RenderObject? Function() root;

  static const _stroke = 2.0;

  /// A decorated box smaller than this share of the child is a detail inside
  /// it (a dot, a badge), not its shape.
  static const _shareOfChild = 0.6;

  @override
  void paint(Canvas canvas, Size size) {
    var rect = Offset.zero & size;
    var radius = Radii.sm;
    var color = ds.accent;
    final shape = _paintedShape(size);
    if (shape != null) {
      rect = shape.rect;
      radius = shape.radius;
      color = _distinct(color, shape.fill, ds.onAccent);
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(_stroke / 2), Radius.circular(radius)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..color = color,
    );
  }

  /// [ring], or [alternative] when it would not stand out from [fill].
  static Color _distinct(Color ring, Color? fill, Color alternative) {
    if (fill == null || fill.a < 0.5) return ring;
    final a = ring.computeLuminance(), b = fill.computeLuminance();
    final ratio = (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
    return ratio < 1.5 ? alternative : ring;
  }

  _Shape? _paintedShape(Size size) {
    RenderCustomPaint? host;
    void findHost(RenderObject o) {
      if (host != null) return;
      if (o is RenderCustomPaint && o.foregroundPainter == this) {
        host = o;
      } else {
        o.visitChildren(findHost);
      }
    }

    root()?.visitChildren(findHost);
    final hostBox = host;
    if (hostBox == null) return null;

    _Shape? found;
    void findShape(RenderObject o) {
      if (found != null) return;
      if (o is RenderDecoratedBox && o.position == DecorationPosition.background && o.hasSize) {
        final d = o.decoration;
        if (d is BoxDecoration &&
            d.borderRadius is BorderRadius &&
            o.size.width >= size.width * _shareOfChild &&
            o.size.height >= size.height * _shareOfChild) {
          final rect = MatrixUtils.transformRect(o.getTransformTo(hostBox), Offset.zero & o.size);
          found = _Shape(rect, (d.borderRadius! as BorderRadius).topLeft.x, d.color);
          return;
        }
      }
      o.visitChildren(findShape);
    }

    hostBox.visitChildren(findShape);
    return found;
  }

  @override
  bool shouldRepaint(_FocusRing old) => old.ds != ds;
}

class _Shape {
  const _Shape(this.rect, this.radius, this.fill);

  final Rect rect;
  final double radius;
  final Color? fill;
}
