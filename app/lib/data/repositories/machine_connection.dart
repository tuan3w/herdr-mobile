import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/herdr_models.dart';
import '../models/machine_profile.dart';
import '../services/herdr_api.dart';
import '../services/herdr_transport.dart';
import '../services/snapshot_cache.dart';

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

  /// The device has no network. Not retrying until it returns.
  offline,
}

Duration defaultBackoff(int attempt) =>
    Duration(seconds: const [1, 2, 4, 8, 15, 30][attempt.clamp(0, 5)]);

/// Live state of one herdr machine: keeps a snapshot fresh from the event
/// stream, reconnecting independently of every other machine.
///
/// Listeners are notified only when something observable changed: the link
/// state, the error, or a snapshot that differs from the previous one.
class MachineConnection extends ChangeNotifier {
  MachineConnection({
    required this.profile,
    required this._api,
    this._cache,
    this.backoff = defaultBackoff,
    this.pollInterval = const Duration(seconds: 20),
    this.structuralDelay = const Duration(milliseconds: 150),
    this.churnInterval = const Duration(milliseconds: 1500),
    this.cacheWriteInterval = const Duration(seconds: 5),
  });

  final MachineProfile profile;
  final HerdrApi _api;
  final SnapshotCache? _cache;
  final Duration Function(int attempt) backoff;

  /// Safety net in case an event is ever missed.
  final Duration pollInterval;

  /// Delay before refreshing after a structural or status event.
  final Duration structuralDelay;

  /// Minimum spacing of refreshes caused only by `pane_updated` (title and
  /// spinner churn from busy agents, which never stops).
  final Duration churnInterval;

  /// Minimum spacing of snapshot cache writes.
  final Duration cacheWriteInterval;

  LinkState _state = LinkState.connecting;
  String? _error;
  Snapshot _snapshot = Snapshot.empty;
  DateTime? _lastSync;
  bool _disposed = false;
  bool _forgotten = false;
  bool _seeding = false;

  /// Identifies the connect loop that may touch state. Bumped whenever the
  /// loop is stopped or replaced, so a loop still unwinding (awaiting a
  /// cancel, a request) can never act alongside its successor.
  int _epoch = 0;
  bool _looping = false;
  Completer<void>? _wake;
  Completer<void>? _watchEnd;

  Timer? _persistTimer;
  bool _persistDirty = false;

  final _activity = StreamController<String>.broadcast();

  /// Emits a pane id whenever herdr reports activity (`pane_updated`) on it.
  /// Broadcast; lets a pane view re-read on change instead of blind polling.
  Stream<String> get paneActivity => _activity.stream;

  HerdrApi get api => _api;
  LinkState get state => _state;
  String? get error => _error;
  Snapshot get snapshot => _snapshot;
  DateTime? get lastSync => _lastSync;
  bool get isLive => _state == LinkState.online;

  void start() {
    if (_disposed) return;
    if (!profile.enabled) {
      _set(LinkState.disabled);
      return;
    }
    _seedFromCache();
    _startLoop();
  }

  /// Retry now (skip backoff, or leave `attention`).
  void retry() {
    if (_disposed) return;
    if (_looping) {
      _wakeUp();
    } else {
      start();
    }
  }

  /// Re-fetch the snapshot immediately (pull to refresh).
  Future<void> refresh() => _refresh();

  /// The device lost its network: stop retrying, keep the stale snapshot.
  /// `attention` stays, since the network is not what needs fixing.
  void goOffline() {
    if (_disposed) return;
    if (!profile.enabled) {
      _set(LinkState.disabled);
      return;
    }
    if (_state == LinkState.attention) return;
    _seedFromCache();
    _stopLoop();
    _set(LinkState.offline);
  }

  /// The socket is presumed dead (network switched, app was suspended): drop
  /// it now and reconnect immediately, without waiting out a backoff.
  void reconnect() {
    if (_disposed || _state == LinkState.attention) return;
    _stopLoop();
    _api.reset();
    start();
  }

  /// Tears the connection down without retrying (long time in background);
  /// [reconnect] or [retry] brings it back.
  void suspend() {
    if (_disposed) return;
    if (_state case LinkState.attention || LinkState.disabled || LinkState.offline) {
      return;
    }
    _stopLoop();
    _api.reset();
    _set(LinkState.reconnecting, error: _error);
  }

  /// The machine was removed: drop its cached snapshot for good.
  void forget() {
    _forgotten = true;
    _persistTimer?.cancel();
    _persistTimer = null;
    _persistDirty = false;
    final cache = _cache;
    if (cache != null) {
      unawaited(cache.delete(profile.id).catchError((Object _) {}));
    }
  }

  void _startLoop() {
    if (_looping) return;
    _looping = true;
    unawaited(_run(++_epoch));
  }

  void _stopLoop() {
    _epoch++;
    _looping = false;
    _wakeUp();
    final end = _watchEnd;
    if (end != null && !end.isCompleted) end.complete();
  }

  void _wakeUp() {
    if (_wake case final wake? when !wake.isCompleted) wake.complete();
  }

  Future<void> _run(int epoch) async {
    bool alive() => !_disposed && epoch == _epoch;
    var attempt = 0;
    try {
      while (alive()) {
        String? error;
        try {
          _set(
            attempt == 0 && _lastSync == null
                ? LinkState.connecting
                : LinkState.reconnecting,
            error: _error,
          );
          await _refresh();
          if (!alive()) return;
          _set(LinkState.online);
          attempt = 0;
          await _watch();
          if (!alive()) return;
          error = 'Connection closed';
        } on HerdrTransportException catch (e) {
          if (!alive()) return;
          if (e.fatal) {
            _set(LinkState.attention, error: e.message);
            return;
          }
          error = e.message;
        } on HerdrApiException catch (e) {
          if (!alive()) return;
          error = e.toString();
        }
        _set(LinkState.reconnecting, error: error);
        await _sleep(backoff(attempt++));
      }
    } finally {
      if (epoch == _epoch) _looping = false;
    }
  }

  Future<void> _sleep(Duration d) async {
    final wake = _wake = Completer<void>();
    final timer = Timer(d, () {
      if (!wake.isCompleted) wake.complete();
    });
    await wake.future;
    timer.cancel();
    if (identical(_wake, wake)) _wake = null;
  }

  Future<void> _refresh() async {
    final s = await _api.snapshot();
    if (_disposed) return;
    _lastSync = DateTime.now();
    if (s == _snapshot) return;
    _snapshot = s;
    _persist();
    notifyListeners();
  }

  Future<void> _watch() async {
    final end = _watchEnd = Completer<void>();
    void fail(Object e) {
      if (!end.isCompleted) end.completeError(e);
    }

    final refresher = _RefreshScheduler(
      urgentDelay: structuralDelay,
      churnDelay: churnInterval,
      refresh: _refresh,
      onError: fail,
    );
    final sub = _api.changes().listen(
          (event) => _onEvent(event, refresher),
          onError: fail,
          onDone: () {
            if (!end.isCompleted) end.complete();
          },
        );
    final poll = Timer.periodic(
        pollInterval, (_) => refresher.schedule(urgent: true));
    try {
      await end.future;
    } finally {
      poll.cancel();
      refresher.close();
      if (identical(_watchEnd, end)) _watchEnd = null;
      await sub.cancel();
    }
  }

  /// Structure, agent detection and worktree events always warrant a quick
  /// refresh. `pane_updated` fires continuously for busy agents (spinner
  /// frames, every keystroke) but carries the whole pane, so it is compared
  /// with what we already know instead of blindly refetching:
  ///
  ///  * identical once normalised (spinner/revision churn) -> nothing to do;
  ///  * status or agent changed (e.g. working -> blocked)    -> refresh now;
  ///  * anything else (title, cwd)                            -> throttled.
  void _onEvent(Map<String, dynamic> event, _RefreshScheduler refresher) {
    if (event['event'] != 'pane_updated') {
      refresher.schedule(urgent: true);
      return;
    }
    final raw = switch (event) {
      {'data': {'pane': final Map<String, dynamic> pane}} => pane,
      _ => null,
    };
    // Activity first: an open pane view needs the signal even when the rest
    // of the payload is not something we can interpret.
    if (raw?['pane_id'] case final String id when !_activity.isClosed) {
      _activity.add(id);
    }

    final updated = _parsePane(raw);
    if (updated == null) {
      refresher.schedule(urgent: false);
      return;
    }
    final known = _snapshot.panes.where((p) => p.id == updated.id).firstOrNull;
    if (known == null || known.status != updated.status || known.agent != updated.agent) {
      refresher.schedule(urgent: true);
    } else if (known != updated) {
      refresher.schedule(urgent: false);
    }
  }

  static Pane? _parsePane(Map<String, dynamic>? raw) {
    if (raw == null) return null;
    try {
      return Pane.fromJson(raw);
    } on Object {
      return null;
    }
  }

  /// Shows the last known snapshot while the first connection is still
  /// being made. Never overrides a fresh one.
  void _seedFromCache() {
    final cache = _cache;
    if (cache == null || _seeding) return;
    _seeding = true;
    unawaited(() async {
      final Snapshot? cached;
      try {
        cached = await cache.read(profile.id);
      } on Object {
        return;
      }
      if (cached == null || _disposed || _forgotten || _lastSync != null) return;
      _snapshot = cached;
      notifyListeners();
    }());
  }

  /// At most one write per [cacheWriteInterval]: the first goes out at once,
  /// later changes are coalesced into one trailing write.
  void _persist() {
    final cache = _cache;
    if (cache == null || _forgotten) return;
    if (_persistTimer != null) {
      _persistDirty = true;
      return;
    }
    _persistDirty = false;
    unawaited(cache.write(profile.id, _snapshot).catchError((Object _) {}));
    _persistTimer = Timer(cacheWriteInterval, () {
      _persistTimer = null;
      if (_persistDirty) _persist();
    });
  }

  void _set(LinkState s, {String? error}) {
    if (_disposed || (_state == s && _error == error)) return;
    _state = s;
    _error = error;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopLoop();
    _persistTimer?.cancel();
    final cache = _cache;
    if (cache != null && _persistDirty && !_forgotten) {
      unawaited(cache.write(profile.id, _snapshot).catchError((Object _) {}));
    }
    unawaited(_activity.close());
    unawaited(_api.close());
    super.dispose();
  }
}

/// Throttles snapshot refreshes (never a debounce: busy agents emit events
/// continuously, and a timer reset per event would starve the refresh).
///
/// Urgent events refresh after [urgentDelay]; non-urgent ones are spaced
/// [churnDelay] apart, but an urgent event pulls a pending churn refresh
/// forward. Events arriving during a refresh yield one trailing refresh.
class _RefreshScheduler {
  _RefreshScheduler({
    required this.urgentDelay,
    required this.churnDelay,
    required this.refresh,
    required this.onError,
  });

  final Duration urgentDelay;
  final Duration churnDelay;
  final Future<void> Function() refresh;
  final void Function(Object) onError;

  Timer? _timer;
  bool _timerUrgent = false;
  bool _inFlight = false;
  bool _pending = false;
  bool _pendingUrgent = false;
  bool _closed = false;

  void schedule({required bool urgent}) {
    if (_closed) return;
    if (_inFlight) {
      _pending = true;
      _pendingUrgent = _pendingUrgent || urgent;
      return;
    }
    if (_timer case final timer?) {
      if (!urgent || _timerUrgent) return;
      timer.cancel();
    }
    _timerUrgent = urgent;
    _timer = Timer(urgent ? urgentDelay : churnDelay, _run);
  }

  Future<void> _run() async {
    _timer = null;
    _inFlight = true;
    try {
      await refresh();
    } on Object catch (e) {
      if (!_closed) onError(e);
      return;
    } finally {
      _inFlight = false;
    }
    if (_closed || !_pending) return;
    final urgent = _pendingUrgent;
    _pending = _pendingUrgent = false;
    schedule(urgent: urgent);
  }

  void close() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
  }
}
