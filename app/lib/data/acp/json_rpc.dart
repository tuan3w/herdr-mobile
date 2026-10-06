import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// What a [JsonRpcConnection] talks over: one JSON text per line each way.
///
/// Kept this small on purpose: the SSH channel, a `Process`, a unix socket and
/// the in-memory pair the tests use all fit. The bytes-to-lines step lives in
/// [splitLines], so a transport only has to hand its byte stream to it.
abstract class AcpTransport {
  /// What the peer wrote, one JSON text per element, without the newline.
  /// Single subscription; it ends when the peer is gone.
  Stream<String> get lines;

  /// Writes one JSON text and its newline. Throws if the transport is closed.
  void send(String line);

  /// Ends the conversation (closes the peer's stdin). Idempotent.
  Future<void> close();
}

/// Longest line [splitLines] keeps; a longer one is dropped with an error
/// event (an ACP line is one JSON text, and a base64 image is the largest
/// thing in it).
const maxLineBytes = 64 * 1024 * 1024;

/// Splits a byte stream into lines (`\n`, a trailing `\r` is dropped, blank
/// lines are skipped; a last line without a newline is delivered at the end).
/// UTF-8 is decoded per line, so a character split across two chunks is safe.
///
/// A synchronous transformer, not an `async*` generator: reading an SSH
/// channel with `await for` pauses the stream per chunk and cost 40 ms per
/// round trip (see `muxMessages` in `mux_client.dart` and docs/ENGINEERING.md). Never
/// pause the channel's stream per message.
Stream<String> splitLines(Stream<List<int>> bytes, {int maxLine = maxLineBytes}) {
  var buf = Uint8List(16 * 1024);
  var start = 0, end = 0;
  // Bytes before this offset are known not to hold a newline, so a big line
  // arriving in many chunks is scanned once, not once per chunk.
  var scanned = 0;
  // After an over-long line: skip bytes until its newline.
  var skipping = false;

  void emit(EventSink<String> sink, int from, int to) {
    if (to > from && buf[to - 1] == 0x0D) to--;
    if (to == from) return;
    if (to - from > maxLine) {
      sink.addError(FormatException('line longer than $maxLine bytes dropped'));
      return;
    }
    sink.add(utf8.decode(Uint8List.sublistView(buf, from, to), allowMalformed: true));
  }

  void feed(List<int> chunk, EventSink<String> sink) {
    if (end + chunk.length > buf.length) {
      final live = end - start;
      if (live + chunk.length > buf.length) {
        final bigger = Uint8List(math.max(live + chunk.length, buf.length * 2));
        bigger.setRange(0, live, buf, start);
        buf = bigger;
      } else {
        buf.setRange(0, live, buf, start);
      }
      scanned -= start;
      start = 0;
      end = live;
    }
    buf.setRange(end, end + chunk.length, chunk);
    end += chunk.length;

    while (true) {
      var nl = scanned < start ? start : scanned;
      while (nl < end && buf[nl] != 0x0A) {
        nl++;
      }
      if (nl == end) {
        scanned = end;
        break;
      }
      if (skipping) {
        skipping = false;
      } else {
        emit(sink, start, nl);
      }
      start = scanned = nl + 1;
    }
    if (end - start > maxLine) {
      if (!skipping) {
        sink.addError(FormatException('line longer than $maxLine bytes dropped'));
      }
      skipping = true;
      start = end = scanned = 0;
    }
    if (start == end) start = end = scanned = 0;
  }

  return StreamTransformer<List<int>, String>.fromHandlers(
    handleData: feed,
    handleDone: (sink) {
      if (!skipping && end > start) emit(sink, start, end);
      sink.close();
    },
  ).bind(bytes);
}

/// The standard JSON-RPC 2.0 error codes, plus the one ACP adds.
abstract final class JsonRpcCode {
  static const parseError = -32700;
  static const invalidRequest = -32600;
  static const methodNotFound = -32601;
  static const invalidParams = -32602;
  static const internalError = -32603;

  /// `$/cancel_request` answered: "Request cancelled".
  static const requestCancelled = -32800;
}

/// An error answer from the peer (to our request), or one to send as the
/// answer to its request: throw it from an incoming-request handler.
class JsonRpcException implements Exception {
  const JsonRpcException(this.code, this.message, [this.data]);

  JsonRpcException.methodNotFound(String method) : this(JsonRpcCode.methodNotFound, 'Method not found: $method');

  const JsonRpcException.invalidParams(String message, [Object? data])
    : this(JsonRpcCode.invalidParams, message, data);

  final int code;
  final String message;
  final Object? data;

  bool get isCancelled => code == JsonRpcCode.requestCancelled;

  @override
  String toString() => 'JsonRpcException($code: $message)';
}

/// The transport ended (or was closed) before the peer answered.
class JsonRpcClosedException implements Exception {
  const JsonRpcClosedException([this.message = 'connection closed']);

  final String message;

  @override
  String toString() => 'JsonRpcClosedException($message)';
}

/// A request we sent: its id, the answer, and a way to withdraw it.
class JsonRpcCall {
  JsonRpcCall._(this.id, this.response, this._cancel);

  final int id;

  /// The `result` (decoded JSON), or an error: [JsonRpcException] for the
  /// peer's error answer, [TimeoutException], [JsonRpcClosedException].
  final Future<Object?> response;
  final void Function() _cancel;

  /// Sends `$/cancel_request` for this call. The peer still answers (an
  /// error `-32800` or a partial result); [response] waits for that.
  void cancel() => _cancel();
}

/// A request the peer sent us. Answer by returning from the handler (the
/// value becomes `result`) or by throwing [JsonRpcException].
class IncomingRequest {
  IncomingRequest._(this.id, this.method, this.params, this._cancelled);

  /// The peer's id, an int or a string; echoed back untouched.
  final Object id;
  final String method;
  final Object? params;
  final Completer<void> _cancelled;

  /// Completes when the peer sends `$/cancel_request` for this request. The
  /// connection has by then answered `-32800` itself; what the handler
  /// returns afterwards is dropped.
  Future<void> get cancelled => _cancelled.future;
}

typedef IncomingRequestHandler = Future<Object?> Function(IncomingRequest request);
typedef IncomingNotificationHandler = void Function(String method, Object? params);

/// JSON-RPC 2.0 over newline-delimited JSON, both directions at once.
///
/// - Our requests are correlated by an integer id; each can have a timeout.
/// - The peer's requests go to [onRequest]; without one (or when it throws
///   [JsonRpcException.methodNotFound]) the peer gets `-32601`.
/// - `$/cancel_request` works both ways ([JsonRpcCall.cancel], and
///   [IncomingRequest.cancelled]).
/// - A malformed line, a message that is none of request/notification/
///   response, an answer nobody waits for: [onProblem] hears of it and the
///   stream goes on. Nothing is thrown into the stream.
/// - When the transport ends every pending request fails with
///   [JsonRpcClosedException] and [done] completes.
class JsonRpcConnection {
  JsonRpcConnection(
    this.transport, {
    this.onRequest,
    this.onNotification,
    this.onNotificationLine,
    this.onProblem,
    this.defaultTimeout,
  }) {
    _subscription = transport.lines.listen(
      _onLine,
      onError: (Object error, StackTrace _) => _problem('transport error: $error'),
      onDone: () => _shutdown(const JsonRpcClosedException('transport ended')),
      cancelOnError: false,
    );
  }

  final AcpTransport transport;
  final IncomingRequestHandler? onRequest;
  final IncomingNotificationHandler? onNotification;

  /// Told of every notification's raw text (its [method] and the whole line)
  /// just before [onNotification] sees it decoded: a caller that keeps a log
  /// of what arrived stores the line as it came, without encoding it again.
  final void Function(String method, String line)? onNotificationLine;

  /// A line or message that could not be used; [line] is the raw text when
  /// there is one.
  final void Function(String message, {String? line})? onProblem;

  /// Applied to requests that name no timeout of their own; null waits for
  /// ever.
  final Duration? defaultTimeout;

  late final StreamSubscription<String> _subscription;
  final _done = Completer<void>();
  final _pending = <int, _Pending>{};
  final _incoming = <Object, IncomingRequest>{};
  final _answered = <Object>{};
  var _nextId = 1;
  var _closed = false;

  /// Completes (never with an error) when the transport has ended or
  /// [close] ran.
  Future<void> get done => _done.future;
  bool get isClosed => _closed;

  /// Sends a request. [timeout] overrides [defaultTimeout]; pass
  /// [Duration.zero] for none (a prompt turn lasts as long as the agent
  /// works).
  JsonRpcCall call(String method, [Object? params, Duration? timeout]) {
    final id = _nextId++;
    final completer = Completer<Object?>();
    final pending = _Pending(completer);
    final call = JsonRpcCall._(id, completer.future, () {
      if (!_closed && _pending.containsKey(id)) notify(r'$/cancel_request', {'requestId': id});
    });
    if (_closed) {
      completer.completeError(const JsonRpcClosedException());
      return call;
    }
    _pending[id] = pending;
    final limit = timeout ?? defaultTimeout;
    if (limit != null && limit > Duration.zero) {
      pending.timer = Timer(limit, () {
        if (_pending.remove(id) == null) return;
        completer.completeError(TimeoutException('$method timed out', limit));
      });
    }
    try {
      _write({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': ?params});
    } on Object catch (e) {
      _pending.remove(id)?.timer?.cancel();
      completer.completeError(JsonRpcClosedException('send failed: $e'));
    }
    return call;
  }

  /// [call] without the handle.
  Future<Object?> request(String method, [Object? params, Duration? timeout]) => call(method, params, timeout).response;

  /// Sends a notification. Throws [JsonRpcClosedException] when the
  /// transport is gone.
  void notify(String method, [Object? params]) {
    if (_closed) throw const JsonRpcClosedException();
    try {
      _write({'jsonrpc': '2.0', 'method': method, 'params': ?params});
    } on Object catch (e) {
      throw JsonRpcClosedException('send failed: $e');
    }
  }

  /// Fails what is pending, stops listening and closes the transport.
  Future<void> close() async {
    _shutdown(const JsonRpcClosedException());
    await _subscription.cancel();
    try {
      await transport.close();
    } on Object {
      // Already gone.
    }
  }

  void _write(Map<String, Object?> message) => transport.send(jsonEncode(message));

  void _problem(String message, [String? line]) {
    try {
      onProblem?.call(message, line: line);
    } on Object {
      // A reporting hook must not break the stream.
    }
  }

  void _shutdown(JsonRpcClosedException why) {
    if (_closed) return;
    _closed = true;
    final pending = _pending.values.toList();
    _pending.clear();
    for (final p in pending) {
      p.timer?.cancel();
      p.completer.completeError(why);
    }
    for (final request in _incoming.values) {
      if (!request._cancelled.isCompleted) request._cancelled.complete();
    }
    _incoming.clear();
    if (!_done.isCompleted) _done.complete();
  }

  void _onLine(String line) {
    final Object? message;
    try {
      message = jsonDecode(line);
    } on FormatException catch (e) {
      _problem('not JSON: ${e.message}', line);
      return;
    }
    try {
      _dispatch(message, line);
    } on Object catch (e) {
      _problem('could not handle message: $e', line);
    }
  }

  void _dispatch(Object? message, String line) {
    if (message is! Map<String, Object?>) {
      _problem(message is List ? 'batches are not part of ACP' : 'not a JSON-RPC message', line);
      return;
    }
    final method = message['method'];
    final id = message['id'];
    if (method is String) {
      if (id == null) {
        try {
          onNotificationLine?.call(method, line);
        } on Object {
          // A log must never cost the stream a message.
        }
        _notification(method, message['params']);
      } else if (id is int || id is String) {
        _request(id, method, message['params']);
      } else {
        _problem('request id is neither a number nor a string', line);
      }
      return;
    }
    if (id != null && (message.containsKey('result') || message.containsKey('error'))) {
      _response(id, message, line);
      return;
    }
    _problem('neither a request, a notification nor a response', line);
  }

  void _notification(String method, Object? params) {
    if (method == r'$/cancel_request') {
      final target = params is Map ? params['requestId'] : null;
      final request = target == null ? null : _incoming[target];
      if (request == null) return; // Finished already: ignore, as the RFD says.
      if (_answered.add(request.id)) {
        _reply(request.id, error: const JsonRpcException(JsonRpcCode.requestCancelled, 'Request cancelled'));
      }
      if (!request._cancelled.isCompleted) request._cancelled.complete();
      return;
    }
    try {
      onNotification?.call(method, params);
    } on Object catch (e) {
      _problem('notification handler for $method threw: $e');
    }
  }

  void _request(Object id, String method, Object? params) {
    final request = IncomingRequest._(id, method, params, Completer<void>());
    final handler = onRequest;
    if (handler == null) {
      _reply(id, error: JsonRpcException.methodNotFound(method));
      return;
    }
    if (_incoming.containsKey(id)) {
      _reply(id, error: const JsonRpcException(JsonRpcCode.invalidRequest, 'request id is already in flight'));
      return;
    }
    _incoming[id] = request;
    Future<Object?>.sync(() => handler(request)).then<void>(
      (result) {
        _incoming.remove(id);
        if (_answered.remove(id)) return; // answered -32800 on cancel
        _reply(id, result: result);
      },
      onError: (Object e, StackTrace _) {
        _incoming.remove(id);
        if (_answered.remove(id)) return;
        if (e is JsonRpcException) {
          _reply(id, error: e);
        } else {
          _problem('handler for $method threw: $e');
          _reply(id, error: JsonRpcException(JsonRpcCode.internalError, '$e'));
        }
      },
    );
  }

  void _reply(Object id, {Object? result, JsonRpcException? error}) {
    if (_closed) return;
    try {
      _write({
        'jsonrpc': '2.0',
        'id': id,
        if (error != null)
          'error': {'code': error.code, 'message': error.message, if (error.data != null) 'data': error.data}
        else
          'result': result,
      });
    } on Object catch (e) {
      _problem('could not answer request $id: $e');
    }
  }

  void _response(Object rawId, Map<String, Object?> message, String line) {
    final id = rawId is int
        ? rawId
        : rawId is num
        ? rawId.toInt()
        : rawId is String
        ? int.tryParse(rawId)
        : null;
    final pending = id == null ? null : _pending.remove(id);
    if (pending == null) {
      _problem('answer to a request nobody waits for (id $rawId)', line);
      return;
    }
    pending.timer?.cancel();
    final error = message['error'];
    if (error != null) {
      if (error is Map) {
        final code = error['code'];
        final text = error['message'];
        pending.completer.completeError(
          JsonRpcException(code is int ? code : JsonRpcCode.internalError, text is String ? text : 'error', error['data']),
        );
      } else {
        pending.completer.completeError(JsonRpcException(JsonRpcCode.internalError, '$error'));
      }
      return;
    }
    pending.completer.complete(message['result']);
  }
}

class _Pending {
  _Pending(this.completer);

  final Completer<Object?> completer;
  Timer? timer;
}
