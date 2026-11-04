import 'package:herdr_mobile/l10n/l10n_context.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../data/acp/subagents/subagent_run.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/words/plural.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'agent_session_navigation.dart';
import 'observed_roster.dart' show showObservedSubagents;
import 'session_select.dart';
import 'subagent_card.dart';
import 'subagent_format.dart';

class _ChipSnap {
  const _ChipSnap(this.summary, this.blocked, this.live, this.observedTotal, this.observedRunning, this.partial);

  final SubagentSummary summary;
  final int blocked;
  final bool live;
  final int observedTotal;
  final int observedRunning;

  /// The phone has read only the end of the log: the observed total is of that
  /// part.
  final bool partial;

  @override
  bool operator ==(Object other) =>
      other is _ChipSnap &&
      other.summary == summary &&
      other.blocked == blocked &&
      other.live == live &&
      other.observedTotal == observedTotal &&
      other.observedRunning == observedRunning &&
      other.partial == partial;

  @override
  int get hashCode => Object.hash(summary, blocked, live, observedTotal, observedRunning, partial);
}

/// The chip under the bar that opens the roster: `3 subagents`, `1 of 3
/// running`, `1 needs you` (tinted), `1 of 3 failed`; for a session followed
/// through its log `6 running` (the total is in the sheet) or `66+ subagents`
/// (the `+`: only the end of the log is read). The index of
/// every subagent of the session, for an agent that talks ACP (their
/// [SubagentRun]s) and for one followed through its log (the observed
/// roster). Takes no room without subagents; the bar places it.
class SubagentsChip extends StatelessWidget {
  const SubagentsChip({super.key, required this.session});

  final AgentSessionView session;

  @override
  Widget build(BuildContext context) => SessionSelect<_ChipSnap>(
    session: session,
    select: (s) => _ChipSnap(
      s.subagentSummary,
      blockedRunIds(s.state).length,
      // A log-followed session has no runs: its words are as live as its link.
      s.subagents.isNotEmpty ? s.link == AgentLink.live : runsAreLive(s.state, linkLive: s.link == AgentLink.live),
      s.subagents.length,
      s.subagents.where((e) => e.state == SubagentState.running).length,
      s.earlier != EarlierHistory.none,
    ),
    builder: (context, v) {
      final ds = context.ds;
      final observed = v.observedTotal > 0;
      final total = observed ? v.observedTotal : v.summary.total;
      if (total == 0) return const SizedBox.shrink();
      final running = observed ? v.observedRunning : v.summary.active;
      Color? tint;
      String label;
      if (!observed && v.live && v.blocked > 0) {
        label = needYou(v.blocked);
        tint = ds.blockedText;
      } else if (running > 0 && v.live) {
        label = observed ? '$running running' : '$running of $total running';
      } else if (!observed && v.summary.failed > 0) {
        label = '${v.summary.failed} of $total failed';
        tint = ds.dangerText;
      } else {
        label = observed ? '$total${v.partial ? '+' : ''} ${plural(total, 'subagent')}' : countOf(total, 'subagent');
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: Gap.hair),
        child: AppChip(
          label: label,
          tint: tint,
          leading: Icon(HerdrIcons.agents, size: IconSize.inline, color: tint ?? ds.textSecondary),
          onTap: () => showSubagents(context, session),
        ),
      );
    },
  );
}

/// The roster as a sheet. An observed session lists its subagents from the
/// log; an ACP session lists its runs, grouped Waiting, Running, Finished.
Future<void> showSubagents(BuildContext context, AgentSessionView session) {
  if (session.isObserved || session.subagents.isNotEmpty) {
    return showObservedSubagents(context, session);
  }
  return showAppSheet<void>(context, builder: (ctx) => SubagentRoster(session: session));
}

class _RosterSnap {
  const _RosterSnap(this.runs, this.blocked, this.live);

  final List<SubagentRun> runs;
  final Set<String> blocked;
  final bool live;

  bool sameAs(_RosterSnap o) => identical(runs, o.runs) && live == o.live && setEquals(blocked, o.blocked);
}

/// Up to this many lines the sheet is as tall as its lines; past it, it is
/// as tall as a list sheet grows and the list is lazy.
const _shrinkWrapUntil = 8;

/// Every subagent of an ACP session, grouped: Waiting (the ones that need the
/// person first), Running, Finished (failed first). A row is the same card as
/// in the work log; a tap opens the run. Virtualized past [_shrinkWrapUntil]
/// lines, so 25 subagents cost what the ones on screen cost.
class SubagentRoster extends StatelessWidget {
  const SubagentRoster({super.key, required this.session});

  final AgentSessionView session;

  void _open(BuildContext context, String runId) {
    final navigator = Navigator.of(context)..pop();
    // ignore: use_build_context_synchronously
    unawaited(openSubagentRun(navigator.context, session, runId));
  }

  @override
  Widget build(BuildContext context) => SessionSelect<_RosterSnap>(
    session: session,
    select: (s) =>
        _RosterSnap(s.subagentRuns, blockedRunIds(s.state), runsAreLive(s.state, linkLive: s.link == AgentLink.live)),
    same: (a, b) => a.sameAs(b),
    builder: (context, snap) {
      final ds = context.ds;
      final items = rosterOf(snap.runs, blocked: snap.blocked, live: snap.live);
      final summary = SubagentSummary.of(snap.runs);
      final list = ListView.builder(
        shrinkWrap: items.length <= _shrinkWrapUntil,
        padding: const EdgeInsets.only(left: Gap.sm, right: Gap.sm, bottom: Gap.sm),
        itemCount: items.length,
        itemBuilder: (context, i) => switch (items[i]) {
          RosterHeader(:final section, :final count) => Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.md, Gap.xs, Gap.xs),
            child: Semantics(
              header: true,
              child: Text(
                '${section.title} · $count',
                style: Type.labelStrong.copyWith(color: ds.textSecondary, fontFeatures: Type.tabular),
              ),
            ),
          ),
          RosterEntry(:final run, :final tone) => Padding(
            padding: const EdgeInsets.only(bottom: Gap.xs),
            child: SubagentCard(
              key: ValueKey(run.id),
              session: session,
              run: run,
              tone: tone,
              onOpen: () => _open(context, run.id),
            ),
          ),
        },
      );
      return SheetScaffold(
        title: summary.total == 0 ? context.l10n.uiSubagents : context.l10n.messageSubagents('${summary.total}'),
        kind: SheetKind.list,
        scrolls: items.isNotEmpty,
        child: items.isEmpty
            ? const EmptyState.inline(
                'None started yet.',
                padding: EdgeInsets.only(left: Gap.lg, right: Gap.lg, bottom: Gap.sm),
              )
            : list,
      );
    },
  );
}
