import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';

/// The way back to the end of the conversation, shown while the reader is
/// away from it: a round chevron, or, when blocks of the answer have been
/// finished since they left, a pill that says how many (`3 new`). A plain
/// count, no animation; the label is announced as `3 new, jump to latest`.
/// Both are 44 dp targets (the pill paints 36 high).
class JumpToLatest extends StatelessWidget {
  const JumpToLatest({super.key, required this.newBlocks, required this.onPressed});

  /// Blocks finished since the reader left the end; 0 shows the chevron.
  final int newBlocks;
  final VoidCallback onPressed;

  static const _pill = 36.0;

  @override
  Widget build(BuildContext context) {
    if (newBlocks <= 0) {
      return CircleButton(
        icon: LucideIcons.chevronsDown,
        tooltip: 'Jump to latest',
        size: _pill,
        onPressed: onPressed,
      );
    }
    final ds = context.ds;
    return Tooltip(
      message: 'Jump to latest',
      excludeFromSemantics: true,
      child: PressBuilder(
        onTap: onPressed,
        scale: 0.96,
        semanticLabel: '$newBlocks new, jump to latest',
        button: true,
        minTapSize: kMinTap,
        builder: (context, pressed) => AnimatedContainer(
          duration: Motion.pressing(pressed),
          curve: Motion.easeOut,
          height: _pill,
          padding: const EdgeInsets.only(left: 14, right: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_pill / 2),
            // Opaque: it floats over text, which must not show through.
            color: Color.alphaBlend(
              ds.accent.withValues(alpha: ds.isDark ? (pressed ? 0.3 : 0.22) : (pressed ? 0.2 : 0.14)),
              ds.bg,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ExcludeSemantics(
                child: Text(
                  '$newBlocks new',
                  maxLines: 1,
                  style: Type.label.copyWith(
                    color: ds.accentText,
                    fontWeight: FontWeight.w600,
                    fontFeatures: Type.tabular,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Icon(LucideIcons.chevronsDown, size: 16, color: ds.accentText),
            ],
          ),
        ),
      ),
    );
  }
}
