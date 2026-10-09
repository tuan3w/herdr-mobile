import 'background/background_book.dart';
import 'background/background_work.dart' show BackgroundTask;
import 'background/omp_jobs.dart';
import 'acp_models.dart';
import 'live_text.dart';
import 'subagents/run_facts.dart';
import 'subagents/subagent_book.dart';
import 'subagents/subagent_run.dart';
import 'turns/tool_summary.dart' show kindWord, toolSummary;

/// Why the agent session needs (or does not need) the person.
enum AgentPhase {
  /// Nothing running; the next prompt can go.
  idle,

  /// A turn is running and nothing waits for the user.
  working,

  /// A `session/request_permission` is waiting for an answer.
  blockedOnPermission,

  /// An `elicitation/create` (the agent's question) is waiting.
  blockedOnQuestion,
}

/// One entry of the transcript, in the order things happened.
///
/// Every item says when this client first saw it ([at], by the clock the
/// caller gave [AgentSessionState.apply]). An item that came with a replayed
/// history (`session/load`), or from a caller that gave no clock, has no time:
/// the replay time would be a lie, so [at] is null and [timed] false, and
/// nothing derived from times (a duration) may be shown for it.
sealed class TranscriptItem {
  const TranscriptItem();

  /// Stable for the life of the session; a list key.
  String get key;

  /// When this client first saw the item; null when unknown (see above).
  DateTime? get at;

  /// [at] is a real time.
  bool get timed => at != null;
}

/// One message of the conversation.
///
/// The message that is streaming in right now is *live*: the end of its text
/// sits in a [LiveText] that chunks append to in place, so a chunk costs O(1)
/// and leaves the item list untouched (see [AgentSessionState.apply]). [text]
/// and [blocks] always give the text so far, live or not; every other message
/// (history, a prompt the user sent, a message that ended) holds plain blocks
/// and never changes.
class TranscriptMessage extends TranscriptItem {
  const TranscriptMessage({
    required this.key,
    required this.role,
    this.messageId,
    this._blocks = const [],
    this.local = false,
    this.at,
    this.endedAt,
  }) : live = null;

  /// A message whose last block is the text in [live]; [head] are the blocks
  /// before it. Made by the reducer only.
  const TranscriptMessage._streaming({
    required this.key,
    required this.role,
    required this.messageId,
    required List<ContentBlock> head,
    required LiveText this.live,
    required this.at,
  })  : _blocks = head,
        local = false,
        endedAt = null;

  @override
  final String key;
  final MessageRole role;

  /// When the first part of the message arrived (see [TranscriptItem.at]).
  @override
  final DateTime? at;

  /// When the message stopped growing: the time of the update that settled
  /// it (the next item, the end of the turn). Null while it is live, for a
  /// message that was never live, and when the clock is unknown.
  final DateTime? endedAt;

  /// The agent's id; null when it sends none (and for [local] messages).
  final String? messageId;
  final List<ContentBlock> _blocks;

  /// The text still growing, as the last block of the message; null when the
  /// message is not streaming.
  final LiveText? live;

  /// A user message this client added when it sent the prompt, before any
  /// echo from the agent.
  final bool local;

  /// The content so far. For a live message this builds the list (and joins
  /// the live text) on every call: rows that follow the stream read [live]
  /// instead.
  List<ContentBlock> get blocks {
    final l = live;
    return l == null ? _blocks : [..._blocks, TextBlock(l.text)];
  }

  /// The text blocks joined.
  String get text {
    final b = StringBuffer();
    for (final block in _blocks) {
      if (block is TextBlock) b.write(block.text);
    }
    if (live case final l?) b.write(l.text);
    return b.toString();
  }

  /// This message as it stands, no longer live (itself when it is not);
  /// [now] is when it stopped growing.
  TranscriptMessage settledAt(DateTime? now) => live == null
      ? this
      : TranscriptMessage(key: key, role: role, messageId: messageId, blocks: blocks, local: local, at: at, endedAt: now);

  /// A copy with other content; never live.
  TranscriptMessage _with({String? key, List<ContentBlock>? blocks, String? messageId, bool? local}) => TranscriptMessage(
    key: key ?? this.key,
    role: role,
    messageId: messageId ?? this.messageId,
    blocks: blocks ?? this.blocks,
    local: local ?? this.local,
    at: at,
    endedAt: endedAt,
  );
}

/// One tool call. [at] is when the call was first seen (the start of its
/// step, waiting for the person's approval included); [finishedAt] when it
/// first reached a finished status. A call seen finished in a replay has
/// neither, and one that started in a replay and finished live has only
/// [finishedAt]: [duration] is then null.
class TranscriptTool extends TranscriptItem {
  const TranscriptTool(this.call, {this.at, this.finishedAt});

  final ToolCall call;

  @override
  final DateTime? at;
  final DateTime? finishedAt;

  /// Start of the step; same as [at].
  DateTime? get startedAt => at;

  /// How long the step took; null while it runs and whenever either end is
  /// unknown.
  Duration? get duration {
    final a = at, b = finishedAt;
    return a == null || b == null ? null : b.difference(a);
  }

  @override
  String get key => 'tool:${call.toolCallId}';
}

/// A quiet line the app writes where a turn stopped for a reason the person
/// should know: the agent refused, or ran into a limit. It is not something
/// the agent said. A cancelled turn (the person's own act) and an error turn
/// (shown as the session's problem) get none.
class TranscriptStop extends TranscriptItem {
  const TranscriptStop({required this.key, required this.reason, this.at});

  @override
  final String key;

  @override
  final DateTime? at;

  /// [StopReason.refusal], [StopReason.maxTokens] or [StopReason.maxTurnRequests].
  final StopReason reason;
}

/// A quiet line the app writes about something that changed in the session
/// and is not something the agent said: today the agent switching the mode on
/// its own ("Mode changed to Plan"). Never written for a replayed history, nor
/// for a change the person made in this session.
class TranscriptNote extends TranscriptItem {
  const TranscriptNote({required this.key, required this.text, this.modeId, this.at});

  @override
  final String key;

  /// The words, plain text.
  final String text;

  /// The mode the note announces; null for any other note.
  final String? modeId;

  @override
  final DateTime? at;
}

/// The key of the note at the very top of a transcript whose host dropped its
/// oldest turns (`AcpSessionSetup.droppedTurns`).
const hostDroppedKey = 'host-dropped';

String hostDroppedText(int turns) =>
    'Earlier messages are no longer kept on the host ($turns ${turns == 1 ? 'turn' : 'turns'}).';

/// The key and words of the divider between what only this phone still has
/// (above) and what the host replayed (below), written when the two could not
/// be matched up ([AgentSessionState.withHeld]).
const phoneEarlierKey = 'phone-earlier';
const phoneEarlierText = 'Earlier, from this phone';

/// A request from the agent that waits for the person. [id] is the JSON-RPC
/// id of the agent's request.
sealed class PendingRequest {
  const PendingRequest(this.id, {this.origin});

  final Object id;

  /// The subagent that asked ("From subagent: Explore"), when one did; null
  /// for the main agent. A request from a subagent is as blocking as any.
  final SubagentOrigin? origin;

  String? get sessionId;

  /// The same request, said to come from [origin].
  PendingRequest withOrigin(SubagentOrigin origin);
}

class PendingPermission extends PendingRequest {
  const PendingPermission(super.id, this.request, {super.origin});

  final PermissionRequest request;

  @override
  String get sessionId => request.sessionId;

  @override
  PendingPermission withOrigin(SubagentOrigin origin) => PendingPermission(id, request, origin: origin);
}

class PendingQuestion extends PendingRequest {
  const PendingQuestion(super.id, this.request, {this.receivedAt, super.origin, this.draftKey});

  final ElicitationRequest request;

  /// When this client received the request (its own clock); null when the
  /// caller kept none. The countdown of an auto-resolving question counts
  /// from here.
  final DateTime? receivedAt;

  /// What identifies the QUESTION across requests, when the same question
  /// comes back under a new [id] (an observed question the terminal refused:
  /// the request is re-issued, the person's answers must not be lost). Null:
  /// the [id] is the question.
  final Object? draftKey;

  /// The key the unsent answers are kept under.
  Object get draftId => draftKey ?? id;

  @override
  String? get sessionId => request.sessionId;

  @override
  PendingQuestion withOrigin(SubagentOrigin origin) =>
      PendingQuestion(id, request, receivedAt: receivedAt, origin: origin, draftKey: draftKey);
}

const _keep = Object();

/// Everything the phone knows about one agent session, built only from what
/// the agent sent and what this client did (sent a prompt, cancelled,
/// answered a request).
///
/// Immutable, with one documented exception: the live slot. [apply] folds one
/// `session/update` in and returns the next state; the other `with*` methods
/// record client-side events. Same inputs, same output: nothing here reads a
/// clock or a random source.
///
/// **The live slot.** The message that is streaming in right now keeps the end
/// of its text in a [LiveText] ([liveMessage]). A text chunk for it is
/// appended to that object *in place*: O(1), the [items] list is the same
/// instance in the returned state (only the cheap state object is new, so a
/// caller that compares `identical(before, after)` still sees a change), and
/// states that share the list also share the grown text. The list is replaced
/// only when the structure changes: a new message, tool call or stop note, the
/// end of the turn, a disconnect, an upsert, a chunk for another message
/// (the previous live message is settled into plain blocks, the target goes
/// live). Whoever owns the state decides when listeners of the [LiveText]
/// hear of the text (`LiveText.flush`). A replayed or settled message has no
/// live part: [TranscriptMessage.text] and [TranscriptMessage.blocks] give
/// the same text either way, and the final text equals what a copy per chunk
/// would give (tested against a reference reducer over every recorded trace).
///
/// Rules ([apply]):
/// - A message is identified by `(role, messageId)` (omp sends one id for
///   the thought and the answer of a turn). A chunk without an id continues
///   the last message of its role. Chunks append; adjacent text merges.
///   A v2 upsert (`agent_message`...) replaces the blocks of the message it
///   names, keeps them when `content` is absent and clears them on null.
/// - Tool calls are keyed by id. `tool_call` replaces; `tool_call_update` is
///   a patch (omitted keeps, null clears) and creates the call when the
///   start was missed. They sit in the transcript where they first appeared.
///   Command output that arrives in `_meta` (codex-acp, pi-acp) is appended
///   per call ([ToolOutput]), never replaced, and survives a repeated start.
/// - A turn that ends in a refusal or a limit leaves a [TranscriptStop].
/// - Plan, commands and config options are replaced whole by each update.
/// - A user echo of the prompt this client already added is dropped, so a
///   session with an echoing agent does not show the prompt twice.
/// - Times: items and tool calls are stamped with [apply]'s `at` (see
///   [TranscriptItem]); nothing is stamped while [replaying].
/// - The agent switching the mode on its own (`current_mode_update`, or a
///   `config_option_update` that changes the mode option) adds one
///   [TranscriptNote], unless the state is [replaying] or [expectedMode] says
///   the person asked for exactly that mode.
/// - **Subagents.** What a subagent sends never enters [items]. Claude tags
///   everything a subagent says with `_meta.claudeCode.parentToolUseId` (the
///   id of the `Task`/`Agent` call): messages, tool calls (and their later,
///   untagged updates, routed by the call id), plans. They go to the
///   transcript of that run ([SubagentRun.items]), which is folded by the same
///   rules as this one, live slot included, so a child's text grows in place
///   ([SubagentRun.liveTextOf]); the run list stays the same instance while
///   only text grows. An update whose run does not exist yet is held (at most
///   [SubagentBook.maxHeld]) and applied when the call arrives. A child
///   transcript keeps the newest [SubagentRun.maxItems] items
///   ([SubagentRun.droppedItems] counts the rest). omp and Codex runs are
///   made from the parent call alone (no transcript). Cancelling takes the
///   active runs with it. A request that waits for the person gets the run it
///   came from as `origin` (see [withPending]).
class AgentSessionState {
  const AgentSessionState(
    this.sessionId, {
    this.items = const [],
    this.plan = const [],
    this.commands = const [],
    this.modes,
    this.configOptions = const [],
    this.title,
    this.updatedAt,
    this.usage,
    this.pending = const [],
    this.turnActive = false,
    this.cancelRequested = false,
    this.runState,
    this.lastStopReason,
    this.disconnected = false,
    this.nextKey = 0,
    this.echoed = 0,
    this.lastActivityAt,
    this.turnUsage,
    this.turnMeta,
    this.infoMeta,
    this.replaying = false,
    this.expectedMode,
    this.liveIndex = -1,
    this.subagentBook = const SubagentBook(),
    this.backgroundBook = const BackgroundBook(),
  });

  final String sessionId;
  final List<TranscriptItem> items;
  final List<PlanEntry> plan;
  final List<AcpCommand> commands;
  final ModeState? modes;
  final List<ConfigOption> configOptions;
  final String? title;
  final DateTime? updatedAt;
  final AcpUsage? usage;

  /// Requests waiting for the person, oldest first.
  final List<PendingRequest> pending;

  /// A prompt is in flight (or the v2 `state_update` says `running`).
  final bool turnActive;

  /// `session/cancel` went out and the turn has not ended yet.
  final bool cancelRequested;
  final AgentRunState? runState;

  /// How the last finished turn ended; null before the first one ends and
  /// while a turn runs.
  final StopReason? lastStopReason;

  /// The connection ended; the agent may or may not still be alive.
  final bool disconnected;

  /// Source of [TranscriptMessage.key]s.
  final int nextKey;

  /// Characters of the local user message the agent has echoed so far.
  final int echoed;

  /// When the agent last sent an update of any kind (a message, a tool call,
  /// an unknown one), by the clock the caller gave [apply]; null before the
  /// first. A client acts on [turnActive], but an agent can keep streaming
  /// after its `PromptResponse` (Claude, with background tasks; UNVERIFIED):
  /// this says "something is still arriving" whatever [turnActive] says.
  final DateTime? lastActivityAt;

  /// `PromptResponse.usage` of the last finished turn; null when that turn
  /// reported none, and before the first turn ends.
  final TurnUsage? turnUsage;

  /// `PromptResponse._meta` of the last finished turn (codex-acp: `quota`).
  final Json? turnMeta;

  /// `_meta` of the last `session_info_update` that carried one (pi-acp:
  /// `piAcp {queueDepth, running}`).
  final Json? infoMeta;

  /// Where in [items] the live message sits (see the class doc), or -1.
  /// Maintained by the reducer; a state built by hand has none.
  final int liveIndex;

  /// The subagents of the session and what routes updates to them (see
  /// [subagents]).
  final SubagentBook subagentBook;

  /// The background work that outlives a turn (shell jobs, background
  /// terminals, workflows). Cancelling a turn does not touch it: the work
  /// survives Stop. See [backgroundTasks].
  final BackgroundBook backgroundBook;

  /// The state is being rebuilt from a `session/load` replay: what arrives is
  /// history, so nothing is stamped with a time and no mode note is written.
  /// `AcpClient.loadSession` starts the state this way and [withSetup] (the
  /// answer to the load) ends it.
  final bool replaying;

  /// The mode the person just asked for (`session/set_mode`, or the mode
  /// option of `session/set_config_option`): the agent's own report of that
  /// change, whether it comes before or after the answer, writes no note.
  /// Set by [withExpectedMode] before the request, cleared when the mode
  /// arrives and by the caller when the request ends.
  final String? expectedMode;

  /// The message that is streaming in right now, whose last text chunks
  /// append to in place; null when none is.
  TranscriptMessage? get liveMessage {
    final i = liveIndex;
    if (i < 0 || i >= items.length) return null;
    final m = items[i];
    return m is TranscriptMessage && m.live != null ? m : null;
  }

  /// [TranscriptItem.key] of [liveMessage].
  String? get liveKey => liveMessage?.key;

  /// The growing text of the live message [messageKey], or null when that
  /// message is not live.
  LiveText? liveTextOf(String messageKey) {
    final m = liveMessage;
    return m != null && m.key == messageKey ? m.live : null;
  }

  AgentPhase get phase {
    if (pending.any((p) => p is PendingPermission)) return AgentPhase.blockedOnPermission;
    if (pending.any((p) => p is PendingQuestion)) return AgentPhase.blockedOnQuestion;
    if (runState == AgentRunState.requiresAction) return AgentPhase.blockedOnQuestion;
    return turnActive ? AgentPhase.working : AgentPhase.idle;
  }

  /// The tool calls in transcript order.
  Iterable<ToolCall> get toolCalls => [
    for (final i in items)
      if (i is TranscriptTool) i.call,
  ];

  /// The call with [id], or null.
  ToolCall? toolCall(String id) {
    final i = _toolIndex(id);
    return i < 0 ? null : (items[i] as TranscriptTool).call;
  }

  /// The id of the active mode: from the mode config option when there is
  /// one, else from `modes`.
  String? get currentModeId {
    for (final o in configOptions) {
      if (o is SelectConfigOption && o.category == 'mode') return o.value;
    }
    return modes?.currentModeId;
  }

  /// The pending request answered by [id], or null.
  PendingRequest? pendingById(Object id) {
    for (final p in pending) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// The ids of the tool calls that wait for the person's permission.
  Set<String> get waitingToolIds => {
    for (final p in pending)
      if (p is PendingPermission && p.request.toolCall.toolCallId.isNotEmpty) p.request.toolCall.toolCallId,
  };

  AgentSessionState _copy({
    List<TranscriptItem>? items,
    List<PlanEntry>? plan,
    List<AcpCommand>? commands,
    Object? modes = _keep,
    List<ConfigOption>? configOptions,
    Object? title = _keep,
    Object? updatedAt = _keep,
    Object? usage = _keep,
    List<PendingRequest>? pending,
    bool? turnActive,
    bool? cancelRequested,
    Object? runState = _keep,
    Object? lastStopReason = _keep,
    bool? disconnected,
    int? nextKey,
    int? echoed,
    Object? lastActivityAt = _keep,
    Object? turnUsage = _keep,
    Object? turnMeta = _keep,
    Object? infoMeta = _keep,
    int? liveIndex,
    bool? replaying,
    Object? expectedMode = _keep,
    SubagentBook? subagentBook,
    BackgroundBook? backgroundBook,
  }) => AgentSessionState(
    sessionId,
    items: items ?? this.items,
    plan: plan ?? this.plan,
    commands: commands ?? this.commands,
    modes: identical(modes, _keep) ? this.modes : modes as ModeState?,
    configOptions: configOptions ?? this.configOptions,
    title: identical(title, _keep) ? this.title : title as String?,
    updatedAt: identical(updatedAt, _keep) ? this.updatedAt : updatedAt as DateTime?,
    usage: identical(usage, _keep) ? this.usage : usage as AcpUsage?,
    pending: pending ?? this.pending,
    turnActive: turnActive ?? this.turnActive,
    cancelRequested: cancelRequested ?? this.cancelRequested,
    runState: identical(runState, _keep) ? this.runState : runState as AgentRunState?,
    lastStopReason: identical(lastStopReason, _keep) ? this.lastStopReason : lastStopReason as StopReason?,
    disconnected: disconnected ?? this.disconnected,
    nextKey: nextKey ?? this.nextKey,
    echoed: echoed ?? this.echoed,
    lastActivityAt: identical(lastActivityAt, _keep) ? this.lastActivityAt : lastActivityAt as DateTime?,
    turnUsage: identical(turnUsage, _keep) ? this.turnUsage : turnUsage as TurnUsage?,
    turnMeta: identical(turnMeta, _keep) ? this.turnMeta : turnMeta as Json?,
    infoMeta: identical(infoMeta, _keep) ? this.infoMeta : infoMeta as Json?,
    liveIndex: liveIndex ?? this.liveIndex,
    replaying: replaying ?? this.replaying,
    expectedMode: identical(expectedMode, _keep) ? this.expectedMode : expectedMode as String?,
    subagentBook: subagentBook ?? this.subagentBook,
    backgroundBook: backgroundBook ?? this.backgroundBook,
  );

  // -- updates from the agent ----------------------------------------------

  /// The state after [update]. An update this client does not model leaves
  /// the state as it is (the same instance), unless [at] is given.
  ///
  /// [at] is when the update arrived by the caller's clock (the reducer reads
  /// none); it becomes [lastActivityAt] for every update, modelled or not, and
  /// the time of what the update adds (see [TranscriptItem.at]) unless the
  /// state is [replaying].
  AgentSessionState apply(SessionUpdate update, {DateTime? at}) {
    final next = _apply(update, replaying ? null : at);
    return at == null ? next : next._copy(lastActivityAt: at);
  }

  AgentSessionState _apply(SessionUpdate update, DateTime? now) {
    final parent = _parentOf(update);
    if (parent != null) return _childUpdate(parent, update, now);
    final next = _applyMain(update, now);
    final toolId = _toolIdOf(update);
    if (toolId == null) return next;
    return next._noticeTool(toolId, _updateMeta(update), null, now)._noticeBackground(toolId, now);
  }

  /// [update] applied to this transcript, whoever sent it (a subagent's
  /// transcript is a state of its own, and is folded the same way).
  AgentSessionState _applyMain(SessionUpdate update, DateTime? now) => switch (update) {
    MessageChunk() => _chunk(update, now),
    MessageUpsert() => _upsert(update, now),
    ToolCallStart() => _putTool(
      update.call.toolCallId,
      (old) => old == null ? update.call : update.call.afterEarlier(old),
      now,
    ),
    ToolCallPatchUpdate() => _putTool(update.patch.toolCallId, update.patch.applyTo, now),
    ToolCallContentChunk() => _putTool(update.toolCallId, (old) {
      final call = old ?? ToolCall(toolCallId: update.toolCallId);
      return call.copyWith(content: [...call.content, update.content]);
    }, now),
    PlanUpdate() => _copy(plan: update.entries),
    CommandsUpdate() => _copy(commands: update.commands),
    ModeUpdate() => _mode(update.modeId, now),
    ConfigUpdate() => _copy(configOptions: update.options, modes: _modesFor(update.options))._announceMode(currentModeId, now),
    SessionInfoUpdate() => _copy(
      title: update.hasTitle ? update.title : _keep,
      updatedAt: update.hasUpdatedAt ? update.updatedAt : _keep,
      infoMeta: update.meta ?? _keep,
    ),
    UsageUpdate() => _copy(usage: update.usage),
    StateUpdate() => _state(update, now),
    AsyncTaskSpawned() => _background(backgroundBook.withSpawned(update, now: now)),
    AsyncTaskProgress() => _background(backgroundBook.withProgress(update, now: now)),
    AsyncTaskStateUpdate() => _background(backgroundBook.withState(update, now: now)),
    SdkBackgroundTasks() => _background(backgroundBook.withSdkTasks(update, now: now)),
    SdkTaskNotification() => _background(backgroundBook.withSdkNotification(update, now: now)),
    UnknownUpdate() => this,
  };

  AgentSessionState _chunk(MessageChunk c, DateTime? now) {
    if (c.role == MessageRole.user) {
      final echo = _echo(c);
      if (echo != null) return echo;
    }
    final block = c.content;
    // Text with no `_meta` merges into the text before it, as one block.
    final plain = block is TextBlock && block.meta == null;
    final target = _chunkTarget(c);
    if (target < 0) {
      final fresh = plain
          ? TranscriptMessage._streaming(
              key: 'm$nextKey',
              role: c.role,
              messageId: c.messageId,
              head: const [],
              live: LiveText(block.text),
              at: now,
            )
          : TranscriptMessage(key: 'm$nextKey', role: c.role, messageId: c.messageId, blocks: [block], at: now);
      return _append(fresh, live: plain, now: now)._copy(nextKey: nextKey + 1);
    }
    final m = items[target] as TranscriptMessage;
    if (plain && m.live != null) {
      // The O(1) path: the text grows in place, the list is the same list.
      m.live!.append(block.text);
      return _copy();
    }
    if (!plain) return _replaceAt(target, m._with(blocks: [...m.blocks, block]));
    // Plain text for a message that is not live: it goes live, taking the
    // text block it would have merged into.
    final blocks = m.blocks;
    final last = blocks.isEmpty ? null : blocks.last;
    final merge = last is TextBlock && last.meta == null;
    final started = TranscriptMessage._streaming(
      key: m.key,
      role: m.role,
      messageId: m.messageId,
      head: merge ? blocks.sublist(0, blocks.length - 1) : blocks,
      live: LiveText(merge ? last.text + block.text : block.text),
      at: m.at ?? now,
    );
    final next = List<TranscriptItem>.of(items);
    _settleIn(next, except: target, now: now);
    next[target] = started;
    return _copy(items: next, liveIndex: target);
  }

  /// The message [c] continues: the live one when it is that, else the
  /// latest of its `(role, id)`; -1 for none.
  int _chunkTarget(MessageChunk c) {
    final i = liveIndex;
    if (i >= 0 && i < items.length) {
      final m = items[i];
      if (m is TranscriptMessage &&
          m.live != null &&
          m.role == c.role &&
          (c.messageId == null ? i == items.length - 1 : m.messageId == c.messageId)) {
        return i;
      }
    }
    return _findMessage(c.role, c.messageId);
  }

  AgentSessionState _upsert(MessageUpsert u, DateTime? now) {
    final at = _findMessage(u.role, u.messageId);
    if (at < 0) {
      return _append(
        TranscriptMessage(key: 'm$nextKey', role: u.role, messageId: u.messageId, blocks: u.content ?? const [], at: now),
        now: now,
      )._copy(nextKey: nextKey + 1);
    }
    if (!u.hasContent) return this;
    final m = items[at] as TranscriptMessage;
    return _replaceAt(at, m._with(blocks: u.content ?? const []));
  }

  /// The index of the message a chunk or upsert belongs to, or -1.
  int _findMessage(MessageRole role, String? id) {
    if (id != null) {
      for (var i = items.length - 1; i >= 0; i--) {
        final it = items[i];
        if (it is TranscriptMessage && it.role == role && it.messageId == id) return i;
      }
      return -1;
    }
    if (items.isEmpty) return -1;
    final last = items.last;
    return last is TranscriptMessage && last.role == role && !last.local ? items.length - 1 : -1;
  }

  /// Drops a user chunk that repeats the local user message; null when it is
  /// not an echo.
  AgentSessionState? _echo(MessageChunk c) {
    if (items.isEmpty) return null;
    final last = items.last;
    final block = c.content;
    if (last is! TranscriptMessage || !last.local || block is! TextBlock) return null;
    final text = last.text;
    if (text.isEmpty || !text.startsWith(block.text, echoed)) return null;
    final matched = echoed + block.text.length;
    if (matched < text.length) return _copy(echoed: matched);
    return _replaceAt(items.length - 1, last._with(local: false, messageId: c.messageId))._copy(echoed: 0);
  }

  int _toolIndex(String id) {
    for (var i = items.length - 1; i >= 0; i--) {
      final it = items[i];
      if (it is TranscriptTool && it.call.toolCallId == id) return i;
    }
    return -1;
  }

  AgentSessionState _putTool(String id, ToolCall Function(ToolCall? old) next, DateTime? now) {
    final at = _toolIndex(id);
    if (at < 0) {
      final call = next(null);
      return _append(TranscriptTool(call, at: now, finishedAt: call.status.isFinished ? now : null), now: now);
    }
    final old = items[at] as TranscriptTool;
    final call = next(old.call);
    // The first moment the call is seen finished; a call that was finished
    // already (in a replay) keeps the time it has, or none.
    final finished = call.status.isFinished ? old.finishedAt ?? (old.call.status.isFinished ? null : now) : null;
    return _replaceAt(at, TranscriptTool(call, at: old.at, finishedAt: finished));
  }

  /// Adds [item] at the end. The live message (there is at most one) is
  /// settled first (at [now]): whatever comes next, it is not the one
  /// streaming any more. [live] marks [item] as the new live message.
  AgentSessionState _append(TranscriptItem item, {bool live = false, DateTime? now}) {
    final next = List<TranscriptItem>.of(items);
    _settleIn(next, except: -1, now: now);
    next.add(item);
    return _copy(items: next, liveIndex: live ? next.length - 1 : -1);
  }

  AgentSessionState _replaceAt(int at, TranscriptItem item) {
    final next = List<TranscriptItem>.of(items);
    next[at] = item;
    final stillLive = at != liveIndex || (item is TranscriptMessage && item.live != null);
    return _copy(items: next, liveIndex: stillLive ? null : -1);
  }

  /// Replaces the live message in [list] (a copy of [items]) by its settled
  /// form, unless it sits at [except]; [now] is when it stopped growing.
  void _settleIn(List<TranscriptItem> list, {required int except, DateTime? now}) {
    final i = liveIndex;
    if (i < 0 || i >= list.length || i == except) return;
    if (list[i] case final TranscriptMessage m when m.live != null) list[i] = m.settledAt(now);
  }

  /// The same state with the live message settled (at [now]): the message
  /// ended (the turn is over, the link dropped).
  AgentSessionState _settled([DateTime? now]) {
    if (liveMessage == null) return liveIndex < 0 ? this : _copy(liveIndex: -1);
    final next = List<TranscriptItem>.of(items);
    _settleIn(next, except: -1, now: now);
    return _copy(items: next, liveIndex: -1);
  }

  AgentSessionState _mode(String id, DateTime? now) {
    final before = currentModeId;
    final m = modes;
    return _copy(
      modes: m == null ? ModeState(currentModeId: id) : m.withCurrent(id),
      configOptions: [
        for (final o in configOptions)
          if (o is SelectConfigOption && o.category == 'mode' && o.choices.any((c) => c.value == id)) o.withValue(id) else o,
      ],
    )._announceMode(before, now);
  }

  /// After a change of the mode (this state already has the new one): the
  /// note that says so, when the agent made it on its own. [before] is the
  /// mode id before the update. The person's own change ([expectedMode]),
  /// a replay, and a first sight of the mode write none.
  AgentSessionState _announceMode(String? before, DateTime? now) {
    final after = currentModeId;
    if (after == null || after == before) return this;
    final mine = expectedMode == after;
    final state = mine ? _copy(expectedMode: null) : this;
    if (mine || before == null || replaying) return state;
    return state._append(
      TranscriptNote(key: 'n$nextKey', text: 'Mode changed to ${_modeName(after)}', modeId: after, at: now),
      now: now,
    )._copy(nextKey: nextKey + 1);
  }

  /// What the person reads for mode [id].
  String _modeName(String id) {
    for (final o in configOptions) {
      if (o is SelectConfigOption && o.category == 'mode') {
        for (final c in o.choices) {
          if (c.value == id) return c.name;
        }
      }
    }
    for (final m in modes?.availableModes ?? const <SessionMode>[]) {
      if (m.id == id) return m.name;
    }
    return id;
  }

  /// `modes` after the options changed: the mode option's value wins.
  ModeState? _modesFor(List<ConfigOption> options) {
    final m = modes;
    if (m == null) return null;
    for (final o in options) {
      if (o is SelectConfigOption && o.category == 'mode') return m.withCurrent(o.value);
    }
    return m;
  }

  AgentSessionState _state(StateUpdate u, DateTime? now) => switch (u.state) {
    AgentRunState.running => _copy(runState: u.state, turnActive: true),
    AgentRunState.idle => _settled(now)._copy(
      runState: u.state,
      turnActive: false,
      cancelRequested: false,
      lastStopReason: u.stopReason,
    )._withStopNote(u.stopReason, now)._cancelUnfinished(u.stopReason == StopReason.cancelled, now),
    AgentRunState.requiresAction => _copy(runState: u.state, turnActive: true),
    AgentRunState.unknown => this,
  };

  // -- subagents ----------------------------------------------------------------

  /// The subagents of the session, in the order they first appeared (see
  /// [SubagentRun]); empty for an agent that starts none. The list is the same
  /// instance until a run changes (the text of a subagent that streams in
  /// does not change it), so it can be compared and memoized by identity.
  List<SubagentRun> get subagents => subagentBook.runs;

  /// The run [id] ([SubagentRun.id]), or null.
  SubagentRun? subagentRun(String id) => subagentBook.run(id);

  /// The runs the tool call [toolCallId] started (the row in the transcript
  /// links to them by this); empty when it started none.
  List<SubagentRun> subagentsOfToolCall(String toolCallId) => [
    for (final r in subagentBook.runs)
      if (r.parentToolCallId == toolCallId) r,
  ];

  /// How many subagents there are and where they stand; memoized.
  SubagentSummary get subagentSummary => SubagentSummary.of(subagentBook.runs);

  /// Tells the listeners of every subagent's live text that text arrived
  /// (`LiveText.flush`), as the owner of the state does for [liveMessage].
  void flushSubagentLive() {
    for (final r in subagentBook.runs) {
      r.liveMessage?.live?.flush();
    }
  }

  /// The background tasks in order of first sight; the same list instance
  /// while none changed, so it can be compared and memoized by identity.
  List<BackgroundTask> get backgroundTasks => backgroundBook.tasks;

  AgentSessionState _background(BackgroundBook next) => identical(next, backgroundBook) ? this : _copy(backgroundBook: next);

  /// After the tool call [toolId] changed: the background jobs its result
  /// names (omp has no task update, see `ompJobFacts`).
  AgentSessionState _noticeBackground(String toolId, DateTime? now) {
    final index = _toolIndex(toolId);
    if (index < 0) return this;
    final facts = ompJobFacts((items[index] as TranscriptTool).call);
    if (facts.isEmpty) return this;
    var book = backgroundBook;
    for (final f in facts) {
      book = book.withOmpFact(f, toolCallId: toolId, now: now);
    }
    return _background(book);
  }

  /// The run the update names as its parent: the tag Claude puts on
  /// everything a subagent sends (`_meta.claudeCode.parentToolUseId`), or the
  /// run that owns the tool call the update is about (late updates of a call
  /// carry no tag); null for the main agent's own.
  String? _parentOf(SessionUpdate u) {
    final String? tagged = switch (u) {
      MessageChunk(:final meta) => _parentTag(meta),
      MessageUpsert(:final meta) => _parentTag(meta),
      PlanUpdate(:final meta) => _parentTag(meta),
      ToolCallStart() || ToolCallPatchUpdate() => _parentTag(_updateMeta(u)),
      _ => null,
    };
    final id = _toolIdOf(u);
    final parent = tagged ?? (id == null ? null : subagentBook.owners[id]);
    return parent == null || parent == id ? null : parent;
  }

  static String? _parentTag(Json? meta) {
    final cc = meta?['claudeCode'];
    final p = cc is Map ? cc['parentToolUseId'] : null;
    return p is String && p.isNotEmpty ? p : null;
  }

  static String? _toolIdOf(SessionUpdate u) => switch (u) {
    ToolCallStart(:final call) => call.toolCallId,
    ToolCallPatchUpdate(:final patch) => patch.toolCallId,
    ToolCallContentChunk(:final toolCallId) => toolCallId,
    _ => null,
  };

  /// The `_meta` of one tool call update alone.
  static Json? _updateMeta(SessionUpdate u) => switch (u) {
    ToolCallStart(:final call) => call.meta,
    ToolCallPatchUpdate(:final patch) => patch.fields['_meta'] is Map ? (patch.fields['_meta'] as Map).cast<String, Object?>() : null,
    _ => null,
  };

  /// An update from a subagent: it goes to the transcript of its run, never
  /// to the main one. Held when the run does not exist yet; a call that was
  /// first seen without its tag moves out of the main transcript.
  AgentSessionState _childUpdate(String parentId, SessionUpdate update, DateTime? now) {
    final toolId = _toolIdOf(update);
    var book = subagentBook;
    if (toolId != null) {
      book = book.withOwner(toolId, parentId);
      final at = _toolIndex(toolId);
      if (at >= 0) {
        final moved = items[at] as TranscriptTool;
        final s = _withoutItem(at)._copy(subagentBook: book);
        return s._childUpdate(parentId, ToolCallStart(moved.call), moved.at)._childUpdate(parentId, update, now);
      }
    }
    final run = book.run(parentId);
    if (run == null) return _copy(subagentBook: book.withHeld(HeldUpdate(parentId, update, now)));
    if (update is PlanUpdate) return _copy(subagentBook: book.withRun(run.copyWith(plan: update.entries)));

    final before = run.transcript ?? AgentSessionState(sessionId);
    final fresh = toolId != null && before._toolIndex(toolId) < 0;
    var child = before._applyMain(update, now);
    if (update is MessageChunk && run.transcript != null && identical(child.items, before.items)) {
      // Text grew in the child's live slot: nothing else changed.
      return _copy(subagentBook: book);
    }
    var dropped = run.droppedItems;
    if (child.items.length > SubagentRun.maxItems + SubagentRun.itemsSlack) {
      final drop = child.items.length - SubagentRun.maxItems;
      final live = child.liveIndex - drop;
      child = child._copy(items: child.items.sublist(drop), liveIndex: live < 0 ? -1 : live);
      dropped += drop;
    }
    var updated = run.copyWith(
      transcript: child,
      droppedItems: dropped,
      status: run.status == SubagentStatus.waiting ? SubagentStatus.running : null,
    );
    if (toolId != null) {
      final last = child._lastToolCall();
      if (last != null) {
        updated = updated.copyWith(
          toolCount: fresh ? updated.toolCount + 1 : null,
          lastTool: _toolName(last),
          lastToolLine: toolSummary(last).plain,
          recentTools: fresh ? _pushRecent(updated.recentTools, _toolName(last)) : null,
        );
      }
    }
    final s = _copy(subagentBook: book.withRun(updated));
    return toolId == null ? s : s._noticeTool(toolId, _updateMeta(update), parentId, now);
  }

  /// The newest tool call of the transcript, or null.
  ToolCall? _lastToolCall() {
    for (var i = items.length - 1; i >= 0; i--) {
      final it = items[i];
      if (it is TranscriptTool) return it.call;
    }
    return null;
  }

  static String _toolName(ToolCall call) {
    final cc = call.meta?['claudeCode'];
    final fromMeta = cc is Map ? cc['toolName'] : null;
    final name = call.name ?? (fromMeta is String ? fromMeta : null);
    return name != null && name.isNotEmpty ? name : kindWord(call.kind);
  }

  static List<String> _pushRecent(List<String> recent, String name) {
    final next = [...recent, name];
    return next.length <= SubagentRun.maxRecent ? next : next.sublist(next.length - SubagentRun.maxRecent);
  }

  /// After the tool call [toolId] changed in the transcript of [containerId]
  /// (null: the main one): makes or updates the runs it starts, and lets the
  /// updates that waited for it in.
  AgentSessionState _noticeTool(String toolId, Json? updateMeta, String? containerId, DateTime? now) {
    final container = containerId == null ? this : subagentBook.run(containerId)?.transcript;
    final index = container?._toolIndex(toolId) ?? -1;
    if (container == null || index < 0) return this;
    final tool = container.items[index] as TranscriptTool;
    final held = subagentBook.hasHeldFor(toolId);
    final known = [
      for (final r in subagentBook.runs)
        if (r.parentToolCallId == toolId) r,
    ];
    var facts = launchFacts(tool.call, updateMeta: updateMeta, known: known);
    if (facts.isEmpty) {
      if (!held) return this;
      // Children name it as their parent: it is a subagent whatever it is called.
      facts = [genericRunFacts(tool.call)];
    }
    var s = this;
    for (final f in facts) {
      s = s._upsertRun(f, tool, containerId, now);
    }
    if (!held) return s;
    final (book, updates) = s.subagentBook.takeHeld(toolId);
    s = s._copy(subagentBook: book);
    for (final h in updates) {
      s = s._childUpdate(h.parentId, h.update, h.at);
    }
    return s;
  }

  AgentSessionState _upsertRun(RunFacts f, TranscriptTool tool, String? containerId, DateTime? now) {
    final old = subagentBook.run(f.id);
    var run = runFromFacts(
      f,
      old: old,
      parentToolCallId: tool.call.toolCallId,
      parentRunId: containerId,
      startedAt: tool.at,
      now: now,
    );
    if (f.route == SubagentRoute.claude && run.transcript == null) {
      run = run.copyWith(transcript: AgentSessionState(sessionId));
    }
    final s = _copy(subagentBook: subagentBook.withRun(run));
    final cancelled = run.status == SubagentStatus.cancelled && old?.status != SubagentStatus.cancelled;
    return cancelled ? s._cascadeCancel(run.id, now) : s;
  }

  /// Marks the active run [id] cancelled, with what it was still doing.
  AgentSessionState _cancelRun(String id, DateTime? now) {
    final run = subagentBook.run(id);
    if (run == null || !run.isActive) return this;
    final cancelled = run.copyWith(status: SubagentStatus.cancelled, finishedAt: now);
    return _copy(subagentBook: subagentBook.withRun(cancelled))._cascadeCancel(id, now);
  }

  /// The run [id] was cancelled: its unfinished calls and the subagents it
  /// started are cancelled too.
  AgentSessionState _cascadeCancel(String id, DateTime? now) {
    final run = subagentBook.run(id);
    if (run == null) return this;
    var s = this;
    if (run.transcript case final t?) {
      s = s._copy(subagentBook: s.subagentBook.withRun(run.copyWith(transcript: t._settled(now)._cancelUnfinished(true, now))));
    }
    for (final nested in [
      for (final r in s.subagentBook.runs)
        if (r.parentRunId == id && r.isActive) r.id,
    ]) {
      s = s._cancelRun(nested, now);
    }
    return s;
  }

  /// The call [toolCallId] that starts a run waits for the person's
  /// permission ([blocked]) or was answered.
  AgentSessionState _runBlocked(String toolCallId, bool blocked) {
    final run = subagentBook.run(toolCallId);
    if (run == null) return this;
    if (blocked && run.status == SubagentStatus.running) {
      return _copy(subagentBook: subagentBook.withRun(run.copyWith(status: SubagentStatus.waiting)));
    }
    final stillBlocked = pending.any((p) => p is PendingPermission && p.request.toolCall.toolCallId == toolCallId);
    if (!blocked && !stillBlocked && run.status == SubagentStatus.waiting) {
      return _copy(subagentBook: subagentBook.withRun(run.copyWith(status: SubagentStatus.running)));
    }
    return this;
  }

  /// The subagent that [request] came from, or null.
  SubagentOrigin? _originOf(PendingRequest request) {
    final String? toolId;
    final String? tagged;
    switch (request) {
      case PendingPermission(:final request):
        toolId = request.toolCall.toolCallId;
        final own = request.toolCall.fields['_meta'];
        tagged = _parentTag(own is Map ? own.cast<String, Object?>() : null) ?? _parentTag(request.meta);
      case PendingQuestion(:final request):
        toolId = request.toolCallId;
        tagged = _parentTag(request.meta);
    }
    final parent = tagged ?? (toolId == null || toolId.isEmpty ? null : subagentBook.owners[toolId]);
    if (parent == null || parent == toolId) return null;
    return subagentBook.run(parent)?.origin;
  }

  /// The state without the item at [at].
  AgentSessionState _withoutItem(int at) {
    final next = List<TranscriptItem>.of(items)..removeAt(at);
    final live = liveIndex;
    return _copy(items: next, liveIndex: live == at ? -1 : (live > at ? live - 1 : live));
  }


  // -- what this client did ---------------------------------------------------

  /// The session as answered by new/load/resume: modes and options replace
  /// what was known; commands only when the response carried some (the
  /// agent sends them in an update). When the keeper says it no longer holds
  /// the oldest turns ([AcpSessionSetup.droppedTurns]), the transcript opens
  /// with one quiet line about it ([hostDroppedKey]).
  AgentSessionState withSetup(AcpSessionSetup s) {
    final next = _copy(
      modes: s.modes ?? modes,
      configOptions: s.configOptions.isEmpty ? configOptions : s.configOptions,
      commands: s.commands.isEmpty ? commands : s.commands,
      replaying: false,
    );
    return s.droppedTurns > 0 ? next._withHostDropped(s.droppedTurns) : next;
  }

  AgentSessionState _withHostDropped(int turns) {
    if (items.isEmpty) return this;
    final note = TranscriptNote(key: hostDroppedKey, text: hostDroppedText(turns));
    if (items.first.key == hostDroppedKey) return _copy(items: [note, ...items.skip(1)]);
    return _copy(items: [note, ...items], liveIndex: liveIndex < 0 ? null : liveIndex + 1);
  }

  /// This state, a replay that is now whole, together with [held], the
  /// transcript the phone showed until the replay arrived (what it held in
  /// memory, or its saved copy). The keeper's log is bounded and a re-attach
  /// must never make a thread shorter: the items of [held] that come before
  /// the replay's first item stay, once.
  ///
  /// Items are matched by what the replay would give again: a tool call by its
  /// id, a message by role and `messageId` (text when it has none). The
  /// replay's first items must be found in [held] (three in a row, where it
  /// has that many): everything of [held] above that point is kept. When the
  /// replay starts before [held] does, nothing is kept (the replay has it
  /// all). When neither can be found, the overlap cannot be proven: all of
  /// [held] stays above a divider ([phoneEarlierKey]) that says it comes from
  /// this phone, and nothing is merged below it.
  ///
  /// A call the host has since trimmed ([ToolCall.detailTrimmed]) keeps the
  /// phone's fuller copy when [held] has one. [older] is how many items were
  /// put above the replay (the divider not counted).
  ({AgentSessionState state, int older}) withHeld(AgentSessionState held) {
    final mine = items;
    final start = mine.isNotEmpty && mine.first.key == hostDroppedKey ? 1 : 0;
    final theirs = [
      for (final i in held.items)
        if (i.key != hostDroppedKey) i,
    ];
    if (theirs.isEmpty) return (state: this, older: 0);

    var cut = -1; // theirs[:cut] is what the replay does not have
    var proven = true;
    if (mine.length == start) {
      cut = theirs.length; // nothing replayed: the phone's is all there is
    } else {
      final replay = _anchors(mine, start);
      final phone = _anchors(theirs, 0);
      if (replay.isNotEmpty && phone.isNotEmpty) {
        for (var c = 0; c < phone.length && cut < 0; c++) {
          if (_matches(phone, c, replay, 0)) cut = phone[c].$1;
        }
        if (cut < 0) {
          for (var c = 0; c < replay.length; c++) {
            if (_matches(replay, c, phone, 0)) {
              cut = 0; // the replay reaches further back than the phone does
              break;
            }
          }
        }
      }
      if (cut < 0) {
        cut = theirs.length;
        proven = false;
      }
    }

    // Calls the phone has in full that the host now holds trimmed.
    final fuller = <String, TranscriptTool>{
      for (final i in theirs)
        if (i is TranscriptTool && !i.call.detailTrimmed) i.key: i,
    };
    final replayed = [
      for (final i in mine.skip(start))
        if (i is TranscriptTool && i.call.detailTrimmed && fuller[i.key] != null) fuller[i.key]! else i,
    ];

    var epoch = 0;
    for (final i in theirs) {
      final m = _earlierKey.firstMatch(i.key);
      if (m != null) epoch = epoch > int.parse(m[1]!) ? epoch : int.parse(m[1]!);
    }
    final prefix = 'e${epoch + 1}.';
    final older = [for (final i in theirs.take(cut)) _earlier(i, prefix)];
    final divider = proven || older.isEmpty
        ? null
        : const TranscriptNote(key: phoneEarlierKey, text: phoneEarlierText);
    final shift = older.length + (divider == null ? 0 : 1);
    if (shift == 0 && _sameItems(replayed, mine, start)) {
      return (state: this, older: 0);
    }

    // Runs of subagents of the older turns keep their cards.
    var book = subagentBook;
    final olderTools = {
      for (final i in older)
        if (i is TranscriptTool) i.call.toolCallId,
    };
    final olderRuns = [
      for (final r in held.subagentBook.runs)
        if (olderTools.contains(r.id) && book.run(r.id) == null) r,
    ];
    if (olderRuns.isNotEmpty) book = book.withRuns([...olderRuns, ...book.runs]);

    return (
      state: _copy(
        items: [if (start == 1) mine.first, ...older, ?divider, ...replayed],
        liveIndex: liveIndex < 0 ? null : liveIndex + shift,
        subagentBook: book,
      ),
      older: older.length,
    );
  }

  static final _earlierKey = RegExp(r'^e(\d+)\.');
  static final _generatedKey = RegExp(r'^[mn]\d+$');

  /// [item] above a replay whose own keys start from 0 again: a key the
  /// reducer made gets [prefix], so it cannot meet one of the replay's.
  static TranscriptItem _earlier(TranscriptItem item, String prefix) {
    if (!_generatedKey.hasMatch(item.key)) return item;
    return switch (item) {
      TranscriptMessage m => m._with(key: '$prefix${m.key}'),
      TranscriptStop s => TranscriptStop(key: '$prefix${s.key}', reason: s.reason, at: s.at),
      TranscriptNote n => TranscriptNote(key: '$prefix${n.key}', text: n.text, modeId: n.modeId, at: n.at),
      TranscriptTool() => item,
    };
  }

  /// What identifies the items a replay would give again (messages and
  /// calls), with their index; a stop or a note is the app's own.
  static List<(int, String)> _anchors(List<TranscriptItem> list, int from) => [
    for (var i = from; i < list.length; i++)
      if (_signature(list[i]) case final s?) (i, s),
  ];

  /// [_signature] of each of [items] that has one, in order.
  static List<String> signaturesOf(Iterable<TranscriptItem> items) => [
    for (final i in items) ?_signature(i),
  ];

  static String? _signature(TranscriptItem item) => switch (item) {
    TranscriptTool(:final call) => 'tool:${call.toolCallId}',
    // The keeper adds the id of a prompt the phone typed; until then it is
    // local and has none: the words are what they share.
    TranscriptMessage(role: MessageRole.user, :final text) => 'user:$text',
    TranscriptMessage(:final role, :final messageId, :final text) => '${role.name}:${messageId ?? text}',
    TranscriptStop() || TranscriptNote() => null,
  };

  /// [a] from [at] continues as [b] from [from]: up to three anchors equal
  /// (fewer when one of the lists ends).
  static bool _matches(List<(int, String)> a, int at, List<(int, String)> b, int from) {
    for (var k = 0; k < 3; k++) {
      if (at + k >= a.length || from + k >= b.length) return k > 0;
      if (a[at + k].$2 != b[from + k].$2) return false;
    }
    return true;
  }

  static bool _sameItems(List<TranscriptItem> replayed, List<TranscriptItem> mine, int start) {
    for (var i = 0; i < replayed.length; i++) {
      if (!identical(replayed[i], mine[start + i])) return false;
    }
    return true;
  }

  /// Replaces the option list (the answer to `session/set_config_option`).
  AgentSessionState withConfigOptions(List<ConfigOption> options) =>
      _copy(configOptions: options, modes: _modesFor(options));

  /// The person is about to ask for mode [modeId] (`session/set_mode`), or
  /// for none ([modeId] null: the request ended, drop what was expected): the
  /// agent's report of that change writes no note ([expectedMode]).
  AgentSessionState withExpectedMode(String? modeId) => expectedMode == modeId ? this : _copy(expectedMode: modeId);

  /// [withExpectedMode] for `session/set_config_option`: only a select of
  /// the mode category sets a mode.
  AgentSessionState withExpectedConfig(String configId, Object value) {
    for (final o in configOptions) {
      if (o.id == configId && o is SelectConfigOption && o.category == 'mode' && value is String) {
        return withExpectedMode(value);
      }
    }
    return this;
  }

  /// Adds the prompt the user just sent, so it shows before the agent
  /// answers. Marked [TranscriptMessage.local] until the agent echoes it.
  /// [at] is when it was sent (the caller's clock).
  AgentSessionState withUserMessage(List<ContentBlock> blocks, {DateTime? at}) => _append(
    TranscriptMessage(key: 'm$nextKey', role: MessageRole.user, blocks: blocks, local: true, at: at),
    now: at,
  )._copy(nextKey: nextKey + 1, echoed: 0);

  /// Takes back the local user message [key] that [withUserMessage] added: the
  /// agent refused the prompt as busy, nothing was taken, so the transcript
  /// must not say it was. Whatever the agent streamed after the row meanwhile
  /// (its own turn) keeps its place. The turn goes back to how [before] (the
  /// state the prompt was sent from) had it; an end the agent reported in the
  /// meantime stays.
  AgentSessionState withoutUserMessage(String key, {required AgentSessionState before}) {
    final at = items.indexWhere((i) => i.key == key && i is TranscriptMessage && i.local);
    final next = at < 0 ? items : (List<TranscriptItem>.of(items)..removeAt(at));
    final live = at >= 0 && liveIndex > at ? liveIndex - 1 : liveIndex;
    return _copy(
      items: next,
      liveIndex: live,
      echoed: 0,
      turnActive: before.turnActive || runState == AgentRunState.running,
      cancelRequested: before.cancelRequested,
      lastStopReason: lastStopReason ?? before.lastStopReason,
    );
  }

  AgentSessionState withTurnStarted() => _copy(turnActive: true, cancelRequested: false, lastStopReason: null);

  /// A transcript read from a log (it has no live slot) cut to its newest
  /// [max] items. The same instance when it already fits.
  AgentSessionState keepingNewest(int max) {
    if (items.length <= max) return this;
    final drop = items.length - max;
    final live = liveIndex - drop;
    return _copy(items: items.sublist(drop), liveIndex: live < 0 ? -1 : live);
  }

  /// The turn ended with [reason], at [at] (the caller's clock). A cancelled
  /// turn also marks what was still running as cancelled; a refusal or a
  /// limit leaves a [TranscriptStop]. [usage] and [meta] are the response's,
  /// kept as the last turn's.
  AgentSessionState withTurnEnded(StopReason reason, {TurnUsage? usage, Json? meta, DateTime? at}) =>
      _settled(at)._copy(
        turnActive: false,
        cancelRequested: false,
        runState: null,
        lastStopReason: reason,
        turnUsage: usage,
        turnMeta: meta,
      )._withStopNote(reason, at)._cancelUnfinished(reason == StopReason.cancelled, at);

  /// A [TranscriptStop] for [reason] when it asks for one, and the last item
  /// is not one already (the v2 `state_update` and the response both report
  /// the same end).
  AgentSessionState _withStopNote(StopReason reason, DateTime? now) {
    final noted = switch (reason) {
      StopReason.refusal || StopReason.maxTokens || StopReason.maxTurnRequests => true,
      _ => false,
    };
    if (!noted || (items.isNotEmpty && items.last is TranscriptStop)) return this;
    return _append(TranscriptStop(key: 'n$nextKey', reason: reason, at: now), now: now)._copy(nextKey: nextKey + 1);
  }

  /// `session/cancel` was sent (at [at], the caller's clock): ACP asks the
  /// client to mark the unfinished tool calls cancelled right away.
  AgentSessionState withCancelRequested({DateTime? at}) => _copy(cancelRequested: true)._cancelUnfinished(true, at);

  AgentSessionState _cancelUnfinished(bool cancel, DateTime? now) {
    if (!cancel) return this;
    var changed = false;
    final next = <TranscriptItem>[];
    for (final i in items) {
      if (i is TranscriptTool && !i.call.status.isFinished) {
        changed = true;
        next.add(TranscriptTool(i.call.copyWith(status: ToolStatus.cancelled), at: i.at, finishedAt: now));
      } else {
        next.add(i);
      }
    }
    var s = changed ? _copy(items: next) : this;
    // What was cancelled took its subagents with it.
    for (final id in [
      for (final r in s.subagentBook.runs)
        if (r.isActive) r.id,
    ]) {
      s = s._cancelRun(id, now);
    }
    return s;
  }

  /// Adds a request that waits for the person. When it came from a subagent
  /// (its call is one a run made, or `_meta.claudeCode.parentToolUseId` names
  /// a run) it gets that run as [PendingRequest.origin]. A permission for the
  /// call that starts a run makes that run [SubagentStatus.waiting] until it
  /// is answered.
  AgentSessionState withPending(PendingRequest request) {
    final origin = request.origin ?? _originOf(request);
    final stamped = origin == null ? request : request.withOrigin(origin);
    final s = _copy(pending: [...pending, stamped]);
    return request is PendingPermission ? s._runBlocked(request.request.toolCall.toolCallId, true) : s;
  }

  AgentSessionState withoutPending(Object id) {
    PendingRequest? removed;
    final next = <PendingRequest>[];
    for (final p in pending) {
      if (p.id == id) {
        removed = p;
      } else {
        next.add(p);
      }
    }
    if (removed == null) return this;
    final s = _copy(pending: next);
    return removed is PendingPermission ? s._runBlocked(removed.request.toolCall.toolCallId, false) : s;
  }

  /// The connection ended: nothing can be answered or is running from this
  /// client's point of view.
  AgentSessionState withDisconnected() =>
      _settled()._copy(disconnected: true, pending: const [], turnActive: false, cancelRequested: false, runState: null);
}
