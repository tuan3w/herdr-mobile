import '../acp/acp_models.dart' show SessionUpdate;
import '../acp/background/background_work.dart' show BackgroundTask;

/// OBSERVED SESSIONS. An agent that runs in a herdr pane on the owner's PC
/// (`omp` first) is shown on the phone as the same chat an agent session is,
/// without any setup: the transcript comes from the agent's own session log
/// (herdr's snapshot names the file in `agent_session`), and the phone's hand
/// is the pane (`pane.send_input` for text, `pane.send_keys` for Esc and for
/// answering a dialog), checked against the log afterwards. The terminal stays
/// one tap away as the fallback.

/// Complete lines appended to a session log on the host.
class LogBatch {
  const LogBatch(this.lines, this.endOffset, {this.reset = false});

  /// Whole JSONL lines, without the trailing newline, oldest first.
  final List<String> lines;

  /// Byte offset in the file just after the last line of [lines]; pass it back
  /// as `follow(from:)` to resume without replaying.
  final int endOffset;

  /// The file shrank or was replaced: forget what came before and rebuild from
  /// [lines] (which start at the new beginning).
  final bool reset;
}

/// Reads a growing log file on a host.
abstract interface class SessionLogSource {
  /// The tail of [path] first (at most the last [tailBytes], default 192 KB,
  /// starting at a line boundary; the whole file when it is smaller), then
  /// every line appended later, pushed within about a second. With [from] it
  /// resumes after that byte offset instead of replaying the tail ("Load
  /// earlier" restarts the follow with a bigger [tailBytes] and resets its
  /// state). Oversized fields are cut on the host so a line stays small (see
  /// the follower). The stream ends when the channel does; it errors with a
  /// retryable `HerdrTransportException` when the link drops.
  Stream<LogBatch> follow(String path, {int? from, int? tailBytes});
}

/// One option of a question the agent asked.
class AskOption {
  const AskOption({required this.label, this.description = ''});

  final String label;
  final String description;
}

/// One question of the agent's question tool.
class AskQuestion {
  const AskQuestion({
    required this.id,
    required this.question,
    required this.options,
    this.multi = false,
    this.recommended,
  });

  final String id;
  final String question;
  final List<AskOption> options;

  /// More than one option may be chosen.
  final bool multi;

  /// Zero-based index of the option the agent recommends, if it named one.
  final int? recommended;
}

/// A question tool call that has no result yet.
class PendingAsk {
  const PendingAsk({required this.toolCallId, required this.questions});

  final String toolCallId;
  final List<AskQuestion> questions;
}

/// What the person answered, one entry per question, in order.
class AskAnswer {
  const AskAnswer({this.selected = const [], this.custom});

  /// Zero-based indexes of the chosen options (one for a single choice).
  final List<int> selected;

  /// Free text typed instead of, or in addition to, the options.
  final String? custom;
}

/// A subagent the observed agent spawned with its `task` tool, as the parent's
/// log last described it. The subagent's own transcript is a log of the same
/// format, in the artifact directory next to the parent's (`<parent>/<name>.jsonl`).
class SubagentInfo {
  const SubagentInfo({
    required this.name,
    this.agent = '',
    this.status = 'pending',
    this.assignment = '',
    this.toolCount = 0,
    this.recentTools = const [],
  });

  /// The subagent's id and display name (`PongReply`).
  final String name;

  /// Its agent type (`task`, `explore`...); empty when the log did not say.
  final String agent;

  /// `pending`, `running`, `completed`, `failed`, `aborted`... as omp reports.
  final String status;

  /// What it was asked to do, cut to about 400 characters.
  final String assignment;
  final int toolCount;

  /// Names of its latest tool calls, oldest first.
  final List<String> recentTools;
}

/// Turns the lines of one agent's session log into the updates the chat
/// reducer (`AgentSessionState.apply`) understands. One instance per session,
/// fed every line in order.
abstract interface class SessionLogMapper {
  /// Updates for [line] (a whole JSON line); unknown or malformed shapes give
  /// an empty list and never throw.
  List<SessionUpdate> map(String line);

  /// The question tool call that has no result yet, if any.
  PendingAsk? get pendingAsk;

  /// Ids of tool calls that started and have no result yet.
  Set<String> get openToolCalls;

  /// The subagents seen in `task` calls and results, latest state per name, in
  /// the order they first appeared.
  List<SubagentInfo> get subagents;

  /// What the agent's log says runs in the background (shell jobs, code cells,
  /// subagents), oldest first; finished ones stay for a while. An id restarts
  /// with the agent's process, so a task is told apart by `BackgroundTask.key`.
  /// Only what the log records: a stop from the agent's own UI is not in it
  /// (see `BackgroundView.derive`, which cross-checks with herdr).
  List<BackgroundTask> get backgroundTasks;

  /// The last turn of the log is over: its last message is the agent's, it
  /// stopped by itself or was interrupted, and no tool call is open. False
  /// after a message from the person, a tool result, a tool call, and when a
  /// finished background job started a new turn.
  bool get turnEnded;

  /// Drops everything learned (after `LogBatch.reset`).
  void reset();
}
