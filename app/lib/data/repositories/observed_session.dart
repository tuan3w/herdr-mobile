import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';

import '../acp/acp_models.dart';
import '../acp/agent_host.dart' show AgentHostException;
import '../acp/auth_needed.dart';
import '../acp/past_session.dart' show ResumeTarget;
import '../acp/prompt_queue.dart';
import '../acp/background/background_work.dart';
import '../acp/session_state.dart';
import '../acp/subagents/subagent_run.dart' show SubagentLogStatus, SubagentRun, SubagentSummary;
import '../models/herdr_models.dart';
import '../models/pane_preview.dart';
import '../observed/background_view.dart';
import '../observed/observed_contracts.dart';
import '../observed/omp_ask_driver.dart';
import '../services/herdr_transport.dart' show HerdrApiException, HerdrTransportException;
import 'acp_agent_session.dart' show defaultRetryJitter;
import 'agent_session.dart';
import 'machine_connection.dart';
import 'observed_requests.dart';
import 'pane_previews.dart';
import 'prompt_detector.dart';

/// Opens the stream of an agent's session log on a machine.
typedef LogSourceFor = SessionLogSource Function(MachineConnection machine);

/// Reads the pane's screen and says what to send next to answer a dialog.
typedef AskStepper = AskStep Function(String screen);

/// The omp driver, one per answer (it remembers checkboxes that scrolled out
/// of view).
AskStepper ompAskStepper(PendingAsk ask, List<AskAnswer> answers) => OmpAskDriver(ask, answers).next;

/// An agent that runs in a herdr pane, as an [AgentSessionView]: the chat
/// screen reads it like an ACP session.
///
/// **Eyes: the log.** The agent appends every message to its session log; a
/// [SessionLogSource] follows the file over the machine's SSH connection while
/// a screen holds the session ([acquire]), the [SessionLogMapper] turns each
/// line into the updates the chat reducer understands. The first batch (the
/// file's tail) is applied in small slices with a yield between them, so the
/// screen never waits on it; after a drop the follow resumes from the byte
/// offset it had reached. Retries run only while the machine is live, with
/// the back-off of an ACP session.
///
/// **Hand: the pane.** A message is `pane.send_input` (the composer path of
/// the terminal screen), Stop is `esc`, an answer to the agent's question is a
/// plan of keys sent step by step with the pane re-read in between, and an
/// approval is the keys of the reply the existing prompt detector found on the
/// screen. Nothing is assumed: an answer counts when the log shows it.
///
/// **Truth: the pane and the log, every time.** [phase], [unseenDone] and the
/// pending request are derived from herdr's status of the pane, the log's open
/// question and the pane's prompt whenever either changes; a request is never
/// kept after the pane stopped waiting for it.
///
/// **Background work.** The log lists what runs after the turn (shell jobs,
/// subagents) and whether the turn is over; herdr says whether the pane looks
/// busy. [backgroundWork] and [waitingOnBackground] are decided from both and
/// the clock in `BackgroundView.derive`; [phase] is not touched by them.
/// Stopping a job asks omp in a message ([stopBackground]); it counts as done
/// only when the log shows the job ended.
///
/// Listeners are told at most once per [notifyEvery] (and per
/// [backgroundNotifyEvery] for streaming text when the app is away and the
/// session is kept alive).
class ObservedAgentSession extends ChangeNotifier implements AgentSessionView {
  ObservedAgentSession({
    required this.machine,
    required this.paneId,
    required this.agent,
    required this._source,
    required this._mapper,
    this._previews,
    this.parent,
    this.subagentName,
    this._fixedPath,
    this.askStepper = ompAskStepper,
    this._clock = DateTime.now,
    this._backoff = defaultBackoff,
    this._jitter = defaultRetryJitter,
    this.maxAttempts = 12,
    this.linger = const Duration(seconds: 20),
    this.idleAfter = const Duration(minutes: 10),
    this.detachAfter = const Duration(seconds: 90),
    this.notifyEvery = const Duration(milliseconds: 16),
    this.backgroundNotifyEvery = const Duration(seconds: 2),
    this.sliceLines = 64,
    this.sliceBudget = const Duration(milliseconds: 6),
    this.readyAfter = const Duration(milliseconds: 2500),
    this.silenceAfter = const Duration(milliseconds: 1500),
    this.confirmWithin = const Duration(seconds: 10),
    this.blockedGrace = const Duration(seconds: 3),
    this.answerGrace = const Duration(seconds: 8),
    this.problemHold = const Duration(seconds: 12),
    this.subagentPoll = const Duration(seconds: 4),
    this.subagentActive = const Duration(seconds: 8),
    this.maxAskSteps = 25,
    this.onIdle,
  }) : assert((parent == null) == (subagentName == null), 'a subagent names its parent'),
       _log = AgentSessionState(subagentName == null ? 'pane/$paneId' : 'sub/$paneId/$subagentName') {
    _phaseSince = DateTime.now();
  }

  @override
  final MachineConnection machine;

  /// The pane the agent runs in (a subagent's is its main agent's).
  final String paneId;
  @override
  final String agent;

  /// The main agent's session when this is one of its subagents.
  final ObservedAgentSession? parent;
  final String? subagentName;

  final SessionLogSource _source;
  final SessionLogMapper _mapper;
  final PanePreviews? _previews;
  final Duration Function(int attempt) _backoff;
  final double Function() _jitter;
  final String? _fixedPath;

  /// What the cross-check of background tasks reads as "now" (tests replace
  /// it).
  final DateTime Function() _clock;

  /// Makes the planner that answers the agent's question dialog, one screen at
  /// a time (the omp driver).
  final AskStepper Function(PendingAsk ask, List<AskAnswer> answers) askStepper;

  /// Retries per outage before the session gives up ([AgentLink.failed]).
  final int maxAttempts;

  /// How long the log is followed after the last screen let go.
  final Duration linger;

  /// After this long without a screen the registry may drop the session.
  final Duration idleAfter;

  /// How long the app may stay in the background before the follow stops.
  final Duration detachAfter;
  final Duration notifyEvery;
  final Duration backgroundNotifyEvery;

  /// Most log lines applied before the event loop gets a turn, and the longest
  /// a slice may take.
  final int sliceLines;
  final Duration sliceBudget;

  /// A channel that stays quiet this long without failing counts as open.
  final Duration readyAfter;

  /// A working agent whose log has been quiet this long shows its live output.
  final Duration silenceAfter;

  /// How long the log may take to show an answer the pane took.
  final Duration confirmWithin;

  /// A blocked pane with no understood prompt for this long needs the terminal.
  final Duration blockedGrace;

  /// How long an answered request stays hidden while the pane catches up.
  final Duration answerGrace;

  /// How long a failure message stays.
  final Duration problemHold;

  /// How often the artifact folder is listed while the roster is open.
  final Duration subagentPoll;

  /// A subagent whose log moved this recently is running.
  final Duration subagentActive;
  final int maxAskSteps;

  /// Told when no screen has held the session for [idleAfter].
  final void Function(ObservedAgentSession session)? onIdle;

  // -- state ------------------------------------------------------------------

  AgentSessionState _log;
  AgentSessionState? _composed;
  late DateTime _phaseSince;
  AgentPhase _lastPhase = AgentPhase.idle;

  int _holds = 0;
  bool _disposed = false;
  bool _keepAlive = false;
  DateTime? _backgroundedAt;
  bool _graceElapsed = false;
  bool _detached = false;
  Timer? _detachTimer;
  Timer? _lingerTimer;
  Timer? _idleTimer;

  // The follow.
  int _epoch = 0;
  bool _following = false;
  String? _followedPath;
  int? _offset;
  bool _ready = false;
  AgentLink _logLink = AgentLink.connecting;
  String? _failure;
  Completer<void>? _machineWake;
  Timer? _retryTimer;
  StreamSubscription<LogBatch>? _sub;

  String? _problem;
  Timer? _problemTimer;

  // Pending request.
  PendingRequest? _pending;
  String _pendingSig = '';
  PromptInfo? _pendingPrompt;
  bool _pendingFromMenu = false;
  PromptInfo? _menu;
  bool _probing = false;
  PanePreview? _probedFor;
  PendingAsk? _pendingAsk;
  bool _needsTerminal = false;
  int _attempt = 0;
  String? _suppressedSig;
  Timer? _suppressTimer;
  bool _busy = false;
  Timer? _blockedTimer;
  bool _blockedSettled = false;
  DateTime? _lastCancelAt;
  final _waiters = <_Waiter>[];

  // Preview watch, live output.
  PreviewHandle? _handle;
  PanePreview? _preview;
  Timer? _silenceTimer;
  bool _silent = false;
  List<String> _liveRows = const [];

  // Subagents.
  int _rosterWatchers = 0;
  Timer? _rosterTimer;
  Map<String, SubagentState> _refined = const {};
  Timer? _activeTimer;
  bool _recentlyActive = false;

  // Notification coalescing.
  Timer? _flushTimer;
  bool _flushSlow = false;
  bool _dirty = false;
  bool _batching = false;
  Object? _lastShown;

  /// The background work last handed out: the same instance until it changes.
  BackgroundView _bg = BackgroundView.none;

  bool get _isSub => parent != null;

  // -- the view ---------------------------------------------------------------

  @override
  String get key => _isSub
      ? 'sub/${machine.profile.id}/$paneId/$subagentName'
      : 'pane/${machine.profile.id}/$paneId';

  @override
  String get agentLabel => _isSub ? 'Subagent of ${parent!.title}' : (agent == 'omp' ? 'omp' : agent);

  Pane? get _pane => machine.paneById(paneId);

  @override
  String get cwd => _pane?.cwd ?? '';

  @override
  String get title {
    if (_isSub) return subagentName!;
    final logged = _log.title?.trim();
    if (logged != null && logged.isNotEmpty) return logged;
    final pane = _pane;
    final named = pane?.title.trim();
    if (named != null && named.isNotEmpty) return named;
    return _folderName(cwd, fallback: agentLabel);
  }

  @override
  AgentSessionState get state => _composed ??= _compose();

  AgentSessionState _compose() {
    var s = _log;
    if (phase == AgentPhase.working) s = s.withTurnStarted();
    if (_pending case final p?) s = s.withPending(p);
    return s;
  }

  @override
  DateTime? get cachedAsOf => null;

  @override
  AgentLink get link {
    if (_disposed) return AgentLink.ended;
    if (_isSub && parent!.link == AgentLink.ended) return AgentLink.ended;
    if (_gone || _exited) return AgentLink.ended;
    return _logLink;
  }

  /// herdr no longer lists the pane (its machine answers, so it is really
  /// gone).
  bool get _gone => machine.isLive && _pane == null;

  /// The pane is still there but nothing in it is an agent any more.
  bool get _exited => _pane != null && !_pane!.isAgent;

  @override
  String? get error {
    if (_problem != null) return _problem;
    if (_isSub && parent!.link == AgentLink.ended) return parent!.error;
    if (_gone) return 'This pane is gone from ${machine.profile.label}.';
    if (_exited) return '$agentLabel is not running in this pane any more.';
    return _failure;
  }

  /// Blocked on the person, and reachable.
  bool get _blocked => !_isSub && machine.isLive && _pane?.status == AgentStatus.blocked;

  @override
  AgentPhase get phase {
    final l = link;
    if (l == AgentLink.ended || l == AgentLink.failed) return AgentPhase.idle;
    if (_isSub) return _subWorking ? AgentPhase.working : AgentPhase.idle;
    final pane = _pane;
    if (pane == null || !machine.isLive) return AgentPhase.idle;
    if (_pending is PendingQuestion) return AgentPhase.blockedOnQuestion;
    return switch (pane.status) {
      AgentStatus.blocked => _pending is PendingQuestion ? AgentPhase.blockedOnQuestion : AgentPhase.blockedOnPermission,
      AgentStatus.working => AgentPhase.working,
      _ => AgentPhase.idle,
    };
  }

  bool get _subWorking =>
      _recentlyActive || _mapper.openToolCalls.isNotEmpty || parent!._stateOf(subagentName!) == SubagentState.running;

  @override
  DateTime? get phaseSince {
    if (!_isSub) {
      final pane = _pane;
      if (pane != null) {
        final seen = machine.statusSince(paneId);
        if (seen != null) return seen;
      }
    }
    return _phaseSince;
  }

  /// What this app knows of a turn it did not start: when the pane's status
  /// turned to working.
  @override
  DateTime? get turnStartedAt => phase == AgentPhase.working ? phaseSince : null;

  @override
  Listenable? liveTextOf(String messageKey) => _log.liveTextOf(messageKey);

  @override
  bool get unseenDone => !_isSub && machine.isLive && _pane?.status == AgentStatus.done;

  @override
  void markSeen() {
    if (_isSub) return;
    machine.markReviewed(paneId);
  }

  @override
  bool unmarkSeen() => !_isSub && machine.unmarkReviewed(paneId);

  @override
  bool get isObserved => true;

  @override
  String? get terminalPaneId => paneId;

  @override
  bool get needsTerminal => _needsTerminal;

  @override
  bool get evicted => false;

  @override
  ResumeTarget? get resumeTarget => null;

  @override
  String? get relayNote => _isSub ? 'Goes to ${parent!.title}, who relays it to $subagentName' : null;

  @override
  String? get sendBlocked {
    if (_isSub) return parent!.sendBlocked;
    return switch (_pending) {
      PendingQuestion() => 'Answer the question above first',
      PendingPermission() => 'Answer the request above first',
      _ => _blocked ? 'Waiting for you in the terminal' : null,
    };
  }

  // An agent in a pane has its own composer: the terminal queues or steers as
  // that agent does, and the phone only types into it. No queue, no login
  // flow, no attachments here.
  @override
  SendDelivery get delivery => SendDelivery.now;

  @override
  bool get canSteer => false;

  @override
  bool get acceptsImages => false;

  @override
  bool get acceptsEmbeddedContext => false;

  @override
  List<QueuedMessage> get queued => const [];

  @override
  void editQueued(String id, String text) {}

  @override
  void removeQueued(String id) {}

  @override
  void resumeQueue() {}

  @override
  AuthNeeded? get authNeeded => null;

  // Subagents of an observed session are the roster ([subagents]); the
  // reducer's runs belong to ACP sessions.
  @override
  List<SubagentRun> get subagentRuns => const [];

  @override
  SubagentSummary get subagentSummary => SubagentSummary.none;

  @override
  SubagentRun? subagentRun(String id) => null;

  @override
  void watchSubagentLog(String runId, bool on) {}

  @override
  SubagentLogStatus subagentLogStatus(String runId) => SubagentLogStatus.idle;

  @override
  void retrySubagentLog(String runId) {}

  @override
  List<SubagentRun> subagentsOfToolCall(String toolCallId) => const [];

  // -- background work ----------------------------------------------------------

  /// The log's tasks checked against herdr and the clock (see
  /// [BackgroundView.derive]), memoized so that a widget can compare by
  /// identity. A subagent's own session has none: its parent's list holds the
  /// job.
  BackgroundView _background() {
    if (_isSub) return BackgroundView.none;
    final gone = link == AgentLink.ended;
    final tasks = _mapper.backgroundTasks;
    final next = BackgroundView.derive(
      // The agent is not running in the pane any more: nothing is left to
      // wake it.
      herdr: gone ? AgentStatus.idle : (machine.isLive ? _pane?.status : null),
      turnEnded: gone || _mapper.turnEnded,
      tasks: tasks,
      now: _clock(),
      wakeLabel: agentLabel,
      watchedRunning: tasks.any((t) => t.kind == BackgroundKind.agent && t.isActive)
          ? {
              for (final s in _mapper.subagents)
                if (_stateOf(s.name) == SubagentState.running) s.name,
            }
          : const {},
    );
    if (_bg.sameAs(next)) return _bg;
    return _bg = next;
  }

  @override
  BackgroundWork get backgroundWork => _background().work;

  @override
  bool get waitingOnBackground => _background().waiting;

  /// omp has no key or request that stops one job, only its model can
  /// (`write proc://<id>/kill`): the phone asks it, in a message through the
  /// same path as the composer. Never keys: nothing types into omp blind.
  @override
  Future<BackgroundStopResult> stopBackground(String id) async {
    final task = backgroundWork.running.where((t) => t.id == id).firstOrNull;
    if (task == null) return const BackgroundAlreadyDone();
    return _askToStop([task]);
  }

  @override
  Future<BackgroundStopResult> stopAllBackground() async {
    final work = backgroundWork;
    if (work.running.isEmpty) return const BackgroundAlreadyDone();
    return _askToStop(work.stoppable);
  }

  /// One message for all of [tasks]; only ids that are plain tokens are put
  /// into it (they come from a log).
  Future<BackgroundStopResult> _askToStop(List<BackgroundTask> tasks) async {
    final ids = [
      for (final t in tasks)
        if (t.stop == StopRoute.message && isSafeBackgroundId(t.id)) t.id,
    ];
    final message = stopMessageForOmp(ids);
    if (message == null) return const BackgroundNotStoppable();
    final failure = await _sendPrompt(message);
    if (failure != null) return BackgroundStopFailed(failure);
    return const BackgroundStopped(asked: true);
  }

  @override
  List<String>? get liveOutput => _silent ? _liveRows : null;

  @override
  List<SubagentEntry> get subagents => [
    for (final s in _mapper.subagents) SubagentEntry(info: s, state: _stateOf(s.name)),
  ];

  SubagentState _stateOf(String name) {
    final info = _mapper.subagents.where((s) => s.name == name).firstOrNull;
    if (info == null) return SubagentState.waiting;
    final logged = switch (info.status) {
      'running' => SubagentState.running,
      'completed' || 'done' || 'finished' => SubagentState.finished,
      'failed' || 'aborted' || 'cancelled' || 'error' => SubagentState.failed,
      _ => SubagentState.waiting,
    };
    final refined = _refined[name];
    if (refined == null || logged == SubagentState.failed) return logged;
    return refined;
  }

  // -- demand -----------------------------------------------------------------

  @override
  void acquire() {
    if (_disposed) return;
    _holds++;
    _lingerTimer?.cancel();
    _lingerTimer = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_holds == 1) {
      machine.addListener(_onMachine);
      parent?.addListener(_onMachine);
    }
    _ensureFollowing();
    _refresh();
  }

  @override
  void release() {
    if (_disposed || _holds == 0) return;
    if (--_holds > 0) return;
    _lingerTimer = Timer(linger, _stopFollowing);
    _idleTimer = Timer(idleAfter, () => onIdle?.call(this));
    _refresh();
  }

  /// A screen holds the session.
  bool get held => _holds > 0;

  /// A subagent whose main agent moved on to another log (the person started
  /// or resumed a session): what it shows belongs to the old one.
  bool get stale => _isSub && parent!.subagentLog(subagentName!) != _fixedPath;

  /// The follow is running (tests, diagnostics).
  bool get following => _following;

  @override
  Future<void> reattach() async {
    if (_disposed || _backgroundedAt != null) return;
    _failure = null;
    _attempt = 0;
    if (held) _restartFollow();
    _refresh();
  }

  // -- the log ------------------------------------------------------------------

  /// Where the agent writes its log now: what herdr says the pane runs (it
  /// changes when the person starts or resumes another session), or a
  /// subagent's file.
  String? get _logPath {
    if (_fixedPath != null) return _fixedPath;
    final session = _pane?.session;
    if (session == null || session.kind != 'path' || !session.value.endsWith('.jsonl')) return null;
    return session.value;
  }

  void _ensureFollowing() {
    if (_disposed || _following || _detached || !held) return;
    if (_failure != null) return;
    _following = true;
    unawaited(_follow(++_epoch));
  }

  void _restartFollow() {
    _epoch++;
    _dropStream();
    _following = false;
    _ensureFollowing();
  }

  void _stopFollowing() {
    _lingerTimer = null;
    if (!_following && _sub == null) return;
    _epoch++;
    _dropStream();
    _following = false;
    _machineWake = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _logLink = AgentLink.connecting;
    _ready = false;
    _refresh();
  }

  void _dropStream() {
    final sub = _sub;
    _sub = null;
    if (sub != null) unawaited(sub.cancel());
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  bool _alive(int epoch) => !_disposed && epoch == _epoch;

  Future<void> _follow(int epoch) async {
    var attempt = 0;
    try {
      while (_alive(epoch)) {
        final path = _logPath;
        if (path == null) {
          _fail('This agent does not name a session log.');
          return;
        }
        if (_followedPath != null && _followedPath != path) {
          _resetLog();
          _ready = false;
          _logLink = AgentLink.connecting;
        }
        _followedPath = path;
        if (!machine.isLive) {
          _setLink(AgentLink.reconnecting);
          await _waitForMachine(epoch);
          continue;
        }
        if (!_ready) _setLink(AgentLink.connecting);
        Object? failure;
        try {
          final gotRecords = await _followOnce(path, epoch);
          if (!_alive(epoch)) return;
          if (gotRecords) attempt = 0;
          failure = const HerdrTransportException('The connection to the log ended.');
        } on AgentHostException catch (e) {
          if (!_alive(epoch)) return;
          if (e.fatal) {
            _fail(e.message);
            return;
          }
          failure = e;
        } on HerdrTransportException catch (e) {
          if (!_alive(epoch)) return;
          if (e.fatal) {
            _fail(e.message);
            return;
          }
          failure = e;
        } on Object catch (e) {
          if (!_alive(epoch)) return;
          _fail('The log could not be read: $e');
          return;
        }
        if (attempt >= maxAttempts) {
          _fail('The connection to the log kept dropping: ${_words(failure)}');
          return;
        }
        _setLink(AgentLink.reconnecting);
        final delay = _backoff(attempt++);
        final spread = Duration(microseconds: (delay.inMicroseconds * _jitter()).round());
        await _sleep(_quiet && spread < backgroundNotifyEvery * 15 ? backgroundNotifyEvery * 15 : spread, epoch);
      }
    } finally {
      if (epoch == _epoch) _following = false;
    }
  }

  static String _words(Object e) => switch (e) {
    AgentHostException(:final message) => message,
    HerdrTransportException(:final message) => message,
    _ => '$e',
  };

  Future<void> _sleep(Duration d, int epoch) {
    final done = Completer<void>();
    _retryTimer = Timer(d, () {
      if (!done.isCompleted) done.complete();
    });
    return done.future;
  }

  Future<void> _waitForMachine(int epoch) {
    final wake = _machineWake = Completer<void>();
    return wake.future;
  }

  /// Follows [path] until the stream ends or fails; true if it delivered a batch.
  Future<bool> _followOnce(String path, int epoch) {
    final done = Completer<bool>();
    var got = false;
    var work = Future<void>.value();
    final sub = _source.follow(path, from: _offset).listen(
      (batch) {
        got = true;
        work = work.then((_) => _alive(epoch) ? _applyBatch(batch, epoch) : null);
      },
      onError: (Object e, StackTrace s) {
        work = work.then((_) {
          if (!done.isCompleted) done.completeError(e, s);
        });
      },
      onDone: () {
        work = work.then((_) {
          if (!done.isCompleted) done.complete(got);
        });
      },
      cancelOnError: true,
    );
    _sub = sub;
    // The helper says `caught up` after its first read to the end, which is how
    // an empty log or a resume at its end becomes live. This is the fallback for
    // a channel that stays quiet without failing: live once it has been quiet a
    // moment.
    final ready = Timer(readyAfter, () {
      if (!_alive(epoch) || _ready) return;
      _ready = true;
      _failure = null;
      _setLink(AgentLink.live);
    });
    return done.future.whenComplete(() {
      ready.cancel();
      if (identical(_sub, sub)) _sub = null;
    });
  }

  Future<void> _applyBatch(LogBatch batch, int epoch) async {
    if (batch.reset) _resetLog();
    final lines = batch.lines;
    final big = lines.length > sliceLines || !_ready;
    if (big) _batching = true;
    final clock = Stopwatch()..start();
    var at = 0;
    while (at < lines.length) {
      if (!_alive(epoch)) {
        _batching = false;
        return;
      }
      clock.reset();
      var n = 0;
      while (at < lines.length && n < sliceLines && (n == 0 || clock.elapsed < sliceBudget)) {
        _applyLine(lines[at++]);
        n++;
      }
      if (at < lines.length) await Future<void>.delayed(Duration.zero);
    }
    _batching = false;
    _offset = batch.endOffset;
    final first = !_ready;
    if (first) _toldSinceFirstBatch = false;
    _ready = true;
    _failure = null;
    if (first) _setLink(AgentLink.live);
    _composed = null;
    if (lines.isNotEmpty) _onLogEntries();
    _refresh(urgent: first || batch.reset || big);
    _wake();
  }

  void _applyLine(String line) {
    for (final u in _mapper.map(line)) {
      _log = _log.apply(u);
    }
  }

  void _resetLog() {
    _mapper.reset();
    _log = AgentSessionState(_log.sessionId);
    _composed = null;
    _offset = null;
    _pendingAsk = null;
    _refined = const {};
  }

  void _setLink(AgentLink link) {
    if (_logLink == link) return;
    _logLink = link;
    _refresh();
  }

  void _fail(String message) {
    _failure = message;
    _logLink = AgentLink.failed;
    _following = false;
    _ready = false;
    _dropStream();
    _refresh();
  }

  /// A log entry arrived: the live output (a stand-in for it) goes, activity
  /// of a subagent is noted.
  void _onLogEntries() {
    _silenceTimer?.cancel();
    _silenceTimer = null;
    if (_silent) {
      _silent = false;
      _liveRows = const [];
    }
    if (_isSub) {
      _recentlyActive = true;
      _activeTimer?.cancel();
      _activeTimer = Timer(subagentActive, () {
        _activeTimer = null;
        _recentlyActive = false;
        _refresh();
      });
    }
  }

  // -- deriving everything from the pane and the log -----------------------------

  void _onMachine() {
    if (_disposed) return;
    if (machine.isLive) _wake();
    // herdr named another log (a new or resumed session): follow that one.
    if (held && !_isSub) {
      final path = _logPath;
      if (path != null && _followedPath != null && path != _followedPath && _following) {
        _restartFollow();
      } else if (path != null && _failure != null && path != _followedPath) {
        _failure = null;
        _attempt = 0;
        _ensureFollowing();
      }
    }
    _refresh();
  }

  void _wake() {
    final wake = _machineWake;
    _machineWake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
    for (final w in List.of(_waiters)) {
      if (w.test()) {
        _waiters.remove(w);
        w.done.complete(true);
      }
    }
  }

  /// Recomputes what the screen shows from the pane, the log and the prompt,
  /// and tells the listeners when any of it changed.
  void _refresh({bool urgent = true}) {
    if (_disposed) return;
    _syncPending();
    _syncWatch();
    _syncSilence();
    final phase = this.phase;
    if (phase != _lastPhase) {
      _lastPhase = phase;
      _phaseSince = DateTime.now();
    }
    _composed = null;
    final background = _background();
    final shown = (
      link,
      phase,
      unseenDone,
      _pending,
      _needsTerminal,
      title,
      '$error|$sendBlocked',
      cwd,
      _silent ? _liveRows : null,
      _log,
      _mapper.subagents.length,
      _refined,
      background.work,
      background.waiting,
    );
    if (_lastShown != null && _recordsEqual(_lastShown!, shown)) return;
    _lastShown = shown;
    _changed(urgent: urgent);
  }

  static bool _recordsEqual(Object a, Object b) {
    final x = a as (AgentLink, AgentPhase, bool, PendingRequest?, bool, String, String?, String, List<String>?, AgentSessionState, int, Map<String, SubagentState>, BackgroundWork, bool);
    final y = b as (AgentLink, AgentPhase, bool, PendingRequest?, bool, String, String?, String, List<String>?, AgentSessionState, int, Map<String, SubagentState>, BackgroundWork, bool);
    return x.$1 == y.$1 &&
        x.$2 == y.$2 &&
        x.$3 == y.$3 &&
        identical(x.$4, y.$4) &&
        x.$5 == y.$5 &&
        x.$6 == y.$6 &&
        x.$7 == y.$7 &&
        x.$8 == y.$8 &&
        listEquals(x.$9, y.$9) &&
        identical(x.$10, y.$10) &&
        x.$11 == y.$11 &&
        mapEquals(x.$12, y.$12) &&
        identical(x.$13, y.$13) &&
        x.$14 == y.$14;
  }

  /// The request the pane waits on, or none.
  void _syncPending() {
    if (_isSub) return;
    PendingRequest? next;
    String sig = '';
    PromptInfo? prompt;
    PendingAsk? ask;
    var needsTerminal = false;
    // The log's open question is enough: herdr marks the dialog blocked only
    // when its omp extension is installed. Answers are checked against the
    // screen before a key is sent.
    final asking = _mapper.pendingAsk;
    if (asking != null && machine.isLive && (_pane?.isAgent ?? false)) {
      ask = asking;
      sig = 'ask:${askSignature(asking)}';
    } else if (_blocked) {
      final understood = _preview?.prompt ?? _menu;
      if (_preview != null && _preview!.prompt == null && !_probing && !identical(_probedFor, _preview)) {
        unawaited(_probe(_preview!));
      }
      if (understood != null) {
        prompt = understood;
        sig = 'prompt:${promptSignature(understood)}';
      } else {
        needsTerminal = _blockedSettled;
      }
    }
    if (sig.isNotEmpty && sig == _suppressedSig) {
      next = null;
    } else if (sig.isNotEmpty) {
      final full = '$sig\u0003$_attempt';
      if (full == _pendingSig && _pending != null) {
        next = _pending;
      } else {
        _pendingSig = full;
        if (ask != null) {
          next = PendingQuestion('ask:${ask.toolCallId}:$_attempt', askRequest(ask, sessionId: paneId, agentLabel: agentLabel));
        } else {
          next = PendingPermission('prompt:${promptSignature(prompt!).hashCode}:$_attempt', promptRequest(prompt, paneId: paneId, call: _openCall()));
        }
      }
    }
    if (sig != _suppressedSig && _suppressedSig != null) {
      // The pane moved on from what was answered.
      _suppressedSig = null;
      _suppressTimer?.cancel();
      _suppressTimer = null;
    }
    if (next == null) _pendingSig = '';
    _pending = next;
    _pendingPrompt = next is PendingPermission ? prompt : null;
    _pendingFromMenu = _pendingPrompt != null && _preview?.prompt == null;
    if (!_blocked) {
      _menu = null;
      _probedFor = null;
    }
    _pendingAsk = next is PendingQuestion ? ask : null;
    _needsTerminal = needsTerminal;
    // Blocked but not understood: give the preview a moment before saying so.
    if (_blocked && next == null && sig.isEmpty && !_blockedSettled) {
      _blockedTimer ??= Timer(blockedGrace, () {
        _blockedTimer = null;
        _blockedSettled = true;
        _refresh();
      });
    } else if (!_blocked || next != null || sig.isNotEmpty) {
      _blockedTimer?.cancel();
      _blockedTimer = null;
      _blockedSettled = false;
    }
  }

  /// The tool call the pane most likely asks about: the latest one that
  /// started and has no result.
  ToolCall? _openCall() {
    ToolCall? found;
    for (final id in _mapper.openToolCalls) {
      final call = _log.toolCall(id);
      if (call != null && !call.status.isFinished) found = call;
    }
    return found;
  }

  // -- preview and live output -----------------------------------------------------

  bool get _quiet => _keepAlive && _backgroundedAt != null;

  bool get _wantsPrompt => held && _blocked && _mapper.pendingAsk == null && !_isSub;

  bool get _wantsTail => held && _backgroundedAt == null && _silent && !_isSub;

  void _syncWatch() {
    final previews = _previews;
    final want = previews != null && (_wantsPrompt || _wantsTail);
    if (want && _handle == null) {
      final handle = _handle = previews.watch(machine.profile.id, paneId);
      handle.preview.addListener(_onPreview);
      _preview = handle.preview.value;
    } else if (!want && _handle != null) {
      _releaseHandle();
    }
  }

  void _releaseHandle() {
    final handle = _handle;
    if (handle == null) return;
    _handle = null;
    handle.preview.removeListener(_onPreview);
    handle.release();
    _preview = null;
  }

  void _onPreview() {
    final next = _handle?.preview.value;
    _preview = next;
    if (_silent) _liveRows = _tail(next);
    _refresh();
  }

  static const _tailRows = 6;

  static List<String> _tail(PanePreview? p) {
    if (p == null) return const [];
    final rows = [for (final l in p.lines) l.text];
    return rows.length <= _tailRows ? rows : rows.sublist(rows.length - _tailRows);
  }

  /// The silence timer runs only while the live output could be shown: the
  /// agent works, nothing waits for the person, the app is in front.
  void _syncSilence() {
    final want = held && !_isSub && _backgroundedAt == null && phase == AgentPhase.working;
    if (!want) {
      _silenceTimer?.cancel();
      _silenceTimer = null;
      if (_silent) {
        _silent = false;
        _liveRows = const [];
      }
      return;
    }
    if (_silent || _silenceTimer != null) return;
    _silenceTimer = Timer(silenceAfter, () {
      _silenceTimer = null;
      _silent = true;
      _liveRows = _tail(_preview);
      _refresh();
    });
  }

  // -- what the person does -----------------------------------------------------------

  @override
  Future<bool> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    if (_isSub) {
      final failure = await parent!._sendPrompt(
        'Please relay this to subagent $subagentName with write agent://$subagentName: $trimmed',
      );
      _setProblem(failure);
      return failure == null;
    }
    final before = _userMessages();
    final failure = await _sendPrompt(trimmed);
    _setProblem(failure);
    if (failure != null) return false;
    markSeen();
    unawaited(_confirmSent(before));
    return true;
  }

  @override
  Future<bool> sendBlocks(List<ContentBlock> blocks, {bool queue = false}) async {
    if (blocks.any((b) => b is! TextBlock)) {
      _setProblem('This agent runs in a terminal; attachments cannot be sent to it. The message was not sent.');
      return false;
    }
    return send([for (final b in blocks) (b as TextBlock).text].join('\n'));
  }

  int _userMessages() => _log.items.where((i) => i is TranscriptMessage && i.role == MessageRole.user).length;

  /// The agent writes the message to its log when it takes it: no entry in
  /// [confirmWithin] means the pane did not take it (the log is the truth, so
  /// nothing is echoed locally).
  Future<void> _confirmSent(int before) async {
    final seen = await _waitFor(() => _userMessages() > before, confirmWithin);
    if (!seen && !_disposed && _logLink == AgentLink.live) {
      _setProblem('The message is not in the agent’s log yet. Check the terminal.');
    }
  }

  /// Types [text] into the pane as the composer of the terminal screen does;
  /// null when it went, else why not.
  Future<String?> _sendPrompt(String text) async {
    if (_disposed) return 'This session is closed.';
    if (!machine.isLive || _pane == null) return 'Not connected. The message was not sent.';
    if (_blocked || _pending != null) {
      return _pending is PendingQuestion
          ? 'The agent is waiting for an answer. Answer it first; the message was not sent.'
          : 'The agent is waiting for you in the terminal. The message was not sent.';
    }
    try {
      await machine.api.sendLine(paneId, text);
      return null;
    } on HerdrApiException catch (e) {
      return e.toString();
    } on HerdrTransportException catch (e) {
      return e.message;
    }
  }

  /// `esc`, the same key as the terminal screen's chip. A second Stop within a
  /// moment is ignored: two escapes open omp's message tree.
  @override
  void cancel() {
    if (_isSub || _disposed) return;
    final now = DateTime.now();
    final last = _lastCancelAt;
    if (last != null && now.difference(last) < const Duration(milliseconds: 1500)) return;
    _lastCancelAt = now;
    unawaited(_keys(const ['esc']));
  }

  Future<void> _keys(List<String> keys) async {
    try {
      await machine.api.sendKeys(paneId, keys);
    } on HerdrApiException catch (e) {
      _setProblem(e.toString());
    } on HerdrTransportException catch (e) {
      _setProblem(e.message);
    }
  }

  @override
  Future<void> setMode(String modeId) async => _setProblem('This agent runs in a terminal; change it there.');

  @override
  Future<void> setConfigOption(String configId, Object value) async =>
      _setProblem('This agent runs in a terminal; change it there.');

  @override
  Future<void> end() => throw const AgentHostException('An agent that runs in a terminal is ended in the terminal.');

  @override
  void answerPermission(Object requestId, PermissionOutcome outcome) {
    final p = _pending;
    if (p is! PendingPermission || p.id != requestId || _busy || _disposed) return;
    unawaited(_answerPermission(p, outcome));
  }

  Future<void> _answerPermission(PendingPermission p, PermissionOutcome outcome) async {
    _busy = true;
    try {
      if (outcome is PermissionSelected) {
        final shown = _pendingPrompt;
        final index = int.tryParse(outcome.optionId);
        if (shown == null || index == null || index < 0 || index >= shown.replies.length) {
          return _refuse(p, 'That answer is no longer on the screen. Check the terminal.');
        }
        // The screen is the truth: send the keys only if it still asks this.
        final fresh = await _freshPrompt(menu: _pendingFromMenu);
        if (fresh == null ||
            promptSignature(fresh) != promptSignature(shown) ||
            index >= fresh.replies.length) {
          return _refuse(p, 'The terminal changed before that answer was sent. Look at it and answer again.');
        }
        await machine.api.sendKeys(paneId, fresh.replies[index].keys);
        machine.markReviewed(paneId);
      } else {
        await machine.api.sendKeys(paneId, const ['esc']);
      }
      _suppress(p);
    } on HerdrApiException catch (e) {
      _refuse(p, e.toString());
    } on HerdrTransportException catch (e) {
      _refuse(p, e.message);
    } finally {
      _busy = false;
    }
  }

  /// The prompt on the pane's screen right now, read the way [menu] says: omp's
  /// own menus (tool approval, plan review) or the generic prompt detector.
  Future<PromptInfo?> _freshPrompt({required bool menu}) async {
    final read = await machine.api.readPane(paneId, lines: 60);
    return _parsePrompt(read.text, menu: menu);
  }

  static PromptInfo? _parsePrompt(String text, {required bool menu}) {
    if (menu) return _menuPrompt(text);
    final rows = <String>[];
    for (final raw in text.split('\n')) {
      final cr = raw.lastIndexOf('\r');
      final row = cleanPreviewRow(stripAnsi(cr < 0 ? raw : raw.substring(cr + 1)));
      if (row != null) rows.add(row.length > 160 ? row.substring(0, 160) : row);
    }
    return detectPrompt(rows);
  }

  /// omp's tool approval or plan review as a prompt: each option with the keys
  /// that choose it from where the cursor is.
  static PromptInfo? _menuPrompt(String screen) {
    final approval = parseOmpApproval(screen);
    final OmpMenuScreen? menu = approval ?? parseOmpPlanReview(screen);
    if (menu == null) return null;
    final replies = <QuickReply>[];
    for (final (i, o) in menu.options.indexed) {
      final keys = menu.keysFor(i);
      if (keys == null) return null;
      replies.add(QuickReply(label: o.label, keys: keys));
    }
    return PromptInfo(
      question: approval == null ? 'Plan mode - next step' : 'Allow tool: ${approval.tool}',
      subject: approval == null ? '' : _approvalSubject(approval.detail),
      replies: replies,
    );
  }

  /// The rows above an approval's options, without their `Command:`-style
  /// labels when it names a command.
  static String _approvalSubject(List<String> detail) {
    for (final line in detail) {
      final m = RegExp(r'^\s*(?:Command|Path|File|Url|URL):\s*(.+)$').firstMatch(line);
      if (m != null) return m[1]!.trim();
    }
    return detail.map((l) => l.trim()).where((l) => l.isNotEmpty).join('\n');
  }

  /// One read of the pane for omp's own menus, when the generic detector found
  /// nothing in the preview.
  Future<void> _probe(PanePreview seen) async {
    _probing = true;
    try {
      final read = await machine.api.readPane(paneId, lines: 60);
      if (_disposed) return;
      _menu = _menuPrompt(read.text);
    } on HerdrApiException {
      _menu = null;
    } on HerdrTransportException {
      _menu = null;
    } finally {
      _probing = false;
      _probedFor = seen;
    }
    _refresh();
  }

  /// The pane did not take the answer: the request comes back, new, and the
  /// person is told.
  void _refuse(PendingRequest p, String message) {
    _attempt++;
    _setProblem(message);
    _refresh();
  }

  /// [p] was answered: it stays hidden until the pane moves on, or for
  /// [answerGrace], after which it comes back if the pane still waits.
  void _suppress(PendingRequest p) {
    _suppressedSig = _pendingSig.split('\u0003').first;
    _suppressTimer?.cancel();
    _suppressTimer = Timer(answerGrace, () {
      _suppressTimer = null;
      _suppressedSig = null;
      _attempt++;
      _refresh();
    });
    _refresh();
  }

  @override
  void answerQuestion(Object requestId, ElicitationResponse response) {
    final p = _pending;
    if (p is! PendingQuestion || p.id != requestId || _busy || _disposed) return;
    final ask = _pendingAsk;
    if (response is! ElicitationAccept || ask == null) {
      _busy = true;
      unawaited(
        _keys(const ['esc']).whenComplete(() {
          _busy = false;
          _suppress(p);
        }),
      );
      return;
    }
    final parsed = askAnswers(ask, response.content);
    if (parsed.problem != null) {
      _refuse(p, parsed.problem!);
      return;
    }
    unawaited(_answerAsk(p, ask, parsed.answers));
  }

  static const _notTaken = 'The terminal did not take that answer. Open the terminal.';

  Future<void> _answerAsk(PendingQuestion p, PendingAsk ask, List<AskAnswer> answers) async {
    _busy = true;
    try {
      var submitted = false;
      final stepper = askStepper(ask, answers);
      for (var step = 0; step < maxAskSteps && !submitted; step++) {
        final read = await machine.api.readPane(paneId, lines: 60);
        final next = stepper(read.text);
        switch (next) {
          case AskDone():
            submitted = true;
          case AskMismatch():
            return _refuse(p, _notTaken);
          case AskSend(:final keys, :final text, :final submits):
            await machine.api.sendInput(paneId, text ?? '', keys: keys);
            submitted = submits;
        }
      }
      if (!submitted) return _refuse(p, _notTaken);
      // The log has the last word: the tool's result line, with the answer.
      final recorded = await _waitFor(() => _mapper.pendingAsk?.toolCallId != ask.toolCallId, confirmWithin);
      final output = _log.toolCall(ask.toolCallId)?.rawOutput;
      if (!recorded) return _refuse(p, _notTaken);
      if (!askResultMatches(output is String ? output : null, ask, answers)) {
        _setProblem('The terminal recorded a different answer than the one you gave. Check the terminal.');
      }
      _suppress(p);
    } on HerdrApiException catch (e) {
      _refuse(p, e.toString());
    } on HerdrTransportException catch (e) {
      _refuse(p, e.message);
    } finally {
      _busy = false;
    }
  }

  Future<bool> _waitFor(bool Function() test, Duration timeout) {
    if (test()) return Future.value(true);
    final waiter = _Waiter(test);
    _waiters.add(waiter);
    final timer = Timer(timeout, () {
      if (_waiters.remove(waiter)) waiter.done.complete(false);
    });
    return waiter.done.future.whenComplete(timer.cancel);
  }

  void _setProblem(String? problem) {
    if (_problem == problem) return;
    _problem = problem;
    _problemTimer?.cancel();
    _problemTimer = null;
    if (problem != null) {
      _problemTimer = Timer(problemHold, () {
        _problemTimer = null;
        _problem = null;
        _refresh();
      });
    }
    _refresh();
  }

  // -- subagents --------------------------------------------------------------

  @override
  void watchSubagents(bool on) {
    if (_disposed) return;
    if (on) {
      if (_rosterWatchers++ == 0) {
        unawaited(_listArtifacts());
        _rosterTimer = Timer.periodic(subagentPoll, (_) => unawaited(_listArtifacts()));
      }
    } else if (_rosterWatchers > 0 && --_rosterWatchers == 0) {
      _rosterTimer?.cancel();
      _rosterTimer = null;
    }
  }

  /// The folder next to the log that holds the subagents' files.
  String? get artifactDir {
    final path = _followedPath ?? _logPath;
    if (path == null || !path.endsWith('.jsonl')) return null;
    return path.substring(0, path.length - '.jsonl'.length);
  }

  /// The log file of subagent [name].
  String? subagentLog(String name) {
    final dir = artifactDir;
    return dir == null ? null : '$dir/$name.jsonl';
  }

  Future<void> _listArtifacts() async {
    final dir = artifactDir;
    if (dir == null || !machine.isLive || _disposed) return;
    final List<dynamic> entries;
    try {
      entries = await machine.api.files.list(dir);
    } on Object {
      return;
    }
    if (_disposed || _rosterWatchers == 0) return;
    final now = DateTime.now().toUtc();
    final names = <String, Map<String, DateTime?>>{};
    for (final e in entries) {
      final name = e.name as String;
      final dot = name.lastIndexOf('.');
      if (dot <= 0) continue;
      names.putIfAbsent(name.substring(0, dot), () => {})[name.substring(dot + 1)] = e.modified as DateTime?;
    }
    final refined = <String, SubagentState>{};
    for (final s in _mapper.subagents) {
      final files = names[s.name];
      if (files == null) continue;
      if (files.containsKey('md') || files.containsKey('json')) {
        refined[s.name] = SubagentState.finished;
      } else if (files.containsKey('jsonl')) {
        final at = files['jsonl'];
        refined[s.name] = at != null && now.difference(at.toUtc()) <= subagentActive * 4
            ? SubagentState.running
            : SubagentState.finished;
      }
    }
    if (mapEquals(refined, _refined)) return;
    _refined = refined;
    _refresh();
  }

  // -- app lifecycle ---------------------------------------------------------------

  /// Feeds app lifecycle transitions: `hidden`/`paused` start the clock to
  /// [detachAfter] (no live output, no preview watch meanwhile), `resumed`
  /// follows again what is wanted.
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

  void background({DateTime? since}) {
    if (_disposed || _backgroundedAt != null) return;
    _backgroundedAt = since ?? DateTime.now();
    _graceElapsed = false;
    _detachTimer = Timer(detachAfter, () {
      _detachTimer = null;
      _graceElapsed = true;
      if (!_keepAlive) _detach();
    });
    _refresh();
  }

  set keepAliveInBackground(bool value) {
    if (_keepAlive == value) return;
    _keepAlive = value;
    if (!value && _backgroundedAt != null && _graceElapsed) _detach();
    if (_flushTimer != null && _flushSlow) _changed();
  }

  void foreground() {
    if (_backgroundedAt == null) return;
    _backgroundedAt = null;
    _graceElapsed = false;
    _detachTimer?.cancel();
    _detachTimer = null;
    if (_flushTimer != null && _flushSlow) _changed();
    if (_detached) {
      _detached = false;
      _attempt = 0;
      _ensureFollowing();
    }
    _refresh();
  }

  void _detach() {
    if (_disposed || _detached) return;
    _detached = true;
    _epoch++;
    _dropStream();
    _following = false;
    _ready = false;
    _logLink = AgentLink.reconnecting;
    _refresh();
  }

  // -- notifying --------------------------------------------------------------------

  /// Whether listeners were told anything since the first batch of this follow
  /// was applied.
  bool _toldSinceFirstBatch = false;

  /// Notifies once per [notifyEvery] however many changes came, except that the
  /// change that shows the first batch of a follow goes out on the next turn of
  /// the event loop: an open does not wait a frame for its first paint (never
  /// synchronously: `acquire()` runs in `initState`). In the background with the
  /// session kept alive the text that streams in notifies at most once per
  /// [backgroundNotifyEvery]; an [urgent] change (link, phase, a request, an
  /// error) still goes out within [notifyEvery]. Nothing is told while a big
  /// batch is being applied.
  void _changed({bool urgent = true}) {
    if (_disposed || _batching) return;
    _dirty = true;
    final slow = _quiet && !urgent;
    if (_flushTimer != null && (slow || !_flushSlow)) return;
    _flushTimer?.cancel();
    _flushSlow = slow;
    final wait = slow
        ? backgroundNotifyEvery
        : (_toldSinceFirstBatch ? notifyEvery : Duration.zero);
    _flushTimer = Timer(wait, () {
      _flushTimer = null;
      if (_disposed || !_dirty) return;
      _dirty = false;
      _toldSinceFirstBatch = true;
      _log.liveMessage?.live?.flush();
      notifyListeners();
    });
  }

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
    machine.removeListener(_onMachine);
    parent?.removeListener(_onMachine);
    _dropStream();
    _releaseHandle();
    for (final t in [
      _detachTimer,
      _lingerTimer,
      _idleTimer,
      _problemTimer,
      _suppressTimer,
      _blockedTimer,
      _silenceTimer,
      _rosterTimer,
      _activeTimer,
      _flushTimer,
    ]) {
      t?.cancel();
    }
    for (final w in _waiters) {
      if (!w.done.isCompleted) w.done.complete(false);
    }
    _waiters.clear();
    final wake = _machineWake;
    if (wake != null && !wake.isCompleted) wake.complete();
    super.dispose();
  }
}

class _Waiter {
  _Waiter(this.test);

  final bool Function() test;
  final done = Completer<bool>();
}
