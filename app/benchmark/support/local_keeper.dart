// Desktop-only harness for the open-session benchmark: the REAL keeper script
// (python3, installed the way the app installs it) in a temp HOME, with
// `benchmark/support/bench_acp_agent.py` behind it as the agent, an
// [AgentHost] that attaches through `sh -c keeperAttachCommand(id)` (what the
// SSH exec channel runs, minus SSH), and a link model wrapped around any
// transport.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/acp/json_rpc.dart';
import 'package:herdr_mobile/data/acp/past_session.dart';
import 'package:herdr_mobile/data/acp/process_transport.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart';

/// A keeper host that is a temp directory on this machine.
class LocalKeeperHost implements AgentHost {
  LocalKeeperHost._(this.home, this.env);

  final Directory home;
  final Map<String, String> env;

  String get work => '${home.path}/work';

  static Future<LocalKeeperHost> create() async {
    final home = Directory.systemTemp.createTempSync('session_open_bench_');
    final bin = Directory('${home.path}/bin')..createSync();
    Directory('${home.path}/work').createSync();
    final agent = File('benchmark/support/bench_acp_agent.py').absolute.path;
    if (!File(agent).existsSync()) throw StateError('run from app/: $agent is missing');
    final omp = File('${bin.path}/omp')..writeAsStringSync('#!/bin/sh\nexec python3 \'$agent\' "\$@"\n');
    await Process.run('chmod', ['755', omp.path]);
    final host = LocalKeeperHost._(home, {
      'HOME': home.path,
      'PATH': '${bin.path}:/usr/bin:/bin:/usr/local/bin',
    });
    await host.install();
    return host;
  }

  Future<({String out, String err, int code})> run(String command, {String input = '', Map<String, String> extraEnv = const {}}) async {
    final p = await Process.start(
      '/bin/sh',
      ['-c', command],
      environment: {...env, ...extraEnv},
      includeParentEnvironment: false,
      workingDirectory: home.path,
    );
    p.stdin.write(input);
    await p.stdin.close();
    final out = utf8.decodeStream(p.stdout);
    final err = utf8.decodeStream(p.stderr);
    final code = await p.exitCode.timeout(const Duration(seconds: 120));
    return (out: await out, err: await err, code: code);
  }

  Future<void> install() async {
    final r = await run(keeperInstallCommand(), input: keeperInstallPayload());
    if (r.code != 0 || r.out.trim() != '{"ok":true}') throw StateError('keeper install failed: ${r.err}');
  }

  /// Starts a keeper whose agent plays [seedFile] on its first prompt.
  @override
  Future<KeeperInfo> start({required String agent, required String cwd, String? seedFile}) async {
    final r = await run(keeperStartCommand(agent: agent, cwd: cwd), extraEnv: {'BENCH_SEED': ?seedFile});
    if (r.code != 0) throw StateError('keeper start failed (${r.code}): ${r.err}');
    return KeeperInfo.fromJson((jsonDecode(r.out) as Map).cast<String, Object?>());
  }

  @override
  Future<Set<String>> available() async => {'omp'};

  @override
  Future<List<KeeperInfo>> list() async {
    final r = await run(keeperListCommand());
    if (r.code != 0) throw StateError('keeper list failed: ${r.err}');
    return [for (final j in jsonDecode(r.out) as List) KeeperInfo.fromJson((j as Map).cast<String, Object?>())];
  }

  /// A `Process` running the attach command, like the SSH exec channel does.
  Future<Process> attachProcess(String id) => Process.start(
    '/bin/sh',
    ['-c', keeperAttachCommand(id)],
    environment: env,
    includeParentEnvironment: false,
    workingDirectory: home.path,
  );

  @override
  Future<AcpTransport> attach(String keeperId) => ProcessTransport.start(
    '/bin/sh',
    ['-c', keeperAttachCommand(keeperId)],
    environment: env,
    workingDirectory: home.path,
  );

  @override
  Future<void> kill(String keeperId) async {
    await run(keeperKillCommand(keeperId));
  }

  @override
  Future<PastSessions> history({required String agent, String? cwd}) async {
    final r = await run(keeperHistoryCommand(agent: agent, cwd: cwd));
    if (r.code != 0) throw StateError('keeper history failed (${r.code}): ${r.err}');
    return PastSessions.fromJson((jsonDecode(r.out) as Map).cast<String, Object?>());
  }

  Future<void> dispose() async {
    try {
      for (final k in await list()) {
        await kill(k.id);
      }
    } on Object {
      // best effort: the temp home goes away next
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

/// [LocalKeeperHost] seen through [link]: an attach costs what an SSH exec
/// channel costs (channel open, then the exec request answered: two round
/// trips, the command starting after one and a half), everything after it the
/// transport's delays.
class LinkedHost implements AgentHost {
  LinkedHost(this.inner, this.link);

  final LocalKeeperHost inner;
  final LinkModel link;

  @override
  Future<AcpTransport> attach(String keeperId) async {
    if (link == LinkModel.local) return inner.attach(keeperId);
    await Future<void>.delayed(link.rtt + link.oneWay); // the exec request reaches the host
    final transport = await inner.attach(keeperId);
    await Future<void>.delayed(link.oneWay); // and its answer reaches the phone
    return LinkedTransport(transport, link);
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
