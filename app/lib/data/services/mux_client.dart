import 'dart:async';
import 'dart:convert';
import 'dart:io' show zlib;

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

  /// A response the remote deflated (see [muxCompressMin]): `z`, then base64
  /// of zlib data holding the JSON line. Parsed straight from the bytes.
  static Object? _inflate(String line) => json
      .fuse(utf8)
      .decode(zlib.decode(base64.decode(line.substring(1))));

  void _route(String line) {
    // The one and only decode of this response: requests receive the decoded
    // object (re-decoding a 140 KB pane read cost ~14 ms on a mid-range phone).
    final Object? decoded;
    try {
      decoded = line.startsWith('z') ? _inflate(line) : jsonDecode(line);
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
    Duration timeout,
  ) async {
    if (!_alive) throw const HerdrTransportException('herdr connection lost');
    final reply = _pending[id] = Completer<Object?>();
    try {
      _channel.send(jsonEncode({'id': id, 'method': method, 'params': params}));
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
    final Object? decoded;
    try {
      decoded = await _exchange('m${_nextId++}', method, params, requestTimeout);
    } on TimeoutException {
      throw HerdrTransportException('herdr did not answer $method in time');
    }
    return unwrapDecoded(decoded);
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
