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

/// A command running on the host, reached through the machine's SSH
/// connection: its stdout as lines, its stdin as [send].
///
/// Ends (see [lines], [exitCode]) when the command exits or the connection
/// drops; it never reconnects or retries by itself.
abstract interface class ExecChannel {
  /// What the command wrote to stdout, one text per element, without the
  /// newline (a trailing `\r` is dropped, blank lines are skipped). Single
  /// subscription, buffered until listened to. Ends when the command exits or
  /// the connection drops; through an isolate it errors with a retryable
  /// [HerdrTransportException] first when the worker died.
  Stream<String> get lines;

  /// Writes [line] and a newline to the command's stdin. Throws a
  /// [StateError] after [close]; does nothing once the command has ended.
  void send(String line);

  /// Ends the command's input: it sees end of file on stdin, while its output
  /// and exit status can still be read. For a command that reads its input to
  /// the end and then answers (an installer). Idempotent; [send] throws a
  /// [StateError] afterwards. [close] still ends the channel.
  Future<void> closeInput();

  /// Exit status of the command; null when it was killed by a signal or the
  /// connection dropped. Completes once the channel has ended.
  Future<int?> get exitCode;

  /// The last ~2 KB the command wrote to stderr, for error messages. Complete
  /// once [exitCode] has completed.
  String get stderrTail;

  /// Closes the command's stdin, then the channel. Idempotent. The SSH
  /// connection and its other channels are not touched.
  Future<void> close();
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

  /// The app is in the background (true) watching agents for notifications,
  /// or back in the foreground (false). In the background the liveness checks
  /// of the connection relax (a ping every 120 s instead of 8 s) to save the
  /// radio; going back to the foreground restores the old intervals and tests
  /// the link at once, so one that died meanwhile shows in seconds. Idempotent;
  /// the setting survives reconnects. The connection is never closed by it.
  void setBackground(bool background);

  /// Drops the underlying connection immediately, without waiting for a
  /// timeout: the network changed or the app was suspended, so the socket is
  /// presumed dead. In-flight requests and event streams fail with a
  /// retryable [HerdrTransportException]; the next call reconnects.
  void reset();

  /// Runs [command] on the host over this machine's existing SSH connection
  /// (a new channel on it, never a new connection) and returns once the
  /// command has started. Throws [HerdrTransportException] when the
  /// connection or the channel cannot be opened.
  ///
  /// With [zipped] the command is `keeper attach --z` (`keeperAttachCommand`):
  /// what it writes is plain lines and `Z<base64>` lines of one zlib stream.
  /// The transport reads that back where it decodes the network, so the
  /// channel's [ExecChannel.lines] are plain lines either way and the caller
  /// never inflates anything on the UI isolate.
  Future<ExecChannel> openExec(String command, {bool zipped = false});

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

  /// `mkdir -p` over SFTP: creates [path] and any missing parents with mode
  /// 0700; an existing folder is left as it is. Throws permission /
  /// notADirectory.
  Future<void> makeDirs(String path);

  /// Deletes the regular file (or link) at [path]; never a folder. Throws
  /// notFound / permission.
  Future<void> removeFile(String path);

  /// Copies the local file [localPath] to [remotePath] (created or
  /// overwritten, mode 0600) over the machine's one SFTP channel. The file is
  /// read and sent where the connection lives (the worker isolate): no bytes
  /// reach the caller. [onProgress] hears the bytes the host has acknowledged
  /// (monotonic, at most every 100 ms, the last call is `total`/`total`). The
  /// job's `done` fails with [RemoteFileException]; a half-written file is
  /// removed. Not resumed after a lost connection.
  UploadJob uploadFile({
    required String localPath,
    required String remotePath,
    void Function(int sent, int total)? onProgress,
  });

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
