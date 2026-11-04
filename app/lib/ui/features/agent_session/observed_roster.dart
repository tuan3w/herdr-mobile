import 'package:herdr_mobile/l10n/l10n_context.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../data/acp/background/background_work.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/observed_session.dart';
import '../../../data/words/elapsed.dart';
import '../../../data/words/plural.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../render/visible_text.dart';
import '../../support/step_clock.dart';
import 'agent_session_navigation.dart';
import 'background_controls.dart';
import 'session_select.dart';
import 'transcript_view.dart' show EarlierRow;

/// The roster of an observed session as a sheet, the same sections as the ACP
/// roster, but Running first: Running (each with a held stop, and one `Stop
/// all`), Waiting, and Done (failed first, newest first, [rosterDoneShown] shown). Each row has
/// its state, what it was asked (cut) and its latest tools. The host's artifact
/// folder is listed to refine the states only while the sheet is open. (The
/// chip that opens it, and the roster of an ACP session, are in
/// `subagent_roster.dart`.)
Future<void> showObservedSubagents(BuildContext context, AgentSessionView session) {
  session.watchSubagents(true);
  return showAppSheet<void>(
    context,
    builder: (ctx) => ObservedRoster(session: session),
  ).whenComplete(() => session.watchSubagents(false));
}

/// Done rows listed before `Show more`: a swarm leaves dozens, and the person
/// opened the sheet for what runs now.
const rosterDoneShown = 8;

/// Up to this many lines the sheet is as tall as its lines; past it, it is as
/// tall as a list sheet grows and the list is lazy.
const _shrinkWrapUntil = 8;

class RosterSections {
  const RosterSections({required this.waiting, required this.running, required this.done});

  final List<SubagentEntry> waiting;
  final List<SubagentEntry> running;
  final List<SubagentEntry> done;
}

/// [entries] (oldest first, as the log named them) in the order the sheet
/// lists them: waiting and running as they came, done with the failed first,
/// each newest first.
RosterSections rosterSections(List<SubagentEntry> entries) {
  List<SubagentEntry> of(SubagentState s) => [
    for (final e in entries)
      if (e.state == s) e,
  ];
  return RosterSections(
    waiting: of(SubagentState.waiting),
    running: of(SubagentState.running),
    done: [...of(SubagentState.failed).reversed, ...of(SubagentState.finished).reversed],
  );
}

typedef _Snap = (List<SubagentEntry>, BackgroundWork, bool, EarlierHistory);

sealed class _Item {
  const _Item();
}

class _Head extends _Item {
  const _Head(this.title, this.count);

  final String title;
  final int count;
}

class _Row extends _Item {
  const _Row(this.entry);

  final SubagentEntry entry;
}

class _More extends _Item {
  const _More(this.hidden, this.open);

  final int hidden;
  final bool open;
}

class _Earlier extends _Item {
  const _Earlier();
}

class ObservedRoster extends StatefulWidget {
  const ObservedRoster({super.key, required this.session});

  final AgentSessionView session;

  @override
  State<ObservedRoster> createState() => _ObservedRosterState();
}

class _ObservedRosterState extends State<ObservedRoster> {
  late final BackgroundStopper _stopper = BackgroundStopper(widget.session)..addListener(_changed);
  bool _moreDone = false;

  AgentSessionView get _session => widget.session;

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _stopper.dispose();
    super.dispose();
  }

  static bool _sameEntries(List<SubagentEntry> a, List<SubagentEntry> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.name != y.name ||
          x.state != y.state ||
          x.info.toolCount != y.info.toolCount ||
          x.info.assignment != y.info.assignment ||
          !listEquals(x.info.recentTools, y.info.recentTools)) {
        return false;
      }
    }
    return true;
  }

  /// Reads the work when the hold completes, not when the sheet was built.
  void _stopAll() {
    final work = _session.backgroundWork;
    final agents = [
      for (final t in work.running)
        if (t.kind == BackgroundKind.agent) t,
    ];
    final targets = [
      for (final t in agents)
        if (t.stop != StopRoute.none) t,
    ];
    unawaited(_stopper.stopAll(targets: targets, skipped: agents.length - targets.length, only: BackgroundKind.agent));
  }

  void _open(String name) {
    final parent = _session;
    if (parent is! ObservedAgentSession) return;
    final navigator = Navigator.of(context)..pop();
    // ignore: use_build_context_synchronously
    unawaited(openSubagentChat(navigator.context, parent, name));
  }

  @override
  Widget build(BuildContext context) => SessionSelect<_Snap>(
    session: _session,
    select: (s) => (s.subagents, s.backgroundWork, s.link == AgentLink.live, s.earlier),
    same: (a, b) => _sameEntries(a.$1, b.$1) && identical(a.$2, b.$2) && a.$3 == b.$3 && a.$4 == b.$4,
    builder: (context, snap) {
      final (entries, work, live, earlier) = snap;
      final ds = context.ds;
      final sections = rosterSections(entries);
      final done = sections.done;
      final shown = _moreDone ? done : done.take(rosterDoneShown).toList();
      final items = <_Item>[
        // Running first: omp names every subagent of a `task` call pending at once,
        // so a swarm of 24 would put the few that run now below two dozen waiting.
        if (sections.running.isNotEmpty) _Head(live ? 'Running' : 'Was running', sections.running.length),
        for (final e in sections.running) _Row(e),
        if (sections.waiting.isNotEmpty) _Head('Waiting', sections.waiting.length),
        for (final e in sections.waiting) _Row(e),
        if (done.isNotEmpty) _Head('Done', done.length),
        for (final e in shown) _Row(e),
        if (done.length > rosterDoneShown) _More(done.length - rosterDoneShown, _moreDone),
        if (earlier != EarlierHistory.none) const _Earlier(),
      ];
      final agents = [
        for (final t in work.running)
          if (t.kind == BackgroundKind.agent) t,
      ];
      final targets = [
        for (final t in agents)
          if (t.stop != StopRoute.none) t,
      ];
      final stopAll =
          live && targets.length >= 2 && targets.any((t) => _stopper.stops[t.key]?.phase != StopPhase.stopping);
      final summary = _stopper.summary;
      final pre = [
        if (stopAll)
          Padding(
            padding: const EdgeInsets.only(left: Gap.md, top: Gap.md, right: Gap.md),
            child: StopAllChip(
              count: targets.length,
              primed: _stopper.primed == BackgroundStopper.all,
              onTap: () =>
                  _stopper.primed == BackgroundStopper.all ? _stopAll() : _stopper.prime(BackgroundStopper.all),
              onHeld: _stopAll,
            ),
          ),
        if (summary != null)
          Padding(
            padding: const EdgeInsets.only(left: Gap.md, top: Gap.sm, right: Gap.md),
            child: Text(summary, style: Type.secondary.copyWith(color: ds.textSecondary)),
          ),
      ];
      final post = [
        if (!live)
          const SheetFooter(lines: ['Not connected. This is the last known list.'])
        else if (agents.isNotEmpty)
          SheetFooter(
            lines: [
              'Stop on the message bar ends the turn only. Subagents keep running until you stop them.',
              if (targets.any((t) => t.stop == StopRoute.message)) messageRouteNote(_session.agentLabel),
            ],
          ),
      ];
      final byName = {for (final t in agents) t.id: t};
      Widget item(BuildContext context, int i) => switch (items[i]) {
        _Head(:final title, :final count) => SectionHead(title, count),
        _Row(:final entry) => _RosterRow(
          key: ValueKey(entry.name),
          entry: entry,
          task: byName[entry.info.logId ?? entry.name],
          agentLabel: _session.agentLabel,
          live: live,
          stop: _stopper.stops[byName[entry.info.logId ?? entry.name]?.key],
          primed: _stopper.primed != null && _stopper.primed == byName[entry.info.logId ?? entry.name]?.key,
          opens: _session is ObservedAgentSession,
          onTap: () => _open(entry.name),
          onStopper: _stopper,
        ),
        _More(:final hidden, :final open) => ShowMoreRow(
          hidden: hidden,
          open: open,
          onTap: () => setState(() => _moreDone = !_moreDone),
        ),
        _Earlier() => Padding(
          padding: const EdgeInsets.only(left: Gap.md, top: Gap.md, right: Gap.md),
          child: Column(
            children: [
              Text(
                context.l10n.uiSubagentsFromEarlierInThisChatAreNotListed,
                textAlign: TextAlign.center,
                style: Type.secondary.copyWith(color: ds.textMuted),
              ),
              const SizedBox(height: Gap.xs),
              EarlierRow(earlier: earlier, onLoad: _session.loadEarlier),
            ],
          ),
        ),
      };
      final partial = earlier != EarlierHistory.none ? '+' : '';
      return SheetScaffold(
        title: entries.isEmpty
            ? context.l10n.uiSubagents
            : context.l10n.messageSubagents67('${entries.length}', partial),
        kind: SheetKind.list,
        scrolls: items.isNotEmpty,
        child: items.isEmpty
            ? const EmptyState.inline('None started yet.', padding: EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.md))
            : ListView.builder(
                shrinkWrap: items.length <= _shrinkWrapUntil,
                padding: const EdgeInsets.only(bottom: Gap.xs),
                itemCount: pre.length + items.length + post.length,
                itemBuilder: (context, i) => i < pre.length
                    ? pre[i]
                    : i < pre.length + items.length
                    ? item(context, i - pre.length)
                    : post[i - pre.length - items.length],
              ),
      );
    },
  );
}

class _RosterRow extends StatelessWidget {
  const _RosterRow({
    super.key,
    required this.entry,
    required this.task,
    required this.agentLabel,
    required this.live,
    required this.stop,
    required this.primed,
    required this.opens,
    required this.onTap,
    required this.onStopper,
  });

  final SubagentEntry entry;

  /// The running background task of this subagent, when the log lists one: what
  /// can be stopped.
  final BackgroundTask? task;
  final String agentLabel;
  final bool live;
  final TaskStop? stop;
  final bool primed;
  final bool opens;
  final VoidCallback onTap;
  final BackgroundStopper onStopper;

  String _word() => switch (entry.state) {
    SubagentState.waiting => 'Waiting',
    SubagentState.running => live ? 'Running' : 'Was running',
    SubagentState.finished => 'Done',
    SubagentState.failed => 'Failed',
  };

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final info = entry.info;
    final color = switch (entry.state) {
      SubagentState.running => live ? ds.working : ds.textMuted,
      SubagentState.failed => ds.dangerText,
      SubagentState.finished => ds.done,
      SubagentState.waiting => ds.textMuted,
    };
    final tools = info.recentTools.isEmpty ? null : info.recentTools.join(' · ');
    final started = entry.state == SubagentState.running ? task?.startedAt : null;
    Widget detail(DateTime? now) => Text(
      [
        _word(),
        if (started != null && now != null) Elapsed.compact(now.difference(started)),
        if (info.toolCount > 0) countOf(info.toolCount, 'tool'),
      ].join(' · '),
      style: Type.captionStrong.copyWith(color: color, fontFeatures: Type.tabular),
    );
    final t = task;
    final canStop = live && entry.state == SubagentState.running && t != null && t.stop != StopRoute.none;
    final trailing = t != null && (canStop || stop?.phase == StopPhase.unconfirmed)
        ? stopControl(
            context,
            task: t,
            agentLabel: agentLabel,
            stop: stop,
            primed: primed,
            onActivate: () => onStopper.activate(t),
            onHold: () => onStopper.stop(t),
            onRetry: () => onStopper.stop(t),
          )
        : null;
    final note = stopNote(context, stop);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: PressRow(
            onTap: opens ? onTap : null,
            minHeight: kMinTap,
            padding: const EdgeInsets.only(left: Gap.lg - PressRow.inset, right: Gap.sm, top: Gap.sm, bottom: Gap.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  visibleText(entry.name),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Type.row.copyWith(color: ds.text),
                ),
                started != null ? MinuteBuilder(builder: (context, now) => detail(now)) : detail(null),
                if (info.assignment.isNotEmpty)
                  Text(
                    visibleText(info.assignment),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Type.secondary.copyWith(color: ds.textSecondary),
                  ),
                if (tools != null)
                  Text(
                    tools,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Mono.small.copyWith(color: ds.textMuted),
                  ),
                ?note,
              ],
            ),
          ),
        ),
        if (trailing != null)
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm, right: Gap.sm),
            child: trailing,
          ),
      ],
    );
  }
}
