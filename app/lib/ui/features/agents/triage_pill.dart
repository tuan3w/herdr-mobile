import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/tokens.dart';
import '../../../data/models/herdr_models.dart';

/// "2 need you · Review": floats above the tab bar while any reachable agent
/// is blocked, and starts the triage sheet that walks through them.
///
/// Same surface, hairline and shadow as the tab bar, so it reads as part of
/// the bar's furniture, with the status shape as its only colour. 44 high.
class TriagePill extends StatelessWidget {
  const TriagePill({super.key, required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  static const height = kMinTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: PressBuilder(
        onTap: onTap,
        haptic: true,
        scale: 0.97,
        builder: (context, pressed) => AnimatedContainer(
          duration: Motion.pressing(pressed),
          curve: Motion.easeOut,
          height: height,
          padding: const EdgeInsets.only(left: 14, right: 12),
          decoration: BoxDecoration(
            color: Color.alphaBlend(
              ds.blocked.withValues(alpha: pressed ? 0.16 : 0.08),
              ds.surface,
            ),
            borderRadius: BorderRadius.circular(height / 2),
            border: Border.all(color: ds.blocked.withValues(alpha: 0.5)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: ds.isDark ? 0.45 : 0.08),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const StatusGlyph(status: AgentStatus.blocked, size: 16),
              const SizedBox(width: 8),
              Text(
                '$count need${count == 1 ? 's' : ''} you',
                style: Type.label.copyWith(
                  color: ds.text,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  fontFeatures: Type.tabular,
                ),
              ),
              const SizedBox(width: 8),
              Text('·', style: Type.label.copyWith(color: ds.textMuted)),
              const SizedBox(width: 8),
              Text(
                'Review',
                style: Type.label.copyWith(
                  color: ds.blockedText,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              const SizedBox(width: 2),
              Icon(LucideIcons.chevronRight, size: 16, color: ds.blockedText),
            ],
          ),
        ),
      ),
    );
  }
}
