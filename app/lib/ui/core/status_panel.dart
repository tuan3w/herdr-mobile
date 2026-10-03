import 'package:flutter/material.dart';

import 'controls.dart';
import 'motion.dart';
import 'theme.dart';

/// Shared look of [StatusPanel] and [StatusStrip]: a 12% tint of the state's
/// colour with a faint outline in the same colour. Tint instead of elevation;
/// the colour is the state's colour, never decoration.
abstract final class StatusTint {
  /// Fill opacity. `blockedText` / `dangerText` reach 4.5:1 on it in both themes.
  static const fillAlpha = 0.12;
  static const borderAlpha = 0.22;

  static const pad = Gap.md;

  static BoxDecoration decoration(Color color, {bool pressed = false}) => BoxDecoration(
        color: color.withValues(alpha: pressed ? fillAlpha + 0.06 : fillAlpha),
        borderRadius: BorderRadius.circular(Radii.panel),
        border: Border.all(color: color.withValues(alpha: borderAlpha)),
      );
}

/// Flat tinted panel for a state that needs a sentence: a connection error, a
/// sign-in to approve, a test result. For a one-line state use [StatusStrip].
///
/// Layout: optional [icon], then [title] / [message] / [footer] stacked, and
/// an optional [trailing] action (a compact button) vertically centred.
class StatusPanel extends StatelessWidget {
  const StatusPanel({
    super.key,
    required this.color,
    this.icon,
    this.title,
    this.message,
    this.mono = false,
    this.messageMaxLines,
    this.footer,
    this.trailing,
  });

  final Color color;
  final IconData? icon;
  final String? title;
  final String? message;

  /// Message in the terminal font (fingerprints, paths).
  final bool mono;
  final int? messageMaxLines;
  final Widget? footer;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    // A compact action is 44 high for touch; trim the panel's own padding so
    // the panel is no taller than it was around a 36 button.
    final vertical = trailing == null ? StatusTint.pad : Gap.sm;
    return Semantics(
      container: true,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(StatusTint.pad, vertical, trailing == null ? StatusTint.pad : Gap.sm, vertical),
        decoration: StatusTint.decoration(color),
        child: Row(
          // A titled panel reads top-down (icon beside the title); a one-line
          // message with an action centres on the action.
          crossAxisAlignment: title != null ? CrossAxisAlignment.start : CrossAxisAlignment.center,
          children: [
            if (icon != null)
              Padding(
                padding: EdgeInsets.only(
                  right: Gap.md,
                  top: title != null ? 1 + StatusTint.pad - vertical : 0,
                ),
                child: ExcludeSemantics(child: Icon(icon, size: 18, color: color)),
              ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: StatusTint.pad - vertical),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (title != null)
                      Semantics(
                        header: true,
                        child: Text(
                          title!,
                          style: Type.label.copyWith(color: ds.text, fontWeight: FontWeight.w600, fontSize: 14),
                        ),
                      ),
                    if (message != null && message!.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(top: title == null ? 0 : 2),
                        child: Text(
                          message!,
                          maxLines: messageMaxLines,
                          overflow: messageMaxLines == null ? null : TextOverflow.ellipsis,
                          style: (mono ? const TextStyle(fontFamily: monoFamily, fontSize: 12, height: 1.45) : Type.secondary)
                              .copyWith(color: ds.textSecondary),
                        ),
                      ),
                    if (footer != null) Padding(padding: const EdgeInsets.only(top: Gap.md), child: footer),
                  ],
                ),
              ),
            ),
            if (trailing != null)
              Padding(
                padding: const EdgeInsets.only(left: Gap.sm),
                child: Semantics(container: true, child: trailing),
              ),
          ],
        ),
      ),
    );
  }
}

/// A one-line status: [leading] (a `LinkDot` or glyph), [title] with an optional
/// quieter [detail] after it, and an optional compact [action] (an
/// [AppButton] with `compact: true`). Same tint as [StatusPanel], ~48 high, so
/// several of them can stack above a list without pushing it off screen.
///
/// With [onTap] the whole strip is a button; the [action] stays its own.
class StatusStrip extends StatelessWidget {
  const StatusStrip({
    super.key,
    required this.color,
    required this.title,
    this.detail,
    this.leading,
    this.action,
    this.onTap,
  });

  final Color color;
  final String title;
  final String? detail;
  final Widget? leading;
  final Widget? action;
  final VoidCallback? onTap;

  static const height = 48.0;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Semantics(
      container: true,
      child: PressBuilder(
        onTap: onTap,
        builder: (context, pressed) => AnimatedContainer(
          duration: Motion.pressing(pressed),
          curve: Motion.easeOut,
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: height),
          padding: EdgeInsets.fromLTRB(StatusTint.pad, 0, action == null ? StatusTint.pad : Gap.xs, 0),
          decoration: StatusTint.decoration(color, pressed: pressed && onTap != null),
          child: Row(
            children: [
              if (leading != null) ...[
                ExcludeSemantics(child: leading),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                  child: Text.rich(
                    TextSpan(
                      text: title,
                      style: Type.label.copyWith(color: ds.text, fontWeight: FontWeight.w600, fontSize: 14),
                      children: [
                        if (detail != null && detail!.isNotEmpty)
                          TextSpan(
                            text: '  $detail',
                            style: Type.secondary.copyWith(color: ds.textSecondary),
                          ),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (action != null)
                Padding(
                  padding: const EdgeInsets.only(left: Gap.sm),
                  child: Semantics(container: true, child: action),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
