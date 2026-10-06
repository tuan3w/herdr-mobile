import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/acp/agent_host.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/agent_session_settings.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/machine_connection.dart';
import 'session_prefill.dart';
import 'session_start_support.dart' show NewSessionError, folderError, recentFolders;

/// Null when [folder] can be the working directory of an ACP session: the
/// agent gets it as `cwd`, and ACP wants an absolute path (a `~` would reach
/// the agent unexpanded).
String? agentFolderError(String? folder) {
  final problem = folderError(folder);
  if (problem != null) return problem;
  return folder!.trim().startsWith('/') ? null : 'An absolute path, starting with /';
}

/// State of the new-agent-session form: which machine and agent, what the
/// machine can run, and the start itself. The folder field is owned by the
/// screen and handed to [start].
class NewAgentSessionViewModel extends ChangeNotifier {
  NewAgentSessionViewModel({
    required this._fleet,
    required this._sessions,
    required this._settings,
    String? machineId,
    this.prefill,
  }) {
    // A duplicate keeps its machine even when it is offline: the form then
    // says so, rather than starting the folder somewhere else.
    _machineId = prefill?.machineId ?? _initialMachine(machineId);
    final copied = prefill?.agent;
    _agent = copied != null && agentRouteById(copied) != null ? copied : _rememberedAgent();
    _fleet.addListener(_onFleet);
    _signature = _signatureNow();
    unawaited(_probe());
  }

  /// What a duplicate starts from; null for a form opened empty.
  final SessionPrefill? prefill;

  final FleetRepository _fleet;
  final AgentSessions _sessions;
  final AgentSessionSettings _settings;

  String? _machineId;
  late String _agent;
  bool _busy = false;
  bool _disposed = false;
  NewSessionError? _error;
  String _signature = '';

  // What each machine can run, by machine id; a machine that has not answered
  // (or answered with a failure) has no entry.
  final _installed = <String, Set<String>>{};
  final _probing = <String>{};
  final _probeFailure = <String, String>{};

  /// Machines that can take a session now, in saved order.
  List<MachineConnection> get machines => [
        for (final c in _fleet.connections)
          if (c.isLive) c,
      ];

  /// The chosen machine, or null when none is online (or the chosen one went
  /// offline).
  MachineConnection? get machine {
    final id = _machineId;
    for (final c in machines) {
      if (c.profile.id == id) return c;
    }
    return null;
  }

  /// The chosen machine was online and is not any more.
  bool get machineLost => _machineId != null && machine == null && machines.isNotEmpty;

  /// The chosen route id.
  String get agent => _agent;

  bool get busy => _busy;
  NewSessionError? get error => _error;

  /// Whether the chosen machine is still being asked what it can run.
  bool get checking => _machineId != null && _probing.contains(_machineId);

  /// Why the chosen machine could not say what it can run; null when it did
  /// (or has not been asked yet).
  String? get probeFailure => _machineId == null ? null : _probeFailure[_machineId];

  /// Whether the chosen machine can run [routeId]: null while that is not
  /// known (the machine is being asked, or did not answer).
  bool? isAvailable(String routeId) => _installed[_machineId]?.contains(routeId);

  /// One line on why [route] cannot be chosen; null when it can.
  String? unavailableReason(AgentRoute route) {
    final m = machine;
    if (m == null || isAvailable(route.id) != false) return null;
    return '${route.label} is not installed on ${m.profile.label}';
  }

  /// The chosen agent can be started (as far as is known).
  bool get canStart => machine != null && isAvailable(_agent) != false;

  List<String> get recent {
    final m = machine;
    return m == null ? const [] : recentFolders(m.snapshot);
  }

  /// The folder used last on the chosen machine; empty when none.
  String get rememberedFolder {
    final id = _machineId;
    return (id == null ? null : _settings.folderFor(id)) ?? '';
  }

  void selectMachine(String id) {
    if (id == _machineId) return;
    _machineId = id;
    _agent = _rememberedAgent();
    _error = null;
    unawaited(_probe());
    _changed();
  }

  void selectAgent(String routeId) {
    if (routeId == _agent || isAvailable(routeId) == false) return;
    _agent = routeId;
    _error = null;
    _changed();
  }

  void dismissError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  /// Starts the session in [folder]. Null when it did not start; [error] says
  /// why. The caller opens the returned session.
  Future<AgentSessionView?> start(String folder) async {
    if (_busy) return null;
    final m = machine;
    final path = folder.trim();
    if (m == null) {
      return _fail(const NewSessionError('No machine online', 'Pick a machine that is online.'));
    }
    final problem = agentFolderError(path);
    if (problem != null) return _fail(NewSessionError('Check the form', problem));
    final agentId = _agent;

    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final session = await _sessions.start(machine: m, agent: agentId, cwd: path);
      unawaited(_settings.remember(machineId: m.profile.id, agent: agentId, folder: path));
      return session;
    } on AgentHostException catch (e) {
      return _fail(NewSessionError("Couldn't start the session", e.message));
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  AgentSessionView? _fail(NewSessionError error) {
    _error = error;
    if (!_disposed) notifyListeners();
    return null;
  }

  Future<void> _probe() async {
    final m = machine;
    if (m == null) return;
    final id = m.profile.id;
    if (_installed.containsKey(id)) {
      _settleAgent();
      return;
    }
    if (!_probing.add(id)) return;
    _probeFailure.remove(id);
    try {
      _installed[id] = await _sessions.available(m);
    } on AgentHostException catch (e) {
      _probeFailure[id] = e.message;
    } finally {
      _probing.remove(id);
    }
    if (_disposed) return;
    if (id == _machineId) _settleAgent();
    _changed();
  }

  // The remembered agent may not exist on this machine: move to one that does.
  void _settleAgent() {
    if (isAvailable(_agent) != false) return;
    for (final r in agentRoutes) {
      if (isAvailable(r.id) == true) {
        _agent = r.id;
        return;
      }
    }
  }

  String? _initialMachine(String? preferred) {
    final online = machines;
    for (final id in [preferred, _settings.lastMachineId]) {
      if (id != null && online.any((c) => c.profile.id == id)) return id;
    }
    return online.firstOrNull?.profile.id;
  }

  String _rememberedAgent() {
    final id = _machineId;
    final saved = id == null ? null : _settings.agentFor(id);
    return saved != null && agentRouteById(saved) != null ? saved : agentRoutes.first.id;
  }

  /// The machines that can be picked, the one chosen, and what the form shows
  /// from its snapshot. A fleet that changes only in unrelated ways must not
  /// rebuild the form.
  String _signatureNow() => '${machines.map((c) => c.profile.id).join(',')}|$_machineId|${recent.join(',')}';

  void _onFleet() {
    final next = _signatureNow();
    if (next == _signature) return;
    _signature = next;
    notifyListeners();
  }

  void _changed() {
    _signature = _signatureNow();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _fleet.removeListener(_onFleet);
    super.dispose();
  }
}
