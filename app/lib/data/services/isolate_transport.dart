import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../host/host_link.dart' show HostException, HostLinkLost;
import '../models/remote_file.dart';
import '../models/remote_search.dart';
import '../models/web_bridge.dart';
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
  IsolateTransport({required this.builder, required this.config, required this.onPin, this.onNotice});

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
      final worker = await _Worker.spawn(builder, await config(), onPin, onNotice ?? (_) {});
      _live = worker;
      if (_background) worker.post(const ['bg', true]);
      // A dead worker is replaced by the next call.
      unawaited(
        worker.gone.then((_) {
          if (identical(_live, worker)) {
            _live = null;
            _worker = null;
          }
        }),
      );
      return worker;
    } on Object {
      _worker = null;
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) async =>
      (await _ensure()).request(method, params);

  @override
  bool get supportsFiles => true;

  @override
  Future<RemoteStat> statFile(String path) async => RemoteStat.fromJson(await _op('stat', [path]) as Map);

  @override
  Future<List<RemoteEntry>> listDirectory(String path) async => [
    for (final e in await _op('list', [path]) as List) RemoteEntry.fromJson(e as Map),
  ];

  @override
  Future<Uint8List> readFile(String path, {int offset = 0, int length = remoteReadCap, RemoteStat? ifMatch}) async {
    final bytes = await _op('read', [
      path,
      offset,
      length.clamp(0, remoteReadCap),
      ifMatch?.size,
      ifMatch?.modified?.millisecondsSinceEpoch,
    ]);
    // Moved, not copied: the worker handed over ownership of the buffer.
    return (bytes! as TransferableTypedData).materialize().asUint8List();
  }

  @override
  Future<WebBridgeInfo> openWebBridge(WebBridgeSpec spec) async {
    // Only primitives cross: the worker rebuilds the spec.
    final out = await _op('web', switch (spec) {
      StaticSite() => ['static', spec.machineName, spec.root],
      PortForward() => ['forward', spec.machineName, spec.host, spec.port],
    }) as List;
    return WebBridgeInfo(port: out[0]! as int, token: out[1]! as String, entryPort: out[2]! as int);
  }

  @override
  Future<String> realPath(String path) async => await _op('real', [path]) as String;

  @override
  Stream<RemoteStat?> watchFile(String path) {
    var cancelled = false;
    void Function()? cancel;
    late final StreamController<Object?> out;
    out = StreamController<Object?>(
      onListen: () async {
        try {
          final worker = await _ensure();
          if (cancelled) return;
          cancel = worker.openWatch(path, out);
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
    return out.stream.map((m) => m == null ? null : RemoteStat.fromJson(m as Map));
  }

  @override
  Future<Uint8List?> thumbnailFile(String path, {int maxPx = 256, RemoteStat? expect, Future<void>? cancelled}) async {
    try {
      final bytes = await (await _ensure()).op('thumb', [
        path,
        maxPx,
        expect?.size,
        expect?.modified?.millisecondsSinceEpoch,
      ], cancelled: cancelled);
      // Moved, not copied, like a read.
      return bytes == null ? null : (bytes as TransferableTypedData).materialize().asUint8List();
    } on Object {
      return null;
    }
  }

  @override
  Stream<FileSearchEvent> searchFiles(FileSearchSpec spec) {
    var cancelled = false;
    void Function()? cancel;
    late final StreamController<Object?> out;
    out = StreamController<Object?>(
      onListen: () async {
        try {
          final worker = await _ensure();
          if (cancelled) return;
          cancel = worker.openSearch(spec, out);
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
    return out.stream.map((m) => FileSearchEvent.fromJson(m! as Map));
  }

  @override
  Future<String> reserveInboxFile({required String key, required String name}) async =>
      await _op('reserve', [key, name]) as String;

  @override
  Future<int> sweepInbox() async => await _op('sweep', const []) as int;

  @override
  UploadJob uploadFile({
    required String localPath,
    required String inboxPath,
    void Function(int sent, int total)? onProgress,
  }) {
    final job = _MainUpload(onProgress);
    _ensure().then((worker) => worker.startUpload(job, localPath, inboxPath), onError: (Object e) => job.fail(e));
    return job;
  }

  /// How many progress messages the main isolate has received from the
  /// current worker (uploads send counters, never bytes). For tests.
  int get uploadProgressMessages => _live?.uploadProgress ?? 0;

  @override
  Future<Object?> hostCall(String service, String method, [Map<String, Object?> args = const {}, Duration? timeout]) =>
      _op('hcall', [service, method, args, timeout?.inMilliseconds]);

  @override
  Future<ExecChannel> openHostStream(String service, String method, [Map<String, Object?> args = const {}]) async =>
      (await _ensure()).openHostStream(service, method, args);

  @override
  Stream<Object?> openHostMessages(String service, String method, [Map<String, Object?> args = const {}]) {
    var cancelled = false;
    void Function()? cancel;
    late final StreamController<Object?> out;
    out = StreamController<Object?>(
      onListen: () async {
        try {
          final worker = await _ensure();
          if (cancelled) return;
          cancel = worker.openMessages(service, method, args, out);
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

  /// How many batches of exec lines the main isolate has received from the
  /// current worker: lines cross the boundary in batches, never one message
  /// each. For tests and diagnostics.
  int get execBatchesReceived => _live?.execBatches ?? 0;

  Future<Object?> _op(String name, List<Object?> args) async => (await _ensure()).op(name, args);

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
          handshake.completeError(HerdrTransportException(message[1] as String, fatal: true));
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
  final _messageStreams = <int, StreamController<Object?>>{};
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
  /// [TransferableTypedData] for bytes. [cancelled] completing tells the worker
  /// that nobody waits for the answer any more (the operation may then end
  /// early, with whatever it answers a cancelled call).
  Future<Object?> op(String name, List<Object?> args, {Future<void>? cancelled}) {
    if (_dead) {
      return Future.error(const HerdrTransportException('herdr connection lost'));
    }
    final id = _nextId++;
    final reply = _ops[id] = Completer<Object?>();
    _to.send(['op', id, name, args]);
    if (cancelled != null) {
      unawaited(
        cancelled.then((_) {
          if (_ops.containsKey(id)) post(['opcancel', id]);
        }, onError: (Object _) {}),
      );
    }
    return reply.future;
  }

  /// Starts [job]'s upload in the worker. Only paths go up and counters come
  /// back; the file is read and sent on the other side.
  void startUpload(_MainUpload job, String localPath, String inboxPath) {
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
    _to.send(['up', id, localPath, inboxPath]);
  }

  /// Forwards the worker's events into [out]; returns the cancel callback.
  void Function() subscribe(List<Map<String, dynamic>> subscriptions, StreamController<Map<String, dynamic>> out) {
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

  /// Forwards the messages of the host stream `[service].[method]` into [out];
  /// returns the cancel callback (which ends the stream on the host).
  void Function() openMessages(
    String service,
    String method,
    Map<String, Object?> args,
    StreamController<Object?> out,
  ) => _openMessageStream(out, (id) => ['hmsg', id, service, method, args]);

  /// Forwards what the worker's `watchFile(path)` says (a stat as JSON, or null
  /// when nothing is there) into [out]; returns the cancel callback.
  void Function() openWatch(String path, StreamController<Object?> out) =>
      _openMessageStream(out, (id) => ['fwatch', id, path]);

  /// Forwards the events of the worker's `searchFiles(spec)` (as JSON) into
  /// [out]; returns the cancel callback.
  void Function() openSearch(FileSearchSpec spec, StreamController<Object?> out) =>
      _openMessageStream(out, (id) => ['fsearch', id, spec.toJson()]);

  void Function() _openMessageStream(StreamController<Object?> out, List<Object?> Function(int id) open) {
    if (_dead) {
      out
        ..addError(const HerdrTransportException('herdr connection lost'))
        ..close();
      return () {};
    }
    final id = _nextId++;
    _messageStreams[id] = out;
    _to.send(open(id));
    return () {
      if (_messageStreams.remove(id) != null) post(['hcancel', id]);
    };
  }

  /// Opens `[service].[method]` of the agent helper in the worker, with [args];
  /// its lines cross like an exec's. The channel is registered before the worker
  /// answers, so lines that follow the answer in the same turn are not lost;
  /// they wait in the channel until its stream is listened to.
  Future<ExecChannel> openHostStream(String service, String method, Map<String, Object?> args) {
    if (_dead) {
      return Future.error(const HerdrTransportException('herdr connection lost'));
    }
    final id = _nextId++;
    _execs[id] = _MainExec(this, id);
    final opened = _opens[id] = Completer<ExecChannel>();
    _to.send(['hstream', id, service, method, args]);
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
      case 'hevt':
        _messageStreams[m[1] as int]?.add(m[2]);
      case 'herr':
        final out = _messageStreams.remove(m[1] as int);
        if (out != null) {
          out.addError(_decodeOpError(m));
          out.close();
        }
      case 'hdone':
        _messageStreams.remove(m[1] as int)?.close();
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

  /// `['err', id, kind, a, b]`: api -> (code, message), host -> (code, message,
  /// retryable), else (message, fatal).
  Object _decodeError(List<Object?> m) => switch (m[2]) {
    'api' => HerdrApiException(m[3]! as String, m[4]! as String),
    'host' =>
      m[3] == 'link_lost'
          ? HostLinkLost(m[4]! as String)
          : HostException(m[3]! as String, m[4]! as String, retryable: m[5] == true),
    _ => HerdrTransportException(m[3]! as String, fatal: m[4] == true),
  };

  /// `['oerr', id, 'file', kind, message, fatal, path]` (kind `changed` is a
  /// [RemoteFileChanged]), or the shapes of [_decodeError] after the id.
  Object _decodeOpError(List<Object?> m) => m[2] != 'file'
      ? _decodeError(m)
      : m[3] == 'changed'
      ? RemoteFileChanged(m[4]! as String, path: m[6] as String?)
      : RemoteFileException(
          RemoteFileErrorKind.parse(m[3] as String?),
          m[4]! as String,
          fatal: m[5] == true,
          path: m[6] as String?,
        );

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
    for (final out in _messageStreams.values.toList()) {
      out
        ..addError(lost)
        ..close();
    }
    _messageStreams.clear();
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
    transport = builder(init[2], (fp) => main.send(['pin', fp]), (banner) => main.send(['notice', banner]));
  } on Object catch (e) {
    main.send(['fatal', '$e']);
    commands.close();
    return;
  }
  main.send(commands.sendPort);

  final subscriptions = <int, StreamSubscription<Map<String, dynamic>>>{};
  final messageSubs = <int, StreamSubscription<Object?>>{};
  final execs = <int, _WorkerExec>{};
  final uploads = <int, UploadJob>{};
  final opCancels = <int, Completer<void>>{};
  var closing = false;

  Future<void> serve(int id, String method, Map<String, dynamic> params) async {
    try {
      main.send(['res', id, await transport.request(method, params)]);
    } on Object catch (e) {
      main.send(['err', id, ..._encodeError(e)]);
    }
  }

  Future<void> serveChannel(int id, Future<ExecChannel> Function() open) async {
    final ExecChannel channel;
    try {
      if (closing) throw const HerdrTransportException('Transport closed');
      channel = await open();
    } on Object catch (e) {
      main.send(['xopenErr', id, ..._encodeError(e)]);
      return;
    }
    final exec = execs[id] = _WorkerExec(id, channel, main, () => execs.remove(id));
    main.send(['xopen', id]);
    exec.start();
    if (closing) unawaited(exec.close());
  }

  Future<void> serveHostStream(int id, String service, String method, Map<String, Object?> args) =>
      serveChannel(id, () => transport.openHostStream(service, method, args));

  void serveUpload(int id, String localPath, String inboxPath) {
    if (closing) {
      main.send(['uerr', id, ..._encodeError(const HerdrTransportException('Transport closed'))]);
      return;
    }
    final UploadJob job;
    try {
      job = transport.uploadFile(
        localPath: localPath,
        inboxPath: inboxPath,
        onProgress: (sent, total) => main.send(['uprog', id, sent, total]),
      );
    } on Object catch (e) {
      main.send(['uerr', id, ..._encodeOpError(e)]);
      return;
    }
    uploads[id] = job;
    job.done.then(
      (_) {
        if (uploads.remove(id) != null) main.send(['udone', id]);
      },
      onError: (Object e) {
        if (uploads.remove(id) != null) main.send(['uerr', id, ..._encodeOpError(e)]);
      },
    );
  }

  Future<void> serveOp(int id, String name, List<Object?> args) async {
    // Completes when the main isolate stops waiting for this operation.
    final stop = opCancels[id] = Completer<void>();
    try {
      final Object? out = switch (name) {
        'stat' => (await transport.statFile(args[0]! as String)).toJson(),
        'list' => [for (final e in await transport.listDirectory(args[0]! as String)) e.toJson()],
        'read' => TransferableTypedData.fromList([
          await transport.readFile(
            args[0]! as String,
            offset: args[1]! as int,
            length: args[2]! as int,
            ifMatch: args[3] == null || args[4] == null
                ? null
                : RemoteStat(
                    path: args[0]! as String,
                    kind: RemoteEntryKind.file,
                    size: args[3]! as int,
                    modified: DateTime.fromMillisecondsSinceEpoch(args[4]! as int, isUtc: true),
                  ),
          ),
        ]),
        'thumb' => await _thumbOp(transport, args, stop.future),
        'real' => await transport.realPath(args[0]! as String),
        'web' => await _openWeb(transport, args),
        'reserve' => await transport.reserveInboxFile(key: args[0]! as String, name: args[1]! as String),
        'sweep' => await transport.sweepInbox(),
        'hcall' => await transport.hostCall(
          args[0]! as String,
          args[1]! as String,
          (args[2]! as Map).cast<String, Object?>(),
          args[3] == null ? null : Duration(milliseconds: args[3]! as int),
        ),
        _ => throw HerdrTransportException('Unknown file operation $name'),
      };
      main.send(['ores', id, out]);
    } on Object catch (e) {
      main.send(['oerr', id, ..._encodeOpError(e)]);
    } finally {
      opCancels.remove(id);
    }
  }

  commands.listen((Object? raw) {
    final m = raw! as List<Object?>;
    switch (m[0]) {
      case 'req':
        unawaited(serve(m[1]! as int, m[2]! as String, m[3]! as Map<String, dynamic>));
      case 'op':
        unawaited(serveOp(m[1]! as int, m[2]! as String, (m[3]! as List).cast<Object?>()));
      case 'hstream':
        unawaited(
          serveHostStream(m[1]! as int, m[2]! as String, m[3]! as String, (m[4]! as Map).cast<String, Object?>()),
        );
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
        subscriptions[id] = transport
            .events(subs)
            .listen(
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
      case 'hmsg':
        final id = m[1]! as int;
        messageSubs[id] = transport
            .openHostMessages(m[2]! as String, m[3]! as String, (m[4]! as Map).cast<String, Object?>())
            .listen(
              (value) => main.send(['hevt', id, value]),
              onError: (Object e) {
                messageSubs.remove(id);
                main.send(['herr', id, ..._encodeError(e)]);
              },
              onDone: () {
                if (messageSubs.remove(id) != null) main.send(['hdone', id]);
              },
            );
      case 'hcancel':
        messageSubs.remove(m[1])?.cancel();
      case 'fwatch':
        final id = m[1]! as int;
        messageSubs[id] = transport
            .watchFile(m[2]! as String)
            .listen(
              (stat) => main.send(['hevt', id, stat?.toJson()]),
              onError: (Object e) {
                messageSubs.remove(id);
                main.send(['herr', id, ..._encodeOpError(e)]);
              },
              onDone: () {
                if (messageSubs.remove(id) != null) main.send(['hdone', id]);
              },
            );
      case 'fsearch':
        final id = m[1]! as int;
        messageSubs[id] = transport
            .searchFiles(FileSearchSpec.fromJson(m[2]! as Map))
            .listen(
              (event) => main.send(['hevt', id, event.toJson()]),
              onError: (Object e) {
                messageSubs.remove(id);
                main.send(['herr', id, ..._encodeOpError(e)]);
              },
              onDone: () {
                if (messageSubs.remove(id) != null) main.send(['hdone', id]);
              },
            );
      case 'opcancel':
        final stop = opCancels[m[1]];
        if (stop != null && !stop.isCompleted) stop.complete();
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
        for (final s in messageSubs.values) {
          s.cancel();
        }
        messageSubs.clear();
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

/// `['thumb']` in the worker: `[path, maxPx, size?, mtimeMs?]` in, the JPEG as
/// transferable bytes (moved, not copied) or null out.
Future<TransferableTypedData?> _thumbOp(HerdrTransport transport, List<Object?> args, Future<void> cancelled) async {
  final size = args[2] as int?;
  final mtime = args[3] as int?;
  final bytes = await transport.thumbnailFile(
    args[0]! as String,
    maxPx: args[1]! as int,
    expect: size == null || mtime == null
        ? null
        : RemoteStat(
            path: args[0]! as String,
            kind: RemoteEntryKind.file,
            size: size,
            modified: DateTime.fromMillisecondsSinceEpoch(mtime, isUtc: true),
          ),
    cancelled: cancelled,
  );
  return bytes == null ? null : TransferableTypedData.fromList([bytes]);
}

/// The worker's half of [IsolateTransport.openWebBridge]: `['static', machine,
/// root]` or `['forward', machine, host, port]` in, `[port, token]` out.
Future<List<Object?>> _openWeb(HerdrTransport transport, List<Object?> args) async {
  final machine = args[1]! as String;
  final spec = switch (args[0]) {
    'static' => StaticSite(args[2]! as String, machineName: machine),
    'forward' => PortForward(args[2]! as String, args[3]! as int, machineName: machine),
    final other => throw HerdrTransportException('Unknown web source $other'),
  };
  final info = await transport.openWebBridge(spec);
  return [info.port, info.token, info.entryPort];
}

/// `[kind, a, b]` for [Object]s that cannot cross the isolate boundary.
/// A file operation's error: `['file', kind, message, fatal, path]`, or the
/// shapes of [_encodeError].
List<Object?> _encodeOpError(Object e) => switch (e) {
  RemoteFileChanged() => ['file', 'changed', e.message, e.fatal, e.path],
  RemoteFileException() => ['file', e.kind.name, e.message, e.fatal, e.path],
  _ => _encodeError(e),
};

List<Object?> _encodeError(Object e) => switch (e) {
  HerdrApiException(:final code, :final message) => ['api', code, message],
  HostException(:final code, :final message, :final retryable) => ['host', code, message, retryable],
  HerdrTransportException(:final message, :final fatal) => ['transport', message, fatal],
  _ => ['transport', '$e', false],
};
