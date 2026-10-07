import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';

import '../models/herdr_models.dart';
import '../models/machine_profile.dart';
import '../services/network_monitor.dart';
import 'agent_screens.dart';
import 'machine_connection.dart';
import 'machine_repository.dart';
import 'reviewed_state.dart';

/// Builds the connection to [profile]. [secrets] reads its credentials from
/// the keychain; it is for the connection to call when it needs them (to open
/// the transport), not for the factory to wait on: a connection that exists
/// already shows what it cached, and the keychain answers meanwhile.
typedef ConnectionFactory = MachineConnection Function(
  MachineProfile profile,
  Future<MachineSecrets> Function() secrets,
);

/// An agent pane together with where it lives.
class FleetAgent {
  const FleetAgent({
    required this.machine,
    required this.pane,
    required this.workspace,
  });

  final MachineConnection machine;
  final Pane pane;
  final Workspace? workspace;

  /// Stale when its machine is not currently online.
  bool get stale => !machine.isLive;

  /// Blocked on the person, and reachable (an offline machine's last-known
  /// "needs you" cannot be answered): `AttentionSet`'s rule for a pane.
  bool get needsYou => pane.status == AgentStatus.blocked && !stale;

  /// Finished and not yet reviewed on this phone. [pane] is what the app
  /// shows, where a reviewed agent is already idle.
  bool get toReview => pane.status == AgentStatus.done;

  /// Which agent program runs in the pane (`omp`, `claude`, ...): what the
  /// agent says about its session, else what herdr detected.
  String? get agentKind => pane.session?.agent.isNotEmpty == true ? pane.session!.agent : pane.agent;

  /// The session log the agent appends its transcript to, on the machine, when
  /// it names one: a `kind: path` session that is a `.jsonl` file. Null
  /// otherwise (the pane then has no observed chat).
  String? get sessionLogPath {
    final session = pane.session;
    if (session == null || session.kind != 'path' || !session.value.endsWith('.jsonl')) return null;
    return session.value;
  }
}

/// All saved machines, each with its own [MachineConnection], plus the
/// merged cross-machine agent view.
class FleetRepository extends ChangeNotifier {
  FleetRepository({
    required this._machines,
    required this._connect,
    required this._network,
    ReviewedState? reviewed,
    this._screens,
    this.longAway = const Duration(seconds: 5),
    this.backgroundSuspendAfter = const Duration(seconds: 90),
    this._clock = DateTime.now,
  })  : reviewed = reviewed ?? ReviewedState(),
        _ownsReviewed = reviewed == null {
    _machines.addListener(_onMachinesChanged);
    _screens?.addListener(_reviewShown);
    _networkSub = _network.changes.listen(_onNetworkChanged);
    _onMachinesChanged();
  }

  final MachineRepository _machines;
  final ConnectionFactory _connect;
  final NetworkMonitor _network;
  final DateTime Function() _clock;

  /// Which finished agents the person has looked at (see [ReviewedState]);
  /// every connection shows those as idle. Kept in memory only unless the
  /// caller passed one with a store.
  final ReviewedState reviewed;
  final bool _ownsReviewed;

  /// The agent screen in front: a terminal there is being looked at.
  final AgentScreens? _screens;

  /// Sockets die while the app is suspended. Back after more than this, the
  /// connections are reset instead of trusted.
  final Duration longAway;

  /// Continuous time in the background after which connections are torn
  /// down to save battery.
  final Duration backgroundSuspendAfter;

  late final StreamSubscription<NetworkState> _networkSub;
  DateTime? _backgroundedAt;
  Timer? _suspendTimer;
  bool _suspended = false;
  final Map<String, MachineConnection> _connections = {};
  final Map<String, String> _keys = {};
  Future<void> _reconciling = Future.value();
  bool _disposed = false;
  bool _keepAlive = false;
  bool _graceElapsed = false;
  bool _background = false;

  /// Keep the connections up while the app is in the background, instead of
  /// suspending them [backgroundSuspendAfter] after it left. The notifier turns
  /// it on while it has agents to watch (and a quiet foreground notice keeps
  /// Android from freezing the process). Off, the usual rule applies at once:
  /// when the grace period has already run out by the time it goes off,
  /// the connections are suspended right then.
  bool get keepAliveInBackground => _keepAlive;
  set keepAliveInBackground(bool value) {
    if (_disposed || _keepAlive == value) return;
    _keepAlive = value;
    _syncBackground();
    notifyListeners(); // the screens that offer "keep watching" read it
    if (!value && _backgroundedAt != null && _graceElapsed && !_suspended) onBackgroundTimeout();
  }

  /// Connections in saved-machine order.
  List<MachineConnection> get connections => [
        for (final m in _machines.machines)
          ?_connections[m.id],
      ];

  MachineConnection? connection(String machineId) => _connections[machineId];

  /// Every agent pane on every machine ([MachineConnection.agentPanes]: not a
  /// keeper's view of an agent session), most urgent first, then by machine
  /// then pane id for a stable order.
  List<FleetAgent> get agents {
    final out = <FleetAgent>[
      for (final c in connections)
        for (final p in c.agentPanes)
          FleetAgent(
            machine: c,
            pane: p,
            workspace: c.snapshot.workspace(p.workspaceId),
          ),
    ];
    out.sort((a, b) {
      final byStatus =
          a.pane.status.attentionRank.compareTo(b.pane.status.attentionRank);
      if (byStatus != 0) return byStatus;
      final byMachine = a.machine.profile.label.compareTo(b.machine.profile.label);
      return byMachine != 0 ? byMachine : a.pane.id.compareTo(b.pane.id);
    });
    return out;
  }

  /// The person looked at [paneId] of [machineId] (opened or answered it): if
  /// it is done, it is reviewed and shows as idle from now on. herdr's own seen
  /// state is never touched (focusing would move the desktop's view).
  void markReviewed(String machineId, String paneId) =>
      _connections[machineId]?.markReviewed(paneId);

  void _onConnectionChanged() {
    notifyListeners();
    // A pane that finishes while its terminal is in front is read as it
    // happens.
    if (_screens?.front != null) _reviewShown();
  }

  /// The terminal in front of the person is being looked at, so a finished
  /// agent there is reviewed. Nothing is reviewed while the app is in the
  /// background (the phone is in a pocket). A chat marks what it shows itself,
  /// once its transcript is whole (`AgentSessionScreen`).
  void _reviewShown() {
    if (_disposed || _backgroundedAt != null) return;
    final front = _screens?.front;
    if (front == null || front.view != AgentView.terminal) return;
    if (front.agent case PaneAgent(:final machineId, :final paneId)) markReviewed(machineId, paneId);
  }

  /// Everything except the host-key pin, which changes on first connect and
  /// must not restart the connection that just made it.
  String _keyOf(MachineProfile p) => [
        _machines.credentialRevision(p.id),
        p.label,
        p.host,
        p.port,
        p.username,
        p.auth.name,
        p.session,
        p.socketPath,
        p.enabled,
      ].join('|');

  void _onMachinesChanged() {
    _reconciling = _reconciling.then((_) => _reconcile());
  }

  Future<void> _reconcile() async {
    if (_disposed) return;
    final wanted = {for (final m in _machines.machines) m.id: m};
    var changed = false;

    for (final id in _connections.keys.toList()) {
      if (!wanted.containsKey(id) || _keys[id] != _keyOf(wanted[id]!)) {
        final gone = _connections.remove(id)!..removeListener(_onConnectionChanged);
        if (!wanted.containsKey(id)) gone.forget();
        gone.dispose();
        _keys.remove(id);
        changed = true;
      }
    }
    for (final p in wanted.values) {
      if (_connections.containsKey(p.id)) continue;
      final c = _connect(p, () => _machines.secretsFor(p.id))
        ..attachReviewed(reviewed)
        ..addListener(_onConnectionChanged);
      _connections[p.id] = c;
      _keys[p.id] = _keyOf(p);
      if (_network.current.online) {
        c.start();
      } else {
        c.goOffline();
      }
      if (_background) c.setBackground(true);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Reconnect machines that are down and refresh the ones that are up.
  /// Used for pull-to-refresh; does nothing while the device has no network.
  Future<void> retryAll() async {
    if (!_network.current.online) return;
    await Future.wait([
      for (final c in connections)
        if (c.state == LinkState.online)
          c.refresh().catchError((Object _) {})
        else
          Future<void>.sync(c.retry),
    ]);
  }

  /// Feeds app lifecycle transitions: `hidden`/`paused` start the background
  /// clock, `resumed` ends it. `inactive` is transient and ignored.
  void onLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        if (_backgroundedAt != null) return;
        _backgroundedAt = _clock();
        _graceElapsed = false;
        _syncBackground();
        _suspendTimer = Timer(backgroundSuspendAfter, _graceEnded);
      case AppLifecycleState.resumed:
        final at = _backgroundedAt;
        if (at == null) return;
        _backgroundedAt = null;
        _graceElapsed = false;
        _syncBackground();
        _suspendTimer?.cancel();
        _suspendTimer = null;
        unawaited(onForeground(away: _clock().difference(at)));
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  /// The app is back after [away]. A long absence (or a suspension) means
  /// the sockets are dead, so reset and reconnect now; a short one only
  /// needs a refresh. With [keepAliveInBackground] on, the process was kept
  /// running and the connections never suspended, so a refresh is enough
  /// whatever the absence: a link that died meanwhile is found by that.
  Future<void> onForeground({required Duration away}) async {
    if (_disposed) return;
    final wasSuspended = _suspended;
    _suspended = false;
    if (!_network.current.online) {
      for (final c in connections) {
        c.goOffline();
      }
    } else if (wasSuspended || (away > longAway && !_keepAlive)) {
      for (final c in connections) {
        c.reconnect();
      }
    } else {
      await retryAll();
    }
  }

  /// Continuously backgrounded for too long: stop every connection until the
  /// next foreground.
  void onBackgroundTimeout() {
    if (_disposed) return;
    _suspended = true;
    for (final c in connections) {
      c.suspend();
    }
  }

  void _graceEnded() {
    _graceElapsed = true;
    if (!_keepAlive) onBackgroundTimeout();
  }

  /// The background profile (relaxed heartbeats and poll, see
  /// [MachineConnection.setBackground]) holds while the app is in the
  /// background AND the connections are kept alive for watching.
  void _syncBackground() {
    final background = _backgroundedAt != null && _keepAlive;
    if (background == _background) return;
    _background = background;
    for (final c in connections) {
      c.setBackground(background);
    }
  }

  void _onNetworkChanged(NetworkState state) {
    if (_disposed) return;
    for (final c in connections) {
      if (!state.online) {
        c.goOffline();
      } else if (!_suspended) {
        c.reconnect();
      }
    }
  }

  /// Completes when pending add/remove/edit reconciliation has been applied.
  Future<void> settled() => _reconciling;

  @override
  void dispose() {
    _disposed = true;
    _suspendTimer?.cancel();
    unawaited(_networkSub.cancel());
    _machines.removeListener(_onMachinesChanged);
    _screens?.removeListener(_reviewShown);
    for (final c in _connections.values) {
      c.removeListener(_onConnectionChanged);
      c.dispose();
    }
    _connections.clear();
    if (_ownsReviewed) reviewed.dispose();
    super.dispose();
  }
}
