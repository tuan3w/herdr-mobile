import 'json_rpc.dart' show AcpTransport;
import 'past_session.dart';

/// An agent the phone can start as an ACP server on a host, and how.
///
/// The host runs [binary] with [args] in the session's folder; it speaks ACP on
/// stdio. When [binary] is not installed and [npxPackage] is set, the host runs
/// `npx -y <npxPackage>` instead. Routes are in `docs/AGENT_SESSIONS.md`.
class AgentRoute {
  const AgentRoute({
    required this.id,
    required this.label,
    required this.binary,
    this.args = const [],
    this.npxPackage,
    this.airCapabilities = const [],
    this.sessionMeta,
  });

  /// Stable, lower case: `omp`, `claude`, `codex`, `pi`.
  final String id;

  /// What the person reads: `Claude Code`.
  final String label;

  final String binary;
  final List<String> args;
  final String? npxPackage;

  /// What the keeper declares to this agent as
  /// `clientCapabilities._meta.jetbrains.air.capabilities`. Empty: nothing, and
  /// the agent keeps its plain ACP shape. ANY declaration makes an agent treat
  /// the client as an AIR client, which changes more than the capability asks
  /// for (claude-agent-acp: no streamed subagent text, a smaller
  /// `toolResponse`), so a route lists it only after that was checked.
  final List<String> airCapabilities;

  /// `_meta` of this route's `session/new`, `session/load` and `session/resume`:
  /// the agent's own session options.
  final Map<String, Object?>? sessionMeta;
}

/// The agents that have an ACP route, in the order the start form lists them.
const agentRoutes = <AgentRoute>[
  AgentRoute(id: 'omp', label: 'omp', binary: 'omp', args: ['acp']),
  AgentRoute(
    id: 'claude',
    label: 'Claude Code',
    binary: 'claude-agent-acp',
    npxPackage: '@agentclientprotocol/claude-agent-acp',
    // Background work without declaring AIR: the raw SDK messages that carry
    // the live background tasks and how each ended.
    sessionMeta: {
      'claudeCode': {
        'emitRawSDKMessages': [
          {'type': 'system', 'subtype': 'background_tasks_changed'},
          {'type': 'system', 'subtype': 'task_notification'},
        ],
      },
    },
  ),
  AgentRoute(
    id: 'codex',
    label: 'Codex',
    binary: 'codex-acp',
    npxPackage: '@agentclientprotocol/codex-acp',
    airCapabilities: ['asyncTasks'],
  ),
  AgentRoute(id: 'pi', label: 'pi', binary: 'pi-acp', npxPackage: 'pi-acp'),
];

AgentRoute? agentRouteById(String id) {
  for (final r in agentRoutes) {
    if (r.id == id) return r;
  }
  return null;
}

enum KeeperState { running, exited }

/// One keeper on a host: a small process that owns one agent process, so the
/// agent outlives the phone's SSH connection (`docs/AGENT_SESSIONS.md`, "The
/// keeper").
class KeeperInfo {
  const KeeperInfo({
    required this.id,
    required this.agent,
    required this.cwd,
    required this.state,
    required this.startedAt,
    this.pid,
    this.exitCode,
    this.sessionId,
    this.title,
    this.pending = 0,
    this.lastEventAt,
    this.exitReason,
    this.turnActive = false,
    this.unseenDone = false,
    this.paneId,
    this.clients = 0,
    this.loginInKeychain = false,
  });

  /// Names the keeper on its host; the key of an agent session.
  final String id;

  /// A route id (`omp`, `claude`, `codex`, `pi`).
  final String agent;
  final String cwd;
  final KeeperState state;
  final DateTime startedAt;
  final int? pid;

  /// Set once [state] is [KeeperState.exited].
  final int? exitCode;

  /// The ACP session the keeper holds, once a client created or loaded one.
  final String? sessionId;
  final String? title;

  /// Requests from the agent (a permission, a question) waiting for a client.
  final int pending;

  /// The last `session/update` the keeper saw, for "quiet for N minutes".
  final DateTime? lastEventAt;

  /// Why the agent exited, in words for the person ("The agent exited with
  /// code 1." plus its last stderr line, or "Ended on request."). Set with
  /// [exitCode] once [state] is [KeeperState.exited].
  final String? exitReason;

  /// A `session/prompt` is in flight right now, as the keeper sees it (every
  /// prompt passes through it), also while no client is attached.
  final bool turnActive;

  /// A prompt turn ended while no client was attached. The keeper clears it
  /// when the next client loads the session (`session/load`).
  final bool unseenDone;

  /// The herdr pane of the keeper's terminal view (`view`), which shows this
  /// session on the computer; null while there is none (no herdr on the
  /// host, or a keeper older than shared sessions).
  final String? paneId;

  /// How many clients are attached now (the phone, the terminal view, ...).
  final int clients;

  /// The agent can only find its login in the macOS Keychain, which macOS
  /// does not open for the SSH session the keeper runs in (Claude Code on a
  /// Mac with no token in the environment). When it asks for a login,
  /// signing in again does not help; a token does.
  final bool loginInKeychain;

  /// Tolerant: an unknown or missing field never throws. Times are epoch
  /// milliseconds or ISO text.
  factory KeeperInfo.fromJson(Map<String, Object?> j) {
    DateTime? time(Object? v) => switch (v) {
      final num n => DateTime.fromMillisecondsSinceEpoch(n.toInt()),
      final String s => DateTime.tryParse(s),
      _ => null,
    };
    return KeeperInfo(
      id: '${j['id']}',
      agent: '${j['agent'] ?? ''}',
      cwd: '${j['cwd'] ?? ''}',
      state: j['state'] == 'exited' ? KeeperState.exited : KeeperState.running,
      startedAt: time(j['started_at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      pid: (j['pid'] as num?)?.toInt(),
      exitCode: (j['exit_code'] as num?)?.toInt(),
      sessionId: j['session_id'] as String?,
      title: j['title'] as String?,
      pending: (j['pending'] as num?)?.toInt() ?? 0,
      lastEventAt: time(j['last_event_at']),
      exitReason: j['exit_reason'] as String?,
      turnActive: j['turn_active'] == true,
      unseenDone: j['unseen_done'] == true,
      paneId: j['pane_id'] is String ? j['pane_id'] as String : null,
      clients: (j['clients'] as num?)?.toInt() ?? 0,
      loginInKeychain: j['login'] == 'keychain',
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'agent': agent,
    'cwd': cwd,
    'state': state.name,
    'started_at': startedAt.millisecondsSinceEpoch,
    if (pid != null) 'pid': pid,
    if (exitCode != null) 'exit_code': exitCode,
    if (sessionId != null) 'session_id': sessionId,
    if (title != null) 'title': title,
    'pending': pending,
    if (lastEventAt != null) 'last_event_at': lastEventAt!.millisecondsSinceEpoch,
    if (exitReason != null) 'exit_reason': exitReason,
    'turn_active': turnActive,
    'unseen_done': unseenDone,
    if (paneId != null) 'pane_id': paneId,
    'clients': clients,
    if (loginInKeychain) 'login': 'keychain',
  };
}

/// The host could not do what was asked; [message] is for the person.
/// [fatal] means retrying will not help (the agent is not installed, the
/// folder is gone).
class AgentHostException implements Exception {
  const AgentHostException(this.message, {this.fatal = false});

  final String message;
  final bool fatal;

  @override
  String toString() => 'AgentHostException($message)';
}

/// What one machine offers for agent sessions: keepers that own agent
/// processes. The real one speaks to the host over SSH (`ssh_agent_host.dart`);
/// tests use a fake.
abstract interface class AgentHost {
  /// Route ids this host can run now (the binary, or `npx`, is on its PATH).
  Future<Set<String>> available();

  /// Keepers on the host, running and recently exited.
  Future<List<KeeperInfo>> list();

  /// Starts a keeper that runs [agent] (a route id) in [cwd]. Returns once the
  /// agent process is up.
  Future<KeeperInfo> start({required String agent, required String cwd});

  /// A transport that speaks ACP to the keeper [keeperId]. To the client the
  /// keeper looks like the agent: `initialize` is answered from the keeper's
  /// cache, `session/load` replays what happened while no client was attached
  /// and then re-issues the requests still waiting. Closing the transport
  /// detaches; it never ends the agent.
  Future<AcpTransport> attach(String keeperId);

  /// Ends the keeper and its agent process.
  Future<void> kill(String keeperId);

  /// What [agent] remembers on this host (`session/list`), newest first, for
  /// [cwd] only when given. Runs the agent briefly without a keeper and
  /// without creating a session. Throws [AgentHostException] (the agent is not
  /// installed, it did not answer, it failed to start).
  Future<PastSessions> history({required String agent, String? cwd});
}
