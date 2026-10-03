import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../models/remote_file.dart';

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

  /// Whether [statFile] and friends can work on this transport at all. False
  /// for transports without a file channel (they throw
  /// [RemoteFileErrorKind.unsupported]).
  bool get supportsFiles;

  /// File operations over SFTP (no remote shell, so nothing to inject into).
  /// Each throws [RemoteFileException] for a file-level problem and
  /// [HerdrTransportException] when the connection itself fails.
  ///
  /// Follows links. Throws notFound / permission.
  Future<RemoteStat> statFile(String path);

  /// Entries of directory [path] (without `.` and `..`), in server order.
  /// Throws notFound / permission / notADirectory.
  Future<List<RemoteEntry>> listDirectory(String path);

  /// Up to [length] bytes from [offset]; fewer at end of file. [length] is
  /// clamped to [remoteReadCap] here whatever the caller asks for. Throws
  /// notFound / permission / notAFile.
  Future<Uint8List> readFile(String path, {int offset = 0, int length = remoteReadCap});

  /// Canonical absolute form of [path] (links resolved when it exists). The
  /// SFTP default directory is the login home, so `realPath('.')` is home.
  Future<String> realPath(String path);

  Future<void> close();
}

/// Splits a byte stream into decoded JSON-line strings.
Stream<String> jsonLines(Stream<List<int>> bytes) =>
    utf8.decoder.bind(bytes).transform(const LineSplitter());

/// Returns the `result` of an already-decoded response, or throws.
Map<String, dynamic> unwrapDecoded(Object? decoded) {
  if (decoded is! Map<String, dynamic>) {
    throw const HerdrTransportException('Unexpected response from herdr');
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
    throw const HerdrTransportException('Response has no result');
  }
  return result;
}

/// Parses one response line and returns its `result`, or throws.
Map<String, dynamic> unwrapResponse(String line) {
  final Object? decoded;
  try {
    decoded = jsonDecode(line);
  } on FormatException {
    final shown = line.length > 200 ? '${line.substring(0, 200)}…' : line;
    throw HerdrTransportException('Malformed response from herdr: $shown');
  }
  return unwrapDecoded(decoded);
}
