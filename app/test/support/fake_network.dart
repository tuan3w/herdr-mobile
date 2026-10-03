import 'dart:async';

import 'package:herdr_mobile/data/services/network_monitor.dart';

/// Hand-driven [NetworkMonitor]; emits synchronously so tests under
/// `fakeAsync` need no extra pumping.
class FakeNetwork implements NetworkMonitor {
  FakeNetwork([this._current = const NetworkState(online: true, signature: 'wifi')]);

  final _changes = StreamController<NetworkState>.broadcast(sync: true);
  NetworkState _current;

  @override
  Stream<NetworkState> get changes => _changes.stream;

  @override
  NetworkState get current => _current;

  void set(NetworkState state) {
    if (state == _current) return;
    _current = state;
    _changes.add(state);
  }

  void goOffline() => set(const NetworkState(online: false, signature: ''));

  void goOnline([String signature = 'wifi']) =>
      set(NetworkState(online: true, signature: signature));
}
