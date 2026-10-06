import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/pop.dart';
import '../../core/tokens.dart';
import '../../../data/models/herdr_models.dart';

/// "1 needs you · 2 to review": floats above the tab bar while any reachable
/// agent (terminal pane or agent session) is blocked, and starts the triage
/// sheet that walks through them. Both numbers are the `AttentionSet`'s: the
/// first is the Agents tab's badge, the second the finished agents that can
/// be reached and are not yet reviewed ([review], left out at 0). It is
/// information; a tap still goes to the blocked agents.
///
/// Same surface, hairline and shadow as the tab bar, so it reads as part of
/// the bar's furniture; the blocked glyph is its only colour. 44 high.
class TriagePill extends StatelessWidget {
  const TriagePill({super.key, required this.count, this.review = 0, required this.onTap});

  /// Reachable blocked agents ("needs you").
  final int count;

  /// Reachable finished agents not yet reviewed ("to review").
  final int review;
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
            color: pressed ? ds.fill : ds.surface,
            borderRadius: BorderRadius.circular(height / 2),
            border: Border.all(color: ds.hairline),
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
              Flexible(
                child: PopOnRise(
                  value: count,
                  alignment: Alignment.centerLeft,
                  child: Text.rich(
                    TextSpan(
                      text: '$count need${count == 1 ? 's' : ''} you',
                      style: Type.label.copyWith(
                        color: ds.text,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        fontFeatures: Type.tabular,
                      ),
                      children: [
                        if (review > 0)
                          TextSpan(
                            text: ' · $review to review',
                            style: TextStyle(color: ds.textSecondary, fontWeight: FontWeight.w500),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(LucideIcons.chevronRight, size: 16, color: ds.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}
