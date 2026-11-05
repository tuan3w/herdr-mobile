import 'package:flutter/material.dart';

import 'motion.dart';
import 'theme.dart';
import 'press.dart';
import 'spinner.dart';

enum AppButtonKind { primary, secondary, ghost, danger }

/// Flat button: 9px radius, no elevation, no ripple. [compact] paints 36 high
/// but still takes a 44 touch target.
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.kind = AppButtonKind.primary,
    this.expand = false,
    this.loading = false,
    this.compact = false,
  });

  final String label;

  /// Null disables the button.
  final VoidCallback? onPressed;
  final IconData? icon;
  final AppButtonKind kind;
  final bool expand;

  /// Shows a spinner and ignores taps.
  final bool loading;

  /// Smaller (36px painted, 44px touch) for inline use in banners and rows.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final (bg, fg, pressedBg) = switch (kind) {
      AppButtonKind.primary => (ds.accent, ds.onAccent, ds.accentPressed),
      AppButtonKind.secondary => (ds.fill, ds.text, ds.fillPressed),
      AppButtonKind.ghost => (Colors.transparent, ds.accentText, ds.fill),
      AppButtonKind.danger => (ds.wash(ds.danger), ds.dangerText, ds.washPressed(ds.danger)),
    };
    final enabled = onPressed != null && !loading;
    final dimmed = onPressed == null && !loading;
    final h = compact ? 36.0 : 46.0;
    return PressBuilder(
      onTap: enabled ? onPressed : null,
      scale: 0.97,
      haptic: kind == AppButtonKind.primary,
      button: true,
      minTapSize: kMinTap,
      // Dimming is baked into the colours: an Opacity layer here would cost a
      // composited layer per button for a state that is almost always off.
      builder: (context, pressed) => TweenAnimationBuilder<double>(
        tween: Tween(end: dimmed ? 0.4 : 1),
        duration: Motion.standard,
        builder: (context, k, _) {
          Color dim(Color c) => Ds.fade(c, k);
          return AnimatedContainer(
            duration: Motion.pressing(pressed),
            curve: Motion.easeOut,
            height: h,
            width: expand ? double.infinity : null,
            padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 18),
            decoration: BoxDecoration(
              color: dim(pressed ? pressedBg : bg),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (loading)
                  BusySpinner(color: dim(fg))
                else if (icon != null)
                  Icon(icon, size: compact ? IconSize.row : IconSize.bar, color: dim(fg)),
                if (loading || icon != null) const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: (compact ? Type.buttonCompact : Type.button).copyWith(color: dim(fg)),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Round icon button, 40px painted (44px touch): the Notion header control. A
/// soft tinted disc with no outline (a ring around every header icon is the
/// loudest repeated line on a screen); [filled] false is a bare icon.
class CircleButton extends StatelessWidget {
  const CircleButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.size = 40,
    this.active = false,
    this.filled = true,
    this.onLongPress,
    this.mark = false,
    this.markLabel = '',
  });

  final IconData icon;
  final VoidCallback? onPressed;

  /// A second action on a hold (the web preview's back arrow lists the pages
  /// of the visit). The hold is the button's own, so its tooltip stays off it.
  final VoidCallback? onLongPress;
  final String tooltip;
  final double size;

  /// A circle inside a field or a row: 36, in a 44 hit area.
  static const compact = 36.0;

  /// Toggled-on state (accent tint).
  final bool active;

  /// Draw the soft disc; false for a bare icon.
  final bool filled;

  /// A small plain dot in the accent on the disc's corner: something behind
  /// the button is worth a look and nothing needs the person (a newer version
  /// behind Settings). Never a count: the loud colour is for a question.
  /// [markLabel] is its meaning for screen readers.
  final bool mark;
  final String markLabel;

  /// The mark's size; its ring is the page's colour, so it reads cut out of
  /// the disc.
  static const _dot = 10.0;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Tooltip(
      message: tooltip,
      // The press node below carries the label; the tooltip would add a second.
      excludeFromSemantics: true,
      triggerMode: onLongPress == null ? null : TooltipTriggerMode.manual,
      child: PressBuilder(
        onTap: onPressed,
        onLongPress: onLongPress,
        scale: PressScale.icon,
        semanticLabel: mark ? '$tooltip, $markLabel' : tooltip,
        button: true,
        selected: active ? true : null,
        minTapSize: kMinTap,
        builder: (context, pressed) => _withMark(
          ds,
          AnimatedContainer(
            duration: Motion.pressing(pressed),
            curve: Motion.easeOut,
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active
                  ? ds.accentWash
                  : filled
                  ? (pressed ? ds.fillPressed : ds.fill)
                  : (pressed ? ds.fill : Colors.transparent),
            ),
            alignment: Alignment.center,
            // A disabled button keeps its disc; the icon fades to decoration.
            child: Icon(
              icon,
              size: size * 0.5,
              color: onPressed == null ? ds.textTertiary : (active ? ds.accentText : ds.text),
            ),
          ),
        ),
      ),
    );
  }

  Widget _withMark(Ds ds, Widget disc) {
    if (!mark) return disc;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        disc,
        Positioned(
          right: 0,
          top: 0,
          child: Container(
            key: const ValueKey('circle-button-mark'),
            width: _dot,
            height: _dot,
            decoration: BoxDecoration(
              color: ds.accent,
              shape: BoxShape.circle,
              border: Border.all(color: ds.bg, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}
