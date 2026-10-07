import 'dart:async';

import '../acp/agent_host.dart' show AgentHostException;
import '../observed/observed_contracts.dart';
import 'herdr_transport.dart';
import 'keeper_command.dart';
import 'ssh_agent_host.dart';

/// Most lines of one [LogBatch]: a burst longer than this is several batches,
/// so the consumer never gets more than a small slice of work at once.
const _maxBatchLines = 512;

/// [SessionLogSource] over the machine's SSH connection: one exec channel that
/// runs the host helper's `follow` (`keeperFollowCommand`, which also says what
/// the records look like). [SshAgentHost] opens it, so a host that does not
/// have the helper yet gets it installed and the command repeated.
///
/// Failures reach the stream as errors, then it ends:
/// - [HerdrTransportException] (retryable): the link dropped or the channel
///   could not be opened;
/// - [AgentHostException]: the host cannot do it (no python3, the file is not
///   readable or not a log inside the home folder, reading failed, the helper
///   could not be installed); `fatal` says whether trying again can help.
class SshLogSource implements SessionLogSource {
  SshLogSource(this._host);

  final SshAgentHost _host;

  /// [tailBytes] widens the first read (the host's default is 192 KB, at most
  /// 8 MB): "load earlier" follows again with a bigger one and starts over.
  @override
  Stream<LogBatch> follow(String path, {int? from, int? tailBytes}) =>
      _Follow(_host, path, from, tailBytes).stream;
}

class _Follow {
  _Follow(this._host, this._path, this._from, this._tailBytes) {
    _out = StreamController<LogBatch>(
      onListen: _start,
      onPause: () => _sub?.pause(),
      onResume: () => _sub?.resume(),
      onCancel: _stop,
    );
  }

  final SshAgentHost _host;
  final String _path;
  final int? _from;
  final int? _tailBytes;
  late final StreamController<LogBatch> _out;

  Stream<LogBatch> get stream => _out.stream;

  ExecChannel? _channel;
  StreamSubscription<String>? _sub;
  var _stopped = false;
  var _finished = false;
  var _rechecked = false;

  // A batch (lines, a reset or the caught-up note) has gone to the listener:
  // the channel works, so the helper is there, and a later caught-up note adds
  // nothing.
  var _delivered = false;

  // Lines that arrived in this turn of the event loop, not yet handed on.
  var _pending = <String>[];
  var _end = 0;
  var _flushScheduled = false;

  void _start() {
    final String command;
    try {
      command = keeperFollowCommand(_path, from: _from, tailBytes: _tailBytes, zipped: true);
    } on ArgumentError {
      _fail(const AgentHostException('That session log has a name the app cannot use.', fatal: true));
      return;
    }
    unawaited(_open(command, missing: false));
  }

  Future<void> _open(String command, {required bool missing}) async {
    final ExecChannel channel;
    try {
      channel = await _host.openKeeperChannel(command, missing: missing, verify: false, zipped: true);
    } on AgentHostException catch (e) {
      // A link problem or a half-finished install is worth another try; a host
      // that cannot do it at all is not.
      _fail(e.fatal ? e : HerdrTransportException(e.message));
      return;
    } on HerdrTransportException catch (e) {
      _fail(e);
      return;
    }
    if (_stopped || _finished) {
      _closeChannel(channel);
      return;
    }
    _channel = channel;
    final sub = _sub = channel.lines.listen(
      _onLine,
      onError: (Object e) => _fail(
        e is HerdrTransportException ? e : const HerdrTransportException('The connection to the machine dropped.'),
      ),
      onDone: () => unawaited(_ended(command, channel)),
    );
    if (_out.isPaused) sub.pause();
  }

  void _onLine(String line) {
    if (_finished) return;
    final tab = line.indexOf('\t');
    if (tab < 1) return; // banner of a login shell, not ours
    if (tab == 1 && line.codeUnitAt(0) == 0x52) {
      // R: the file shrank or was replaced; what follows is its new content.
      final offset = int.tryParse(line.substring(2));
      if (offset == null) return;
      _flush();
      _end = offset;
      _delivered = true;
      _out.add(LogBatch(const [], offset, reset: true));
      return;
    }
    if (tab == 1 && line.codeUnitAt(0) == 0x43) {
      // C: the helper sent everything the file held. With nothing delivered
      // yet (an empty log, a resume at its end) this is the only word the
      // session gets, and it is up to date now instead of after a quiet wait.
      final offset = int.tryParse(line.substring(2));
      if (offset == null) return;
      _flush();
      if (!_delivered) {
        _delivered = true;
        _out.add(LogBatch(const [], offset));
      }
      return;
    }
    if (tab == 1 && line.codeUnitAt(0) == 0x45) {
      // E: the follower met something it cannot go on from, and exits.
      _flush();
      _fail(AgentHostException(
        line.length > 2 ? line.substring(2) : 'The machine could not read the session log.',
      ));
      return;
    }
    final offset = int.tryParse(line.substring(0, tab));
    if (offset == null) return;
    _pending.add(line.substring(tab + 1));
    _end = offset;
    if (_pending.length >= _maxBatchLines) {
      _flush();
    } else if (!_flushScheduled) {
      _flushScheduled = true;
      // One event-loop turn, not a microtask: lines a transport hands over one
      // event at a time still make one batch.
      Timer.run(_flush);
    }
  }

  void _flush() {
    _flushScheduled = false;
    if (_pending.isEmpty || _finished) return;
    final lines = _pending;
    _pending = <String>[];
    _delivered = true;
    _out.add(LogBatch(lines, _end));
  }

  Future<void> _ended(String command, ExecChannel channel) async {
    if (_finished || _stopped) return;
    _flush();
    int? code;
    try {
      code = await channel.exitCode;
    } on Object {
      // no status: the connection dropped
    }
    if (_finished || _stopped) return;
    _flush();
    if (code == 0) {
      _finish();
    } else if (code == 65 && !_delivered && !_rechecked) {
      _rechecked = true;
      // The helper vanished from the host after it had been seen: install again.
      _closeChannel(channel);
      _channel = null;
      await _open(command, missing: true);
    } else if (code == null) {
      _fail(const HerdrTransportException('The connection to the machine dropped.'));
    } else {
      _fail(keeperCommandFailure(code, channel.stderrTail, 'follow the session'));
    }
  }

  void _fail(Object error) {
    if (_finished || _stopped) return;
    _flush();
    _finished = true;
    _out.addError(error);
    unawaited(_out.close());
    _release();
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    unawaited(_out.close());
    _release();
  }

  Future<void> _stop() async {
    _stopped = true;
    _release();
  }

  void _release() {
    final sub = _sub;
    final channel = _channel;
    _sub = null;
    _channel = null;
    if (sub != null) unawaited(sub.cancel());
    if (channel != null) _closeChannel(channel);
  }

  static void _closeChannel(ExecChannel channel) {
    unawaited(channel.close().catchError((Object _) {}));
  }
}
