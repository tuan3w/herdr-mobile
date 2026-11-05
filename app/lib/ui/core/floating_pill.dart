import 'package:flutter/material.dart';

import 'motion.dart';
import 'press.dart';
import 'roll_text.dart';
import 'theme.dart';

enum FloatingPillSize {
  /// 44 high: a pill in the bottom stack.
  regular,

  /// 36 high in a 44 dp target: a pill over content (jump to latest,
  /// changed on disk).
  compact,
}

/// A small floating control over content or above the bars: jump to latest,
/// changed on disk. The floating lanes' look (surface,
/// hairline, the one float shadow, round ends) so it reads as furniture, not
/// content; a tap presses it a little.
///
/// Its parts, each optional: [icon] (or a [leading] widget such as a status
/// glyph or a spinner), [label] with a quieter [detail] after it (`2 need you
/// · 1 to review`; the label rolls when it changes), and a [trailing] widget.
/// An [icon] alone draws a round button.
///
/// [visible] brings it in and out: a fade and a scale from
/// [Motion.enterScale] over [Motion.release] (a fade only under reduced
/// motion). On its way out it keeps what it last said, and once gone it takes
/// no room, no touches and says nothing.
class FloatingPill extends StatefulWidget {
  const FloatingPill({
    super.key,
    this.icon,
    this.leading,
    this.label,
    this.detail,
    this.trailing,
    required this.onTap,
    this.size = FloatingPillSize.regular,
    this.semanticLabel,
    this.tooltip,
    this.haptic = true,
    this.visible = true,
    this.roll = false,
  });

  final IconData? icon;
  final Widget? leading;
  final String? label;

  /// Quieter words after [label], after a middle dot.
  final String? detail;
  final Widget? trailing;

  /// Null while it cannot be tapped (it is busy).
  final VoidCallback? onTap;
  final FloatingPillSize size;

  /// What a screen reader says in place of the visible words.
  final String? semanticLabel;

  /// Shown on a long press (not announced: [semanticLabel] says it).
  final String? tooltip;

  /// The selection tick on tap. Off when the owner fires its own.
  final bool haptic;
  final bool visible;

  /// The label rolls when it changes ([RollText]): for a count that is news
  /// (an unread count), not for one that ticks with output.
  final bool roll;

  static const regularHeight = kMinTap;
  static const compactHeight = 36.0;

  @override
  State<FloatingPill> createState() => _FloatingPillState();
}

class _FloatingPillState extends State<FloatingPill> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: Motion.release, value: widget.visible ? 1 : 0);
  late final _curve = Motion.curved(_controller);
  late final _scale = Tween<double>(begin: Motion.enterScale, end: 1).animate(_curve);

  /// What it last said while visible: drawn while it fades out.
  late FloatingPill _shown = widget;

  @override
  void didUpdateWidget(FloatingPill old) {
    super.didUpdateWidget(old);
    if (widget.visible) _shown = widget;
    if (widget.visible != old.visible) {
      if (widget.visible) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) {
      final visible = widget.visible;
      if (!visible && _controller.isDismissed) return const SizedBox.shrink();
      final pill = _pill(context, _shown);
      return ExcludeSemantics(
        excluding: !visible,
        child: IgnorePointer(
          ignoring: !visible,
          child: FadeTransition(
            opacity: _curve,
            child: Motion.reduced(context) ? pill : ScaleTransition(scale: _scale, child: pill),
          ),
        ),
      );
    },
  );

  Widget _pill(BuildContext context, FloatingPill w) {
    final ds = context.ds;
    final regular = w.size == FloatingPillSize.regular;
    final height = regular ? FloatingPill.regularHeight : FloatingPill.compactHeight;
    final label = w.label;
    final detail = w.detail;
    final round = label == null && w.leading == null && w.trailing == null;
    final style = Type.labelStrong.copyWith(color: ds.text, fontFeatures: Type.tabular);
    final tail = detail == null
        ? null
        : TextSpan(
            text: ' · $detail',
            style: Type.label.copyWith(color: ds.textSecondary),
          );
    final parts = <Widget>[
      if (w.icon != null) Icon(w.icon, size: round ? IconSize.bar : IconSize.row, color: ds.textSecondary),
      ?w.leading,
      if (label != null)
        Flexible(
          child: w.roll
              ? RollText(text: label, style: style, trailing: tail)
              : Text.rich(
                  TextSpan(text: label, style: style, children: [?tail]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
        ),
      ?w.trailing,
    ];
    Widget pill = PressBuilder(
      onTap: w.onTap,
      haptic: w.haptic,
      scale: PressScale.button,
      button: true,
      semanticLabel: w.semanticLabel,
      minTapSize: kMinTap,
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        // Never narrower than tall: an icon alone (no padding) is a circle,
        // and the constraints stay finite when the content changes.
        constraints: BoxConstraints.tightFor(height: height).copyWith(minWidth: height),
        padding: round ? EdgeInsets.zero : EdgeInsets.symmetric(horizontal: regular ? Gap.lg : Gap.md),
        decoration: BoxDecoration(
          color: pressed ? ds.fill : ds.surface,
          borderRadius: BorderRadius.circular(Radii.pill),
          border: Border.all(color: ds.hairline),
          boxShadow: ds.floatShadow,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final (i, p) in parts.indexed) ...[if (i > 0) const SizedBox(width: Gap.sm), p],
          ],
        ),
      ),
    );
    if (w.tooltip case final tip?) {
      pill = Tooltip(message: tip, excludeFromSemantics: true, child: pill);
    }
    // A fixed-height pill: its words grow only as far as the bars' do.
    return MediaQuery.withClampedTextScaling(maxScaleFactor: kBarTextScale, child: pill);
  }
}
