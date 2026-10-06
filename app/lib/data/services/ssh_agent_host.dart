import 'dart:async';
import 'dart:convert';

import '../acp/agent_host.dart';
import '../acp/json_rpc.dart' show AcpTransport;
import '../acp/past_session.dart';
import 'herdr_transport.dart';
import 'keeper_command.dart';

/// How long the keeper waits for a new agent to answer `initialize` before it
/// ends the start with the agent's last stderr lines: `INIT_TIMEOUT` in the
/// keeper script (`keeper_script.dart`; there is no Dart constant to derive it
/// from, so a test reads the script and fails if the two differ).
const keeperInitTimeoutSeconds = 120;

/// Slack on top of [keeperInitTimeoutSeconds] for the SSH round trips.
const startMarginSeconds = 30;

/// [AgentHost] over the machine's existing SSH connection: every operation is
/// one exec channel on it ([HerdrTransport.openExec]), never a second
/// connection. The commands are `keeper_command.dart`'s; their output and
/// exit codes are the keeper's contract:
///
/// - 0: done. 65: the script is not on the host (it is installed, once, and the
///   command repeated). 66: the folder or keeper does not exist. 67: the
///   keeper's agent has exited. 69: the agent is not installed. 70: the agent
///   failed to start. 78: the host has no python3. Anything else: the stderr
///   text.
class SshAgentHost implements AgentHost {
  SshAgentHost(
    this._transport, {
    this.quickTimeout = const Duration(seconds: 10),
    this.startTimeout = const Duration(seconds: keeperInitTimeoutSeconds + startMarginSeconds),
    this.installTimeout = const Duration(seconds: 30),
    this.attachCheck = const Duration(seconds: 2),
  });

  final HerdrTransport _transport;

  /// Longest wait for probe, list and kill.
  final Duration quickTimeout;

  /// Longest wait for `start`: the keeper launches the agent and asks it to
  /// `initialize`, and a first run of an `npx` route downloads the adapter.
  /// The keeper gives up on its own after [keeperInitTimeoutSeconds] and says
  /// why on stderr; this waits [startMarginSeconds] longer so that message,
  /// not a generic timeout, is what the person reads.
  final Duration startTimeout;

  /// Longest wait for putting the keeper script on the host.
  final Duration installTimeout;

  /// How long [attach] watches a new channel for an early exit 65 (script not
  /// installed) while the host is not known to have the script. Once any
  /// command has worked, or the script was installed, attach opens directly.
  final Duration attachCheck;

  // Whether the script is known to be on the host. Set by any command that
  // ran, and by an install; cleared by a 65.
  var _present = false;
  // Bumped by every successful install, so an operation that failed with 65
  // before the install finished does not install again.
  var _installs = 0;
  Future<void>? _installing;

  @override
  Future<Set<String>> available() async {
    final out = await _withInstall(
      () => _run(keeperProbeCommand(), quickTimeout, 'check the agents'),
    );
    final answer = _json<Map<Object?, Object?>>(out, 'the agent check');
    final routes = answer['routes'];
    if (routes is! List) throw _unexpected(out, 'the agent check');
    return {for (final r in routes) '$r'};
  }

  @override
  Future<List<KeeperInfo>> list() async {
    final out = await _withInstall(
      () => _run(keeperListCommand(), quickTimeout, 'list the sessions'),
    );
    final rows = _json<List<Object?>>(out, 'the session list');
    return [
      for (final row in rows)
        if (row is Map) KeeperInfo.fromJson(Map<String, Object?>.from(row)),
    ];
  }

  @override
  Future<KeeperInfo> start({required String agent, required String cwd}) async {
    final String command;
    try {
      command = keeperStartCommand(agent: agent, cwd: cwd);
    } on ArgumentError catch (e) {
      throw AgentHostException(
        e.name == 'cwd' ? 'That folder name cannot be used.' : 'That agent is not known.',
        fatal: true,
      );
    }
    final out = await _withInstall(() => _run(command, startTimeout, 'start the agent'));
    final info = _json<Map<Object?, Object?>>(out, 'the new session');
    return KeeperInfo.fromJson(Map<String, Object?>.from(info));
  }

  @override
  Future<PastSessions> history({required String agent, String? cwd}) async {
    final String command;
    try {
      command = keeperHistoryCommand(agent: agent, cwd: cwd);
    } on ArgumentError catch (e) {
      throw AgentHostException(
        e.name == 'cwd' ? 'That folder name cannot be used.' : 'That agent is not known.',
        fatal: true,
      );
    }
    final out = await _withInstall(() => _run(command, startTimeout, 'read the past sessions'));
    final answer = _json<Map<Object?, Object?>>(out, 'the past sessions');
    return PastSessions.fromJson(Map<String, Object?>.from(answer));
  }

  @override
  Future<void> kill(String keeperId) async {
    await _withInstall(
      () => _run(keeperKillCommand(keeperId), quickTimeout, 'end the session', needsOutput: false),
    );
  }

  @override
  Future<AcpTransport> attach(String keeperId) async {
    return KeeperAttachment._(await openKeeperChannel(keeperAttachCommand(keeperId)));
  }

  /// Opens the long-lived channel of a keeper [command] (`keeperAttachCommand`,
  /// `keeperFollowCommand`) and returns it running. When the host says the
  /// script is not installed (65) it is installed and the command opened once
  /// more. [recheck] is for a caller whose channel just ended with 65 after it
  /// had been opened: the host is then not trusted to still have the script,
  /// so the open watches for a 65 again. Everything that goes wrong is an
  /// [AgentHostException] (a link problem a non-fatal one).
  Future<ExecChannel> openKeeperChannel(String command, {bool recheck = false}) {
    if (recheck) _present = false;
    return _withInstall(() => _openAttach(command));
  }

  /// Opens the long-lived attach channel. While the script is not known to be
  /// on the host the channel is watched for [attachCheck]: the short command
  /// checks for the script before anything else, so a 65 shows at once.
  Future<ExecChannel> _openAttach(String command) async {
    final ExecChannel channel;
    try {
      channel = await _transport.openExec(command);
    } on HerdrTransportException catch (e) {
      throw AgentHostException(e.message, fatal: e.fatal);
    }
    if (_present) return channel;
    final early = await channel.exitCode.then<int?>((c) => c).timeout(
          attachCheck,
          onTimeout: () => -1,
        );
    if (early == _notInstalledExit) {
      _present = false;
      unawaited(channel.close());
      throw const _NotInstalled();
    }
    // Still running after the check, or ended for another reason that the
    // attachment reports: either way the script is there.
    _present = true;
    return channel;
  }

  /// Runs [op]; when the host says the script is not installed (65) installs
  /// it and runs [op] once more. Never more than one install and one retry
  /// per call.
  Future<T> _withInstall<T>(Future<T> Function() op) async {
    final generation = _installs;
    try {
      return await op();
    } on _NotInstalled {
      _present = false;
      if (_installs == generation) await _install();
    }
    try {
      return await op();
    } on _NotInstalled {
      _present = false;
      throw const AgentHostException(
        'The agent helper is still missing on the machine after installing it.',
      );
    }
  }

  /// One install at a time: callers that arrive while it runs wait for it.
  Future<void> _install() => _installing ??= _doInstall().whenComplete(() => _installing = null);

  Future<void> _doInstall() async {
    final _Output out;
    try {
      out = await _run(
        keeperInstallCommand(),
        installTimeout,
        'set up agent sessions',
        input: keeperInstallPayload(),
      );
    } on _NotInstalled {
      throw const AgentHostException('The machine could not set up agent sessions.');
    }
    final Map<Object?, Object?> answer;
    try {
      answer = _json<Map<Object?, Object?>>(out, 'the agent setup');
    } on AgentHostException {
      throw AgentHostException(
        'The machine could not set up agent sessions.${_after(out.stderr)}',
      );
    }
    if (answer['ok'] != true) {
      throw AgentHostException(
        'The machine could not set up agent sessions.${_after(out.stderr)}',
      );
    }
    _installs++;
    _present = true;
  }

  /// Runs [command], collects its stdout and returns it once it exited 0.
  /// The channel is closed on every path. With [input] the text is written to
  /// the command's stdin and stdin is then closed (a command that reads to
  /// end of input, then answers).
  Future<_Output> _run(
    String command,
    Duration timeout,
    String what, {
    bool needsOutput = true,
    String? input,
  }) async {
    final ExecChannel channel;
    final opening = _transport.openExec(command);
    try {
      channel = await opening.timeout(timeout);
    } on TimeoutException {
      // The channel may still arrive; it must not stay open.
      unawaited(opening.then((c) => c.close(), onError: (Object _) {}));
      throw AgentHostException('The machine did not answer in time ($what).');
    } on HerdrTransportException catch (e) {
      throw AgentHostException(e.message, fatal: e.fatal);
    }
    final lines = <String>[];
    final ended = Completer<void>();
    final sub = channel.lines.listen(
      lines.add,
      onError: (Object _) {},
      onDone: ended.complete,
    );
    try {
      if (input != null) {
        // `send` adds the final newline itself.
        channel.send(input.endsWith('\n') ? input.substring(0, input.length - 1) : input);
        await channel.closeInput();
      }
      final int? code;
      try {
        code = await Future.wait<Object?>([ended.future, channel.exitCode])
            .then((r) => r[1] as int?)
            .timeout(timeout);
      } on TimeoutException {
        throw AgentHostException('The machine did not answer in time ($what).');
      }
      final out = _Output(lines, channel.stderrTail);
      if (code == _notInstalledExit) throw const _NotInstalled();
      if (code != 0) throw _failure(code, out.stderr, what);
      if (needsOutput && lines.isEmpty) {
        throw AgentHostException(
          'The machine answered nothing ($what).${_after(out.stderr)}',
        );
      }
      _present = true;
      return out;
    } finally {
      unawaited(sub.cancel());
      try {
        await channel.close().timeout(const Duration(seconds: 3));
      } on Object {
        // the connection is gone, so the channel is too
      }
    }
  }

  static String _after(String stderr) => stderr.isEmpty ? '' : ' ${_excerpt(stderr)}';

  static AgentHostException _unexpected(_Output out, String what) {
    final last = out.lines.isEmpty ? '' : _excerpt(out.lines.last, 120);
    return AgentHostException(
      'The machine answered something unexpected for $what${last.isEmpty ? '' : ': $last'}',
    );
  }

  /// The last line of [out] that is a JSON [T]. Earlier lines are ignored:
  /// a shell profile that prints a banner must not break the answer.
  static T _json<T>(_Output out, String what) {
    for (var i = out.lines.length - 1; i >= 0; i--) {
      try {
        final decoded = jsonDecode(out.lines[i]);
        if (decoded is T) return decoded;
      } on FormatException {
        continue;
      }
    }
    throw _unexpected(out, what);
  }
}

/// The last part of [text], which is where an error message is.
String _excerpt(String text, [int max = 400]) {
  final t = text.trim();
  return t.length <= max ? t : '…${t.substring(t.length - max)}';
}

/// The words for an exit status of a keeper command that did not succeed.
/// [code] is null when the connection dropped. Fatal where trying again
/// cannot help.
AgentHostException _failure(int? code, String stderr, String what) {
  final said = _excerpt(stderr);
  String or(String fallback) => said.isEmpty ? fallback : said;
  return switch (code) {
    null => const AgentHostException('The connection to the machine dropped.'),
    66 => AgentHostException(
        or('That folder or session does not exist on the machine.'),
        fatal: true,
      ),
    67 => AgentHostException(or('The agent of this session has exited.'), fatal: true),
    69 => AgentHostException(or('That agent is not installed on the machine.'), fatal: true),
    65 => AgentHostException(or('The agent helper is not installed on the machine.')),
    70 => AgentHostException(or('The agent exited while starting.')),
    78 => AgentHostException(or('Agent sessions need python3 on this machine.'), fatal: true),
    64 => AgentHostException(
        or('The app asked the machine something it did not understand.'),
        fatal: true,
      ),
    126 || 127 => AgentHostException(
        or('The machine could not run the command (command not found).'),
        fatal: true,
      ),
    _ => AgentHostException(or('Could not $what (exit status $code).')),
  };
}

/// The words for a keeper command that exited with [code] (null: the connection
/// dropped) after it was running: [stderr] is its last words, [what] says what
/// the person was doing ("follow the session").
AgentHostException keeperCommandFailure(int? code, String stderr, String what) =>
    _failure(code, stderr, what);

class _Output {
  const _Output(this.lines, this.stderr);

  final List<String> lines;
  final String stderr;
}

/// The [AcpTransport] of one attach: the keeper's stdout as [lines], [send]
/// to its stdin. [close] detaches (the keeper sees end of input); the agent
/// lives on.
///
/// When the attach ends with a failure (the keeper is unknown or its agent has
/// exited) [lines] reports an [AgentHostException] and then ends, and
/// [endReason] holds the same exception. A clean end (evicted by a newer
/// attach, the agent exited while attached, the connection dropped) has no
/// reason here: the keeper's own notifications and the connection state say
/// why.
class KeeperAttachment implements AcpTransport {
  KeeperAttachment._(this._channel) {
    _channel.lines.listen(
      _out.add,
      onError: _out.addError,
      onDone: _ended,
    );
  }

  final ExecChannel _channel;
  final _endReason = Completer<AgentHostException?>();

  // Synchronous, like the stream it forwards: see `splitLines`.
  late final StreamController<String> _out = StreamController<String>(
    sync: true,
    onCancel: close,
  );

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

/// Exit status of a keeper command when the script of this app version is not
/// on the host (`keeper_command.dart`).
const _notInstalledExit = 65;

/// Raised inside the host by a command that exited [_notInstalledExit]; never
/// leaves it.
class _NotInstalled implements Exception {
  const _NotInstalled();
}
