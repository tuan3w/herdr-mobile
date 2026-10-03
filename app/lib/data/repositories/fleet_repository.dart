import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';

import '../models/herdr_models.dart';
import '../models/machine_profile.dart';
import '../services/network_monitor.dart';
import 'machine_connection.dart';
import 'machine_repository.dart';

typedef ConnectionFactory = MachineConnection Function(
  MachineProfile profile,
  MachineSecrets secrets,
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
}

/// All saved machines, each with its own [MachineConnection], plus the
/// merged cross-machine agent view.
class FleetRepository extends ChangeNotifier {
  FleetRepository({
    required this._machines,
    required this._connect,
    required this._network,
    this.longAway = const Duration(seconds: 5),
    this.backgroundSuspendAfter = const Duration(seconds: 90),
    this._clock = DateTime.now,
  }) {
    _machines.addListener(_onMachinesChanged);
    _networkSub = _network.changes.listen(_onNetworkChanged);
    _onMachinesChanged();
  }

  final MachineRepository _machines;
  final ConnectionFactory _connect;
  final NetworkMonitor _network;
  final DateTime Function() _clock;

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

  /// Connections in saved-machine order.
  List<MachineConnection> get connections => [
        for (final m in _machines.machines)
          ?_connections[m.id],
      ];

  MachineConnection? connection(String machineId) => _connections[machineId];

  /// Every agent pane on every machine, most urgent first, then by machine
  /// then pane id for a stable order.
  List<FleetAgent> get agents {
    final out = <FleetAgent>[
      for (final c in connections)
        for (final p in c.snapshot.agentPanes)
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

  /// Agents that want the user: blocked, or finished and unseen.
  int get attentionCount => agents
      .where((a) => a.pane.status == AgentStatus.blocked || a.pane.status == AgentStatus.done)
      .length;

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
        final gone = _connections.remove(id)!..removeListener(notifyListeners);
        if (!wanted.containsKey(id)) gone.forget();
        gone.dispose();
        _keys.remove(id);
        changed = true;
      }
    }
    for (final p in wanted.values) {
      if (_connections.containsKey(p.id)) continue;
      final secrets = await _machines.secretsFor(p.id);
      if (_disposed) return;
      final c = _connect(p, secrets)..addListener(notifyListeners);
      _connections[p.id] = c;
      _keys[p.id] = _keyOf(p);
      if (_network.current.online) {
        c.start();
      } else {
        c.goOffline();
      }
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
        _suspendTimer = Timer(backgroundSuspendAfter, onBackgroundTimeout);
      case AppLifecycleState.resumed:
        final at = _backgroundedAt;
        if (at == null) return;
        _backgroundedAt = null;
        _suspendTimer?.cancel();
        _suspendTimer = null;
        unawaited(onForeground(away: _clock().difference(at)));
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  /// The app is back after [away]. A long absence (or a suspension) means
  /// the sockets are dead, so reset and reconnect now; a short one only
  /// needs a refresh.
  Future<void> onForeground({required Duration away}) async {
    if (_disposed) return;
    final wasSuspended = _suspended;
    _suspended = false;
    if (!_network.current.online) {
      for (final c in connections) {
        c.goOffline();
      }
    } else if (wasSuspended || away > longAway) {
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
    for (final c in _connections.values) {
      c.removeListener(notifyListeners);
      c.dispose();
    }
    _connections.clear();
    super.dispose();
  }
}
