import 'package:flutter/widgets.dart';

import 'motion.dart';

/// Plays one small scale pop when [value] goes up, for a count that brings
/// news (a badge, the triage pill). Once and still: no loop, nothing at rest,
/// nothing when the count goes down or the widget first appears. Transform
/// only. Reduced motion skips it.
class PopOnRise extends StatefulWidget {
  const PopOnRise({super.key, required this.value, required this.child, this.alignment = Alignment.center});

  final int value;
  final Widget child;

  /// The point the pop grows from.
  final Alignment alignment;

  @override
  State<PopOnRise> createState() => _PopOnRiseState();
}

class _PopOnRiseState extends State<PopOnRise> with SingleTickerProviderStateMixin {
  // Created on the first rise, like the status glyph's: a count that never
  // rises carries one null field.
  AnimationController? _controller;

  static final _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.22).chain(CurveTween(curve: Motion.easeOut)), weight: 35),
    TweenSequenceItem(tween: Tween(begin: 1.22, end: 1.0).chain(CurveTween(curve: Motion.easeOut)), weight: 65),
  ]);

  @override
  void didUpdateWidget(PopOnRise old) {
    super.didUpdateWidget(old);
    if (widget.value <= old.value || Motion.reduced(context)) return;
    (_controller ??= AnimationController(vsync: this, duration: Motion.settle)).forward(from: 0);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return widget.child;
    return ScaleTransition(scale: _scale.animate(controller), alignment: widget.alignment, child: widget.child);
  }
}
