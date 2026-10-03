import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// What the device's connectivity looks like right now.
class NetworkState {
  const NetworkState({required this.online, required this.signature});

  /// At least one interface is up. Says nothing about reachability of any
  /// particular host (LAN and VPN hosts work without internet).
  final bool online;

  /// Identifies the set of active interface types (`mobile`, `vpn+wifi`).
  /// Changing it while [online] means the route changed and every open
  /// socket is presumed dead, e.g. Wi-Fi to cellular.
  final String signature;

  @override
  bool operator ==(Object other) =>
      other is NetworkState &&
      other.online == online &&
      other.signature == signature;

  @override
  int get hashCode => Object.hash(online, signature);

  @override
  String toString() => 'NetworkState(online: $online, $signature)';
}

abstract interface class NetworkMonitor {
  /// Settled changes only; never emits a state equal to the previous one.
  Stream<NetworkState> get changes;

  NetworkState get current;
}

/// [NetworkMonitor] on `connectivity_plus`.
class ConnectivityNetworkMonitor implements NetworkMonitor {
  ConnectivityNetworkMonitor({
    Connectivity? connectivity,
    this.settle = const Duration(milliseconds: 300),
  }) : _connectivity = connectivity ?? Connectivity() {
    _sub = _connectivity.onConnectivityChanged.listen(_onResults);
    unawaited(_prime());
  }

  final Connectivity _connectivity;

  /// Platforms report one switch as a burst (down, then up, then the new
  /// interface); wait until it has settled before telling anyone.
  final Duration settle;

  final _changes = StreamController<NetworkState>.broadcast();
  late final StreamSubscription<List<ConnectivityResult>> _sub;
  Timer? _settleTimer;
  bool _primed = false;

  // Optimistic until primed: a false "offline" would pause every machine.
  NetworkState _current = const NetworkState(online: true, signature: '');

  @override
  Stream<NetworkState> get changes => _changes.stream;

  @override
  NetworkState get current => _current;

  static NetworkState _stateOf(List<ConnectivityResult> results) {
    final active = {
      for (final r in results)
        if (r != ConnectivityResult.none) r.name,
    }.toList()
      ..sort();
    return NetworkState(online: active.isNotEmpty, signature: active.join('+'));
  }

  Future<void> _prime() async {
    final List<ConnectivityResult> results;
    try {
      results = await _connectivity.checkConnectivity();
    } on Object {
      return; // stay optimistic; change events still arrive
    }
    if (_primed || _changes.isClosed) return;
    _primed = true;
    final state = _stateOf(results);
    // Learning the interface set at startup is not a network change.
    if (state.online) {
      _current = state;
    } else {
      _adopt(state);
    }
  }

  void _onResults(List<ConnectivityResult> results) {
    _primed = true;
    _settleTimer?.cancel();
    _settleTimer = Timer(settle, () => _adopt(_stateOf(results)));
  }

  void _adopt(NetworkState state) {
    if (state == _current || _changes.isClosed) return;
    _current = state;
    _changes.add(state);
  }

  Future<void> dispose() async {
    _settleTimer?.cancel();
    await _sub.cancel();
    await _changes.close();
  }
}
