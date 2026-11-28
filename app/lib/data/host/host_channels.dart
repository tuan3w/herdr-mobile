import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../acp/json_rpc.dart' show splitLines;
import '../services/herdr_transport.dart';
import '../services/mux_client.dart';
import 'host_link.dart';

/// [MuxChannel] over a `herdr.mux` stream of a [HostLink]: each `MSG` is one
/// response object (JSON text), each request is one `MSG` the client sends.
///
/// The host sends `{"ready":true}` first once herdr's socket is there; a
/// stream that ends with `unavailable` instead is a host that cannot serve the
/// mux right now, which [MuxClient] reports as [MuxUnavailable] (and the
/// transport then uses the bridge for a while).
class HostMuxChannel implements MuxChannel {
  HostMuxChannel(this._stream);

  final HostStream _stream;

  @override
  late final Stream<String> lines = _stream.texts.transform(
    StreamTransformer<String, String>.fromHandlers(
      handleError: (error, stack, sink) {
        if (error is HostMissing) {
          sink.addError(MuxUnavailable(error.message, helperMissing: true));
        } else if (error is HostException && error is! HostLinkLost && error.code != 'cancelled') {
          // The host says why it cannot serve the mux (no herdr socket, a failed
          // or refused start): not a dropped link, so the caller may use the
          // bridge. A dropped link ([HostLinkLost]) passes through unchanged.
          sink.addError(MuxUnavailable(error.message));
        } else {
          sink.addError(error, stack);
        }
      },
    ),
  );

  @override
  void send(String line) {
    // The stream's end reports a failure; a request that cannot go out times
    // out like any other the host never answers.
    unawaited(_stream.sendText(line).catchError((Object _) {}));
  }

  @override
  Future<void> close() async => _stream.reset();

  @override
  late final Future<int?> exitCode = _stream.done.then((end) {
    final e = end.error;
    if (e == null) return 0;
    if (e is HostLinkLost) return null;
    return e.code == 'unavailable' ? 78 : 1;
  });
}

/// The exit status a command-shaped consumer (`SshAgentHost`'s failure words,
/// which grew up on the keeper's exit codes) reads from how a stream ended: 0
/// for success, the keeper's status for the error codes it maps to, 65 for a
/// helper that is not available, null when the link dropped or the stream was
/// cancelled.
int? exitStatusOf(HostEnd end) {
  final e = end.error;
  if (e == null) return 0;
  if (e is HostLinkLost || e.code == 'cancelled') return null;
  return switch (e.code) {
    'bad_request' => 64,
    'unavailable' || 'helper_missing' => 65,
    'not_found' => 66,
    'agent_exited' => 67,
    'agent_missing' => 69,
    'failed' => 70,
    _ => 1,
  };
}

/// [ExecChannel] over a host stream whose data is lines of text: a keeper
/// attach (`keeper.attach`), a log follow (`keeper.follow`), a blob read.
/// `DATA` frames are the bytes the old command wrote to stdout and read from
/// stdin; the stream's end is the command's exit ([exitCode]).
///
/// The host's credit goes back as chunks are read, and chunks are read only
/// while [lines] has an unpaused listener, so a consumer that stops reading
/// slows the host instead of filling this isolate's memory.
class HostLineChannel implements ExecChannel {
  HostLineChannel(this._stream) {
    _stream.done.then((end) {
      _tail = end.error?.message ?? '';
      _exit.complete(exitStatusOf(end));
    });
  }

  final HostStream _stream;
  final _exit = Completer<int?>();
  var _tail = '';
  var _closed = false;
  var _inputClosed = false;
  Completer<void>? _resume;

  late final StreamController<Uint8List> _bytes = StreamController<Uint8List>(
    sync: true,
    onListen: () => unawaited(_pump()),
    onResume: () => _resume?.complete(),
    onCancel: () => _stream.reset(),
  );

  Future<void> _pump() async {
    while (!_bytes.isClosed) {
      while (_bytes.isPaused && !_bytes.isClosed) {
        final r = _resume = Completer<void>();
        await r.future;
      }
      final chunk = await _stream.read();
      if (chunk == null) break;
      if (_bytes.isClosed) return;
      _bytes.add(chunk);
    }
    await _stream.done;
    if (!_bytes.isClosed) unawaited(_bytes.close());
  }

  // Synchronous splitting, never `await for`: see [splitLines].
  @override
  late final Stream<String> lines = splitLines(_bytes.stream);

  @override
  void send(String line) {
    if (_closed || _inputClosed) throw StateError('exec channel closed');
    if (_stream.isEnded) return;
    unawaited(_stream.write(Uint8List.fromList(utf8.encode('$line\n'))).catchError((Object _) {}));
  }

  @override
  Future<void> closeInput() async {
    if (_inputClosed) return;
    _inputClosed = true;
    _stream.end();
  }

  @override
  Future<int?> get exitCode => _exit.future;

  @override
  String get stderrTail => _tail;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _stream.reset();
    await _stream.done;
  }
}
