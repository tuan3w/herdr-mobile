import 'dart:async';
import 'dart:math' show Random;
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';

import '../acp/acp_client.dart';
import '../acp/acp_models.dart';
import '../acp/agent_host.dart';
import '../acp/auth_needed.dart';
import '../acp/json_rpc.dart';
import '../acp/past_session.dart';
import '../acp/prompt_queue.dart';
import '../acp/background/background_work.dart';
import '../acp/session_state.dart';
import '../acp/transcript_log.dart';
import '../services/transcript_cache.dart';
import '../acp/subagents/subagent_run.dart' show SubagentLogStatus, SubagentRun, SubagentSummary;
import '../streaming/flush_scheduler.dart';
import 'agent_session.dart';
import 'machine_connection.dart';
import 'reviewed_state.dart';
import 'subagent_transcripts.dart';

final _random = Random();

/// A factor in [0.8, 1.2): the spread of retry delays, so sessions that lost
/// their link together do not all knock at the same moment.
double defaultRetryJitter() => 0.8 + _random.nextDouble() * 0.4;

/// One agent session: an [AcpClient] over the transport the host's keeper
/// gives, kept alive across link drops and app backgrounding.
///
/// **Attached or not.** A host allows only a few channels per SSH connection,
/// so a session holds a channel only while someone has a reason: a screen has
/// it open ([acquire]), or the repository asks for it ([want]: a request waits
/// for the person, it was active lately). The rest are shown from the host's
/// listing ([update]): [phase] and [unseenDone] come from what the keeper said
/// (`pending`, `turnActive`, `unseenDone`), never from a transcript that may be
/// stale. An unattached, healthy session reports [AgentLink.live].
///
/// Life of an attach:
/// - [connect] attaches to the keeper, runs `initialize`, then `session/load`
///   when the keeper already holds an ACP session (it replays the
///   conversation and re-issues the requests still waiting) or `session/new`
///   when it does not.
/// - When the transport ends while the session is wanted, [link] is
///   [AgentLink.reconnecting]. If the machine is offline nothing is tried: the
///   session waits for the machine (no timer, no `list`). Otherwise it asks the
///   host whether the keeper still runs and attaches again after 1, 2, 4, 8,
///   15, 30 s, each delay spread by +-20 %, at most [maxAttempts] times; then
///   [link] is [AgentLink.failed] and [reattach] ("Retry") tries again.
///   [state] keeps the old transcript (marked disconnected) until the replay
///   of the new attach is complete. When the keeper exited, [link] is
///   [AgentLink.ended] with the reason; a refusal that retrying cannot cure
///   ([AgentHostException.fatal], an agent error, a protocol the app does not
///   speak) is [AgentLink.failed].
/// - [onLifecycleState]: 90 s after the app goes to the background the
///   transport is detached (the keeper keeps the agent alive) and nothing runs
///   until the app is back, which attaches again what is wanted.
///
/// Nothing is ever allowed by default. A permission or a question completes
/// only through [answerPermission] / [answerQuestion]; every other way out
/// (a cancelled turn, a withdrawn request, a dropped link, [end], [dispose])
/// answers it as cancelled.
///
/// Listeners hear of a burst of updates once per flush (see `_changed`): once
/// per frame when the app injects a frame-aligned [FlushScheduler], once per
/// [notifyEvery] by default. Text that streams in does not replace the item
/// list: it grows in the live slot of [AgentSessionState] and the row that
/// shows it listens to [liveTextOf].
class AcpAgentSession extends ChangeNotifier implements AgentSessionView {
  AcpAgentSession({
    required this.machine,
    required this._host,
    required KeeperInfo info,
    this._reviewed,
    this._clock = DateTime.now,
    this._backoff = defaultBackoff,
    this._jitter = defaultRetryJitter,
    this.maxAttempts = 12,
    this.detachAfter = const Duration(seconds: 90),
    this.notifyEvery = const Duration(milliseconds: 16),
    this.backgroundNotifyEvery = const Duration(seconds: 2),
    FlushScheduler? flush,
    this._onDemand,
    this._cache,
  })  : _flush = flush ?? TimerFlush(notifyEvery),
        _info = info,
        _sessionId = (info.sessionId ?? '').isEmpty ? null : info.sessionId,
        _state = AgentSessionState(info.sessionId ?? '') {
    _phaseSince = _clock();
    _handler = _SessionHandler(this);
    if (info.state == KeeperState.exited) {
      _link = AgentLink.ended;
      _error = _exitReason(info);
    }
    _shownPhase = phase;
  }

  @override
  final MachineConnection machine;
  final AgentHost _host;
  final ReviewedState? _reviewed;
  final DateTime Function() _clock;
  final Duration Function(int attempt) _backoff;
  final double Function() _jitter;

  /// Retries per outage before the session gives up ([AgentLink.failed]).
  final int maxAttempts;

  /// How long the app may stay in the background before the transport is
  /// detached.
  final Duration detachAfter;

  /// Listeners are told of a burst of changes at most this often (the default
  /// scheduler's frame; with a frame-aligned [FlushScheduler] once per frame,
  /// and this is the pace of urgent changes while the app is away).
  final Duration notifyEvery;

  /// The same, in the background with the session kept alive, for text that
  /// streams in.
  final Duration backgroundNotifyEvery;

  /// Decides when [notifyListeners] runs after something changed (see
  /// `_changed`).
  final FlushScheduler _flush;

  /// Told when a screen takes or gives up its hold, so the repository can
  /// re-think which sessions to keep attached.
  final void Function()? _onDemand;

  late final _SessionHandler _handler;

  KeeperInfo _info;
  AgentSessionState _state;
  AgentLink _link = AgentLink.live;
  String? _error;
  late DateTime _phaseSince;
  late AgentPhase _shownPhase;

  /// When the running turn started, by [_clock]; null when none runs.
  DateTime? _turnStartedAt;

  /// When [send] was called, while it hands the prompt over.
  DateTime? _sentAt;
  String? _sessionId;

  AcpClient? _client;
  AcpTransport? _transport;
  StreamSubscription<SessionChange>? _changes;

  /// The attach finished its replay: [state] is the truth and updates flow.
  bool _ready = false;

  /// The attach in flight, valid while [_attachEpoch] is the current epoch.
  Future<void>? _attaching;
  int _attachEpoch = -1;

  /// Bumped whenever an attempt is superseded (a new attach, a drop, a
  /// detach, the end): everything in flight compares and walks away.
  int _epoch = 0;
  int _attempt = 0;

  /// The epoch of the drop being looked into (`list`, then a retry): a nudge
  /// from the repository must not start an attach in the middle of it.
  int _recoveringEpoch = -1;

  /// Screens showing this session ([acquire]).
  int _holds = 0;

  /// Fingers down on its row on the board ([warm]): a screen is likely to open.
  int _warms = 0;

  /// The repository's wish ([want]).
  bool _policyWants = false;

  /// The phase to keep showing after a drop, until the host is asked again.
  AgentPhase? _carried;

  /// Just after an attach the state is empty for a moment, before the keeper
  /// sends again what runs and what waits; for [_settle] the phase never falls
  /// below what was known before (the listing, or the phase at the drop).
  bool _settling = false;
  Timer? _settleTimer;

  /// The conversation is being replayed by `session/load`: turn ends seen now
  /// are history, not news.
  bool _replaying = false;

  /// The replay replaces a transcript that is already shown: show the old one
  /// until the new one is whole.
  bool _holding = false;

  /// The transcript cache; null keeps nothing between runs.
  final TranscriptCache? _cache;

  /// The newest window of `session/update` lines of this attach, for the cache.
  final _recorder = TranscriptRecorder();

  /// The recorder holds the whole log of the attach that is [_ready] (not the
  /// part that arrived before a drop): only then it is worth saving.
  bool _recordingWhole = false;

  /// What the recorder held when the cache was last asked to save.
  int _savedRevision = -1;

  /// The last ask was left to the cache's debounce.
  bool _savePending = false;

  /// When the transcript shown is a saved copy that the keeper has not
  /// confirmed yet: the time it was last known to be right. Null otherwise.
  DateTime? _cachedAsOf;

  /// The saved copy that is shown (until the first attach is whole): its lines
  /// are what a merge with the replay writes back to the cache.
  CachedTranscript? _cachedCopy;
  bool _cacheRequested = false;
  bool _detached = false;

  /// Another device took the keeper over; the session does not attach again
  /// until [reattach].
  bool _evicted = false;

  /// This session's keeper holds no ACP session yet and is to open one the
  /// agent stored ([openPast]): the attach loads (or resumes) it instead of
  /// creating a new one. Until the attach is whole.
  bool _reopening = false;

  /// The lines that built the transcript carried over from the session this
  /// one continues ([openPast]), standing in for the recorder's until the
  /// attach is whole.
  List<String>? _carriedLines;
  bool _disposed = false;
  DateTime? _backgroundedAt;
  bool _keepAlive = false;
  bool _graceElapsed = false;

  Timer? _detachTimer;
  Timer? _retryTimer;
  FlushCancel? _cancelFlush;
  bool _dirty = false;

  /// Waits for the machine to come back; set while no retry can be made.
  VoidCallback? _machineWatch;

  String? _doneKey;
  bool _unseen = false;
  String? _listSeenKey;

  // Keyed by the request object the client hands over: it is the very object
  // in the state's `PendingPermission.request`, so an answer finds its waiter
  // without a second id.
  final _permissions = Map<PermissionRequest, Completer<PermissionOutcome>>.identity();
  final _questions = Map<ElicitationRequest, Completer<ElicitationResponse>>.identity();

  /// What the person sent while the agent could not take it, in the order it
  /// goes out. Lives as long as this object: it survives a dropped link and a
  /// re-attach, never the app being killed (nothing is written to disk).
  final _queue = PromptQueue();

  /// Learned from the agent's `initialize` answer at the last attach.
  bool _canSteer = false;
  bool _acceptsImages = false;
  bool _acceptsEmbeddedContext = false;
  AuthNeeded? _authNeeded;

  // -- the view ---------------------------------------------------------------

  @override
  String get key => '${machine.profile.id}/${_info.id}';

  /// The keeper's id on its host.
  String get keeperId => _info.id;

  @override
  String get agent => _info.agent;

  @override
  String get agentLabel => agentRouteById(_info.agent)?.label ?? _info.agent;

  @override
  String get cwd => _info.cwd;

  @override
  String get title {
    for (final t in [_state.title, _info.title]) {
      final trimmed = t?.trim();
      if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    }
    return _folderName(_info.cwd, fallback: agentLabel);
  }

  @override
  AgentSessionState get state => _state;

  @override
  AgentLink get link => _link == AgentLink.live && _holds > 0 && !_ready ? AgentLink.connecting : _link;

  @override
  String? get error => _error;

  /// What [state] says while attached; otherwise what the host's listing said
  /// (a waiting request is shown as a permission: the listing does not say
  /// which kind), or what it was when the link dropped.
  @override
  AgentPhase get phase {
    if (_ready) {
      final fromState = _state.phase;
      if (!_settling) return fromState;
      final before = _listedPhase;
      return _urgency(before) > _urgency(fromState) ? before : fromState;
    }
    if (_link == AgentLink.ended || _link == AgentLink.failed) return AgentPhase.idle;
    return _listedPhase;
  }

  AgentPhase get _listedPhase {
    if (_carried case final carried?) return carried;
    if (_info.pending > 0) return AgentPhase.blockedOnPermission;
    return _info.turnActive ? AgentPhase.working : AgentPhase.idle;
  }

  static int _urgency(AgentPhase p) => switch (p) {
        AgentPhase.blockedOnPermission || AgentPhase.blockedOnQuestion => 2,
        AgentPhase.working => 1,
        AgentPhase.idle => 0,
      };

  @override
  DateTime get phaseSince => _phaseSince;

  @override
  DateTime? get turnStartedAt => _turnStartedAt;

  @override
  Listenable? liveTextOf(String messageKey) => _state.liveTextOf(messageKey);

  /// The keeper's most recent sign of life by the host's own clock (so
  /// comparable between sessions of one machine): for ranking which sessions
  /// deserve a channel.
  DateTime get activityAt => _info.lastEventAt ?? _info.startedAt;

  @override
  DateTime? get cachedAsOf => _cachedAsOf;

  @override
  bool get unseenDone => phase == AgentPhase.idle && (_unseen || _listedUnseen);

  // A turn that ended while no client was attached, as the host's listing
  // says, until the person looks.
  bool get _listedUnseen =>
      _info.unseenDone &&
      _listSeenKey != _listKey &&
      !(_reviewed?.isReviewed(machine.profile.id, _info.id, _listKey) ?? false);

  String get _listKey => 'l${_info.lastEventAt?.millisecondsSinceEpoch ?? 0}';

  @override
  void markSeen() {
    var changed = false;
    if (_unseen) {
      _unseen = false;
      _clearedDoneKey = _doneKey;
      if (_doneKey case final key?) _reviewed?.review(machine.profile.id, _info.id, key);
      changed = true;
    }
    if (_listedUnseen) {
      _listSeenKey = _clearedListKey = _listKey;
      _reviewed?.review(machine.profile.id, _info.id, _listKey);
      changed = true;
    }
    if (changed) _changed();
  }

  // What the last [markSeen] cleared, so [unmarkSeen] only restores that.
  String? _clearedDoneKey;
  String? _clearedListKey;

  @override
  bool unmarkSeen() {
    if (phase != AgentPhase.idle) return false;
    var changed = false;
    if (_clearedDoneKey case final key? when key == _doneKey && !_unseen) {
      _unseen = true;
      changed = true;
    }
    if (_clearedListKey case final key? when key == _listKey && _listSeenKey == key && _info.unseenDone) {
      _listSeenKey = null;
      changed = true;
    }
    if (!changed) return false;
    _clearedDoneKey = _clearedListKey = null;
    _reviewed?.unmark(machine.profile.id, _info.id);
    _changed();
    return true;
  }

  /// Holds a channel to the keeper right now (the replay is done).
  bool get attached => _ready;

  /// A screen holds this session open, or is about to ([warm]): it counts
  /// against the machine's channels like an open screen, but shows nothing
  /// (the session still reads as a healthy, unwatched one on the board).
  bool get held => _holds > 0 || _warms > 0;

  /// Holds a channel, or is attaching one.
  bool get holdsChannel => _ready || _client != null || _attachInFlight;

  /// The session could be attached: the keeper runs and nothing ended or
  /// failed it.
  bool get attachable => !_disposed && _link != AgentLink.ended && _link != AgentLink.failed;

  @override
  bool get isObserved => false;

  @override
  String? get terminalPaneId => null;

  @override
  bool get needsTerminal => false;

  @override
  List<SubagentEntry> get subagents => const [];

  // The runs the reducer made, with the transcripts read from omp's logs laid
  // over them (see [SubagentTranscripts]); the reducer's own state is the
  // client's and is replaced whenever the client publishes.
  @override
  List<SubagentRun> get subagentRuns => _logs?.overlay.runs(_state.subagents) ?? _state.subagents;

  @override
  SubagentSummary get subagentSummary => _state.subagentSummary;

  @override
  SubagentRun? subagentRun(String id) {
    final run = _state.subagentRun(id);
    return _logs?.overlay.run(run) ?? run;
  }

  @override
  List<SubagentRun> subagentsOfToolCall(String toolCallId) {
    final runs = _state.subagentsOfToolCall(toolCallId);
    final logs = _logs;
    return logs == null ? runs : [for (final r in runs) logs.overlay.run(r)!];
  }

  SubagentTranscripts? _logs;

  SubagentTranscripts get _transcripts => _logs ??= SubagentTranscripts(
    files: machine.files,
    sessionId: () => _sessionId,
    cwd: _info.cwd,
    runOf: (id) => _state.subagentRun(id),
    onChange: _changed,
    reachable: () => machine.isLive && _backgroundedAt == null,
  );

  @override
  void watchSubagentLog(String runId, bool on) {
    if (_disposed) return;
    if (on || _logs != null) _transcripts.watch(runId, on);
  }

  @override
  SubagentLogStatus subagentLogStatus(String runId) => _logs?.status(runId) ?? SubagentLogStatus.idle;

  @override
  void retrySubagentLog(String runId) => _logs?.retry(runId);

  BackgroundWork? _background;
  List<BackgroundTask>? _backgroundSource;

  /// What keeps running after the turn, per route:
  /// Codex and Claude Code over their async tasks, omp from its tool results.
  /// The same instance until the task list changes.
  @override
  BackgroundWork get backgroundWork {
    final tasks = _state.backgroundTasks;
    if (tasks.isEmpty) return BackgroundWork.empty;
    final cached = _background;
    if (cached != null && identical(_backgroundSource, tasks)) return cached;
    final codex = _info.agent == 'codex';
    _backgroundSource = tasks;
    return _background = BackgroundWork(
      tasks: [
        // Codex says `shell` for what is its background terminal.
        for (final t in tasks) codex && t.kind == BackgroundKind.shell ? t.copyWith(kind: BackgroundKind.terminal) : t,
      ],
      wakes: _info.agent == 'claude',
      wakeLabel: _info.agent == 'claude' ? 'Claude' : null,
    );
  }

  /// The turn is over, something runs in the background, and the link is up:
  /// [phase] stays idle (the composer sends), the bar says it waits. A task
  /// past its own deadline is not counted (the agent killed it and we were
  /// not told).
  @override
  bool get waitingOnBackground {
    if (!_ready || _link != AgentLink.live || _state.disconnected || _state.turnActive || phase != AgentPhase.idle) {
      return false;
    }
    final now = _clock();
    return backgroundWork.running.any((t) => !t.pastDeadline(now));
  }

  @override
  Future<BackgroundStopResult> stopBackground(String id) async {
    final task = backgroundWork.byId(id);
    if (task == null || !task.isActive) return const BackgroundAlreadyDone();
    return switch (task.stop) {
      StopRoute.none => const BackgroundNotStoppable(),
      StopRoute.direct => await _stopDirect(task.id),
      StopRoute.message => await _stopByMessage([task.id]),
    };
  }

  @override
  Future<BackgroundStopResult> stopAllBackground() async {
    final stoppable = backgroundWork.stoppable;
    if (stoppable.isEmpty) return const BackgroundNotStoppable();
    final results = <BackgroundStopResult>[
      for (final t in stoppable.where((t) => t.stop == StopRoute.direct)) await _stopDirect(t.id),
      if (stoppable.any((t) => t.stop == StopRoute.message))
        await _stopByMessage([for (final t in stoppable) if (t.stop == StopRoute.message) t.id]),
    ];
    final worked = results.whereType<BackgroundStopped>().toList();
    if (worked.isNotEmpty) return BackgroundStopped(asked: worked.any((r) => r.asked));
    for (final r in results) {
      if (r is BackgroundStopFailed) return r;
    }
    return results.any((r) => r is BackgroundAlreadyDone) ? const BackgroundAlreadyDone() : const BackgroundNotStoppable();
  }

  Future<BackgroundStopResult> _stopDirect(String taskId) async {
    final client = _client;
    final sid = _sessionId;
    if (client == null || sid == null || !_ready) return const BackgroundStopFailed('Not connected.');
    try {
      final stopped = await client.stopAsyncTask(sid, taskId);
      return stopped ? const BackgroundStopped() : const BackgroundAlreadyDone();
    } on Object catch (e) {
      return BackgroundStopFailed(_words(e));
    }
  }

  /// omp has no stop request: the agent is asked, in a message, to kill the jobs.
  Future<BackgroundStopResult> _stopByMessage(List<String> ids) async {
    final message = stopMessageForOmp(ids);
    if (message == null) return const BackgroundNotStoppable();
    await send(message);
    return const BackgroundStopped(asked: true);
  }

  @override
  void watchSubagents(bool on) {}

  @override
  String? get relayNote => null;

  @override
  List<String>? get liveOutput => null;

  @override
  String? get sendBlocked => null;

  @override
  List<QueuedMessage> get queued => _queue.entries;

  @override
  bool get canSteer => _canSteer;

  @override
  bool get acceptsImages => _acceptsImages;

  @override
  bool get acceptsEmbeddedContext => _acceptsEmbeddedContext;

  @override
  AuthNeeded? get authNeeded => _authNeeded;

  @override
  SendDelivery get delivery {
    if (_queue.hasWaiting) return SendDelivery.queued;
    if (!_ready) return _waitsForLink ? SendDelivery.queued : SendDelivery.now;
    if (phase != AgentPhase.idle) return _canSteer ? SendDelivery.steered : SendDelivery.queued;
    return SendDelivery.now;
  }

  /// The link is being made or re-made: a message waits for it.
  bool get _waitsForLink => _attachable && (link == AgentLink.reconnecting || link == AgentLink.connecting);

  // -- demand -----------------------------------------------------------------

  @override
  void acquire() {
    if (_disposed) return;
    _holds++;
    unawaited(_showCached());
    // The repository first makes room (lets other sessions go), then this one
    // attaches: the host's channel count does not overshoot on the way.
    _onDemand?.call();
    _wantChanged();
  }

  @override
  void release() {
    if (_disposed || _holds == 0) return;
    _holds--;
    if (_holds == 0) _saveCache(now: true);
    _onDemand?.call();
    _wantChanged();
  }

  /// The repository's decision about a session nobody holds: keep a channel
  /// ([attach]) or let it go. A held session keeps its channel whatever this
  /// says. Idempotent; also the nudge that attaches a wanted session once its
  /// machine is back.
  void want(bool attach) {
    _policyWants = attach;
    _wantChanged();
  }

  /// Reads the saved copy of the transcript without taking a channel (the
  /// board shows this session as needing the person).
  void preload() => unawaited(_showCached());

  /// A finger went down on this session's row: attaches now, and reads the
  /// saved copy, while the route is being pushed. Paired with [cool]; it takes
  /// a channel like a screen does but changes nothing the board shows.
  void warm() {
    if (_disposed) return;
    _warms++;
    unawaited(_showCached());
    _onDemand?.call();
    _wantChanged();
  }

  /// The finger left without opening (or the screen has taken its own hold).
  void cool() {
    if (_disposed || _warms == 0) return;
    _warms--;
    _onDemand?.call();
    _wantChanged();
  }

  bool get _wants => _holds > 0 || _warms > 0 || _policyWants;

  bool get _attachable => attachable && !_detached;

  bool get _attachInFlight => _attaching != null && _attachEpoch == _epoch;

  void _wantChanged() {
    if (_disposed) return;
    final retrying = _retryTimer != null || _machineWatch != null || _recoveringEpoch == _epoch;
    if (_wants) {
      if (_ready || _attachInFlight || !_attachable || !machine.isLive) return;
      // A person opening the session does not wait out a back-off; the
      // repository's nudge leaves a retry in progress alone.
      if (retrying && _holds == 0) return;
      unawaited(_attach());
    } else if (_ready || _client != null || _attachInFlight || retrying) {
      _unattach();
    }
  }

  /// Lets go of the channel: nobody needs it. The keeper and the agent live
  /// on; the board shows the session from the host's listing again.
  void _unattach() {
    _epoch++;
    _cancelRetry();
    _carried = _ready ? phase : null;
    _dropClient();
    if (_link == AgentLink.reconnecting || _link == AgentLink.connecting) _setLink(AgentLink.live);
    _markDisconnected();
  }

  // -- attaching --------------------------------------------------------------

  /// This session's keeper was just started and holds no ACP session: the
  /// first attach opens the one the agent stored as [sessionId] (`session/load`
  /// replays it; `session/resume` when the agent can only do that) instead of
  /// creating a new one. [continuing], the ended session this one carries on,
  /// lends its transcript: it is shown until the replay is whole and kept
  /// above a replay that does not reach so far back (and is all there is when
  /// the agent resumes without replaying). Call before the first attach.
  void openPast(String sessionId, {AcpAgentSession? continuing}) {
    if (_disposed || _ready || sessionId.isEmpty) return;
    _sessionId = sessionId;
    _reopening = true;
    final from = continuing;
    if (from == null || from._disposed || from._sessionId != sessionId || from._state.items.isEmpty) return;
    _state = from._state;
    _cachedAsOf = from._cachedAsOf ?? from._clock();
    _cachedCopy = from._cachedCopy;
    _carriedLines = !from._recorder.isEmpty
        ? from._recorder.lines
        : (from._cachedCopy == null ? null : cachedLines(from._cachedCopy!));
  }

  /// Attaches and creates or loads the ACP session, and keeps it wanted.
  /// Completes when this attempt is over, whatever [link] became; never
  /// throws. Joins an attach already in flight.
  Future<void> connect() {
    _policyWants = true;
    return _attach();
  }

  Future<void> _attach() {
    if (!_attachable || _ready) return Future<void>.value();
    if (_attaching case final running? when _attachEpoch == _epoch) return running;
    final attempt = _doAttach(); // bumps _epoch before its first await
    _attachEpoch = _epoch;
    late final Future<void> tracked;
    tracked = attempt.whenComplete(() {
      if (identical(_attaching, tracked)) _attaching = null;
    });
    return _attaching = tracked;
  }

  Future<void> _doAttach() async {
    final epoch = ++_epoch;
    _cancelRetry();
    _dropClient();
    try {
      final transport = await _host.attach(_info.id);
      if (epoch != _epoch) {
        unawaited(_quietClose(transport));
        return;
      }
      _transport = transport;
      AcpClient? created;
      final client = created = AcpClient(
        transport,
        handler: _handler,
        clock: _clock,
        onExtension: (method, params) {
          if (created case final c?) _onExtension(c, method, params);
        },
        onUpdateLine: (line) {
          if (epoch == _epoch) _recorder.add(line);
        },
        onSetup: (sid, result) {
          if (epoch == _epoch) _recorder.setup = result;
        },
        onLocalUser: (sid, blocks) {
          if (epoch == _epoch) _recorder.addLocalUser(sid, blocks);
        },
        onLocalUserTaken: (sid) {
          if (epoch == _epoch) _recorder.takeBackLocalUser();
        },
      );
      _client = client;
      _changes = client.changes.listen((c) => _onClientChange(client, c));
      unawaited(client.closed.then((_) => _onClosed(client)));
      // What is shown until the replay is whole is kept apart from it: the
      // replay may be shorter (the keeper's log is bounded), and a thread
      // never gets shorter because of a re-attach.
      _replaying = true;
      _holding = _state.items.isNotEmpty;
      final held = _holding ? _state : null;
      final heldLines = held == null
          ? const <String>[]
          : (_carriedLines ??
              (_recorder.isEmpty ? (_cachedCopy == null ? const <String>[] : cachedLines(_cachedCopy!)) : _recorder.lines));
      // The keeper sends the whole log again: what is kept for the cache
      // starts over with it.
      _recorder.reset();
      _recordingWhole = false;
      var older = 0;
      // `initialize` and the request that opens the session go out together:
      // the keeper answers the first from its cache and takes the second in
      // order, so the open waits for one round trip, not two (on a 300 ms link
      // that is 300 ms of every open).
      final initializing = client.initialize();
      final loading = _openSession(
        client,
        initializing,
        held == null
            ? null
            : (replayed) {
                final merged = replayed.withHeld(held);
                older = merged.older;
                return merged.state;
              },
      );
      // Whichever fails first is the failure; the other is not left unhandled.
      unawaited(loading.then<void>((_) {}, onError: (Object _) {}));
      unawaited(initializing.then<void>((_) {}, onError: (Object _) {}));
      final init = await initializing;
      if (epoch != _epoch) return;
      _canSteer = client.canSteer;
      _acceptsImages = init.capabilities.image;
      _acceptsEmbeddedContext = init.capabilities.embeddedContext;
      final loaded = await loading;
      if (epoch != _epoch) return;
      _sessionId = loaded.sessionId;
      _holding = false;
      _ready = true;
      _recordingWhole = true;
      _cachedAsOf = null;
      _cachedCopy = null;
      _reopening = false;
      _carriedLines = null;
      // Loading clears the keeper's own "unseen" for a turn that ended while
      // nobody was attached; on this phone it stays a review until the person
      // looks, so an Undo of that look still holds after the next listing.
      if (_listedUnseen && !_unseen) {
        _doneKey = _listKey;
        _unseen = true;
      }
      if (older > 0) _keepOlderLines(heldLines, loaded.sessionId, client.state(loaded.sessionId), older);
      _beginSettle();
      _setState(client.state(loaded.sessionId));
      _replaying = false;
      _attempt = 0;
      _evicted = false;
      _setAuth(null);
      _setLink(AgentLink.live);
    } on Object catch (e) {
      if (epoch != _epoch || _disposed) return;
      switch (e) {
        case JsonRpcException() when isAuthRequired(e):
          _fail(_failure(e, _client));
        case AgentHostException(fatal: true, :final message) ||
            AcpProtocolException(:final message) ||
            JsonRpcException(:final message):
          _fail(message);
        default:
          _dropped(_words(e));
      }
    }
  }

  /// What the attach does once the agent is initialized: creates the ACP
  /// session, or opens the one this session has. A past session
  /// ([openPast]) the agent cannot load is resumed without a replay when it
  /// can do that, else the person is told the agent cannot reopen it.
  Future<AgentSessionState> _openSession(
    AcpClient client,
    Future<AcpInitializeResult> init,
    AgentSessionState Function(AgentSessionState replayed)? merge,
  ) async {
    final sid = _sessionId;
    final meta = agentRouteById(_info.agent)?.sessionMeta;
    if (sid == null) return client.newSession(cwd: _info.cwd, meta: meta);
    Future<AgentSessionState> resumeOnly(AcpInitializeResult init) async {
      if (!init.capabilities.canResume) {
        throw AgentHostException('$agentLabel cannot reopen past sessions.', fatal: true);
      }
      return client.resumeSession(sid, cwd: _info.cwd, meta: meta, merge: merge);
    }

    // A past session is reopened by what the agent says it can do, so that one
    // waits for `initialize`. Every other open goes out behind it at once.
    if (_reopening) {
      final caps = await init;
      if (!caps.capabilities.loadSession) return resumeOnly(caps);
    }
    // The keeper tells every agent it can load; one that cannot answers
    // "method not found" to the first request for a session it does not hold.
    try {
      return await client.loadSession(sid, cwd: _info.cwd, meta: meta, merge: merge, pipelined: !_reopening);
    } on JsonRpcException catch (e) {
      if (_reopening && e.code == JsonRpcCode.methodNotFound) return resumeOnly(await init);
      rethrow;
    }
  }

  void _onClientChange(AcpClient client, SessionChange change) {
    if (!identical(client, _client) || _holding || _disposed) return;
    final sid = _sessionId;
    if (sid == null || change.sessionId != sid) return;
    // The client's latest, not this event's snapshot: the events arrive a
    // microtask late and an older one must not undo a newer publish.
    _setState(client.state(sid));
  }

  void _onClosed(AcpClient client) {
    if (!identical(client, _client) || _disposed) return;
    _dropped('Connection lost.');
  }

  /// The keeper's own notifications. Only the client this session holds now
  /// counts: the keeper also evicts the half-dead channel of this very session
  /// when its new one attaches, and that must not end anything.
  void _onExtension(AcpClient client, String method, Object? params) {
    if (!identical(client, _client) || _disposed) return;
    final p = params is Map ? params : const {};
    switch (method) {
      case '_herdr/evicted':
        _evicted = true;
        _stop(AgentLink.ended, 'Opened on another device.');
      case '_herdr/agent_exited':
        final reason = p['reason'];
        final code = p['exitCode'];
        _ended(
          reason is String && reason.trim().isNotEmpty
              ? reason.trim()
              : switch (code) {
                  null || 0 => '$agentLabel exited.',
                  final c => '$agentLabel exited with code $c.',
                },
        );
    }
  }

  @override
  bool get evicted => _evicted && _link == AgentLink.ended;

  /// The ACP session id the agent knows this conversation by; null until the
  /// keeper has one.
  String? get sessionId => _sessionId;

  @override
  ResumeTarget? get resumeTarget {
    final sid = _sessionId;
    if (_link != AgentLink.ended || _evicted || sid == null || agentRouteById(_info.agent) == null) return null;
    return ResumeTarget(agent: _info.agent, cwd: _info.cwd, sessionId: sid);
  }

  @override
  Future<void> reattach() async {
    if (_disposed || _detached || _link == AgentLink.live) return;
    // An agent that exited cannot be taken over; a session another device took
    // and one that failed to attach can.
    if (_link == AgentLink.ended && !_evicted) return;
    _attempt = 0;
    _evicted = false;
    _link = AgentLink.reconnecting;
    _error = 'Taking the session back.';
    _changed();
    await _attach();
  }

  /// The link broke while the session was meant to run: show it, find out
  /// whether the keeper still lives, and attach again.
  void _dropped(String why) {
    if (_disposed) return;
    final epoch = ++_epoch;
    if (_ready) _carried = phase;
    _dropClient();
    _markDisconnected();
    _setLink(AgentLink.reconnecting, error: why);
    if (_detached || !_wants) return;
    _recoveringEpoch = epoch;
    unawaited(_afterDrop(epoch));
  }

  /// With [attachNow] the keeper is attached again as soon as it is found to
  /// run (the machine just came back); otherwise after the next back-off.
  Future<void> _afterDrop(int epoch, {bool attachNow = false}) async {
    // Nothing can be asked of a machine that is not there: wait for it, no
    // timer and no questions meanwhile.
    if (!machine.isLive) {
      _waitForMachine(epoch);
      return;
    }
    try {
      final keepers = await _host.list();
      if (epoch != _epoch) return;
      KeeperInfo? mine;
      for (final k in keepers) {
        if (k.id == _info.id) mine = k;
      }
      if (mine == null) {
        _ended('The session is gone from ${machine.profile.label}.');
        return;
      }
      _info = mine;
      _carried = null;
      _syncPhase();
      if (mine.state == KeeperState.exited) {
        _ended(_exitReason(mine));
        return;
      }
      if (attachNow) {
        unawaited(_attach());
        return;
      }
    } on Exception {
      // The host cannot be asked either: the keeper's fate is unknown, so try
      // again.
      if (epoch != _epoch) return;
    }
    _scheduleRetry(epoch);
  }

  void _scheduleRetry(int epoch) {
    if (_disposed || _detached || epoch != _epoch) return;
    if (_attempt >= maxAttempts) {
      _fail(
        'Could not reach the session on ${machine.profile.label} after $maxAttempts tries. '
        'The agent keeps running there.',
      );
      return;
    }
    _cancelRetry();
    _retryTimer = Timer(_spread(_backoff(_attempt++)), () {
      _retryTimer = null;
      if (epoch != _epoch) return;
      if (machine.isLive) {
        unawaited(_attach());
      } else {
        _waitForMachine(epoch);
      }
    });
  }

  /// Waits, without a timer, until the machine is online again; then tries
  /// once more after a spread-out pause, with a fresh count of attempts (an
  /// outage of the machine is not the session's failure).
  void _waitForMachine(int epoch) {
    _cancelRetry();
    void check() {
      if (_disposed || epoch != _epoch) {
        _cancelRetry();
        return;
      }
      if (!machine.isLive) return;
      _cancelRetry();
      _attempt = 0;
      _retryTimer = Timer(_spread(_backoff(0)), () {
        _retryTimer = null;
        if (epoch == _epoch) unawaited(_afterDrop(epoch, attachNow: true));
      });
    }

    try {
      machine.addListener(check);
    } on Object {
      // The machine's connection is gone for good; the repository drops this
      // session with it.
      return;
    }
    _machineWatch = check;
  }

  Duration _spread(Duration d) => Duration(microseconds: (d.inMicroseconds * _jitter()).round());

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (_machineWatch case final watch?) {
      machine.removeListener(watch);
      _machineWatch = null;
    }
  }

  /// Cannot attach and will not try again by itself.
  void _fail(String why) {
    _epoch++;
    _cancelRetry();
    _carried = null;
    _dropClient();
    _markDisconnected();
    _setLink(AgentLink.failed, error: why);
  }

  /// The agent process is gone (or the person ended it). The saved copy stays:
  /// it is what an ended session shows (read-only, and after a restart too)
  /// until the host forgets the keeper, and it is how the thread is carried on
  /// ([resumeTarget]).
  void _ended(String why) {
    _saveCache(now: true);
    _stop(AgentLink.ended, why);
  }

  /// Stops for good (until [reattach]) with [link] and [why].
  void _stop(AgentLink link, String why) {
    _epoch++;
    _cancelRetry();
    _carried = null;
    _dropClient();
    _markDisconnected();
    _setLink(link, error: why);
  }

  void _markDisconnected() {
    _replaying = false;
    if (!_state.disconnected) _setState(_state.withDisconnected());
  }

  /// Forgets the client and hangs up its transport; the keeper (and the agent)
  /// live on. Whatever waits for an answer is cancelled.
  void _dropClient() {
    final client = _client;
    final transport = _transport;
    _client = null;
    _transport = null;
    _ready = false;
    _holding = false;
    unawaited(_changes?.cancel());
    _changes = null;
    _cancelWaiting();
    _settleTimer?.cancel();
    _settleTimer = null;
    _settling = false;
    // Hang up now: the channel is a scarce slot on the host, and the client's
    // own close only reaches the transport after its reader has stopped.
    if (transport != null) unawaited(_quietClose(transport));
    if (client != null) unawaited(client.close().catchError((Object _) {}));
  }

  static Future<void> _quietClose(AcpTransport transport) async {
    try {
      await transport.close();
    } on Object {
      // Already gone.
    }
  }

  // -- the saved copy ---------------------------------------------------------

  /// Shows the transcript the cache kept of this session while the keeper is
  /// still being reached (and a restart has emptied [state]): the stored lines
  /// go through the reducer a replay goes through, into a state that is shown
  /// at once and held (see [_holding]) until the real replay is whole and
  /// replaces it. Nothing in it can be answered: requests come from the
  /// keeper, with a live attach. Dropped when the real thing got here first.
  /// An ended session shows its copy the same way and keeps it (nothing will
  /// replace it): [cachedAsOf] says when it was saved.
  Future<void> _showCached() async {
    final cache = _cache;
    final sid = _sessionId;
    if (cache == null || _cacheRequested || _disposed || sid == null) return;
    if (_state.items.isNotEmpty || _ready || _replaying) return;
    _cacheRequested = true;
    final CachedTranscript? cached;
    try {
      cached = await cache.read(key);
    } on Object {
      return;
    }
    if (cached == null || cached.sessionId != _sessionId) return;
    if (_disposed || _ready || _replaying || _state.items.isNotEmpty) return;
    final state = replayCachedTranscript(cached);
    if (state.items.isEmpty) return;
    _cachedAsOf = cached.asOf;
    _cachedCopy = cached;
    _setState(state);
  }

  /// [older] items of [merged] came from the transcript shown before the
  /// replay (see `AgentSessionState.withHeld`): the lines that built them go in
  /// front of the recorder's, so the saved copy does not get shorter either. A
  /// copy whose lines do not give those items is left as the replay wrote it.
  void _keepOlderLines(List<String> heldLines, String sid, AgentSessionState merged, int older) {
    final offset = merged.items.isNotEmpty && merged.items.first.key == hostDroppedKey ? 1 : 0;
    final lines = linesBefore(heldLines, sid, merged.items.skip(offset).take(older).toList());
    if (lines != null) _recorder.prepend(lines);
  }

  /// Asks the cache to keep what this attach has seen: when a turn ends (after
  /// the cache's debounce), and at once when the screen lets go or the app
  /// leaves. Nothing when nothing changed since the last ask, and nothing
  /// before the attach's replay was whole.
  void _saveCache({bool now = false}) {
    final cache = _cache;
    final sid = _sessionId;
    if (cache == null || _disposed || sid == null || !_recordingWhole || _recorder.isEmpty) return;
    // A change not saved yet, or a save still waiting out its debounce that
    // this one is asked to hurry.
    if (_recorder.revision == _savedRevision && !(now && _savePending)) return;
    _savedRevision = _recorder.revision;
    _savePending = !now;
    cache.save(
      key,
      TranscriptSnapshot(
        sessionId: sid,
        asOf: _clock(),
        lines: _recorder.lines,
        setup: _recorder.setup,
        partial: _recorder.partial,
      ),
      now: now,
    );
  }

  // -- lifecycle --------------------------------------------------------------

  /// Feeds app lifecycle transitions: `hidden`/`paused` start the clock to
  /// [detachAfter], `resumed` stops it and attaches again what is wanted.
  void onLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        background();
      case AppLifecycleState.resumed:
        foreground();
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  /// The app went to the background at [since] (now by default). A repeat
  /// does not restart the clock.
  void background({DateTime? since}) {
    if (_disposed || _backgroundedAt != null) return;
    _saveCache(now: true);
    final at = _backgroundedAt = since ?? _clock();
    _graceElapsed = false;
    final left = detachAfter - _clock().difference(at);
    if (left <= Duration.zero) {
      _graceEnded();
    } else {
      _detachTimer = Timer(left, _graceEnded);
    }
  }

  /// Stay attached in the background, instead of detaching [detachAfter] after
  /// the app left (the repository turns it on while the person has asked to be
  /// told about agents that need them). Turned off, the usual rule applies
  /// again: at the end of the grace period, or at once if that has passed.
  set keepAliveInBackground(bool value) {
    if (_keepAlive == value) return;
    _keepAlive = value;
    if (!value && _backgroundedAt != null && _graceElapsed) _detach();
    _flushNow();
  }

  void _graceEnded() {
    _detachTimer = null;
    _graceElapsed = true;
    if (!_keepAlive) _detach();
  }

  void foreground() {
    if (_backgroundedAt == null) return;
    _backgroundedAt = null;
    _graceElapsed = false;
    _detachTimer?.cancel();
    _detachTimer = null;
    _flushNow();
    if (!_detached) return;
    _detached = false;
    _attempt = 0;
    if (_disposed || _link == AgentLink.ended || _link == AgentLink.failed) return;
    if (_wants) {
      _wantChanged();
    } else if (_link == AgentLink.reconnecting) {
      _setLink(AgentLink.live);
    }
  }

  void _detach() {
    _detachTimer = null;
    if (_disposed || _detached) return;
    _detached = true;
    final active = _client != null || _attachInFlight || _link == AgentLink.reconnecting || _holds > 0;
    _epoch++;
    _cancelRetry();
    if (_link == AgentLink.ended || _link == AgentLink.failed) return;
    _carried = null;
    _dropClient();
    if (active) {
      _markDisconnected();
      _setLink(AgentLink.reconnecting, error: 'Paused while the app is in the background.');
    }
  }

  // -- what the person does ---------------------------------------------------

  @override
  Future<bool> send(String text) => sendBlocks([TextBlock(text)]);

  @override
  Future<bool> sendBlocks(List<ContentBlock> blocks, {bool queue = false}) async {
    if (blocks.isEmpty) return false;
    final client = _client;
    final sid = _sessionId;
    if (client == null || sid == null || !_ready) {
      if (_waitsForLink) {
        // The link is coming back: the message waits for it and goes out when
        // the agent is known to be idle.
        _queue.add(blocks, at: _clock());
        _changed();
        return true;
      }
      _setProblem('Not connected. The message was not sent.');
      return false;
    }
    markSeen();
    _setProblem(null);
    _setAuth(null);
    if (_queue.hasWaiting) {
      // Behind what already waits: the order the person sent them in.
      _queue.add(blocks, at: _clock());
      _changed();
      _pump();
      return true;
    }
    if (phase != AgentPhase.idle || client.state(sid).turnActive) {
      if (queue || !_canSteer) {
        _queue.add(blocks, at: _clock());
        _changed();
        return true;
      }
      return _steer(client, sid, blocks);
    }
    return _promptNow(client, sid, blocks);
  }

  @override
  void editQueued(String id, String text) {
    if (_queue.edit(id, text)) _changed();
  }

  @override
  void removeQueued(String id) {
    if (_queue.remove(id)) _changed();
  }

  @override
  void resumeQueue() {
    if (!_queue.release()) return;
    _changed();
    _pump();
  }

  /// Hands [blocks] to the agent as a prompt of its own. [fromQueue] is the
  /// queue entry these blocks came from: it leaves the queue once the turn has
  /// started, and is held (with the reason) when the prompt could not even
  /// start. Completes with whether the message was kept (see
  /// [AgentSessionView.sendBlocks]): true at once when the turn has started,
  /// else, when the prompt has failed, true if it waits held. The turn itself
  /// is not waited for.
  Future<bool> _promptNow(AcpClient client, String sid, List<ContentBlock> blocks, {String? fromQueue}) {
    final before = client.state(sid);
    var started = false;
    var kept = false;
    _sentAt = _clock();
    final turn = _guard(client, () async {
      try {
        final result = await client.prompt(sid, blocks);
        kept = true;
        if (_disposed || !identical(client, _client)) return null;
        if (result.stopReason == StopReason.endTurn && !_answered(before, client.state(sid))) {
          _setProblem(_silentTurn);
        }
        return null;
      } on AcpSessionBusyException {
        if (_disposed || !identical(client, _client)) return null;
        // Nothing was taken and nothing shows (the client took the row back):
        // the message waits, held.
        _queue.add(blocks, at: _clock(), state: QueuedState.held, heldReason: _busyReason, first: true);
        kept = true;
        _setState(client.state(sid));
        _changed();
        return null;
      } on Object catch (e) {
        if (!started && !_disposed && identical(client, _client)) {
          // It never started (the agent takes no pictures, say): the text is
          // not lost, it waits held for the person to edit or drop.
          final why = _failure(e, client);
          if (fromQueue != null) {
            _queue.hold(fromQueue, why);
          } else {
            _queue.add(blocks, at: _clock(), state: QueuedState.held, heldReason: why);
          }
          kept = true;
          _changed();
        }
        rethrow;
      }
    });
    // The client's `prompt` has run up to its first await: the local row and
    // the running turn are in its state already. Take them now, so the next
    // flush (the next frame) shows the row and `working`, instead of waiting
    // for the client's change event to arrive a microtask later.
    _setState(client.state(sid));
    _sentAt = null;
    started = client.state(sid).turnActive && !before.turnActive;
    if (fromQueue != null && started && _queue.remove(fromQueue)) _changed();
    // A started turn has the message: the person is not kept waiting for the
    // turn to end to learn it went.
    if (started) return Future.value(true);
    return turn.then((_) => kept);
  }

  static const _busyReason = 'The agent is busy with its own work. Resume to send it when it is free.';

  /// Sends [blocks] into the running turn (`_session/steering`). True when the
  /// agent took it or it waits in the queue (held included), false when it
  /// was lost on the way (the reason in [error], or the link's own).
  Future<bool> _steer(AcpClient client, String sid, List<ContentBlock> blocks) async {
    bool current() => !_disposed && identical(client, _client);
    try {
      final outcome = await client.steer(sid, blocks);
      final took = outcome == SteerOutcome.injected || outcome == SteerOutcome.startedNewTurn;
      // The link was re-made meanwhile: only what the agent took is kept.
      if (!current()) return took;
      switch (outcome) {
        case SteerOutcome.injected || SteerOutcome.startedNewTurn:
          // The client put the row into its state.
          _setState(client.state(sid));
        case SteerOutcome.promptRequired || SteerOutcome.failed:
          // The turn ended while the message was on its way (its own end is
          // about to arrive), or the agent could not apply it: it goes out as
          // a prompt as soon as the turn is over, which may be now.
          _queue.add(blocks, at: _clock());
          _changed();
          _pump();
      }
      return true;
    } on JsonRpcException catch (e) {
      if (!current()) return false;
      _holdRefused(blocks, _failure(e, client));
      return true;
    } on AcpProtocolException catch (e) {
      if (!current()) return false;
      _holdRefused(blocks, e.message);
      return true;
    } on Object catch (e) {
      if (!current()) return false;
      // A dropped link is already said by [link].
      if (e is JsonRpcClosedException && !_ready) return false;
      _setProblem(_words(e));
      return false;
    }
  }

  /// A message the agent refused: it waits held, with the reason, for the
  /// person to edit or drop it; the reason is also the session's [error].
  void _holdRefused(List<ContentBlock> blocks, String why) {
    _queue.add(blocks, at: _clock(), state: QueuedState.held, heldReason: why);
    _setProblem(why);
    _changed();
  }

  /// Sends the next queued message when the agent is idle and nothing else is
  /// going on. Never while a turn runs, a request waits, or an attach is
  /// settling (the keeper has not yet said whether a turn is running), so two
  /// prompts are never in flight.
  void _pump() {
    if (!_canDispatch) return;
    final next = _queue.firstWaiting;
    if (next == null) return;
    unawaited(_promptNow(_client!, _sessionId!, next.blocks, fromQueue: next.id));
  }

  bool get _canDispatch =>
      !_disposed &&
      _ready &&
      !_settling &&
      !_replaying &&
      !_holding &&
      _client != null &&
      _sessionId != null &&
      !_state.disconnected &&
      _state.phase == AgentPhase.idle;

  static const _silentTurn = 'The agent ended the turn without an answer. '
      'If this keeps happening, its login on the host may have expired.';

  /// Whether the agent did anything visible since [before]: a message or a
  /// thought of its own, a tool call, a plan. The user's own message (local or
  /// echoed) does not count. Some adapters end a turn with `end_turn` and no
  /// word when the model call failed (an expired login).
  static bool _answered(AgentSessionState before, AgentSessionState after) {
    for (final item in after.items.skip(before.items.length)) {
      switch (item) {
        case TranscriptTool():
          return true;
        case TranscriptMessage(:final role) when role != MessageRole.user:
          return true;
        case TranscriptMessage():
          break;
        case TranscriptStop():
          break;
        case TranscriptNote():
          break;
      }
    }
    return !identical(before.plan, after.plan) && after.plan.isNotEmpty;
  }

  @override
  void cancel() {
    // What waits stays, held: the person decides whether it still makes sense.
    if (_queue.holdAll('Held because you stopped the turn. Resume to send it.')) _changed();
    final client = _client;
    final sid = _sessionId;
    if (client == null || sid == null) return;
    client.cancel(sid);
  }

  @override
  Future<void> setMode(String modeId) => _call((c, sid) => c.setMode(sid, modeId));

  @override
  Future<void> setConfigOption(String configId, Object value) =>
      _call((c, sid) => c.setConfigOption(sid, configId, value));

  Future<void> _call(Future<void> Function(AcpClient client, String sid) f) async {
    final client = _client;
    final sid = _sessionId;
    if (client == null || sid == null || !_ready) {
      _setProblem('Not connected.');
      return;
    }
    await _guard(client, () => f(client, sid));
  }

  /// Runs [f], which talks to [client], and turns any failure into [error].
  Future<void> _guard(AcpClient client, Future<Object?> Function() f) async {
    try {
      await f();
    } on Object catch (e) {
      if (_disposed || !identical(client, _client)) return;
      // A dropped link is already said by [link].
      if (e is JsonRpcClosedException && !_ready) return;
      _setProblem(_failure(e, client));
    }
  }

  /// [e] in words for the person. An agent that wants a login also sets
  /// [authNeeded].
  String _failure(Object e, AcpClient? client) {
    if (e is JsonRpcException && isAuthRequired(e)) {
      final need = authNeededFrom(e, agentLabel: agentLabel, advertised: client?.agent?.raw['authMethods']);
      _setAuth(need);
      return need.message;
    }
    return _words(e);
  }

  void _setAuth(AuthNeeded? need) {
    if (identical(_authNeeded, need)) return;
    _authNeeded = need;
    _changed();
  }

  @override
  void answerPermission(Object requestId, PermissionOutcome outcome) {
    // Never from a saved copy: only the keeper's live attach confirms that a
    // request still waits.
    if (_cachedAsOf != null) return;
    final pending = _pendingById(requestId);
    if (pending is! PendingPermission) return;
    final waiter = _permissions.remove(pending.request);
    if (waiter != null && !waiter.isCompleted) waiter.complete(outcome);
  }

  @override
  void answerQuestion(Object requestId, ElicitationResponse response) {
    if (_cachedAsOf != null) return;
    final pending = _pendingById(requestId);
    if (pending is! PendingQuestion) return;
    final waiter = _questions.remove(pending.request);
    if (waiter != null && !waiter.isCompleted) waiter.complete(response);
  }

  // The client's own state is the authority on what is waiting.
  PendingRequest? _pendingById(Object requestId) {
    final sid = _sessionId;
    return sid == null ? null : _client?.state(sid).pendingById(requestId);
  }

  @override
  Future<void> end() async {
    if (_link == AgentLink.ended) return;
    try {
      await _host.kill(_info.id);
    } on AgentHostException {
      rethrow;
    } on Exception catch (e) {
      throw AgentHostException('Could not end the session: ${_words(e)}');
    }
    if (_disposed) return;
    _ended('Ended from this phone.');
  }

  /// A fresher listing of the keeper (title, phase, exit). An exit ends the
  /// session.
  void update(KeeperInfo next) {
    if (_disposed) return;
    final before = _info;
    _info = next;
    _carried = null;
    if (_sessionId == null && (next.sessionId ?? '').isNotEmpty) _sessionId = next.sessionId;
    if (next.state == KeeperState.exited && _link != AgentLink.ended) {
      _ended(_exitReason(next));
      return;
    }
    _syncPhase();
    if (before.title != next.title ||
        before.pending != next.pending ||
        before.turnActive != next.turnActive ||
        before.unseenDone != next.unseenDone) {
      _changed();
    }
  }

  // -- requests from the agent ------------------------------------------------

  Future<PermissionOutcome> _requestPermission(PermissionRequest request, Future<void> cancelled) {
    final waiter = Completer<PermissionOutcome>();
    _permissions[request] = waiter;
    unawaited(cancelled.then((_) {
      _permissions.remove(request);
      if (!waiter.isCompleted) waiter.complete(const PermissionCancelled());
    }));
    return waiter.future;
  }

  Future<ElicitationResponse> _elicit(ElicitationRequest request, Future<void> cancelled) {
    // A question outside any session cannot be shown anywhere.
    if (request.sessionId == null) return Future.value(const ElicitationCancel());
    final waiter = Completer<ElicitationResponse>();
    _questions[request] = waiter;
    unawaited(cancelled.then((_) {
      _questions.remove(request);
      if (!waiter.isCompleted) waiter.complete(const ElicitationCancel());
    }));
    return waiter.future;
  }

  void _cancelWaiting() {
    for (final waiter in _permissions.values.toList()) {
      if (!waiter.isCompleted) waiter.complete(const PermissionCancelled());
    }
    _permissions.clear();
    for (final waiter in _questions.values.toList()) {
      if (!waiter.isCompleted) waiter.complete(const ElicitationCancel());
    }
    _questions.clear();
  }

  // -- state ------------------------------------------------------------------

  void _setState(AgentSessionState next) {
    final prev = _state;
    if (identical(prev, next)) return;
    _state = next;
    final before = _shownPhase;
    _syncPhase();
    if (!next.turnActive) {
      _turnStartedAt = null;
    } else {
      _turnStartedAt ??= _sentAt ?? _clock();
    }
    final finished = prev.turnActive && !next.turnActive || prev.lastStopReason == null && next.lastStopReason != null;
    if (finished && !next.turnActive && !next.disconnected && !_replaying) {
      _turnEnded(next.lastStopReason);
      // A stopped or failed turn is not the end of a conversation to carry on
      // with whatever was queued behind it: the person decides.
      final held = switch (next.lastStopReason) {
        StopReason.cancelled => 'Held because the turn was stopped. Resume to send it.',
        StopReason.error => 'Held because the turn failed. Resume to send it.',
        _ => null,
      };
      if (held != null) _queue.holdAll(held);
    }
    final requests = prev.pending.length != next.pending.length ||
        (next.pending.isNotEmpty && prev.pending.first.id != next.pending.first.id);
    _changed(urgent: _shownPhase != before || requests || finished || prev.disconnected != next.disconnected);
    _pump();
  }

  /// [phaseSince] follows the phase that is shown, whatever it comes from (by
  /// this phone's clock: "since this app saw it").
  void _syncPhase() {
    final now = phase;
    if (now == _shownPhase) return;
    _shownPhase = now;
    _phaseSince = _clock();
  }

  void _beginSettle() {
    _settling = true;
    _settleTimer?.cancel();
    _settleTimer = Timer(_settle, () {
      _settleTimer = null;
      _settling = false;
      _carried = null;
      _syncPhase();
      _changed();
      _pump();
    });
  }

  static const _settle = Duration(seconds: 1);

  /// A turn this app watched finished: it is news until the person looks. A
  /// cancelled turn was the person's own doing and an error is not a result.
  void _turnEnded(StopReason? reason) {
    _saveCache();
    if (reason == null || reason == StopReason.cancelled || reason == StopReason.error) return;
    final key = _doneKey = '${_clock().microsecondsSinceEpoch}';
    _unseen = !(_reviewed?.isReviewed(machine.profile.id, _info.id, key) ?? false);
  }

  void _setLink(AgentLink link, {String? error}) {
    if (_link == link && _error == error) return;
    _link = link;
    _error = error;
    _syncPhase();
    _changed();
  }

  void _setProblem(String? problem) {
    if (_error == problem) return;
    _error = problem;
    _changed();
  }

  /// Notifies once per flush however many changes came; the [FlushScheduler]
  /// says when: at the start of the next frame, before build (`FrameFlush`), or
  /// after [notifyEvery] (`TimerFlush`, the default). In the background with
  /// the session kept alive ([keepAliveInBackground]) frames do not run: the
  /// text that streams in notifies at most once per [backgroundNotifyEvery]
  /// (nobody is looking), and a change that is [urgent] (phase, request, link,
  /// title, a finished turn) still goes out within [notifyEvery].
  ///
  /// An urgent change is never held back by a slower flush that was already
  /// waiting, and is carried by the very next flush: the same frame as the
  /// chunks that came with it. Not every change is urgent; a chunk is not.
  void _changed({bool urgent = true}) {
    if (_disposed) return;
    _dirty = true;
    final slow = _quiet && !urgent;
    if (_cancelFlush != null && (slow || !_flushSlow)) return;
    _cancelFlush?.call();
    _flushSlow = slow;
    _cancelFlush = slow
        ? _flush.after(backgroundNotifyEvery, _flushDue)
        : _quiet
            ? _flush.after(notifyEvery, _flushDue)
            : _flush.nextFrame(_flushDue);
  }

  /// The flush: the text that grew in place is announced to its row, then the
  /// session's listeners are told.
  void _flushDue() {
    _cancelFlush = null;
    if (_disposed || !_dirty) return;
    _dirty = false;
    _state.liveMessage?.live?.flush();
    _state.flushSubagentLive();
    notifyListeners();
  }

  /// The app is away and this session is kept attached for watching.
  bool get _quiet => _keepAlive && _backgroundedAt != null;

  /// What waits in [_cancelFlush] is the slow one.
  bool _flushSlow = false;

  /// Back in front, or no longer kept: whatever waits is told now.
  void _flushNow() {
    if (_cancelFlush != null && _flushSlow) _changed();
  }

  String _exitReason(KeeperInfo k) {
    final said = k.exitReason?.trim();
    if (said != null && said.isNotEmpty) return said;
    return switch (k.exitCode) {
      null || 0 => '$agentLabel exited.',
      final code => '$agentLabel exited with code $code.',
    };
  }

  static String _words(Object e) => switch (e) {
        AcpProtocolException(:final message) => message,
        JsonRpcException(:final message) when message.toLowerCase().contains('does not support image') =>
          '$message. Send it without the picture, or pick another model.',
        JsonRpcException(:final message) => message,
        AgentHostException(:final message) => message,
        JsonRpcClosedException() => 'The connection dropped.',
        TimeoutException() => 'The agent did not answer in time.',
        _ => '$e',
      };

  static String _folderName(String cwd, {required String fallback}) {
    var v = cwd.trim();
    while (v.length > 1 && v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    if (v.isEmpty) return fallback;
    if (v == '/') return '/';
    return v.substring(v.lastIndexOf('/') + 1);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    _detachTimer?.cancel();
    _cancelRetry();
    _cancelFlush?.call();
    _logs?.dispose();
    _dropClient();
    super.dispose();
  }
}

/// The part of [AcpClientHandler] the session keeps to itself.
class _SessionHandler implements AcpClientHandler {
  _SessionHandler(this._session);

  final AcpAgentSession _session;

  @override
  Future<PermissionOutcome> requestPermission(PermissionRequest request, Future<void> cancelled) =>
      _session._requestPermission(request, cancelled);

  @override
  Future<ElicitationResponse> elicit(ElicitationRequest request, Future<void> cancelled) =>
      _session._elicit(request, cancelled);
}
