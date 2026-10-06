import 'dart:async';

import 'package:herdr_mobile/data/services/herdr_transport.dart';

/// An [ExecChannel] whose remote end the test plays: [emit] is the command
/// writing a line, [exit] is it ending, [sent] is what the app wrote to its
/// stdin.
class FakeExecChannel implements ExecChannel {
  FakeExecChannel();

  /// A command that prints [stdout] and exits with [code] (null: the link
  /// dropped) as soon as the channel exists.
  FakeExecChannel.run({
    List<String> stdout = const [],
    int? code = 0,
    String stderr = '',
  }) {
    stdout.forEach(emit);
    exit(code, stderr: stderr);
  }

  final _lines = StreamController<String>();
  final _exit = Completer<int?>();
  var _stderr = '';

  /// Lines the app sent, in order.
  final sent = <String>[];
  var closeCalls = 0;
  bool get ended => _exit.isCompleted;

  @override
  Stream<String> get lines => _lines.stream;

  @override
  void send(String line) {
    if (closeCalls > 0 || inputClosed) throw StateError('exec channel closed');
    if (!ended) sent.add(line);
  }

  /// Whether the app ended the command's input.
  var inputClosed = false;

  /// Runs when the app ends the command's input; a command that reads its
  /// input to the end answers here ([emit], [exit]).
  void Function()? onInputClosed;

  @override
  Future<void> closeInput() async {
    if (inputClosed) return;
    inputClosed = true;
    onInputClosed?.call();
  }

  @override
  Future<int?> get exitCode => _exit.future;

  @override
  String get stderrTail => _stderr;

  @override
  Future<void> close() async {
    closeCalls++;
    // Closing stdin ends a command that reads it to the end.
    exit(null);
  }

  void emit(String line) {
    if (!ended) _lines.add(line);
  }

  /// The command ends.
  void exit(int? code, {String stderr = ''}) {
    if (ended) return;
    if (stderr.isNotEmpty) _stderr = stderr;
    unawaited(_lines.close());
    _exit.complete(code);
  }
}
