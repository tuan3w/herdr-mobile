import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';

import '../acp/agent_host.dart';
import '../acp/past_session.dart';
import '../acp/session_state.dart';
import '../streaming/flush_scheduler.dart';
import 'acp_agent_session.dart';
import 'agent_session.dart';
import 'fleet_repository.dart';
import 'machine_connection.dart';
import 'attention_set.dart';
import 'reviewed_state.dart';
import '../services/transcript_cache.dart';

/// Builds what talks to the keepers of [machine]. The real one rides on the
/// machine's SSH connection (`ssh_agent_host.dart`); tests pass a fake.
typedef AgentHostFactory = AgentHost Function(MachineConnection machine);

/// The agent sessions of every connected machine.
///
/// For each machine that is online it lists the keepers with ONE short `list`
/// (when the machine connects, when the app comes back to the foreground, on
/// [refresh], and every [refreshEvery] while the Agents tab is visible: no
/// timer runs otherwise) and holds one [AcpAgentSession] per keeper. The board
/// shows every session from that listing (a waiting request, a turn in flight,
/// a finished turn nobody saw).
///
/// A host allows only a few channels per SSH connection, shared with the
/// mux, the events and SFTP, so the sessions are NOT all attached. Per
/// machine at most [maxAttached] channels are held by the repository's choice:
/// the sessions with a waiting request first (longest waiting first), then up
/// to [recentAttached] of the most recently active. A session a screen holds
/// open ([AgentSessionView.acquire]) is attached whatever the cap says, and
/// takes its slot from the others. An unattached session never shows stale
/// streaming state: it shows the listing's phase and, when opened, attaches
/// and replays. Sessions detach themselves 90 s after the app goes to the
/// background, unless [keepAliveInBackground] is on: then they stay attached
/// (the same caps and order) and the hosts are listed every
/// [backgroundRefreshEvery].
///
/// Listeners (the board, the tab badge) are told only when something the board
/// shows changes: a phase, a link, a title, a waiting request. Streaming text
/// does not reach them; a screen that wants it listens to its session.
class AgentSessionRepository extends ChangeNotifier implements AgentSessions {
  AgentSessionRepository({
    required this._fleet,
    required this._hostFor,
    ReviewedState? reviewed,
    this._clock = DateTime.now,
    this._backoff = defaultBackoff,
    this._jitter = defaultRetryJitter,
    this.maxAttempts = 12,
    this.maxAttached = 4,
    this.recentAttached = 3,
    this.refreshEvery = const Duration(seconds: 30),
    this.backgroundRefreshEvery = const Duration(seconds: 90),
    this.detachAfter = const Duration(seconds: 90),
    this.notifyEvery = const Duration(milliseconds: 16),
    this.flush,
    this._cache,
    this.preconnectHold = const Duration(seconds: 6),
  })  : reviewed = reviewed ?? ReviewedState(),
        _ownsReviewed = reviewed == null {
    _fleet.addListener(_onFleet);
    _onFleet();
  }

  final FleetRepository _fleet;
  final AgentHostFactory _hostFor;
  final DateTime Function() _clock;
  final Duration Function(int attempt) _backoff;
  final double Function() _jitter;

  /// Passed to every session: retries per outage before it gives up.
  final int maxAttempts;

  /// Most channels per machine the repository keeps open by its own choice
  /// (screens that hold a session open come on top).
  final int maxAttached;

  /// Of those, at most this many go to sessions with nothing waiting, the most
  /// recently active first.
  final int recentAttached;

  /// How often the Agents tab, while visible, lists the hosts again.
  final Duration refreshEvery;

  /// How often the hosts are listed while the app is in the background and
  /// kept alive ([keepAliveInBackground]).
  final Duration backgroundRefreshEvery;

  /// Passed to every session: how long the app may stay in the background
  /// before they detach.
  final Duration detachAfter;
  final Duration notifyEvery;

  /// Passed to every session: when it tells its listeners (the app injects a
  /// frame-aligned one); null is a timer of [notifyEvery].
  final FlushScheduler? flush;

  /// Where the transcripts of the sessions are kept between runs; null keeps
  /// none.
  final TranscriptCache? _cache;

  /// How long a [preconnect] hold that nobody cancels lasts.
  final Duration preconnectHold;

  /// Which finished turns the person has looked at, per device. Separate from
  /// the terminal panes' state (it prunes by pane id).
  final ReviewedState reviewed;
  final bool _ownsReviewed;

  final _machines = <String, _Machine>{};
  final _sessions = <String, AcpAgentSession>{};
  final _adoptedAt = <String, DateTime>{};
  final _signatures = <String, String>{};

  /// Machines whose saved transcripts were swept against a listing this run.
  final _swept = <String>{};
  final _listeners = <String, VoidCallback>{};
  List<AgentSessionView>? _sorted;

  Timer? _timer;
  bool _boardVisible = false;
  DateTime? _backgroundedAt;
  bool _keepAlive = false;
  bool _disposed = false;

  // -- reading ------------------------------------------------------------------

  @override
  List<AgentSessionView> get sessions => _sorted ??= List.unmodifiable(_sort());

  @override
  AgentSessionView? byKey(String key) => _sessions[key];

  static bool _isBlocked(AgentSessionView s) => AttentionSet.sessionBlocked(s);

  /// Blocked, then finished and unseen, then working, then idle (ended and
  /// failed last); inside a rank the one that changed most recently first, so
  /// streaming text never reorders the list.
  List<AgentSessionView> _sort() {
    int rank(AcpAgentSession s) {
      if (_isBlocked(s)) return 0;
      if (s.unseenDone) return 1;
      if (s.phase == AgentPhase.working) return 2;
      return s.link == AgentLink.ended || s.link == AgentLink.failed ? 4 : 3;
    }

    final list = _sessions.values.toList()
      ..sort((a, b) {
        final byRank = rank(a).compareTo(rank(b));
        if (byRank != 0) return byRank;
        final byTime = b.phaseSince.compareTo(a.phaseSince);
        return byTime != 0 ? byTime : a.key.compareTo(b.key);
      });
    return list;
  }

  // -- the machines -------------------------------------------------------------

  void _onFleet() {
    if (_disposed) return;
    final seen = <String>{};
    for (final c in _fleet.connections) {
      final id = c.profile.id;
      seen.add(id);
      var m = _machines[id];
      if (m != null && !identical(m.connection, c)) {
        // The connection was rebuilt (credentials changed): its sessions point
        // at the old one.
        _dropMachine(id, forget: false);
        m = null;
      }
      m ??= _machines[id] = _Machine(c, _hostFor(c));
      if (c.isLive) {
        if (!m.live) {
          m.live = true;
          unawaited(_refreshMachine(m));
        }
      } else {
        m.live = false;
      }
    }
    for (final id in _machines.keys.toList()) {
      if (!seen.contains(id)) _dropMachine(id, forget: true);
    }
  }

  void _dropMachine(String id, {required bool forget}) {
    _machines.remove(id);
    var changed = false;
    for (final s in _sessions.values.toList()) {
      if (s.machine.profile.id != id) continue;
      _remove(s);
      changed = true;
    }
    if (forget) {
      reviewed.forgetMachine(id);
      if (_cache case final cache?) unawaited(cache.deleteMachine(id));
    }
    if (changed) _changed();
  }

  _Machine _machineOf(MachineConnection machine) {
    final m = _machines[machine.profile.id];
    if (m == null || !identical(m.connection, machine)) {
      throw AgentHostException('${machine.profile.label} is not connected.');
    }
    return m;
  }

  AgentHost _hostOf(MachineConnection machine) {
    final m = _machines[machine.profile.id];
    return m != null && identical(m.connection, machine) ? m.host : _hostFor(machine);
  }

  // -- listing --------------------------------------------------------------------

  /// The app has been in the background for [detachAfter] or longer: nothing
  /// asks the hosts anything until it is back.
  bool get _suspended {
    final at = _backgroundedAt;
    return at != null && !_keepAlive && _clock().difference(at) >= detachAfter;
  }

  @override
  Future<void> refresh() async {
    if (_disposed || _suspended) return;
    await Future.wait([
      for (final m in _machines.values.toList())
        if (m.connection.isLive) _refreshMachine(m),
    ]);
  }

  Future<void> _refreshMachine(_Machine m) async {
    if (_disposed || m.listing || _suspended) return;
    m.listing = true;
    final startedAt = _clock();
    try {
      final keepers = await m.host.list();
      if (_disposed || !identical(_machines[m.connection.profile.id], m)) return;
      _apply(m, keepers, startedAt);
    } on Exception {
      // The host did not answer: keep what is known; the next refresh tries
      // again.
    } finally {
      m.listing = false;
    }
  }

  void _apply(_Machine m, List<KeeperInfo> keepers, DateTime listedAt) {
    final id = m.connection.profile.id;
    var changed = false;
    final listed = <String>{};
    for (final k in keepers) {
      listed.add(k.id);
      if (!_sessions.containsKey('$id/${k.id}')) changed = true;
      _adopt(m, k);
    }
    for (final s in _sessions.values.toList()) {
      if (s.machine.profile.id != id || listed.contains(s.keeperId)) continue;
      // Started after this listing began, or in use: the host's forgetting it
      // is not news yet.
      if (s.attached || s.held || _adoptedAt[s.key]!.isAfter(listedAt)) continue;
      // The host forgot it: its saved transcript goes with it.
      if (_cache case final cache?) unawaited(cache.delete(s.key));
      _remove(s);
      changed = true;
    }
    reviewed.prune(id, listed);
    // The first listing of a machine in this run also sweeps the copies of
    // keepers that went while the app was closed (no session was ever made for
    // them to be removed above).
    if (_swept.add(id)) {
      if (_cache case final cache?) {
        unawaited(cache.retain(id, {
          ...listed,
          for (final s in _sessions.values)
            if (s.machine.profile.id == id) s.keeperId,
        }));
      }
    }
    _rebalance(id);
    if (changed) _changed();
  }

  /// The session for [info], made if there is none yet; a known one just
  /// learns what the listing says. Idempotent, so a listing and a `start` that
  /// both found a new keeper end up with one session.
  AcpAgentSession _adopt(_Machine m, KeeperInfo info) {
    final machineId = m.connection.profile.id;
    final key = '$machineId/${info.id}';
    if (_sessions[key] case final known?) {
      known.update(info);
      return known;
    }
    final s = AcpAgentSession(
      machine: m.connection,
      host: m.host,
      info: info,
      reviewed: reviewed,
      clock: _clock,
      backoff: _backoff,
      jitter: _jitter,
      maxAttempts: maxAttempts,
      detachAfter: detachAfter,
      notifyEvery: notifyEvery,
      flush: flush,
      onDemand: () => _rebalance(machineId),
      cache: _cache,
    );
    void listener() => _onSession(s);
    _sessions[s.key] = s;
    _adoptedAt[s.key] = _clock();
    _signatures[s.key] = _signature(s);
    _listeners[s.key] = listener;
    s.addListener(listener);
    s.keepAliveInBackground = _keepAlive;
    if (_backgroundedAt case final at?) s.background(since: at);
    return s;
  }

  /// Decides which sessions of [machineId] hold a channel: a screen's, then
  /// the ones with a waiting request, then the latest active (see the class
  /// comment). Idempotent; also nudges a wanted session whose machine just
  /// came back.
  void _rebalance(String machineId) {
    final m = _machines[machineId];
    if (_disposed || m == null || !m.connection.isLive) return;
    final mine = [
      for (final s in _sessions.values)
        if (s.machine.profile.id == machineId) s,
    ];
    final heldCount = mine.where((s) => s.held && s.attachable).length;
    final others = [
      for (final s in mine)
        if (!s.held && s.attachable) s,
    ];
    final blocked = [
      for (final s in others)
        if (_isBlocked(s)) s,
    ]..sort((a, b) {
        // The keeper's last event is, for a waiting request, about when it
        // began to wait; by the host's clock, comparable across sessions.
        final byWait = a.activityAt.compareTo(b.activityAt);
        return byWait != 0 ? byWait : a.key.compareTo(b.key);
      });
    final quiet = [
      for (final s in others)
        if (!_isBlocked(s)) s,
    ]..sort((a, b) {
        final byActivity = b.activityAt.compareTo(a.activityAt);
        return byActivity != 0 ? byActivity : a.key.compareTo(b.key);
      });
    var slots = maxAttached - heldCount;
    if (slots < 0) slots = 0;
    final chosen = <AcpAgentSession>{};
    for (final s in blocked) {
      if (slots == 0) break;
      chosen.add(s);
      slots--;
    }
    var recents = recentAttached < slots ? recentAttached : slots;
    for (final s in quiet) {
      if (recents == 0) break;
      chosen.add(s);
      recents--;
    }
    // Channels are given back before new ones are taken, so the host's count
    // does not overshoot on the way.
    final keep = [for (final s in mine) if (s.held || chosen.contains(s)) s];
    for (final s in mine) {
      if (!keep.contains(s)) s.want(false);
    }
    for (final s in keep) {
      s.want(true);
    }
    _preload(mine, blocked);
  }

  /// The sessions the board shows as needing the person get their saved
  /// transcript read now, no channel taken: a waiting one is attached anyway
  /// (above), and a finished one nobody has looked at is left unattached on
  /// purpose (attaching clears the keeper's "to review" for every device), so
  /// reading its copy is how its opening gets ready. A few per machine, none
  /// in the background.
  void _preload(List<AcpAgentSession> mine, List<AcpAgentSession> blocked) {
    if (_backgroundedAt != null) return;
    final needy = [
      ...blocked,
      for (final s in mine)
        if (!s.held && s.attachable && !_isBlocked(s) && s.unseenDone) s,
    ];
    for (final s in needy.take(maxAttached)) {
      if (!s.holdsChannel) s.preload();
    }
  }

  void _remove(AcpAgentSession s) {
    _sessions.remove(s.key);
    _adoptedAt.remove(s.key);
    _signatures.remove(s.key);
    if (_listeners.remove(s.key) case final listener?) s.removeListener(listener);
    s.dispose();
  }

  // What the board shows of a session; a change to any of it is worth a
  // rebuild.
  static String _signature(AgentSessionView s) {
    final pending = s.state.pending.isEmpty ? '' : '${s.state.pending.first.id}';
    return '${s.phase.index}|${s.unseenDone}|${s.link.index}|${s.title}|$pending|${s.error}|${s.waitingOnBackground}';
  }

  void _onSession(AcpAgentSession s) {
    if (_disposed) return;
    final signature = _signature(s);
    if (_signatures[s.key] == signature) return;
    _signatures[s.key] = signature;
    _changed();
    _rebalance(s.machine.profile.id);
  }

  void _changed() {
    if (_disposed) return;
    _sorted = null;
    notifyListeners();
  }

  // -- timer and lifecycle -------------------------------------------------------

  @override
  void setBoardVisible(bool visible) {
    if (_boardVisible == visible) return;
    _boardVisible = visible;
    _syncTimer();
  }

  void _syncTimer() {
    _timer?.cancel();
    _timer = null;
    if (_disposed) return;
    if (_backgroundedAt != null) {
      // Kept alive: the hosts are listed now and then, so a session that starts
      // waiting while it is unattached is seen. Otherwise nothing runs.
      if (_keepAlive) _timer = Timer.periodic(backgroundRefreshEvery, (_) => unawaited(refresh()));
      return;
    }
    if (!_boardVisible) return;
    _timer = Timer.periodic(refreshEvery, (_) => unawaited(refresh()));
  }

  @override
  set keepAliveInBackground(bool value) {
    if (_disposed || _keepAlive == value) return;
    _keepAlive = value;
    for (final s in _sessions.values.toList()) {
      s.keepAliveInBackground = value;
    }
    _syncTimer();
  }

  /// Feeds app lifecycle transitions, as [FleetRepository.onLifecycleState]
  /// gets them. `hidden`/`paused`: the listing timer stops and every session
  /// starts its clock to detaching. `resumed`: sessions attach again and the
  /// hosts are listed.
  void onLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        if (_backgroundedAt != null) return;
        _backgroundedAt = _clock();
        _syncTimer();
        for (final s in _sessions.values.toList()) {
          s.onLifecycleState(state);
        }
      case AppLifecycleState.resumed:
        if (_backgroundedAt == null) return;
        _backgroundedAt = null;
        for (final s in _sessions.values.toList()) {
          s.onLifecycleState(state);
        }
        _syncTimer();
        unawaited(refresh());
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  // -- starting -------------------------------------------------------------------

  @override
  Future<Set<String>> available(MachineConnection machine) async {
    try {
      return await _hostOf(machine).available();
    } on AgentHostException {
      rethrow;
    } on Exception catch (e) {
      throw AgentHostException(_unreachable(machine, e));
    }
  }

  @override
  Future<AgentSessionView> start({
    required MachineConnection machine,
    required String agent,
    required String cwd,
  }) async {
    final m = await _preflight(machine, agent);
    final info = await _startKeeper(m, agent, cwd);
    return _openNew(m, info);
  }

  /// The machine of [machine] once [agent] is known to be runnable on it: the
  /// route exists, the agent is installed, the host answers.
  Future<_Machine> _preflight(MachineConnection machine, String agent) async {
    final route = agentRouteById(agent);
    if (route == null) throw AgentHostException('There is no way to run "$agent" as an agent session.', fatal: true);
    final m = _machineOf(machine);

    final Set<String> installed;
    try {
      installed = await m.host.available();
    } on AgentHostException {
      rethrow;
    } on Exception catch (e) {
      throw AgentHostException(_unreachable(machine, e));
    }
    if (!installed.contains(agent)) {
      throw AgentHostException('${route.label} is not installed on ${machine.profile.label}.', fatal: true);
    }
    return m;
  }

  /// Starts a keeper for [agent] in [cwd]. One that finished starting after
  /// the machine went away is killed again.
  Future<KeeperInfo> _startKeeper(_Machine m, String agent, String cwd) async {
    final KeeperInfo info;
    try {
      info = await m.host.start(agent: agent, cwd: cwd);
    } on AgentHostException {
      rethrow;
    } on Exception catch (e) {
      throw AgentHostException(_unreachable(m.connection, e));
    }
    if (_disposed || !identical(_machines[m.connection.profile.id], m)) {
      unawaited(_quietKill(m.host, info.id));
      throw AgentHostException('${m.connection.profile.label} is no longer connected.');
    }
    return info;
  }

  /// Adopts the session of the new keeper [info] and attaches it; with
  /// [sessionId] it opens that past session of the agent ([continuing] is the
  /// ended session it carries on) instead of creating one. A session that
  /// cannot be attached is removed and its keeper killed.
  Future<AcpAgentSession> _openNew(
    _Machine m,
    KeeperInfo info, {
    String? sessionId,
    AcpAgentSession? continuing,
  }) async {
    final session = _adopt(m, info);
    if (sessionId != null) session.openPast(sessionId, continuing: continuing);
    // Held while it starts, so no re-think of who is attached can take its
    // channel away mid-attach.
    session.acquire();
    _changed();
    await session.connect();
    // A listing that found the keeper first may have attached it before the
    // past session was named: then it holds a session of its own.
    final other = session.attached && sessionId != null && session.sessionId != sessionId;
    if (!session.attached || other) {
      final why = other ? 'The session could not be reopened.' : session.error ?? 'The session could not be attached.';
      final fatal = other || session.link == AgentLink.failed;
      session.release();
      if (_sessions[session.key] == session) {
        _remove(session);
        _changed();
      }
      await _quietKill(m.host, info.id);
      throw AgentHostException(why, fatal: fatal);
    }
    session.release();
    return session;
  }

  @override
  Future<PastSessions> history({required MachineConnection machine, required String agent, String? cwd}) async {
    final m = _machineOf(machine);
    try {
      return await m.host.history(agent: agent, cwd: cwd);
    } on AgentHostException {
      rethrow;
    } on Exception catch (e) {
      throw AgentHostException(_unreachable(machine, e));
    }
  }

  /// Reopens in flight, by machine, agent and session id: a second ask joins
  /// the first, so a double tap never starts two keepers.
  final _reopening = <String, Future<AgentSessionView>>{};

  @override
  Future<AgentSessionView> resume({
    required MachineConnection machine,
    required String agent,
    required String cwd,
    required String sessionId,
    String? replaces,
  }) async {
    final m = _machineOf(machine);
    final machineId = machine.profile.id;
    // A keeper that holds the conversation already (an agent refuses a second
    // client on a thread, or kills the first) is the way back to it.
    for (final s in _sessions.values) {
      if (s.machine.profile.id != machineId || s.agent != agent || s.sessionId != sessionId || _isGone(s)) continue;
      await _dropEnded(m, replaces, sessionId);
      return s;
    }
    final slot = '$machineId/$agent/$sessionId';
    if (_reopening[slot] case final running?) return running;
    final run = _reopen(m, agent: agent, cwd: cwd, sessionId: sessionId, replaces: replaces);
    _reopening[slot] = run;
    try {
      return await run;
    } finally {
      _reopening.remove(slot);
    }
  }

  Future<AgentSessionView> _reopen(
    _Machine m, {
    required String agent,
    required String cwd,
    required String sessionId,
    required String? replaces,
  }) async {
    await _preflight(m.connection, agent);
    final info = await _startKeeper(m, agent, cwd);
    final session = await _openNew(m, info, sessionId: sessionId, continuing: _endedSession(m, replaces, sessionId));
    await _dropEnded(m, replaces, sessionId);
    return session;
  }

  /// The agent process of [s] is gone and nothing will bring it back by itself
  /// (a session another device took over is not).
  static bool _isGone(AcpAgentSession s) => s.link == AgentLink.ended && !s.evicted;

  /// The ended session [key] of machine [m] that holds [sessionId], else null.
  AcpAgentSession? _endedSession(_Machine m, String? key, String sessionId) {
    final s = key == null ? null : _sessions[key];
    if (s == null || s.machine.profile.id != m.connection.profile.id) return null;
    return _isGone(s) && s.sessionId == sessionId ? s : null;
  }

  /// Drops the ended session [key] that a reopened one continues: its saved
  /// copy, its row, and its exited record on the host (which would bring the
  /// row back at the next listing).
  Future<void> _dropEnded(_Machine m, String? key, String sessionId) async {
    final old = _endedSession(m, key, sessionId);
    if (old == null) return;
    if (_cache case final cache?) unawaited(cache.delete(old.key));
    _remove(old);
    _changed();
    await _quietKill(m.host, old.keeperId);
  }

  static Future<void> _quietKill(AgentHost host, String keeperId) async {
    try {
      await host.kill(keeperId);
    } on Object {
      // Nothing more to do for a keeper that cannot be reached.
    }
  }

  static String _unreachable(MachineConnection machine, Object e) => switch (e) {
        TimeoutException() => '${machine.profile.label} did not answer in time.',
        _ => 'Could not reach ${machine.profile.label}: $e',
      };

  @override
  Preconnect preconnect(String sessionKey) {
    final s = _sessions[sessionKey];
    // Nothing speculative in the background (the radio sleeps), for a machine
    // that is not there, or a session that cannot be attached.
    if (_disposed || s == null || _backgroundedAt != null || !s.attachable || !s.machine.isLive) {
      return Preconnect.none;
    }
    // Never past the machine's channel limit: a finger that slides away must
    // not have cost another session its channel.
    if (!s.holdsChannel && !_hasRoom(s)) return Preconnect.none;
    return _Warm(s, preconnectHold);
  }

  /// A channel is free on [s]'s machine without letting another go.
  bool _hasRoom(AcpAgentSession s) {
    var used = 0;
    for (final other in _sessions.values) {
      if (identical(other, s) || other.machine.profile.id != s.machine.profile.id) continue;
      if (other.held || other.holdsChannel) used++;
    }
    return used < maxAttached;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _fleet.removeListener(_onFleet);
    for (final s in _sessions.values.toList()) {
      if (_listeners.remove(s.key) case final listener?) s.removeListener(listener);
      s.dispose();
    }
    _sessions.clear();
    if (_ownsReviewed) reviewed.dispose();
    super.dispose();
  }
}

/// A finger-down hold on a session ([AgentSessionRepository.preconnect]): it
/// lets go when cancelled, or by itself after [ttl].
class _Warm implements Preconnect {
  _Warm(this._session, Duration ttl) {
    _session.warm();
    _timer = Timer(ttl, cancel);
  }

  final AcpAgentSession _session;
  late final Timer _timer;
  var _done = false;

  @override
  void cancel() {
    if (_done) return;
    _done = true;
    _timer.cancel();
    _session.cool();
  }
}

class _Machine {
  _Machine(this.connection, this.host);

  final MachineConnection connection;
  final AgentHost host;
  bool live = false;
  bool listing = false;
}
