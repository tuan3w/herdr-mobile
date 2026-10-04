import 'dart:async';
import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:math' as math;
import 'dart:typed_data';

import 'bridge_command.dart';
import 'herdr_transport.dart';

/// A line-oriented duplex channel to the remote mux script (see
/// `buildMuxCommand`). Abstract so [MuxClient] is testable without SSH.
abstract interface class MuxChannel {
  /// Lines the remote wrote to stdout. Single-subscription; ends when the
  /// channel closes.
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
        continue;
      }
      sink.add(text);
    }
    if (start == end) start = end = 0;
  }

  return StreamTransformer<List<int>, String>.fromHandlers(handleData: feed)
      .bind(bytes);
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
    required this.heartbeatInterval,
    required this.heartbeatTimeout,
  });

  /// Waits for the remote ready line, then starts the heartbeat.
  /// Throws [MuxUnavailable] if the channel closes first or never becomes
  /// ready within [startupTimeout].
  static Future<MuxClient> connect(
    MuxChannel channel, {
    Duration startupTimeout = const Duration(seconds: 5),
    Duration requestTimeout = const Duration(seconds: 20),
    Duration heartbeatInterval = const Duration(seconds: 8),
    Duration heartbeatTimeout = const Duration(seconds: 5),
  }) async {
    final client = MuxClient._(
      channel,
      requestTimeout: requestTimeout,
      heartbeatInterval: heartbeatInterval,
      heartbeatTimeout: heartbeatTimeout,
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
  final Duration heartbeatInterval;
  final Duration heartbeatTimeout;

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
    if (id is String) _pending.remove(id)?.complete(decoded);
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
    // One read per distinct pane read at a time may name the answer it holds;
    // a second one concurrently gets the whole text.
    final key = method == 'pane.read' ? jsonEncode(params) : null;
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
    if (key != null) _resolveRead(key, basis, decoded);
    return unwrapDecoded(decoded);
  }

  /// Completes a `pane.read` answer: a delta (see [muxDeltaMin]) is turned
  /// back into the full `text` using [basis], the answer this request named,
  /// and the rows of the answer are held for the next request.
  void _resolveRead(String key, _HeldRead? basis, Object? decoded) {
    if (decoded is! Map<String, dynamic>) return;
    final result = decoded['result'];
    final read = result is Map<String, dynamic> ? result['read'] : null;
    if (read is! Map<String, dynamic>) return;
    final seq = decoded['seq'];
    final delta = read['delta'];
    final List<String> rows;
    final int chars;
    if (delta is Map<String, dynamic>) {
      final s = delta['s'], k = delta['k'], x = delta['x'], lit = delta['t'];
      if (basis == null ||
          delta['base'] != basis.seq ||
          seq is! int ||
          s is! int ||
          k is! int ||
          x is! int ||
          lit is! List ||
          s < 0 ||
          k < 0 ||
          x < 0 ||
          s + k > basis.rows.length ||
          x > basis.rows.length) {
        _drop(key);
        throw const HerdrTransportException('herdr sent a pane read we cannot rebuild');
      }
      final old = basis.rows;
      rows = [
        ...old.getRange(s, s + k),
        ...lit.cast<String>(),
        ...old.getRange(old.length - x, old.length),
      ];
      read.remove('delta');
      final text = rows.join('\n');
      chars = text.length;
      read['text'] = text;
    } else {
      final text = read['text'];
      if (seq is! int || text is! String) {
        _drop(key);
        return;
      }
      chars = text.length;
      rows = text.split('\n');
    }
    _drop(key);
    _held[key] = _HeldRead(seq, rows, chars);
    _heldChars += chars;
    while (_held.length > 1 &&
        (_held.length > muxDeltaKeep || _heldChars > muxDeltaChars)) {
      _drop(_held.keys.first);
    }
  }

  void _drop(String key) {
    final gone = _held.remove(key);
    if (gone != null) _heldChars -= gone.chars;
  }

  Future<void> _beat() async {
    if (_beating || !_alive) return;
    _beating = true;
    try {
      await _exchange('hb${_nextId++}', 'ping', const {}, heartbeatTimeout);
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
