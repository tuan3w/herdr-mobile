import 'dart:async';

import 'package:flutter/material.dart';

import 'press.dart';
import 'motion.dart';
import 'tokens.dart';

/// The floating pill at the bottom of a screen: the board's batch actions
/// while it picks, and the attach sheet's bars. One slot, one look.
///
/// Slim on purpose: 56 dp tall, at most [maxWidth] wide and centred, so it
/// sits in the thumb's reach without spreading edge to edge over the list it
/// serves.
///
/// The bottom stack is lanes, from the bottom edge up, each present only while
/// it has content: the inset; the Dock ([height]: on home, the batch bar while
/// the board picks, and nothing otherwise); the toast. Every gap is [margin].
/// There was a tab bar in the Dock at rest; it went when Machines and Settings
/// became pages opened from home's header (it cost focus and covered the end
/// of the list). One motion for every lane ([BottomStackTransition]).
abstract final class FloatingBar {
  static const height = 56.0;
  static const pad = 4.0;
  static const cell = height - pad * 2;
  static const margin = 8.0;
  static const side = 12.0;
  static const maxWidth = 312.0;

  /// From the bottom edge to the top of the Dock and its margin: where the
  /// next lane (or a toast) stands.
  static double clearance(BuildContext context) => height + margin * 2 + MediaQuery.paddingOf(context).bottom;

  /// The space a scrolling list keeps free at its end, so its last row can be
  /// read above the Dock.
  static double listEnd(BuildContext context) => clearance(context) + margin;
}

/// Where a [FloatingBarPill] stands: [FloatingBar.margin] above the system
/// inset, [FloatingBar.side] from the edges, centred, at most
/// [FloatingBar.maxWidth] wide. Text stops growing at [kBarTextScale].
///
/// A lane that stands on another lane (not on the screen's bottom edge) sets
/// [aboveInset] false: then only the margin is below it.
class FloatingBarSlot extends StatelessWidget {
  const FloatingBarSlot({super.key, required this.child, this.aboveInset = true});

  final Widget child;
  final bool aboveInset;

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.paddingOf(context);
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: kBarTextScale,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          inset.left + FloatingBar.side,
          0,
          inset.right + FloatingBar.side,
          (aboveInset ? inset.bottom : 0) + FloatingBar.margin,
        ),
        child: Align(
          alignment: Alignment.bottomCenter,
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: FloatingBar.maxWidth),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The pill itself: the surface, a hairline and the one float shadow
/// ([Ds.floatShadow]), no backdrop blur (a full-screen blur pass per frame on
/// mid-range GPUs). [child] is one row of [FloatingBar.cell] height.
class FloatingBarPill extends StatelessWidget {
  const FloatingBarPill({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ds.surface,
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: ds.hairline),
        boxShadow: ds.floatShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.all(FloatingBar.pad),
        child: SizedBox(height: FloatingBar.cell, child: child),
      ),
    );
  }
}

/// Rows fade out into the page just above the floating bar and are gone
/// behind it and the system navigation: the scrim is solid under the pill and
/// the gesture inset, so no text shows beside or below the pill. It is
/// [FloatingBar.clearance] tall: a taller one dimmed what stood above the
/// Dock from its bottom edge up.
///
/// The fading top half lets taps through to the rows that still show in it;
/// the solid half takes them, so nothing hidden beside the pill is tapped by
/// accident.
class FloatingBarScrim extends StatelessWidget {
  const FloatingBarScrim({super.key});

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Column(
      children: [
        Expanded(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Ds.fade(ds.bg, 0), ds.bg],
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTap: () {},
            child: ColoredBox(color: ds.bg),
          ),
        ),
      ],
    );
  }
}

/// How a lane of the bottom stack comes and goes: up from [Motion.travel]
/// with a fade, [Motion.sheetIn]; the reverse, [Motion.sheetOut]. With
/// [slide] false it only fades over [Motion.fade]: the batch bar and the
/// selection header coming and going in their own places. Reduced motion fades.
///
/// The lane keeps one widget structure at rest and in motion (an opaque
/// [Opacity] paints no layer), so the lane's State lives through the end of
/// the transition. Hidden, it is nothing: [builder] runs only while the lane
/// shows, so a hidden lane listens to nothing.
class BottomStackTransition extends StatefulWidget {
  const BottomStackTransition({super.key, required this.visible, required this.builder, this.slide = true});

  final bool visible;
  final bool slide;
  final WidgetBuilder builder;

  @override
  State<BottomStackTransition> createState() => _BottomStackTransitionState();
}

class _BottomStackTransitionState extends State<BottomStackTransition> with SingleTickerProviderStateMixin {
  late final AnimationController _shown = AnimationController(vsync: this, value: widget.visible ? 1 : 0);
  late final ExitCurvedAnimation _curve = Motion.curved(_shown);

  @override
  void didUpdateWidget(BottomStackTransition old) {
    super.didUpdateWidget(old);
    if (old.visible == widget.visible) return;
    final fadeOnly = !widget.slide || Motion.reduced(context);
    _shown
      ..duration = fadeOnly ? Motion.fade : Motion.sheetIn
      ..reverseDuration = fadeOnly ? Motion.fade : Motion.sheetOut;
    if (widget.visible) {
      unawaited(_shown.forward());
    } else {
      unawaited(_shown.reverse());
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _shown.dispose();
    super.dispose();
  }

  // One widget structure at rest and in motion, so the child's State (a
  // RollText, a busy bar) survives the end of the transition. Fully
  // hidden, the child is dropped.
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _curve,
    builder: (context, _) {
      final t = _curve.value;
      if (t <= 0) return const SizedBox.shrink();
      final slide = widget.slide && !Motion.reduced(context);
      return IgnorePointer(
        ignoring: t < 1,
        child: Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, slide ? (1 - t) * Motion.travel : 0),
            child: widget.builder(context),
          ),
        ),
      );
    },
  );
}
