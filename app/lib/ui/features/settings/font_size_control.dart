import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/terminal_settings.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';

/// The terminal font size: a stepper (smaller, the size, larger) over a sample
/// line drawn in the terminal font at that size.
///
/// It edits the same [TerminalSettings] the pane pinches, in the same 8 to 22
/// range, so the two always agree. Each step is saved.
class FontSizeControl extends StatelessWidget {
  const FontSizeControl({super.key});

  /// What one tap on a step button changes. The pinch can land between
  /// whole numbers; the bounds are reached exactly from either side.
  static const step = 1.0;

  /// "11.5", "12": no trailing zero.
  static String format(double size) =>
      size == size.roundToDouble() ? size.toStringAsFixed(0) : size.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final settings = context.read<TerminalSettings>();
    final size = context.select<TerminalSettings, double>((s) => s.fontSize);
    void set(double next) => unawaited(settings.setFontSize(next));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: Gap.xs),
          child: Text('Font size', style: Type.row.copyWith(color: ds.text)),
        ),
        const SizedBox(height: Gap.sm),
        _Stepper(
          value: format(size),
          onSmaller: size > minTerminalFontSize
              ? () => set(math.max(minTerminalFontSize, size - step))
              : null,
          onLarger: size < maxTerminalFontSize
              ? () => set(math.min(maxTerminalFontSize, size + step))
              : null,
        ),
        const SizedBox(height: Gap.sm),
        _Sample(fontSize: size),
      ],
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.value, required this.onSmaller, required this.onLarger});

  final String value;
  final VoidCallback? onSmaller;
  final VoidCallback? onLarger;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    // The track is a fixed 44 high, so its text stops growing at 1.2x like
    // the other fixed-height controls.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      child: Container(
        height: kMinTap,
        decoration: BoxDecoration(
          color: ds.fill,
          borderRadius: BorderRadius.circular(Radii.segmented),
        ),
        child: Row(
          children: [
            _StepButton(
              icon: LucideIcons.minus,
              label: 'Decrease font size',
              onTap: onSmaller,
            ),
            Expanded(
              child: Center(
                child: Text(
                  value,
                  maxLines: 1,
                  style: Type.row.copyWith(
                    color: ds.text,
                    fontWeight: FontWeight.w600,
                    fontFeatures: Type.tabular,
                  ),
                ),
              ),
            ),
            _StepButton(
              icon: LucideIcons.plus,
              label: 'Increase font size',
              onTap: onLarger,
            ),
          ],
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;

  /// Null at the end of the range: the button is dimmed and does nothing.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return PressBuilder(
      onTap: onTap,
      haptic: true,
      semanticLabel: label,
      button: true,
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        width: 64,
        height: kMinTap,
        decoration: BoxDecoration(
          color: pressed ? ds.fillPressed : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.segmented),
        ),
        child: Icon(icon, size: 18, color: onTap == null ? ds.textTertiary : ds.text),
      ),
    );
  }
}

/// A terminal-coloured strip with one line in the terminal font at [fontSize],
/// scaled the way the pane scales it (large text sizes grow it, up to 1.6x).
/// Its height is that of the largest size, so stepping never moves what
/// follows it.
class _Sample extends StatelessWidget {
  const _Sample({required this.fontSize});

  final double fontSize;

  static const _lineHeight = 1.3;

  static double _scaled(TextScaler scaler, double size) =>
      math.min(math.max(scaler.scale(size), size), size * 1.6);

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final tallest = _scaled(scaler, maxTerminalFontSize) * _lineHeight;
    return ExcludeSemantics(
      child: SizedBox(
        height: tallest + 2 * Gap.md,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: TerminalColors.background,
            borderRadius: BorderRadius.circular(Radii.control),
            border: Border.all(color: TerminalColors.border),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.md),
            // Already scaled above; the text must not be scaled a second time.
            child: MediaQuery.withNoTextScaling(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  r'$ git status',
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  softWrap: false,
                  style: TextStyle(
                    fontFamily: monoFamily,
                    fontSize: _scaled(scaler, fontSize),
                    height: _lineHeight,
                    color: TerminalColors.foreground,
                    fontFeatures: const [FontFeature.disable('liga'), FontFeature.disable('calt')],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
