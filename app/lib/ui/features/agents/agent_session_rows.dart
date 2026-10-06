import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/acp/acp_models.dart';
import '../../../data/acp/session_state.dart';
import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/agent_screens.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/attention_set.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/step_clock.dart';
import '../../core/tokens.dart';
import 'agent_navigation.dart';
import 'agents_grouping.dart' show boardStatus, formatElapsed, timeInState;
import 'board_selection.dart';
import 'preconnect_tap.dart';
import 'swipe_review.dart';

/// A finished session that a swipe or "Mark all reviewed" may mark seen: done
/// on the board and reachable (`AttentionSet.sessionReachable`: a session
/// whose machine or link is down shows what it knew and is not acted on).
bool sessionReviewable(AgentSessionView s) =>
    AttentionSet.sessionToReview(s) && AttentionSet.sessionReachable(s);

/// What the oldest waiting request of [s] is about, on one line: the command
/// of a permission (else the tool's title), the message of a question. Null
/// when nothing waits. The board only tells; the answer is given in the
/// session.
String? blockedSummary(AgentSessionView s) {
  final line = switch (s.state.pending.firstOrNull) {
    PendingPermission(:final request) => _permissionLine(request),
    PendingQuestion(:final request) => request.message.isNotEmpty
        ? request.message
        : (request.schema?.title ?? 'A question for you'),
    null => null,
  };
  if (line == null) return null;
  final one = line.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.isEmpty ? null : one;
}

String _permissionLine(PermissionRequest r) {
  final command = r.command;
  if (command != null && command.trim().isNotEmpty) return command;
  final input = r.toolCall.rawInput;
  if (input is Map && input['command'] is String && (input['command'] as String).trim().isNotEmpty) {
    return input['command'] as String;
  }
  return r.toolCall.title ?? r.title ?? 'Permission needed';
}

/// `Claude Code · studio-mac · herdr-mobile`.
String sessionMeta(AgentSessionView s) => [
      s.agentLabel,
      s.machine.profile.label,
      cwdTail(s.cwd),
    ].where((p) => p.isNotEmpty).join(' · ');

/// "needs you 3m", "working 12m", "waiting 14m" (the turn is over and the
/// agent waits on background work), "reconnecting": the time in the phase
/// while the link is up, the link's own word while it is not.
String sessionStateLabel(AgentSessionView s, DateTime now) {
  switch (s.link) {
    case AgentLink.connecting:
      return 'connecting';
    case AgentLink.reconnecting:
      return 'reconnecting';
    case AgentLink.ended:
      return 'ended';
    case AgentLink.failed:
      return 'failed';
    case AgentLink.live:
      final since = s.phaseSince;
      if (since == null) return '';
      final elapsed = now.difference(since);
      if (boardStatus(s) == AgentStatus.idle && s.waitingOnBackground) return 'waiting ${formatElapsed(elapsed)}';
      return timeInState(boardStatus(s), elapsed);
  }
}

/// One agent session as a compact board row: status shape, title, what it
/// waits for (blocked) and where it runs, and how long it has been in its
/// phase. Tapping opens the session; a finished one that can be reached
/// swipes left to be marked reviewed without opening it (as a terminal
/// agent's card does).
class AgentSessionRow extends StatelessWidget {
  const AgentSessionRow({super.key, required this.session, required this.divider});

  final AgentSessionView session;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final status = boardStatus(session);
    final summary = status == AgentStatus.blocked ? blockedSummary(session) : null;
    final meta = sessionMeta(session);
    final live = session.link == AgentLink.live;
    final ref = sessionRef(session.key);
    final sel = rowSelect(context, ref);
    void pick({bool feedback = true}) {
      if (feedback) Haptics.tick();
      context.read<BoardSelection?>()?.toggle(ref);
    }

    final swipeable = sessionReviewable(session) && !sel.active;
    bool review() => markSessionReviewedWithUndo(context, session);

    return SwipeToReview(
      enabled: swipeable,
      onReviewed: review,
      inset: Gap.md,
      child: SelectableRowFrame(
        state: sel,
        child: ReviewAction(
          enabled: swipeable,
          onReviewed: review,
          // A finger going down starts the attach; the tap hands that hold to
          // the screen it opens.
          child: PreconnectTap(
            sessionKey: session.key,
            enabled: !sel.active,
            builder: (context, takePreconnect) => ListRow(
              leading: StatusGlyph(status: status, size: 20),
              title: session.title,
              subtitle: summary ?? meta,
              subtitle2: summary == null ? null : meta,
              titleMaxLines: 2,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _StateTime(session: session),
                  if (sel.active) ...[
                    const SizedBox(width: 6),
                    SelectMark(selected: sel.selected, size: 18),
                  ],
                ],
              ),
              dim: !live,
              divider: divider,
              semanticLabel: live
                  ? null
                  : [
                      status.label,
                      session.title,
                      ?summary,
                      if (meta.isNotEmpty) meta,
                      sessionStateLabel(session, DateTime.now()),
                    ].join(', '),
              onTap: sel.active
                  ? pick
                  : () {
                      Haptics.tick();
                      openAgent(context, SessionAgent(session.key), preconnect: takePreconnect());
                    },
              onLongPress: () => pick(feedback: false),
            ),
          ),
        ),
      ),
    );
  }
}

class _StateTime extends StatelessWidget {
  const _StateTime({required this.session});

  final AgentSessionView session;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final blocked = boardStatus(session) == AgentStatus.blocked;
    final style = Type.caption.copyWith(
      fontSize: 12.5,
      color: blocked ? ds.blockedText : ds.textMuted,
      fontFeatures: Type.tabular,
    );
    Widget label(String text) => text.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(text, maxLines: 1, softWrap: false, style: style),
          );
    if (session.link != AgentLink.live) return label(sessionStateLabel(session, DateTime.now()));
    return MinuteBuilder(builder: (context, now) => label(sessionStateLabel(session, now)));
  }
}
