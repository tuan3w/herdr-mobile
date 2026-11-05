import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/acp/acp_models.dart';
import '../../../data/acp/session_state.dart';
import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/agent_screens.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/attention_set.dart';
import '../../../data/words/elapsed.dart';
import '../../../data/words/place_name.dart';
import '../../../data/words/where_line.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../support/step_clock.dart';
import 'agent_navigation.dart';
import 'agents_grouping.dart' show boardStatus, timeInState, timeInStateWords;
import 'board_selection.dart';
import 'preconnect_tap.dart';
import 'swipe_review.dart';

/// A finished session that a swipe or "Mark reviewed" may mark seen: done
/// on the board and reachable (`AttentionSet.sessionReachable`: a session
/// whose machine or link is down shows what it knew and is not acted on).
bool sessionReviewable(AgentSessionView s) => AttentionSet.sessionToReview(s) && AttentionSet.sessionReachable(s);

/// What the oldest waiting request of [s] is about, on one line: the command
/// of a permission (else the tool's title), the message of a question. Null
/// when nothing waits. The board only tells; the answer is given in the
/// session.
String? blockedSummary(AgentSessionView s) {
  final line = switch (s.state.pending.firstOrNull) {
    PendingPermission(:final request) => _permissionLine(request),
    PendingQuestion(:final request) =>
      request.message.isNotEmpty ? request.message : (request.schema?.title ?? 'A question for you'),
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
String sessionMeta(AgentSessionView s) => whereLine(
  agent: s.agentLabel,
  machine: s.machine.profile.label,
  folder: placeName(s.machine.places, s.cwd),
  title: s.title,
);

/// "3m", "12m", "idle · jobs 14m" (the turn is over and the agent waits on
/// background work), "reconnecting": the time in the phase while the link is
/// up (the glyph says the phase), the link's own word while it is not.
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
      if (_onJobs(s)) return 'idle · jobs ${Elapsed.compact(elapsed, seconds: false)}';
      return timeInState(boardStatus(s), elapsed);
  }
}

bool _onJobs(AgentSessionView s) => boardStatus(s) == AgentStatus.idle && s.waitingOnBackground;

/// [sessionStateLabel] for screen readers: the state in words ("needs you,
/// 3 minutes", "idle, jobs running, 14 minutes").
String sessionStateWords(AgentSessionView s, DateTime now) {
  final since = s.phaseSince;
  if (s.link != AgentLink.live || since == null) return sessionStateLabel(s, now);
  final elapsed = now.difference(since);
  if (_onJobs(s)) return 'idle, jobs running, ${Elapsed.words(elapsed)}';
  return timeInStateWords(boardStatus(s), elapsed);
}

/// One agent session as a compact board row: status shape, title, what it
/// waits for (blocked) and where it runs, and how long it has been in its
/// phase. Tapping opens the session; a finished one that can be reached
/// swipes left to be marked reviewed without opening it (as a terminal
/// agent's card does).
class AgentSessionRow extends StatelessWidget {
  const AgentSessionRow({super.key, required this.session, required this.divider, this.where});

  final AgentSessionView session;
  final bool divider;

  /// Where it runs, in place of [sessionMeta]: on the board, which feature
  /// it is (`repo · branch · agent`, `sessionWhereOnBoard`).
  final String? where;

  @override
  Widget build(BuildContext context) {
    final status = boardStatus(session);
    final summary = status == AgentStatus.blocked ? blockedSummary(session) : null;
    final meta = where ?? sessionMeta(session);
    final live = session.link == AgentLink.live;
    final ref = sessionRef(session.key);
    final sel = rowSelect(context, ref);
    void pick({bool feedback = true}) {
      if (feedback) Haptics.tick();
      context.read<BoardSelection?>()?.toggle(ref);
    }

    final swipeable = sessionReviewable(session) && !sel.active;
    bool review() => markSessionReviewedWithUndo(context, session);

    final row = SwipeToReview(
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
              leading: StatusGlyph(status: status, size: IconSize.lead),
              title: session.title,
              subtitle: summary ?? meta,
              subtitle2: summary == null ? null : meta,
              titleMaxLines: 2,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SessionStateTime(session: session),
                  if (sel.active) ...[
                    const SizedBox(width: Gap.sm),
                    SelectMark(selected: sel.selected, size: IconSize.bar),
                  ],
                ],
              ),
              dim: !live,
              semanticLabel: live
                  ? null
                  : [
                      status.label,
                      session.title,
                      ?summary,
                      if (meta.isNotEmpty) meta,
                      sessionStateWords(session, DateTime.now()),
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
    if (!divider) return row;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row,
        Hairline(indent: ListRow.textIndent()),
      ],
    );
  }
}

/// A session's [sessionStateLabel] as the board's rows show it: the time
/// only, in the blocked colour and weight when the person is needed.
class SessionStateTime extends StatelessWidget {
  const SessionStateTime({super.key, required this.session});

  final AgentSessionView session;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final blocked = boardStatus(session) == AgentStatus.blocked;
    // Say it once: the glyph names the state; the time takes the status's
    // colour and weight only when the person is needed.
    final style = (blocked ? Type.captionStrong : Type.caption).copyWith(
      color: blocked ? ds.blockedText : ds.textMuted,
      fontFeatures: Type.tabular,
    );
    Widget label(DateTime now) {
      final text = sessionStateLabel(session, now);
      if (text.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: Gap.hair),
        child: Semantics(
          label: sessionStateWords(session, now),
          excludeSemantics: true,
          child: Text(text, maxLines: 1, softWrap: false, style: style),
        ),
      );
    }

    if (session.link != AgentLink.live) return label(DateTime.now());
    return MinuteBuilder(builder: (context, now) => label(now));
  }
}
