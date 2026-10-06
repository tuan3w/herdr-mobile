// Folds a recorded ACP trace (`test/fixtures/traces/<agent>/<scenario>.jsonl`)
// into an AgentSessionState the way the app does: the prompt the client sent
// becomes the user message at its recorded time, every update is applied at its
// recorded time (a fake clock: the trace's own), the answer to the prompt ends
// the turn.
import 'dart:io';

import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';

import '../../../benchmark/support/trace_replay.dart';

/// The start of the fake clock: trace time 0.
final traceEpoch = DateTime.utc(2026, 10, 5, 12);

/// The fake clock reading for [tMs] milliseconds into a trace.
DateTime traceTime(double tMs) => traceEpoch.add(Duration(microseconds: (tMs * 1000).round()));

List<TraceLine> loadTrace(String agent, String scenario) =>
    parseTrace(File('test/fixtures/traces/$agent/$scenario.jsonl').readAsStringSync());

/// What the trace did, found in the raw lines.
class TraceFacts {
  TraceFacts(this.lines) {
    final prompt = lines.firstWhere((l) => !l.received && l.method == 'session/prompt');
    promptLine = prompt;
    final blocks = (prompt.msg['params'] as Map)['prompt'] as List;
    promptText = [for (final b in blocks) if (b is Map && b['text'] is String) b['text'] as String].join();
    final answer = lines.firstWhere((l) => l.received && l.method == null && l.msg['id'] == prompt.msg['id']);
    answerLine = answer;
    stopReason = StopReason.parse(((answer.msg['result'] as Map)['stopReason']) as String?);
  }

  final List<TraceLine> lines;
  late final TraceLine promptLine;
  late final TraceLine answerLine;
  late final String promptText;
  late final StopReason stopReason;

  /// Every `session/update` the agent sent, parsed.
  Iterable<(TraceLine, SessionUpdate)> get updates sync* {
    for (final l in lines) {
      final u = updateOf(l);
      if (u != null) yield (l, SessionUpdate.parse(u));
    }
  }

  /// The text of all chunks of [sessionUpdate] (`agent_message_chunk`) in order.
  String textOf(String sessionUpdate) {
    final b = StringBuffer();
    for (final l in lines) {
      final u = updateOf(l);
      if (u != null && u['sessionUpdate'] == sessionUpdate) {
        final content = u['content'];
        if (content is Map && content['text'] is String) b.write(content['text']);
      }
    }
    return b.toString();
  }

  /// The setup the agent answered `session/new` with.
  AcpSessionSetup get setup {
    final neu = lines.firstWhere((l) => !l.received && l.method == 'session/new');
    final answer = lines.firstWhere((l) => l.received && l.method == null && l.msg['id'] == neu.msg['id']);
    return AcpSessionSetup.parse(answer.msg['result']);
  }
}

/// The state after the whole trace, live (with times). With [stopAtPermission]
/// the fold stops at the first permission request and leaves it pending, with
/// the turn running: the state a person sees while asked.
AgentSessionState stateOfTrace(String agent, String scenario, {bool stopAtPermission = false}) {
  final facts = TraceFacts(loadTrace(agent, scenario));
  var state = AgentSessionState('s').withSetup(facts.setup);
  for (final l in facts.lines) {
    if (l == facts.promptLine) {
      state = state.withUserMessage([TextBlock(facts.promptText)], at: traceTime(l.tMs)).withTurnStarted();
    } else if (l == facts.answerLine) {
      state = state.withTurnEnded(facts.stopReason, at: traceTime(l.tMs));
    } else if (l.received && l.method == 'session/request_permission') {
      if (stopAtPermission) {
        final params = l.msg['params'];
        return state.withPending(PendingPermission(l.msg['id']!, PermissionRequest.parse(params)));
      }
    } else if (updateOf(l) case final u?) {
      state = state.apply(SessionUpdate.parse(u), at: traceTime(l.tMs));
    }
  }
  return state;
}

/// The same trace as it would arrive in a `session/load` replay: history, so
/// no times. The prompt comes as a user chunk, there is no answer to a
/// prompt, and the setup ends the replay.
AgentSessionState replayOfTrace(String agent, String scenario) {
  final facts = TraceFacts(loadTrace(agent, scenario));
  var state = AgentSessionState('s', replaying: true);
  for (final l in facts.lines) {
    if (l == facts.promptLine) {
      state = state.apply(
        MessageChunk(MessageRole.user, null, TextBlock(facts.promptText)),
        at: traceTime(l.tMs),
      );
    } else if (updateOf(l) case final u?) {
      state = state.apply(SessionUpdate.parse(u), at: traceTime(l.tMs));
    }
  }
  return state.withSetup(facts.setup);
}
