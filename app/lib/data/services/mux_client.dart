import 'dart:async';
import 'dart:convert';

import 'bridge_command.dart';
import 'herdr_transport.dart';

/// A duplex channel to the host's herdr mux (a `herdr.mux` stream of the agent
/// helper, see `HostMuxChannel`). Abstract so [MuxClient] is testable without
/// SSH.
abstract interface class MuxChannel {
  /// The messages the host wrote, one JSON text each: first the ready message
  /// ([muxReadyLine]), then one response per request. Single-subscription;
  /// ends when the channel closes; errors with [MuxUnavailable] when the host
  /// says it cannot serve the mux right now.
  Stream<String> get lines;

  void send(String line);

  Future<void> close();

  /// Exit status of the remote process, or null if it was killed or the
  /// link dropped. Completes once the channel is closed.
  Future<int?> get exitCode;
}

/// The remote mux could not be started (no socket at the guessed path, the
/// agent helper is not installed, never became ready).
class MuxUnavailable implements Exception {
  const MuxUnavailable(this.message, {this.linkLost = false, this.helperMissing = false});

  final String message;

  /// The channel died without a remote exit status, i.e. the SSH link dropped
  /// while starting. Retrying later may work; otherwise the remote simply
  /// cannot run the mux.
  final bool linkLost;

  /// The agent helper is not installed on the host (its `serve` command exited
  /// 65): installing it and starting again can work.
  final bool helperMissing;

  @override
  String toString() => message;
}

enum MuxDeath {
  /// The channel closed or errored, or [MuxClient.close] was called.
  closed,

  /// The remote stopped answering heartbeats: the link is presumed
  /// half-open (e.g. after a network switch) and the whole connection
  /// should be dropped.
  unresponsive,
}

/// Multiplexes pipelined requests over one [MuxChannel], matching responses
/// by id. Once dead (channel closed or heartbeat missed) it never revives;
/// create a new client.
class MuxClient {
  MuxClient._(
    this._channel, {
    required this.requestTimeout,
    required Duration heartbeatInterval,
    required Duration heartbeatTimeout,
    Duration Function()? clock,
  }) : _heartbeatInterval = heartbeatInterval, // ignore: prefer_initializing_formals
       _heartbeatTimeout = heartbeatTimeout, // ignore: prefer_initializing_formals
       _now = clock ?? _stopwatchClock();

  static Duration Function() _stopwatchClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  final Duration Function() _now;

  /// When the last answer to a request that is not a heartbeat came in. An
  /// answer proves the mux and the link are alive as well as a heartbeat's
  /// does, so a heartbeat is only sent when none came for a whole interval:
  /// in the background the safety-net poll is then the one thing that wakes
  /// the radio, instead of the poll and the heartbeat each doing it.
  Duration? _lastAnswer;

  /// Starts the client on [channel]. With [waitForReady] (the default) it
  /// returns once the remote's ready message came, and throws [MuxUnavailable]
  /// if the channel closes first or never becomes ready within
  /// [startupTimeout].
  ///
  /// Without it the client is returned at once and requests may be sent right
  /// away: the remote answers them after its ready message (which is consumed
  /// when it arrives), so the first request does not wait a round trip for
  /// readiness. A startup failure then fails every request already sent with
  /// the [MuxUnavailable] ([MuxUnavailable.linkLost] and
  /// [MuxUnavailable.helperMissing] say which kind) and kills the client. The
  /// heartbeat starts after ready either way.
  static Future<MuxClient> connect(
    MuxChannel channel, {
    Duration startupTimeout = const Duration(seconds: 5),
    Duration requestTimeout = const Duration(seconds: 20),
    Duration heartbeatInterval = const Duration(seconds: 8),
    Duration heartbeatTimeout = const Duration(seconds: 5),
    Duration Function()? clock,
    bool waitForReady = true,
  }) async {
    final client = MuxClient._(
      channel,
      requestTimeout: requestTimeout,
      heartbeatInterval: heartbeatInterval,
      heartbeatTimeout: heartbeatTimeout,
      clock: clock,
    );
    final ready = client._listen(startupTimeout).then<void>((_) {
      client._started = true;
      if (client._alive) {
        client._heartbeat = Timer.periodic(client._heartbeatInterval, (_) => client._beat());
      }
    });
    if (!waitForReady) {
      unawaited(ready.catchError((Object e) => client._die(MuxDeath.closed, 'mux failed to start', failure: e)));
      return client;
    }
    try {
      await ready;
    } on Object catch (e) {
      client._die(MuxDeath.closed, 'mux failed to start', failure: e);
      rethrow;
    }
    return client;
  }

  final MuxChannel _channel;
  final Duration requestTimeout;
  Duration _heartbeatInterval;
  Duration _heartbeatTimeout;

  /// How often the remote is pinged, and how long it may take to answer.
  Duration get heartbeatInterval => _heartbeatInterval;
  Duration get heartbeatTimeout => _heartbeatTimeout;

  /// Changes the heartbeat now: the timer is replaced (never doubled), so the
  /// next beat is a full [interval] away, or immediate with [beatNow] (the
  /// app came back to the foreground and wants to know the link is alive).
  /// A beat already waiting for its answer keeps the timeout it started with
  /// and is not repeated; [beatNow] then adds nothing.
  void setHeartbeat(Duration interval, Duration timeout, {bool beatNow = false}) {
    _heartbeatInterval = interval;
    _heartbeatTimeout = timeout;
    // Before ready the new values wait for the heartbeat to start.
    if (!_alive || !_started) return;
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(interval, (_) => _beat());
    if (beatNow) unawaited(_beat());
  }

  final _pending = <String, Completer<Object?>>{};
  final _dead = Completer<MuxDeath>();
  StreamSubscription<String>? _sub;
  Timer? _heartbeat;
  var _nextId = 0;
  var _alive = true;
  var _beating = false;
  var _started = false;
  Completer<void>? _readyDone;
  Timer? _startupTimer;

  // The last answer to each distinct pane.read, for delta answers.
  final _held = <String, _HeldRead>{};
  var _heldChars = 0;
  final _reading = <String>{};

  bool get isAlive => _alive;

  /// Completes when this client dies, with the cause.
  Future<MuxDeath> get onDead => _dead.future;

  /// Listens to the channel until the ready message, then routes responses.
  /// The future completes when ready came and fails with [MuxUnavailable].
  Future<void> _listen(Duration timeout) {
    final ready = _readyDone = Completer<void>();
    void fail(MuxUnavailable e) {
      _startupTimer?.cancel();
      if (ready.isCompleted) return;
      ready.completeError(e);
      // At once, not when the caller's handler runs: the channel's own end
      // follows this error in the same turn and must not be taken for a lost
      // connection, and requests already sent are failed with [e].
      _die(MuxDeath.closed, 'mux failed to start', failure: e);
    }

    _startupTimer = Timer(timeout, () => fail(const MuxUnavailable('mux did not become ready in time')));
    _sub = _channel.lines.listen(
      (line) {
        if (ready.isCompleted) {
          _route(line);
        } else if (line.trim() == muxReadyLine) {
          _startupTimer?.cancel();
          ready.complete();
        }
      },
      onError: (Object e) {
        if (!ready.isCompleted) {
          // A channel that knows why it cannot serve (the host has no herdr
          // socket right now, the helper is not installed) says so itself; any
          // other failure is the link.
          fail(e is MuxUnavailable ? e : MuxUnavailable('mux channel failed: $e', linkLost: true));
        } else {
          _die(MuxDeath.closed, 'herdr connection lost: $e');
        }
      },
      onDone: () async {
        if (ready.isCompleted) {
          _die(MuxDeath.closed, 'herdr connection closed');
          return;
        }
        final code = await _channel.exitCode
            .timeout(const Duration(seconds: 1), onTimeout: () => null)
            .catchError((Object _) => null);
        if (ready.isCompleted) return;
        fail(
          MuxUnavailable(
            code == null
                ? 'mux channel closed before it was ready'
                : 'mux exited with status $code before it was ready',
            linkLost: code == null,
          ),
        );
      },
    );
    return ready.future;
  }

  void _route(String line) {
    // The one and only decode of this response: requests receive the decoded
    // object (re-decoding a 140 KB pane read cost ~14 ms on a mid-range phone).
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return;
    }
    final id = decoded is Map<String, dynamic> ? decoded['id'] : null;
    if (id is String) {
      if (!id.startsWith('hb')) _lastAnswer = _now();
      _pending.remove(id)?.complete(decoded);
    }
  }

  /// Sends one request and returns the decoded response. Throws
  /// [TimeoutException] on no answer within [timeout], or
  /// [HerdrTransportException] if the client is or becomes dead.
  Future<Object?> _exchange(
    String id,
    String method,
    Map<String, dynamic> params,
    Duration timeout, {
    int? have,
  }) async {
    if (!_alive) throw const HerdrTransportException('herdr connection lost');
    final reply = _pending[id] = Completer<Object?>();
    try {
      _channel.send(jsonEncode({'id': id, 'method': method, 'params': params, 'mux_have': ?have}));
    } on Object catch (e) {
      _pending.remove(id);
      _die(MuxDeath.closed, 'herdr connection lost: $e');
      throw HerdrTransportException('herdr connection lost: $e');
    }
    try {
      return await reply.future.timeout(timeout);
    } finally {
      _pending.remove(id);
    }
  }

  /// Returns the `result` of [method]. Throws [HerdrApiException] on an API
  /// error and a non-fatal [HerdrTransportException] if the connection is
  /// lost or herdr is too slow to answer.
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) async {
    // One read per distinct pane read or snapshot at a time may name the
    // answer it holds; a second one concurrently gets the whole answer.
    final key = method == 'pane.read' || method == 'session.snapshot' ? '$method ${jsonEncode(params)}' : null;
    final owns = key != null && _reading.add(key);
    final basis = owns ? _held[key] : null;
    final Object? decoded;
    try {
      decoded = await _exchange('m${_nextId++}', method, params, requestTimeout, have: basis?.seq);
    } on TimeoutException {
      throw HerdrTransportException('herdr did not answer $method in time');
    } finally {
      if (owns) _reading.remove(key);
    }
    if (key != null) _resolveHeld(method, key, basis, decoded);
    return unwrapDecoded(decoded);
  }

  /// The rows [ops] describe over [old]: `[start, count]` keeps a run of old
  /// rows, a list of strings is new rows. Null if [ops] is not that or points
  /// outside [old].
  static List<String>? _applyOps(List<String> old, Object? ops) {
    if (ops is! List) return null;
    final rows = <String>[];
    for (final op in ops) {
      if (op is! List || op.isEmpty) return null;
      if (op[0] is int) {
        if (op.length != 2 || op[1] is! int) return null;
        final s = op[0] as int, n = op[1] as int;
        if (s < 0 || n < 0 || s + n > old.length) return null;
        rows.addAll(old.getRange(s, s + n));
      } else {
        for (final row in op) {
          if (row is! String) return null;
          rows.add(row);
        }
      }
    }
    return rows;
  }

  /// Completes a `pane.read` or `session.snapshot` answer. A delta (see
  /// [muxDeltaMin]) is turned back into the whole answer using [basis], the
  /// answer this request named; a snapshot always travels as rows (one per
  /// workspace, tab and pane, see [_snapshotFromRows]). The rows of the answer
  /// are held for the next request.
  void _resolveHeld(String method, String key, _HeldRead? basis, Object? decoded) {
    if (decoded is! Map<String, dynamic>) return;
    final result = decoded['result'];
    final snapshot = method == 'session.snapshot';
    final box = result is Map<String, dynamic> ? result[snapshot ? 'snapshot' : 'read'] : null;
    if (box is! Map<String, dynamic>) return;
    final seq = decoded['seq'];
    final delta = box['delta'];
    final List<String> rows;
    if (delta is Map<String, dynamic>) {
      final rebuilt = basis != null && delta['base'] == basis.seq && seq is int
          ? _applyOps(basis.rows, delta['o'])
          : null;
      if (rebuilt == null) {
        _drop(key);
        throw HerdrTransportException('herdr sent a $method answer we cannot rebuild');
      }
      rows = rebuilt;
      if (!snapshot) {
        box.remove('delta');
        box['text'] = rows.join('\n');
      }
    } else if (snapshot) {
      final sent = box['rows'];
      if (seq is! int || sent is! List || sent.any((r) => r is! String)) {
        _drop(key);
        return;
      }
      rows = sent.cast<String>();
    } else {
      final text = box['text'];
      if (seq is! int || text is! String) {
        _drop(key);
        return;
      }
      rows = text.split('\n');
    }
    if (snapshot) {
      final whole = _snapshotFromRows(rows);
      if (whole == null) {
        _drop(key);
        throw const HerdrTransportException('herdr sent a snapshot we cannot read');
      }
      (result! as Map<String, dynamic>)['snapshot'] = whole;
    }
    _drop(key);
    final chars = rows.fold<int>(0, (n, r) => n + r.length + 1);
    _held[key] = _HeldRead(seq as int, rows, chars);
    _heldChars += chars;
    while (_held.length > 1 && (_held.length > muxDeltaKeep || _heldChars > muxDeltaChars)) {
      _drop(_held.keys.first);
    }
  }

  /// The snapshot the rows of the mux script describe: `v<version>`, then a
  /// letter and the JSON of each workspace (`w`), tab (`t`) and pane (`p`).
  static Map<String, dynamic>? _snapshotFromRows(List<String> rows) {
    if (rows.isEmpty || !rows.first.startsWith('v')) return null;
    final lists = {'w': <Object?>[], 't': <Object?>[], 'p': <Object?>[]};
    try {
      for (final row in rows.skip(1)) {
        final list = row.isEmpty ? null : lists[row[0]];
        if (list == null) return null;
        list.add(jsonDecode(row.substring(1)));
      }
    } on FormatException {
      return null;
    }
    return {'version': rows.first.substring(1), 'workspaces': lists['w'], 'tabs': lists['t'], 'panes': lists['p']};
  }

  void _drop(String key) {
    final gone = _held.remove(key);
    if (gone != null) _heldChars -= gone.chars;
  }

  Future<void> _beat() async {
    if (_beating || !_alive) return;
    final last = _lastAnswer;
    if (last != null && _now() - last < _heartbeatInterval) return;
    _beating = true;
    try {
      await _exchange('hb${_nextId++}', 'ping', const {}, _heartbeatTimeout);
    } on TimeoutException {
      _die(MuxDeath.unresponsive, 'herdr connection stopped responding');
    } on HerdrTransportException {
      // already dead
    } finally {
      _beating = false;
    }
  }

  void _die(MuxDeath cause, String reason, {Object? failure}) {
    if (!_alive) return;
    _alive = false;
    _heartbeat?.cancel();
    _startupTimer?.cancel();
    final failed = _pending.values.toList();
    _pending.clear();
    for (final reply in failed) {
      reply.completeError(failure ?? HerdrTransportException(reason));
    }
    // A client closed while still starting: whoever waits for ready is told.
    final startup = _readyDone;
    if (startup != null && !startup.isCompleted) {
      startup.completeError(failure ?? const MuxUnavailable('mux closed before it was ready'));
    }
    _dead.complete(cause);
    _sub?.cancel();
    _channel.close().catchError((Object _) {});
  }

  /// Kills the client now; in-flight requests fail with a retryable error.
  void close() => _die(MuxDeath.closed, 'herdr connection closed');
}

/// The rows of a `pane.read` answer (of [chars] characters of text) and the
/// `seq` the mux gave it.
class _HeldRead {
  const _HeldRead(this.seq, this.rows, this.chars);

  final int seq;
  final List<String> rows;
  final int chars;
}
