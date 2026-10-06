import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';

import '../observed/observed_contracts.dart';
import 'fleet_repository.dart';
import 'machine_connection.dart';
import 'observed_session.dart';
import 'pane_previews.dart';

/// Makes a fresh mapper for the agent kind it is registered under.
typedef LogMapperFactory = SessionLogMapper Function();

/// The observed sessions: one [ObservedAgentSession] per `(machine, pane)`,
/// made when a screen first asks for it, dropped when its pane has gone from
/// herdr or when nobody has looked for a long while. Subagents are sessions of
/// their own, made from the main agent's.
///
/// Which agents can be observed is the [mappers] map: an agent kind (`omp`)
/// with the factory of the mapper that reads its log. A pane is observable
/// when herdr names such an agent and a `.jsonl` log it writes
/// (`FleetAgent.sessionLogPath`).
class ObservedSessions extends ChangeNotifier {
  ObservedSessions({
    required this._fleet,
    required this._previews,
    required this._sourceFor,
    required this._mappers,
    this.idleAfter = const Duration(minutes: 10),
  }) {
    _fleet.addListener(_prune);
  }

  final FleetRepository _fleet;
  final PanePreviews _previews;
  final LogSourceFor _sourceFor;
  final Map<String, LogMapperFactory> _mappers;

  /// A session nobody holds for this long is dropped.
  final Duration idleAfter;

  final _sessions = <String, ObservedAgentSession>{};
  bool _disposed = false;
  bool _keepAlive = false;
  DateTime? _backgroundedAt;

  /// Live sessions (tests, diagnostics).
  Iterable<ObservedAgentSession> get sessions => _sessions.values;

  /// Whether pane [paneId] of [machine] runs an agent this app can follow
  /// through its log.
  bool supports(MachineConnection machine, String paneId) => _agentOf(machine, paneId) != null;

  String? _agentOf(MachineConnection machine, String paneId) {
    final pane = machine.paneById(paneId);
    if (pane == null) return null;
    final agent = FleetAgent(machine: machine, pane: pane, workspace: null);
    final kind = agent.agentKind;
    if (kind == null || !_mappers.containsKey(kind) || agent.sessionLogPath == null) return null;
    return kind;
  }

  /// The session of pane [paneId], made if the pane can be observed; null
  /// otherwise.
  ObservedAgentSession? forPane(MachineConnection machine, String paneId) {
    if (_disposed) return null;
    final key = 'pane/${machine.profile.id}/$paneId';
    final have = _sessions[key];
    if (have != null) return have;
    final kind = _agentOf(machine, paneId);
    if (kind == null) return null;
    return _add(
      key,
      ObservedAgentSession(
        machine: machine,
        paneId: paneId,
        agent: kind,
        source: _sourceFor(machine),
        mapper: _mappers[kind]!(),
        previews: _previews,
        onIdle: _drop,
        idleAfter: idleAfter,
      ),
    );
  }

  /// The session with [key] (`pane/...` or `sub/...`), if it exists.
  ObservedAgentSession? byKey(String key) => _sessions[key];

  /// The transcript of subagent [name] of [parent], read-only, made on demand;
  /// null when the parent has no log folder.
  ObservedAgentSession? subagent(ObservedAgentSession parent, String name) {
    if (_disposed) return null;
    final key = 'sub/${parent.machine.profile.id}/${parent.paneId}/$name';
    final have = _sessions[key];
    if (have != null && !have.stale) return have;
    if (have != null) _drop(have);
    final path = parent.subagentLog(name);
    if (path == null) return null;
    return _add(
      key,
      ObservedAgentSession(
        machine: parent.machine,
        paneId: parent.paneId,
        agent: parent.agent,
        source: _sourceFor(parent.machine),
        mapper: _mappers[parent.agent]!(),
        previews: null,
        parent: parent,
        subagentName: name,
        fixedPath: path,
        onIdle: _drop,
        idleAfter: idleAfter,
      ),
    );
  }

  ObservedAgentSession _add(String key, ObservedAgentSession session) {
    _sessions[key] = session;
    session.keepAliveInBackground = _keepAlive;
    if (_backgroundedAt case final at?) session.background(since: at);
    return session;
  }

  void _drop(ObservedAgentSession session) {
    if (_sessions[session.key] == session) _sessions.remove(session.key);
    // Its subagents read through it.
    for (final sub in _sessions.values.where((s) => s.parent == session).toList()) {
      _drop(sub);
    }
    session.dispose();
  }

  /// Drops what is not held and whose pane herdr no longer lists, or whose
  /// main agent moved to another log. A held session stays until its screen
  /// lets go (it shows the pane as gone meanwhile).
  void _prune() {
    if (_disposed) return;
    for (final s in _sessions.values.toList()) {
      if (s.held) continue;
      final gone = s.machine.isLive && s.machine.paneById(s.paneId) == null;
      if (gone || s.stale) _drop(s);
    }
  }

  /// Feeds app lifecycle transitions to every session.
  void onLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        _backgroundedAt ??= DateTime.now();
      case AppLifecycleState.resumed:
        _backgroundedAt = null;
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
    for (final s in _sessions.values.toList()) {
      s.onLifecycleState(state);
    }
  }

  /// Keep following in the background (the person asked to be told about
  /// agents), see `AttentionNotifier`.
  set keepAliveInBackground(bool value) {
    if (_disposed || _keepAlive == value) return;
    _keepAlive = value;
    for (final s in _sessions.values.toList()) {
      s.keepAliveInBackground = value;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _fleet.removeListener(_prune);
    for (final s in _sessions.values.toList()) {
      s.dispose();
    }
    _sessions.clear();
    super.dispose();
  }
}
