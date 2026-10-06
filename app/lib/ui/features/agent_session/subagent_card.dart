import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/session_state.dart';
import '../../../data/acp/subagents/subagent_run.dart';
import '../../../data/models/herdr_models.dart' show AgentStatus;
import '../../../data/repositories/agent_session.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/markdown/markdown.dart';
import '../../core/motion.dart';
import '../../core/step_clock.dart';
import '../../core/theme.dart';
import 'agent_session_navigation.dart';
import 'log_atoms.dart';
import 'session_select.dart';
import 'status_line.dart' show secondsClock, statusNow;
import 'subagent_format.dart';
import 'tool_rows.dart';
import 'transcript_rows.dart';
import 'visible_text.dart';

/// Which subagent cards are open. Kept per session, not per widget, so a card
/// that scrolls out of the transcript and back is still open (the toggles of
/// the other rows live with the transcript view; a card is not a row of the
/// plan, it has one toggle per run).
class RunExpansion extends ChangeNotifier {
  RunExpansion._();

  static final _byOwner = Expando<RunExpansion>('run expansion');

  /// The expansion state of [owner] (a session object).
  static RunExpansion of(Object owner) => _byOwner[owner] ??= RunExpansion._();

  final _open = <String>{};

  bool isOpen(String runId) => _open.contains(runId);

  void toggle(String runId) {
    if (!_open.remove(runId)) _open.add(runId);
    notifyListeners();
  }
}

/// Builds [builder] with the time now, and again every second while the run
/// is running here (it counts from when this client first saw it): the
/// shared seconds clock is leased only then, and only while the widget is
/// on screen. A run that is not running builds once. Nothing animates.
class RunClock extends StatefulWidget {
  const RunClock({super.key, required this.run, required this.tone, required this.builder});

  final SubagentRun run;
  final RunTone tone;
  final Widget Function(BuildContext context, DateTime now) builder;

  @override
  State<RunClock> createState() => _RunClockState();
}

class _RunClockState extends State<RunClock> with StepClockLease<RunClock> {
  @override
  StepClock get clock => secondsClock;

  @override
  bool get wantsClock => widget.tone == RunTone.running && widget.run.startedAt != null;

  @override
  void didUpdateWidget(RunClock old) {
    super.didUpdateWidget(old);
    syncClock();
  }

  @override
  Widget build(BuildContext context) => wantsClock
      ? ValueListenableBuilder<int>(
          valueListenable: clock.steps,
          builder: (context, _, _) => widget.builder(context, statusNow()),
        )
      : widget.builder(context, statusNow());
}

/// The glyph of a run's tone: the shape says what the colour would.
class RunGlyph extends StatelessWidget {
  const RunGlyph({super.key, required this.tone, this.size = 16});

  final RunTone tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return ExcludeSemantics(
      child: switch (tone) {
        RunTone.waitingForYou => StatusGlyph(status: AgentStatus.blocked, size: size),
        RunTone.starting || RunTone.stale => StatusGlyph(status: AgentStatus.idle, size: size),
        RunTone.running => StatusGlyph(status: AgentStatus.working, size: size),
        RunTone.done => StatusGlyph(status: AgentStatus.done, size: size),
        RunTone.failed => Icon(LucideIcons.circleX, size: size, color: ds.danger),
        RunTone.cancelled => Icon(LucideIcons.ban, size: size, color: ds.textTertiary),
      },
    );
  }
}

/// The colour of a run's live line (words, so a text tone).
Color runLineColor(Ds ds, RunTone tone) => switch (tone) {
  RunTone.waitingForYou => ds.blockedText,
  RunTone.failed => ds.dangerText,
  RunTone.cancelled || RunTone.stale => ds.textMuted,
  _ => ds.textSecondary,
};

/// `3 subagents · 2 running` above the cards of subagents started together.
class SubagentGroupHeader extends StatelessWidget {
  const SubagentGroupHeader({super.key, required this.runs, required this.blocked, required this.live});

  final List<SubagentRun> runs;
  final Set<String> blocked;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final title = groupTitle(runs, blocked, live: live);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.xs, 6, Gap.xs, Gap.xs),
      child: Row(
        children: [
          Icon(LucideIcons.bot, size: 14, color: ds.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: Type.label.copyWith(color: ds.textSecondary, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What the work log shows for the tool call [item] when it started
/// subagents: their cards in place of the plain row (a group header over
/// parallel ones). A call that started none is a [ToolRow].
///
/// The call's own input and output stay reachable: the first card opens to
/// `Call details`, the tool body. A child's own calls never get here: the
/// reducer keeps them out of the transcript.
Widget toolOrSubagentRow({
  required AgentSessionView session,
  required String rowKey,
  required TranscriptTool item,
  required double gap,
  required bool open,
  required bool all,
  required RowToggle onToggle,
  bool nested = false,
}) {
  if (session.subagentsOfToolCall(item.call.toolCallId).isEmpty) {
    return ToolRow(rowKey: rowKey, item: item, gap: gap, open: open, all: all, onToggle: onToggle, nested: nested);
  }
  return SubagentToolRow(rowKey: rowKey, session: session, item: item, gap: gap);
}

class _Snap {
  const _Snap(this.runs, this.group, this.blocked, this.live);

  final List<SubagentRun> runs;

  /// The runs of the group this call heads (two or more); null when it heads none.
  final List<SubagentRun>? group;
  final Set<String> blocked;
  final bool live;

  bool sameAs(_Snap o) =>
      live == o.live &&
      setEquals(blocked, o.blocked) &&
      _sameRuns(runs, o.runs) &&
      (group == null ? o.group == null : o.group != null && _sameRuns(group!, o.group!));

  static bool _sameRuns(List<SubagentRun> a, List<SubagentRun> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }
}

/// The cards of the subagents one tool call started.
class SubagentToolRow extends StatelessWidget {
  const SubagentToolRow({super.key, required this.rowKey, required this.session, required this.item, required this.gap});

  final String rowKey;
  final AgentSessionView session;
  final TranscriptTool item;
  final double gap;

  _Snap _snap(AgentSessionView s) {
    final id = item.call.toolCallId;
    final runs = s.subagentsOfToolCall(id);
    final g = groupOf(id, s.state.items, s.subagentRuns);
    final heads = g != null && g.isGroup && g.firstToolCallId == id;
    return _Snap(runs, heads ? g.runs : null, blockedRunIds(s.state), runsAreLive(s.state, linkLive: s.link == AgentLink.live));
  }

  @override
  Widget build(BuildContext context) {
    notifyRowBuilt(rowKey);
    return SessionSelect<_Snap>(
      session: session,
      select: _snap,
      same: (a, b) => a.sameAs(b),
      builder: (context, snap) => Padding(
        padding: EdgeInsets.only(top: gap),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (snap.group != null) SubagentGroupHeader(runs: snap.group!, blocked: snap.blocked, live: snap.live),
            for (final (i, run) in snap.runs.indexed) ...[
              if (i > 0 || snap.group != null) const SizedBox(height: 6),
              SubagentCard(
                key: ValueKey(run.id),
                session: session,
                run: run,
                tone: toneOf(run, blocked: snap.blocked, live: snap.live),
                callRow: i == 0 ? item : null,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

final _results = Expando<MdDocument>('subagent result');

/// The most of a result a card draws; the screen of the run has the rest.
const cardResultChars = 3000;

/// One subagent: a quiet panel with its description, one live line (`running
/// 42s · Grep · 7 tools`, `Explore · done · 31s · 12 tools`) and a shape for
/// its state. Tapped it opens to what it was asked and what it handed back
/// (as Markdown), with a way into its conversation, or into its summary when
/// the agent does not send one; with [onOpen] a tap goes straight there (the
/// roster) and the card does not open.
///
/// The seconds of a running card come from the shared seconds clock, leased
/// only while the card is running and on screen (nothing animates).
class SubagentCard extends StatefulWidget {
  const SubagentCard({
    super.key,
    required this.session,
    required this.run,
    required this.tone,
    this.callRow,
    this.onOpen,
  });

  final AgentSessionView session;
  final SubagentRun run;
  final RunTone tone;

  /// The tool call that started the run, for `Call details`; null on a card
  /// that does not offer them.
  final TranscriptTool? callRow;
  final VoidCallback? onOpen;

  @override
  State<SubagentCard> createState() => _SubagentCardState();
}

class _SubagentCardState extends State<SubagentCard> {
  bool _details = false;
  bool _detailsAll = false;

  RunExpansion get _expansion => RunExpansion.of(widget.session);

  void _openRun() {
    Haptics.tick();
    unawaited(openSubagentRun(context, widget.session, widget.run.id));
  }

  @override
  Widget build(BuildContext context) {
    final onOpen = widget.onOpen;
    if (onOpen != null) return _panel(open: false);
    return ListenableBuilder(
      listenable: _expansion,
      builder: (context, _) => _panel(open: _expansion.isOpen(widget.run.id)),
    );
  }

  Widget _panel({required bool open}) {
    final ds = context.ds;
    final run = widget.run;
    return DecoratedBox(
      decoration: BoxDecoration(color: ds.fill, borderRadius: BorderRadius.circular(Radii.panel)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RunClock(run: run, tone: widget.tone, builder: (context, now) => _header(open, now)),
          if (open) _body(run),
        ],
      ),
    );
  }

  Widget _header(bool open, DateTime now) {
    final ds = context.ds;
    final run = widget.run;
    final tone = widget.tone;
    final roster = widget.onOpen != null;
    final title = visibleText(runTitle(run));
    final line = runLine(run, tone, now: now);
    final why = tone == RunTone.failed ? failureLine(run) : null;
    return Semantics(
      expanded: roster ? null : open,
      child: PressBuilder(
        onTap: roster ? widget.onOpen : () => _expansion.toggle(run.id),
        semanticLabel: [title, line, ?why].join(', '),
        builder: (context, pressed) => AnimatedContainer(
          duration: Motion.pressing(pressed),
          curve: Motion.easeOut,
          constraints: const BoxConstraints(minHeight: kMinTap),
          padding: const EdgeInsets.fromLTRB(Gap.md, 10, Gap.md, 10),
          decoration: BoxDecoration(
            color: pressed ? ds.fillPressed : Colors.transparent,
            borderRadius: BorderRadius.vertical(
              top: const Radius.circular(Radii.panel),
              bottom: Radius.circular(open ? 0 : Radii.panel),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 2), child: RunGlyph(tone: tone)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Type.secondary.copyWith(color: ds.text, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      line,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Type.caption.copyWith(color: runLineColor(ds, tone), fontFeatures: Type.tabular),
                    ),
                    if (why != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          why,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Type.caption.copyWith(color: ds.dangerText),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: Gap.sm),
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: roster
                    ? Icon(LucideIcons.chevronRight, size: 14, color: ds.textTertiary)
                    : Caret(open: open),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(SubagentRun run) {
    final ds = context.ds;
    final assignment = run.assignment?.trim() ?? '';
    final result = run.result?.trim() ?? '';
    final cut = result.length > cardResultChars ? result.length - cardResultChars : 0;
    final doc = result.isEmpty ? null : (_results[run] ??= parseMd(cut == 0 ? result : result.substring(0, cardResultChars)));
    final call = widget.callRow;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md + 26, 0, Gap.md, Gap.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (assignment.isNotEmpty) ...[
            _Label('Asked to'),
            Text(
              visibleText(assignment),
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: Type.secondary.copyWith(color: ds.textSecondary),
            ),
            const SizedBox(height: Gap.sm),
          ],
          if (doc != null) ...[
            _Label('Result'),
            MdToneScope(tone: MdTone.quiet, child: MdDocumentView(document: doc)),
            if (cut > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('… $cut more characters', style: Type.caption.copyWith(color: ds.textMuted)),
              ),
            const SizedBox(height: Gap.xs),
          ] else if (run.note != null && run.note!.trim().isNotEmpty) ...[
            Text(visibleText(run.note!.trim()), style: Type.secondary.copyWith(color: ds.textSecondary)),
            const SizedBox(height: Gap.xs),
          ],
          _ActionRow(
            label: run.hasTranscript ? 'Open conversation' : 'Open summary',
            icon: run.hasTranscript ? LucideIcons.messageSquareText : LucideIcons.listTree,
            onTap: _openRun,
          ),
          if (call != null) ...[
            _ActionRow(
              label: 'Call details',
              icon: LucideIcons.wrench,
              onTap: () => setState(() => _details = !_details),
              expanded: _details,
            ),
            if (_details)
              ToolRow(
                rowKey: '${widget.run.id}:call',
                item: call,
                gap: 0,
                open: true,
                all: _detailsAll,
                onToggle: (id) => setState(() {
                  if (id.endsWith(':all')) {
                    _detailsAll = !_detailsAll;
                  } else {
                    _details = false;
                  }
                }),
              ),
          ],
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Text(text, style: Type.caption.copyWith(color: context.ds.textMuted, fontWeight: FontWeight.w600)),
  );
}

/// A 44 dp row inside the open card: an icon and a label.
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.label, required this.icon, required this.onTap, this.expanded});

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool? expanded;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Semantics(
      expanded: expanded,
      child: PressBuilder(
        onTap: onTap,
        builder: (context, pressed) => AnimatedContainer(
          duration: Motion.pressing(pressed),
          curve: Motion.easeOut,
          constraints: const BoxConstraints(minHeight: kMinTap),
          decoration: BoxDecoration(
            color: pressed ? ds.fillPressed : Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.row),
          ),
          child: Row(
            children: [
              Icon(icon, size: 16, color: ds.textSecondary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: Type.secondary.copyWith(color: ds.text, fontWeight: FontWeight.w500),
                ),
              ),
              if (expanded != null) Caret(open: expanded!) else Icon(LucideIcons.chevronRight, size: 14, color: ds.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}
