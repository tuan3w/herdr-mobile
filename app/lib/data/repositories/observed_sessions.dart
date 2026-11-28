import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';

import '../models/herdr_models.dart' show Pane;
import '../observed/observed_kind.dart';
import 'agent_session.dart' show Preconnect;
import 'fleet_repository.dart';
import 'background_grace.dart';
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
    this.detachAfter = defaultBackgroundGrace,
    this.preconnectHold = const Duration(seconds: 6),
    this.maxWarm = 3,
  }) {
    _fleet.addListener(_prune);
  }

  final FleetRepository _fleet;
  final PanePreviews _previews;
  final LogSourceFor _sourceFor;
  final Map<String, ObservedKind> _kinds;

  /// A session nobody holds for this long is dropped.
  final Duration idleAfter;

  /// How long the app may stay in the background before a session stops
  /// following its log, asked when the app goes away.
  final BackgroundGrace detachAfter;

  /// How long a [preconnect] hold that nobody cancels lasts.
  final Duration preconnectHold;

  /// How many logs a [preconnect] may start following at once that nothing
  /// else holds: a scroll across the board must not open a stream per card.
  final int maxWarm;
  int _warm = 0;
  final _holds = <_FollowHold>{};

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
        detachAfter: detachAfter,
      ),
    );
  }

  /// Starts following the log of pane [paneId] before its screen asks for it
  /// (a finger went down on its row or card): the first batch is on its way
  /// while the route is pushed. Cancel the hold when the finger leaves, or
  /// hand it to the screen, which holds the session itself ([Preconnect.cancel]
  /// once it has). Nothing starts in the background (the radio sleeps), for a
  /// machine that is not live, for a pane that cannot be observed, or past
  /// [maxWarm] logs; then the hold is inert. A hold nobody cancels lets go by
  /// itself after [preconnectHold], and a press that came to nothing leaves
  /// the log followed for that long, not the usual wait of a screen that was
  /// left. Reads the same tail the screen would ask for, once.
  Preconnect preconnect(MachineConnection machine, String paneId) {
    if (_disposed || _backgroundedAt != null || !machine.isLive) return Preconnect.none;
    final have = _sessions['pane/${machine.profile.id}/$paneId'];
    final costs = have == null || !have.following;
    if (costs && _warm >= maxWarm) return Preconnect.none;
    final session = forPane(machine, paneId);
    if (session == null) return Preconnect.none;
    final cold = !session.following;
    if (cold) _warm++;
    final hold = _FollowHold(
      session,
      preconnectHold,
      cold: cold,
      onDone: (hold) {
        _holds.remove(hold);
        if (cold) _warm--;
      },
    );
    _holds.add(hold);
    return hold;
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
        detachAfter: detachAfter,
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
        // Nobody is looking: a finger-down hold does not outlive the app's
        // being in front.
        for (final hold in _holds.toList()) {
          hold.cancel();
        }
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
  /// agents), see `AttentionNotifier`. A page from a machine held open does
  /// not keep these: it needs the connection, not the agents' logs.
  bool get keepAliveInBackground => _keepAlive;
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

/// A finger-down hold on an observed session ([ObservedSessions.preconnect]):
/// a hold like a screen's, let go when cancelled or by itself after the TTL.
/// A log it started following ([cold]) is not followed for long after a hold
/// that came to nothing: [ttl], not the session's usual wait.
class _FollowHold implements Preconnect {
  _FollowHold(this._session, this._ttl, {required this.cold, required this.onDone}) {
    _session.acquire();
    _timer = Timer(_ttl, cancel);
  }

  final ObservedAgentSession _session;
  final Duration _ttl;
  final bool cold;
  final void Function(_FollowHold hold) onDone;
  late final Timer _timer;
  var _done = false;

  @override
  void cancel() {
    if (_done) return;
    _done = true;
    _timer.cancel();
    _session.release(linger: cold ? _ttl : null);
    onDone(this);
  }
}
