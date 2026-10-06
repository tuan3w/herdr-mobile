import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../models/remote_file.dart';
import 'herdr_transport.dart';

/// Builds the real transport inside the worker isolate.
///
/// Must be a top-level or static function (closures cannot cross an isolate
/// boundary) and what [IsolateTransport.config] returns must be sendable.
/// [onPin] reports a host key trusted
/// on first use back to the main isolate; [onNotice] forwards login banners.
typedef TransportBuilder = HerdrTransport Function(
  Object? config,
  void Function(String fingerprint) onPin,
  void Function(String banner) onNotice,
);

/// Runs a [HerdrTransport] in its own isolate so the work it does (SSH
/// encryption, decompression, JSON decoding) can never block the UI thread.
///
/// dartssh2 encrypts in pure Dart. Even with a fast cipher a busy pane means
/// ~140 KB of ciphertext several times a second, and on a mid-range phone that
/// work ran between frames and made touch input stutter.
///
/// The worker starts on first use and is replaced if it ever dies. A request
/// in flight when it dies fails with a retryable [HerdrTransportException].
class IsolateTransport implements HerdrTransport {
  IsolateTransport({
    required this.builder,
    required this.config,
    required this.onPin,
    this.onNotice,
  });

  final TransportBuilder builder;

  /// What the worker is built from. Asked for each time a worker starts (the
  /// first request, and again after one died or a start failed), so it can
  /// wait for something the app does not have yet, such as the keychain's
  /// answer, without the connection having to wait for it to exist.
  final FutureOr<Object?> Function() config;
  final void Function(String fingerprint) onPin;

  /// Receives text the server shows before login (an SSH banner), such as a
  /// sign-in link to approve in a browser.
  final void Function(String banner)? onNotice;

  /// Sees every message from the worker before it is handled. Tests use it to
  /// check what crosses the isolate boundary.
  static void Function(List<Object?> message)? debugOnMessage;

  Future<_Worker>? _worker;
  _Worker? _live;
  var _closed = false;
  // Whether the app is in the background; handed to every worker that starts.
  var _background = false;

  Future<_Worker> _ensure() {
    if (_closed) {
      return Future.error(const HerdrTransportException('Transport closed'));
    }
    // Do not hand out a worker that has died but whose `gone` callback has not
    // run yet: the request would fail for no reason.
    if (_live case final live? when live.isDead) {
      _live = null;
      _worker = null;
    }
    return _worker ??= _start();
  }

  Future<_Worker> _start() async {
    try {
      final worker = await _Worker.spawn(
        builder,
        await config(),
        onPin,
        onNotice ?? (_) {},
      );
      _live = worker;
      if (_background) worker.post(const ['bg', true]);
      // A dead worker is replaced by the next call.
      unawaited(worker.gone.then((_) {
        if (identical(_live, worker)) {
          _live = null;
          _worker = null;
        }
      }));
      return worker;
    } on Object {
      _worker = null;
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async => (await _ensure()).request(method, params);

  @override
  bool get supportsFiles => true;

  @override
  Future<RemoteStat> statFile(String path) async =>
      RemoteStat.fromJson(await _op('stat', [path]) as Map);

  @override
  Future<List<RemoteEntry>> listDirectory(String path) async => [
        for (final e in await _op('list', [path]) as List) RemoteEntry.fromJson(e as Map),
      ];

  @override
  Future<Uint8List> readFile(String path, {int offset = 0, int length = remoteReadCap}) async {
    final bytes = await _op('read', [path, offset, length.clamp(0, remoteReadCap)]);
    // Moved, not copied: the worker handed over ownership of the buffer.
    return (bytes! as TransferableTypedData).materialize().asUint8List();
  }

  @override
  Future<String> realPath(String path) async => await _op('real', [path]) as String;

  @override
  Future<void> makeDirs(String path) async {
    await _op('mkdirs', [path]);
  }

  @override
  Future<void> removeFile(String path) async {
    await _op('rm', [path]);
  }

  @override
  UploadJob uploadFile({
    required String localPath,
    required String remotePath,
    void Function(int sent, int total)? onProgress,
  }) {
    final job = _MainUpload(onProgress);
    _ensure().then(
      (worker) => worker.startUpload(job, localPath, remotePath),
      onError: (Object e) => job.fail(e),
    );
    return job;
  }

  /// How many progress messages the main isolate has received from the
  /// current worker (uploads send counters, never bytes). For tests.
  int get uploadProgressMessages => _live?.uploadProgress ?? 0;

  @override
  Future<ExecChannel> openExec(String command) async => (await _ensure()).openExec(command);

  /// How many batches of exec lines the main isolate has received from the
  /// current worker: lines cross the boundary in batches, never one message
  /// each. For tests and diagnostics.
  int get execBatchesReceived => _live?.execBatches ?? 0;

  Future<Object?> _op(String name, List<Object?> args) async =>
      (await _ensure()).op(name, args);

  @override
  Stream<Map<String, dynamic>> events(List<Map<String, dynamic>> subscriptions) {
    var cancelled = false;
    void Function()? cancel;
    late final StreamController<Map<String, dynamic>> out;
    out = StreamController<Map<String, dynamic>>(
      onListen: () async {
        try {
          final worker = await _ensure();
          if (cancelled) return;
          cancel = worker.subscribe(subscriptions, out);
        } on Object catch (e) {
          if (cancelled) return;
          out.addError(e);
          await out.close();
        }
      },
      onCancel: () {
        cancelled = true;
        cancel?.call();
      },
    );
    return out.stream;
  }

  @override
  void setBackground(bool background) {
    if (background == _background) return;
    _background = background;
    // A worker that is not up yet (or was replaced) learns it when it starts.
    _live?.post(['bg', background]);
  }

  @override
  void reset() {
    final worker = _worker;
    if (worker == null) return;
    worker.then((w) => w.post(const ['reset']), onError: (Object _) {});
  }

  @override
  Future<void> close() async {
    _closed = true;
    final worker = _worker;
    _worker = null;
    if (worker == null) return;
    try {
      await (await worker).close();
    } on Object {
      // never started
    }
  }
}

/// The main-isolate end of one worker.
class _Worker {
  _Worker._(this._isolate, this._to, this._from, this._exit, this._onPin, this._onNotice);

  static Future<_Worker> spawn(
    TransportBuilder builder,
    Object? config,
    void Function(String) onPin,
    void Function(String) onNotice,
  ) async {
    final from = ReceivePort();
    final exit = ReceivePort();
    final handshake = Completer<SendPort>();
    final worker = Completer<_Worker>();
    late final StreamSubscription<Object?> sub;
    sub = from.listen((Object? message) {
      if (!handshake.isCompleted) {
        if (message is SendPort) {
          handshake.complete(message);
        } else if (message is List && message.first == 'fatal') {
          handshake.completeError(HerdrTransportException(
            message[1] as String,
            fatal: true,
          ));
        }
        return;
      }
      worker.future.then((w) => w._onMessage(message as List<Object?>));
    });
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn<List<Object?>>(
        _workerMain,
        [from.sendPort, builder, config],
        onExit: exit.sendPort,
        debugName: 'herdr-transport',
      );
    } on Object catch (e) {
      await sub.cancel();
      from.close();
      exit.close();
      throw HerdrTransportException('Cannot start network worker: $e');
    }
    final SendPort to;
    try {
      to = await handshake.future;
    } on Object {
      isolate.kill(priority: Isolate.immediate);
      await sub.cancel();
      from.close();
      exit.close();
      rethrow;
    }
    final w = _Worker._(isolate, to, from, exit, onPin, onNotice);
    worker.complete(w);
    exit.listen((_) => w._gone());
    return w;
  }

  final Isolate _isolate;
  final SendPort _to;
  final ReceivePort _from;
  final ReceivePort _exit;
  final void Function(String) _onPin;
  final void Function(String) _onNotice;

  final _requests = <int, Completer<Map<String, dynamic>>>{};
  final _streams = <int, StreamController<Map<String, dynamic>>>{};
  final _ops = <int, Completer<Object?>>{};
  final _execs = <int, _MainExec>{};
  final _opens = <int, Completer<ExecChannel>>{};
  final _uploads = <int, _MainUpload>{};
  var uploadProgress = 0;
  var execBatches = 0;
  final _gone$ = Completer<void>();
  Completer<void>? _closedAck;
  var _nextId = 0;
  var _dead = false;

  /// Completes when the isolate has exited, for any reason.
  Future<void> get gone => _gone$.future;

  bool get isDead => _dead;

  void post(List<Object?> message) {
    if (!_dead) _to.send(message);
  }

  Future<Map<String, dynamic>> request(String method, Map<String, dynamic> params) {
    if (_dead) {
      return Future.error(const HerdrTransportException('herdr connection lost'));
    }
    final id = _nextId++;
    final reply = _requests[id] = Completer<Map<String, dynamic>>();
    _to.send(['req', id, method, params]);
    return reply.future;
  }

  /// A file operation in the worker. The reply is a JSON-like value, or a
  /// [TransferableTypedData] for bytes.
  Future<Object?> op(String name, List<Object?> args) {
    if (_dead) {
      return Future.error(const HerdrTransportException('herdr connection lost'));
    }
    final id = _nextId++;
    final reply = _ops[id] = Completer<Object?>();
    _to.send(['op', id, name, args]);
    return reply.future;
  }

  /// Starts [job]'s upload in the worker. Only paths go up and counters come
  /// back; the file is read and sent on the other side.
  void startUpload(_MainUpload job, String localPath, String remotePath) {
    if (_dead) {
      job.fail(const HerdrTransportException('herdr connection lost'));
      return;
    }
    if (job.cancelled) return;
    final id = _nextId++;
    _uploads[id] = job;
    job.bind(() {
      if (_uploads.remove(id) != null) post(['upcancel', id]);
    });
    _to.send(['up', id, localPath, remotePath]);
  }

  /// Forwards the worker's events into [out]; returns the cancel callback.
  void Function() subscribe(
    List<Map<String, dynamic>> subscriptions,
    StreamController<Map<String, dynamic>> out,
  ) {
    if (_dead) {
      out
        ..addError(const HerdrTransportException('herdr connection lost'))
        ..close();
      return () {};
    }
    final id = _nextId++;
    _streams[id] = out;
    _to.send(['sub', id, subscriptions]);
    return () {
      if (_streams.remove(id) != null) post(['cancel', id]);
    };
  }

  /// Opens [command] in the worker. The channel is registered before the
  /// worker answers, so lines that follow the answer in the same turn are not
  /// lost; they wait in the channel until its stream is listened to.
  Future<ExecChannel> openExec(String command) {
    if (_dead) {
      return Future.error(const HerdrTransportException('herdr connection lost'));
    }
    final id = _nextId++;
    _execs[id] = _MainExec(this, id);
    final opened = _opens[id] = Completer<ExecChannel>();
    _to.send(['exec', id, command]);
    return opened.future;
  }

  void _onMessage(List<Object?> m) {
    IsolateTransport.debugOnMessage?.call(m);
    switch (m[0]) {
      case 'res':
        _requests.remove(m[1] as int)?.complete(m[2]! as Map<String, dynamic>);
      case 'err':
        _requests.remove(m[1] as int)?.completeError(_decodeError(m));
      case 'ores':
        _ops.remove(m[1] as int)?.complete(m[2]);
      case 'oerr':
        _ops.remove(m[1] as int)?.completeError(_decodeOpError(m));
      case 'evt':
        _streams[m[1] as int]?.add(m[2]! as Map<String, dynamic>);
      case 'evtErr':
        final out = _streams.remove(m[1] as int);
        if (out != null) {
          out.addError(_decodeError(m));
          out.close();
        }
      case 'evtDone':
        _streams.remove(m[1] as int)?.close();
      case 'xopen':
        _opens.remove(m[1] as int)?.complete(_execs[m[1] as int]);
      case 'xopenErr':
        _execs.remove(m[1] as int);
        _opens.remove(m[1] as int)?.completeError(_decodeError(m));
      case 'xlines':
        execBatches++;
        _execs[m[1] as int]?.addLines((m[2]! as List).cast<String>());
      case 'uprog':
        uploadProgress++;
        _uploads[m[1] as int]?.progress(m[2]! as int, m[3]! as int);
      case 'udone':
        _uploads.remove(m[1] as int)?.finish();
      case 'uerr':
        _uploads.remove(m[1] as int)?.fail(_decodeOpError(m));
      case 'xwarn':
        _execs[m[1] as int]?.warn(m[2]! as String);
      case 'xend':
        _execs[m[1] as int]?.end(m[2] as int?, m[3]! as String);
      case 'pin':
        _onPin(m[1]! as String);
      case 'notice':
        _onNotice(m[1]! as String);
      case 'closed':
        _closedAck?.complete();
    }
  }

  /// `['err', id, kind, a, b]`: api -> (code, message), else (message, fatal).
  Object _decodeError(List<Object?> m) => m[2] == 'api'
      ? HerdrApiException(m[3]! as String, m[4]! as String)
      : HerdrTransportException(m[3]! as String, fatal: m[4] == true);

  /// `['oerr', id, 'file', kind, message, fatal, path]`, or the shapes of
  /// [_decodeError] after the id.
  Object _decodeOpError(List<Object?> m) => m[2] == 'file'
      ? RemoteFileException(
          RemoteFileErrorKind.parse(m[3] as String?),
          m[4]! as String,
          fatal: m[5] == true,
          path: m[6] as String?,
        )
      : _decodeError(m);

  void _gone({bool graceful = false}) {
    if (_dead) return;
    _dead = true;
    const lost = HerdrTransportException('herdr connection lost');
    for (final reply in _requests.values.toList()) {
      reply.completeError(lost);
    }
    for (final reply in _ops.values.toList()) {
      reply.completeError(lost);
    }
    _ops.clear();
    _requests.clear();
    for (final out in _streams.values.toList()) {
      out
        ..addError(lost)
        ..close();
    }
    _streams.clear();
    for (final open in _opens.values.toList()) {
      open.completeError(lost);
    }
    _opens.clear();
    for (final upload in _uploads.values.toList()) {
      upload.fail(lost);
    }
    _uploads.clear();
    // A channel that the transport's own close() left open ends quietly; one
    // whose worker died ends with the retryable error.
    for (final exec in _execs.values.toList()) {
      exec.end(null, exec.stderrTail, error: graceful ? null : lost);
    }
    _execs.clear();
    _from.close();
    _exit.close();
    _gone$.complete();
  }

  Future<void> close() async {
    if (_dead) return;
    final ack = _closedAck = Completer<void>();
    _to.send(const ['close']);
    await ack.future.timeout(const Duration(seconds: 1), onTimeout: () {});
    _isolate.kill(priority: Isolate.immediate);
    _gone(graceful: true);
  }
}

/// Worker entry point. [init] is `[SendPort main, TransportBuilder, config]`.
void _workerMain(List<Object?> init) {
  final main = init[0]! as SendPort;
  final builder = init[1]! as TransportBuilder;
  final commands = ReceivePort();

  final HerdrTransport transport;
  try {
    transport = builder(
      init[2],
      (fp) => main.send(['pin', fp]),
      (banner) => main.send(['notice', banner]),
    );
  } on Object catch (e) {
    main.send(['fatal', '$e']);
    commands.close();
    return;
  }
  main.send(commands.sendPort);

  final subscriptions = <int, StreamSubscription<Map<String, dynamic>>>{};
  final execs = <int, _WorkerExec>{};
  final uploads = <int, UploadJob>{};
  var closing = false;

  Future<void> serve(int id, String method, Map<String, dynamic> params) async {
    try {
      main.send(['res', id, await transport.request(method, params)]);
    } on Object catch (e) {
      main.send(['err', id, ..._encodeError(e)]);
    }
  }

  Future<void> serveExec(int id, String command) async {
    final ExecChannel channel;
    try {
      if (closing) throw const HerdrTransportException('Transport closed');
      channel = await transport.openExec(command);
    } on Object catch (e) {
      main.send(['xopenErr', id, ..._encodeError(e)]);
      return;
    }
    final exec = execs[id] = _WorkerExec(id, channel, main, () => execs.remove(id));
    main.send(['xopen', id]);
    exec.start();
    if (closing) unawaited(exec.close());
  }

  void serveUpload(int id, String localPath, String remotePath) {
    if (closing) {
      main.send(['uerr', id, ..._encodeError(const HerdrTransportException('Transport closed'))]);
      return;
    }
    final UploadJob job;
    try {
      job = transport.uploadFile(
        localPath: localPath,
        remotePath: remotePath,
        onProgress: (sent, total) => main.send(['uprog', id, sent, total]),
      );
    } on Object catch (e) {
      main.send(['uerr', id, ..._encodeOpError(e)]);
      return;
    }
    uploads[id] = job;
    job.done.then((_) {
      if (uploads.remove(id) != null) main.send(['udone', id]);
    }, onError: (Object e) {
      if (uploads.remove(id) != null) main.send(['uerr', id, ..._encodeOpError(e)]);
    });
  }

  Future<void> serveOp(int id, String name, List<Object?> args) async {
    try {
      final Object out = switch (name) {
        'stat' => (await transport.statFile(args[0]! as String)).toJson(),
        'list' => [
            for (final e in await transport.listDirectory(args[0]! as String)) e.toJson(),
          ],
        'read' => TransferableTypedData.fromList([
            await transport.readFile(
              args[0]! as String,
              offset: args[1]! as int,
              length: args[2]! as int,
            ),
          ]),
        'real' => await transport.realPath(args[0]! as String),
        'mkdirs' => await transport.makeDirs(args[0]! as String).then((_) => true),
        'rm' => await transport.removeFile(args[0]! as String).then((_) => true),
        _ => throw HerdrTransportException('Unknown file operation $name'),
      };
      main.send(['ores', id, out]);
    } on Object catch (e) {
      main.send(['oerr', id, ..._encodeOpError(e)]);
    }
  }

  commands.listen((Object? raw) {
    final m = raw! as List<Object?>;
    switch (m[0]) {
      case 'req':
        unawaited(serve(m[1]! as int, m[2]! as String, m[3]! as Map<String, dynamic>));
      case 'op':
        unawaited(serveOp(m[1]! as int, m[2]! as String, (m[3]! as List).cast<Object?>()));
      case 'exec':
        unawaited(serveExec(m[1]! as int, m[2]! as String));
      case 'up':
        serveUpload(m[1]! as int, m[2]! as String, m[3]! as String);
      case 'upcancel':
        uploads.remove(m[1])?.cancel();
      case 'xsend':
        execs[m[1]]?.send(m[2]! as String);
      case 'xeof':
        final exec = execs[m[1]];
        if (exec != null) unawaited(exec.closeInput());
      case 'xclose':
        final exec = execs[m[1]];
        if (exec != null) unawaited(exec.close());
      case 'sub':
        final id = m[1]! as int;
        final subs = (m[2]! as List).cast<Map<String, dynamic>>();
        subscriptions[id] = transport.events(subs).listen(
          (event) => main.send(['evt', id, event]),
          onError: (Object e) {
            subscriptions.remove(id);
            main.send(['evtErr', id, ..._encodeError(e)]);
          },
          onDone: () {
            if (subscriptions.remove(id) != null) main.send(['evtDone', id]);
          },
        );
      case 'cancel':
        subscriptions.remove(m[1])?.cancel();
      case 'bg':
        transport.setBackground(m[1] == true);
      case 'reset':
        transport.reset();
      case 'close':
        closing = true;
        for (final upload in uploads.values.toList()) {
          upload.cancel();
        }
        uploads.clear();
        for (final s in subscriptions.values) {
          s.cancel();
        }
        subscriptions.clear();
        // Exec channels get a moment to flush stdin and report their end
        // before the connection goes; the main isolate does not wait longer.
        Future.wait([for (final e in execs.values.toList()) e.close()])
            .timeout(const Duration(milliseconds: 500), onTimeout: () => const <void>[])
            .then((_) => transport.close())
            .whenComplete(() {
          main.send(const ['closed']);
          commands.close();
        });
    }
  });
}

/// Worker side of one exec channel: forwards its lines to the main isolate in
/// batches. Batching is by time and size, not by arrival: a burst of lines is
/// a few messages, and a lone line is delayed by [_window] at most.
class _WorkerExec {
  _WorkerExec(this._id, this._channel, this._main, this._onEnd);

  static const _window = Duration(milliseconds: 8);
  // A batch is decoded and reduced on the UI isolate in one go (about 5-10 ms
  // of JSON and 20-40 ms of state on a mid-range phone for the old 2048 lines
  // / 256 KB), which dropped frames at every attach. Small batches keep each
  // slice of that work under a frame or two; the flush window still turns a
  // flood into few messages.
  static const _maxLines = 256;
  static const _maxChars = 48 * 1024;

  final int _id;
  final ExecChannel _channel;
  final SendPort _main;
  final void Function() _onEnd;
  final _batch = <String>[];
  var _chars = 0;
  Timer? _timer;
  StreamSubscription<String>? _sub;
  Future<void>? _finishing;

  void start() {
    _sub = _channel.lines.listen(
      (line) {
        _batch.add(line);
        _chars += line.length;
        if (_batch.length >= _maxLines || _chars >= _maxChars) {
          _flush();
        } else {
          _timer ??= Timer(_window, _flush);
        }
      },
      onError: (Object e) {
        _flush();
        _main.send(['xwarn', _id, '$e']);
      },
      onDone: () => unawaited(_finish()),
    );
  }

  Future<void> closeInput() async {
    try {
      await _channel.closeInput();
    } on Object {
      // already gone: the end is reported on its own
    }
  }

  void send(String line) {
    try {
      _channel.send(line);
    } on Object {
      // closed meanwhile: the end is reported on its own
    }
  }

  void _flush() {
    _timer?.cancel();
    _timer = null;
    if (_batch.isEmpty) return;
    // The port copies the list as it is sent, so it can be reused.
    _main.send(['xlines', _id, _batch]);
    _batch.clear();
    _chars = 0;
  }

  Future<void> close() async {
    try {
      await _channel.close();
    } on Object {
      // already gone
    }
    await _sub?.cancel();
    await _finish();
  }

  Future<void> _finish() => _finishing ??= _end();

  Future<void> _end() async {
    _flush();
    int? code;
    try {
      code = await _channel.exitCode.timeout(const Duration(seconds: 2));
    } on Object {
      code = null;
    }
    _main.send(['xend', _id, code, _channel.stderrTail]);
    _onEnd();
  }
}

/// Main-isolate end of one exec channel; the worker holds the real one.
class _MainExec implements ExecChannel {
  _MainExec(this._worker, this._id);

  final _Worker _worker;
  final int _id;
  final _out = StreamController<String>();
  final _exit = Completer<int?>();
  var _tail = '';
  var _closed = false;
  var _inputClosed = false;
  var _ended = false;
  Future<void>? _closing;

  @override
  Stream<String> get lines => _out.stream;

  @override
  void send(String line) {
    if (_closed || _inputClosed) throw StateError('exec channel closed');
    if (!_ended) _worker.post(['xsend', _id, line]);
  }

  @override
  Future<void> closeInput() async {
    if (_inputClosed) return;
    _inputClosed = true;
    if (!_ended) _worker.post(['xeof', _id]);
  }


  @override
  Future<int?> get exitCode => _exit.future;

  @override
  String get stderrTail => _tail;

  void addLines(List<String> batch) {
    if (_ended) return;
    for (final line in batch) {
      _out.add(line);
    }
  }

  void warn(String message) {
    if (!_ended) _out.addError(HerdrTransportException(message));
  }

  void end(int? code, String tail, {Object? error}) {
    if (_ended) return;
    _ended = true;
    _tail = tail;
    _worker._execs.remove(_id);
    if (error != null) _out.addError(error);
    unawaited(_out.close());
    _exit.complete(code);
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    if (_ended) return;
    _worker.post(['xclose', _id]);
    // The worker answers with the end; if it cannot, the channel still ends.
    await _exit.future.timeout(const Duration(seconds: 3), onTimeout: () => null);
    end(null, _tail);
  }
}

/// The main-isolate end of one upload: counters in, nothing else.
class _MainUpload implements UploadJob {
  _MainUpload(this._onProgress) {
    // Whoever listens, a failure is never an unhandled error.
    _done.future.then((_) {}, onError: (Object _) {});
  }

  final void Function(int sent, int total)? _onProgress;
  final _done = Completer<void>();
  void Function()? _cancelWorker;
  bool cancelled = false;

  @override
  Future<void> get done => _done.future;

  /// Tells the worker to stop when [cancel] is called.
  void bind(void Function() cancelWorker) => _cancelWorker = cancelWorker;

  void progress(int sent, int total) {
    if (_done.isCompleted) return;
    try {
      _onProgress?.call(sent, total);
    } on Object {
      // a listener's bug must not end the upload
    }
  }

  void finish() {
    if (!_done.isCompleted) _done.complete();
  }

  void fail(Object error) {
    if (!_done.isCompleted) _done.completeError(error);
  }

  @override
  void cancel() {
    if (_done.isCompleted) return;
    cancelled = true;
    fail(UploadCancelled());
    _cancelWorker?.call();
  }
}

/// `[kind, a, b]` for [Object]s that cannot cross the isolate boundary.
/// A file operation's error: `['file', kind, message, fatal, path]`, or the
/// shapes of [_encodeError].
List<Object?> _encodeOpError(Object e) => e is RemoteFileException
    ? ['file', e.kind.name, e.message, e.fatal, e.path]
    : _encodeError(e);

List<Object?> _encodeError(Object e) => switch (e) {
      HerdrApiException(:final code, :final message) => ['api', code, message],
      HerdrTransportException(:final message, :final fatal) => ['transport', message, fatal],
      _ => ['transport', '$e', false],
    };
