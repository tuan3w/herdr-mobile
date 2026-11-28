import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../models/remote_file.dart';
import '../models/remote_search.dart';
import '../models/web_bridge.dart';

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

/// A stream of the agent helper on the host (`HerdrTransport.openHostStream`),
/// reached through the machine's SSH connection: its data as lines, [send] to
/// write to it.
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

/// The marker event a transport emits first from [HerdrTransport.events] once
/// herdr has accepted the subscription: herdr streams only what happens after
/// that, so whatever changed between the caller's snapshot and this moment
/// needs one refresh.
const subscriptionStartedEvent = 'subscription_started';

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
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]);

  /// Subscribes to event [types] (e.g. `pane.updated`).
  /// Emits each event object; errors with [HerdrTransportException] if the
  /// channel drops. Cancelling the subscription closes the channel. A
  /// transport that knows when herdr accepted the subscription first emits
  /// `{'event': subscriptionStartedEvent}` (see [subscriptionStartedEvent]).
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

  /// Runs [method] of [service] on the agent helper of this machine
  /// (`herdr-host serve`, hostwire/1) and returns its JSON result: the one
  /// message the call answers with, decoded (null when there was none). The
  /// helper is installed on first use when the host does not have it.
  ///
  /// Throws [HostException] for what the host answered (`not_found`,
  /// `permission`, …) or when the helper cannot be had on this machine
  /// (`unavailable`); [HostLinkLost] (retryable) when the connection drops; and
  /// [HerdrTransportException] when no channel can be opened.
  Future<Object?> hostCall(String service, String method, [Map<String, Object?> args = const {}, Duration? timeout]);

  /// Opens the stream [service].[method] with [args] on the agent helper and
  /// returns it as a line channel: the lines the stream's data holds (a keeper
  /// attach, a log follow). [ExecChannel.exitCode] is how the stream ended in the
  /// keeper's exit codes (0 done, 66 not found, 67 agent exited, … 65 the helper
  /// is not available, null the link dropped) and [ExecChannel.stderrTail] the
  /// host's words for a failure. Errors as [hostCall].
  Future<ExecChannel> openHostStream(String service, String method, [Map<String, Object?> args = const {}]);

  /// Opens the stream [service].[method] with [args] on the agent helper and
  /// returns what it sends as decoded JSON messages, in order (a watch: file
  /// changes, listening ports). The host stream opens when the returned stream is
  /// listened to and ends when the subscription is cancelled (the host stops
  /// watching). It errors with [HostException] when the host ends it in failure
  /// (`unavailable` when the helper cannot be had, `bad_request`, …) or with
  /// [HostLinkLost] when the connection drops, then closes.
  Stream<Object?> openHostMessages(String service, String method, [Map<String, Object?> args = const {}]);

  /// Whether [statFile] and friends can work on this transport at all. False
  /// for transports without a file channel (they throw
  /// [RemoteFileErrorKind.unsupported]).
  bool get supportsFiles;

  /// File operations: through the agent helper's `fs` service when the machine
  /// has it, over SFTP (read-only, no remote shell) when it has not. Each throws
  /// [RemoteFileException] for a file-level problem and
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
  ///
  /// With [ifMatch] (the file as it was seen) the read only happens when the
  /// file still has that size and modification time, else it throws
  /// [RemoteFileChanged]: only the agent helper can check that, SFTP reads
  /// whatever is there.
  Future<Uint8List> readFile(String path, {int offset = 0, int length = remoteReadCap, RemoteStat? ifMatch});

  /// Canonical absolute form of [path] (links resolved when it exists). The
  /// login directory is where `.` and relative paths start, so `realPath('.')`
  /// is home.
  Future<String> realPath(String path);

  /// [path] now (null when nothing is there) and again whenever it changes, until
  /// the subscription is cancelled: the helper looks every couple of seconds
  /// and tells only changes, SFTP is asked every 15 s. A failure ends the stream
  /// with it (a [RemoteFileException] or [HerdrTransportException]); listening
  /// again starts over.
  Stream<RemoteStat?> watchFile(String path);

  /// A small JPEG of the picture at [path] (longest side [maxPx]) made on the
  /// machine, or null when this machine cannot make one (no agent helper, an
  /// older one, a file it cannot read, too large, changed since [expect]) or
  /// [cancelled] completed first. Never throws for a file-level reason: the
  /// caller does what it did before thumbnails existed. See
  /// [RemoteFileBackend.thumbnail].
  Future<Uint8List?> thumbnailFile(String path, {int maxPx = 256, RemoteStat? expect, Future<void>? cancelled});

  /// The matches of [spec] below its root, in batches as they are found, then
  /// one [FileSearchDone]; cancelling the subscription stops the search. Fails
  /// like [listDirectory] for the root. See [RemoteFileBackend.search].
  Stream<FileSearchEvent> searchFiles(FileSearchSpec spec);

  /// Picks the host's inbox path for the phone file [name] of the session
  /// [key]: `<home>/.herdr-mobile/inbox/<12 hex of sha1(key)>/<UTC time>-<name>`
  /// with the folders made (0700). The host owns the naming (safe name, unique);
  /// the same arguments give a new path each time.
  ///
  /// Throws [RemoteFileException] with kind `unsupported` and the reason
  /// "Needs the agent helper on this machine." on a machine without the helper:
  /// nothing is written to a host any other way.
  Future<String> reserveInboxFile({required String key, required String name});

  /// Copies the local file [localPath] to [inboxPath] (a path [reserveInboxFile]
  /// gave) through the agent helper. The file is hashed, read and sent where the
  /// connection lives (the worker isolate): no bytes reach the caller.
  /// [onProgress] hears the bytes sent (monotonic, at most every 100 ms, the
  /// last call is `total`/`total` once the host stored the file, mode 0600).
  /// The job's `done` fails with [RemoteFileException] (see [UploadJob]).
  ///
  /// A lost connection or [UploadJob.cancel] keeps what the host received:
  /// calling this again with the same file and [inboxPath] continues there.
  /// Without the helper the job fails with kind `unsupported`.
  UploadJob uploadFile({
    required String localPath,
    required String inboxPath,
    void Function(int sent, int total)? onProgress,
  });

  /// Removes the old files from the host's inbox (the host decides which: 14
  /// days, at most 200 a call) and returns how many went. Throws like
  /// [reserveInboxFile].
  Future<int> sweepInbox();

  /// Starts (or finds) the loopback listener for [spec] on the phone and
  /// returns its port and token. Idempotent per [WebBridgeSpec.key]: the same
  /// spec gives the same port and token, also after the listener stopped for
  /// idleness, so a browser tab that is reloaded later still works. Each call
  /// restarts the idle timer.
  ///
  /// Throws [HerdrTransportException] when no port can be bound, or when the
  /// host forbids port forwarding (a [PortForward]). A [StaticSite] on a host
  /// without SFTP opens; its pages then answer with the reason.
  Future<WebBridgeInfo> openWebBridge(WebBridgeSpec spec);

  Future<void> close();
}

/// Splits a byte stream into decoded JSON-line strings.
Stream<String> jsonLines(Stream<List<int>> bytes) => utf8.decoder.bind(bytes).transform(const LineSplitter());

/// Returns the `result` of an already-decoded response, or throws.
Map<String, dynamic> unwrapDecoded(Object? decoded) {
  if (decoded is! Map<String, dynamic>) {
    throw const HerdrTransportException('Unexpected response from herdr');
  }
  final error = decoded['error'];
  if (error is Map) {
    throw HerdrApiException((error['code'] as String?) ?? 'error', (error['message'] as String?) ?? 'unknown error');
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
