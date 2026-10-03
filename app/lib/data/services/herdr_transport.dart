import 'dart:async';
import 'dart:convert';

/// Connection-level failure: unreachable host, auth failure, dropped channel,
/// missing bridge. Retryable by reconnecting.
class HerdrTransportException implements Exception {
  const HerdrTransportException(this.message, {this.fatal = false});

  final String message;

  /// True when retrying cannot help without user action (bad credentials,
  /// changed host key, no bridge on the remote).
  final bool fatal;

  @override
  String toString() => message;
}

/// herdr answered with an `error` response.
class HerdrApiException implements Exception {
  const HerdrApiException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// Request/response and event-stream access to one herdr server.
///
/// herdr's own socket serves one request per connection, but implementations
/// should not pay a connection per [request]: [SshTransport] multiplexes
/// requests over one persistent channel and keeps one long-lived channel per
/// [events] subscription.
abstract interface class HerdrTransport {
  /// Sends [method] and returns the `result` object.
  /// Throws [HerdrApiException] on an API error, [HerdrTransportException]
  /// on connection problems.
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]);

  /// Subscribes to event [types] (e.g. `pane.updated`).
  /// Emits each event object; errors with [HerdrTransportException] if the
  /// channel drops. Cancelling the subscription closes the channel.
  Stream<Map<String, dynamic>> events(List<Map<String, dynamic>> subscriptions);

  /// Drops the underlying connection immediately, without waiting for a
  /// timeout: the network changed or the app was suspended, so the socket is
  /// presumed dead. In-flight requests and event streams fail with a
  /// retryable [HerdrTransportException]; the next call reconnects.
  void reset();

  Future<void> close();
}

/// Splits a byte stream into decoded JSON-line strings.
Stream<String> jsonLines(Stream<List<int>> bytes) =>
    utf8.decoder.bind(bytes).transform(const LineSplitter());

/// Parses one response line and returns its `result`, or throws.
Map<String, dynamic> unwrapResponse(String line) {
  final Object? decoded;
  try {
    decoded = jsonDecode(line);
  } on FormatException {
    throw HerdrTransportException('Malformed response from herdr: $line');
  }
  if (decoded is! Map<String, dynamic>) {
    throw HerdrTransportException('Unexpected response from herdr: $line');
  }
  final error = decoded['error'];
  if (error is Map) {
    throw HerdrApiException(
      (error['code'] as String?) ?? 'error',
      (error['message'] as String?) ?? 'unknown error',
    );
  }
  final result = decoded['result'];
  if (result is! Map<String, dynamic>) {
    throw HerdrTransportException('Response has no result: $line');
  }
  return result;
}
