import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/observed_session.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/step_clock.dart';
import '../../core/theme.dart';
import 'agent_session_navigation.dart';
import 'session_select.dart';
import 'visible_text.dart';

/// What the pane shows right now, under the transcript, while the agent works
/// and its log is quiet (the model is writing its next message, which the log
/// only gets when it is finished). Muted, mono, never part of the transcript:
/// the real message replaces it in the list above. Takes no room when the
/// session has nothing to show.
class LiveOutput extends StatelessWidget {
  const LiveOutput({super.key, required this.session});

  final AgentSessionView session;

  @override
  Widget build(BuildContext context) => SessionSelect<List<String>?>(
    session: session,
    select: (s) => s.liveOutput,
    same: (a, b) => a == null || b == null ? a == b : listEquals(a, b),
    builder: (context, rows) {
      if (rows == null || rows.isEmpty) return const SizedBox.shrink();
      final ds = context.ds;
      return Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
        child: DecoratedBox(
          decoration: BoxDecoration(color: ds.fill, borderRadius: BorderRadius.circular(Radii.chip)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Semantics(
              label: 'Live output from the terminal',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: Text('Live from terminal', style: Type.caption.copyWith(color: ds.textMuted)),
                  ),
                  const SizedBox(height: 4),
                  for (final row in rows)
                    ExcludeSemantics(
                      child: Text(
                        visibleText(row),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: TextStyle(
                          fontFamily: monoFamily,
                          fontSize: 11.5,
                          height: 1.4,
                          color: ds.textSecondary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// `Working · 42 s` next to the status glyph while the log is quiet: how long
/// the agent has been in this phase, moving by the minute clock (30 s steps),
/// never per second.
class WorkingLabel extends StatelessWidget {
  const WorkingLabel({super.key, required this.since});

  final DateTime? since;

  /// `42 s`, `3 min`, `1 h 05 min`.
  static String elapsed(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds < 0 ? 0 : d.inSeconds} s';
    if (d.inMinutes < 60) return '${d.inMinutes} min';
    return '${d.inHours} h ${(d.inMinutes % 60).toString().padLeft(2, '0')} min';
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return MinuteBuilder(
      builder: (context, now) {
        final at = since;
        final text = at == null ? 'Working' : 'Working · ${elapsed(now.difference(at))}';
        return Text(
          text,
          maxLines: 1,
          style: Type.caption.copyWith(color: ds.working, fontFeatures: Type.tabular),
        );
      },
    );
  }
}

/// The roster of an observed session as a sheet: each subagent with its state,
/// what it was asked (cut) and its latest tools. The host's artifact folder is
/// listed to refine the states only while the sheet is open. (The chip that
/// opens it, and the roster of an ACP session, are in `subagent_roster.dart`.)
Future<void> showObservedSubagents(BuildContext context, AgentSessionView session) {
  session.watchSubagents(true);
  return showAppSheet<void>(context, builder: (ctx) => _Roster(session: session)).whenComplete(
    () => session.watchSubagents(false),
  );
}

class _Roster extends StatelessWidget {
  const _Roster({required this.session});

  final AgentSessionView session;

  @override
  Widget build(BuildContext context) => SessionSelect<List<SubagentEntry>>(
    session: session,
    select: (s) => s.subagents,
    same: (a, b) => a.length == b.length && _same(a, b),
    builder: (context, entries) {
      final ds = context.ds;
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Semantics(
                header: true,
                child: Text('Subagents', style: Type.label.copyWith(color: ds.textSecondary)),
              ),
            ),
            if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text('None started yet.', style: Type.secondary.copyWith(color: ds.textMuted)),
              ),
            for (final e in entries) _SubagentRow(session: session, entry: e),
          ],
        ),
      );
    },
  );

  static bool _same(List<SubagentEntry> a, List<SubagentEntry> b) {
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
}

class _SubagentRow extends StatelessWidget {
  const _SubagentRow({required this.session, required this.entry});

  final AgentSessionView session;
  final SubagentEntry entry;

  static String _state(SubagentState s) => switch (s) {
    SubagentState.waiting => 'Waiting',
    SubagentState.running => 'Running',
    SubagentState.finished => 'Finished',
    SubagentState.failed => 'Failed',
  };

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final info = entry.info;
    final color = switch (entry.state) {
      SubagentState.running => ds.working,
      SubagentState.failed => ds.dangerText,
      SubagentState.finished => ds.done,
      SubagentState.waiting => ds.textMuted,
    };
    final tools = info.recentTools.isEmpty ? null : info.recentTools.join(' · ');
    final detail = [
      _state(entry.state),
      if (info.toolCount > 0) '${info.toolCount} ${info.toolCount == 1 ? 'tool' : 'tools'}',
    ].join(' · ');
    final parent = session;
    return PressBuilder(
      onTap: parent is ObservedAgentSession
          ? () {
              final navigator = Navigator.of(context)..pop();
              // ignore: use_build_context_synchronously
              unawaited(openSubagentChat(navigator.context, parent, entry.name));
            }
          : null,
      button: true,
      builder: (context, pressed) => Container(
        constraints: const BoxConstraints(minHeight: kMinTap),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: pressed ? ds.fill : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.row),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    visibleText(entry.name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.row.copyWith(color: ds.text),
                  ),
                ),
                const SizedBox(width: Gap.sm),
                Text(detail, style: Type.caption.copyWith(color: color, fontWeight: FontWeight.w600)),
              ],
            ),
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
                style: TextStyle(fontFamily: monoFamily, fontSize: 11.5, color: ds.textMuted),
              ),
          ],
        ),
      ),
    );
  }
}
