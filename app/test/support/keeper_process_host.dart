import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/acp/json_rpc.dart' show AcpTransport;
import 'package:herdr_mobile/data/acp/past_session.dart';
import 'package:herdr_mobile/data/acp/process_transport.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart';

/// An [AgentHost] over the REAL keeper script (python3) and the scripted agent
/// `test/support/fake_acp_agent.py`, run as local processes the way an SSH
/// server would run them (`sh -c`), with HOME in a temp directory so nothing
/// touches the real home. The agent `omp` is a wrapper on PATH; the keepers
/// live under that temp HOME only.
///
/// For tests that need the phone's session objects and the keeper's log
/// together, in real time (the keeper is a separate process).
///
/// The agent's own store (what `history` lists and `session/load` replays in a
/// NEW keeper) is switched on with [useAgentStore], which sets the
/// `FAKE_ACP_STORE`, `FAKE_ACP_PAGE` and `FAKE_ACP_CAPS` environment of
/// `fake_acp_agent.py`; other switches of that file (`FAKE_ACP_LIST_FAIL`,
/// `FAKE_ACP_LIST_DELAY`, `FAKE_ACP_LIST_NOISE`, `FAKE_ACP_IGNORE_TERM`, ...)
/// are set in [env] before the command runs. [agentRuns] lists the fake agent
/// processes that were started.
class KeeperProcessHost implements AgentHost {
  KeeperProcessHost._(this.home, this.env, this.busyFile);

  final Directory home;
  final Map<String, String> env;

  /// While this file exists the fake agent is busy with a turn of its own and
  /// answers every prompt `-32003` (see `fake_acp_agent.py`).
  final File busyFile;

  final _transports = <ProcessTransport>[];

  String get work => '${home.path}/work';

  static Future<KeeperProcessHost> create() async {
    final home = Directory.systemTemp.createTempSync('keeper_host_');
    final bin = Directory('${home.path}/bin')..createSync();
    Directory('${home.path}/work').createSync();
    final fake = File('test/support/fake_acp_agent.py').absolute.path;
    expect(File(fake).existsSync(), isTrue, reason: fake);
    final omp = File('${bin.path}/omp')
      ..writeAsStringSync('#!/bin/sh\nexec python3 \'$fake\' "\$@"\n');
    await Process.run('chmod', ['755', omp.path]);
    var python = '/usr/bin';
    for (final d in [
      '/usr/bin',
      '/bin',
      '/usr/local/bin',
      '/opt/homebrew/bin',
    ]) {
      if (File('$d/python3').existsSync()) {
        python = d;
        break;
      }
    }
    final busy = File('${home.path}/busy');
    final host = KeeperProcessHost._(home, {
      'HOME': home.path,
      'PATH': '${bin.path}:$python:/usr/bin:/bin',
      'FAKE_ACP_LOG': '${home.path}/agent.jsonl',
      'FAKE_ACP_BUSY_FILE': busy.path,
      'FAKE_ACP_PID_FILE': '${home.path}/agent.pids',
    }, busy);
    await host._run(keeperInstallCommand(), input: keeperInstallPayload());
    return host;
  }

  /// The agent is busy with its own work (omp's autonomous turn) or free again.
  set busy(bool value) {
    if (value) {
      busyFile.writeAsStringSync('busy');
    } else if (busyFile.existsSync()) {
      busyFile.deleteSync();
    }
  }

  /// What reached the agent, in order (`session/prompt` texts only).
  List<String> promptsSeenByAgent() {
    final f = File(env['FAKE_ACP_LOG']!);
    if (!f.existsSync()) return [];
    final out = <String>[];
    for (final l in f.readAsLinesSync()) {
      if (l.trim().isEmpty) continue;
      final m = (jsonDecode(l) as Map)['recv'] as Map;
      if (m['method'] != 'session/prompt') continue;
      final blocks = (m['params'] as Map)['prompt'] as List;
      out.add([for (final b in blocks) (b as Map)['text'] ?? ''].join());
    }
    return out;
  }

  Future<String> _run(String command, {String input = ''}) async {
    final p = await Process.start(
      '/bin/sh',
      ['-c', command],
      environment: env,
      includeParentEnvironment: false,
      workingDirectory: home.path,
    );
    p.stdin.write(input);
    await p.stdin.close();
    final out = utf8.decodeStream(p.stdout);
    final err = utf8.decodeStream(p.stderr);
    final code = await p.exitCode.timeout(const Duration(seconds: 60));
    final stderr = await err;
    if (code != 0) throw AgentHostException('exit $code: $stderr', fatal: true);
    return out;
  }

  @override
  Future<Set<String>> available() async => {'omp'};

  @override
  Future<List<KeeperInfo>> list() async => [
    for (final j in jsonDecode(await _run(keeperListCommand())) as List)
      KeeperInfo.fromJson(Map<String, Object?>.from(j as Map)),
  ];

  @override
  Future<KeeperInfo> start({
    required String agent,
    required String cwd,
  }) async => KeeperInfo.fromJson(
    Map<String, Object?>.from(
      jsonDecode(await _run(keeperStartCommand(agent: agent, cwd: cwd))) as Map,
    ),
  );

  /// What the fake agent remembers (`FAKE_ACP_STORE`, see `fake_acp_agent.py`):
  /// it survives every agent process, like omp's session folder. The agent
  /// uses it once [useAgentStore] is called (before the first `start`/`history`).
  File get agentStore => File('${home.path}/agent_store.json');

  /// The pid and folder of every fake agent that answered `initialize`, in order.
  List<({int pid, String cwd})> get agentRuns {
    final f = File(env['FAKE_ACP_PID_FILE']!);
    if (!f.existsSync()) return [];
    return [
      for (final l in f.readAsLinesSync())
        if (l.trim().isNotEmpty) (pid: int.parse(l.split('\t').first), cwd: l.split('\t').last),
    ];
  }

  /// The `history` command as a running process, for a test that signals it.
  Future<Process> historyProcess({required String agent, String? cwd}) => Process.start(
    '/bin/sh',
    ['-c', keeperHistoryCommand(agent: agent, cwd: cwd)],
    environment: env,
    includeParentEnvironment: false,
    workingDirectory: home.path,
  );

  /// The raw stdout lines of the `history` command.
  Future<List<String>> historyLines({required String agent, String? cwd}) async =>
      const LineSplitter().convert(await _run(keeperHistoryCommand(agent: agent, cwd: cwd)));

  /// Turns the agent's store on: it lists, loads and resumes. [sessions] are
  /// written to the store file (`{sessionId, cwd, title?, updatedAt?,
  /// messageCount?, updates?}`); [page] is the page size of `session/list`.
  void useAgentStore({List<Map<String, Object?>> sessions = const [], int? page, String? caps}) {
    agentStore.writeAsStringSync(jsonEncode({'sessions': sessions}));
    env['FAKE_ACP_STORE'] = agentStore.path;
    if (page != null) env['FAKE_ACP_PAGE'] = '$page';
    if (caps != null) env['FAKE_ACP_CAPS'] = caps;
  }

  @override
  Future<PastSessions> history({required String agent, String? cwd}) async => PastSessions.fromJson(
    Map<String, Object?>.from(
      jsonDecode(await _run(keeperHistoryCommand(agent: agent, cwd: cwd))) as Map,
    ),
  );

  /// How many channels were opened to keepers.
  int get attachCount => _transports.length;

  /// The phone's links all die at once (the SSH connection dropped); the
  /// keepers live on.
  Future<void> dropLinks() => Future.wait([
    for (final t in _transports)
      t
          .close(grace: const Duration(milliseconds: 500))
          .catchError((Object _) {}),
  ]);

  @override
  Future<AcpTransport> attach(String keeperId) async {
    final t = await ProcessTransport.start(
      '/bin/sh',
      ['-c', keeperAttachCommand(keeperId)],
      environment: env,
      workingDirectory: home.path,
    );
    _transports.add(t);
    return t;
  }

  @override
  Future<void> kill(String keeperId) async {
    await _run(keeperKillCommand(keeperId));
  }

  /// Ends every keeper this host started (their agents with them) and removes
  /// the temp HOME.
  Future<void> dispose() async {
    for (final t in _transports) {
      unawaited(
        t
            .close(grace: const Duration(milliseconds: 200))
            .catchError((Object _) {}),
      );
    }
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
