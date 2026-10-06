import 'package:flutter/material.dart';

import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/tokens.dart';

/// The painted on/off switch: a pill track with a thumb that slides across.
///
/// It only draws. Put it in a [SwitchRow] (or any other tappable row), which
/// is the touch target and the one accessibility node; a switch on its own
/// would be a 46 x 28 target and a second node.
///
/// Off is a quiet fill with a `textTertiary` outline and thumb (3:1 on the
/// page, like the other rings and icons); on is the accent with `onAccent`.
/// The thumb moves with an aligned slide, the colours cross-fade, both in
/// [Motion.standard].
class AppSwitch extends StatelessWidget {
  const AppSwitch({super.key, required this.value});

  final bool value;

  static const width = 46.0;
  static const height = 28.0;
  static const _inset = 3.0;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final duration = Motion.reduced(context) ? Duration.zero : Motion.standard;
    return AnimatedContainer(
      duration: duration,
      curve: Motion.easeOut,
      width: width,
      height: height,
      padding: const EdgeInsets.all(_inset),
      decoration: BoxDecoration(
        color: value ? ds.accent : ds.fill,
        borderRadius: BorderRadius.circular(height / 2),
        border: Border.all(color: value ? ds.accent : ds.textTertiary, width: 1.5),
      ),
      child: AnimatedAlign(
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        duration: duration,
        curve: Motion.easeOut,
        child: AnimatedContainer(
          duration: duration,
          curve: Motion.easeOut,
          width: height - 2 * _inset - 3,
          height: height - 2 * _inset - 3,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: value ? ds.onAccent : ds.textTertiary,
          ),
        ),
      ),
    );
  }
}

/// A setting that is on or off: title, an optional line saying what it does,
/// and an [AppSwitch]. The whole row toggles; it is at least 56 high, and the
/// text wraps rather than clipping at large text sizes.
///
/// Announced once, as a switch: "Wrap long lines, on". With [enabled] false
/// the row is dimmed, ignores taps and is announced as unavailable.
class SwitchRow extends StatelessWidget {
  const SwitchRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final subtitle = this.subtitle;
    Widget row = Semantics(
      toggled: value,
      enabled: enabled ? null : false,
      child: PressBuilder(
        onTap: enabled ? () => onChanged(!value) : null,
        haptic: true,
        // A switch, not a button: the role comes from `toggled` above.
        button: false,
        builder: (context, pressed) => AnimatedContainer(
          duration: Motion.pressing(pressed),
          curve: Motion.easeOut,
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(vertical: Gap.sm),
          decoration: BoxDecoration(
            color: pressed ? ds.fill : Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.row),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: Type.row.copyWith(color: ds.text)),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle,
                          style: Type.secondary.copyWith(color: ds.textSecondary),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: Gap.lg),
              AppSwitch(value: value),
            ],
          ),
        ),
      ),
    );
    // A layer only while dimmed (an opacity-1 wrapper would cost one always).
    // Without a tap action nothing merges the texts into the node by itself.
    if (!enabled) row = Opacity(opacity: 0.45, child: MergeSemantics(child: row));
    return row;
  }
}
