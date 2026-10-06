import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'zipped_lines.dart';
import 'json_rpc.dart';

/// An [AcpTransport] over a local child process's stdio. For tests and
/// desktop tooling only: the app reaches agents over SSH, and `dart:io`
/// `Process` does not exist on the platform the app ships to.
class ProcessTransport implements AcpTransport {
  ProcessTransport._(this._process, {bool zipped = false}) {
    lines = zipped ? zippedLines(splitLines(_process.stdout)) : splitLines(_process.stdout);
    // An agent logs to stderr; an unread pipe would stall it. Keep a tail
    // for diagnostics.
    _process.stderr.transform(utf8.decoder).listen((chunk) {
      _stderr.write(chunk);
      if (_stderr.length > _stderrCap) {
        final text = _stderr.toString();
        _stderr
          ..clear()
          ..write(text.substring(text.length - _stderrCap));
      }
    });
    // A write to a dead child fails asynchronously on `done`; [send] reports
    // the synchronous case.
    _process.stdin.done.then<void>((_) {}, onError: (Object _) {});
  }

  /// Starts [executable] with [arguments]. The child's stdout becomes
  /// [lines], read as `keeper attach --z` lines with [zipped].
  static Future<ProcessTransport> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool zipped = false,
  }) async => ProcessTransport._(
    await Process.start(executable, arguments, workingDirectory: workingDirectory, environment: environment),
    zipped: zipped,
  );

  static const _stderrCap = 16 * 1024;

  final Process _process;
  final _stderr = StringBuffer();
  var _closed = false;

  @override
  late final Stream<String> lines;

  /// The last 16 KiB the child wrote to stderr.
  String get stderrTail => _stderr.toString();

  /// The child's exit code; completes when it ends (also after [close]).
  Future<int> get exitCode => _process.exitCode;

  @override
  void send(String line) {
    if (_closed) throw StateError('transport is closed');
    _process.stdin.add(utf8.encode('$line\n'));
  }

  /// Closes the child's stdin (an ACP agent exits on EOF), gives it
  /// [grace] to exit, then terminates it.
  @override
  Future<void> close({Duration grace = const Duration(seconds: 3)}) async {
    if (_closed) return;
    _closed = true;
    try {
      await _process.stdin.close();
    } on Object {
      // The child is gone already.
    }
    try {
      await _process.exitCode.timeout(grace);
    } on TimeoutException {
      _process.kill();
      try {
        await _process.exitCode.timeout(grace);
      } on TimeoutException {
        _process.kill(ProcessSignal.sigkill);
      }
    }
  }
}
