import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/acp_models.dart';
import '../../../data/acp/session_state.dart';
import '../../../data/acp/subagents/subagent_run.dart';
import '../../../data/models/herdr_models.dart' show AgentStatus;
import '../../../data/acp/turns/turns.dart';
import '../../../data/decision/mode_danger.dart';
import '../../../data/decision/session_chips.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/words/elapsed.dart';
import '../../../data/words/plural.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../support/step_clock.dart';
import 'log_atoms.dart';
import 'permission_subject.dart';
import 'session_bar.dart' show sessionStatus;
import 'session_overview_model.dart';
import 'session_select.dart';
import 'status_line.dart' show statusNow;
import 'subagent_format.dart';
import 'subagent_roster.dart';
import 'transcript_rows.dart' show allKey;
import 'changed_card.dart' show ChangedFileRow;
import '../../render/visible_text.dart';

/// The orchestration view of one agent without scrolling its transcript: a
/// sheet over the session.
///
/// In order: where it stands (status and the time in it), the goal (the first
/// message), the plan, what it changed across the whole session (tap a file
/// for its diff), the commands it ran with their exit codes, its subagents,
/// mode and model, context and cost where the agent reports them, and what
/// waits for the person. A part the session has nothing for is absent, never
/// an empty placeholder.
///
/// It reads the same per-turn summaries as the folds ([overviewOf], memoized
/// per transcript list), and rebuilds only when one of the lists it reads is
/// replaced: a streaming answer touches none of them.
Future<void> showSessionOverview(BuildContext context, AgentSessionView session) =>
    showAppSheet<void>(context, builder: (ctx) => SessionOverview(session: session));

class _Snap {
  const _Snap(this.s, this.phase, this.since, this.unseen);

  final AgentSessionState s;
  final AgentPhase phase;
  final DateTime? since;
  final bool unseen;

  bool sameAs(_Snap o) =>
      phase == o.phase &&
      since == o.since &&
      unseen == o.unseen &&
      identical(s.items, o.s.items) &&
      identical(s.plan, o.s.plan) &&
      identical(s.pending, o.s.pending) &&
      identical(s.usage, o.s.usage) &&
      identical(s.turnUsage, o.s.turnUsage) &&
      identical(s.configOptions, o.s.configOptions) &&
      identical(s.modes, o.s.modes) &&
      identical(s.subagents, o.s.subagents);
}

class SessionOverview extends StatefulWidget {
  const SessionOverview({super.key, required this.session});

  final AgentSessionView session;

  @override
  State<SessionOverview> createState() => _SessionOverviewState();
}

class _SessionOverviewState extends State<SessionOverview> {
  /// Toggles of the sheet: a file's diff (`path`, `path:all`), a command.
  final _open = <String>{};
  int _filesShown = overviewFiles;

  void _toggle(String id) => setState(() => _open.contains(id) ? _open.remove(id) : _open.add(id));

  /// Closes the sheet, then [then] runs with the context under it.
  void _leave(void Function(BuildContext context) then) {
    final navigator = Navigator.of(context)..pop();
    // ignore: use_build_context_synchronously
    then(navigator.context);
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return SessionSelect<_Snap>(
      session: session,
      select: (s) => _Snap(s.state, s.phase, s.phaseSince, s.unseenDone),
      same: (a, b) => a.sameAs(b),
      builder: (context, snap) {
        final ds = context.ds;
        final state = snap.s;
        final model = overviewOf(state.items);
        final progress = planProgress(state.plan);
        final chips = sessionChipsOf(state).all.where(
          (c) => c.kind == SessionChipKind.mode || c.kind == SessionChipKind.model || c.kind == SessionChipKind.effort,
        );
        final usage = state.usage;
        final runs = state.subagents;
        final observed = session.subagents;
        return SheetScaffold(
          title: 'Session overview',
          kind: SheetKind.list,
          child: Padding(
            // The list kind's inset 4 + 12: the facts sit 16 from the edge.
            padding: const EdgeInsets.symmetric(horizontal: Gap.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _StatusRow(snap: snap),
                if (model.goal != null) ...[
                  _Section('Goal'),
                  Text(
                    visibleText(model.goal!),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Type.compact.copyWith(color: ds.text),
                  ),
                ],
                if (progress != null) ...[
                  _Section('Plan', detail: '${progress.done} of ${progress.total} done'),
                  _Bar(fraction: progress.done / progress.total, color: ds.done),
                  if (progress.current != null)
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.sm),
                      child: Text(
                        visibleText(progress.current!),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Type.secondary.copyWith(color: ds.textSecondary),
                      ),
                    ),
                ],
                if (model.files.isNotEmpty) ..._changed(context, model),
                if (model.commands.isNotEmpty) ..._commands(context, model),
                if (runs.isNotEmpty || observed.isNotEmpty) ..._subagents(context, state, runs, observed),
                if (chips.isNotEmpty) ..._settings(context, chips),
                if (usage != null || state.turnUsage != null) ..._usage(context, usage, state.turnUsage),
                if (state.pending.isNotEmpty) ..._pending(context, state.pending),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _changed(BuildContext context, SessionOverviewModel model) {
    final ds = context.ds;
    final files = model.files;
    final shown = files.length <= _filesShown ? files.length : _filesShown;
    final more = files.length - shown;
    return [
      _Section(
        'Changed',
        detail: countOf(files.length, 'file'),
        trailing: DiffStats(added: model.added, removed: model.removed),
      ),
      ClipRRect(
        borderRadius: BorderRadius.circular(Radii.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < shown; i++)
              ChangedFileRow(
                key: ValueKey(files[i].path),
                rowKey: 'overview:${files[i].path}',
                file: files[i],
                last: i == shown - 1 && more == 0,
                open: _open.contains('file:${files[i].path}'),
                all: _open.contains(allKey('file:${files[i].path}')),
                onToggle: (id) => _toggle(id.startsWith('overview:') ? id.replaceFirst('overview:', 'file:') : id),
              ),
            if (more > 0)
              PressRow(
                onTap: () => setState(() => _filesShown += 16),
                minHeight: kMinTap,
                padding: const EdgeInsets.symmetric(horizontal: Gap.md - PressRow.inset),
                child: Text('$more more', style: Type.labelStrong.copyWith(color: ds.accentText)),
              ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _commands(BuildContext context, SessionOverviewModel model) {
    return [
      _Section(
        'Commands',
        detail: '${model.commandCount}',
        alert: model.failedCommands > 0 ? '${model.failedCommands} failed' : null,
      ),
      for (final (i, c) in model.commands.indexed)
        _CommandRow(command: c, open: _open.contains('cmd:$i'), onTap: () => _toggle('cmd:$i')),
    ];
  }

  List<Widget> _subagents(
    BuildContext context,
    AgentSessionState state,
    List<SubagentRun> runs,
    List<SubagentEntry> observed,
  ) {
    final ds = context.ds;
    final String text;
    if (runs.isNotEmpty) {
      text = groupTitle(
        runs,
        blockedRunIds(state),
        live: runsAreLive(state, linkLive: widget.session.link == AgentLink.live),
      );
    } else {
      final running = observed.where((e) => e.state == SubagentState.running).length;
      text = [countOf(observed.length, 'subagent'), if (running > 0) '$running running'].join(' · ');
    }
    return [
      _Section('Subagents'),
      PressRow(
        onTap: () => _leave((c) => unawaited(showSubagents(c, widget.session))),
        minHeight: kMinTap,
        padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
        child: Row(
          children: [
            Icon(HerdrIcons.agents, size: IconSize.row, color: ds.textSecondary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(text, style: Type.secondaryStrong.copyWith(color: ds.text)),
            ),
            Icon(LucideIcons.chevronRight, size: IconSize.inline, color: ds.textTertiary),
          ],
        ),
      ),
    ];
  }

  List<Widget> _settings(BuildContext context, Iterable<SessionChip> chips) {
    final ds = context.ds;
    return [
      _Section('Mode and model'),
      for (final c in chips)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.xs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: _nameWidth,
                    child: Text(visibleText(c.title), style: Type.secondary.copyWith(color: ds.textMuted)),
                  ),
                  if (c.risk == ModeRisk.dangerous)
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.hair, right: Gap.sm),
                      child: Icon(LucideIcons.triangleAlert, size: IconSize.inline, color: ds.dangerText),
                    ),
                  Expanded(
                    child: Text(
                      visibleText(c.label),
                      style: Type.secondaryStrong.copyWith(
                        color: c.risk == ModeRisk.dangerous ? ds.dangerText : ds.text,
                      ),
                    ),
                  ),
                ],
              ),
              // The why stays quiet even for a dangerous mode: the warning
              // and the mode's name already say it, and red here was one of
              // six on the sheet, louder than what needs the person.
              if (c.isRisky && c.reason != null)
                Padding(
                  padding: const EdgeInsets.only(left: _nameWidth, top: Gap.hair),
                  child: Text(c.reason!, style: Type.caption.copyWith(color: ds.textSecondary)),
                ),
            ],
          ),
        ),
    ];
  }

  List<Widget> _usage(BuildContext context, AcpUsage? usage, TurnUsage? turn) {
    final ds = context.ds;
    final fraction = contextFraction(usage);
    final percent = fraction == null ? null : (fraction * 100).round().clamp(0, 100);
    final warn = fraction != null && fraction >= contextWarnAt;
    final cost = usage?.costAmount;
    // A context nearly full is worth a look, not a failure: past
    // [contextWarnAt] the bar takes the working colour and the words their
    // weight, never the danger red, which on this sheet is for what failed.
    return [
      _Section('Context and cost'),
      if (fraction != null) ...[
        _Bar(fraction: fraction, color: warn ? ds.working : ds.textSecondary),
        Padding(
          padding: const EdgeInsets.only(top: Gap.sm),
          child: Text(
            '${formatTokens(usage!.used)} of ${formatTokens(usage.size)} tokens · $percent% of context',
            style: (warn ? Type.secondaryStrong : Type.secondary).copyWith(
              color: ds.textSecondary,
              fontFeatures: Type.tabular,
            ),
          ),
        ),
      ],
      if (cost != null) _Fact('Cost', formatCost(cost, usage!.costCurrency)),
      if (turn != null) _Fact('Last turn', _turnWords(turn)),
    ];
  }

  static String _turnWords(TurnUsage t) => [
    '${formatTokens(t.totalTokens)} tokens',
    if (t.inputTokens > 0 || t.outputTokens > 0)
      '${formatTokens(t.inputTokens)} in · ${formatTokens(t.outputTokens)} out',
  ].join(' · ');

  List<Widget> _pending(BuildContext context, List<PendingRequest> pending) {
    final ds = context.ds;
    return [
      _Section('Needs you', detail: '${pending.length}', detailColor: ds.blockedText),
      for (final p in pending.take(3))
        PressRow(
          onTap: () => Navigator.of(context).pop(),
          minHeight: kMinTap,
          padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: Gap.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: Gap.hair),
                child: StatusGlyph(status: AgentStatus.blocked, size: IconSize.row),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _pendingText(p),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Type.secondaryStrong.copyWith(color: ds.text),
                    ),
                    if (p.origin != null)
                      Text(
                        'From subagent: ${visibleText(p.origin!.label)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Type.caption.copyWith(color: ds.textSecondary),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      if (pending.length > 3)
        Padding(
          padding: const EdgeInsets.only(left: Gap.xs, top: Gap.hair),
          child: Text('${pending.length - 3} more', style: Type.caption.copyWith(color: ds.textMuted)),
        ),
    ];
  }

  static String _pendingText(PendingRequest p) => switch (p) {
    PendingPermission(:final request) => describePermission(request).title,
    PendingQuestion(:final request) => visibleText(
      request.message.trim().split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => 'A question'),
    ),
  };
}

class _Section extends StatelessWidget {
  const _Section(this.title, {this.detail, this.detailColor, this.alert, this.trailing});

  final String title;
  final String? detail;
  final Color? detailColor;

  /// What failed, after [detail], in the danger text: the one red words of
  /// the sheet (`2 · 1 failed`: the total stays quiet).
  final String? alert;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xl, bottom: Gap.sm),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text.rich(
                TextSpan(
                  text: title,
                  style: Type.labelStrong.copyWith(color: ds.textSecondary),
                  children: [
                    if (detail != null)
                      TextSpan(
                        text: ' · $detail',
                        style: Type.label.copyWith(color: detailColor ?? ds.textMuted, fontFeatures: Type.tabular),
                      ),
                    if (alert != null) ...[
                      TextSpan(
                        text: ' · ',
                        style: Type.label.copyWith(color: ds.textMuted),
                      ),
                      TextSpan(
                        text: alert,
                        style: Type.label.copyWith(color: ds.dangerText, fontFeatures: Type.tabular),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: Gap.sm), trailing!],
        ],
      ),
    );
  }
}

/// A thin bar: a track and a fill by [fraction]. Never animated.
class _Bar extends StatelessWidget {
  const _Bar({required this.fraction, required this.color});

  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.pill),
        child: SizedBox(
          height: _barHeight,
          child: Stack(
            children: [
              Positioned.fill(child: ColoredBox(color: ds.fillPressed)),
              Positioned.fill(
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: fraction.clamp(0.0, 1.0),
                  child: ColoredBox(color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.name, this.value);

  final String name;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _nameWidth,
            child: Text(name, style: Type.secondary.copyWith(color: ds.textMuted)),
          ),
          Expanded(
            child: Text(
              value,
              style: Type.secondary.copyWith(color: ds.text, fontFeatures: Type.tabular),
            ),
          ),
        ],
      ),
    );
  }
}

/// `Working · 4 min`: the status the glyph shows, in words, and how long.
class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.snap});

  final _Snap snap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final status = sessionStatus(snap.phase, unseenDone: snap.unseen);
    final since = snap.since;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.sm),
      child: Row(
        children: [
          StatusGlyph(status: status, size: IconSize.row),
          const SizedBox(width: Gap.md),
          Expanded(
            child: MinuteBuilder(
              builder: (context, _) {
                final time = since == null ? null : Elapsed.compact(statusNow().difference(since));
                return Text(
                  [status.label, ?time].join(' · '),
                  style: Type.answer.copyWith(color: status.textColor(ds), fontFeatures: Type.tabular),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// One command: the command in mono on a line, `exit 1` at the end, muted
/// even when it failed (the failed disc in front already says so, in the
/// one red the row has); a tap shows all of it.
class _CommandRow extends StatelessWidget {
  const _CommandRow({required this.command, required this.open, required this.onTap});

  final CommandRun command;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final code = command.signal != null && command.signal!.isNotEmpty
        ? 'signal ${visibleText(command.signal!)}'
        : (command.exitCode == null ? null : 'exit ${command.exitCode}');
    final mono = Mono.base.copyWith(color: ds.text);
    final text = visibleText(command.command);
    return Semantics(
      expanded: open,
      child: PressRow(
        onTap: onTap,
        semanticLabel: [text, if (command.failed) 'failed', ?code].join(', '),
        minHeight: kMinTap,
        padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: Gap.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: Gap.hair),
              child: command.failed
                  ? const StatusGlyph.failed(size: IconSize.row)
                  : Icon(LucideIcons.terminal, size: IconSize.row, color: ds.textSecondary),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(text, maxLines: open ? 8 : 1, overflow: TextOverflow.ellipsis, style: mono),
            ),
            if (code != null) ...[
              const SizedBox(width: Gap.sm),
              Text(
                code,
                style: Type.caption.copyWith(color: ds.textMuted, fontFeatures: Type.tabular),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Width of the name column of a fact row (`Cost`, `Mode`), so values line up.
const _nameWidth = 72.0;

/// Thickness of the context bar.
const _barHeight = 4.0;
