import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/observed_session.dart';
import '../../../data/repositories/observed_sessions.dart';
import '../../core/toast.dart';
import 'agent_session_screen.dart';
import 'subagent_run_session.dart';
import 'subagent_screen.dart';

// Agents themselves (sessions, and agents in panes) open through `openAgent`
// (`agents/agent_navigation.dart`); what is here opens what lives inside one.

/// Opens the transcript of subagent [name] of the observed [parent], pushed
/// over the agent's chat: it is not an agent of the board (no swipe, no
/// toggle). Says so in a toast when its log folder is unknown.
Future<void> openSubagentChat(BuildContext context, ObservedAgentSession parent, String name) async {
  final session = context.read<ObservedSessions?>()?.subagent(parent, name);
  if (session == null) {
    showToast(context, 'That subagent’s transcript is not available.');
    return;
  }
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AgentSessionScreen(session: session)));
}

/// Opens the subagent [runId] of [session] in a pushed read-only screen: its
/// conversation when the agent sends one, else its summary. Going back returns
/// to where the person was. A run that is gone says so in a toast.
///
/// [session] may itself be the view of a subagent (one that started another):
/// the run is looked up in the session that owns them all.
Future<void> openSubagentRun(BuildContext context, AgentSessionView session, String runId) {
  final owner = session is SubagentRunSession ? session.parent : session;
  if (owner.subagentRun(runId) == null) {
    showToast(context, 'That subagent is no longer listed.');
    return Future.value();
  }
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => SubagentRunScreen(session: owner, runId: runId)),
  );
}
