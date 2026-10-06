import '../acp_models.dart';
import '../session_state.dart';
import 'changes.dart';
import 'tool_summary.dart';

/// One command a turn ran, with how it ended.
class CommandRun {
  const CommandRun({required this.tool, required this.command, this.exitCode, this.signal, required this.failed});

  final TranscriptTool tool;

  /// The command as the agent gave it, shell wrapper removed, whole (not cut
  /// to a line); the call's title when the call names none.
  final String command;

  /// From the terminal output (`ToolCall.output`); null when the agent sent
  /// none (Claude and omp report no code) or the command still runs.
  final int? exitCode;
  final String? signal;

  /// [toolFailed]: the agent said `failed`, or the code was not zero.
  final bool failed;
}

/// One turn of the conversation: the user message that starts it and
/// everything the agent did until the next one. Built by [turnsOf] from the
/// transcript; immutable.
///
/// What a UI needs:
/// - [answer]: the agent message after the last tool call or thought of the
///   turn (null while the agent is still working towards one: only narration,
///   tool calls or thoughts so far). It stays visible when the log folds.
/// - [work]: what folds into one summary line (thoughts, narration, tool
///   calls, in order); [narration], [thoughts] and [tools] are the same items
///   by kind.
/// - [breakouts]: what must stay visible when the log folds: a failed or
///   cancelled call, a call that waits for the person, a stop row.
/// - [changed]: the files the turn changed; [commands]: what it ran.
/// - the counts and times the fold line is made of ([workSummaryLine]).
class Turn {
  Turn._(this.key, this.user, List<TranscriptItem> items, this.live) : items = List.unmodifiable(items) {
    final agent = <TranscriptMessage>[];
    final thoughts = <TranscriptMessage>[];
    final tools = <TranscriptTool>[];
    final stops = <TranscriptStop>[];
    final notes = <TranscriptNote>[];
    for (final item in this.items) {
      switch (item) {
        case TranscriptMessage(role: MessageRole.agent) when _hasContent(item):
          agent.add(item);
        case TranscriptMessage(role: MessageRole.thought) when _hasContent(item):
          thoughts.add(item);
        case TranscriptMessage():
          break;
        case TranscriptTool():
          tools.add(item);
        case TranscriptStop():
          stops.add(item);
        case TranscriptNote():
          notes.add(item);
      }
    }
    // The answer is the last thing the agent did, ignoring quiet lines the
    // app wrote and empty messages.
    TranscriptMessage? answer;
    for (var i = this.items.length - 1; i >= 0; i--) {
      final item = this.items[i];
      if (item is TranscriptStop || item is TranscriptNote) continue;
      if (item is TranscriptMessage && !_hasContent(item)) continue;
      if (item is TranscriptMessage && item.role == MessageRole.agent) answer = item;
      break;
    }
    this.answer = answer;
    narration = List.unmodifiable([
      for (final m in agent)
        if (!identical(m, answer)) m,
    ]);
    this.thoughts = List.unmodifiable(thoughts);
    this.tools = List.unmodifiable(tools);
    this.stops = List.unmodifiable(stops);
    this.notes = List.unmodifiable(notes);
    work = List.unmodifiable([
      for (final item in this.items)
        if ((item is TranscriptTool) ||
            (item is TranscriptMessage &&
                _hasContent(item) &&
                !identical(item, answer) &&
                item.role != MessageRole.user))
          item,
    ]);
  }

  /// Stable for the life of the session: the key of the user message, else of
  /// the first item (a turn with no user message: autonomous activity, or what
  /// came after a replay).
  final String key;

  /// The message that starts the turn; null for autonomous activity before
  /// any user message.
  final TranscriptMessage? user;

  /// Every item after [user], in order.
  final List<TranscriptItem> items;

  /// The agent is working on this turn right now (it is the last turn and a
  /// turn is active). False once it ended.
  final bool live;

  /// The turn ended (the opposite of [live]).
  bool get ended => !live;

  late final TranscriptMessage? answer;

  /// Agent messages before the answer: the agent saying what it is about to
  /// do. They fold into the work log.
  late final List<TranscriptMessage> narration;
  late final List<TranscriptMessage> thoughts;
  late final List<TranscriptTool> tools;

  /// The [TranscriptStop] rows (a refusal, a limit).
  late final List<TranscriptStop> stops;

  /// The [TranscriptNote] rows (a mode the agent switched).
  late final List<TranscriptNote> notes;

  /// The items that fold: tool calls, thoughts and narration, in order. Not
  /// the answer, the stop rows, the notes or the user message.
  late final List<TranscriptItem> work;

  /// A work log exists.
  bool get hasWork => work.isNotEmpty;

  /// The turn without a user message and without anything the agent did.
  bool get isEmpty => user == null && items.isEmpty;

  /// The turn as live or ended. Memoized: the same turn gives the same twin.
  Turn withLive(bool value) {
    if (value == live) return this;
    final known = _twin;
    if (known != null) return known;
    final twin = Turn._(key, user, items, value);
    twin._twin = this;
    return _twin = twin;
  }

  Turn? _twin;

  /// Whether [other] is built from exactly these items.
  bool _sameItems(TranscriptMessage? u, List<TranscriptItem> slice) {
    if (!identical(user, u) || items.length != slice.length) return false;
    for (var i = 0; i < slice.length; i++) {
      if (!identical(items[i], slice[i])) return false;
    }
    return true;
  }

  // -- the parts of the fold line ---------------------------------------------

  /// Tool calls by kind (kinds with no call are absent).
  late final Map<ToolKind, int> toolCounts = () {
    final out = <ToolKind, int>{};
    for (final t in tools) {
      out[t.call.kind] = (out[t.call.kind] ?? 0) + 1;
    }
    return Map<ToolKind, int>.unmodifiable(out);
  }();

  /// Calls that failed ([toolFailed]), were cancelled, and are not finished
  /// (pending or running).
  late final int failedCount = tools.where((t) => toolFailed(t.call)).length;
  late final int cancelledCount = tools.where((t) => t.call.status == ToolStatus.cancelled).length;
  late final int unfinishedCount = tools.where((t) => !t.call.status.isFinished).length;

  /// The files changed by the turn's completed edit and delete calls, one per
  /// path, in the order they were first touched (see [changedFilesOf]).
  late final List<ChangedFile> changed = List.unmodifiable(
    changedFilesOf([
      for (final t in tools)
        if (t.call.status == ToolStatus.completed) t.call,
    ]),
  );

  /// The commands the turn ran (calls of kind execute), in order.
  late final List<CommandRun> commands = List.unmodifiable([
    for (final t in tools)
      if (t.call.kind == ToolKind.execute)
        CommandRun(
          tool: t,
          command: commandOf(t.call) ?? toolSummary(t.call).text,
          exitCode: t.call.output?.exitCode ?? toolSummary(t.call).exitCode,
          signal: t.call.output?.signal ?? toolSummary(t.call).signal,
          failed: toolFailed(t.call),
        ),
  ]);

  // -- time -------------------------------------------------------------------

  /// When the turn started: the user message's time, else the first item's;
  /// null when that is unknown. A turn that began in a replayed history has
  /// no start (and so no [duration]) even if it went on live: the part
  /// before the replay is missing.
  late final DateTime? startedAt = (user ?? (items.isEmpty ? null : items.first))?.at;

  /// The last time anything of the turn happened (a message stopped growing,
  /// a call finished); null while the turn is [live] and when no time is known.
  late final DateTime? endedAt = live ? null : _lastEvent();

  /// First to last event; null while [live], and whenever [startedAt] or
  /// [endedAt] is unknown (replayed history). Never negative.
  late final Duration? duration = () {
    final a = startedAt, b = endedAt;
    if (a == null || b == null) return null;
    final d = b.difference(a);
    return d.isNegative ? Duration.zero : d;
  }();

  /// [duration] is a real measurement.
  bool get timed => duration != null;

  DateTime? _lastEvent() {
    DateTime? last;
    void see(DateTime? t) {
      if (t != null && (last == null || t.isAfter(last!))) last = t;
    }

    see(user?.at);
    for (final item in items) {
      switch (item) {
        case TranscriptMessage():
          see(item.endedAt ?? item.at);
        case TranscriptTool():
          see(item.finishedAt ?? item.at);
        case TranscriptStop() || TranscriptNote():
          see(item.at);
      }
    }
    return last;
  }

  // -- what breaks out of the fold ----------------------------------------------

  /// What stays visible when the log folds, in order: calls that failed or
  /// were cancelled, calls that wait for the person's permission ([waiting]:
  /// `AgentSessionState.waitingToolIds`), and the stop rows. The answer and
  /// the notes are visible anyway and not listed.
  List<TranscriptItem> breakouts([Set<String> waiting = const {}]) => [
    for (final item in items)
      if ((item is TranscriptTool &&
              (toolFailed(item.call) ||
                  item.call.status == ToolStatus.cancelled ||
                  waiting.contains(item.call.toolCallId))) ||
          item is TranscriptStop)
        item,
  ];

  /// A tool call of the turn needs a look: [breakouts] is not empty.
  bool needsAttention([Set<String> waiting = const {}]) => breakouts(waiting).isNotEmpty;
}

/// A message with something to show: a block that is not blank text. A live
/// message always counts: its text grows without the transcript list
/// changing, so what it holds now says nothing about what the turn will see.
bool _hasContent(TranscriptMessage m) {
  if (m.live != null) return true;
  for (final b in m.blocks) {
    if (b is! TextBlock || b.text.trim().isNotEmpty) return true;
  }
  return false;
}

final _built = Expando<List<Turn>>('turns');
final _builtLive = Expando<List<Turn>>('live turns');
final _byFirst = Expando<Turn>('turn by first item');

/// The turns of a transcript: a turn starts at each user message; items
/// before the first user message form a turn of their own with no user.
///
/// Memoized by list identity: the same list gives the same turn list, and a
/// turn whose items did not change since the list before it is the same
/// object (so a widget can key its own memo on `identical(turn, old)`). The
/// reducer keeps the list as it is while text streams into the live message,
/// so streaming costs nothing here; a structural change costs one pass over
/// the items.
///
/// With [live] (`AgentSessionState.turnActive`) the last turn is live.
List<Turn> turnsOf(List<TranscriptItem> items, {bool live = false}) {
  final base = _built[items] ??= _build(items);
  if (!live || base.isEmpty) return base;
  return _builtLive[items] ??= List.unmodifiable([...base.take(base.length - 1), base.last.withLive(true)]);
}

List<Turn> _build(List<TranscriptItem> items) {
  final out = <Turn>[];
  void close(TranscriptMessage? user, List<TranscriptItem> slice) {
    if (user == null && slice.isEmpty) return;
    final first = user ?? slice.first;
    final known = _byFirst[first];
    if (known != null && known._sameItems(user, slice)) {
      out.add(known);
      return;
    }
    final turn = Turn._(user == null ? 'turn:${slice.first.key}' : 'turn:${user.key}', user, slice, false);
    _byFirst[first] = turn;
    out.add(turn);
  }

  TranscriptMessage? user;
  var slice = <TranscriptItem>[];
  for (final item in items) {
    if (item is TranscriptMessage && item.role == MessageRole.user) {
      close(user, slice);
      user = item;
      slice = [];
    } else {
      slice.add(item);
    }
  }
  close(user, slice);
  return List.unmodifiable(out);
}
