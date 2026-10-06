import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;

import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import 'visible_text.dart';

/// One quiet line for a piece of content that is not text: an icon, what it
/// is, where it lives, and (when something could not be shown) why in a
/// second line.
///
/// With [onTap] the line is a tappable row at least 44 dp high with a pressed
/// fill (bleeding 8 dp past the text, so tappable and plain lines share a left
/// edge) and its title in the link colour; without, it is plain text. Every
/// string passes [visibleText]: names and addresses come from the agent.
class ContentChip extends StatelessWidget {
  const ContentChip({
    super.key,
    required this.icon,
    required this.title,
    this.detail = '',
    this.note,
    this.onTap,
    this.muted = false,
    this.semanticLabel,
  });

  final IconData icon;
  final String title;

  /// Mono text after the title: a path, a host, a mime type.
  final String detail;

  /// A sentence under the line: why the content is not shown.
  final String? note;
  final VoidCallback? onTap;
  final bool muted;

  /// Set only when the row says something its text does not.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final tappable = onTap != null;
    // The icon sits on the middle of the first line, at any text size.
    final lineHeight = MediaQuery.textScalerOf(context).scale(
      (Type.secondary.fontSize ?? 14) * (Type.secondary.height ?? 1.3),
    );
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: lineHeight, child: Center(child: Icon(icon, size: 15, color: ds.textTertiary))),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  text: visibleText(title),
                  style: Type.secondary.copyWith(
                    color: tappable ? ds.accentText : (muted ? ds.textMuted : ds.textSecondary),
                    fontWeight: FontWeight.w500,
                  ),
                  children: [
                    if (detail.isNotEmpty)
                      TextSpan(
                        text: '  ${visibleText(detail)}',
                        style: TextStyle(fontFamily: monoFamily, fontSize: 12, color: ds.textMuted),
                      ),
                  ],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (note != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(visibleText(note!), style: Type.caption.copyWith(color: ds.textMuted)),
                ),
            ],
          ),
        ),
      ],
    );
    if (!tappable) return row;

    final body = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kMinTap),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs), child: row),
      ),
    );
    return LayoutBuilder(
      builder: (context, box) => OverflowBox(
        fit: OverflowBoxFit.deferToChild,
        minWidth: box.maxWidth + 2 * Gap.sm,
        maxWidth: box.maxWidth + 2 * Gap.sm,
        child: PressBuilder(
          onTap: onTap,
          semanticLabel: semanticLabel,
          builder: (context, pressed) => AnimatedContainer(
            duration: Motion.pressing(pressed),
            curve: Motion.easeOut,
            decoration: BoxDecoration(
              color: pressed ? ds.fillPressed : const Color(0x00000000),
              borderRadius: BorderRadius.circular(Radii.row),
            ),
            child: body,
          ),
        ),
      ),
    );
  }
}
