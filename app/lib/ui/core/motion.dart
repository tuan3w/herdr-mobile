import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Motion tokens. UI motion stays under ~300ms and uses strong ease-out curves:
/// built-in curves are too weak, and ease-in delays the moment the user is
/// watching most closely.
abstract final class Motion {
  /// Entering / responding to input. Starts fast, settles gently.
  static const easeOut = Cubic(0.23, 1, 0.32, 1);

  /// Elements that move or morph while staying on screen.
  static const easeInOut = Cubic(0.77, 0, 0.175, 1);

  /// Press-down feedback: snap in.
  static const press = Duration(milliseconds: 100);

  /// Release: slightly slower than the press, so the response never feels abrupt.
  static const release = Duration(milliseconds: 180);

  /// Default for state changes (colour, size of small elements).
  static const standard = Duration(milliseconds: 200);

  /// Expanding/collapsing sections.
  static const expand = Duration(milliseconds: 220);

  /// Honour the platform's reduced-motion setting: drop movement, keep
  /// colour/opacity changes.
  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  /// Animation style for `ExpansionTile`, whose default is ease-in.
  static const expansion = AnimationStyle(
    curve: easeOut,
    reverseCurve: easeOut,
    duration: expand,
    reverseDuration: expand,
  );
}

/// Confirms the interface heard a touch: the child scales down slightly while
/// pressed. Interruptible (retargets from the current scale) and transform-only.
/// Does not take part in the gesture arena, so the child's own tap handling is
/// untouched.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.scale = 0.98});

  final Widget child;

  /// Scale while pressed. Large surfaces (cards) need a gentler value than buttons.
  final double scale;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final active = _down && !Motion.reduced(context);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: active ? widget.scale : 1,
        duration: _down ? Motion.press : Motion.release,
        curve: Motion.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// Light tap feedback shared by list rows.
void tapFeedback() => HapticFeedback.selectionClick();
