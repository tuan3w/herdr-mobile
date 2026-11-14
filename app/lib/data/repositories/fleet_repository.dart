import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';

import '../models/machine_profile.dart';
import 'background_grace.dart';
import '../services/network_monitor.dart';
import 'agent_screens.dart';
import 'fleet_agent.dart';
import 'machine_connection.dart';
import 'machine_repository.dart';
import 'pane_session_names.dart';
import 'reviewed_state.dart';

export 'fleet_agent.dart';

/// Builds the connection to [profile]. [secrets] reads its credentials from
/// the keychain; it is for the connection to call when it needs them (to open
/// the transport), not for the factory to wait on: a connection that exists
/// already shows what it cached, and the keychain answers meanwhile.
typedef ConnectionFactory = MachineConnection Function(
  MachineProfile profile,
  Future<MachineSecrets> Function() secrets,
);

/// All saved machines, each with its own [MachineConnection], plus the
/// merged cross-machine agent view.
class FleetRepository extends ChangeNotifier {
  FleetRepository({
    required this._machines,
    required this._connect,
    required this._network,
    ReviewedState? reviewed,
    this._screens,
    PaneSessionNames? names,
    this.probeTimeout = const Duration(seconds: 4),
    this.backgroundSuspendAfter = defaultBackgroundGrace,
    this._clock = DateTime.now,
  }) : reviewed = reviewed ?? ReviewedState(),
       _ownsReviewed = reviewed == null {
    this.names =
        names ?? PaneSessionNames(agents: () => agents, canRead: () => _backgroundedAt == null && _suspended.isEmpty);
    this.names.addListener(notifyListeners);
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

  /// How long a connection that is up is given to answer when the app is back
  /// from the background, before it is rebuilt (see [onForeground]).
  final Duration probeTimeout;

  /// Continuous time in the background after which connections are torn down
  /// to save battery; asked when the app goes away.
  final BackgroundGrace backgroundSuspendAfter;

  late final StreamSubscription<NetworkState> _networkSub;
  DateTime? _backgroundedAt;
  Timer? _suspendTimer;

  /// Machines whose connection was torn down after the grace period, until
  /// the next foreground.
  final Set<String> _suspended = {};
  final Map<String, MachineConnection> _connections = {};
  final Map<String, String> _keys = {};
  Future<void> _reconciling = Future.value();
  bool _disposed = false;
  bool _keepAlive = false;
  final List<_Hold> _holds = [];
  bool _pageNotice = false;
  bool _graceElapsed = false;

  /// Machines in the background profile.
  final Set<String> _background = {};

  /// Whether any connection is kept up in the background (see [keeps]).
  /// Set by the notifier while it has agents to watch (and a quiet
  /// foreground notice keeps Android from freezing the process): every
  /// connection is then kept instead of suspended [backgroundSuspendAfter]
  /// after the app left. Off, the usual rule applies at once: when the grace
  /// period has already run out by the time it goes off, the connections
  /// nothing keeps are suspended right then.
  bool get keepAliveInBackground => _keepAlive || (_pageNotice && _holds.isNotEmpty);
  set keepAliveInBackground(bool value) {
    if (_disposed || _keepAlive == value) return;
    _keepAlive = value;
    _keepChanged();
  }

  /// What the notifier asked for, without the pages: the agents it watches.
  bool get watchingAgents => _keepAlive;

  /// Whether a page is held open ([holdAlive]): the notifier runs its
  /// foreground notice for it, whether or not alerts are on.
  bool get held => _holds.isNotEmpty;

  /// The pages held open, as the Watching notice names them
  /// (`localhost:8790 on devbox`), oldest first.
  List<String> get heldPages => [for (final h in _holds) h.page];

  /// The notifier's foreground notice is up for the pages held open. Only
  /// then does a hold keep its machine's connection: without the notice
  /// (refused by Android, or no notices at all, as on iOS) Android freezes
  /// the process anyway, its sockets die, and the old rule (suspend after
  /// [backgroundSuspendAfter], reconnect on return) is the honest one.
  bool get pageNotice => _pageNotice;
  set pageNotice(bool value) {
    if (_disposed || _pageNotice == value) return;
    _pageNotice = value;
    _keepChanged();
  }

  /// Whether [machineId]'s connection is kept up in the background: every
  /// machine while agents are watched, else the machines of the pages held
  /// open while their notice is up.
  bool keeps(String machineId) => _keepAlive || (_pageNotice && _holds.any((h) => h.machineId == machineId));

  /// Holds [machineId]'s connection up in the background, for the page
  /// named [page] (`localhost:8790 on devbox`, said by the Watching notice),
  /// until the returned callback runs (once; a second call does nothing).
  /// Holds count, and hold only their own machine: another machine follows
  /// the usual rule.
  ///
  /// Why: a page from a machine (`WebPreviewScreen`) talks to it over the
  /// connection, and in a Custom Tab the app went to the background, Android
  /// dropped the SSH connection and the page waited forever. While the page
  /// is open, switching apps or turning the screen off must not end it.
  VoidCallback holdAlive(String machineId, {required String page}) {
    if (_disposed) return () {};
    final hold = _Hold(machineId, page);
    _holds.add(hold);
    _keepChanged();
    var released = false;
    return () {
      if (released || _disposed) return;
      released = true;
      _holds.remove(hold);
      _keepChanged();
    };
  }

  void _keepChanged() {
    _syncBackground();
    notifyListeners(); // the notifier and the screens that offer "keep watching" read it
    if (_backgroundedAt != null && _graceElapsed) _letGo();
  }

  /// Past the grace period: tears down every connection nothing keeps.
  void _letGo() {
    for (final MapEntry(key: id, value: c) in _connections.entries) {
      if (keeps(id) || !_suspended.add(id)) continue;
      c.suspend();
    }
  }

  /// Connections in saved-machine order.
  List<MachineConnection> get connections => [for (final m in _machines.machines) ?_connections[m.id]];

  MachineConnection? connection(String machineId) => _connections[machineId];

  /// One agent pane as the board has it (with the name read for it), or null
  /// when the machine or the pane is not there.
  FleetAgent? agent(String machineId, String paneId) {
    final c = _connections[machineId];
    final p = c?.paneById(paneId);
    if (c == null || p == null) return null;
    return FleetAgent(
      machine: c,
      pane: p,
      workspace: c.snapshot.workspace(p.workspaceId),
      sessionName: names.nameFor(machineId, paneId, FleetAgent.logPathOf(p)),
      lastActive: names.lastActiveFor(machineId, paneId, FleetAgent.logPathOf(p)),
    );
  }

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
            sessionName: names.nameFor(c.profile.id, p.id, FleetAgent.logPathOf(p)),
            lastActive: names.lastActiveFor(c.profile.id, p.id, FleetAgent.logPathOf(p)),
          ),
    ];
    out.sort((a, b) {
      final byStatus = a.pane.status.attentionRank.compareTo(b.pane.status.attentionRank);
      if (byStatus != 0) return byStatus;
      final byMachine = a.machine.profile.label.compareTo(b.machine.profile.label);
      return byMachine != 0 ? byMachine : a.pane.id.compareTo(b.pane.id);
    });
    return out;
  }

  /// Names read from agents' session logs for panes whose title says nothing.
  late final PaneSessionNames names;

  /// The person looked at [paneId] of [machineId] (opened or answered it): if
  /// it is done, it is reviewed and shows as idle from now on. herdr's own seen
  /// state is never touched (focusing would move the desktop's view).
  void markReviewed(String machineId, String paneId) => _connections[machineId]?.markReviewed(paneId);

  void _onConnectionChanged() {
    notifyListeners();
    names.sync();
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

  /// One machine that cannot be set up or torn down (a connection factory that
  /// throws) must not decide for the others: every machine is handled on its
  /// own, and a failure is logged and left for the next change to try again
  /// (a machine with no connection is built again by the next reconcile).
  Future<void> _reconcile() async {
    if (_disposed) return;
    final wanted = {for (final m in _machines.machines) m.id: m};
    var changed = false;

    for (final id in _connections.keys.toList()) {
      if (!wanted.containsKey(id) || _keys[id] != _keyOf(wanted[id]!)) {
        final gone = _connections.remove(id)!..removeListener(_onConnectionChanged);
        _keys.remove(id);
        _background.remove(id);
        _suspended.remove(id);
        changed = true;
        try {
          if (!wanted.containsKey(id)) gone.forget();
          gone.dispose();
        } on Object catch (e, s) {
          debugPrint('herdr: could not close the connection to $id: $e\n$s');
        }
      }
    }
    for (final p in wanted.values) {
      if (_connections.containsKey(p.id)) continue;
      try {
        final c = _connect(p, () => _machines.secretsFor(p.id))
          ..attachReviewed(reviewed)
          ..addListener(_onConnectionChanged);
        _connections[p.id] = c;
        _keys[p.id] = _keyOf(p);
        changed = true;
        if (_network.current.online) {
          c.start();
        } else {
          c.goOffline();
        }
        if (_backgroundedAt != null && keeps(p.id)) {
          _background.add(p.id);
          c.setBackground(true);
        }
      } on Object catch (e, s) {
        debugPrint('herdr: could not set up the connection to ${p.id}: $e\n$s');
      }
    }
    if (changed) notifyListeners();
  }

  /// Reconnect machines that are down and refresh the ones that are up.
  /// Used for pull-to-refresh; does nothing while the device has no network.
  Future<void> retryAll() => _refresh(connections);

  Future<void> _refresh(Iterable<MachineConnection> which) async {
    if (!_network.current.online) return;
    await Future.wait([
      for (final c in which)
        if (c.state == LinkState.online) c.refresh().catchError((Object _) {}) else Future<void>.sync(c.retry),
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
        _suspendTimer = Timer(backgroundSuspendAfter(), _graceEnded);
      case AppLifecycleState.resumed:
        if (_backgroundedAt == null) return;
        _backgroundedAt = null;
        _graceElapsed = false;
        _syncBackground();
        names.sync(); // reads that waited for the foreground start now
        _suspendTimer?.cancel();
        _suspendTimer = null;
        unawaited(onForeground());
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  /// The app is back. A connection that was let go (suspended after the grace
  /// period) is rebuilt now. One that was not is asked something small instead
  /// of being rebuilt: the person who stepped out to copy something comes back
  /// to a board that is already current, not to a handshake. Whether the socket
  /// survived (Android may have frozen the process, a handover may have moved
  /// the path) is learned from the answer: an error, or none within
  /// [probeTimeout], and the connection is rebuilt, as it always was. A
  /// connection that was kept ([keeps]) is probed the same way.
  Future<void> onForeground() async {
    if (_disposed) return;
    final wasSuspended = {..._suspended};
    _suspended.clear();
    if (!_network.current.online) {
      for (final c in connections) {
        c.goOffline();
      }
      return;
    }
    final probe = <MachineConnection>[];
    for (final c in connections) {
      if (wasSuspended.contains(c.profile.id)) {
        c.reconnect();
      } else {
        probe.add(c);
      }
    }
    await Future.wait([
      for (final c in probe)
        if (c.state == LinkState.online)
          c.refresh().timeout(probeTimeout).catchError((Object _) => c.reconnect())
        else
          Future<void>.sync(c.retry),
    ]);
  }

  /// Continuously backgrounded for too long: stop every connection until the
  /// next foreground.
  void onBackgroundTimeout() {
    if (_disposed) return;
    for (final c in connections) {
      _suspended.add(c.profile.id);
      c.suspend();
    }
  }

  void _graceEnded() {
    _graceElapsed = true;
    _letGo();
  }

  /// The background profile (relaxed heartbeats and poll, see
  /// [MachineConnection.setBackground]) holds for a connection while the app
  /// is in the background AND that connection is kept ([keeps]).
  void _syncBackground() {
    for (final MapEntry(key: id, value: c) in _connections.entries) {
      final on = _backgroundedAt != null && keeps(id);
      if (on == _background.contains(id)) continue;
      if (on) {
        _background.add(id);
      } else {
        _background.remove(id);
      }
      c.setBackground(on);
    }
  }

  void _onNetworkChanged(NetworkState state) {
    if (_disposed) return;
    for (final c in connections) {
      if (!state.online) {
        c.goOffline();
      } else if (!_suspended.contains(c.profile.id)) {
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
    names
      ..removeListener(notifyListeners)
      ..dispose();
    if (_ownsReviewed) reviewed.dispose();
    super.dispose();
  }
}

/// One page held open ([FleetRepository.holdAlive]).
class _Hold {
  _Hold(this.machineId, this.page);

  final String machineId;
  final String page;
}
