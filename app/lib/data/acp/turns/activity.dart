import '../acp_models.dart';
import '../session_state.dart';
import 'plain_text.dart';
import 'tool_summary.dart';

/// What the status line says the agent is doing.
enum ActivityKind {
  /// A tool call runs (or is about to): [ActivityLine.tool] has its summary.
  tool,

  /// The agent is thinking: the first sentence of its latest thought.
  thought,

  /// A turn runs and nothing more specific is known.
  working,

  /// The agent waits for the person: a permission or a question.
  waiting,
}

/// The status line of a running turn, from the transcript alone. It replaces
/// per-row spinners and the "is it dead?" gap.
class ActivityLine {
  const ActivityLine({required this.kind, required this.text, this.tool, this.since, this.quiet});

  final ActivityKind kind;

  /// Plain text for the line: the tool summary ([ToolSummary.plain]), the
  /// first sentence of the thought, `Working`, or what is waited for.
  final String text;

  /// The summary of the running call, for [ActivityKind.tool] and, when the
  /// call is the one waiting, [ActivityKind.waiting].
  final ToolSummary? tool;

  /// When the step began (the call first seen, the thought first heard): the
  /// start of "Running flutter test · 12s". Null when unknown (replayed
  /// history, no clock).
  final DateTime? since;

  /// How long nothing has arrived, when that is long enough to say so
  /// ([quietFor]); null otherwise.
  final Duration? quiet;

  /// How long the step has been going at [now]; null when [since] is unknown.
  Duration? elapsed(DateTime now) {
    final s = since;
    if (s == null) return null;
    final d = now.difference(s);
    return d.isNegative ? Duration.zero : d;
  }
}

/// How long without an event counts as quiet (a real stuck signal: the agent
/// streams several updates a second while it works).
const quietAfter = Duration(seconds: 60);

/// What the agent is doing at [now], or null when no turn runs (nothing is
/// waited for either).
///
/// In order: a call waiting for the person; a running call (the latest one
/// that is pending or in progress: Claude never says `in_progress`); the
/// first sentence of the latest thought when it is the last thing of the turn;
/// `Working`. A question waiting for the person, with no call to name, is
/// [ActivityKind.waiting] too.
ActivityLine? activityOf(AgentSessionState state, {required DateTime now}) {
  final phase = state.phase;
  if (phase == AgentPhase.idle) return null;
  final quiet = quietFor(state, now: now);
  final waiting = state.waitingToolIds;
  final items = state.items;

  // The turn: from the end back to the last user message.
  TranscriptTool? running;
  TranscriptTool? waited;
  TranscriptMessage? trailingThought;
  var seenLast = false;
  for (var i = items.length - 1; i >= 0; i--) {
    final item = items[i];
    if (item is TranscriptMessage && item.role == MessageRole.user) break;
    switch (item) {
      case TranscriptTool():
        seenLast = true;
        if (!item.call.status.isFinished) {
          running ??= item;
          if (waiting.contains(item.call.toolCallId)) waited ??= item;
        }
      case TranscriptMessage(role: MessageRole.thought):
        if (!seenLast) trailingThought = item;
        seenLast = true;
      case TranscriptMessage():
        seenLast = true;
      case TranscriptStop() || TranscriptNote():
        break;
    }
  }

  if (waited != null) {
    final summary = toolSummary(waited.call);
    return ActivityLine(kind: ActivityKind.waiting, text: summary.plain, tool: summary, since: waited.at, quiet: null);
  }
  if (phase != AgentPhase.working) {
    return const ActivityLine(kind: ActivityKind.waiting, text: 'Waiting for you');
  }
  if (running != null) {
    final summary = toolSummary(running.call);
    return ActivityLine(kind: ActivityKind.tool, text: summary.plain, tool: summary, since: running.at, quiet: quiet);
  }
  if (trailingThought != null) {
    final sentence = firstSentence(trailingThought.text);
    if (sentence != null) {
      return ActivityLine(kind: ActivityKind.thought, text: sentence, since: trailingThought.at, quiet: quiet);
    }
  }
  return ActivityLine(kind: ActivityKind.working, text: 'Working', quiet: quiet);
}

/// How long it has been since anything arrived while a turn runs, when that is
/// at least [threshold]; null otherwise. Never while the agent waits for the
/// person (a permission, a question: silence is expected), never when the
/// link is down (that has its own words), and null when no clock reading
/// exists.
///
/// The silence counts from the last update of any kind
/// (`AgentSessionState.lastActivityAt`), or from the user's message when that
/// is later (a turn that never produced a first event).
Duration? quietFor(AgentSessionState state, {required DateTime now, Duration threshold = quietAfter}) {
  if (!state.turnActive || state.disconnected || state.phase != AgentPhase.working) return null;
  var anchor = state.lastActivityAt;
  for (var i = state.items.length - 1; i >= 0; i--) {
    final item = state.items[i];
    if (item is TranscriptMessage && item.role == MessageRole.user) {
      final sent = item.at;
      if (sent != null && (anchor == null || sent.isAfter(anchor))) anchor = sent;
      break;
    }
  }
  if (anchor == null) return null;
  final d = now.difference(anchor);
  return d >= threshold ? d : null;
}
