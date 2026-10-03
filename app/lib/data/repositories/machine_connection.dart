import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/herdr_models.dart';
import '../models/machine_profile.dart';
import '../services/herdr_api.dart';
import '../services/herdr_transport.dart';

enum LinkState {
  /// First connection attempt in flight.
  connecting,

  /// Snapshot fresh, event stream live.
  online,

  /// Lost; retrying with backoff. Last snapshot is stale.
  reconnecting,

  /// Needs user action (bad credentials, changed host key, no bridge).
  attention,

  disabled,
}

Duration defaultBackoff(int attempt) =>
    Duration(seconds: const [1, 2, 4, 8, 15, 30][attempt.clamp(0, 5)]);

/// Live state of one herdr machine: keeps a snapshot fresh from the event
/// stream, reconnecting independently of every other machine.
class MachineConnection extends ChangeNotifier {
  MachineConnection({
    required this.profile,
    required this._api,
    this.backoff = defaultBackoff,
    this.pollInterval = const Duration(seconds: 20),
    this.refreshDebounce = const Duration(milliseconds: 400),
  });

  final MachineProfile profile;
  final HerdrApi _api;
  final Duration Function(int attempt) backoff;
  final Duration pollInterval;
  final Duration refreshDebounce;

  LinkState _state = LinkState.connecting;
  String? _error;
  Snapshot _snapshot = Snapshot.empty;
  DateTime? _lastSync;
  bool _disposed = false;
  bool _running = false;
  Completer<void>? _wake;
  Completer<void>? _watchEnd;
  Timer? _debounce;
  bool _refreshing = false;
  bool _dirty = false;

  HerdrApi get api => _api;
  LinkState get state => _state;
  String? get error => _error;
  Snapshot get snapshot => _snapshot;
  DateTime? get lastSync => _lastSync;
  bool get isLive => _state == LinkState.online;

  void start() {
    if (_running || _disposed || !profile.enabled) {
      if (!profile.enabled) _set(LinkState.disabled);
      return;
    }
    _running = true;
    unawaited(_run().whenComplete(() => _running = false));
  }

  /// Retry now (skip backoff, or leave `attention`).
  void retry() {
    if (_disposed) return;
    if (!_running) {
      start();
    } else {
      _wake?.complete();
    }
  }

  /// Re-fetch the snapshot immediately (pull to refresh).
  Future<void> refresh() => _refresh();

  Future<void> _run() async {
    var attempt = 0;
    while (!_disposed) {
      try {
        _set(_snapshot == Snapshot.empty && _lastSync == null
            ? LinkState.connecting
            : LinkState.reconnecting);
        await _refresh();
        _error = null;
        _set(LinkState.online);
        attempt = 0;
        await _watch();
        if (_disposed) return;
        _error = 'Connection closed';
      } on HerdrTransportException catch (e) {
        if (_disposed) return;
        _error = e.message;
        if (e.fatal) {
          _set(LinkState.attention);
          return;
        }
      } on HerdrApiException catch (e) {
        if (_disposed) return;
        _error = e.toString();
      }
      _set(LinkState.reconnecting);
      await _sleep(backoff(attempt++));
    }
  }

  Future<void> _sleep(Duration d) async {
    final wake = _wake = Completer<void>();
    await Future.any([Future<void>.delayed(d), wake.future]);
    _wake = null;
  }

  Future<void> _refresh() async {
    final s = await _api.snapshot();
    if (_disposed) return;
    _snapshot = s;
    _lastSync = DateTime.now();
    notifyListeners();
  }

  Future<void> _watch() async {
    final end = _watchEnd = Completer<void>();
    void fail(Object e) {
      if (!end.isCompleted) end.completeError(e);
    }

    final sub = _api.changes().listen(
          (_) => _scheduleRefresh(fail),
          onError: fail,
          onDone: () {
            if (!end.isCompleted) end.complete();
          },
        );
    final poll = Timer.periodic(pollInterval, (_) => _scheduleRefresh(fail));
    try {
      await end.future;
    } finally {
      poll.cancel();
      _debounce?.cancel();
      _watchEnd = null;
      await sub.cancel();
    }
  }

  /// Throttle, not debounce: busy agents emit events continuously, and a
  /// timer reset per event would starve the refresh forever.
  void _scheduleRefresh(void Function(Object) fail) {
    if (_refreshing) {
      _dirty = true;
      return;
    }
    if (_debounce?.isActive ?? false) return;
    _debounce = Timer(refreshDebounce, () => _runRefresh(fail));
  }

  Future<void> _runRefresh(void Function(Object) fail) async {
    _refreshing = true;
    try {
      await _refresh();
    } on Object catch (e) {
      fail(e);
      return;
    } finally {
      _refreshing = false;
    }
    if (_dirty) {
      _dirty = false;
      _scheduleRefresh(fail);
    }
  }

  void _set(LinkState s) {
    if (_state == s && !_disposed) {
      notifyListeners();
      return;
    }
    _state = s;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _wake?.complete();
    final end = _watchEnd;
    if (end != null && !end.isCompleted) end.complete();
    unawaited(_api.close());
    super.dispose();
  }
}
