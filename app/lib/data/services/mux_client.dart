import 'dart:async';
import 'dart:convert';
import 'dart:io' show RawZLibFilter, zlib;
import 'dart:math' as math;
import 'dart:typed_data';

import 'bridge_command.dart';
import 'herdr_transport.dart';

/// A duplex channel to the remote mux script (see `buildMuxCommand`).
/// Abstract so [MuxClient] is testable without SSH.
abstract interface class MuxChannel {
  /// The messages the remote wrote to stdout, one JSON text each (the SSH
  /// channel gets them from `muxMessages`, which also inflates deflated
  /// frames). Single-subscription; ends when the channel closes.
  Stream<String> get lines;

  void send(String line);

  Future<void> close();

  /// Exit status of the remote process, or null if it was killed or the
  /// link dropped. Completes once the channel is closed.
  Future<int?> get exitCode;
}

/// The remote mux could not be started (no python3, no socket at the guessed
/// path, never became ready).
class MuxUnavailable implements Exception {
  const MuxUnavailable(this.message, {this.linkLost = false});

  final String message;

  /// The channel died without a remote exit status, i.e. the SSH link dropped
  /// while starting. Retrying later may work; otherwise the remote simply
  /// cannot run the mux.
  final bool linkLost;

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

/// Largest deflated frame [muxMessages] waits for; a bigger announcement is
/// not one of ours.
const _maxFrame = 1 << 26;

/// The messages the remote mux script wrote, as JSON text: plain lines as they
/// are, and each deflated frame (`Z<n>\n` and `n` bytes of zlib data, see
/// [muxCompressMin]) inflated. A frame that does not inflate is dropped, like
/// any other line that is not JSON. Splits on the bytes, so the compressed
/// data is never decoded as text.
///
/// A synchronous transformer, not an `async*` generator: the same parser
/// written with `await for` pauses the SSH channel's stream around every
/// chunk, and a request/response loop over loopback then took 40 ms per round
/// trip instead of 2 (a delayed-ACK stall; the likely cause is the channel's
/// window update held back by Nagle's algorithm, not confirmed). Never pause
/// the channel's stream per message.
Stream<String> muxMessages(Stream<List<int>> bytes) {
  var buf = Uint8List(64 * 1024);
  var start = 0, end = 0;
  // The `E` frames: one inflater for the whole stream, and the rest of a line
  // it has not finished yet.
  ByteConversionSink? inflater;
  EventSink<String>? inflated;
  var partial = const <int>[];
  var broken = false;

  void onInflated(List<int> data) {
    final all = partial.isEmpty ? data : [...partial, ...data];
    var from = 0;
    for (var i = 0; i < all.length; i++) {
      if (all[i] != 0x0A) continue;
      if (i > from) {
        inflated!.add(utf8.decode(all.sublist(from, i), allowMalformed: true));
      }
      from = i + 1;
    }
    partial = from == all.length ? const [] : all.sublist(from);
  }

  void feed(List<int> chunk, EventSink<String> sink) {
    if (broken) return;
    if (end + chunk.length > buf.length) {
      final live = end - start;
      if (live + chunk.length > buf.length) {
        final bigger = Uint8List(math.max(live + chunk.length, buf.length * 2));
        bigger.setRange(0, live, buf, start);
        buf = bigger;
      } else {
        buf.setRange(0, live, buf, start);
      }
      start = 0;
      end = live;
    }
    buf.setRange(end, end + chunk.length, chunk);
    end += chunk.length;

    while (start < end) {
      var nl = start;
      while (nl < end && buf[nl] != 0x0A) {
        nl++;
      }
      if (nl == end) break; // no complete line yet
      final kind = buf[start];
      if (kind != 0x5A /* Z */ && kind != 0x45 /* E */) {
        final line = Uint8List.sublistView(buf, start, nl);
        start = nl + 1;
        sink.add(utf8.decode(line, allowMalformed: true));
        continue;
      }
      final n = int.tryParse(ascii.decode(buf.sublist(start + 1, nl), allowInvalid: true));
      if (n == null || n < 0 || n > _maxFrame) {
        start = nl + 1; // not a frame header: skip the line
        continue;
      }
      if (end - (nl + 1) < n) break; // the rest of the frame is on its way
      final frame = Uint8List.sublistView(buf, nl + 1, nl + 1 + n);
      start = nl + 1 + n;
      if (kind == 0x45) {
        // Another piece of the one zlib stream; what it inflates to is lines.
        inflated = sink;
        try {
          (inflater ??= zlib.decoder.startChunkedConversion(_Collect(onInflated))).add(frame);
        } on Object {
          // The stream's state is gone: nothing after this can be read.
          broken = true;
          sink.addError(const FormatException('event stream is corrupt'));
          return;
        }
        continue;
      }
      final String text;
      try {
        text = utf8.decode(zlib.decode(frame));
      } on Object {
        // Only a bug in the script can do this (the link is authenticated):
        // fail now, so the connection is rebuilt, rather than let the one
        // request this answers wait out its timeout.
        broken = true;
        sink.addError(const FormatException('mux frame is corrupt'));
        return;
      }
      sink.add(text);
    }
    if (start == end) start = end = 0;
  }

  return StreamTransformer<List<int>, String>.fromHandlers(
    handleData: feed,
    handleDone: (sink) {
      inflater?.close();
      sink.close();
    },
  ).bind(bytes);
}

/// Frames request lines for the mux script: one zlib stream for the life of
/// the channel, flushed after every line, each piece sent as `Q<n>\n` and `n`
/// bytes (see [muxCompressMin] for the other direction). The script inflates
/// it as it arrives, so a request is never held back.
class MuxRequestEncoder {
  final _filter = RawZLibFilter.deflateFilter(level: 6);

  /// The bytes to write for [line].
  List<int> frame(String line) {
    final data = utf8.encode('$line\n');
    _filter.process(data, 0, data.length);
    final out = BytesBuilder(copy: false);
    while (true) {
      final piece = _filter.processed(flush: true);
      if (piece == null || piece.isEmpty) break;
      out.add(piece);
    }
    final z = out.takeBytes();
    return [...ascii.encode('Q${z.length}\n'), ...z];
  }
}

/// Receives what a chunked zlib decoder produces.
class _Collect implements Sink<List<int>> {
  const _Collect(this._onData);

  final void Function(List<int>) _onData;

  @override
  void add(List<int> data) => _onData(data);

  @override
  void close() {}
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
  })  : _heartbeatInterval = heartbeatInterval, // ignore: prefer_initializing_formals
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

  /// Waits for the remote ready line, then starts the heartbeat.
  /// Throws [MuxUnavailable] if the channel closes first or never becomes
  /// ready within [startupTimeout].
  static Future<MuxClient> connect(
    MuxChannel channel, {
    Duration startupTimeout = const Duration(seconds: 5),
    Duration requestTimeout = const Duration(seconds: 20),
    Duration heartbeatInterval = const Duration(seconds: 8),
    Duration heartbeatTimeout = const Duration(seconds: 5),
    Duration Function()? clock,
  }) async {
    final client = MuxClient._(
      channel,
      requestTimeout: requestTimeout,
      heartbeatInterval: heartbeatInterval,
      heartbeatTimeout: heartbeatTimeout,
      clock: clock,
    );
    try {
      await client._ready(startupTimeout);
    } on Object {
      client._die(MuxDeath.closed, 'mux failed to start');
      rethrow;
    }
    if (client._alive) {
      client._heartbeat = Timer.periodic(heartbeatInterval, (_) => client._beat());
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
    if (!_alive) return;
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

  // The last answer to each distinct pane.read, for delta answers.
  final _held = <String, _HeldRead>{};
  var _heldChars = 0;
  final _reading = <String>{};

  bool get isAlive => _alive;

  /// Completes when this client dies, with the cause.
  Future<MuxDeath> get onDead => _dead.future;

  Future<void> _ready(Duration timeout) {
    final ready = Completer<void>();
    _sub = _channel.lines.listen(
      (line) {
        if (ready.isCompleted) {
          _route(line);
        } else if (line.trim() == muxReadyLine) {
          ready.complete();
        }
      },
      onError: (Object e) {
        if (!ready.isCompleted) {
          ready.completeError(MuxUnavailable('mux channel failed: $e', linkLost: true));
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
        ready.completeError(MuxUnavailable(
          code == null
              ? 'mux channel closed before it was ready'
              : 'mux exited with status $code before it was ready',
          linkLost: code == null,
        ));
      },
    );
    return ready.future.timeout(
      timeout,
      onTimeout: () => throw const MuxUnavailable('mux did not become ready in time'),
    );
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
      _channel.send(jsonEncode({
        'id': id,
        'method': method,
        'params': params,
        'mux_have': ?have,
      }));
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
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    // One read per distinct pane read or snapshot at a time may name the
    // answer it holds; a second one concurrently gets the whole answer.
    final key = method == 'pane.read' || method == 'session.snapshot'
        ? '$method ${jsonEncode(params)}'
        : null;
    final owns = key != null && _reading.add(key);
    final basis = owns ? _held[key] : null;
    final Object? decoded;
    try {
      decoded = await _exchange(
        'm${_nextId++}',
        method,
        params,
        requestTimeout,
        have: basis?.seq,
      );
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
    while (_held.length > 1 &&
        (_held.length > muxDeltaKeep || _heldChars > muxDeltaChars)) {
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
    return {
      'version': rows.first.substring(1),
      'workspaces': lists['w'],
      'tabs': lists['t'],
      'panes': lists['p'],
    };
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

  void _die(MuxDeath cause, String reason) {
    if (!_alive) return;
    _alive = false;
    _heartbeat?.cancel();
    final failed = _pending.values.toList();
    _pending.clear();
    for (final reply in failed) {
      reply.completeError(HerdrTransportException(reason));
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
