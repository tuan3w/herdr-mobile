import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/acp/json_rpc.dart' show AcpTransport;
import 'package:herdr_mobile/data/acp/past_session.dart';
import 'package:herdr_mobile/data/app_info.dart';
import 'package:herdr_mobile/data/host/host_link.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart';
import 'package:herdr_mobile/data/services/ssh_agent_host.dart';

import 'keeper_harness.dart';
import 'process_host.dart';

/// An [AgentHost] over the REAL keeper (the `herdr-host` binary) and the
/// scripted agent `fake-acp-agent` (`rust/crates/testkit`), the way the app reaches
/// them: `herdr-host serve` started by the app's own command under `sh -c` (as
/// an SSH server would run it), a [HostLink] on it, and the real
/// [SshAgentHost] over that link. HOME is a temp directory so nothing touches
/// the real home. The agent `omp` is a wrapper on PATH; the keepers live under
/// that temp HOME only.
///
/// For tests that need the phone's session objects and the keeper's log
/// together, in real time (the keeper is a separate process).
///
/// The agent's own store (what `history` lists and `session/load` replays in a
/// NEW keeper) is switched on with [useAgentStore], which sets the
/// `FAKE_ACP_STORE`, `FAKE_ACP_PAGE` and `FAKE_ACP_CAPS` variables of the
/// testkit agent (see its README); other switches (`FAKE_ACP_LIST_FAIL`,
/// `FAKE_ACP_LIST_DELAY`, `FAKE_ACP_LIST_NOISE`, `FAKE_ACP_IGNORE_TERM`, ...)
/// are set in [env] before the first call, which starts `serve` (the agent
/// inherits `serve`'s environment). [agentRuns] lists the fake agent
/// processes that were started.
class KeeperProcessHost implements AgentHost {
  KeeperProcessHost._(this.home, this.env, this.busyFile);

  final Directory home;
  final Map<String, String> env;

  /// While this file exists the fake agent is busy with a turn of its own and
  /// answers every prompt `-32003` (see the testkit README).
  final File busyFile;

  final _serves = <ProcessHostProcess>[];
  HostLink? _link;
  Future<HostLink>? _linking;
  var _attaches = 0;

  late final SshAgentHost _app = SshAgentHost(LinkTransport(link), quickTimeout: const Duration(seconds: 30));

  String get work => '${home.path}/work';

  static Future<KeeperProcessHost> create() async {
    final home = Directory.systemTemp.createTempSync('keeper_host_');
    final bin = Directory('${home.path}/bin')..createSync();
    Directory('${home.path}/work').createSync();
    await writeAgentWrapper('${bin.path}/omp');
    final busy = File('${home.path}/busy');
    final host = KeeperProcessHost._(home, {
      'HOME': home.path,
      'PATH': '${bin.path}:/usr/bin:/bin',
      'FAKE_ACP_LOG': '${home.path}/agent.jsonl',
      'FAKE_ACP_BUSY_FILE': busy.path,
      'FAKE_ACP_PID_FILE': '${home.path}/agent.pids',
      // A herdr on this machine must never get a pane from a test.
      'HERDR_MOBILE_NO_PANE': '1',
    }, busy);
    await installHostBinary(home);
    return host;
  }

  /// The machine's one link, opened on first use and again after it died (the
  /// way the app's transport reconnects).
  Future<HostLink> link() {
    final live = _link;
    if (live != null && live.isOpen) return Future.value(live);
    return _linking ??= _connect().then((l) => _link = l).whenComplete(() => _linking = null);
  }

  Future<HostLink> _connect() async {
    final serve = await ProcessHostProcess.start(
      '/bin/sh',
      ['-c', hostServeCommand()],
      environment: env,
      workingDirectory: home.path,
    );
    _serves.add(serve);
    return HostLink.connect(serve, version: appVersion, helloTimeout: const Duration(seconds: 30));
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

  @override
  Future<Set<String>> available() async => {'omp'};

  @override
  Future<List<KeeperInfo>> list() => _app.list();

  @override
  Future<KeeperInfo> start({required String agent, required String cwd}) => _app.start(agent: agent, cwd: cwd);

  /// What the fake agent remembers (`FAKE_ACP_STORE`, see the testkit README):
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

  /// The `history` call as a stream that is still running, for a test that
  /// resets it (the phone gave up waiting).
  Future<HostStream> openHistory({required String agent, String? cwd}) async =>
      (await link()).open('keeper', 'history', {'agent': agent, 'cwd': ?cwd});

  /// What the host answered to `history`, as it is (the object `herdr-host
  /// history` prints).
  Future<Map<String, Object?>> historyObject({required String agent, String? cwd}) async {
    final answer = await (await link()).call('keeper', 'history', {
      'agent': agent,
      'cwd': ?cwd,
    }, const Duration(seconds: 60));
    return asJson(answer);
  }

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
  Future<PastSessions> history({required String agent, String? cwd}) => _app.history(agent: agent, cwd: cwd);

  /// How many attaches were opened to keepers.
  int get attachCount => _attaches;

  /// The phone's link dies (the SSH connection dropped): `serve` is killed
  /// outright and every attach ends without a status; the keepers live on. The
  /// next call opens a new link.
  Future<void> dropLinks() async {
    final live = _link;
    for (final p in _serves) {
      p.kill();
    }
    if (live != null) await live.closed;
  }

  @override
  Future<AcpTransport> attach(String keeperId) {
    _attaches++;
    return _app.attach(keeperId);
  }

  @override
  Future<void> kill(String keeperId) => _app.kill(keeperId);

  /// Ends every keeper this host started (their agents with them) and removes
  /// the temp HOME.
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
