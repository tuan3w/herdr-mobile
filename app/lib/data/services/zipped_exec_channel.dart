import 'dart:async';

import '../acp/zipped_lines.dart';
import 'herdr_transport.dart';

/// [inner] with its lines read back from `keeper attach --z`: plain lines pass
/// and `Z` lines inflate (see [zippedLines]). Everything else is [inner]'s.
///
/// Built where the channel is opened (the transport's worker isolate), so the
/// base64 and inflate work of a replay is not done on the UI isolate.
///
/// A piece that does not inflate ends the lines with a [CorruptZippedLines]
/// error, and the channel is closed: the command would otherwise run on, and
/// whoever waits for its exit status would wait for ever. The caller sees the
/// connection drop and attaches again.
class ZippedExecChannel implements ExecChannel {
  ZippedExecChannel(this._inner) {
    lines = zippedLines(_inner.lines).transform(
      StreamTransformer<String, String>.fromHandlers(
        handleError: (error, stack, sink) {
          sink.addError(error, stack);
          if (error is CorruptZippedLines) unawaited(_inner.close());
        },
      ),
    );
  }

  final ExecChannel _inner;

  @override
  late final Stream<String> lines;

  @override
  void send(String line) => _inner.send(line);

  @override
  Future<void> closeInput() => _inner.closeInput();

  @override
  Future<int?> get exitCode => _inner.exitCode;

  @override
  String get stderrTail => _inner.stderrTail;

  @override
  Future<void> close() => _inner.close();
}
