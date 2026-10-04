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

  Future<_Worker>? _worker;
  _Worker? _live;
  var _closed = false;

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

  void _onMessage(List<Object?> m) {
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

  void _gone() {
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
    _gone();
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

  Future<void> serve(int id, String method, Map<String, dynamic> params) async {
    try {
      main.send(['res', id, await transport.request(method, params)]);
    } on Object catch (e) {
      main.send(['err', id, ..._encodeError(e)]);
    }
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
        _ => throw HerdrTransportException('Unknown file operation $name'),
      };
      main.send(['ores', id, out]);
    } on RemoteFileException catch (e) {
      main.send(['oerr', id, 'file', e.kind.name, e.message, e.fatal, e.path]);
    } on Object catch (e) {
      main.send(['oerr', id, ..._encodeError(e)]);
    }
  }

  commands.listen((Object? raw) {
    final m = raw! as List<Object?>;
    switch (m[0]) {
      case 'req':
        unawaited(serve(m[1]! as int, m[2]! as String, m[3]! as Map<String, dynamic>));
      case 'op':
        unawaited(serveOp(m[1]! as int, m[2]! as String, (m[3]! as List).cast<Object?>()));
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
      case 'reset':
        transport.reset();
      case 'close':
        for (final s in subscriptions.values) {
          s.cancel();
        }
        subscriptions.clear();
        transport.close().whenComplete(() {
          main.send(const ['closed']);
          commands.close();
        });
    }
  });
}

/// `[kind, a, b]` for [Object]s that cannot cross the isolate boundary.
List<Object?> _encodeError(Object e) => switch (e) {
      HerdrApiException(:final code, :final message) => ['api', code, message],
      HerdrTransportException(:final message, :final fatal) => ['transport', message, fatal],
      _ => ['transport', '$e', false],
    };
