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
    this.authMethod,
    this.airCapabilities = const [],
    this.sessionMeta,
  });

  /// Stable, lower case, for example `omp`, `claude`, `codex`, `pi`.
  final String id;

  /// What the person reads: `Claude Code`.
  final String label;

  final String binary;
  final List<String> args;
  final String? npxPackage;

  /// An `authMethods` id the keeper must `authenticate` with before the first
  /// session. Cursor only: its flow is initialize, authenticate, session/new.
  final String? authMethod;

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
  // The routes below launch the vendor's own ACP server. Ids equal herdr's
  // `IntegrationTarget` ids (the keeper reports `pane report-agent --agent
  // <id>`); herdr has none for DeepSeek. None declares `airCapabilities` or
  // `sessionMeta`: that is only done once an agent was checked.
  // kimi: `kimi acp`, probed on kimi 0.26 and kimi-cli 1.29 (loadSession,
  // session/list + resume); installs into ~/.kimi-code/bin. Without it the
  // ACP registry's own launch is used: `npx @moonshot-ai/kimi-code acp` (2.5.3
  // probed: adds close, delete, fork).
  AgentRoute(id: 'kimi', label: 'Kimi', binary: 'kimi', args: ['acp'], npxPackage: '@moonshot-ai/kimi-code'),
  // opencode: `opencode acp` (opencode.ai/docs/acp). Builds before 1.19 crash
  // on any `initialize` (1.1.50 probed: "fn3 is not a function"); 1.19.5
  // probed OK (loadSession, list, resume). Installs into ~/.opencode/bin.
  AgentRoute(id: 'opencode', label: 'OpenCode', binary: 'opencode', args: ['acp'], npxPackage: 'opencode-ai'),
  // cursor: `cursor-agent acp` (cursor.com/docs/cli/acp), probed: loadSession
  // but no session/list; flow is initialize, authenticate(cursor_login),
  // session/new. Its `cursor/*` requests are translated by the keeper.
  AgentRoute(id: 'cursor', label: 'Cursor', binary: 'cursor-agent', args: ['acp'], authMethod: 'cursor_login'),
  // copilot: `copilot --acp --stdio` (GitHub Copilot CLI ACP server, public
  // preview, docs.github.com). Probed through npx (1.0.109, ~10 s cold):
  // loadSession, sessionCapabilities {close, list} (no resume), auth method
  // `copilot-login`, modes agent/plan/autopilot with URL ids. A real turn with a
  // subagent was recorded in BYOK mode (`COPILOT_PROVIDER_*`, no GitHub login).
  AgentRoute(
    id: 'copilot',
    label: 'Copilot',
    binary: 'copilot',
    args: ['--acp', '--stdio'],
    npxPackage: '@github/copilot',
  ),
  // antigravity: `agy acp` (antigravity.google/docs/cli/acp), 1.5.5 probed:
  // loadSession, sessionCapabilities {resume, close, load, list,
  // additionalDirectories}, auth methods oauth-personal, oauth-business,
  // gemini-api-key, agent-platform. Logged out, `session/new` answers -32000
  // "Authentication required" (an older build exited before `initialize`).
  AgentRoute(id: 'antigravity_cli', label: 'Antigravity', binary: 'agy', args: ['acp']),
  // hermes: `hermes acp` (NousResearch/hermes-agent acp_adapter/server.py:
  // loadSession, list, resume; terminal auth method `hermes-setup`).
  // A real turn with a subagent was recorded on an editable install (Python 3.14,
  // `uv sync --extra acp`; the launcher on the test machine has a broken venv),
  // with an OpenAI-compatible endpoint (`model.provider: custom` in config.yaml).
  AgentRoute(id: 'hermes', label: 'Hermes', binary: 'hermes', args: ['acp']),
  // deepseek: `dsh --profile acp` (deepseek-ai/deepseek-harness, npm
  // @deepseek-ai/dsh, bin `dsh`). Automation profile: no session/load (the
  // keeper answers that itself), one-shot allow/reject permissions.
  // Only prereleases are published, so a bare `npx -y @deepseek-ai/dsh` fails
  // with ETARGET (`*` excludes them): the `next` tag (0.2.2-rc.1) is pinned.
  // Probed through npm: initialize answers sessionCapabilities {close, list,
  // resume}, no auth methods. Needs Node >= 24.9 on paper; ran on Node 22.21.
  // A cold `npx` installs 900 MB (about a minute). No real turn run here.
  AgentRoute(
    id: 'deepseek',
    label: 'DeepSeek',
    binary: 'dsh',
    args: ['--profile', 'acp'],
    npxPackage: '@deepseek-ai/dsh@next',
  ),
];

AgentRoute? agentRouteById(String id) {
  for (final r in agentRoutes) {
    if (r.id == id) return r;
  }
  return null;
}

/// Where a keeper is in its life, as the host lists it.
///
/// [starting] is a keeper whose agent has not answered `initialize` yet (the
/// host's list shows it early, and `start` only returns once it is over);
/// [running] is one that has, and [exited] one whose agent ended.
enum KeeperState { starting, running, exited }

/// One keeper on a host: a small process that owns one agent process, so the
/// agent outlives the phone's SSH connection (`docs/AGENT_SESSIONS.md`, "The
/// keeper").
class KeeperInfo {
  const KeeperInfo({
    required this.id,
    required this.agent,
    required this.cwd,
    required this.state,
    this.startedAt,
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

  /// A route id (for example `omp`, `claude`, `codex`, `pi`).
  final String agent;
  final String cwd;
  final KeeperState state;

  /// When the keeper started; null when the host did not say.
  final DateTime? startedAt;
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

  /// What a host listed, row by row: a row that is no keeper (not an object,
  /// no id) is left out, so one odd row never hides the others.
  static List<KeeperInfo> listFromJson(Iterable<Object?> rows) => [for (final row in rows) ?_tryParse(row)];

  static KeeperInfo? _tryParse(Object? row) {
    if (row is! Map) return null;
    try {
      return KeeperInfo.fromJson(Map<String, Object?>.from(row));
    } on FormatException {
      return null;
    } on TypeError {
      return null; // a key that is not text
    }
  }

  /// Reads one keeper. Throws [FormatException] when [j] names none (no string
  /// id: a key made of `null` would be a session that does not exist). A field
  /// of another type than expected is as good as missing, never an error; an
  /// unknown state reads as running. Times are epoch milliseconds or ISO text.
  factory KeeperInfo.fromJson(Map<String, Object?> j) {
    final id = j['id'];
    if (id is! String || id.isEmpty) throw FormatException('a keeper has no id', j);
    String? text(String key) => j[key] is String ? j[key] as String : null;
    int? whole(String key) => switch (j[key]) {
      final num n when n.isFinite => n.toInt(),
      _ => null,
    };
    DateTime? time(String key) {
      try {
        return switch (j[key]) {
          final num n when n.isFinite => DateTime.fromMillisecondsSinceEpoch(n.toInt()),
          final String s => DateTime.tryParse(s),
          _ => null,
        };
      } on ArgumentError {
        return null;
      }
    }

    return KeeperInfo(
      id: id,
      agent: text('agent') ?? '',
      cwd: text('cwd') ?? '',
      state: switch (j['state']) {
        'exited' => KeeperState.exited,
        'starting' => KeeperState.starting,
        _ => KeeperState.running,
      },
      startedAt: time('started_at'),
      pid: whole('pid'),
      exitCode: whole('exit_code'),
      sessionId: text('session_id'),
      title: text('title'),
      pending: whole('pending') ?? 0,
      lastEventAt: time('last_event_at'),
      exitReason: text('exit_reason'),
      turnActive: j['turn_active'] == true,
      unseenDone: j['unseen_done'] == true,
      paneId: text('pane_id'),
      clients: whole('clients') ?? 0,
      loginInKeychain: j['login'] == 'keychain',
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'agent': agent,
    'cwd': cwd,
    'state': state.name,
    if (startedAt != null) 'started_at': startedAt!.millisecondsSinceEpoch,
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
