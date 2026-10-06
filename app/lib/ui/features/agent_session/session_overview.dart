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
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/step_clock.dart';
import '../../core/theme.dart';
import 'log_atoms.dart';
import 'observed_widgets.dart' show WorkingLabel;
import 'permission_subject.dart';
import 'session_bar.dart' show sessionStatus;
import 'session_overview_model.dart';
import 'session_select.dart';
import 'status_line.dart' show statusNow;
import 'subagent_format.dart';
import 'subagent_roster.dart';
import 'transcript_rows.dart' show allKey;
import 'changed_card.dart' show ChangedFileRow;
import 'visible_text.dart';

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
        return Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 8, Gap.lg, Gap.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Semantics(
                  header: true,
                  child: Text('Session overview', style: Type.label.copyWith(color: ds.textSecondary)),
                ),
              ),
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
                    padding: const EdgeInsets.only(top: 6),
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
        detail: files.length == 1 ? '1 file' : '${files.length} files',
        trailing: DiffStats(added: model.added, removed: model.removed),
      ),
      ClipRRect(
        borderRadius: BorderRadius.circular(Radii.panel),
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
              PressBuilder(
                onTap: () => setState(() => _filesShown += 16),
                builder: (context, pressed) => Container(
                  constraints: const BoxConstraints(minHeight: kMinTap),
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                  color: pressed ? ds.fillPressed : ds.fill,
                  child: Text(
                    '$more more',
                    style: Type.secondary.copyWith(color: ds.textSecondary, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _commands(BuildContext context, SessionOverviewModel model) {
    final ds = context.ds;
    return [
      _Section(
        'Commands',
        detail: [
          '${model.commandCount}',
          if (model.failedCommands > 0) '${model.failedCommands} failed',
        ].join(' · '),
        detailColor: model.failedCommands > 0 ? ds.dangerText : null,
      ),
      for (final (i, c) in model.commands.indexed)
        _CommandRow(
          command: c,
          open: _open.contains('cmd:$i'),
          onTap: () => _toggle('cmd:$i'),
        ),
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
      text = groupTitle(runs, blockedRunIds(state), live: runsAreLive(state, linkLive: widget.session.link == AgentLink.live));
    } else {
      final running = observed.where((e) => e.state == SubagentState.running).length;
      text = [
        observed.length == 1 ? '1 subagent' : '${observed.length} subagents',
        if (running > 0) '$running running',
      ].join(' · ');
    }
    return [
      _Section('Subagents'),
      PressBuilder(
        onTap: () => _leave((c) => unawaited(showSubagents(c, widget.session))),
        builder: (context, pressed) => AnimatedContainer(
          duration: Motion.pressing(pressed),
          curve: Motion.easeOut,
          constraints: const BoxConstraints(minHeight: kMinTap),
          padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
          decoration: BoxDecoration(
            color: pressed ? ds.fill : Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.row),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.bot, size: 16, color: ds.textSecondary),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: Type.secondary.copyWith(color: ds.text, fontWeight: FontWeight.w500))),
              Icon(LucideIcons.chevronRight, size: 14, color: ds.textTertiary),
            ],
          ),
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
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 72,
                    child: Text(visibleText(c.title), style: Type.secondary.copyWith(color: ds.textMuted)),
                  ),
                  if (c.risk == ModeRisk.dangerous)
                    Padding(
                      padding: const EdgeInsets.only(top: 2, right: 6),
                      child: Icon(LucideIcons.triangleAlert, size: 14, color: ds.dangerText),
                    ),
                  Expanded(
                    child: Text(
                      visibleText(c.label),
                      style: Type.secondary.copyWith(
                        color: c.risk == ModeRisk.dangerous ? ds.dangerText : ds.text,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              if (c.isRisky && c.reason != null)
                Padding(
                  padding: const EdgeInsets.only(left: 72, top: 2),
                  child: Text(
                    c.reason!,
                    style: Type.caption.copyWith(color: c.risk == ModeRisk.dangerous ? ds.dangerText : ds.textSecondary),
                  ),
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
    return [
      _Section('Context and cost'),
      if (fraction != null) ...[
        _Bar(fraction: fraction, color: warn ? ds.danger : ds.textSecondary),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '${formatTokens(usage!.used)} of ${formatTokens(usage.size)} tokens · $percent% of context',
            style: Type.secondary.copyWith(
              color: warn ? ds.dangerText : ds.textSecondary,
              fontWeight: warn ? FontWeight.w600 : FontWeight.w400,
              fontFeatures: Type.tabular,
            ),
          ),
        ),
      ],
      if (cost != null)
        _Fact('Cost', formatCost(cost, usage!.costCurrency)),
      if (turn != null) _Fact('Last turn', _turnWords(turn)),
    ];
  }

  static String _turnWords(TurnUsage t) => [
    '${formatTokens(t.totalTokens)} tokens',
    if (t.inputTokens > 0 || t.outputTokens > 0) '${formatTokens(t.inputTokens)} in · ${formatTokens(t.outputTokens)} out',
  ].join(' · ');

  List<Widget> _pending(BuildContext context, List<PendingRequest> pending) {
    final ds = context.ds;
    return [
      _Section('Waiting for you', detail: '${pending.length}', detailColor: ds.blockedText),
      for (final p in pending.take(3))
        PressBuilder(
          onTap: () => Navigator.of(context).pop(),
          builder: (context, pressed) => AnimatedContainer(
            duration: Motion.pressing(pressed),
            curve: Motion.easeOut,
            constraints: const BoxConstraints(minHeight: kMinTap),
            padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: 6),
            decoration: BoxDecoration(
              color: pressed ? ds.fill : Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.row),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: StatusGlyph(status: AgentStatus.blocked, size: 16),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _pendingText(p),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Type.secondary.copyWith(color: ds.text, fontWeight: FontWeight.w500),
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
        ),
      if (pending.length > 3)
        Padding(
          padding: const EdgeInsets.only(left: Gap.xs, top: 2),
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
  const _Section(this.title, {this.detail, this.detailColor, this.trailing});

  final String title;
  final String? detail;
  final Color? detailColor;
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
                  style: Type.label.copyWith(color: ds.textSecondary, fontWeight: FontWeight.w600),
                  children: [
                    if (detail != null)
                      TextSpan(
                        text: ' · $detail',
                        style: Type.label.copyWith(
                          color: detailColor ?? ds.textMuted,
                          fontWeight: FontWeight.w500,
                          fontFeatures: Type.tabular,
                        ),
                      ),
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
        borderRadius: BorderRadius.circular(2),
        child: SizedBox(
          height: 4,
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
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 72, child: Text(name, style: Type.secondary.copyWith(color: ds.textMuted))),
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
          StatusGlyph(status: status, size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: MinuteBuilder(
              builder: (context, _) {
                final time = since == null ? null : WorkingLabel.elapsed(statusNow().difference(since));
                return Text(
                  [status.label, ?time].join(' · '),
                  style: Type.compact.copyWith(
                    color: status.textColor(ds),
                    fontWeight: FontWeight.w600,
                    fontFeatures: Type.tabular,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// One command: the command in mono on a line, `exit 1` at the end (the
/// danger text and a cross when it failed); a tap shows all of it.
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
    final mono = TextStyle(fontFamily: monoFamily, fontSize: 12.5, color: ds.text);
    final text = visibleText(command.command);
    return Semantics(
      expanded: open,
      child: PressBuilder(
        onTap: onTap,
        semanticLabel: [text, if (command.failed) 'failed', ?code].join(', '),
        builder: (context, pressed) => AnimatedContainer(
          duration: Motion.pressing(pressed),
          curve: Motion.easeOut,
          constraints: const BoxConstraints(minHeight: kMinTap),
          padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: 6),
          decoration: BoxDecoration(
            color: pressed ? ds.fill : Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.row),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: command.failed
                    ? Icon(LucideIcons.circleX, size: 16, color: ds.danger)
                    : Icon(LucideIcons.terminal, size: 16, color: ds.textSecondary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  maxLines: open ? 8 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono,
                ),
              ),
              if (code != null) ...[
                const SizedBox(width: Gap.sm),
                Text(
                  code,
                  style: Type.caption.copyWith(
                    color: command.failed ? ds.dangerText : ds.textMuted,
                    fontWeight: command.failed ? FontWeight.w600 : FontWeight.w500,
                    fontFeatures: Type.tabular,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
