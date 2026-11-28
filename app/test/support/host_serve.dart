import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:herdr_mobile/data/app_info.dart';
import 'package:herdr_mobile/data/host/host_files.dart';
import 'package:herdr_mobile/data/host/host_link.dart';
import 'package:herdr_mobile/data/host/wire.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/models/remote_search.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';

import 'no_files.dart';
import 'process_host.dart';

/// The built `herdr-host`: `HERDR_HOST_BIN`, else the release build in
/// `rust/target/release` (`cd rust && cargo build --release -p host`).
File hostBinary() {
  final fromEnv = Platform.environment['HERDR_HOST_BIN'];
  if (fromEnv != null && fromEnv.isNotEmpty) return File(fromEnv);
  final root = Directory.current.parent.path;
  return File('$root/rust/target/release/herdr-host');
}

/// Why a test that needs the binary cannot run, or null when it can.
String? hostBinarySkip() => hostBinary().existsSync()
    ? null
    : 'build the host first: cd rust && cargo build --release -p host (or set HERDR_HOST_BIN)';

/// A [HostProcess] that decodes what the client writes, so a test can say what
/// went over the wire (one request, a reset on cancel).
class SpyHostProcess implements HostProcess {
  SpyHostProcess(this.inner) {
    stdin = _Tap(inner.stdin, (bytes) {
      _decoder.add(bytes, written.add);
    });
  }

  final ProcessHostProcess inner;
  final _decoder = FrameDecoder(expectMagic: false);

  /// Every frame the client wrote, in order.
  final written = <Frame>[];

  @override
  Stream<Uint8List> get stdout => inner.stdout;

  @override
  Stream<Uint8List> get stderr => inner.stderr;

  @override
  late final StreamSink<Uint8List> stdin;

  @override
  Future<void> get done => inner.done;

  @override
  int? get exitCode => inner.exitCode;

  @override
  void close() => inner.close();

  /// The connection dies without a word.
  void kill() => inner.kill();

  /// The frames of [kind] the client wrote.
  List<Frame> sent(FrameKind kind) => [
    for (final f in written)
      if (f.kind == kind) f,
  ];

  /// The OPENs the client wrote, decoded: `svc`, `method`, `args`, `stream`.
  List<Map<String, Object?>> openRequests() => [
    for (final f in sent(FrameKind.open))
      (jsonDecode(utf8.decode(f.payload)) as Map).cast<String, Object?>()..['stream'] = f.stream,
  ];

  /// The OPENs the client wrote, as `service.method`.
  List<String> opens() => [for (final o in openRequests()) '${o['svc']}.${o['method']}'];

  /// The `args` of every OPEN of `service.method`.
  List<Map<String, Object?>> argsOf(String serviceMethod) => [
    for (final o in openRequests())
      if ('${o['svc']}.${o['method']}' == serviceMethod) (o['args']! as Map).cast<String, Object?>(),
  ];
}

class _Tap implements StreamSink<Uint8List> {
  _Tap(this._inner, this._seen);

  final StreamSink<Uint8List> _inner;
  final void Function(Uint8List) _seen;

  @override
  void add(Uint8List data) {
    _seen(data);
    _inner.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<Uint8List> stream) => _inner.addStream(
    stream.map((b) {
      _seen(b);
      return b;
    }),
  );

  @override
  Future<void> close() => _inner.close();

  @override
  Future<void> get done => _inner.done;
}

/// A home folder and the `herdr-host serve` processes run as that home's user,
/// the way an SSH server would run them (one per connection).
class ServedHost {
  ServedHost() : home = Directory.systemTemp.createTempSync('served_host').resolveSymbolicLinksSync();

  /// The (resolved) home folder: what `~` is on this host.
  final String home;
  final processes = <SpyHostProcess>[];

  Future<SpyHostProcess> start() async {
    final p = SpyHostProcess(
      await ProcessHostProcess.start(
        hostBinary().path,
        ['serve'],
        environment: {'HOME': home, 'XDG_CONFIG_HOME': '$home/xdg', 'PATH': '/usr/bin:/bin'},
        workingDirectory: home,
      ),
    );
    processes.add(p);
    return p;
  }

  /// A new connection: a new process and its link.
  Future<(SpyHostProcess, HostLink)> connect() async {
    final p = await start();
    return (p, await HostLink.connect(p, version: appVersion));
  }

  /// Ends every process and removes the home folder.
  void dispose() {
    for (final p in processes) {
      p.close();
    }
    processes.clear();
    final dir = Directory(home);
    if (dir.existsSync()) {
      // A test may leave folders it made unreadable.
      Process.runSync('chmod', ['-R', 'u+rwX', home]);
      dir.deleteSync(recursive: true);
    }
  }
}

/// A [HerdrTransport] whose files are a [HostFiles] (the real binary behind
/// it): what `RemoteFiles` and the staging of a copy see on a machine with the
/// agent helper. Everything else throws [UnsupportedError].
class HostFilesTransport with NoFiles implements HerdrTransport {
  HostFilesTransport(this.files);

  final HostFiles files;

  @override
  bool get supportsFiles => true;

  @override
  Future<RemoteStat> statFile(String path) => files.stat(path);

  @override
  Future<List<RemoteEntry>> listDirectory(String path) => files.list(path);

  @override
  Future<Uint8List> readFile(String path, {int offset = 0, int length = remoteReadCap, RemoteStat? ifMatch}) =>
      files.read(path, offset, length.clamp(0, remoteReadCap), ifMatch: ifMatch);

  @override
  Future<String> realPath(String path) => files.realPath(path);

  @override
  Stream<RemoteStat?> watchFile(String path) => files.watch(path);

  @override
  Future<Uint8List?> thumbnailFile(String path, {int maxPx = 256, RemoteStat? expect, Future<void>? cancelled}) =>
      files.thumbnail(path, maxPx: maxPx, expect: expect, cancelled: cancelled);

  @override
  Stream<FileSearchEvent> searchFiles(FileSearchSpec spec) => files.search(spec);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('${invocation.memberName}');
}
