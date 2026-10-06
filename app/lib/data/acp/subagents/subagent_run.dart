import '../acp_models.dart';
import '../live_text.dart';
import '../session_state.dart';

/// Where a subagent stands. Same words as the roster of an observed session
/// (`SubagentState`), plus [cancelled].
enum SubagentStatus {
  /// Asked for, not started: the call has no input yet, or waits for the
  /// person's approval, or the agent says it is initialising.
  waiting,
  running,
  finished,

  /// It ended with an error, or the call that started it failed.
  failed,

  /// The person cancelled the turn, or the call that started it was
  /// cancelled, while it ran.
  cancelled;

  /// Waiting or running: it may still say something.
  bool get isActive => this == waiting || this == running;
}

/// Which agent's data a run was built from; says how much of it exists.
enum SubagentRoute {
  /// Claude: the child's updates come tagged, so there is a transcript.
  claude,

  /// omp: a `task` call's progress and result, a summary. The conversation
  /// is not sent over ACP; when the subagent's own log can be read on the
  /// host, the session attaches it as a transcript ([SubagentRun.log]).
  omp,

  /// Codex: a `collabAgentToolCall` / `subAgentActivity`; a title and a
  /// status, no transcript.
  codex,
}

/// Where a run's transcript came from when the agent did not send it: the
/// agent's own log of the subagent, read over SFTP on the host (omp). Tells
/// the screen to say so once, and what is missing from the start.
class SubagentLogInfo {
  const SubagentLogInfo({this.earlierNotShown = false, this.skippedLines = 0});

  /// The log is longer than what was read (a byte or line cap): the start of
  /// the conversation is not shown.
  final bool earlierNotShown;

  /// Lines left out because one line alone was over the size cap.
  final int skippedLines;

  @override
  bool operator ==(Object other) =>
      other is SubagentLogInfo && other.earlierNotShown == earlierNotShown && other.skippedLines == skippedLines;

  @override
  int get hashCode => Object.hash(earlierNotShown, skippedLines);
}

/// Where reading a run's log on the host stands, for the drill-in.
enum SubagentLogStatus {
  /// Nothing was tried (the screen is not open, or the run is not omp's).
  idle,

  /// The first read is under way and nothing is shown yet.
  loading,

  /// The transcript is attached ([SubagentRun.hasTranscript]).
  shown,

  /// There is no usable log: no such file, no SFTP, no permission, a format
  /// this app does not know, or nothing in it. The screen stays the summary
  /// and says nothing about it.
  unavailable,

  /// The read failed because of the connection; the summary stays and offers
  /// a retry.
  failed,
}

/// omp's auto-retry: the subagent sleeps between provider retries (a rate
/// limit), which would otherwise look like a run that is merely slow.
class SubagentRetry {
  const SubagentRetry({required this.attempt, this.maxAttempts, this.delay, this.message = ''});

  final int attempt;
  final int? maxAttempts;
  final Duration? delay;
  final String message;
}

/// Where a request that waits for the person came from, when a subagent
/// asked: "From subagent: Explore". Taken from the run when the request
/// arrived; a later rename of the run is not followed.
class SubagentOrigin {
  const SubagentOrigin({required this.id, required this.title, this.agentType});

  /// [SubagentRun.id].
  final String id;
  final String title;
  final String? agentType;

  /// What the dock says: the agent type when the agent named one, else the
  /// title.
  String get label => agentType != null && agentType!.isNotEmpty ? agentType! : title;
}

/// One subagent of the session: what the agent that started it, and the
/// updates it sent, say about it.
///
/// A run is made by the reducer (`AgentSessionState.apply`), never by hand,
/// and is immutable, with one exception: the live text of its transcript (see
/// [liveTextOf]). What exists depends on the [route]: Claude sends the whole
/// child transcript ([hasTranscript]); omp and Codex send a summary, and a
/// field they do not send is null or empty (never a made-up value). omp's run
/// gets a transcript anyway when its session can read the subagent's own log
/// on the host (best effort): the reducer never makes it, the session lays it
/// over the run ([log] says so).
///
/// [id] is stable: Claude, the id of the `Task`/`Agent` call; Codex, the
/// child's thread id; omp, `<call id>#<index>` (one `task` call may start
/// several). The call that started it keeps its row in the transcript ([parentToolCallId]).
class SubagentRun {
  const SubagentRun({
    required this.id,
    required this.route,
    required this.parentToolCallId,
    this.parentRunId,
    this.name,
    this.title = 'Subagent',
    this.agentType,
    this.assignment,
    this.status = SubagentStatus.waiting,
    this.startedAt,
    this.finishedAt,
    this.reportedElapsed,
    this.totalElapsed,
    this.toolCount = 0,
    this.tokens,
    this.cost,
    this.model,
    this.percent,
    this.lastTool,
    this.lastToolLine,
    this.recentTools = const [],
    this.recentOutput = const [],
    this.note,
    this.result,
    this.failure,
    this.retry,
    this.background = false,
    this.plan = const [],
    this.droppedItems = 0,
    this.transcript,
    this.log,
  });

  final String id;
  final SubagentRoute route;

  /// The tool call that started it: its row sits in the transcript of
  /// [parentRunId], or in the session's own when that is null.
  final String parentToolCallId;

  /// The run whose transcript holds [parentToolCallId] (a subagent that
  /// started a subagent); null for a run the main agent started.
  final String? parentRunId;

  /// omp: the subagent's own name (`PongReply`). Codex: its path's last
  /// segment, when the agent gave one.
  final String? name;

  /// What it is doing, in a few words: Claude, the call's `description`; omp,
  /// its description, else its name; Codex, the first line of the prompt.
  /// `Subagent` until the agent says.
  final String title;

  /// `Explore`, `general-purpose`, `scout`...; null when not told.
  final String? agentType;

  /// What it was asked to do (the prompt), cut to [maxAssignment] characters.
  final String? assignment;

  final SubagentStatus status;

  /// When this client first saw the call that started it (the caller's
  /// clock); null in a replayed history.
  final DateTime? startedAt;

  /// When this client first saw the run end (or be cancelled); null while it
  /// runs and in a replay.
  final DateTime? finishedAt;

  /// The elapsed time the agent last reported while it runs (Claude:
  /// `toolResponse.elapsedTimeSeconds`; omp: `durationMs`). Whole seconds for
  /// Claude.
  final Duration? reportedElapsed;

  /// How long the run took, by the agent's own clock, once it ended
  /// (Claude `totalDurationMs`, omp `durationMs`).
  final Duration? totalElapsed;

  /// How long it took, as best known: the agent's final figure, else the span
  /// this client saw, else the last figure reported while it ran; null when
  /// nothing is known. A running run shows `now - startedAt` where
  /// [startedAt] is known, else this.
  Duration? get elapsed {
    if (totalElapsed != null) return totalElapsed;
    final a = startedAt, b = finishedAt;
    if (a != null && b != null) return b.difference(a);
    return reportedElapsed;
  }

  /// Tool calls it made: the most the agent reported and this client counted.
  final int toolCount;

  /// Tokens it used; null until the agent reports (Claude only at the end).
  final int? tokens;

  /// Cost in USD (omp); null when not reported.
  final double? cost;

  /// The model it ran on, as the agent names it.
  final String? model;

  /// omp's self-estimate of completion, 0-100.
  final int? percent;

  /// The name of the tool it used last (`Bash`, `grep`).
  final String? lastTool;

  /// One line about that call (`ls -1 /tmp/scratch`, `Read /x.ts`).
  final String? lastToolLine;

  /// Its latest tool names, oldest first, at most [maxRecent].
  final List<String> recentTools;

  /// omp: the last lines it wrote, oldest first, at most [maxRecent].
  final List<String> recentOutput;

  /// The latest status message the agent reported (Codex `agentsStates`).
  final String? note;

  /// What it handed back, plain text (Markdown), cut to [maxResult].
  final String? result;

  /// Why it did not succeed: the error text; null otherwise.
  final String? failure;

  final SubagentRetry? retry;

  /// Claude: it was started with `run_in_background`, so the call that
  /// started it finished at once while it keeps working. It stays running
  /// until the agent says it ended, or the person cancels. UNVERIFIED: no
  /// recorded trace shows the end of a background run.
  final bool background;

  /// The plan it wrote (Claude: its own todo list); never the session's.
  final List<PlanEntry> plan;

  /// Items dropped from the start of the transcript to stay under
  /// [maxItems].
  final int droppedItems;

  /// The child transcript as a state of its own; null when the run has none
  /// (omp without a readable log, Codex: see [hasTranscript]). Read [items],
  /// [liveMessage] and [liveTextOf] instead, which say the same; this is
  /// public for the reducer.
  final AgentSessionState? transcript;

  /// Set when [transcript] was read from the agent's log on the host instead
  /// of being sent by the agent; null otherwise.
  final SubagentLogInfo? log;

  /// The most items one child transcript keeps (the newest); the reducer
  /// drops from the start in steps of [itemsSlack].
  static const maxItems = 2000;
  static const itemsSlack = 200;
  static const maxRecent = 5;
  static const maxAssignment = 4000;
  static const maxResult = 64 * 1024;

  /// The run has a transcript to drill into. False for a summary-only run:
  /// the screen must not show it as a chat.
  bool get hasTranscript => transcript != null;

  /// Waiting or running.
  bool get isActive => status.isActive;

  /// The child's messages and tool calls in the order they happened; empty
  /// without a transcript. The text of the message streaming in grows in
  /// place ([liveTextOf]) without this list changing.
  List<TranscriptItem> get items => transcript?.items ?? const [];

  /// The child message that is streaming in right now, or null.
  TranscriptMessage? get liveMessage => transcript?.liveMessage;

  /// The growing text of the live child message [messageKey]; null when it
  /// is not live.
  LiveText? liveTextOf(String messageKey) => transcript?.liveTextOf(messageKey);

  /// What the dock names when this run asks the person something.
  SubagentOrigin get origin => SubagentOrigin(id: id, title: title, agentType: agentType);

  SubagentRun copyWith({
    String? name,
    String? title,
    String? agentType,
    String? assignment,
    SubagentStatus? status,
    DateTime? startedAt,
    Object? finishedAt = _same,
    Duration? reportedElapsed,
    Duration? totalElapsed,
    int? toolCount,
    int? tokens,
    double? cost,
    String? model,
    int? percent,
    String? lastTool,
    String? lastToolLine,
    List<String>? recentTools,
    List<String>? recentOutput,
    String? note,
    String? result,
    Object? failure = _same,
    Object? retry = _same,
    bool? background,
    List<PlanEntry>? plan,
    int? droppedItems,
    AgentSessionState? transcript,
    SubagentLogInfo? log,
    String? parentRunId,
  }) => SubagentRun(
    id: id,
    route: route,
    parentToolCallId: parentToolCallId,
    parentRunId: parentRunId ?? this.parentRunId,
    name: name ?? this.name,
    title: title ?? this.title,
    agentType: agentType ?? this.agentType,
    assignment: assignment ?? this.assignment,
    status: status ?? this.status,
    startedAt: startedAt ?? this.startedAt,
    finishedAt: identical(finishedAt, _same) ? this.finishedAt : finishedAt as DateTime?,
    reportedElapsed: reportedElapsed ?? this.reportedElapsed,
    totalElapsed: totalElapsed ?? this.totalElapsed,
    toolCount: toolCount ?? this.toolCount,
    tokens: tokens ?? this.tokens,
    cost: cost ?? this.cost,
    model: model ?? this.model,
    percent: percent ?? this.percent,
    lastTool: lastTool ?? this.lastTool,
    lastToolLine: lastToolLine ?? this.lastToolLine,
    recentTools: recentTools ?? this.recentTools,
    recentOutput: recentOutput ?? this.recentOutput,
    note: note ?? this.note,
    result: result ?? this.result,
    failure: identical(failure, _same) ? this.failure : failure as String?,
    retry: identical(retry, _same) ? this.retry : retry as SubagentRetry?,
    background: background ?? this.background,
    plan: plan ?? this.plan,
    droppedItems: droppedItems ?? this.droppedItems,
    transcript: transcript ?? this.transcript,
    log: log ?? this.log,
  );
}

const _same = Object();

/// How many subagents there are and where they stand: the figures of the chip
/// ("1 of 3 running") and the group headers. Memoized per runs list (see
/// [of]), so reading it on every build costs a lookup.
class SubagentSummary {
  const SubagentSummary({
    this.total = 0,
    this.waiting = 0,
    this.running = 0,
    this.finished = 0,
    this.failed = 0,
    this.cancelled = 0,
  });

  /// The summary of [runs]. The same list instance gives the same summary
  /// object; the reducer keeps the list while nothing about the runs changed.
  static SubagentSummary of(List<SubagentRun> runs) {
    if (runs.isEmpty) return none;
    return _memo[runs] ??= _count(runs);
  }

  static final _memo = Expando<SubagentSummary>('SubagentSummary');

  static const none = SubagentSummary();

  static SubagentSummary _count(List<SubagentRun> runs) {
    var waiting = 0, running = 0, finished = 0, failed = 0, cancelled = 0;
    for (final r in runs) {
      switch (r.status) {
        case SubagentStatus.waiting:
          waiting++;
        case SubagentStatus.running:
          running++;
        case SubagentStatus.finished:
          finished++;
        case SubagentStatus.failed:
          failed++;
        case SubagentStatus.cancelled:
          cancelled++;
      }
    }
    return SubagentSummary(
      total: runs.length,
      waiting: waiting,
      running: running,
      finished: finished,
      failed: failed,
      cancelled: cancelled,
    );
  }

  final int total;
  final int waiting;
  final int running;
  final int finished;
  final int failed;
  final int cancelled;

  /// Waiting or running.
  int get active => waiting + running;

  @override
  bool operator ==(Object other) =>
      other is SubagentSummary &&
      other.total == total &&
      other.waiting == waiting &&
      other.running == running &&
      other.finished == finished &&
      other.failed == failed &&
      other.cancelled == cancelled;

  @override
  int get hashCode => Object.hash(total, waiting, running, finished, failed, cancelled);

  @override
  String toString() => 'SubagentSummary($total: $running running, $waiting waiting, $finished finished, $failed failed, $cancelled cancelled)';
}
