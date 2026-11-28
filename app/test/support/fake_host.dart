import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:herdr_mobile/data/host/host_link.dart';
import 'package:herdr_mobile/data/host/wire.dart';

/// The host end of a [HostLink], played by the test: it decodes what the client
/// writes into [received] and writes frames back with [send]. No Rust involved;
/// the real binary is exercised by host_serve_test.dart.
class FakeHost implements HostProcess {
  FakeHost() {
    _stdin.stream.listen((bytes) {
      _decoder.add(bytes, (f) {
        received.add(f);
        onFrame?.call(f);
      });
    });
  }

  final _stdout = StreamController<Uint8List>();
  final _stderr = StreamController<Uint8List>();
  final _stdin = StreamController<Uint8List>();
  final _done = Completer<void>();
  final _decoder = FrameDecoder(expectMagic: false);
  int? _exit;

  /// Every frame the client wrote, in order.
  final received = <Frame>[];

  /// Called for each frame the client writes, as it arrives.
  void Function(Frame)? onFrame;

  var closedByClient = false;

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  StreamSink<Uint8List> get stdin => _stdin.sink;

  @override
  Future<void> get done => _done.future;

  @override
  int? get exitCode => _exit;

  @override
  void close() {
    closedByClient = true;
    _finish(null);
  }

  /// Writes raw bytes to the client.
  void sendBytes(List<int> bytes) => _stdout.add(Uint8List.fromList(bytes));

  /// Writes the magic and the host's HELLO, with [services] available.
  void greet({Map<String, Map<String, Object?>>? services, int window = 1 << 20}) {
    sendBytes(hostMagic);
    send(
      Frame.json(FrameKind.hello, 0, {
        'proto': 1,
        'host': {
          'version': '9.9.9',
          'os': 'linux',
          'arch': 'x86_64',
          'home': '/home/u',
          'hostname': 'box',
          'user': 'u',
        },
        'limits': {'max_msg': maxPayload, 'max_data': maxData, 'window': window, 'max_streams': 64},
        'services':
            services ??
            {
              'herdr': {'available': true, 'reason': null},
            },
      }),
    );
  }

  void send(Frame f) => sendBytes(encodeFrame(f));

  void sendJson(FrameKind kind, int stream, Object? value) => send(Frame.json(kind, stream, value));

  void writeStderr(String text) => _stderr.add(Uint8List.fromList(utf8.encode(text)));

  /// Ends the process with [code] (null: the link dropped).
  void exit(int? code) => _finish(code);

  void _finish(int? code) {
    if (_done.isCompleted) return;
    _exit = code;
    _stdout.close();
    _stderr.close();
    _done.complete();
  }

  /// The OPEN frames the client wrote, decoded.
  List<Map<String, Object?>> get opens => [
    for (final f in received)
      if (f.kind == FrameKind.open)
        (jsonDecode(utf8.decode(f.payload)) as Map).cast<String, Object?>()..['stream'] = f.stream,
  ];

  /// What the client sent on [stream] as `MSG` text.
  List<String> messagesOn(int stream) => [
    for (final f in received)
      if (f.kind == FrameKind.msg && f.stream == stream) utf8.decode(f.payload),
  ];

  /// The frame kinds the client wrote on [stream] (stream 0: the HELLO), in order.
  List<FrameKind> kindsOn(int stream) => [
    for (final f in received)
      if (f.stream == stream) f.kind,
  ];

  /// What the client sent on [stream] as `MSG`s, decoded: the requests of a mux.
  List<Map<String, Object?>> requestsOn(int stream) => [
    for (final text in messagesOn(stream)) (jsonDecode(text) as Map).cast<String, Object?>(),
  ];

  /// The mux's first message on [stream]: herdr's socket is there.
  void sendReady(int stream) => sendJson(FrameKind.msg, stream, {'ready': true});

  /// The mux's answer to request [id].
  void answer(int stream, String id, [Map<String, Object?> result = const {}]) =>
      sendJson(FrameKind.msg, stream, {'id': id, 'result': result});

  /// The total the client has credited on [stream].
  int creditedOn(int stream) => received
      .where((f) => f.kind == FrameKind.credit && f.stream == stream)
      .fold(0, (sum, f) => sum + (f.creditBytes ?? 0));
}

/// Waits until [check] holds; the event loop runs meanwhile.
Future<void> until(
  bool Function() check, {
  String what = 'condition',
  Duration timeout = const Duration(seconds: 5),
}) async {
  final end = DateTime.now().add(timeout);
  while (!check()) {
    if (DateTime.now().isAfter(end)) throw StateError('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}
