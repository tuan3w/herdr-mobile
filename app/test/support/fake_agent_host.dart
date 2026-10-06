import 'dart:async';

import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/acp/json_rpc.dart';
import 'package:herdr_mobile/data/acp/past_session.dart';

import '../acp/support/fake_agent.dart';

Json agentChunk(String text, {String messageId = 'a1'}) => {
      'sessionUpdate': 'agent_message_chunk',
      'messageId': messageId,
      'content': {'type': 'text', 'text': text},
    };

Json userChunk(String text, {String messageId = 'u1'}) => {
      'sessionUpdate': 'user_message_chunk',
      'messageId': messageId,
      'content': {'type': 'text', 'text': text},
    };

Json idleUpdate(String stopReason) => {
      'sessionUpdate': 'state_update',
      'state': 'idle',
      'stopReason': stopReason,
    };

Json runningUpdate() => {'sessionUpdate': 'state_update', 'state': 'running'};

/// A request the agent made that nobody answered yet. Like the real keeper's
/// pending table it survives a dropped link and is issued again after the
/// next `session/load`.
class FakeRequest {
  FakeRequest(this.method, this.params);

  final String method;
  final Json params;

  /// What the client answered; null until it did.
  Object? answer;
  bool answered = false;
  bool issued = false;
}

/// One session in an agent's own store ([FakeAgentHost.agentStore]): what the
/// agent keeps after its process (and the keeper around it) is gone.
class StoredSession {
  StoredSession({
    required this.agent,
    required this.cwd,
    required this.sessionId,
    this.title,
    DateTime? updatedAt,
    List<Json>? updates,
  }) : updatedAt = updatedAt ?? DateTime.utc(2026, 1, 1),
       updates = updates ?? [];

  final String agent;
  final String cwd;
  final String sessionId;
  final String? title;
  final DateTime updatedAt;

  /// The `session/update` payloads `session/load` replays, in order.
  List<Json> updates;

  /// User and agent messages, as omp counts them (`_meta.messageCount`).
  int get messageCount => updates
      .where((u) => u['sessionUpdate'] == 'user_message_chunk' || u['sessionUpdate'] == 'agent_message_chunk')
      .length;
}

/// One keeper of a [FakeAgentHost]: a scripted agent that stays alive when the
/// phone's link drops. It keeps the updates it sent (replayed on
/// `session/load`) and the requests nobody answered.
class FakeKeeper {
  FakeKeeper(this.host, this.info);

  final FakeAgentHost host;
  KeeperInfo info;

  /// Every `session/update` the agent sent, in order; `session/load` replays
  /// them.
  final log = <Json>[];
  final requests = <FakeRequest>[];
  final prompts = <String>[];
  final modes = <String>[];
  final _agents = <FakeAgent>[];
  var newCount = 0;
  var loadCount = 0;

  /// `session/resume` calls: the session is taken (as by a load) without a replay.
  var resumeCount = 0;

  /// A turn runs on the keeper without a prompt of this phone's (started from
  /// another device): what `list` reports as `turnActive` besides [turn].
  bool busy = false;

  /// A turn ended while no client was attached; `session/load` clears it, as
  /// the real keeper does.
  bool unseenDone = false;

  /// The keeper's last sign of life, by the host's clock (ranks which
  /// sessions deserve a channel).
  DateTime? lastEventAt;

  /// A prompt is in flight right now.
  bool get turnActive => busy || turn != null;

  /// A channel to this keeper is open (loaded or not).
  bool get linkOpen => _agent != null && !_agent!.rpc.isClosed;

  /// The ACP session id, once a client created one.
  String? sessionId;

  /// While set, a prompt waits for it and ends with the stop reason it
  /// completes with.
  Completer<String>? turn;

  /// What a prompt does instead of the default (an agent message, `end_turn`).
  FutureOr<Object?> Function(String text)? onPrompt;

  /// The agent's `initialize` answer (omp's by default; see
  /// `claudeInitialize` / `codexInitialize` in `acp/support/fake_agent.dart`).
  Json Function() initialize = ompInitialize;

  /// `_session/steering` requests (the params), and what the agent answers:
  /// `{outcome: injected}` by default, or what [onSteer] returns or throws.
  final steers = <Map<String, Object?>>[];
  FutureOr<Object?> Function(Map<String, Object?> params)? onSteer;

  /// The blocks of every prompt (the raw JSON), parallel to [prompts].
  final promptBlocks = <List<Object?>>[];

  /// Prompts being answered right now, and the most there ever were at once:
  /// the app must never have two in flight.
  var promptsInFlight = 0;
  var maxPromptsInFlight = 0;

  /// While set, `session/load` pauses after [loadSplit] lines of the log until
  /// it completes (a long replay over a slow link).
  Completer<void>? loadGate;
  int loadSplit = 0;

  /// Makes `session/new` fail with this (an `auth_required`, say).
  JsonRpcException? newFailure;

  /// What the keeper's log gave up, as the real one reports it in the answer
  /// to `session/load` (`_meta.herdr`). A test that cuts the start off [log]
  /// sets it to match.
  int droppedTurns = 0;
  int trimmedTurns = 0;

  MemoryLink? _link;
  FakeAgent? _agent;

  /// A client is attached and has finished loading.
  bool get attached => _agent != null && !_agent!.rpc.isClosed && _loaded;
  bool _loaded = false;

  /// The answers the client gave, in order.
  List<Object?> get answers => [
        for (final r in requests)
          if (r.answered) r.answer,
      ];

  void update(Json update) {
    log.add(update);
    final id = sessionId;
    if (attached && id != null) _agent!.update(id, update);
  }

  void say(String text, {String messageId = 'a1'}) => update(agentChunk(text, messageId: messageId));

  /// The agent asks to run [command]. Returns the request, to read its answer.
  FakeRequest askPermission({String command = 'npm test', String toolCallId = 't1'}) {
    final r = FakeRequest('session/request_permission', {
      'toolCall': {
        'toolCallId': toolCallId,
        'title': 'Run $command',
        'kind': 'execute',
        'rawInput': {'command': command},
      },
      'options': [
        {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
        {'optionId': 'always', 'name': 'Always allow', 'kind': 'allow_always'},
        {'optionId': 'deny', 'name': 'Deny', 'kind': 'reject_once'},
      ],
    });
    requests.add(r);
    _issue(r);
    return r;
  }

  /// The agent asks a question (a form with one choice).
  FakeRequest askQuestion({String message = 'Which approach?'}) {
    final r = FakeRequest('elicitation/create', {
      'mode': 'form',
      'message': message,
      'requestedSchema': {
        'type': 'object',
        'properties': {
          'approach': {
            'type': 'string',
            'enum': ['safe', 'fast'],
          },
        },
        'required': ['approach'],
      },
    });
    requests.add(r);
    _issue(r);
    return r;
  }

  /// Ends the turn a prompt is waiting on (see [turn]). With no client
  /// attached nobody sees it end: [unseenDone].
  void finishTurn([String stopReason = 'end_turn']) {
    final t = turn;
    turn = null;
    busy = false;
    if (!attached) unseenDone = true;
    if (t != null && !t.isCompleted) t.complete(stopReason);
  }

  void _issue(FakeRequest r) {
    final id = sessionId;
    final agent = _agent;
    if (!attached || id == null || agent == null || r.issued || r.answered) return;
    r.issued = true;
    agent.ask(r.method, {'sessionId': id, ...r.params}).response.then<void>(
      (result) {
        r.answered = true;
        r.answer = result;
      },
      // The link died before the answer: the request stays pending in the
      // keeper and goes out again after the next load.
      onError: (Object _) {
        r.issued = false;
      },
    );
  }

  void _issueWaiting() {
    for (final r in requests.toList()) {
      _issue(r);
    }
  }

  /// The phone's link drops (the SSH connection died); the keeper lives on.
  void dropLink() {
    _loaded = false;
    _link?.agent.close();
  }

  /// The client's side of the link reads EOF (the SSH channel died) while the
  /// keeper does not notice: its end stays open until another client attaches
  /// and evicts it.
  void halfDie() {
    _loaded = false;
    _link?.client.peerDied();
  }

  /// The agent process exits. An attached client is told (`_herdr/agent_exited`)
  /// before the link closes, as the real keeper does.
  void exit({int code = 1, String? reason}) {
    info = host._copy(info, state: KeeperState.exited, exitCode: code, exitReason: reason);
    if (attached) {
      _agent!.rpc.notify('_herdr/agent_exited', {'exitCode': code, 'reason': reason ?? ''});
    }
    dropLink();
  }

  /// A client attaches. One writer at a time: the one attached before is told
  /// (`_herdr/evicted`) and hung up on, like the real keeper does. A channel
  /// its owner already closed cannot be told, which is also what a half-dead
  /// SSH channel looks like to the app.
  MemoryLink attach() {
    final previous = _agent;
    if (previous != null && !previous.rpc.isClosed) {
      try {
        previous.rpc.notify('_herdr/evicted', {'reason': 'another client attached'});
      } on Object {
        // The old channel is dead on the client's side: the notice is lost.
      }
      _link?.agent.close();
    }
    final link = _link = MemoryLink();
    _loaded = false;
    final agent = _agent = FakeAgent(link.agent, {
      'initialize': (_) => initialize(),
      '_session/steering': (r) async {
        final params = Map<String, Object?>.from(r.params as Map);
        steers.add(params);
        final custom = onSteer;
        if (custom != null) return custom(params);
        return {'outcome': 'injected'};
      },
      'session/new': (_) {
        final failure = newFailure;
        if (failure != null) throw failure;
        newCount++;
        sessionId ??= 'sess-${info.id}';
        _remember();
        _loaded = true;
        unseenDone = false;
        scheduleMicrotask(_issueWaiting);
        return ompSessionNew(id: sessionId!);
      },
      'session/load': (r) async {
        final params = r.params as Map;
        if (params['sessionId'] != sessionId && !_adopt('${params['sessionId']}')) {
          throw const JsonRpcException(-32602, 'unknown session');
        }
        loadCount++;
        _loaded = true;
        unseenDone = false;
        final gate = loadGate;
        for (final (i, u) in log.indexed) {
          // A replay that takes its time: the first [loadSplit] lines, then a
          // wait for [loadGate], then the rest.
          if (gate != null && i == loadSplit) await gate.future;
          _agent!.update(sessionId!, u);
        }
        // The real keeper then says whether a turn is in flight.
        if (turnActive) _agent!.update(sessionId!, runningUpdate());
        scheduleMicrotask(_issueWaiting);
        return {
          ...ompSessionNew(id: sessionId!),
          '_meta': {
            'herdr': {'droppedTurns': droppedTurns, 'trimmedTurns': trimmedTurns},
          },
        };
      },
      'session/resume': (r) async {
        final params = r.params as Map;
        if (params['sessionId'] != sessionId && !_adopt('${params['sessionId']}')) {
          throw const JsonRpcException(-32602, 'unknown session');
        }
        resumeCount++;
        _loaded = true;
        unseenDone = false;
        scheduleMicrotask(_issueWaiting);
        return ompSessionNew(id: sessionId!);
      },
      'session/prompt': (r) async {
        final params = r.params as Map;
        final blocks = params['prompt'] as List;
        final text = [for (final b in blocks) (b as Map)['text'] ?? ''].join();
        prompts.add(text);
        promptBlocks.add(blocks);
        log.add(userChunk(text, messageId: 'keeper-${prompts.length}'));
        promptsInFlight++;
        if (promptsInFlight > maxPromptsInFlight) maxPromptsInFlight = promptsInFlight;
        try {
          final custom = onPrompt;
          if (custom != null) return await custom(text);
          final waiting = turn;
          if (waiting != null) return {'stopReason': await waiting.future};
          say('ok: $text', messageId: 'r${prompts.length}');
          return {'stopReason': 'end_turn'};
        } finally {
          promptsInFlight--;
        }
      },
      'session/set_mode': (r) {
        modes.add('${(r.params as Map)['modeId']}');
        return <String, Object?>{};
      },
      'session/set_config_option': (_) => <String, Object?>{},
    });
    _agents.add(agent);
    return link;
  }

  /// `session/cancel` notifications the client sent, over every link.
  int get cancelsReceived => _agents.fold(0, (n, a) => n + a.paramsOf('session/cancel').length);

  /// Records this keeper's session in the agent's store (sharing [log], so the
  /// store has every update). A no-op until the keeper has a session.
  void _remember() {
    final id = sessionId;
    if (id == null) return;
    host.agentStore.putIfAbsent(
      id,
      () => StoredSession(agent: info.agent, cwd: info.cwd, sessionId: id, title: info.title, updates: log),
    );
  }

  /// `session/load` of an id this keeper does not hold: when the keeper has
  /// no session yet and the agent's store holds [id] for this agent and
  /// folder, the keeper takes it over (its updates become the keeper's log,
  /// which the load then replays). False: the agent does not know it.
  bool _adopt(String id) {
    final stored = host.agentStore[id];
    if (sessionId != null || stored == null) return false;
    if (stored.agent != info.agent || stored.cwd != info.cwd) return false;
    log.addAll(stored.updates);
    stored.updates = log;
    sessionId = id;
    info = host._copy(info, sessionId: id, title: stored.title);
    return true;
  }
}

/// A scripted [AgentHost]: keepers that outlive a dropped link, installed
/// routes, and failures to inject.
///
/// Assumptions the tests of the app's sessions rest on:
/// - [FakeKeeper.attached] means "a client is attached and loaded"; it is read
///   from the agent side's `JsonRpcConnection.isClosed`, because closing the
///   client's end closes the agent's reader but not its `MemoryEnd.closed`.
///   The app's sessions hang up their transport synchronously when they let
///   go, so a test sees a released channel at once (a client's own `close()`
///   would complete only after a root-zone microtask, which `fakeAsync` never
///   runs).
/// - [openLinks] / [peakOpenLinks] count channels by the same flag, loaded or
///   not: the number the host's channel limit cares about.
/// - Attaching to an exited keeper throws a NON-fatal [AgentHostException]
///   (the app then asks `list` and ends the session with the keeper's reason).
///   The real keeper's answer for this case is not specified by the contract.
/// - Links are synchronous in-memory pairs, so a test on a fake clock needs only
///   `elapse` (the sessions' 16 ms notify timer) to see results.
///
/// History (what the agent remembers, `docs/AGENT_SESSIONS.md`): [agentStore]
/// holds every session an agent made and outlives [restart] and dropped
/// keepers; [history] answers [pastSessions] for an agent, else from the store;
/// a new keeper in the same folder and agent that is asked `session/load` for a
/// stored id takes the session over and replays it. [restart] simulates a host
/// reboot (every keeper `exited`, every channel dead).
class FakeAgentHost implements AgentHost {
  FakeAgentHost({Set<String>? installed, this.clock})
      : installed = installed ?? {for (final r in agentRoutes) r.id};

  /// Route ids [available] reports.
  Set<String> installed;

  /// Stamps [attachTimes] when a test drives time itself.
  final DateTime Function()? clock;

  final keepers = <String, FakeKeeper>{};

  /// Channels open now, and the most there ever were at once.
  int get openLinks => keepers.values.where((k) => k.linkOpen).length;
  int peakOpenLinks = 0;

  /// While set, [start] has made its keeper but waits for it before returning
  /// (a listing can find the keeper meanwhile).
  Completer<void>? startGate;

  /// When set, the `initialize` answer of every keeper [start] makes (a new
  /// keeper that advertises, say, no `loadSession`, or only `resume`; see
  /// `claudeInitialize` / `codexInitialize`). Keepers made by [add] keep omp's.
  Json Function()? startInitialize;

  AgentHostException? availableFailure;
  AgentHostException? listFailure;
  AgentHostException? startFailure;
  AgentHostException? killFailure;

  /// Failures the next attaches throw, one each, in order.
  final attachFailures = <AgentHostException>[];

  /// While set, [attach] waits for it.
  Completer<void>? attachGate;

  var availableCalls = 0;
  var listCalls = 0;
  var startCalls = 0;
  var attachCalls = 0;
  final attachTimes = <DateTime>[];
  final killed = <String>[];
  var _next = 0;

  /// A keeper that already exists (started from another device, or before
  /// this app run).
  FakeKeeper add({
    String agent = 'omp',
    String cwd = '/home/u/proj',
    String? title,
    KeeperState state = KeeperState.running,
    String? sessionId,
    int? exitCode,
    String? exitReason,
    String? id,
  }) {
    final keeperId = id ?? 'k${++_next}';
    final keeper = FakeKeeper(
      this,
      KeeperInfo(
        id: keeperId,
        agent: agent,
        cwd: cwd,
        state: state,
        startedAt: DateTime.utc(2026, 1, 1),
        sessionId: sessionId,
        title: title,
        exitCode: exitCode,
        exitReason: exitReason,
      ),
    )..sessionId = sessionId;
    if (sessionId != null) keeper._remember();
    keepers[keeperId] = keeper;
    return keeper;
  }

  KeeperInfo _copy(
    KeeperInfo i, {
    KeeperState? state,
    int? exitCode,
    String? exitReason,
    String? sessionId,
    String? title,
    int? pending,
    bool? turnActive,
    bool? unseenDone,
    DateTime? lastEventAt,
  }) =>
      KeeperInfo(
        id: i.id,
        agent: i.agent,
        cwd: i.cwd,
        state: state ?? i.state,
        startedAt: i.startedAt,
        pid: i.pid,
        exitCode: exitCode ?? i.exitCode,
        sessionId: sessionId ?? i.sessionId,
        title: title ?? i.title,
        pending: pending ?? i.pending,
        turnActive: turnActive ?? i.turnActive,
        unseenDone: unseenDone ?? i.unseenDone,
        lastEventAt: lastEventAt ?? i.lastEventAt,
        exitReason: exitReason ?? i.exitReason,
      );

  @override
  Future<Set<String>> available() async {
    availableCalls++;
    if (availableFailure case final f?) throw f;
    return {...installed};
  }

  @override
  Future<List<KeeperInfo>> list() async {
    listCalls++;
    if (listFailure case final f?) throw f;
    return [
      for (final k in keepers.values)
        _copy(
          k.info,
          sessionId: k.sessionId,
          pending: k.requests.where((r) => !r.answered).length,
          turnActive: k.turnActive,
          unseenDone: k.unseenDone,
          lastEventAt: k.lastEventAt,
        ),
    ];
  }

  @override
  Future<KeeperInfo> start({required String agent, required String cwd}) async {
    startCalls++;
    if (startFailure case final f?) throw f;
    if (!installed.contains(agent)) {
      throw AgentHostException('$agent is not installed.', fatal: true);
    }
    final keeper = add(agent: agent, cwd: cwd);
    if (startInitialize case final init?) keeper.initialize = init;
    if (startGate case final gate?) await gate.future;
    return keeper.info;
  }

  @override
  Future<AcpTransport> attach(String keeperId) async {
    attachCalls++;
    if (clock != null) attachTimes.add(clock!());
    if (attachGate case final gate?) await gate.future;
    if (attachFailures.isNotEmpty) throw attachFailures.removeAt(0);
    final keeper = keepers[keeperId];
    if (keeper == null) throw const AgentHostException('There is no such keeper.', fatal: true);
    if (keeper.info.state == KeeperState.exited) throw const AgentHostException('The keeper has exited.');
    final link = keeper.attach().client;
    final open = openLinks;
    if (open > peakOpenLinks) peakOpenLinks = open;
    return link;
  }

  @override
  Future<void> kill(String keeperId) async {
    killed.add(keeperId);
    if (killFailure case final f?) throw f;
    final keeper = keepers[keeperId];
    if (keeper == null) return;
    // The real `kill` forgets a record of any state; an ended one only goes.
    if (keeper.info.state == KeeperState.exited) {
      keepers.remove(keeperId);
      return;
    }
    keeper.exit(code: 0, reason: 'Ended on request.');
  }

  // -- what the agent remembers (history) -----------------------------------

  /// The agents' own stores: every session a keeper's agent made (a live
  /// keeper's updates are in it as they happen, by sharing its log), keyed by
  /// session id. It survives [restart] and a keeper being dropped from
  /// [keepers]: a NEW keeper started in the same folder for the same agent and
  /// asked `session/load` for a stored id replays that session (as the real
  /// agent does, which is how a thread comes back after the host rebooted).
  /// Seed one with [remember].
  final agentStore = <String, StoredSession>{};

  /// Puts a session in the agent's store without a keeper (it was made before
  /// this app run, on another device, ...).
  StoredSession remember({
    String agent = 'omp',
    String cwd = '/home/u/proj',
    required String sessionId,
    String? title,
    DateTime? updatedAt,
    List<Json> updates = const [],
  }) => agentStore[sessionId] = StoredSession(
    agent: agent,
    cwd: cwd,
    sessionId: sessionId,
    title: title,
    updatedAt: updatedAt,
    updates: [...updates],
  );

  /// What [history] answers for an agent, as is (cwd ignored; [historyRequests]
  /// has what was asked). An agent without an entry answers from [agentStore]
  /// (its sessions, for the folder asked, newest first; list, load and resume
  /// supported).
  final pastSessions = <String, PastSessions>{};

  /// Makes [history] throw this.
  AgentHostException? historyFailure;

  /// The `(agent, cwd)` of every [history] call.
  final historyRequests = <({String agent, String? cwd})>[];

  @override
  Future<PastSessions> history({required String agent, String? cwd}) async {
    historyRequests.add((agent: agent, cwd: cwd));
    if (historyFailure case final f?) throw f;
    if (!installed.contains(agent)) {
      throw AgentHostException('$agent is not installed on the machine.', fatal: true);
    }
    if (pastSessions[agent] case final answer?) return answer;
    final mine = [
      for (final s in agentStore.values)
        if (s.agent == agent && (cwd == null || s.cwd == cwd)) s,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return PastSessions(
      agent: agent,
      canLoad: true,
      canResume: true,
      sessions: [
        for (final s in mine)
          PastSession(
            agent: agent,
            sessionId: s.sessionId,
            cwd: s.cwd,
            title: s.title,
            updatedAt: s.updatedAt,
            messageCount: s.messageCount,
          ),
      ],
    );
  }

  /// The host restarted (or the keepers were killed): every running keeper is
  /// `exited` with the reason the real `list` gives for a vanished keeper, and
  /// every channel to it is dead without a word (`_herdr/agent_exited` needs a
  /// live keeper). The turns in flight died with the agents. [agentStore]
  /// stays.
  void restart() {
    for (final k in keepers.values) {
      if (k.info.state == KeeperState.exited) continue;
      k.info = _copy(
        k.info,
        state: KeeperState.exited,
        exitReason: 'The keeper process is gone (killed, or the host restarted).',
      );
      k.turn = null;
      k.busy = false;
      k.requests.clear();
      k.dropLink();
    }
  }
}
