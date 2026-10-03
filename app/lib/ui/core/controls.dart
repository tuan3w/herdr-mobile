import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'motion.dart';
import 'theme.dart';

/// Smallest comfortable touch target (dp). Controls that paint smaller than
/// this still hit-test at least this big.
const kMinTap = 44.0;

/// Press handling shared by every control: feedback on pointer-down (after the
/// scroll-intent delay, so scrolling a list never flashes rows), commit on up,
/// cancel by dragging away. No ripple. Optional press scale.
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
        constraints: BoxConstraints(
          minWidth: widget.minTapSize,
          minHeight: widget.minTapSize,
        ),
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
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTapDown: enabled ? (_) => _set(true) : null,
        onTapUp: enabled ? (_) => _set(false) : null,
        onTapCancel: enabled ? () => _set(false) : null,
        onTap: widget.onTap == null
            ? null
            : () {
                if (widget.haptic) tapFeedback();
                widget.onTap!();
              },
        onLongPress: widget.onLongPress == null
            ? null
            : () {
                HapticFeedback.mediumImpact();
                widget.onLongPress!();
              },
        child: child,
      ),
    );
  }
}

/// The one indeterminate spinner: a thin round-capped ring, for work the user
/// is waiting on (a button that is saving, a send in flight). It is the only
/// looping animation in the app; keep it short-lived and never use it as
/// decoration.
class BusySpinner extends StatelessWidget {
  const BusySpinner({super.key, this.size = 14, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          strokeCap: StrokeCap.round,
          color: color ?? context.ds.textSecondary,
        ),
      );
}

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
      AppButtonKind.primary => (ds.accent, ds.onAccent, Color.alphaBlend(Colors.black.withValues(alpha: 0.12), ds.accent)),
      AppButtonKind.secondary => (ds.fill, ds.text, ds.fillPressed),
      AppButtonKind.ghost => (Colors.transparent, ds.accentText, ds.fill),
      AppButtonKind.danger => (ds.danger.withValues(alpha: 0.12), ds.dangerText, ds.danger.withValues(alpha: 0.2)),
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
          Color dim(Color c) => k == 1 ? c : c.withValues(alpha: c.a * k);
          return AnimatedContainer(
            duration: Motion.pressing(pressed),
            curve: Motion.easeOut,
            height: h,
            width: expand ? double.infinity : null,
            padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 18),
            decoration: BoxDecoration(
              color: dim(pressed ? pressedBg : bg),
              borderRadius: BorderRadius.circular(Radii.control),
            ),
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (loading)
                  BusySpinner(color: dim(fg))
                else if (icon != null)
                  Icon(icon, size: compact ? 16 : 18, color: dim(fg)),
                if (loading || icon != null) const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.button.copyWith(
                      color: dim(fg),
                      fontSize: compact ? 13.5 : 15,
                    ),
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

/// Round icon button, 40px painted (44px touch): the Notion header control.
class CircleButton extends StatelessWidget {
  const CircleButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.size = 40,
    this.active = false,
    this.filled = true,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;
  final double size;

  /// Toggled-on state (accent tint).
  final bool active;

  /// Draw the surface and hairline; false for a bare icon.
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Tooltip(
      message: tooltip,
      // The press node below carries the label; the tooltip would add a second.
      excludeFromSemantics: true,
      child: PressBuilder(
        onTap: onPressed,
        scale: 0.92,
        semanticLabel: tooltip,
        button: true,
        selected: active ? true : null,
        minTapSize: kMinTap,
        builder: (context, pressed) => AnimatedContainer(
          duration: Motion.pressing(pressed),
          curve: Motion.easeOut,
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active
                ? ds.accent.withValues(alpha: ds.isDark ? 0.22 : 0.14)
                : filled
                    ? (pressed ? ds.fillPressed : ds.surface)
                    : (pressed ? ds.fill : Colors.transparent),
            border: filled && !active ? Border.all(color: ds.hairline) : null,
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: size * 0.5, color: active ? ds.accentText : ds.text),
        ),
      ),
    );
  }
}

/// Pill used for filters and tags. [leading] is a small glyph, [count] is
/// rendered with tabular figures. Paints 32 high, takes a 44 touch target
/// (headers reserve [height] for a chip row).
class AppChip extends StatelessWidget {
  const AppChip({
    super.key,
    required this.label,
    this.leading,
    this.count,
    this.selected = false,
    this.onTap,
  });

  final String label;
  final Widget? leading;
  final int? count;
  final bool selected;
  final VoidCallback? onTap;

  /// Layout height including the touch padding above and below the pill.
  static const height = kMinTap;

  static const _pill = 32.0;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return PressBuilder(
      onTap: onTap,
      scale: 0.96,
      haptic: true,
      semanticLabel: count == null ? label : '$label, $count',
      selected: selected,
      minTapSize: kMinTap,
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        height: _pill,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected || pressed ? ds.fill : Colors.transparent,
          borderRadius: BorderRadius.circular(_pill / 2),
          border: Border.all(color: selected ? ds.textTertiary.withValues(alpha: 0.5) : ds.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 7)],
            Text(
              label,
              style: Type.label.copyWith(
                color: selected ? ds.text : ds.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (count != null) ...[
              const SizedBox(width: 6),
              Text(
                '$count',
                style: Type.label.copyWith(
                  color: ds.textMuted,
                  fontFeatures: Type.tabular,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class SegmentOption<T> {
  const SegmentOption(this.value, this.label, [this.icon]);

  final T value;
  final String label;
  final IconData? icon;
}

/// Segmented control with a sliding thumb (transform-only motion). 44 high:
/// every option is a full-height touch target. Text is clamped to 1.2x so the
/// fixed-height track never clips its labels.
class Segmented<T> extends StatelessWidget {
  const Segmented({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<SegmentOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;

  static const _inset = 3.0;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final n = options.length;
    final index = options.indexWhere((o) => o.value == value).clamp(0, n - 1);
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      child: Container(
        height: kMinTap,
        decoration: BoxDecoration(
          color: ds.fill,
          borderRadius: BorderRadius.circular(Radii.segmented),
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(_inset),
              child: AnimatedAlign(
                alignment: Alignment(n == 1 ? 0 : -1 + 2 * index / (n - 1), 0),
                duration: Motion.reduced(context) ? Duration.zero : Motion.standard,
                curve: Motion.easeOut,
                child: FractionallySizedBox(
                  widthFactor: 1 / n,
                  heightFactor: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: ds.surface,
                      borderRadius: BorderRadius.circular(Radii.control),
                      border: Border.all(color: ds.hairline),
                    ),
                  ),
                ),
              ),
            ),
            Row(
              children: [
                for (final o in options)
                  Expanded(
                    child: PressBuilder(
                      onTap: () {
                        if (o.value != value) onChanged(o.value);
                      },
                      haptic: o.value != value,
                      semanticLabel: o.label,
                      selected: o.value == value,
                      builder: (context, _) => Center(
                        // Colour follows the thumb (200 ms) instead of flipping
                        // before it arrives.
                        child: TweenAnimationBuilder<Color?>(
                          tween: ColorTween(end: o.value == value ? ds.text : ds.textSecondary),
                          duration: Motion.standard,
                          builder: (context, color, _) => Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (o.icon != null) ...[
                                Icon(o.icon, size: 15, color: color),
                                const SizedBox(width: 6),
                              ],
                              Flexible(
                                child: Text(
                                  o.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Type.label.copyWith(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: color,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Text field with its label above (Linear-style) instead of Material's
/// floating label.
///
/// The field is named for screen readers by [label] (the visible text is
/// excluded from semantics so it is not read twice), and one line below it is
/// always reserved for [helper] / validation text, so an error appearing never
/// shifts the fields underneath.
class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.label,
    this.controller,
    this.hint,
    this.helper,
    this.validator,
    this.obscure = false,
    this.minLines = 1,
    this.maxLines = 1,
    this.suffix,
    this.keyboardType,
    this.textInputAction,
    this.mono = false,
    this.onChanged,
    this.inputFormatters,
    this.enabled = true,
    this.restorationId,
  });

  final String label;
  final TextEditingController? controller;
  final String? hint;
  final String? helper;
  final FormFieldValidator<String>? validator;
  final bool obscure;
  final int minLines;
  final int maxLines;
  final Widget? suffix;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool mono;
  final ValueChanged<String>? onChanged;
  final List<TextInputFormatter>? inputFormatters;
  final bool enabled;

  /// Persist the text across process death (state restoration). Leave null for
  /// secrets: restoration data is not protected storage.
  final String? restorationId;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: ExcludeSemantics(
            child: Text(label, style: Type.label.copyWith(color: ds.textSecondary)),
          ),
        ),
        Semantics(
          label: label,
          child: TextFormField(
            controller: controller,
            restorationId: restorationId,
            enabled: enabled,
            obscureText: obscure,
            minLines: obscure ? 1 : minLines,
            maxLines: obscure ? 1 : maxLines,
            validator: validator,
            keyboardType: keyboardType,
            textInputAction: textInputAction,
            onChanged: onChanged,
            inputFormatters: inputFormatters,
            autocorrect: false,
            enableSuggestions: false,
            style: (mono
                    ? const TextStyle(fontFamily: monoFamily, fontSize: 13, height: 1.5)
                    : Type.body.copyWith(fontSize: 16))
                .copyWith(color: ds.text),
            cursorColor: ds.accent,
            decoration: InputDecoration(
              hintText: hint,
              suffixIcon: suffix,
              // A blank helper keeps one line reserved for the error text.
              helperText: helper ?? ' ',
              helperMaxLines: 3,
              helperStyle: Type.caption.copyWith(color: ds.textMuted),
            ),
          ),
        ),
      ],
    );
  }
}
