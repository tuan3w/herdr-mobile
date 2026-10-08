import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/subagents/subagent_run.dart';
import '../../../data/acp/turns/plain_text.dart' show safeEnd;
import '../../../data/repositories/agent_session.dart';
import '../../core/controls.dart';
import '../../core/markdown/markdown.dart';
import '../../core/rows.dart' show EmptyState;
import '../../core/theme.dart';
import 'agent_md_scope.dart';
import 'log_atoms.dart';
import 'permission_dock.dart';
import 'session_select.dart';
import 'subagent_card.dart';
import 'subagent_format.dart';
import 'subagent_run_session.dart';
import 'transcript_view.dart';
import 'visible_text.dart';

/// A subagent opened from the roster or its card: a pushed, read-only screen.
///
/// A run with a transcript (Claude's, or omp's when its log on the host could
/// be read) is drawn by the transcript widgets over its own conversation
/// ([SubagentRunSession]), with the prompt pinned above and no composer; a
/// transcript read from a log says so once, under the prompt
/// ([LogOriginNote]). A run without one (omp when its log cannot be read,
/// Codex) opens its summary ([SubagentSummaryBody]) and says once that it is
/// one. While the screen is open the session reads the omp log
/// ([AgentSessionView.watchSubagentLog]); the summary says only that it is
/// loading it or that the read failed ([LogStatusLine]). A request the
/// subagent asks sits in the dock below, as in the main screen.
class SubagentRunScreen extends StatefulWidget {
  const SubagentRunScreen({super.key, required this.session, required this.runId});

  /// The session that owns the run.
  final AgentSessionView session;
  final String runId;

  @override
  State<SubagentRunScreen> createState() => _SubagentRunScreenState();
}

class _SubagentRunScreenState extends State<SubagentRunScreen> {
  SubagentRunSession? _child;

  SubagentRunSession get child => _child ??= SubagentRunSession(widget.session, widget.runId);

  @override
  void initState() {
    super.initState();
    widget.session.watchSubagentLog(widget.runId, true);
  }

  @override
  void dispose() {
    widget.session.watchSubagentLog(widget.runId, false);
    _child?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final session = widget.session;
    return Scaffold(
      backgroundColor: ds.bg,
      body: Column(
        children: [
          _RunBar(session: session, runId: widget.runId),
          RunStateStrip(session: session, runId: widget.runId),
          Expanded(
            child: SessionSelect<(bool, bool)>(
              session: session,
              select: (s) {
                final run = s.subagentRun(widget.runId);
                return (run != null, run?.hasTranscript ?? false);
              },
              builder: (context, v) {
                final (exists, transcript) = v;
                if (!exists) {
                  return const EmptyState(
                    icon: LucideIcons.bot,
                    title: 'Subagent gone',
                    message: 'The agent no longer lists this subagent.',
                  );
                }
                if (!transcript) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LogStatusLine(session: session, runId: widget.runId),
                      Expanded(child: SubagentSummaryBody(session: session, runId: widget.runId)),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PinnedPrompt(session: session, runId: widget.runId),
                    LogOriginNote(session: session, runId: widget.runId),
                    Expanded(child: TranscriptView(session: child)),
                  ],
                );
              },
            ),
          ),
          Flexible(
            flex: 0,
            child: SafeArea(top: false, child: PromptDock(session: session, forRun: widget.runId)),
          ),
        ],
      ),
    );
  }
}

/// The slim bar of the screen: back, the run's description over what it is.
class _RunBar extends StatelessWidget {
  const _RunBar({required this.session, required this.runId});

  final AgentSessionView session;
  final String runId;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        child: Row(
          children: [
            CircleButton(
              icon: LucideIcons.chevronLeft,
              tooltip: 'Back',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: Gap.xs),
            Expanded(
              child: SessionSelect<(String, String?)>(
                session: session,
                select: (s) {
                  final run = s.subagentRun(runId);
                  return (run == null ? 'Subagent' : runTitle(run), run?.agentType);
                },
                builder: (context, v) {
                  final (title, type) = v;
                  final kind = type == null || type.trim().isEmpty ? 'Subagent' : 'Subagent · ${visibleText(type.trim())}';
                  return ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 52),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Semantics(
                            header: true,
                            child: Text(
                              visibleText(title),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Type.barTitle.copyWith(color: ds.text),
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            kind,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Type.secondary.copyWith(color: ds.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StripSnap {
  const _StripSnap(this.run, this.blocked, this.live);

  final SubagentRun? run;
  final Set<String> blocked;
  final bool live;

  bool sameAs(_StripSnap o) => identical(run, o.run) && live == o.live && setEquals(blocked, o.blocked);
}

/// The state of the run in one line under the bar: its shape, `running 42s ·
/// Grep · 7 tools` or `Explore · done · 31s · 12 tools`.
class RunStateStrip extends StatelessWidget {
  const RunStateStrip({super.key, required this.session, required this.runId});

  final AgentSessionView session;
  final String runId;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return SessionSelect<_StripSnap>(
      session: session,
      select: (s) => _StripSnap(
        s.subagentRun(runId),
        blockedRunIds(s.state),
        runsAreLive(s.state, linkLive: s.link == AgentLink.live),
      ),
      same: (a, b) => a.sameAs(b),
      builder: (context, snap) {
        final run = snap.run;
        if (run == null) return const SizedBox.shrink();
        final tone = toneOf(run, blocked: snap.blocked, live: snap.live);
        return Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: 6),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ds.hairline))),
          child: RunClock(
            run: run,
            tone: tone,
            builder: (context, now) {
              final line = runLine(run, tone, now: now);
              return Row(
                children: [
                  RunGlyph(tone: tone),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Semantics(
                      liveRegion: false,
                      label: line,
                      child: ExcludeSemantics(
                        child: Text(
                          line,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Type.secondary.copyWith(
                            color: runLineColor(ds, tone),
                            fontWeight: FontWeight.w500,
                            fontFeatures: Type.tabular,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

/// What the subagent was asked, pinned above its conversation: three lines,
/// and a tap shows all of it (bounded, scrolling).
class PinnedPrompt extends StatefulWidget {
  const PinnedPrompt({super.key, required this.session, required this.runId});

  final AgentSessionView session;
  final String runId;

  @override
  State<PinnedPrompt> createState() => _PinnedPromptState();
}

class _PinnedPromptState extends State<PinnedPrompt> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return SessionSelect<String?>(
      session: widget.session,
      select: (s) => s.subagentRun(widget.runId)?.assignment,
      builder: (context, assignment) {
        final text = assignment?.trim() ?? '';
        if (text.isEmpty) return const SizedBox.shrink();
        final shown = visibleText(text);
        final maxOpen = MediaQuery.sizeOf(context).height * 0.4;
        return Semantics(
          expanded: _open,
          child: PressBuilder(
            onTap: () => setState(() => _open = !_open),
            builder: (context, pressed) => Container(
              constraints: const BoxConstraints(minHeight: kMinTap),
              padding: const EdgeInsets.fromLTRB(Gap.lg, 8, Gap.md, 8),
              decoration: BoxDecoration(
                color: pressed ? ds.fillPressed : ds.fill,
                border: Border(bottom: BorderSide(color: ds.hairline)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Asked to',
                          style: Type.caption.copyWith(color: ds.textMuted, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        if (_open)
                          ConstrainedBox(
                            constraints: BoxConstraints(maxHeight: maxOpen),
                            child: SingleChildScrollView(
                              child: Text(shown, style: Type.secondary.copyWith(color: ds.text)),
                            ),
                          )
                        else
                          Text(
                            shown,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: Type.secondary.copyWith(color: ds.text),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Gap.sm),
                  Padding(padding: const EdgeInsets.only(top: 4), child: Caret(open: _open)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Under the prompt of a transcript that came from the agent's own log on the
/// host rather than from the agent's stream: where it came from, once, and
/// that the start of it is missing when the log was longer than what was read.
/// Nothing for a transcript the agent sent.
class LogOriginNote extends StatelessWidget {
  const LogOriginNote({super.key, required this.session, required this.runId});

  final AgentSessionView session;
  final String runId;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return SessionSelect<SubagentLogInfo?>(
      session: session,
      select: (s) => s.subagentRun(runId)?.log,
      builder: (context, log) {
        if (log == null) return const SizedBox.shrink();
        final text = [
          'From ${session.agentLabel}’s log on the host',
          if (log.earlierNotShown) 'Earlier part not shown',
          if (log.skippedLines > 0) '${log.skippedLines} oversized ${log.skippedLines == 1 ? 'line' : 'lines'} left out',
        ].join(' · ');
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: 6),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ds.hairline))),
          child: Row(
            children: [
              Icon(LucideIcons.fileText, size: 14, color: ds.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(text, style: Type.caption.copyWith(color: ds.textSecondary)),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Above a summary: that the subagent's log is being read, or could not be
/// (the connection failed; tap to try again). Nothing once the log is shown,
/// and nothing when there is no log to read: the summary stands on its own.
class LogStatusLine extends StatelessWidget {
  const LogStatusLine({super.key, required this.session, required this.runId});

  final AgentSessionView session;
  final String runId;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return SessionSelect<SubagentLogStatus>(
      session: session,
      select: (s) => s.subagentLogStatus(runId),
      builder: (context, status) {
        if (status != SubagentLogStatus.loading && status != SubagentLogStatus.failed) return const SizedBox.shrink();
        final failed = status == SubagentLogStatus.failed;
        final row = Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: kMinTap),
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ds.hairline))),
          child: Row(
            children: [
              if (failed)
                Icon(LucideIcons.refreshCw, size: 14, color: ds.textSecondary)
              else
                const BusySpinner(size: 14),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  failed ? 'Couldn’t read the log · Tap to retry' : 'Loading…',
                  style: Type.secondary.copyWith(color: ds.textSecondary),
                ),
              ),
            ],
          ),
        );
        if (!failed) return Semantics(liveRegion: false, label: 'Loading the subagent’s log', child: ExcludeSemantics(child: row));
        return PressBuilder(
          onTap: () => session.retrySubagentLog(runId),
          button: true,
          semanticLabel: 'Couldn’t read the log. Retry',
          builder: (context, pressed) => ColoredBox(color: pressed ? ds.fillPressed : Colors.transparent, child: row),
        );
      },
    );
  }
}

final _resultDocs = Expando<MdDocument>('subagent summary result');

/// The summary of a run the agent sends no conversation for (omp, Codex over
/// ACP): what it was asked, the figures it reported, its latest tools and
/// output (a few lines, mono), the note it left, why it failed, and what it
/// handed back. The one place that says it is a summary, once.
class SubagentSummaryBody extends StatelessWidget {
  const SubagentSummaryBody({super.key, required this.session, required this.runId});

  final AgentSessionView session;
  final String runId;

  @override
  Widget build(BuildContext context) => AgentMdScope(
    session: session,
    child: SessionSelect<SubagentRun?>(
      session: session,
      select: (s) => s.subagentRun(runId),
      same: identical,
      builder: (context, run) {
        if (run == null) return const SizedBox.shrink();
        final rows = _rows(context, run);
        return SelectionArea(
          child: ListView.builder(
            padding: EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.lg + MediaQuery.paddingOf(context).bottom),
            itemCount: rows.length,
            itemBuilder: (context, i) => rows[i](context),
          ),
        );
      },
    ),
  );

  List<WidgetBuilder> _rows(BuildContext context, SubagentRun run) {
    final ds = context.ds;
    final facts = <(String, String)>[
      if (run.model != null && run.model!.trim().isNotEmpty) ('Model', visibleText(run.model!.trim())),
      if (run.tokens != null) ('Tokens', formatTokens(run.tokens!)),
      if (run.cost != null) ('Cost', formatCost(run.cost!, 'USD')),
      if (run.percent != null) ('Progress', '${run.percent}%'),
    ];
    final retry = run.retry;
    final assignment = run.assignment?.trim() ?? '';
    final output = [for (final l in run.recentOutput) if (l.trim().isNotEmpty) _clip(visibleText(l), 300)];
    final result = run.result?.trim() ?? '';
    final doc = result.isEmpty ? null : (_resultDocs[run] ??= parseMd(result));
    final why = failureText(run);
    final note = run.note?.trim();
    Widget section(String title) => Padding(
      padding: const EdgeInsets.only(top: Gap.lg, bottom: Gap.xs),
      child: Semantics(
        header: true,
        child: Text(title, style: Type.label.copyWith(color: ds.textSecondary, fontWeight: FontWeight.w600)),
      ),
    );
    return [
      (c) => Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(color: ds.fill, borderRadius: BorderRadius.circular(Radii.chip)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: 2), child: Icon(LucideIcons.info, size: 16, color: ds.textSecondary)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Summary only. ${session.agentLabel} sends a summary of its subagents, not their conversation.',
                style: Type.secondary.copyWith(color: ds.textSecondary),
              ),
            ),
          ],
        ),
      ),
      if (facts.isNotEmpty)
        (c) => Padding(
          padding: const EdgeInsets.only(top: Gap.md),
          child: Wrap(
            spacing: Gap.lg,
            runSpacing: Gap.xs,
            children: [
              for (final (k, v) in facts)
                Text.rich(
                  TextSpan(
                    text: '$k  ',
                    style: Type.secondary.copyWith(color: ds.textMuted),
                    children: [
                      TextSpan(
                        text: v,
                        style: Type.secondary.copyWith(color: ds.text, fontFeatures: Type.tabular),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      if (retry != null)
        (c) => Padding(
          padding: const EdgeInsets.only(top: Gap.md),
          child: Text(
            [
              retry.maxAttempts == null ? 'Retrying' : 'Retrying, attempt ${retry.attempt} of ${retry.maxAttempts}',
              if (retry.delay != null) 'in ${elapsedWords(retry.delay!)}',
              if (retry.message.trim().isNotEmpty) visibleText(retry.message.trim()),
            ].join(' · '),
            style: Type.secondary.copyWith(color: ds.textSecondary),
          ),
        ),
      if (assignment.isNotEmpty) ...[
        (c) => section('Asked to'),
        (c) => Text(visibleText(assignment), style: Type.compact.copyWith(color: ds.text)),
      ],
      if (run.recentTools.isNotEmpty || (run.lastToolLine ?? '').isNotEmpty) ...[
        (c) => section(run.isActive ? 'Doing now' : 'Latest tools'),
        if ((run.lastToolLine ?? '').trim().isNotEmpty)
          (c) => Text(
            _clip(visibleText(run.lastToolLine!.trim()), 300),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontFamily: monoFamily, fontSize: 12.5, color: ds.text),
          ),
        if (run.recentTools.isNotEmpty)
          (c) => Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(
              run.recentTools.map(visibleText).join(' · '),
              style: Type.secondary.copyWith(color: ds.textSecondary),
            ),
          ),
      ],
      if (output.isNotEmpty) ...[
        (c) => section('Recent output'),
        (c) => Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(color: ds.fill, borderRadius: BorderRadius.circular(Radii.chip)),
          child: Text(
            output.join('\n'),
            style: TextStyle(fontFamily: monoFamily, fontSize: 11.5, height: 1.4, color: ds.textSecondary),
          ),
        ),
      ],
      if (note != null && note.isNotEmpty && (doc == null))
        (c) => Padding(
          padding: const EdgeInsets.only(top: Gap.md),
          child: Text(visibleText(note), style: Type.secondary.copyWith(color: ds.textSecondary)),
        ),
      if (why != null && why.isNotEmpty) ...[
        (c) => section('Why it stopped'),
        (c) => Text(visibleText(why), style: Type.compact.copyWith(color: ds.dangerText)),
      ],
      if (doc != null) ...[
        (c) => section('Result'),
        for (var i = 0; i < doc.blocks.length; i++)
          (c) => Padding(
            padding: EdgeInsets.only(top: mdBlockGap(i == 0 ? null : doc.blocks[i - 1], doc.blocks[i])),
            child: MdToneScope(tone: MdTone.quiet, child: MdBlockView(block: doc.blocks[i])),
          ),
      ],
    ];
  }

  static String _clip(String s, int max) => s.length <= max ? s : '${s.substring(0, safeEnd(s, max - 1))}…';
}

/// `30 s`, `2 min`: a duration in words for a sentence.
String elapsedWords(Duration d) => d.inSeconds < 90 ? '${d.inSeconds} s' : '${d.inMinutes} min';
