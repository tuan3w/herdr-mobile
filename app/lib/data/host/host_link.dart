import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show RawZLibFilter;
import 'dart:typed_data';

import 'wire.dart';

// The app's end of `herdr-host serve`: one exec channel, many streams
// (rust/crates/wire and rust/crates/host/src/session.rs are the reference).
//
// Everything here runs where the SSH connection lives (the transport isolate).
// Frames are dispatched synchronously from the channel's stdout callback: see
// the note at the top of wire.dart on why the channel is never paused per frame.

/// What [HostLink] needs of the exec channel that runs `herdr-host serve`
/// (the members of `ExecSession`, so an SSH session satisfies both).
abstract interface class HostProcess {
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;
  StreamSink<Uint8List> get stdin;

  /// Completes when the channel is closed (errors if the connection died).
  Future<void> get done;

  /// The remote status; null when killed by a signal, or not known.
  int? get exitCode;

  void close();
}

/// A stream or call that ended in failure, as the host said it (the codes of
/// `wire::ErrorCode`) or as the link failed.
class HostException implements Exception {
  const HostException(this.code, this.message, {this.retryable = false});

  /// `not_found`, `permission`, `unavailable`, `changed`, … or, from this side,
  /// `link_lost`, `timeout`, `cancelled`, `bad_response`.
  final String code;
  final String message;

  /// Whether trying again later can work (the host decides; the link's own
  /// failures are retryable).
  final bool retryable;

  @override
  String toString() => '$code: $message';
}

/// The link to the host died: the connection dropped or `serve` exited.
class HostLinkLost extends HostException {
  const HostLinkLost(String message) : super('link_lost', message, retryable: true);
}

/// The agent helper is not on the host: the `serve` command exited 65. The
/// caller installs it (once) and starts again.
///
/// A [HostException] so that a stream opened before the host's HELLO (see
/// [HostLink.start]) ends with it as well: `code` is `helper_missing`, which is
/// what tells "not installed" from [HostLinkLost] ("the connection dropped").
class HostMissing extends HostException {
  const HostMissing(String message) : super('helper_missing', message);
}

/// One service's availability on the host, from the HELLO.
class HostService {
  const HostService({required this.available, this.reason, this.extra = const {}});

  final bool available;
  final String? reason;

  /// Service-specific facts (`socket`, `source`, …).
  final Map<String, Object?> extra;
}

class HostLimits {
  const HostLimits({required this.maxMsg, required this.maxData, required this.window, required this.maxStreams});

  final int maxMsg, maxData, window, maxStreams;
}

/// The host's HELLO: what it is, what it will accept, which services work.
class HostHello {
  const HostHello({
    required this.proto,
    required this.version,
    required this.os,
    required this.arch,
    required this.home,
    required this.hostname,
    required this.user,
    required this.limits,
    required this.services,
  });

  factory HostHello.fromJson(Map<String, Object?> json) {
    final host = (json['host']! as Map).cast<String, Object?>();
    final limits = (json['limits']! as Map).cast<String, Object?>();
    final services = (json['services']! as Map).cast<String, Object?>();
    return HostHello(
      proto: json['proto']! as int,
      version: host['version']! as String,
      os: host['os']! as String,
      arch: host['arch']! as String,
      home: host['home']! as String,
      hostname: host['hostname']! as String,
      user: host['user']! as String,
      limits: HostLimits(
        maxMsg: limits['max_msg']! as int,
        maxData: limits['max_data']! as int,
        window: limits['window']! as int,
        maxStreams: limits['max_streams']! as int,
      ),
      services: {
        for (final e in services.entries)
          e.key: HostService(
            available: (e.value! as Map)['available'] == true,
            reason: (e.value! as Map)['reason'] as String?,
            extra: {
              for (final f in (e.value! as Map).entries)
                if (f.key != 'available' && f.key != 'reason') f.key as String: f.value,
            },
          ),
      },
    );
  }

  final int proto;
  final String version, os, arch, home, hostname, user;
  final HostLimits limits;
  final Map<String, HostService> services;

  /// Whether [service] was working on the host when the link opened. A later
  /// `OPEN` checks again, so a service that starts afterwards still answers.
  bool has(String service) => services[service]?.available ?? false;
}

/// How a stream ended: [error] null is success, [result] the `END` payload.
class HostEnd {
  const HostEnd({this.error, this.result = const {}});

  final HostException? error;
  final Map<String, Object?> result;
}

/// One stream of a [HostLink].
///
/// Receiving: [texts]/[messages] deliver `MSG` frames and give the host credit
/// back as each is delivered; [read] pulls `DATA` and gives the credit back as
/// each chunk is taken, so a slow consumer slows the host. Sending: [send] and
/// [write] wait for the host's credit.
class HostStream {
  HostStream._(this._link, this.id, this._window, this._zctx) : _sendCredit = _window;

  final HostLink _link;
  final int id;
  int _window;

  /// The stream was opened with `zctx`: its frames, in both directions, are
  /// pieces of one zlib stream each.
  final bool _zctx;
  RawZLibFilter? _deflater;

  final _texts = StreamController<String>(sync: true);
  final _data = Queue<(Uint8List, int)>();
  final _readers = Queue<Completer<Uint8List?>>();
  final _end = Completer<HostEnd>();
  Inflater? _inflater;
  var _ended = false;
  var _consumed = 0;
  var _sendCredit = 0;
  // Sends that wait for the host's credit, in the order they were made: a small
  // send never overtakes a large one that is still waiting.
  final _pending = Queue<(Frame, Completer<void>?)>();

  /// The `MSG` payloads as text, in order. Single subscription, buffered until
  /// listened to. Errors with [HostException] when the stream ends in failure,
  /// then closes.
  Stream<String> get texts => _texts.stream;

  /// [texts], decoded as JSON.
  Stream<Object?> get messages => _texts.stream.map(jsonDecode);

  /// Completes when the stream is over; never errors (see [HostEnd.error]).
  Future<HostEnd> get done => _end.future;

  bool get isEnded => _ended;

  /// The next chunk of `DATA`, or null once the host ended the stream and
  /// everything it sent has been read.
  Future<Uint8List?> read() {
    if (_data.isNotEmpty) {
      final (bytes, wire) = _data.removeFirst();
      _consume(wire);
      return Future.value(bytes);
    }
    if (_ended) return Future.value();
    final c = Completer<Uint8List?>();
    _readers.add(c);
    return c.future;
  }

  /// Sends one `MSG` with [text] (JSON text) as its payload.
  Future<void> sendText(String text) => _sendFrame(FrameKind.msg, Uint8List.fromList(utf8.encode(text)));

  /// Sends [value] as one JSON `MSG`.
  Future<void> send(Object? value) => sendText(jsonEncode(value));

  /// Sends [bytes] as `DATA` frames of at most 32 KiB (16 KiB on a `zctx`
  /// stream, whose frames are compressed: see `StreamCtx::send_data` in the
  /// host). All of them are queued at once, so another send never lands between
  /// two of its frames; the future completes when the last one has gone out
  /// (after the host's credit allowed it).
  Future<void> write(Uint8List bytes) {
    if (_ended || _link._closed) return Future.error(const HostException('cancelled', 'the stream is closed'));
    final step = _zctx ? maxData ~/ 2 : maxData;
    Future<void> last = Future.value();
    for (var i = 0; i < bytes.length; i += step) {
      final end = i + step > bytes.length ? bytes.length : i + step;
      last = _sendFrame(FrameKind.data, Uint8List.sublistView(bytes, i, end), notify: end == bytes.length);
    }
    return last;
  }

  /// Ends our side: the host sees the client finished sending.
  void end([Object? result]) {
    if (_ended) return;
    _link._write(Frame.json(FrameKind.end, id, result ?? const {}));
  }

  /// Aborts both directions; nothing more is sent or delivered.
  void reset([String code = 'cancelled', String message = '']) {
    if (_ended) return;
    _link._write(Frame.json(FrameKind.reset, id, {'code': code, 'message': message, 'retryable': false}));
    _finish(HostEnd(error: HostException(code, message)), quiet: true);
  }

  /// Frames at least this long are compressed on a `zctx` stream.
  static const _ctxMin = 64;

  /// [payload] as the frame to send: a piece of the stream's zlib stream on a
  /// `zctx` stream (so a request that repeats the shape of the last one costs
  /// ~16 bytes instead of ~150), plain otherwise.
  Frame _pack(FrameKind kind, Uint8List payload) {
    if (!_zctx || payload.length < _ctxMin) return Frame(kind, id, payload);
    final filter = _deflater ??= RawZLibFilter.deflateFilter(level: 6);
    filter.process(payload, 0, payload.length);
    final out = BytesBuilder(copy: false);
    while (true) {
      final piece = filter.processed(flush: true);
      if (piece == null || piece.isEmpty) break;
      out.add(piece);
    }
    return Frame(kind, id, out.takeBytes(), flags: FrameFlags.deflateCtx);
  }

  Future<void> _sendFrame(FrameKind kind, Uint8List payload, {bool notify = true}) {
    if (_ended || _link._closed) return Future.error(const HostException('cancelled', 'the stream is closed'));
    // Packed when queued, and queued in the order they will be written: the
    // zlib stream's pieces must reach the host in the order they were made.
    final frame = _pack(kind, payload);
    if (_pending.isEmpty && _sendCredit >= frame.payload.length) {
      _sendCredit -= frame.payload.length;
      _link._write(frame);
      return Future.value();
    }
    final c = notify ? Completer<void>() : null;
    _pending.add((frame, c));
    return c?.future ?? Future.value();
  }

  void _onCredit(int n) {
    _sendCredit += n;
    while (_pending.isNotEmpty && _sendCredit >= _pending.first.$1.payload.length) {
      final (frame, c) = _pending.removeFirst();
      _sendCredit -= frame.payload.length;
      _link._write(frame);
      c?.complete();
    }
  }

  /// The host's HELLO named a window other than the one this stream was opened
  /// with (a stream opened before the HELLO assumes [HostLink.defaultWindow]):
  /// what we may still send moves by the difference, and the credit we give
  /// back follows the new size.
  void _setWindow(int window) {
    final delta = window - _window;
    if (delta == 0) return;
    _window = window;
    _onCredit(delta);
  }

  void _grant(int wire) {
    _consumed += wire;
    if (_consumed >= _window ~/ 2) {
      final n = _consumed;
      _consumed = 0;
      if (!_ended) _link._write(Frame.credit(id, n));
    }
  }

  void _consume(int wire) => _grant(wire);

  Uint8List _plain(Frame f) => switch (f.flags) {
    FrameFlags.none => f.payload,
    FrameFlags.deflate => Inflater.once(f.payload),
    FrameFlags.deflateCtx => (_inflater ??= Inflater()).inflate(f.payload),
  };

  void _onMsg(Frame f) {
    final String text;
    try {
      text = utf8.decode(_plain(f), allowMalformed: true);
    } on WireFormatException catch (e) {
      _protocolError(e.message);
      return;
    }
    _texts.add(text);
    _grant(f.payload.length);
  }

  void _onData(Frame f) {
    final Uint8List bytes;
    try {
      bytes = _plain(f);
    } on WireFormatException catch (e) {
      _protocolError(e.message);
      return;
    }
    if (_readers.isNotEmpty) {
      _readers.removeFirst().complete(bytes);
      _grant(f.payload.length);
    } else {
      _data.add((bytes, f.payload.length));
    }
  }

  void _onEnd(Frame f) {
    Map<String, Object?> body = const {};
    HostException? error;
    try {
      final decoded = jsonDecode(utf8.decode(_plain(f)));
      if (decoded is Map) {
        body = decoded.cast<String, Object?>();
        final e = body['error'];
        if (e is Map) {
          error = HostException(
            (e['code'] as String?) ?? 'internal',
            (e['message'] as String?) ?? '',
            retryable: e['retryable'] == true,
          );
        }
      }
    } on Object {
      error = const HostException('bad_response', 'the host ended a stream with something that is not JSON');
    }
    _finish(HostEnd(error: error, result: error == null ? body : const {}));
  }

  void _onReset(Frame f) {
    var error = const HostException('cancelled', 'the host reset the stream');
    try {
      final decoded = jsonDecode(utf8.decode(f.payload));
      if (decoded is Map) {
        error = HostException(
          (decoded['code'] as String?) ?? 'cancelled',
          (decoded['message'] as String?) ?? '',
          retryable: decoded['retryable'] == true,
        );
      }
    } on Object {
      // keep the default
    }
    _finish(HostEnd(error: error));
  }

  void _protocolError(String why) {
    _link._write(Frame.json(FrameKind.reset, id, {'code': 'bad_response', 'message': why, 'retryable': false}));
    _finish(HostEnd(error: HostException('bad_response', why)));
  }

  /// The link died under this stream, for [why].
  void _linkLost(HostException why) => _finish(HostEnd(error: why));

  void _finish(HostEnd end, {bool quiet = false}) {
    if (_ended) return;
    _ended = true;
    _link._streams.remove(id);
    for (final (_, c) in _pending) {
      c?.completeError(const HostException('cancelled', 'the stream is closed'));
    }
    _pending.clear();
    // What the host already sent can still be read; then readers see the end.
    for (final r in _readers) {
      r.complete(null);
    }
    _readers.clear();
    // A stream the client itself reset ends quietly: it asked for that. Any other
    // failure reaches whoever listens.
    if (end.error != null && !quiet) _texts.addError(end.error!);
    unawaited(_texts.close());
    if (!_end.isCompleted) _end.complete(end);
  }
}

/// One exec channel running `herdr-host serve`, shared by every feature of a
/// machine. See `docs/ARCHITECTURE.md` for what runs on it.
class HostLink {
  HostLink._(this._process, this._version, this._helloTimeout);

  final HostProcess _process;
  final String _version;
  final Duration _helloTimeout;
  final _decoder = FrameDecoder();
  final _streams = <int, HostStream>{};
  final _closedDone = Completer<void>();
  final _helloDone = Completer<HostHello>();
  final _stderr = BytesBuilder(copy: false);
  Timer? _helloTimer;
  var _nextId = 1;
  var _closed = false;
  HostHello? _hello;

  /// How much of `serve`'s stderr is kept for error messages.
  static const stderrTailBytes = 2048;

  /// The credit window a stream is opened with before the host's HELLO has
  /// said otherwise: what `serve` sends (`limits.window`).
  static const defaultWindow = 1 << 20;

  /// Starts `serve` on [process]: sends our HELLO and returns at once, without
  /// waiting for the host's. The link is usable straight away: [open] and
  /// [call] write their frames behind our HELLO, the host reads frames in order
  /// and answers each after its own HELLO, so the first request leaves one
  /// round trip earlier than with [connect].
  ///
  /// [helloFuture] completes with the host's HELLO. When the host never gets
  /// there it fails, and so does every stream opened meanwhile (with the same
  /// error, so a caller can tell the cases apart): [HostMissing] when the
  /// command exits 65 (the helper is not installed on the host), [HostLinkLost]
  /// when the connection drops first, [HostException] for a refusal, a
  /// protocol mismatch, a failed start or silence for [helloTimeout]. The link
  /// is closed by any of them.
  static HostLink start(
    HostProcess process, {
    required String version,
    String herdrSession = 'default',
    String? herdrSocket,
    Duration helloTimeout = const Duration(seconds: 10),
  }) {
    final link = HostLink._(process, version, helloTimeout);
    link._start(herdrSession, herdrSocket);
    return link;
  }

  /// [start], then waits for the host's HELLO: the link with [hello] known, for
  /// callers that decide by what the host offers. Throws what [helloFuture]
  /// fails with.
  static Future<HostLink> connect(
    HostProcess process, {
    required String version,
    String herdrSession = 'default',
    String? herdrSocket,
    Duration helloTimeout = const Duration(seconds: 10),
  }) async {
    final link = start(
      process,
      version: version,
      herdrSession: herdrSession,
      herdrSocket: herdrSocket,
      helloTimeout: helloTimeout,
    );
    await link.helloFuture;
    return link;
  }

  /// The host's HELLO, once it has come (see [helloFuture]).
  HostHello get hello => _hello ?? (throw StateError('the host has not said HELLO yet'));

  /// Completes with the host's HELLO; fails as described at [start].
  Future<HostHello> get helloFuture => _helloDone.future;

  bool get isOpen => !_closed;

  /// Completes when the link has ended, however it ended.
  Future<void> get closed => _closedDone.future;

  /// The last ~2 KB `serve` wrote to stderr.
  String get stderrTail {
    final all = _stderr.toBytes();
    final tail = all.length > stderrTailBytes ? Uint8List.sublistView(all, all.length - stderrTailBytes) : all;
    return utf8.decode(tail, allowMalformed: true).trim();
  }

  void _start(String herdrSession, String? herdrSocket) {
    // A caller that only opens streams never reads this; its failure reaches it
    // through the streams, so it must not also surface as an unhandled error.
    unawaited(_helloDone.future.then<void>((_) {}, onError: (Object _) {}));
    _helloTimer = Timer(
      _helloTimeout,
      () => _shutdown(
        const HostException('timeout', 'The machine did not start the agent helper in time.', retryable: true),
      ),
    );
    _process.stderr.listen((chunk) {
      _stderr.add(chunk);
      if (_stderr.length > stderrTailBytes * 2) {
        final all = _stderr.takeBytes();
        _stderr.add(Uint8List.sublistView(all, all.length - stderrTailBytes));
      }
    }, onError: (Object _) {});
    _process.stdout.listen(
      _onBytes,
      onError: (Object e) => _lost('the connection to the machine failed: $e'),
      onDone: () => _lost('the agent helper closed the channel'),
      cancelOnError: false,
    );
    _write(
      Frame.json(FrameKind.hello, 0, {
        'proto': 1,
        'client': {'name': 'herdr-mobile', 'version': _version},
        'herdr': {'session': herdrSession, 'socket': herdrSocket},
      }),
    );
  }

  void _onBytes(Uint8List chunk) {
    try {
      _decoder.add(chunk, _onFrame);
    } on WireFormatException catch (e) {
      _shutdown(HostException('bad_response', e.message));
    }
  }

  void _onFrame(Frame f) {
    if (!_helloDone.isCompleted) {
      _firstFrame(f);
      return;
    }
    final s = _streams[f.stream];
    if (s == null) return; // late frame of a stream that ended
    switch (f.kind) {
      case FrameKind.msg:
        s._onMsg(f);
      case FrameKind.data:
        s._onData(f);
      case FrameKind.credit:
        final n = f.creditBytes;
        if (n != null) s._onCredit(n);
      case FrameKind.end:
        s._onEnd(f);
      case FrameKind.reset:
        s._onReset(f);
      case FrameKind.hello || FrameKind.open:
        _shutdown(const HostException('bad_response', 'the host sent a frame only a client sends'));
    }
  }

  void _firstFrame(Frame f) {
    if (f.stream == 0 && f.kind == FrameKind.hello) {
      final HostHello hello;
      try {
        hello = HostHello.fromJson((jsonDecode(utf8.decode(f.payload)) as Map).cast<String, Object?>());
      } on Object catch (e) {
        _shutdown(HostException('bad_response', 'the host sent a HELLO this app cannot read: $e'));
        return;
      }
      _helloTimer?.cancel();
      _hello = hello;
      // Streams opened before this assumed the default window: a host that says
      // otherwise gets the difference applied to each.
      if (hello.limits.window != defaultWindow) {
        for (final s in _streams.values) {
          s._setWindow(hello.limits.window);
        }
      }
      _helloDone.complete(hello);
      return;
    }
    if (f.stream == 0 && f.kind == FrameKind.end) {
      HostException error = const HostException('bad_response', 'the host refused the connection');
      try {
        final e = (jsonDecode(utf8.decode(f.payload)) as Map)['error'];
        if (e is Map) {
          error = HostException(
            (e['code'] as String?) ?? 'internal',
            (e['message'] as String?) ?? '',
            retryable: e['retryable'] == true,
          );
        }
      } on Object {
        // keep the default
      }
      _shutdown(error);
      return;
    }
    _shutdown(const HostException('bad_response', 'the host did not start with a HELLO'));
  }

  /// stdout ended: the process is gone or the connection dropped.
  Future<void> _lost(String why) async {
    if (_closed) return;
    if (!_helloDone.isCompleted) {
      // Before the HELLO the exit status says why.
      try {
        await _process.done.timeout(const Duration(seconds: 2));
      } on Object {
        // no status then
      }
      if (_closed || _helloDone.isCompleted) return;
      final code = _process.exitCode;
      _shutdown(
        code == 65
            ? HostMissing(_stderrOr('the agent helper is not installed on this machine'))
            : code != null
            ? HostException('failed', _stderrOr('the agent helper exited with status $code'))
            : HostLinkLost(why),
      );
      return;
    }
    _shutdown(HostLinkLost(why));
  }

  String _stderrOr(String fallback) {
    final t = stderrTail;
    return t.isEmpty ? fallback : t;
  }

  /// Ends the link for [why]. Before the HELLO, [why] is what the HELLO and
  /// every stream opened so far fail with ([HostMissing] among them); after it,
  /// streams see the link as lost.
  void _shutdown(HostException why) {
    if (_closed) return;
    _closed = true;
    _helloTimer?.cancel();
    final streamsSee = _helloDone.isCompleted ? HostLinkLost(why.message) : why;
    for (final s in [..._streams.values]) {
      s._linkLost(streamsSee);
    }
    _streams.clear();
    try {
      _process.close();
    } on Object {
      // already gone
    }
    if (!_helloDone.isCompleted) _helloDone.completeError(why);
    if (!_closedDone.isCompleted) _closedDone.complete();
  }

  void _write(Frame f) {
    if (_closed) return;
    try {
      _process.stdin.add(encodeFrame(f));
    } on Object {
      // The channel is gone; stdout's end reports it.
    }
  }

  /// Opens a stream running `[service].[method]` with [args]. Allowed before the
  /// host's HELLO (see [start]): the OPEN is written at once.
  ///
  /// Throws [HostLinkLost] when the link is closed. With [zctx] the host
  /// compresses the stream's frames as one continuous zlib stream.
  HostStream open(String service, String method, [Map<String, Object?> args = const {}, bool zctx = false]) {
    if (_closed) throw const HostLinkLost('the link to the machine is closed');
    final id = _nextId;
    _nextId += 2;
    final s = HostStream._(this, id, _hello?.limits.window ?? defaultWindow, zctx);
    _streams[id] = s;
    _write(Frame.json(FrameKind.open, id, {'svc': service, 'method': method, 'args': args, 'zctx': zctx}));
    return s;
  }

  /// Runs a call: opens the stream, waits for its one result and its end, and
  /// returns that result (the first `MSG`, decoded; null when there was none).
  ///
  /// Throws [HostException] for the host's error, [HostLinkLost] when the link
  /// drops, and a retryable `timeout` after [timeout] (the stream is reset).
  Future<Object?> call(
    String service,
    String method, [
    Map<String, Object?> args = const {},
    Duration timeout = const Duration(seconds: 20),
  ]) async {
    final s = open(service, method, args);
    Object? first;
    var got = false;
    final sub = s.messages.listen((m) {
      if (!got) {
        first = m;
        got = true;
      }
    }, onError: (Object _) {});
    try {
      final end = await s.done.timeout(
        timeout,
        onTimeout: () {
          s.reset('timeout', '$service.$method did not answer in time');
          throw HostException('timeout', 'The machine did not answer $service.$method in time.', retryable: true);
        },
      );
      if (end.error != null) throw end.error!;
      return first;
    } finally {
      await sub.cancel();
    }
  }

  /// Ends every stream and the channel.
  Future<void> close() async {
    _shutdown(const HostException('cancelled', 'the link was closed'));
    await _closedDone.future;
  }
}
