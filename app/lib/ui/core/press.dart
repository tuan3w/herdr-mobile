import 'package:flutter/material.dart';

import 'motion.dart';

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

  @override
  State<PressBuilder> createState() => _PressBuilderState();
}

class _PressBuilderState extends State<PressBuilder> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
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
    if (widget.minTapSize > 0) {
      child = ConstrainedBox(
        constraints: BoxConstraints(minWidth: widget.minTapSize, minHeight: widget.minTapSize),
        child: Align(widthFactor: 1, heightFactor: 1, child: child),
      );
    }
    final isButton = widget.button ?? enabled;
    final label = widget.semanticLabel;
    return Semantics(
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
          onTap: widget.onTap == null
              ? null
              : () {
                  if (widget.haptic) Haptics.tick();
                  widget.onTap!();
                },
          onLongPress: widget.onLongPress == null
              ? null
              : () {
                  Haptics.hold();
                  widget.onLongPress!();
                },
          child: child,
        ),
      ),
    );
  }
}
