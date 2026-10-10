import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/session_state.dart' show AgentPhase;
import '../../../data/acp/background/background_work.dart';
import '../../../data/repositories/agent_session.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import 'background_format.dart';
import 'background_sheet.dart';
import 'composer.dart' show HideWhenCompact;
import 'session_select.dart';

/// What the strip and the chip read from a session: the work (compared by
/// identity: a session hands out the same instance until something changes),
/// the waiting flag, whether the model runs, and whether the link is live.
typedef _Snap = (BackgroundWork, bool, bool, bool);

_Snap _snap(AgentSessionView s) =>
    (s.backgroundWork, s.waitingOnBackground, s.phase != AgentPhase.idle, s.link == AgentLink.live);

bool _same(_Snap a, _Snap b) => identical(a.$1, b.$1) && a.$2 == b.$2 && a.$3 == b.$3 && a.$4 == b.$4;

/// What keeps running after the turn, above the composer: one soft row, the
/// whole row opens the background sheet. One line while the turn runs; two in
/// the waiting state, where the second line names the consequence (`omp
/// continues by itself when it finishes`). Takes no room when nothing runs,
/// appears and goes without a height animation, and is hidden in the compact
/// layout (the bar's [BackgroundChip] carries the count there).
class BackgroundStrip extends StatelessWidget {
  const BackgroundStrip({super.key, required this.session});

  final AgentSessionView session;

  @override
  Widget build(BuildContext context) => SessionSelect<_Snap>(
    session: session,
    select: _snap,
    same: _same,
    builder: (context, snap) {
      final (work, waiting, turnRunning, live) = snap;
      final text = stripText(work, waiting: waiting, turnRunning: turnRunning);
      if (text == null) return const SizedBox(width: double.infinity);
      return HideWhenCompact(
        child: Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: _StripRow(
            text: text,
            live: live,
            semantics: stripSemantics(work, waiting: waiting, turnRunning: turnRunning),
            onTap: () => unawaited(showBackgroundWork(context, session)),
          ),
        ),
      );
    },
  );
}

class _StripRow extends StatelessWidget {
  const _StripRow({required this.text, required this.live, required this.semantics, required this.onTap});

  final StripText text;
  final bool live;
  final String semantics;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final second = text.secondary;
    return PressBuilder(
      onTap: onTap,
      scale: 0.985,
      haptic: true,
      semanticLabel: semantics,
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
        decoration: BoxDecoration(
          color: pressed ? ds.fillPressed : ds.fill,
          borderRadius: BorderRadius.circular(Radii.panel),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.layers, size: 14, color: ds.textSecondary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    text.primary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    // A list that may be out of date is quieter.
                    style: Type.compact.copyWith(color: live ? ds.text : ds.textSecondary),
                  ),
                  if (second != null)
                    Text(
                      second,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Type.secondary.copyWith(color: ds.textSecondary),
                    ),
                ],
              ),
            ),
            const SizedBox(width: Gap.sm),
            Icon(LucideIcons.chevronUp, size: 14, color: ds.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// The strip's count as a chip in the bar, beside the subagents chip. Only in
/// the compact layout (landscape with the keyboard up), where the strip is
/// hidden: a fact has one place.
class BackgroundChip extends StatelessWidget {
  const BackgroundChip({super.key, required this.session});

  final AgentSessionView session;

  @override
  Widget build(BuildContext context) => HideWhenCompact(
    compact: SessionSelect<(_Snap, bool)>(
      session: session,
      select: (s) => (_snap(s), s.subagents.isNotEmpty || s.subagentSummary.total > 0),
      same: (a, b) => _same(a.$1, b.$1) && a.$2 == b.$2,
      builder: (context, v) {
        final ((work, waiting, turnRunning, _), besideSubagents) = v;
        if (stripText(work, waiting: waiting, turnRunning: turnRunning) == null) return const SizedBox.shrink();
        return Padding(
          // The bar's row places the chips; this one follows the subagents chip.
          padding: EdgeInsets.only(left: besideSubagents ? Gap.sm : 0, bottom: 2),
          child: AppChip(
            label: chipLabel(work),
            semanticLabel: stripSemantics(work, waiting: waiting, turnRunning: turnRunning),
            leading: Icon(LucideIcons.layers, size: 14, color: context.ds.textSecondary),
            onTap: () => unawaited(showBackgroundWork(context, session)),
          ),
        );
      },
    ),
    child: const SizedBox.shrink(),
  );
}
