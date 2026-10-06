import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../controls.dart';
import '../motion.dart';
import '../theme.dart';

/// The foot of a capped panel: what is hidden ("12 more lines"), the one
/// action that shows it ("Show all") and, for a panel whose text is worth
/// taking away (command output, a diff), a quiet copy button. 44 dp high.
/// Shared by the code panels of tool output and the Markdown code blocks and
/// tables.
///
/// [action] and [onTap] go together; a row with only [onCopy] says how long the
/// panel is and offers the copy.
class MoreRow extends StatelessWidget {
  const MoreRow({super.key, required this.label, this.action, this.onTap, this.onCopy, this.copyLabel = 'Copy'});

  final String label;
  final String? action;
  final VoidCallback? onTap;

  /// Copies what the panel holds; the owner says "Copied" and ticks.
  final VoidCallback? onCopy;

  /// What a screen reader calls the copy button ("Copy output").
  final String copyLabel;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Type.caption.copyWith(color: ds.textMuted),
    );
    final more = onTap == null || action == null
        ? ConstrainedBox(
            constraints: const BoxConstraints(minHeight: kMinTap),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(padding: const EdgeInsets.only(left: Gap.md), child: text),
            ),
          )
        : PressBuilder(
            onTap: onTap,
            builder: (context, pressed) => AnimatedContainer(
              duration: Motion.pressing(pressed),
              curve: Motion.easeOut,
              constraints: const BoxConstraints(minHeight: kMinTap),
              padding: const EdgeInsets.symmetric(horizontal: Gap.md),
              color: pressed ? ds.fillPressed : const Color(0x00000000),
              child: Row(
                children: [
                  Expanded(child: text),
                  Text(action!, style: Type.label.copyWith(color: ds.accentText, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          );
    if (onCopy == null) return more;
    return Row(
      children: [
        Expanded(child: more),
        PressBuilder(
          onTap: onCopy,
          semanticLabel: copyLabel,
          minTapSize: kMinTap,
          builder: (context, pressed) => Icon(LucideIcons.copy, size: 16, color: pressed ? ds.text : ds.textSecondary),
        ),
      ],
    );
  }
}
