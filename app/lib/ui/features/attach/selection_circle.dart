import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';

/// The round selection mark of a tile or a row: an empty ring, or, when
/// picked, the accent filled with the pick's place (1, 2, 3...).
///
/// Painted 24 dp, hit-tested [kMinTap] around its centre. The press and the
/// change are feedback on the circle itself: it presses to 0.9 and a new
/// number pops in from 0.9 to 1 over `Motion.press`. On a photo the empty ring
/// is white on a dark wash so it reads on any picture; on a row ([onPhoto]
/// false) it is the quiet outline of the design system.
class SelectionCircle extends StatelessWidget {
  const SelectionCircle({
    super.key,
    required this.number,
    required this.onTap,
    required this.label,
    this.onPhoto = false,
  });

  /// 1-based place in the tray; null when not picked.
  final int? number;
  final VoidCallback onTap;

  /// What a screen reader says: `Select photo 12`, `Deselect photo 12`.
  final String label;
  final bool onPhoto;

  static const size = 24.0;

  @override
  Widget build(BuildContext context) {
    final reduced = Motion.reduced(context);
    final mark = SelectionMark(number: number, onPhoto: onPhoto);
    return PressBuilder(
      onTap: onTap,
      haptic: true,
      scale: 0.9,
      minTapSize: kMinTap,
      semanticLabel: label,
      selected: number != null,
      builder: (context, pressed) => reduced ? mark : _Pop(number: number, child: mark),
    );
  }
}

/// Just the painted mark (no touch target): for places that bring their own.
class SelectionMark extends StatelessWidget {
  const SelectionMark({super.key, required this.number, this.onPhoto = false});

  final int? number;
  final bool onPhoto;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final picked = number != null;
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: picked ? ds.accent : (onPhoto ? const Color(0x59000000) : Colors.transparent),
        border: Border.all(color: picked ? ds.onAccent.withValues(alpha: 0.9) : (onPhoto ? Colors.white : ds.textTertiary), width: 1.5),
      ),
      child: SizedBox.square(
        dimension: SelectionCircle.size,
        child: picked
            ? Center(
                child: Text(
                  '$number',
                  style: TextStyle(
                    fontFamily: Type.family,
                    fontSize: 12.5,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    fontFeatures: Type.tabular,
                    color: ds.onAccent,
                  ),
                ),
              )
            : null,
      ),
    );
  }
}

/// Scales its child from 0.9 to 1 over `Motion.press` when [number] changes
/// (not when it first appears: a scrolled-in tile does not animate). The
/// controller exists only after the first change.
class _Pop extends StatefulWidget {
  const _Pop({required this.number, required this.child});

  final int? number;
  final Widget child;

  @override
  State<_Pop> createState() => _PopState();
}

class _PopState extends State<_Pop> with SingleTickerProviderStateMixin {
  AnimationController? _c;

  @override
  void didUpdateWidget(_Pop old) {
    super.didUpdateWidget(old);
    if (old.number == widget.number) return;
    _c ??= AnimationController(vsync: this, duration: Motion.press);
    unawaited(_c!.forward(from: 0).catchError((Object _) {}));
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null) return widget.child;
    return AnimatedBuilder(
      animation: c,
      child: widget.child,
      builder: (context, child) =>
          c.isAnimating ? Transform.scale(scale: 0.9 + 0.1 * Motion.easeOut.transform(c.value), child: child) : child!,
    );
  }
}
