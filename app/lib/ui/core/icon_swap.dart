import 'package:flutter/material.dart';

import 'motion.dart';

/// A glyph that changes meaning in place (copy becomes check): the old one
/// fades and shrinks out while the new one fades and grows in, a
/// [Motion.standard] cross-fade, instead of one icon jumping into the other.
/// The one swap for every control whose icon says its state; a glyph that
/// never changes stays a plain `Icon`.
///
/// It scales between [_from] and 1, never lower: nothing in the app grows from
/// below 0.9 (`docs/DESIGN.md`, Motion). Under reduced motion the glyph is
/// replaced at once. Decorative: the control's own semantic label says what
/// changed ("Copied").
class IconSwap extends StatelessWidget {
  const IconSwap({super.key, required this.icon, required this.size, required this.color});

  final IconData icon;
  final double size;
  final Color color;

  static const _from = 0.9;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: Motion.of(context, Motion.standard),
    switchInCurve: Motion.easeOut,
    switchOutCurve: Motion.easeOutExit,
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        scale: Tween<double>(begin: _from, end: 1).animate(animation),
        child: child,
      ),
    ),
    child: Icon(icon, key: ValueKey(icon), size: size, color: color),
  );
}
