import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/auth_needed.dart';
import 'package:herdr_mobile/data/acp/prompt_queue.dart';
import 'package:herdr_mobile/data/acp/past_session.dart';
import 'package:herdr_mobile/data/acp/background/background_work.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/acp/subagents/subagent_overlay.dart';
import 'package:herdr_mobile/data/acp/subagents/subagent_run.dart' show SubagentLogStatus, SubagentRun, SubagentSummary;
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import 'fake_transport.dart';

/// A scripted [AgentSessionView]: tests push states built with the reducer
/// ([push], [apply]) and read back what the screen did to it.
class FakeAgentSession extends ChangeNotifier implements AgentSessionView {
  FakeAgentSession({
    this._state = const AgentSessionState('s1'),
    this.key = 'm/k1',
    this.agent = 'claude',
    this.agentLabel = 'Claude Code',
    this.cwd = '/home/dev/payments-api',
    this.title = 'payments-api',
    this._link = AgentLink.live,
    this._error,
    this._unseenDone = false,
    MachineConnection? machine,
  }) : machine =
           machine ??
           MachineConnection(
             profile: const MachineProfile(id: 'm', label: 'devbox', host: 'h', username: 'u'),
             api: HerdrApi(FakeTransport()),
             backoff: (_) => const Duration(hours: 1),
           );

  @override
  final String key;
  @override
  final MachineConnection machine;
  @override
  final String agent;
  @override
  final String agentLabel;
  @override
  final String cwd;
  @override
  String title;

  AgentSessionState _state;
  AgentLink _link;
  String? _error;
  bool _unseenDone;

  /// Prompts the screen sent, oldest first.
  final sent = <String>[];
  var cancelCount = 0;
  var markSeenCount = 0;
  final permissionAnswers = <(Object, PermissionOutcome)>[];
  final questionAnswers = <(Object, ElicitationResponse)>[];
  final modes = <String>[];
  final configs = <(String, Object)>[];

  /// When true an answer leaves the request pending, to prove the screen
  /// itself refuses a second answer before the session has caught up.
  bool keepPendingOnAnswer = false;

  @override
  AgentSessionState get state => _state;
  @override
  AgentLink get link => _link;

  /// Set by a test to show the session as a saved copy.
  DateTime? cachedAsOfValue;

  /// Shows the session as a saved copy ([asOf]) or as confirmed (null).
  void setSavedCopy(DateTime? asOf) {
    cachedAsOfValue = asOf;
    notifyListeners();
  }

  @override
  DateTime? get cachedAsOf => cachedAsOfValue;
  @override
  String? get error => _error;
  @override
  AgentPhase get phase => _state.phase;
  DateTime? phaseSinceValue;
  @override
  DateTime? get phaseSince => phaseSinceValue;

  /// What [lastActivity] says; tests set it.
  @override
  DateTime? lastActivity;
  @override
  bool get unseenDone => _unseenDone;

  /// Replaces the state and notifies once. Like the real session's flush, the
  /// live message's text is announced first, then the listeners.
  void push(AgentSessionState state) {
    final ended = _state.turnActive && !state.turnActive;
    _state = state;
    if (!state.turnActive) {
      turnStart = null;
    } else {
      turnStart ??= DateTime.now();
    }
    // Like the real session: after the person's Stop, what waits goes out as one.
    if (ended) {
      if (_stopSendsQueue) _queue.mergeWaiting();
      _stopSendsQueue = false;
    }
    state.liveMessage?.live?.flush();
    notifyListeners();
    _pump();
  }

  bool _stopSendsQueue = false;

  /// Holds what waits, as a failed or foreign-stopped turn does in the real
  /// session.
  void holdQueue(String reason) {
    if (_queue.holdAll(reason)) notifyListeners();
  }

  /// What [turnStartedAt] says; follows [push]: set when a turn runs, cleared
  /// when it does not. Tests may set it.
  DateTime? turnStart;

  @override
  DateTime? get turnStartedAt => turnStart;

  @override
  Listenable? liveTextOf(String messageKey) => _state.liveTextOf(messageKey);

  /// Folds [update] into the state and notifies once.
  void apply(SessionUpdate update) => push(_state.apply(update));

  /// Changes the state with [change] and notifies once.
  void update(AgentSessionState Function(AgentSessionState s) change) => push(change(_state));

  void setLink(AgentLink link, {String? error}) {
    _link = link;
    _error = error;
    notifyListeners();
  }

  void setUnseenDone(bool value) {
    _unseenDone = value;
    notifyListeners();
  }

  bool _seenCleared = false;

  @override
  void markSeen() {
    markSeenCount++;
    if (_unseenDone) {
      _unseenDone = false;
      _seenCleared = true;
      notifyListeners();
    }
  }

  @override
  bool unmarkSeen() {
    if (!_seenCleared || _unseenDone) return false;
    _seenCleared = false;
    _unseenDone = true;
    notifyListeners();
    return true;
  }

  @override
  Future<bool> send(String text) => sendBlocks([TextBlock(text)]);

  /// Set by a test to make every send fail with this reason (in [error]),
  /// nothing kept, like a real send that could not reach the agent.
  String? refuseSends;

  /// Set by a test to hold every send's outcome until it completes.
  Completer<void>? holdSends;

  /// Like the real session: a message goes now when idle, into the turn when
  /// it runs and [steerable], else into [queued]; what waits goes out (one at
  /// a time) when a pushed state has no turn running, unless held.
  @override
  Future<bool> sendBlocks(List<ContentBlock> blocks, {bool queue = false}) async {
    if (blocks.isEmpty) return false;
    if (holdSends case final hold?) await hold.future;
    if (refuseSends case final why?) {
      _error = why;
      notifyListeners();
      return false;
    }
    if (blocks.any((b) => b is ImageBlock) && !imagesAccepted) {
      _error = 'the agent does not take images';
      notifyListeners();
      return false;
    }
    switch (delivery) {
      case SendDelivery.now:
        _go(blocks);
      case SendDelivery.steered when !queue:
        steeredBlocks.add(blocks);
        push(_state.withUserMessage(blocks));
      case SendDelivery.steered || SendDelivery.queued:
        _queue.add(blocks, at: DateTime.now());
        notifyListeners();
    }
    return true;
  }

  void _go(List<ContentBlock> blocks) {
    sentBlocks.add(blocks);
    sent.add(QueuedMessage(id: '', blocks: blocks, at: DateTime.now()).text);
    _state = _state.withUserMessage(blocks).withTurnStarted();
    turnStart ??= DateTime.now();
    notifyListeners();
  }

  void _pump() {
    if (_state.turnActive || _state.pending.isNotEmpty) return;
    final next = _queue.firstWaiting;
    if (next == null) return;
    _queue.remove(next.id);
    _go(next.blocks);
  }

  /// What the screen sent as prompts, blocks and all (parallel to [sent]).
  final sentBlocks = <List<ContentBlock>>[];

  /// What the screen sent into a running turn.
  final steeredBlocks = <List<ContentBlock>>[];

  /// The route takes messages into a running turn ([canSteer]).
  bool steerable = false;

  /// Whether the agent takes pictures ([acceptsImages]); a send with one
  /// fails in [error] when not, like the real session.
  bool imagesAccepted = true;
  bool embeddedAccepted = false;
  AuthNeeded? auth;
  final _queue = PromptQueue();

  /// Tests may force what [delivery] says (an observed session's is always
  /// [SendDelivery.now]).
  SendDelivery? forcedDelivery;

  @override
  SendDelivery get delivery {
    if (forcedDelivery case final forced?) return forced;
    if (_queue.hasWaiting) return SendDelivery.queued;
    if (_state.phase != AgentPhase.idle) return steerable ? SendDelivery.steered : SendDelivery.queued;
    return SendDelivery.now;
  }

  @override
  bool get canSteer => steerable;

  @override
  bool get acceptsImages => imagesAccepted;

  @override
  bool get acceptsEmbeddedContext => embeddedAccepted;

  @override
  List<QueuedMessage> get queued => _queue.entries;

  @override
  void editQueued(String id, String text) {
    if (_queue.edit(id, text)) notifyListeners();
  }

  @override
  void removeQueued(String id) {
    if (_queue.remove(id)) notifyListeners();
  }

  @override
  void resumeQueue() {
    if (!_queue.release()) return;
    notifyListeners();
    _pump();
  }

  @override
  AuthNeeded? get authNeeded => auth;

  // Like the ACP session: read from the pushed state.
  @override
  List<SubagentRun> get subagentRuns => overlay.runs(_state.subagents);

  @override
  SubagentSummary get subagentSummary => _state.subagentSummary;

  @override
  SubagentRun? subagentRun(String id) => overlay.run(_state.subagentRun(id));

  @override
  List<SubagentRun> subagentsOfToolCall(String toolCallId) => [
    for (final r in _state.subagentsOfToolCall(toolCallId)) overlay.run(r)!,
  ];

  /// Transcripts "read from a log" the test attached to runs.
  final overlay = SubagentOverlay();

  /// What [subagentLogStatus] answers, by run id.
  final logStatuses = <String, SubagentLogStatus>{};

  /// Every [watchSubagentLog] call, in order.
  final logWatches = <(String, bool)>[];
  final logRetries = <String>[];

  @override
  void watchSubagentLog(String runId, bool on) => logWatches.add((runId, on));

  @override
  SubagentLogStatus subagentLogStatus(String runId) => logStatuses[runId] ?? SubagentLogStatus.idle;

  @override
  void retrySubagentLog(String runId) => logRetries.add(runId);

  /// Tests set these to drive the background strip and sheet.
  @override
  BackgroundWork backgroundWork = BackgroundWork.empty;
  @override
  bool waitingOnBackground = false;
  final List<String> stopped = [];
  int stopAllCount = 0;
  BackgroundStopResult stopResult = const BackgroundStopped();

  @override
  Future<BackgroundStopResult> stopBackground(String id) async {
    stopped.add(id);
    return stopResult;
  }

  @override
  Future<BackgroundStopResult> stopAllBackground() async {
    stopAllCount++;
    return stopResult;
  }

  /// Replaces the background work and tells the listeners.
  void setBackground(BackgroundWork work, {bool waiting = false}) {
    backgroundWork = work;
    waitingOnBackground = waiting;
    notifyListeners();
  }

  @override
  void cancel() {
    cancelCount++;
    if (_queue.hasWaiting && _state.turnActive) _stopSendsQueue = true;
    push(_state.withCancelRequested());
  }

  @override
  Future<void> setMode(String modeId) async => modes.add(modeId);

  @override
  Future<void> setConfigOption(String configId, Object value) async => configs.add((configId, value));

  @override
  void answerPermission(Object requestId, PermissionOutcome outcome) {
    permissionAnswers.add((requestId, outcome));
    if (!keepPendingOnAnswer) push(_state.withoutPending(requestId));
  }

  @override
  void answerQuestion(Object requestId, ElicitationResponse response) {
    questionAnswers.add((requestId, response));
    if (!keepPendingOnAnswer) push(_state.withoutPending(requestId));
  }

  @override
  Future<void> end() async {
    _link = AgentLink.ended;
    notifyListeners();
  }

  /// Taken over by another device (link ended, [evicted] true).
  bool _evicted = false;
  var reattachCount = 0;

  /// Holds taken with [acquire] and not yet given back.
  var holds = 0;
  var acquired = 0;
  var released = 0;

  @override
  void acquire() {
    holds++;
    acquired++;
  }

  @override
  void release() {
    holds--;
    released++;
  }

  @override
  bool get evicted => _evicted;

  @override
  AnsweredElsewhere? answeredElsewhere;

  /// Another client answered the request [requestId] first (the keeper's
  /// `_herdr/resolved`), then withdrew it here (its `$/cancel_request`).
  void answerElsewhere(Object requestId, {required String by, required String answer}) {
    final pending = _state.pendingById(requestId);
    answeredElsewhere = AnsweredElsewhere(
      requestId: requestId,
      by: by,
      answer: answer,
      kind: pending is PendingPermission
          ? pending.request.options.where((o) => o.name == answer).firstOrNull?.kind
          : null,
      question: pending is PendingQuestion,
    );
    push(_state.withoutPending(requestId));
  }

  /// What [resumeTarget] answers (an ended session a test can continue).
  ResumeTarget? resumeTargetValue;

  @override
  ResumeTarget? get resumeTarget => resumeTargetValue;

  /// Another device took the session over.
  void evict() {
    _evicted = true;
    _link = AgentLink.ended;
    _error = 'Opened on another device.';
    notifyListeners();
  }

  @override
  Future<void> reattach() async {
    reattachCount++;
    _evicted = false;
    _link = AgentLink.live;
    _error = null;
    notifyListeners();
  }

  /// Set to make this fake an observed session (pane `terminalPaneId`).
  bool observed = false;
  String? paneId;
  bool terminalNeeded = false;

  @override
  bool get isObserved => observed;

  @override
  String? get terminalPaneId => observed ? paneId : null;

  @override
  bool get needsTerminal => terminalNeeded;

  /// What the roster shows, and the live output ([liveOutput]); the note the
  /// composer shows ([relayNote]).
  List<SubagentEntry> roster = const [];
  var rosterWatchers = 0;
  String? relay;
  List<String>? live;

  @override
  List<SubagentEntry> get subagents => roster;

  @override
  void watchSubagents(bool on) => rosterWatchers += on ? 1 : -1;

  @override
  String? get relayNote => relay;

  @override
  List<String>? get liveOutput => live;

  String? blockedReason;

  @override
  String? get sendBlocked => blockedReason;
}

/// [AgentSessions] over a fixed list, for the navigation entry point.
class FakeAgentSessions extends ChangeNotifier implements AgentSessions {
  FakeAgentSessions(this.sessions);

  @override
  final List<AgentSessionView> sessions;

  @override
  AgentSessionView? byKey(String key) {
    for (final s in sessions) {
      if (s.key == key) return s;
    }
    return null;
  }

  @override
  Future<Set<String>> available(MachineConnection machine) async => const {};

  @override
  Future<AgentSessionView> start({
    required MachineConnection machine,
    required String agent,
    required String cwd,
  }) => throw UnimplementedError('the screen never starts sessions');

  @override
  Future<PastSessions> history({required MachineConnection machine, required String agent, String? cwd}) async =>
      PastSessions(agent: agent, sessions: const []);

  @override
  Future<AgentSessionView> resume({
    required MachineConnection machine,
    required String agent,
    required String cwd,
    required String sessionId,
    String? replaces,
  }) => throw UnimplementedError('override resume in a test that continues sessions');

  @override
  Future<void> refresh() async {}

  @override
  void setBoardVisible(bool visible) {}

  /// What the app last asked for (see [AgentSessions.keepAliveInBackground]).
  bool keepAlive = false;

  @override
  set keepAliveInBackground(bool value) => keepAlive = value;

  /// The keys [preconnect] was asked for and the holds that are still open.
  final preconnected = <String>[];
  var openPreconnects = 0;

  @override
  Preconnect preconnect(String sessionKey) {
    preconnected.add(sessionKey);
    openPreconnects++;
    return _FakePreconnect(() => openPreconnects--);
  }
}

class _FakePreconnect implements Preconnect {
  _FakePreconnect(this._onCancel);

  final void Function() _onCancel;
  var _done = false;

  @override
  void cancel() {
    if (_done) return;
    _done = true;
    _onCancel();
  }
}

// ---------------------------------------------------------------------------
// state builders

/// A state with [items] and the rest as given.
AgentSessionState stateWith({
  List<TranscriptItem> items = const [],
  List<PlanEntry> plan = const [],
  List<AcpCommand> commands = const [],
  List<ConfigOption> options = const [],
  ModeState? modes,
  List<PendingRequest> pending = const [],
  bool turnActive = false,
}) {
  var s = const AgentSessionState('s1');
  s = s.withSetup(AcpSessionSetup(modes: modes, configOptions: options));
  return AgentSessionState(
    's1',
    items: items,
    plan: plan,
    commands: commands,
    modes: s.modes,
    configOptions: s.configOptions,
    pending: pending,
    turnActive: turnActive,
    nextKey: items.length,
  );
}

TranscriptMessage userMsg(String key, String text) =>
    TranscriptMessage(key: key, role: MessageRole.user, blocks: [TextBlock(text)]);

TranscriptMessage agentMsg(String key, String text) =>
    TranscriptMessage(key: key, role: MessageRole.agent, messageId: key, blocks: [TextBlock(text)]);

TranscriptMessage thoughtMsg(String key, String text) =>
    TranscriptMessage(key: key, role: MessageRole.thought, messageId: key, blocks: [TextBlock(text)]);

TranscriptTool toolItem(
  String id, {
  String title = '',
  ToolKind kind = ToolKind.other,
  ToolStatus status = ToolStatus.completed,
  Object? rawInput,
  Object? rawOutput,
  List<ToolContent> content = const [],
}) => TranscriptTool(
  ToolCall(
    toolCallId: id,
    title: title,
    kind: kind,
    status: status,
    rawInput: rawInput,
    rawOutput: rawOutput,
    content: content,
  ),
);

PermissionRequest permissionRequest({
  String title = 'Run command',
  ToolKind kind = ToolKind.execute,
  Object? rawInput,
  List<PermissionOption>? options,
  List<Object>? locations,
  List<Object>? content,
}) => PermissionRequest(
  sessionId: 's1',
  toolCall: ToolCallPatch('t1', {
    'toolCallId': 't1',
    'title': title,
    'kind': switch (kind) {
      ToolKind.execute => 'execute',
      ToolKind.edit => 'edit',
      _ => 'other',
    },
    'rawInput': ?rawInput,
    'locations': ?locations,
    'content': ?content,
  }),
  options:
      options ??
      const [
        PermissionOption(optionId: 'allow-once', name: 'Allow once', kind: PermissionOptionKind.allowOnce),
        PermissionOption(optionId: 'allow-always', name: 'Always allow', kind: PermissionOptionKind.allowAlways),
        PermissionOption(optionId: 'reject', name: 'Reject', kind: PermissionOptionKind.rejectOnce),
      ],
);
