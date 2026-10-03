import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'motion.dart';
import 'tokens.dart';

/// Press handling shared by every control: feedback on pointer-down (after the
/// scroll-intent delay, so scrolling a list never flashes rows), commit on up,
/// cancel by dragging away. No ripple. Optional press scale.
class PressBuilder extends StatefulWidget {
  const PressBuilder({
    super.key,
    required this.builder,
    this.onTap,
    this.onLongPress,
    this.scale = 1,
    this.haptic = false,
    this.semanticLabel,
  });

  final Widget Function(BuildContext context, bool pressed) builder;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Scale while pressed (1 = none). Small controls use ~0.96, rows none.
  final double scale;

  /// Selection haptic on tap.
  final bool haptic;
  final String? semanticLabel;

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
        duration: _down ? Motion.press : Motion.release,
        curve: Motion.easeOut,
        child: child,
      );
    }
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
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

enum AppButtonKind { primary, secondary, ghost, danger }

/// Flat button: 9px radius, no elevation, no ripple.
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

  /// Smaller (36px) for inline use in banners and rows.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final (bg, fg, pressedBg) = switch (kind) {
      AppButtonKind.primary => (ds.accent, ds.onAccent, Color.alphaBlend(Colors.black.withValues(alpha: 0.12), ds.accent)),
      AppButtonKind.secondary => (ds.fill, ds.text, ds.fillPressed),
      AppButtonKind.ghost => (Colors.transparent, ds.accentText, ds.fill),
      AppButtonKind.danger => (ds.danger.withValues(alpha: 0.12), ds.danger, ds.danger.withValues(alpha: 0.2)),
    };
    final enabled = onPressed != null && !loading;
    final h = compact ? 36.0 : 46.0;
    return PressBuilder(
      onTap: enabled ? onPressed : null,
      scale: 0.97,
      haptic: kind == AppButtonKind.primary,
      semanticLabel: label,
      builder: (context, pressed) => AnimatedOpacity(
        opacity: onPressed == null && !loading ? 0.4 : 1,
        duration: Motion.standard,
        child: AnimatedContainer(
          duration: pressed ? Motion.press : Motion.release,
          curve: Motion.easeOut,
          height: h,
          width: expand ? double.infinity : null,
          padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 18),
          decoration: BoxDecoration(
            color: pressed ? pressedBg : bg,
            borderRadius: BorderRadius.circular(Radii.control),
          ),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (loading)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                )
              else if (icon != null)
                Icon(icon, size: compact ? 16 : 18, color: fg),
              if (loading || icon != null) const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Type.button.copyWith(
                    color: fg,
                    fontSize: compact ? 13.5 : 15,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Round icon button, 40px: the Notion header control.
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
      child: PressBuilder(
        onTap: onPressed,
        scale: 0.92,
        semanticLabel: tooltip,
        builder: (context, pressed) => AnimatedContainer(
          duration: pressed ? Motion.press : Motion.release,
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
/// rendered with tabular figures.
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

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return PressBuilder(
      onTap: onTap,
      scale: 0.96,
      haptic: true,
      semanticLabel: label,
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.standard,
        curve: Motion.easeOut,
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected || pressed ? ds.fill : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
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
                  color: ds.textTertiary,
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

/// Segmented control with a sliding thumb (transform-only motion).
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

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final n = options.length;
    final index = options.indexWhere((o) => o.value == value).clamp(0, n - 1);
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: ds.fill,
        borderRadius: BorderRadius.circular(Radii.control + 2),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
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
                    builder: (context, _) => Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (o.icon != null) ...[
                            Icon(o.icon, size: 15, color: o.value == value ? ds.text : ds.textSecondary),
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
                                color: o.value == value ? ds.text : ds.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Text field with its label above (Linear-style) instead of Material's
/// floating label.
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

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(label, style: Type.label.copyWith(color: ds.textSecondary)),
        ),
        TextFormField(
          controller: controller,
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
                  ? const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13, height: 1.5)
                  : Type.body.copyWith(fontSize: 16))
              .copyWith(color: ds.text),
          cursorColor: ds.accent,
          decoration: InputDecoration(
            hintText: hint,
            suffixIcon: suffix,
            helperText: helper,
            helperMaxLines: 3,
            helperStyle: Type.caption.copyWith(color: ds.textTertiary),
          ),
        ),
      ],
    );
  }
}
