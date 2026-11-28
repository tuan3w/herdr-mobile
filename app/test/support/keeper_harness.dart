import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/app_info.dart';
import 'package:herdr_mobile/data/host/host_channels.dart';
import 'package:herdr_mobile/data/host/host_link.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart';
import 'package:herdr_mobile/data/services/ssh_agent_host.dart';

import 'process_host.dart';

// Runs the real keeper (the `herdr-host` binary) against a scripted ACP agent
// (`fake-acp-agent` of `rust/crates/testkit`). The phone path is the app's own:
// `herdr-host serve` under the app's command (`hostServeCommand`), a `HostLink`
// on it, and the real `SshAgentHost` over that link. Every command is run the
// way an SSH server would run it (`sh -c`), with HOME in a temp directory so
// nothing touches the real home, and the agent `omp` is a wrapper on PATH. No
// python is involved anywhere.

typedef Json = Map<String, Object?>;

Json asJson(Object? v) => (v as Map).cast<String, Object?>();

/// The prebuilt `herdr-host` binary the tests install into their temp homes.
/// `$HERDR_HOST_BIN` overrides the default (`../../rust/target/release/herdr-host`
/// from `app/`). CI builds it in the test job before `flutter test`.
File hostBinary() {
  final fromEnv = Platform.environment['HERDR_HOST_BIN'];
  if (fromEnv != null && fromEnv.isNotEmpty) return File(fromEnv);
  // `test/support/keeper_harness.dart` → up four → the repo root, whose
  // `rust/` is a sibling of `app/`.
  final root = File('test/support/keeper_harness.dart').absolute.parent.parent.parent.parent.absolute.path
      .replaceAll(r'\', '/');
  return File('$root/rust/target/release/herdr-host');
}

/// A binary of `rust/crates/testkit` (`fake-acp-agent`, ...): in
/// `$HERDR_TESTKIT_DIR`, else next to [hostBinary] (both are built by
/// `cargo build -p host -p testkit`). Fails the test when it is missing:
/// a missing fixture is never a reason to skip.
File testkitBinary(String name) {
  final fromEnv = Platform.environment['HERDR_TESTKIT_DIR'];
  final dir = fromEnv != null && fromEnv.isNotEmpty ? fromEnv : hostBinary().parent.path;
  final bin = File('$dir/$name');
  expect(
    bin.existsSync(),
    isTrue,
    reason:
        '$name not found at ${bin.path}; build it (cd rust && cargo build -p testkit) '
        'or set HERDR_TESTKIT_DIR',
  );
  return bin;
}

/// Writes the script a keeper's PATH finds as the agent [path] (`omp`, ...): it
/// runs `fake-acp-agent`, after [before] (shell lines) when given.
Future<void> writeAgentWrapper(String path, {String before = ''}) async {
  final fake = testkitBinary('fake-acp-agent').absolute.path.replaceAll("'", "'\\''");
  final wrapper = File(path)..writeAsStringSync("#!/bin/sh\n${before}exec '$fake' \"\$@\"\n");
  await Process.run('chmod', ['755', wrapper.path]);
}

/// The file name of the keeper on a host: one per app version, as
/// `tool/install-host.sh` names it and `keeper_command.dart` execs it.
const hostBinaryName = 'herdr-host-$appVersion';

/// Copies the prebuilt [hostBinary] into [home]'s `~/.herdr-mobile/bin/<hostBinaryName>`
/// (0700), the way `tool/install-host.sh` puts it on a real host. The temp home
/// starts empty, so there is nothing to rename over.
Future<void> installHostBinary(Directory home) async {
  final bin = hostBinary();
  expect(
    bin.existsSync(),
    isTrue,
    reason:
        'herdr-host not found at ${bin.path}; '
        'build it (cd rust && cargo build --release -p host) '
        'or set HERDR_HOST_BIN',
  );
  final dir = Directory('${home.path}/.herdr-mobile/bin')..createSync(recursive: true);
  final dest = File('${dir.path}/$hostBinaryName');
  dest.writeAsBytesSync(bin.readAsBytesSync());
  await Process.run('chmod', ['700', dest.path]);
}

Future<bool> processAlive(int pid) async => (await Process.run('kill', ['-0', '$pid'])).exitCode == 0;

/// Polls [check] until it holds; fails with [what] after [timeout].
Future<void> eventually(
  FutureOr<bool> Function() check, {
  String what = 'condition',
  Duration timeout = const Duration(seconds: 30),
}) async {
  final end = DateTime.now().add(timeout);
  while (!await check()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

bool Function(Json) isMethod(String name) =>
    (m) => m['method'] == name;

bool Function(Json) isUpdate(String kind) =>
    (m) => m['method'] == 'session/update' && asJson(asJson(m['params'])['update'])['sessionUpdate'] == kind;

/// The `update` objects of the `session/update` notifications in [messages].
List<Json> updatesOf(Iterable<Json> messages) => [
  for (final m in messages)
    if (m['method'] == 'session/update') asJson(asJson(m['params'])['update']),
];

String updateText(Json update) => (asJson(update['content'])['text'] ?? '') as String;

typedef Replay = ({Json load, List<Json> updates, int bytes});

/// One user message and what followed it in a replay.
class ReplayTurn {
  ReplayTurn(this.user);

  final String user;
  final tools = <Json>[];
  String? answer;
}

/// The replay cut at its user messages; whatever precedes the first one (a
/// turn whose start was lost) is a turn with an empty `user`.
List<ReplayTurn> turnsOf(List<Json> updates) {
  final turns = <ReplayTurn>[];
  for (final u in updates) {
    if (u['sessionUpdate'] == 'user_message_chunk') {
      turns.add(ReplayTurn(updateText(u)));
      continue;
    }
    if (turns.isEmpty) turns.add(ReplayTurn(''));
    switch (u['sessionUpdate']) {
      case 'tool_call' || 'tool_call_update':
        turns.last.tools.add(u);
      case 'agent_message_chunk':
        turns.last.answer = updateText(u);
    }
  }
  return turns;
}

/// `_meta.herdr` of the answer to `session/load`: what the keeper gave up.
Map<String, Object?> herdrMeta(Json loadResponse) => asJson(asJson(asJson(loadResponse['result'])['_meta'])['herdr']);

bool isTrimmed(Json update) =>
    update['_meta'] is Map &&
    asJson(update['_meta'])['herdr'] is Map &&
    asJson(asJson(update['_meta'])['herdr'])['trimmed'] == true;

typedef RunResult = ({String out, String err, int code});

class KeeperHost {
  KeeperHost._(this.home, this.env, this._root);

  final Directory home;
  final Directory _root;
  final Map<String, String> env;
  final clients = <KeeperAttach>[];

  // Every `herdr-host serve` this host started, one per link.
  final _serves = <ProcessHostProcess>[];
  HostLink? _link;
  Future<HostLink>? _linking;

  String get work => '${home.path}/work';
  String get keepers => '${home.path}/.herdr-mobile/keepers';

  /// [homeLeaf] names the home folder inside the temp directory (a hostile
  /// name, for the paths the keeper types into a shell).
  static Future<KeeperHost> create(Map<String, String> extra, {String? homeLeaf}) async {
    final temp = Directory.systemTemp.createTempSync('keeper_test_');
    final home = homeLeaf == null ? temp : (Directory('${temp.path}/$homeLeaf')..createSync());
    final bin = Directory('${home.path}/bin')..createSync();
    Directory('${home.path}/work').createSync();
    for (final binary in ['omp', 'codex-acp', 'claude-agent-acp', 'cursor-agent']) {
      await writeAgentWrapper('${bin.path}/$binary');
    }
    return KeeperHost._(home, {
      'HOME': home.path,
      'PATH': '${bin.path}:/usr/bin:/bin',
      'FAKE_ACP_LOG': '${home.path}/agent.jsonl',
      // A herdr on this machine must never get a pane from a test.
      'HERDR_MOBILE_NO_PANE': '1',
      // A test keeper stays a child of its starter: no launchd job on the
      // machine running the tests (one test turns this on).
      'HERDR_MOBILE_NO_LAUNCHD': '1',
      ...extra,
    }, temp);
  }

  /// A raw shell command, the way an SSH server would run it: for what is still
  /// a command (the installer, the serve command's exit 65).
  Future<RunResult> run(String command, {String input = '', Map<String, String> environment = const {}}) async {
    final p = await Process.start(
      '/bin/sh',
      ['-c', command],
      environment: {...env, ...environment},
      includeParentEnvironment: false,
      workingDirectory: home.path,
    );
    p.stdin.write(input);
    await p.stdin.close();
    final out = utf8.decodeStream(p.stdout);
    final err = utf8.decodeStream(p.stderr);
    final code = await p.exitCode.timeout(const Duration(seconds: 60));
    return (out: await out, err: await err, code: code);
  }

  /// Installs the keeper the way the phone does: the `herdr-host` binary at
  /// `~/.herdr-mobile/bin/herdr-host-<appVersion>` (the phone fetches it from
  /// the release; the test copies the prebuilt one, `installHostBinary`).
  Future<void> install() async {
    await installHostBinary(home);
  }

  // ---- the host link: what the app talks to ----

  /// A new `herdr-host serve` as an SSH server would run the app's command
  /// (`hostServeCommand`), with [umask] applied to the login shell first.
  Future<ProcessHostProcess> _serve({String? umask}) async {
    final command = hostServeCommand();
    final p = await ProcessHostProcess.start(
      '/bin/sh',
      ['-c', umask == null ? command : 'umask $umask; $command'],
      environment: env,
      workingDirectory: home.path,
    );
    _serves.add(p);
    return p;
  }

  /// A new link to a new `serve` process (its own channel, like another phone).
  Future<HostLink> openLink({String? umask}) async => HostLink.connect(
    await _serve(umask: umask),
    version: appVersion,
    helloTimeout: const Duration(seconds: 30),
  );

  /// The shared link, opened on first use and again after it died.
  Future<HostLink> link() {
    final live = _link;
    if (live != null && live.isOpen) return Future.value(live);
    return _linking ??= openLink().then((l) => _link = l).whenComplete(() => _linking = null);
  }

  /// The shared link dies without a word: its `serve` is killed outright (the
  /// keepers live on).
  void dropLink() {
    for (final p in _serves) {
      p.kill();
    }
  }

  /// What the app has of this machine: the real [SshAgentHost] over [link].
  late final LinkTransport transport = LinkTransport(link);
  late final SshAgentHost agentHost = SshAgentHost(transport, quickTimeout: const Duration(seconds: 30));

  /// `keeper.[method]` as a command's result: the answer is [RunResult.out],
  /// a failure's words are [RunResult.err] and its code is the exit status the
  /// keeper's command line ends with (64, 66, 67, 69, 70; -1: link lost).
  Future<RunResult> _call(HostLink link, String method, Json args, {Duration? timeout}) async {
    try {
      final r = await link.call('keeper', method, args, timeout ?? const Duration(seconds: 180));
      return (out: '${jsonEncode(r)}\n', err: '', code: 0);
    } on HostException catch (e) {
      return (out: '', err: e.message, code: exitStatusOf(HostEnd(error: e)) ?? -1);
    }
  }

  /// `start` on a link of its own, as a result: for tests that look at the
  /// failure's words and code. [umask] is the login shell's.
  Future<RunResult> runStart({String agent = 'omp', String? cwd, String? umask}) async {
    final l = await openLink(umask: umask);
    try {
      return await _call(l, 'start', {'agent': agent, 'cwd': cwd ?? work});
    } finally {
      unawaited(l.close());
    }
  }

  /// A `start` that is not waited for: for tests that look at the keeper while
  /// its agent is still initialising. Killing [KeeperRunning.process] is the
  /// phone going away mid-start.
  Future<KeeperRunning> startInBackground({String agent = 'omp'}) async {
    final serve = await _serve();
    final l = await HostLink.connect(serve, version: appVersion, helloTimeout: const Duration(seconds: 30));
    return KeeperRunning(serve.process, _call(l, 'start', {'agent': agent, 'cwd': work}));
  }

  Future<KeeperInfo> start({String agent = 'omp', String? cwd}) => agentHost.start(agent: agent, cwd: cwd ?? work);

  Future<List<Json>> rawList() async {
    final rows = await (await link()).call('keeper', 'list');
    return [for (final j in rows! as List) asJson(j)];
  }

  Future<List<KeeperInfo>> list() async => [for (final j in await rawList()) KeeperInfo.fromJson(j)];

  /// What reached the agent, in order.
  List<Json> agentLog() {
    final f = File(env['FAKE_ACP_LOG']!);
    if (!f.existsSync()) return [];
    return [
      for (final l in f.readAsLinesSync())
        if (l.trim().isNotEmpty) asJson(asJson(jsonDecode(l))['recv']),
    ];
  }

  /// A client of a keeper (a phone), on a link of its own.
  Future<KeeperAttach> attach(String id) async {
    final l = await openLink();
    final a = KeeperAttach.stream(l.open('keeper', 'attach', {'id': id}, true), l);
    clients.add(a);
    return a;
  }

  /// An attach that detaches at once (stdin closed), as a result: its exit
  /// status says whether the keeper took it (0) or refused (66, 67, ...).
  Future<RunResult> attachAndLeave(String id) async {
    final l = await openLink();
    final channel = HostLineChannel(l.open('keeper', 'attach', {'id': id}, true));
    try {
      final lines = <String>[];
      final sub = channel.lines.listen(lines.add, onError: (Object _) {});
      await channel.closeInput();
      final code = await channel.exitCode.timeout(const Duration(seconds: 30));
      await sub.cancel();
      return (out: lines.join('\n'), err: channel.stderrTail, code: code ?? -1);
    } finally {
      unawaited(l.close());
    }
  }

  /// `kill ID` for this host.
  Future<RunResult> kill(String id) async => _call(await link(), 'kill', {'id': id});

  Future<void> dispose() async {
    for (final a in clients) {
      a.kill();
    }
    try {
      for (final j in await rawList()) {
        await kill(j['id']! as String);
      }
    } on Object {
      // best effort: the temp home goes away next
    }
    for (final p in _serves) {
      p.close();
    }
    try {
      _root.deleteSync(recursive: true);
    } on Object {
      // a keeper still writing its record: the OS temp cleaner takes it
    }
  }
}

/// A `start` that was not waited for: [finished] completes with its result;
/// [process] is the `serve` that carries it.
class KeeperRunning {
  KeeperRunning(this.process, this.finished);

  final Process process;
  final Future<RunResult> finished;
}

/// The phone's side of `attach`: a link whose lines are parsed.
class KeeperAttach {
  KeeperAttach._({
    required Stream<String> lines,
    required this.writeRaw,
    required this.closeInput,
    required this.exit,
    required this.kill,
  }) {
    lines.listen((l) {
      if (l.trim().isNotEmpty) seen.add(asJson(jsonDecode(l)));
    });
  }

  /// An attach stream of [link] (closed with it).
  factory KeeperAttach.stream(HostStream stream, HostLink link) {
    final channel = HostLineChannel(stream);
    final a = KeeperAttach._(
      lines: channel.lines,
      writeRaw: (text) => unawaited(stream.write(Uint8List.fromList(utf8.encode(text))).catchError((Object _) {})),
      closeInput: channel.closeInput,
      exit: channel.exitCode.then((code) => code ?? -1),
      kill: () {
        unawaited(channel.close().catchError((Object _) {}));
        unawaited(link.close());
      },
    );
    unawaited(channel.exitCode.then((_) => a.stderr.write(channel.stderrTail)));
    return a;
  }

  /// Writes [text] to the keeper as it is (no newline added).
  final void Function(String text) writeRaw;

  /// Ends the client's direction (a detach).
  final Future<void> Function() closeInput;

  /// The connection drops without a word.
  final void Function() kill;
  final seen = <Json>[];
  final stderr = StringBuffer();

  /// Exit status: 0 done, 66 no such keeper, 67 its agent exited, ... -1 the
  /// link was lost.
  final Future<int> exit;
  var _cursor = 0;
  var _nextId = 0;

  /// The next message at or after the cursor that satisfies [test]; messages
  /// skipped on the way stay in [seen].
  Future<Json> next(bool Function(Json) test, {Duration timeout = const Duration(seconds: 30)}) async {
    final end = DateTime.now().add(timeout);
    while (true) {
      while (_cursor < seen.length) {
        final m = seen[_cursor++];
        if (test(m)) return m;
      }
      if (DateTime.now().isAfter(end)) {
        throw TimeoutException('no matching message; seen: ${jsonEncode(seen)}; stderr: $stderr');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  void write(Json message) => writeRaw('${jsonEncode({'jsonrpc': '2.0', ...message})}\n');

  /// Sends a request and returns its id.
  int post(String method, [Json params = const {}]) {
    final id = ++_nextId;
    write({'id': id, 'method': method, 'params': params});
    return id;
  }

  Future<Json> response(int id, {Duration timeout = const Duration(seconds: 30)}) =>
      next((m) => !m.containsKey('method') && m['id'] == id, timeout: timeout);

  Future<Json> request(String method, [Json params = const {}]) => response(post(method, params));

  void reply(Object? id, Json result) => write({'id': id, 'result': result});

  Future<Json> initialize({String? title, bool viewer = false, String? pane}) => request('initialize', {
    'protocolVersion': 1,
    'clientCapabilities': <String, Object?>{},
    if (title != null) 'clientInfo': {'name': 'test-client', 'title': title, 'version': '1'},
    if (viewer || pane != null)
      '_meta': {
        'herdr': {'viewer': viewer, 'pane': ?pane},
      },
  });

  Future<Json> newSession(KeeperHost h) => request('session/new', {'cwd': h.work, 'mcpServers': <Object?>[]});

  Future<Json> load(KeeperHost h, {String sessionId = 'sess-1', Duration timeout = const Duration(seconds: 30)}) =>
      response(
        post('session/load', {'sessionId': sessionId, 'cwd': h.work, 'mcpServers': <Object?>[]}),
        timeout: timeout,
      );

  int prompt(String text) => post('session/prompt', {
    'sessionId': 'sess-1',
    'prompt': [
      {'type': 'text', 'text': text},
    ],
  });

  /// Closes stdin (a detach) and returns the exit code.
  Future<int> close() async {
    await closeInput();
    return exit.timeout(const Duration(seconds: 30));
  }
}
