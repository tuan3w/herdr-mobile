// Desktop-only harness for the open-session benchmarks: the REAL keeper (the
// `herdr-host` binary, installed the way the app installs it) in a temp HOME,
// with the testkit's `bench-acp-agent` behind it as the agent, reached the way
// the app reaches it: `herdr-host serve` started by the app's own command
// under `sh -c` (what an SSH server runs, minus SSH), one [HostLink] on it, and
// the real [SshAgentHost] over that link. The bytes the host writes are
// counted per stream ([WireMeter]) before the link reads them, and a link
// model can be wrapped around any transport.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/acp/json_rpc.dart';
import 'package:herdr_mobile/data/acp/past_session.dart';
import 'package:herdr_mobile/data/app_info.dart';
import 'package:herdr_mobile/data/host/host_channels.dart';
import 'package:herdr_mobile/data/host/host_link.dart';
import 'package:herdr_mobile/data/host/wire.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart';
import 'package:herdr_mobile/data/services/ssh_agent_host.dart';

import '../../test/support/keeper_harness.dart';
import '../../test/support/process_host.dart';

/// A binary of the testkit crate (`rust/crates/testkit`): `$HERDR_TESTKIT_DIR`,
/// else `rust/target/release` (build: `cd rust && cargo build --release -p
/// testkit`; benchmarks run the release build).
File testkitBinary(String name) {
  final dir = Platform.environment['HERDR_TESTKIT_DIR'];
  if (dir != null && dir.isNotEmpty) return File('$dir/$name');
  final root = File('benchmark/support/local_keeper.dart').absolute.parent.parent.parent.parent.path;
  return File('$root/rust/target/release/$name');
}

/// What the host wrote on one stream: whole frames, header included.
class StreamTally {
  var bytes = 0;
  int? firstUs;
  int? lastUs;
}

/// Counts what `serve` writes, per stream, as the phone's side would receive
/// it (the frame header and compression included; SSH framing and the few
/// bytes the phone writes are not counted). It walks the frame headers and
/// skips payloads, so it costs the phone-side CPU measurements next to nothing.
class WireMeter {
  /// Never reset: timestamps are microseconds on it.
  final clock = Stopwatch()..start();
  final _streams = <int, StreamTally>{};
  final _head = Uint8List(9);
  var _have = 0;
  var _left = 0;
  var _stream = 0;
  var _magic = hostMagic.length;

  /// Forgets everything: a new link starts a new stream.
  void reset() {
    _streams.clear();
    _have = 0;
    _left = 0;
    _magic = hostMagic.length;
  }

  /// What was written on [id] so far (nothing: zeros).
  StreamTally stream(int id) => _streams[id] ?? StreamTally();

  void add(Uint8List chunk) {
    final now = clock.elapsedMicroseconds;
    var i = 0;
    while (i < chunk.length) {
      if (_magic > 0) {
        final n = _magic < chunk.length - i ? _magic : chunk.length - i;
        _magic -= n;
        i += n;
        continue;
      }
      if (_left > 0) {
        final n = _left < chunk.length - i ? _left : chunk.length - i;
        _left -= n;
        i += n;
        _streams[_stream]!.lastUs = now;
        continue;
      }
      _head[_have++] = chunk[i++];
      if (_have == 9) {
        final h = ByteData.sublistView(_head);
        final len = h.getUint32(0, Endian.little); // kind + stream + payload
        _stream = h.getUint32(5, Endian.little);
        _left = len - 5;
        _have = 0;
        (_streams[_stream] ??= StreamTally())
          ..bytes += 4 + len
          ..firstUs ??= now
          ..lastUs = now;
      }
    }
  }
}

/// The `serve` process as a [HostProcess], with its stdout counted.
class MeteredHostProcess implements HostProcess {
  MeteredHostProcess(this._inner, this._meter);

  final ProcessHostProcess _inner;
  final WireMeter? _meter;

  @override
  late final Stream<Uint8List> stdout = _meter == null
      ? _inner.stdout
      : _inner.stdout.map((chunk) {
          _meter.add(chunk);
          return chunk;
        });

  @override
  Stream<Uint8List> get stderr => _inner.stderr;

  @override
  StreamSink<Uint8List> get stdin => _inner.stdin;

  @override
  Future<void> get done => _inner.done;

  @override
  int? get exitCode => _inner.exitCode;

  @override
  void close() => _inner.close();
}

/// A stream the phone opened on the link: its id, what it was and when.
typedef OpenedStream = ({int id, String method, int startedUs});

/// [LinkTransport] whose streams are opened with [LocalKeeperHost.zctx] (the
/// app opens them all with zctx) and noted in [LocalKeeperHost.opens].
class _BenchTransport extends LinkTransport {
  _BenchTransport(this._host) : super(_host.link);

  final LocalKeeperHost _host;

  @override
  Future<ExecChannel> openHostStream(String service, String method, [Map<String, Object?> args = const {}]) async {
    final link = await _host.link();
    final s = link.open(service, method, args, _host.zctx);
    _host.opens.add((id: s.id, method: '$service.$method', startedUs: _host.meter.clock.elapsedMicroseconds));
    return HostLineChannel(s);
  }
}

/// A keeper host that is a temp directory on this machine.
class LocalKeeperHost implements AgentHost {
  LocalKeeperHost._(this.home, this.env);

  final Directory home;
  final Map<String, String> env;

  /// What the host wrote on the shared link.
  final meter = WireMeter();

  /// Every stream [transport] opened, in order.
  final opens = <OpenedStream>[];

  /// Open streams as the app does (`zctx`: the host compresses the stream as
  /// one continuous zlib stream); false to see what the same session costs as
  /// plain frames.
  bool zctx = true;

  final _serves = <ProcessHostProcess>[];
  HostLink? _link;
  Future<HostLink>? _linking;

  String get work => '${home.path}/work';

  static Future<LocalKeeperHost> create() async {
    final home = Directory.systemTemp.createTempSync('session_open_bench_');
    final bin = Directory('${home.path}/bin')..createSync();
    Directory('${home.path}/work').createSync();
    final agent = testkitBinary('bench-acp-agent');
    if (!agent.existsSync()) {
      throw StateError(
        '${agent.path} is missing: cd rust && cargo build --release -p testkit (or set HERDR_TESTKIT_DIR)',
      );
    }
    final omp = File('${bin.path}/omp')..writeAsStringSync('#!/bin/sh\nexec \'${agent.absolute.path}\' "\$@"\n');
    await Process.run('chmod', ['755', omp.path]);
    final host = LocalKeeperHost._(home, {
      'HOME': home.path,
      'PATH': '${bin.path}:/usr/bin:/bin:/usr/local/bin',
      // A herdr on this machine must never get a pane from a benchmark.
      'HERDR_MOBILE_NO_PANE': '1',
    });
    await installHostBinary(home);
    return host;
  }

  /// A new `herdr-host serve` as an SSH server would run the app's command, and
  /// a link on it. [extraEnv] is added to the process's environment (the agent
  /// inherits it); [metered] counts what it writes in [meter] (one metered link
  /// at a time).
  Future<HostLink> openLink({Map<String, String> extraEnv = const {}, bool metered = true}) async {
    final p = await ProcessHostProcess.start(
      '/bin/sh',
      ['-c', hostServeCommand()],
      environment: {...env, ...extraEnv},
      workingDirectory: home.path,
    );
    _serves.add(p);
    if (metered) meter.reset();
    return HostLink.connect(
      MeteredHostProcess(p, metered ? meter : null),
      version: appVersion,
      helloTimeout: const Duration(seconds: 30),
    );
  }

  /// The shared link, opened on first use (and again after it died).
  Future<HostLink> link() {
    final live = _link;
    if (live != null && live.isOpen) return Future.value(live);
    return _linking ??= openLink().then((l) => _link = l).whenComplete(() => _linking = null);
  }

  /// What the app has of this machine: [SshAgentHost] over [transport].
  late final transport = _BenchTransport(this);
  late final SshAgentHost agentHost = SshAgentHost(transport, quickTimeout: const Duration(seconds: 30));

  /// Starts a keeper whose agent plays [seedFile] on its first prompt. The
  /// keeper is started through a `serve` of its own, whose environment carries
  /// `BENCH_SEED` (the agent inherits it), and not counted by [meter].
  @override
  Future<KeeperInfo> start({required String agent, required String cwd, String? seedFile}) async {
    if (seedFile == null) return agentHost.start(agent: agent, cwd: cwd);
    final l = await openLink(extraEnv: {'BENCH_SEED': seedFile}, metered: false);
    try {
      return await SshAgentHost(LinkTransport(() async => l)).start(agent: agent, cwd: cwd);
    } finally {
      unawaited(l.close());
    }
  }

  @override
  Future<Set<String>> available() => agentHost.available();

  @override
  Future<List<KeeperInfo>> list() => agentHost.list();

  /// The keeper's attach stream, raw: for a benchmark that reads the bytes
  /// itself. Plain unless [zctx] is given.
  Future<HostStream> attachStream(String id, {bool? zctx}) async {
    final link = await this.link();
    final s = link.open('keeper', 'attach', {'id': id}, zctx ?? false);
    opens.add((id: s.id, method: 'keeper.attach', startedUs: meter.clock.elapsedMicroseconds));
    return s;
  }

  @override
  Future<AcpTransport> attach(String keeperId) => agentHost.attach(keeperId);

  @override
  Future<void> kill(String keeperId) => agentHost.kill(keeperId);

  @override
  Future<PastSessions> history({required String agent, String? cwd}) => agentHost.history(agent: agent, cwd: cwd);

  Future<void> dispose() async {
    try {
      for (final k in await list()) {
        await kill(k.id);
      }
    } on Object {
      // best effort: the temp home goes away next
    }
    for (final p in _serves) {
      p.close();
    }
    try {
      home.deleteSync(recursive: true);
    } on Object {
      // a keeper still writing its record: the OS temp cleaner takes it
    }
  }
}

/// A phone's link: [rttMs] round trip, [mbit] megabits a second towards the
/// phone (0: unlimited). The sender's queue is modelled, so a big replay
/// takes `bytes / rate` on top of the latency; the phone to host direction
/// only pays the latency (its messages are small).
class LinkModel {
  const LinkModel(this.name, this.rttMs, this.mbit);

  final String name;
  final double rttMs;
  final double mbit;

  static const local = LinkModel('local', 0, 0);

  Duration get oneWay => Duration(microseconds: (rttMs * 500).round());
  Duration get rtt => Duration(microseconds: (rttMs * 1000).round());

  /// Time `bytes` occupy the link towards the phone.
  Duration wire(int bytes) => mbit <= 0 ? Duration.zero : Duration(microseconds: (bytes * 8 / mbit).round());
}

/// Delays what [inner] says and what is said to it as [link] would.
class LinkedTransport implements AcpTransport {
  LinkedTransport(this.inner, this.link) {
    _clock.start();
    inner.lines.listen(
      _arrived,
      onError: _out.addError,
      onDone: () {
        _innerDone = true;
        _drain();
      },
    );
  }

  final AcpTransport inner;
  final LinkModel link;
  final _clock = Stopwatch();
  final _out = StreamController<String>(sync: true);
  final _queue = Queue<(Duration due, String line)>();
  var _lastDue = Duration.zero;
  var _innerDone = false;
  Timer? _timer;

  @override
  Stream<String> get lines => _out.stream;

  void _arrived(String line) {
    if (link == LinkModel.local) {
      _out.add(line);
      return;
    }
    final now = _clock.elapsed;
    final start = now + link.oneWay;
    final from = start > _lastDue ? start : _lastDue;
    final due = from + link.wire(utf8.encode(line).length + 1);
    _lastDue = due;
    _queue.add((due, line));
    _arm();
  }

  void _arm() {
    if (_timer != null || _queue.isEmpty) return;
    final wait = _queue.first.$1 - _clock.elapsed;
    _timer = Timer(wait.isNegative ? Duration.zero : wait, () {
      _timer = null;
      _drain();
    });
  }

  void _drain() {
    final now = _clock.elapsed;
    while (_queue.isNotEmpty && _queue.first.$1 <= now) {
      _out.add(_queue.removeFirst().$2);
    }
    if (_queue.isNotEmpty) {
      _arm();
    } else if (_innerDone && !_out.isClosed) {
      unawaited(_out.close());
    }
  }

  @override
  void send(String line) {
    if (link == LinkModel.local) {
      inner.send(line);
      return;
    }
    Timer(link.oneWay, () {
      try {
        inner.send(line);
      } on Object {
        // closed meanwhile
      }
    });
  }

  @override
  Future<void> close() => inner.close();
}

/// [LocalKeeperHost] seen through [link]. The app keeps one link to the host
/// open, so an attach costs no channel to open: the stream's OPEN and the
/// first request travel together, and everything after it is the transport's
/// delays. (A first use on a new connection also pays the SSH exec and the
/// HELLO, about 3 round trips, once per connection; not modelled here.)
class LinkedHost implements AgentHost {
  LinkedHost(this.inner, this.link);

  final LocalKeeperHost inner;
  final LinkModel link;

  @override
  Future<AcpTransport> attach(String keeperId) async {
    final transport = await inner.attach(keeperId);
    return link == LinkModel.local ? transport : LinkedTransport(transport, link);
  }

  @override
  Future<Set<String>> available() => inner.available();

  @override
  Future<List<KeeperInfo>> list() => inner.list();

  @override
  Future<KeeperInfo> start({required String agent, required String cwd}) => inner.start(agent: agent, cwd: cwd);

  @override
  Future<void> kill(String keeperId) => inner.kill(keeperId);

  @override
  Future<PastSessions> history({required String agent, String? cwd}) => inner.history(agent: agent, cwd: cwd);
}
