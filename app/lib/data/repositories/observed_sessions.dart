import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';

import '../models/herdr_models.dart' show Pane;
import '../observed/observed_kind.dart';
import 'fleet_repository.dart';
import 'machine_connection.dart';
import 'observed_session.dart';
import 'pane_previews.dart';

/// The observed sessions: one [ObservedAgentSession] per `(machine, pane)`,
/// made when a screen first asks for it, dropped when its pane has gone from
/// herdr or when nobody has looked for a long while. Subagents are sessions of
/// their own, made from the main agent's.
///
/// Which agents can be observed is the [kinds] map: herdr's agent label
/// (`omp`, `claude`, `codex`) with the [ObservedKind] that finds and reads its
/// log. A pane is observable when herdr names such an agent and its locator
/// says the pane may have a log; a pane whose log turned out not to be
/// findable ([markUnlinked]) opens as its terminal for a while.
class ObservedSessions extends ChangeNotifier {
  ObservedSessions({
    required this._fleet,
    required this._previews,
    required this._sourceFor,
    required this._kinds,
    this.idleAfter = const Duration(minutes: 10),
  }) {
    _fleet.addListener(_prune);
  }

  final FleetRepository _fleet;
  final PanePreviews _previews;
  final LogSourceFor _sourceFor;
  final Map<String, ObservedKind> _kinds;

  /// A session nobody holds for this long is dropped.
  final Duration idleAfter;

  final _sessions = <String, ObservedAgentSession>{};
  bool _disposed = false;
  bool _keepAlive = false;
  DateTime? _backgroundedAt;

  /// Live sessions (tests, diagnostics).
  Iterable<ObservedAgentSession> get sessions => _sessions.values;

  /// How long a pane whose log could not be found opens as its terminal.
  static const unlinkedFor = Duration(seconds: 60);

  final _unlinked = <String, ({DateTime at, String? session})>{};

  /// Whether pane [paneId] of [machine] runs an agent this app can follow
  /// through its log.
  bool supports(MachineConnection machine, String paneId) => _kindOf(machine, paneId) != null;

  /// The herdr integration target of the agent in pane [paneId] when herdr
  /// reports no session for it (an agent that does not need one, like omp,
  /// has no target): installing the integration makes it readable as a chat.
  /// It does not depend on whether a look for the log failed lately: the way
  /// to set it up is always where the person looks.
  String? integrationFor(MachineConnection machine, String paneId) {
    final pane = machine.paneById(paneId);
    if (pane == null || pane.session != null) return null;
    return _kinds[FleetAgent.kindOf(pane)]?.integration;
  }

  /// The log of pane [paneId] could not be found and will not be: the next
  /// open goes to the terminal until its session reference changes or
  /// [unlinkedFor] has passed.
  void markUnlinked(MachineConnection machine, String paneId) {
    final pane = machine.paneById(paneId);
    _unlinked['${machine.profile.id}/$paneId'] = (at: DateTime.now(), session: _sessionSig(pane));
    notifyListeners();
  }

  /// The pane's session when there is one: kept while a screen holds it or the
  /// pane can be followed, dropped otherwise (a failed one must not be handed
  /// out for the next ten minutes instead of the terminal).
  ObservedAgentSession? _existing(MachineConnection machine, String paneId, String key) {
    final have = _sessions[key];
    if (have == null) return null;
    if (have.held || _kindOf(machine, paneId) != null) return have;
    _drop(have);
    return null;
  }

  static String? _sessionSig(Pane? pane) {
    final s = pane?.session;
    return s == null ? null : '${s.kind}:${s.value}';
  }

  ObservedKind? _kindOf(MachineConnection machine, String paneId) {
    final pane = machine.paneById(paneId);
    if (pane == null) return null;
    final label = FleetAgent.kindOf(pane);
    final kind = label == null ? null : _kinds[label];
    if (kind == null || !kind.locator.mayLocate(pane)) return null;
    final bad = _unlinked['${machine.profile.id}/$paneId'];
    if (bad != null) {
      if (bad.session == _sessionSig(pane) && DateTime.now().difference(bad.at) < unlinkedFor) return null;
      _unlinked.remove('${machine.profile.id}/$paneId');
    }
    return kind;
  }

  /// The session of pane [paneId], made if the pane can be observed; null
  /// otherwise.
  ObservedAgentSession? forPane(MachineConnection machine, String paneId) {
    if (_disposed) return null;
    final key = 'pane/${machine.profile.id}/$paneId';
    final have = _existing(machine, paneId, key);
    if (have != null) return have;
    final kind = _kindOf(machine, paneId);
    if (kind == null) return null;
    return _add(
      key,
      ObservedAgentSession(
        machine: machine,
        paneId: paneId,
        kind: kind,
        source: _sourceFor(machine),
        mapper: kind.newMapper,
        previews: _previews,
        onUnlinked: () => markUnlinked(machine, paneId),
        onIdle: _drop,
        idleAfter: idleAfter,
      ),
    );
  }

  /// The session with [key] (`pane/...` or `sub/...`), if it exists.
  ObservedAgentSession? byKey(String key) => _sessions[key];

  /// The transcript of subagent [name] of [parent], read-only, made on demand;
  /// null when the kind has no subagent transcripts or the parent has no log
  /// yet.
  ObservedAgentSession? subagent(ObservedAgentSession parent, String name) {
    if (_disposed) return null;
    final key = 'sub/${parent.machine.profile.id}/${parent.paneId}/$name';
    final have = _sessions[key];
    if (have != null && !have.stale) return have;
    if (have != null) _drop(have);
    if (parent.kind.subagents == null || parent.logPath == null) return null;
    return _add(
      key,
      ObservedAgentSession(
        machine: parent.machine,
        paneId: parent.paneId,
        kind: parent.kind,
        source: _sourceFor(parent.machine),
        mapper: parent.kind.newSubagentMapper ?? parent.kind.newMapper,
        previews: null,
        parent: parent,
        subagentName: name,
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
