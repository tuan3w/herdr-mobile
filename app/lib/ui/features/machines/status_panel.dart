import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Flat tinted panel for a state that needs a sentence: a connection error, a
/// sign-in to approve, a test result. Tint instead of a border or elevation;
/// the colour is the state's colour, never decoration.
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
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(Gap.md, Gap.md, trailing == null ? Gap.md : Gap.sm, Gap.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: ds.isDark ? 0.14 : 0.10),
        borderRadius: BorderRadius.circular(Radii.panel),
      ),
      child: Row(
        // A titled panel reads top-down (icon beside the title); a one-line
        // message with an action centres on the action.
        crossAxisAlignment: title != null ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          if (icon != null)
            Padding(
              padding: EdgeInsets.only(right: Gap.md, top: title != null ? 1 : 0),
              child: Icon(icon, size: 18, color: color),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (title != null)
                  Text(
                    title!,
                    style: Type.label.copyWith(color: ds.text, fontWeight: FontWeight.w600, fontSize: 14),
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
          if (trailing != null) Padding(padding: const EdgeInsets.only(left: Gap.sm), child: trailing),
        ],
      ),
    );
  }
}
