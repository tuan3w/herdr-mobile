import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/acp/agent_host.dart';
import '../../../data/acp/past_session.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/agent_session_settings.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/machine_connection.dart';
import '../agent_session/visible_text.dart';
import '../../core/rows.dart' show cwdTail;

/// What the Past sessions screen can show.
enum PastPhase {
  /// No machine is online, or the chosen one went offline.
  offline,

  /// The chosen machine is being asked which agents it has.
  checking,

  /// The machine could not say which agents it has, or could not list the
  /// sessions of the chosen one ([PastSessionsViewModel.failure] says why).
  failed,

  /// The machine has none of the agents with an ACP route.
  noAgents,

  /// The chosen agent is being asked what it remembers.
  loading,

  /// [PastSessionsViewModel.history] is the answer.
  ready,
}

/// State of the Past sessions screen: which machine and agent, what that agent
/// remembers there (its own store is the record, not this app), the search,
/// and reopening one of them.
///
/// Answers are kept by machine, agent and folder for as long as the screen
/// lives, so switching a chip back is instant; a late answer lands under its
/// own key and can never show for another choice.
class PastSessionsViewModel extends ChangeNotifier {
  PastSessionsViewModel({
    required this._fleet,
    required this._sessions,
    required this._settings,
    String? machineId,
    String? cwd,
  }) : folder = _absolute(cwd) {
    _machineId = _initialMachine(machineId);
    _folderOnly = folder != null;
    _fleet.addListener(_onFleet);
    _sessions.addListener(_onSessions);
    _open = _openNow();
    _signature = _signatureNow();
    _ensure();
  }

  final FleetRepository _fleet;
  final AgentSessions _sessions;
  final AgentSessionSettings _settings;

  /// The folder the opener was working in (the new agent session form's), if it
  /// named an absolute one: the `This folder` chip filters on it.
  final String? folder;

  String? _machineId;
  String? _agent;
  late bool _folderOnly;
  String _query = '';
  bool _disposed = false;
  String _signature = '';

  // What each machine can run, by machine id; absent while unknown.
  final _installed = <String, Set<String>>{};
  final _probing = <String>{};
  final _probeFailure = <String, String>{};

  // What agents remember, by [_key].
  final _history = <String, PastSessions>{};
  final _loading = <String>{};
  final _historyFailure = <String, String>{};

  // Sessions held now (live, not ended): `machine|agent|sessionId` -> key.
  Map<String, String> _open = const {};
  String? _resuming;

  static String? _absolute(String? path) {
    final p = path?.trim();
    return p != null && p.startsWith('/') && p.length > 1 ? p : null;
  }

  /// Machines that can be asked now, in saved order.
  List<MachineConnection> get machines => [
    for (final c in _fleet.connections)
      if (c.isLive) c,
  ];

  /// The chosen machine; null when none is online or the chosen one went
  /// offline.
  MachineConnection? get machine {
    final id = _machineId;
    for (final c in machines) {
      if (c.profile.id == id) return c;
    }
    return null;
  }

  /// The chosen machine was online and is not any more.
  bool get machineLost => _machineId != null && machine == null && machines.isNotEmpty;

  /// The agents the chosen machine has, in the order the start form lists them.
  List<AgentRoute> get agents {
    final have = _installed[_machineId];
    return have == null
        ? const []
        : [
            for (final r in agentRoutes)
              if (have.contains(r.id)) r,
          ];
  }

  /// The route id asked about; null until the machine said which it has.
  String? get agent {
    final have = agents;
    if (have.isEmpty) return null;
    if (_agent != null && have.any((r) => r.id == _agent)) return _agent;
    final remembered = _machineId == null ? null : _settings.agentFor(_machineId!);
    for (final r in have) {
      if (r.id == remembered) return r.id;
    }
    return have.first.id;
  }

  /// The chosen agent's name for the person (`Claude Code`).
  String get agentLabel => agentRouteById(agent ?? '')?.label ?? '';

  /// Only [folder] is listed (the agent filters; the others stay on the host).
  bool get folderOnly => folder != null && _folderOnly;

  String get query => _query;

  /// The session being reopened now (its id), if any. Taps on every row are
  /// ignored meanwhile: two keepers for one tap would be worse than waiting.
  String? get resumingId => _resuming;

  String? get failure {
    final m = _machineId;
    if (m == null) return null;
    return _probeFailure[m] ?? _historyFailure[_key()];
  }

  PastPhase get phase {
    final m = machine;
    if (m == null) return PastPhase.offline;
    final id = m.profile.id;
    if (_probeFailure.containsKey(id)) return PastPhase.failed;
    if (!_installed.containsKey(id)) return PastPhase.checking;
    if (agent == null) return PastPhase.noAgents;
    final key = _key();
    if (_history.containsKey(key)) return PastPhase.ready;
    return _historyFailure.containsKey(key) ? PastPhase.failed : PastPhase.loading;
  }

  /// What the chosen agent answered; null unless [phase] is [PastPhase.ready].
  PastSessions? get history => _history[_key()];

  /// [history]'s sessions that match the search, newest first.
  List<PastSession> get visible {
    final all = history?.sessions ?? const <PastSession>[];
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return [
      for (final s in all)
        if (_matches(s, q)) s,
    ];
  }

  static bool _matches(PastSession s, String q) =>
      visibleText(s.title ?? '').toLowerCase().contains(q) ||
      visibleText(s.cwd).toLowerCase().contains(q) ||
      cwdTail(s.cwd).toLowerCase().contains(q);

  /// The key of the session held on the chosen machine for [past] (live, not
  /// ended), or null.
  String? openKeyFor(PastSession past) => _open['${_machineId ?? ''}|${past.agent}|${past.sessionId}'];

  void selectMachine(String id) {
    if (id == _machineId) return;
    _machineId = id;
    _agent = null;
    _changed();
    _ensure();
  }

  void selectAgent(String routeId) {
    if (routeId == _agent) return;
    _agent = routeId;
    _changed();
    _ensure();
  }

  void setFolderOnly(bool value) {
    if (value == _folderOnly) return;
    _folderOnly = value;
    _changed();
    _ensure();
  }

  void setQuery(String value) {
    if (value == _query) return;
    _query = value;
    if (!_disposed) notifyListeners();
  }

  /// Asks again after a failure.
  void retry() {
    final m = _machineId;
    if (m == null) return;
    if (_probeFailure.remove(m) == null) _historyFailure.remove(_key());
    _changed();
    _ensure();
  }

  /// Reopens [past] in a new keeper (see [AgentSessions.resume]). The result
  /// holds the attached session, or the words for the person when it failed;
  /// both null when the tap was not taken (another reopen runs, the agent
  /// cannot reopen anything, the machine is gone).
  Future<({AgentSessionView? session, String? error})> resume(PastSession past) async {
    final m = machine;
    if (_resuming != null || m == null || history?.canReopen != true) return (session: null, error: null);
    _resuming = past.sessionId;
    notifyListeners();
    try {
      final session = await _sessions.resume(
        machine: m,
        agent: past.agent,
        cwd: past.cwd,
        sessionId: past.sessionId,
      );
      return (session: session, error: null);
    } on AgentHostException catch (e) {
      return (session: null, error: e.message);
    } finally {
      _resuming = null;
      if (!_disposed) notifyListeners();
    }
  }

  String _key() => '${_machineId ?? ''}|${agent ?? ''}|${folderOnly ? folder : ''}';

  // Asks for whatever the screen shows and does not have yet: first which
  // agents the machine has, then what the chosen one remembers.
  void _ensure() {
    final m = machine;
    if (m == null) return;
    final id = m.profile.id;
    if (_probeFailure.containsKey(id)) return;
    if (!_installed.containsKey(id)) {
      unawaited(_probe(m));
      return;
    }
    final route = agent;
    if (route == null) return;
    final key = _key();
    if (_history.containsKey(key) || _historyFailure.containsKey(key)) return;
    unawaited(_load(m, route, key, folderOnly ? folder : null));
  }

  Future<void> _probe(MachineConnection m) async {
    final id = m.profile.id;
    if (!_probing.add(id)) return;
    try {
      _installed[id] = await _sessions.available(m);
    } on AgentHostException catch (e) {
      _probeFailure[id] = e.message;
    } finally {
      _probing.remove(id);
    }
    if (_disposed) return;
    _changed();
    _ensure();
  }

  Future<void> _load(MachineConnection m, String route, String key, String? cwd) async {
    if (!_loading.add(key)) return;
    try {
      _history[key] = await _sessions.history(machine: m, agent: route, cwd: cwd);
    } on AgentHostException catch (e) {
      _historyFailure[key] = e.message;
    } finally {
      _loading.remove(key);
    }
    if (!_disposed) notifyListeners();
  }

  String? _initialMachine(String? preferred) {
    final online = machines;
    for (final id in [preferred, _settings.lastMachineId]) {
      if (id != null && online.any((c) => c.profile.id == id)) return id;
    }
    return online.firstOrNull?.profile.id;
  }

  Map<String, String> _openNow() => {
    for (final s in _sessions.sessions)
      if (s.link != AgentLink.ended && s.state.sessionId.isNotEmpty)
        '${s.machine.profile.id}|${s.agent}|${s.state.sessionId}': s.key,
  };

  // The machines that can be asked, and the one chosen. A fleet that changes
  // in unrelated ways must not rebuild the screen.
  String _signatureNow() => '${machines.map((c) => c.profile.id).join(',')}|$_machineId';

  void _onFleet() {
    // The first machine to come online is taken when none was chosen yet.
    _machineId ??= _initialMachine(null);
    final next = _signatureNow();
    if (next == _signature) return;
    _signature = next;
    notifyListeners();
    _ensure();
  }

  void _onSessions() {
    final next = _openNow();
    if (mapEquals(next, _open)) return;
    _open = next;
    if (!_disposed) notifyListeners();
  }

  void _changed() {
    _signature = _signatureNow();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _fleet.removeListener(_onFleet);
    _sessions.removeListener(_onSessions);
    super.dispose();
  }
}
