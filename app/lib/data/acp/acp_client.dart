import 'dart:async';

import 'acp_models.dart';
import 'json_rpc.dart';
import 'session_state.dart';

/// What the app decides for the agent. There is no default implementation on
/// purpose: nothing may answer a permission request unless a person (or a
/// policy the user set) did.
abstract interface class AcpClientHandler {
  /// The agent asks to run a tool. Return the user's choice; the returned
  /// option must be one of [request]'s. [cancelled] completes when the answer
  /// no longer matters (the turn was cancelled or the agent withdrew the
  /// request): the client then answers `cancelled` itself and drops what this
  /// returns.
  Future<PermissionOutcome> requestPermission(PermissionRequest request, Future<void> cancelled);

  /// The agent asks the user a question (a form). Same contract for
  /// [cancelled]. Only `mode: form` requests arrive; others are refused
  /// before they get here.
  Future<ElicitationResponse> elicit(ElicitationRequest request, Future<void> cancelled);
}

/// The agent or the caller broke a rule of the protocol (a version we do not
/// speak, a capability that was not offered, a second prompt in one session).
class AcpProtocolException implements Exception {
  const AcpProtocolException(this.message);

  final String message;

  @override
  String toString() => 'AcpProtocolException($message)';
}

/// ACP's `sessionBusy` (`-32003`, omp): a prompt arrived while the agent runs
/// a turn of its own (a background job, a finished subagent) that no prompt of
/// ours started. The prompt was not taken.
const acpSessionBusy = -32003;

/// The agent refused a prompt because it is busy with its own work
/// ([acpSessionBusy]). Nothing was taken: the client has taken the message's
/// row and the running turn back out of the state (whatever the agent streamed
/// meanwhile stays), so the caller keeps the text and sends it later.
class AcpSessionBusyException implements Exception {
  const AcpSessionBusyException(this.message);

  final String message;

  @override
  String toString() => 'AcpSessionBusyException($message)';
}

/// What the agent did with a message sent to the turn that runs
/// (`_session/steering`).
enum SteerOutcome {
  /// It joined the running turn.
  injected,

  /// No turn was running any more (it ended while the message was on its
  /// way): the agent started one for it, detached from any `session/prompt`.
  /// No answer to a prompt will come for that turn; its updates just arrive.
  startedNewTurn,

  /// Claude Code, asked with `idleBehavior: promptRequired`: no turn runs and
  /// nothing was done; the caller sends an ordinary prompt.
  promptRequired,

  /// Codex could not apply it, or an answer this client does not know.
  failed;

  static SteerOutcome parse(Object? v) => switch (v) {
    'injected' => injected,
    'startedNewTurn' => startedNewTurn,
    'promptRequired' => promptRequired,
    _ => failed,
  };
}

/// A session's state changed.
class SessionChange {
  const SessionChange(this.sessionId, this.state);

  final String sessionId;
  final AgentSessionState state;
}

/// The one place the params of a `session/update` notification become a new
/// state: the live client folds every notification through it, and the
/// transcript cache folds the lines it stored through it, so a cached
/// transcript is parsed and reduced exactly as a replay from the keeper is.
/// [at] stamps the new items (null for history).
AgentSessionState applyUpdateParams(AgentSessionState state, Map<Object?, Object?> params, {DateTime? at}) =>
    state.apply(SessionUpdate.parse(params['update']), at: at);

/// An ACP client over one [AcpTransport]: one agent process, any number of
/// sessions.
///
/// Updates fold into an [AgentSessionState] per session ([state], [changes]).
/// The client advertises neither `fs/*` nor `terminal/*`; those requests, and
/// anything else it does not know, are answered `-32601`.
class AcpClient {
  AcpClient(
    AcpTransport transport, {
    required this._handler,
    this.clientInfo = const AcpImplementation(name: 'herdr-mobile', title: 'herdr mobile', version: '0'),
    this.capabilities = const AcpClientCapabilities(),
    this.requestTimeout = const Duration(seconds: 60),
    this.loadTimeout = const Duration(minutes: 3),
    this._onProblem,
    this._onExtension,
    this._clock = DateTime.now,
    this._onUpdateLine,
    this._onSetup,
    this._onLocalUser,
    this._onLocalUserTaken,
  }) {
    _rpc = JsonRpcConnection(
      transport,
      onRequest: _onRequest,
      onNotification: _onNotification,
      onNotificationLine: _onUpdateLine == null
          ? null
          : (method, line) {
              if (method == 'session/update') _onUpdateLine(line);
            },
      onProblem: (message, {line}) => _onProblem?.call(line == null ? message : '$message: $line'),
      defaultTimeout: requestTimeout,
    );
    _rpc.done.then((_) => _disconnected());
  }

  final AcpClientHandler _handler;

  /// Stamps [AgentSessionState.lastActivityAt] and [PendingQuestion.receivedAt].
  final DateTime Function() _clock;
  final void Function(String message)? _onProblem;

  /// Told of every notification the client does not handle itself (anything
  /// but `session/update`): extension methods such as a keeper's
  /// `_herdr/evicted`.
  final void Function(String method, Object? params)? _onExtension;

  /// The raw text of every `session/update` notification, as it arrived: what
  /// a caller that keeps the log of a session (the transcript cache) stores.
  final void Function(String line)? _onUpdateLine;

  /// The agent's answer to `session/new`, `session/load` or `session/resume`,
  /// as it arrived.
  final void Function(String sessionId, Object? result)? _onSetup;

  /// The user's own message was added to the state locally (a prompt, or a
  /// steer): no `session/update` carries it on this connection, so a caller
  /// that keeps a log needs to be told.
  final void Function(String sessionId, List<ContentBlock> content)? _onLocalUser;

  /// The message [_onLocalUser] told of was taken back (the agent was busy).
  final void Function(String sessionId)? _onLocalUserTaken;
  late final JsonRpcConnection _rpc;
  final AcpImplementation clientInfo;
  final AcpClientCapabilities capabilities;

  /// For everything but a prompt (which lasts as long as the agent works).
  final Duration requestTimeout;

  /// For `session/load` and `session/resume`, which can replay a long history.
  final Duration loadTimeout;

  final _states = <String, AgentSessionState>{};
  final _changes = StreamController<SessionChange>.broadcast();
  final _aborts = <String, Set<Completer<void>>>{};
  final _cancelling = <String>{};
  AcpInitializeResult? _agent;

  /// The agent's answer to `initialize`; null before it.
  AcpInitializeResult? get agent => _agent;

  /// The agent accepts `_session/steering`: a message into the turn that
  /// runs. Advertised in `initialize._meta.steering.supported` (Claude Code
  /// and Codex; omp and pi do not have it).
  bool get canSteer {
    final meta = _agent?.raw['_meta'];
    final steering = meta is Map ? meta['steering'] : null;
    return steering is Map && steering['supported'] == true;
  }

  /// Every state change of every session, in order.
  Stream<SessionChange> get changes => _changes.stream;

  /// Completes when the connection ended (agent exit, EOF, [close]).
  Future<void> get closed => _rpc.done;

  /// The state of [sessionId] (an empty one for a session never seen).
  AgentSessionState state(String sessionId) => _states[sessionId] ?? AgentSessionState(sessionId);

  AgentSessionState _update(String sessionId, AgentSessionState Function(AgentSessionState s) f) {
    final before = state(sessionId);
    final after = f(before);
    _states[sessionId] = after;
    if (!identical(before, after) && !_changes.isClosed) _changes.add(SessionChange(sessionId, after));
    return after;
  }

  void _disconnected() {
    for (final id in _states.keys.toList()) {
      _update(id, (s) => s.withDisconnected());
    }
    for (final set in _aborts.values) {
      for (final c in set.toList()) {
        if (!c.isCompleted) c.complete();
      }
    }
  }

  // -- the agent's methods ----------------------------------------------------

  /// Negotiates the protocol. Throws [AcpProtocolException] when the agent
  /// does not answer with version 1 (v2 is a draft this client does not speak).
  Future<AcpInitializeResult> initialize() async {
    final result = AcpInitializeResult.parse(
      await _rpc.request('initialize', {
        'protocolVersion': acpProtocolVersion,
        'clientCapabilities': capabilities.toJson(),
        'clientInfo': clientInfo.toJson(),
      }),
    );
    if (result.protocolVersion != acpProtocolVersion) {
      throw AcpProtocolException('agent speaks ACP v${result.protocolVersion}, this client v$acpProtocolVersion');
    }
    return _agent = result;
  }

  /// Runs an agent-handled authentication method (one of
  /// [AcpInitializeResult.authMethods] with no `type`).
  Future<void> authenticate(String methodId) async {
    await _rpc.request('authenticate', {'methodId': methodId});
  }

  /// Starts a session in [cwd] (an absolute path on the agent's host). [meta]
  /// is the request's `_meta` (an agent's own session options, such as Claude
  /// Code's `claudeCode.emitRawSDKMessages`).
  Future<AgentSessionState> newSession({required String cwd, List<Json> mcpServers = const [], Json? meta}) async {
    final raw = await _rpc.request('session/new', {'cwd': cwd, 'mcpServers': mcpServers, '_meta': ?meta});
    final setup = AcpSessionSetup.parse(raw);
    if (setup.sessionId case final id? when id.isNotEmpty) _onSetup?.call(id, raw);
    final id = setup.sessionId;
    if (id == null || id.isEmpty) throw const AcpProtocolException('session/new answered without a sessionId');
    return _update(id, (s) => s.withSetup(setup));
  }

  /// Reopens [sessionId] and lets the agent replay the conversation into the
  /// state (`session/load`). The state is emptied first, so the replay
  /// rebuilds it. [merge] gets the state once the replay is whole (and the
  /// answer to the load is in) and returns the state to keep: the owner of a
  /// transcript shown meanwhile puts back what the replay is shorter by
  /// ([AgentSessionState.withHeld]).
  Future<AgentSessionState> loadSession(
    String sessionId, {
    required String cwd,
    List<Json> mcpServers = const [],
    AgentSessionState Function(AgentSessionState replayed)? merge,
    Json? meta,
  }) async {
    _require(_agent?.capabilities.loadSession ?? false, 'session/load');
    _states[sessionId] = AgentSessionState(sessionId, replaying: true);
    final raw = await _rpc.request('session/load', {
      'sessionId': sessionId,
      'cwd': cwd,
      'mcpServers': mcpServers,
      '_meta': ?meta,
    }, loadTimeout);
    _onSetup?.call(sessionId, raw);
    final setup = AcpSessionSetup.parse(raw);
    return _update(sessionId, (s) {
      final replayed = s.withSetup(setup);
      return merge == null ? replayed : merge(replayed);
    });
  }

  /// Reopens [sessionId] without replaying the conversation
  /// (`session/resume`). The state starts empty; [merge] gets it once the
  /// answer is in and returns the state to keep (the owner of a transcript
  /// shown meanwhile puts it back, see [loadSession]).
  Future<AgentSessionState> resumeSession(
    String sessionId, {
    required String cwd,
    List<Json> mcpServers = const [],
    AgentSessionState Function(AgentSessionState resumed)? merge,
    Json? meta,
  }) async {
    _require(_agent?.capabilities.canResume ?? false, 'session/resume');
    final raw = await _rpc.request('session/resume', {
      'sessionId': sessionId,
      'cwd': cwd,
      'mcpServers': mcpServers,
      '_meta': ?meta,
    }, loadTimeout);
    _onSetup?.call(sessionId, raw);
    final setup = AcpSessionSetup.parse(raw);
    return _update(sessionId, (s) {
      final resumed = s.withSetup(setup);
      return merge == null ? resumed : merge(resumed);
    });
  }

  Future<AcpSessionPage> listSessions({String? cwd, String? cursor}) async {
    _require(_agent?.capabilities.canList ?? false, 'session/list');
    return AcpSessionPage.parse(await _rpc.request('session/list', {'cwd': ?cwd, 'cursor': ?cursor}));
  }

  /// Sends [content] and completes with the stop reason when the turn ends.
  /// What the agent does meanwhile streams into [state]. A turn cancelled
  /// with [cancel] completes normally with [StopReason.cancelled], even when
  /// the agent reports the cancellation as an error. There is no timeout.
  ///
  /// One prompt at a time per session: while a turn runs this throws
  /// [AcpProtocolException] (the caller queues the message, or [steer]s it).
  /// omp would not queue it but cancel the running turn
  /// (`oh-my-pi/.../acp/acp-agent.ts:803`), and pi-acp queues it where the
  /// phone cannot show or edit it.
  ///
  /// Throws [AcpSessionBusyException] when the agent says it is busy with its
  /// own work ([acpSessionBusy]).
  Future<PromptResult> prompt(String sessionId, List<ContentBlock> content) async {
    _checkContent(content);
    if (state(sessionId).turnActive) throw const AcpProtocolException('a prompt is already running in this session');
    final before = state(sessionId);
    final rowKey = 'm${before.nextKey}';
    _update(sessionId, (s) => s.withUserMessage(content, at: _clock()).withTurnStarted());
    _onLocalUser?.call(sessionId, content);
    try {
      final result = PromptResult.parse(
        await _rpc.request('session/prompt', {
          'sessionId': sessionId,
          'prompt': [for (final b in content) b.toJson()],
        }, Duration.zero),
      );
      _update(sessionId, (s) => s.withTurnEnded(result.stopReason, usage: result.usage, meta: result.meta, at: _clock()));
      return result;
    } on Object catch (e) {
      final wasCancelled = _cancelling.contains(sessionId) && e is JsonRpcException;
      if (e is JsonRpcException && e.code == acpSessionBusy && !wasCancelled) {
        // Nothing was taken: the message's row and turn go back out of the
        // state, even when the agent's own turn streamed meanwhile.
        _update(sessionId, (s) => s.withoutUserMessage(rowKey, before: before));
        _onLocalUserTaken?.call(sessionId);
        throw AcpSessionBusyException(e.message);
      }
      final reason = wasCancelled ? StopReason.cancelled : StopReason.error;
      _update(sessionId, (s) => s.withTurnEnded(reason, at: _clock()));
      if (wasCancelled) return const PromptResult(StopReason.cancelled);
      rethrow;
    } finally {
      _cancelling.remove(sessionId);
    }
  }

  /// Sends [content] into the turn that runs (`_session/steering`) and says
  /// what the agent did with it. The agent must advertise it ([canSteer]).
  ///
  /// Shape (Claude Code `acp-agent.ts:566`, Codex `AcpExtensions.ts:122`):
  /// params `{sessionId, prompt: ContentBlock[]}`, answer
  /// `{outcome: injected | startedNewTurn | failed}`. Claude Code is also
  /// asked, in `_meta.steering.idleBehavior`, to answer `promptRequired`
  /// instead of starting a turn of its own when none runs any more (a turn
  /// started that way is detached: nothing would ever tell this client it
  /// ended); Codex has no such option and ignores the field.
  ///
  /// The message's row joins the transcript on [SteerOutcome.injected] and
  /// [SteerOutcome.startedNewTurn], and when the answer is lost (a dropped
  /// link or a timeout: the message may have arrived), so it is not missing
  /// from the person's view. A refusal ([JsonRpcException], for example
  /// Codex's "The current model does not support image input") adds nothing
  /// and is rethrown; so are the lost answers, after the row is added.
  Future<SteerOutcome> steer(String sessionId, List<ContentBlock> content) async {
    if (!canSteer) throw const AcpProtocolException('the agent does not take messages during a turn');
    _checkContent(content);
    final Object? answer;
    try {
      answer = await _rpc.request('_session/steering', {
        'sessionId': sessionId,
        'prompt': [for (final b in content) b.toJson()],
        if (_steersWithFallback)
          '_meta': {
            'steering': {'idleBehavior': 'promptRequired'},
          },
      });
    } on JsonRpcException {
      rethrow;
    } on Object {
      _update(sessionId, (s) => s.withUserMessage(content, at: _clock()));
      _onLocalUser?.call(sessionId, content);
      rethrow;
    }
    final outcome = SteerOutcome.parse(answer is Map ? answer['outcome'] : null);
    if (outcome == SteerOutcome.injected || outcome == SteerOutcome.startedNewTurn) {
      _update(sessionId, (s) => s.withUserMessage(content, at: _clock()));
      _onLocalUser?.call(sessionId, content);
    }
    return outcome;
  }

  /// Claude Code (it marks its capabilities with `_meta.claudeCode`) is the
  /// agent that understands `idleBehavior: promptRequired`.
  bool get _steersWithFallback {
    final meta = _agent?.capabilities.raw['_meta'];
    return meta is Map && meta['claudeCode'] is Map;
  }

  /// Stops the background task [asyncTaskId] (`_session/async_task/stop`,
  /// Codex and Claude Code with `asyncTasks`): true when the agent stopped it,
  /// false when it did not (unknown, already finished, already stopping) or
  /// does not have the method (`-32601`). Other errors are thrown.
  Future<bool> stopAsyncTask(String sessionId, String asyncTaskId) async {
    final Object? answer;
    try {
      answer = await _rpc.request('_session/async_task/stop', {'sessionId': sessionId, 'asyncTaskId': asyncTaskId});
    } on JsonRpcException catch (e) {
      if (e.code == JsonRpcCode.methodNotFound) return false;
      rethrow;
    }
    return answer is Map && answer['stopped'] == true;
  }

  void _checkContent(List<ContentBlock> content) {
    final caps = _agent?.capabilities;
    if (caps == null) return;
    for (final b in content) {
      if (b is ImageBlock && !caps.image) throw const AcpProtocolException('the agent does not take images');
      if (b is AudioBlock && !caps.audio) throw const AcpProtocolException('the agent does not take audio');
      if (b is EmbeddedResourceBlock && !caps.embeddedContext) {
        throw const AcpProtocolException('the agent does not take embedded context');
      }
    }
  }

  /// Stops the running turn: sends `session/cancel`, marks unfinished tool
  /// calls cancelled and answers every request the agent is waiting on in
  /// this session as cancelled. [prompt] completes when the agent says so.
  /// Does nothing when the connection is gone.
  void cancel(String sessionId) {
    _cancelling.add(sessionId);
    _update(sessionId, (s) => s.withCancelRequested(at: _clock()));
    try {
      _rpc.notify('session/cancel', {'sessionId': sessionId});
    } on JsonRpcClosedException {
      _cancelling.remove(sessionId);
    }
    _abort(sessionId);
  }

  /// Asks for mode [modeId]. The person's own request: the agent's report of
  /// the change (before or after its answer) writes no transcript note.
  Future<void> setMode(String sessionId, String modeId) async {
    _update(sessionId, (s) => s.withExpectedMode(modeId));
    try {
      await _rpc.request('session/set_mode', {'sessionId': sessionId, 'modeId': modeId});
      _update(sessionId, (s) => s.apply(ModeUpdate(modeId)));
    } finally {
      _update(sessionId, (s) => s.withExpectedMode(null));
    }
  }

  /// Sets a config option: a `String` for a select, a `bool` for a toggle.
  /// The agent's answer (the full option list) replaces the state's. Like
  /// [setMode], a change of the mode option writes no transcript note.
  Future<void> setConfigOption(String sessionId, String configId, Object value) async {
    _update(sessionId, (s) => s.withExpectedConfig(configId, value));
    try {
      final result = await _rpc.request('session/set_config_option', {
        'sessionId': sessionId,
        'configId': configId,
        'value': value,
        if (value is bool) 'type': 'boolean',
      });
      final options = parseConfigOptions(result is Map ? result['configOptions'] : null);
      _update(
        sessionId,
        (s) => s.withConfigOptions(
          options.isNotEmpty ? options : [for (final o in s.configOptions) o.id == configId ? o.withValue(value) : o],
        ),
      );
    } finally {
      _update(sessionId, (s) => s.withExpectedMode(null));
    }
  }

  /// Ends [sessionId] on the agent and forgets its state.
  Future<void> closeSession(String sessionId) async {
    _require(_agent?.capabilities.canClose ?? false, 'session/close');
    _abort(sessionId);
    await _rpc.request('session/close', {'sessionId': sessionId});
    _states.remove(sessionId);
  }

  /// Closes the transport (the agent sees EOF on its stdin) and releases the
  /// streams.
  Future<void> close() async {
    await _rpc.close();
    if (!_changes.isClosed) await _changes.close();
  }

  void _require(bool supported, String method) {
    if (!supported) throw AcpProtocolException('the agent does not offer $method');
  }

  // -- the agent's requests and notifications ---------------------------------

  /// Answers every waiting request of [sessionId] as cancelled.
  void _abort(String sessionId) {
    for (final c in (_aborts[sessionId] ?? const <Completer<void>>{}).toList()) {
      if (!c.isCompleted) c.complete();
    }
  }

  Future<Object?> _onRequest(IncomingRequest r) {
    switch (r.method) {
      case 'session/request_permission':
        return _permission(r);
      case 'elicitation/create':
        return _elicitation(r);
      default:
        // fs/*, terminal/* (never offered) and anything newer.
        throw JsonRpcException.methodNotFound(r.method);
    }
  }

  /// A completer that fires when the request is withdrawn, the session's
  /// turn is cancelled or the connection ends.
  Completer<void> _watch(IncomingRequest r, String? sessionId) {
    final abort = Completer<void>();
    if (sessionId != null) (_aborts[sessionId] ??= {}).add(abort);
    r.cancelled.then((_) {
      if (!abort.isCompleted) abort.complete();
    });
    return abort;
  }

  void _unwatch(String? sessionId, Completer<void> abort) {
    if (sessionId == null) return;
    final set = _aborts[sessionId];
    set?.remove(abort);
    if (set != null && set.isEmpty) _aborts.remove(sessionId);
  }

  Future<Object?> _permission(IncomingRequest r) async {
    final request = PermissionRequest.parse(r.params);
    if (request.sessionId.isEmpty || request.options.isEmpty) {
      throw const JsonRpcException.invalidParams('session/request_permission needs a sessionId and options');
    }
    final sid = request.sessionId;
    final abort = _watch(r, sid);
    _update(sid, (s) => s.withPending(PendingPermission(r.id, request)));
    try {
      final outcome = await Future.any<PermissionOutcome>([
        _handler.requestPermission(request, abort.future),
        abort.future.then((_) => const PermissionCancelled()),
      ]);
      if (outcome is PermissionSelected && !request.hasOption(outcome.optionId)) {
        // A handler bug, never a reason to allow anything: cancel.
        _onProblem?.call('handler chose option ${outcome.optionId}, which the request did not offer');
        return const PermissionCancelled().toJson();
      }
      return outcome.toJson();
    } finally {
      _unwatch(sid, abort);
      _update(sid, (s) => s.withoutPending(r.id));
    }
  }

  Future<Object?> _elicitation(IncomingRequest r) async {
    final request = ElicitationRequest.parse(r.params);
    if (request.mode != 'form' || request.schema == null || !capabilities.elicitationForm) {
      // The spec's answer to a mode the client did not advertise.
      throw JsonRpcException.invalidParams('elicitation mode "${request.mode}" is not supported');
    }
    final sid = request.sessionId;
    final abort = _watch(r, sid);
    if (sid != null) _update(sid, (s) => s.withPending(PendingQuestion(r.id, request, receivedAt: _clock())));
    try {
      final response = await Future.any<ElicitationResponse>([
        _handler.elicit(request, abort.future),
        abort.future.then((_) => const ElicitationCancel()),
      ]);
      return response.toJson();
    } finally {
      _unwatch(sid, abort);
      if (sid != null) _update(sid, (s) => s.withoutPending(r.id));
    }
  }

  void _onNotification(String method, Object? params) {
    if (method == '_claude/sdkMessage') {
      _onSdkMessage(params);
      return;
    }
    if (method != 'session/update') {
      _onExtension?.call(method, params);
      return;
    }
    final p = params is Map ? params : const {};
    final sid = p['sessionId'];
    if (sid is! String || sid.isEmpty) {
      _onProblem?.call('session/update without a sessionId');
      return;
    }
    _update(sid, (s) => applyUpdateParams(s, p, at: _clock()));
  }

  /// Claude Code's raw SDK messages, which a session gets with
  /// `_meta.claudeCode.emitRawSDKMessages`: the ones the state reads become
  /// updates; the rest are not asked for and are dropped.
  void _onSdkMessage(Object? params) {
    final p = params is Map ? params : const {};
    final sid = p['sessionId'];
    final update = SessionUpdate.fromClaudeSdkMessage(p['message']);
    if (sid is! String || sid.isEmpty || update == null) return;
    _update(sid, (s) => s.apply(update, at: _clock()));
  }
}
