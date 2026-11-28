import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import '../acp/agent_host.dart';
import '../acp/json_rpc.dart' show AcpTransport;
import '../acp/past_session.dart';
import '../host/host_channels.dart' show exitStatusOf;
import '../host/host_link.dart' show HostEnd, HostException;
import 'herdr_transport.dart';

/// How long the keeper waits for a new agent to answer `initialize` before it
/// ends the start with the agent's last stderr lines: `INIT_TIMEOUT` in the
/// keeper (`rust/crates/keeper/src/records.rs`; there is no Dart constant to
/// derive it from, so a test reads the source and fails if the two differ).
const keeperInitTimeoutSeconds = 120;

/// Slack on top of [keeperInitTimeoutSeconds] for the SSH round trips.
const startMarginSeconds = 30;

/// [AgentHost] over the machine's agent helper link: every operation is a call
/// or a stream of the `keeper` service ([HerdrTransport.hostCall],
/// [HerdrTransport.openHostStream]; `docs/host-api.json` lists the methods),
/// never a connection or channel of its own. The link installs the helper when
/// the host does not have it, so nothing here does.
///
/// The helper's errors keep its words and map to the exit statuses the keeper's
/// commands always ended with: `bad_request` 64, `not_found` 66, `agent_exited`
/// 67, `agent_missing` 69, `failed` 70.
class SshAgentHost implements AgentHost {
  SshAgentHost(
    this._transport, {
    this.quickTimeout = const Duration(seconds: 10),
    this.startTimeout = const Duration(seconds: keeperInitTimeoutSeconds + startMarginSeconds),
  });

  final HerdrTransport _transport;

  /// Longest wait for probe, list and kill.
  final Duration quickTimeout;

  /// Longest wait for `start`: the keeper launches the agent and asks it to
  /// `initialize`, and a first run of an `npx` route downloads the adapter.
  /// The keeper gives up on its own after [keeperInitTimeoutSeconds] and says
  /// why; this waits [startMarginSeconds] longer so that message, not a generic
  /// timeout, is what the person reads.
  final Duration startTimeout;

  @override
  Future<Set<String>> available() async {
    const what = 'check the agents';
    final answer = await _call('probe', const {}, quickTimeout, what);
    final routes = answer is Map ? answer['routes'] : null;
    if (routes is! List) throw _unexpected(answer, what);
    return {for (final r in routes) '$r'};
  }

  @override
  Future<List<KeeperInfo>> list() async {
    const what = 'the session list';
    final answer = await _call('list', const {}, quickTimeout, 'list the sessions');
    if (answer is! List) throw _unexpected(answer, what);
    try {
      return KeeperInfo.listFromJson(answer);
    } on FormatException {
      throw _unexpected(answer, what);
    } on TypeError {
      throw _unexpected(answer, what);
    }
  }

  @override
  Future<KeeperInfo> start({required String agent, required String cwd}) async {
    const what = 'the new session';
    final answer = await _call('start', {'agent': agent, 'cwd': cwd}, startTimeout, 'start the agent');
    if (answer is! Map) throw _unexpected(answer, what);
    try {
      return KeeperInfo.fromJson(Map<String, Object?>.from(answer));
    } on FormatException {
      throw _unexpected(answer, what);
    } on TypeError {
      throw _unexpected(answer, what);
    }
  }

  @override
  Future<PastSessions> history({required String agent, String? cwd}) async {
    const what = 'the past sessions';
    final answer = await _call('history', {'agent': agent, 'cwd': ?cwd}, startTimeout, 'read the past sessions');
    if (answer is! Map) throw _unexpected(answer, what);
    try {
      return PastSessions.fromJson(Map<String, Object?>.from(answer));
    } on FormatException {
      throw _unexpected(answer, what);
    } on TypeError {
      throw _unexpected(answer, what);
    }
  }

  @override
  Future<void> kill(String keeperId) async {
    await _call('kill', {'id': keeperId}, quickTimeout, 'end the session');
  }

  @override
  Future<AcpTransport> attach(String keeperId) async => KeeperAttachment._(await _open('attach', {'id': keeperId}));

  /// Follows the agent's session log [path] (an absolute `.jsonl` path under
  /// the host user's home; the host answers `bad_request` or `not_found` for
  /// anything else) and returns the line channel of its records:
  ///
  /// - `<endOffset>\t<json>`: a log line, re-serialised compactly, every
  ///   string cut to 16 KB (`... [N bytes cut]`) and binary payloads dropped,
  ///   each with a note that says where to fetch it (`ref=`, see [blob]);
  /// - `S\t<offset>`: before the first line of a tail read (at the start and
  ///   with every `R`): where in the file the tail begins, 0 when whole;
  /// - `R\t<offset>`: the file shrank or was replaced (or [from] is not a line
  ///   end of it): forget what came before, what follows is its content from
  ///   `offset`;
  /// - `C\t<offset>`: once, after the first read to the end of the file:
  ///   everything up to `offset` has been sent;
  /// - `E\t<message>`: reading failed; the stream ends with `failed`.
  ///
  /// First the tail of the file (the last [tailBytes] from a line start, 192 KB
  /// by default, clamped by the host to 16 KB..64 MB), or with [from] everything
  /// after that byte offset; then every complete line that is appended. With
  /// [to] it reads the part from [from] (default 0) up to that byte offset
  /// once, sends its `C` and ends (a line that holds the offset is sent whole).
  /// With [digest] the records are the digest of the lines (thinking emptied,
  /// strings cut to 8 KB, bookkeeping entries left out). The host compresses
  /// the stream. Closing the channel ends the follow.
  ///
  /// Failures are [AgentHostException]s, a link problem a non-fatal one.
  Future<ExecChannel> follow(String path, {int? from, int? to, bool digest = false, int? tailBytes}) =>
      _open('follow', {'path': path, 'from': ?from, 'to': ?to, if (digest) 'digest': true, 'tail_bytes': ?tailBytes});

  /// Longest wait for [blob]: a picture of up to about 3 MB (4 MB of text, the
  /// most `follow` gives a reference to) over a slow link, with the connection
  /// allowed to be slow rather than dead.
  static const blobTimeout = Duration(seconds: 90);

  /// The binary payload `follow` dropped from the log line that starts at byte
  /// [start] of [path]; [hash] is the 16 lowercase hex digits in the `ref=` of
  /// its note. The picture's base64 text arrives as `B\t<piece>` records and a
  /// closing `D\t<length>`; what comes back is its bytes. A reply whose length
  /// does not match was cut short (the link dropped mid-way).
  Future<Uint8List> blob(String path, {required int start, required String hash}) async {
    const what = 'read the picture';
    final channel = await _open('blob', {'path': path, 'start': start, 'hash': hash}, timeout: blobTimeout, what: what);
    final lines = <String>[];
    final ended = Completer<void>();
    final sub = channel.lines.listen(lines.add, onError: (Object _) {}, onDone: ended.complete);
    try {
      await channel.closeInput();
      final int? code;
      try {
        code = await Future.wait<Object?>([ended.future, channel.exitCode])
            .then((r) => r[1] as int?)
            .timeout(blobTimeout);
      } on TimeoutException {
        throw const AgentHostException('The machine didn’t answer in time ($what).');
      }
      if (code != 0) throw _failure(code, channel.stderrTail, what);
    } finally {
      unawaited(sub.cancel());
      try {
        await channel.close().timeout(const Duration(seconds: 3));
      } on Object {
        // the connection is gone, so the channel is too
      }
    }
    final text = StringBuffer();
    int? total;
    for (final line in lines) {
      if (line.startsWith('B\t')) {
        text.write(line.substring(2));
      } else if (line.startsWith('D\t')) {
        total = int.tryParse(line.substring(2));
      }
    }
    final joined = text.toString();
    if (total == null || total != joined.length || joined.isEmpty) {
      throw const AgentHostException('The picture came back incomplete.');
    }
    try {
      return joined.length > _blobIsolateFromChars ? await _decodeOffThread(joined) : base64.decode(joined);
    } on FormatException {
      throw const AgentHostException('That isn’t a picture.', fatal: true);
    }
  }

  // Base64 text longer than this is decoded off the UI isolate (the same
  // threshold as the preview cache's).
  static const _blobIsolateFromChars = 64 * 1024;

  /// `keeper.[method]` as a call: its one JSON answer, or an
  /// [AgentHostException] in the helper's words.
  Future<Object?> _call(String method, Map<String, Object?> args, Duration timeout, String what) async {
    try {
      return await _transport.hostCall('keeper', method, args, timeout).timeout(timeout);
    } on TimeoutException {
      throw AgentHostException('The machine didn’t answer in time ($what).');
    } on HostException catch (e) {
      throw _hostFailure(e, what);
    } on HerdrTransportException catch (e) {
      throw AgentHostException(e.message, fatal: e.fatal);
    }
  }

  /// Opens the stream `keeper.[method]` and returns its line channel, running.
  /// Everything that goes wrong is an [AgentHostException] (a link problem a
  /// non-fatal one).
  Future<ExecChannel> _open(
    String method,
    Map<String, Object?> args, {
    Duration timeout = const Duration(seconds: 30),
    String what = 'reach the machine',
  }) async {
    final opening = _transport.openHostStream('keeper', method, args);
    try {
      return await opening.timeout(timeout);
    } on TimeoutException {
      // The channel may still arrive; it must not stay open.
      unawaited(opening.then((c) => c.close(), onError: (Object _) {}));
      throw AgentHostException('The machine didn’t answer in time ($what).');
    } on HostException catch (e) {
      throw _hostFailure(e, what);
    } on HerdrTransportException catch (e) {
      throw AgentHostException(e.message, fatal: e.fatal);
    }
  }

  static AgentHostException _unexpected(Object? answer, String what) {
    final text = jsonEncode(answer);
    return AgentHostException('The machine answered something unexpected for $what: ${_excerpt(text, 120)}');
  }
}

/// Decodes base64 in another isolate. Top level on purpose: a closure made in a
/// method would drag the host (and its transport) into the message, which an
/// isolate cannot be sent.
Future<Uint8List> _decodeOffThread(String text) => Isolate.run(() => base64.decode(text));

/// The last part of [text], which is where an error message is.
String _excerpt(String text, [int max = 400]) {
  final t = text.trim();
  return t.length <= max ? t : '…${t.substring(t.length - max)}';
}

/// The words for a [HostException] of a call or stream that did not start.
AgentHostException _hostFailure(HostException e, String what) => switch (e.code) {
  'timeout' => AgentHostException('The machine didn’t answer in time ($what).'),
  'unavailable' => const AgentHostException('The machine couldn’t set up agent sessions.'),
  // The installer's own words (what it said on stderr) are the explanation.
  'install_failed' => AgentHostException(e.message),
  _ => _failure(exitStatusOf(HostEnd(error: e)), e.message, what),
};

/// The words for an exit status of a keeper command that did not succeed.
/// [code] is null when the connection dropped. Fatal where trying again
/// cannot help.
AgentHostException _failure(int? code, String stderr, String what) {
  final said = _excerpt(stderr);
  String or(String fallback) => said.isEmpty ? fallback : said;
  return switch (code) {
    null => const AgentHostException('The connection to the machine dropped.'),
    66 => AgentHostException(or('That folder or session doesn’t exist on the machine.'), fatal: true),
    67 => AgentHostException(or('The agent of this session has exited.'), fatal: true),
    69 => AgentHostException(or('That agent isn’t installed on the machine.'), fatal: true),
    65 => AgentHostException(or('The machine couldn’t set up agent sessions.')),
    70 => AgentHostException(or('The agent exited while starting.')),
    64 => AgentHostException(or('The app asked the machine something it didn’t understand.'), fatal: true),
    _ => AgentHostException(or('Couldn’t $what (exit status $code).')),
  };
}

/// The words for a keeper stream that ended with [code] (null: the connection
/// dropped) after it was running: [stderr] is its last words, [what] says what
/// the person was doing ("follow the session").
AgentHostException keeperCommandFailure(int? code, String stderr, String what) => _failure(code, stderr, what);

/// The [AcpTransport] of one attach: the keeper's lines as [lines], [send]
/// to it. [close] detaches (the keeper sees the stream end); the agent lives
/// on.
///
/// When the attach ends with a failure (the keeper is unknown or its agent has
/// exited) [lines] reports an [AgentHostException] and then ends, and
/// [endReason] holds the same exception. A clean end (evicted by a newer
/// attach, which only a keeper started before shared sessions does; the agent
/// exited while attached; the connection dropped) has no reason here: the
/// keeper's own notifications and the connection state say why.
class KeeperAttachment implements AcpTransport {
  KeeperAttachment._(this._channel) {
    _channel.lines.listen(_out.add, onError: _out.addError, onDone: _ended);
  }

  final ExecChannel _channel;
  final _endReason = Completer<AgentHostException?>();

  // Synchronous, like the stream it forwards: see `splitLines`.
  late final StreamController<String> _out = StreamController<String>(sync: true, onCancel: close);

  Future<void> _ended() async {
    AgentHostException? reason;
    try {
      final code = await _channel.exitCode;
      if (code != null && code != 0) {
        reason = _failure(code, _channel.stderrTail, 'stay attached');
      }
    } on Object {
      // no status: the connection dropped
    }
    if (reason != null) _out.addError(reason);
    _endReason.complete(reason);
    unawaited(_out.close());
  }

  @override
  Stream<String> get lines => _out.stream;

  /// Why the attach failed; null when it ended cleanly. Completes when
  /// [lines] ends.
  Future<AgentHostException?> get endReason => _endReason.future;

  @override
  void send(String line) => _channel.send(line);

  @override
  Future<void> close() => _channel.close();
}
