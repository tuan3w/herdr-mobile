import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/acp/zipped_lines.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart';

// Runs the real keeper script (python3) against a scripted ACP agent
// (`test/support/fake_acp_agent.py`). Every command is run the way an SSH
// server would run it (`sh -c`), with HOME in a temp directory so nothing
// touches the real home, and the agent `omp` is a wrapper on PATH.

typedef Json = Map<String, Object?>;

Json asJson(Object? v) => (v as Map).cast<String, Object?>();

String? pythonDir() {
  for (final d in ['/usr/bin', '/bin', '/usr/local/bin', '/opt/homebrew/bin']) {
    if (File('$d/python3').existsSync()) return d;
  }
  return null;
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

bool isTrimmed(Json update) => update['_meta'] is Map && asJson(update['_meta'])['herdr'] is Map && asJson(asJson(update['_meta'])['herdr'])['trimmed'] == true;

/// Loads the keeper script as a module and exercises `ReplayLog.remove`, the
/// way the keeper takes back the message of a prompt the agent refused.
const removeProbe = r'''
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("keeper", sys.argv[1])
k = importlib.util.module_from_spec(spec)
spec.loader.exec_module(k)

def msg(su, **kw):
    u = {"sessionUpdate": su}
    u.update(kw)
    return {"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s", "update": u}}

def add(log, m):
    return log.add(m, len(json.dumps(m)), lambda: set())

def user(log, text, mid):
    return add(log, msg("user_message_chunk", content={"type": "text", "text": text}, messageId=mid))

def agent(log, text, mid):
    return add(log, msg("agent_message_chunk", content={"type": "text", "text": text}, messageId=mid))

def tally(log):
    # The counters against what the turns really hold.
    es = [e for t in log.turns.values() for e in t.e]
    return {
        "turns": len(log.turns),
        "bytesOk": log.bytes == sum(e["n"] for e in es) and all(t.n == sum(e["n"] for e in t.e) for t in log.turns.values()),
        "countOk": log.count == len(es),
        "texts": [e["o"]["params"]["update"]["content"]["text"] for e in es],
        "lastOk": (log.last is None and not log.turns) or log.last is list(log.turns.values())[-1],
    }

out = {}

# Refused attempts after a finished turn: the agent's own output streamed in
# between ends up in the turn before, not in a turn of its own.
log = k.ReplayLog(1 << 20, 100, 3)
user(log, "first", "m1")
agent(log, "answer", "a1")
for i in range(3):
    e = user(log, "again", "k%d" % i)
    agent(log, "own %d" % i, "o%d" % i)
    assert log.remove(e)
    assert not log.remove(e)
out["refused"] = tally(log)

# A turn whose only entry is the refused message disappears.
log = k.ReplayLog(1 << 20, 100, 3)
e = user(log, "alone", "m1")
assert log.remove(e)
out["alone"] = tally(log)
user(log, "after", "m2")
out["aloneThenAdd"] = tally(log)

# A message of two blocks is one entry; it goes whole.
log = k.ReplayLog(1 << 20, 100, 3)
agent(log, "before", "a0")
e1 = user(log, "one ", "m1")
e2 = user(log, "two", "m1")
out["sameEntry"] = e1 is e2
agent(log, "reply", "a1")
assert log.remove(e1)
out["twoBlocks"] = tally(log)

# An entry the log already dropped is not found, and nothing moves.
log = k.ReplayLog(1 << 20, 100, 3)
user(log, "x", "m1")
agent(log, "y", "a1")
ghost = {"o": msg("user_message_chunk", content={"type": "text", "text": "gone"}, messageId="g"), "n": 99}
before = (log.bytes, log.count)
out["ghost"] = [log.remove(ghost), (log.bytes, log.count) == before]

# Under the entry bound: refused attempts (no output of the agent's own) do
# not eat the room of real turns.
log = k.ReplayLog(1 << 20, 12, 3)
for i in range(4):
    user(log, "q%d" % i, "m%d" % i)
    agent(log, "a%d" % i, "a%d" % i)
for i in range(40):
    e = user(log, "again", "k%d" % i)
    log.remove(e)
out["bounded"] = tally(log)
out["boundedDropped"] = log.dropped
print(json.dumps(out))
''';

/// Loads the keeper script as a module and drives `ReplayLog` directly.
const logProbe = r'''
import importlib.util, json, sys, time
spec = importlib.util.spec_from_file_location("keeper", sys.argv[1])
k = importlib.util.module_from_spec(spec)
spec.loader.exec_module(k)

def msg(su, **kw):
    u = {"sessionUpdate": su}
    u.update(kw)
    return {"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s", "update": u}}

def add(log, m, waiting=lambda: set()):
    log.add(m, len(json.dumps(m)), waiting)

def user(log, i, waiting=lambda: set()):
    add(log, msg("user_message_chunk", content={"type": "text", "text": "u%d" % i}, messageId="m%d" % i), waiting)

def call(log, i, tool, waiting=lambda: set(), size=8000, status="completed"):
    add(log, msg("tool_call", toolCallId=tool, title="t", status="pending", kind="execute"), waiting)
    add(log, msg("tool_call_update", toolCallId=tool, status=status, rawOutput="x" * size), waiting)

def answer(log, i, waiting=lambda: set()):
    add(log, msg("agent_message_chunk", content={"type": "text", "text": "a%d" % i}, messageId="a%d" % i), waiting)

out = {}

# A request waits on a tool call of the oldest turn: it stays whole.
log = k.ReplayLog(30000, 100000, 1)
hold = lambda: {"old"}
user(log, 0, hold)
call(log, 0, "old", hold, status="in_progress")
for i in range(1, 31):
    user(log, i, hold)
    call(log, i, "t%d" % i, hold)
    answer(log, i, hold)
es = list(log.entries())
users = [e["o"]["params"]["update"]["content"]["text"] for e in es if e["o"]["params"]["update"]["sessionUpdate"] == "user_message_chunk"]
out["pinned"] = {
    "oldKept": "u0" in users,
    "oldHasRaw": any("rawOutput" in e["o"]["params"]["update"] and e["o"]["params"]["update"]["toolCallId"] == "old" for e in es),
    "otherDropped": log.dropped,
    "newestKept": "u30" in users,
    "bytes": log.bytes,
}

# State a dropped turn held (the mode, the commands) still reaches a replay,
# whether the turn goes whole (3000-byte calls) or is eaten from the front
# because it is the newest and over the bounds by itself (8000-byte calls).
def carried(size):
    log = k.ReplayLog(5000, 100000, 1)
    user(log, 0)
    add(log, msg("current_mode_update", currentModeId="plan"))
    add(log, msg("available_commands_update", availableCommands=[{"name": "x", "description": "y"}]))
    call(log, 0, "c0", size=size)
    answer(log, 0)
    for i in range(1, 30):
        user(log, i)
        call(log, i, "c%d" % i, size=size)
        answer(log, i)
    es = list(log.entries())
    kinds = [e["o"]["params"]["update"]["sessionUpdate"] for e in es]
    return {
        "carry": sorted(set(x for x in kinds if x.endswith("_update") and not x.startswith("tool"))),
        "mode": [e["o"]["params"]["update"]["currentModeId"] for e in es if e["o"]["params"]["update"]["sessionUpdate"] == "current_mode_update"],
        "first": kinds[0],
        "dropped": log.dropped,
        "bytes": log.bytes,
    }

out["carryWhole"] = carried(3000)
out["carryCut"] = carried(8000)

# Turns so heavy that the newest three alone pass the soft budget: the older
# ones among them are cut too (never the newest), rather than turns of the
# conversation dropped.
log = k.ReplayLog(4 * 1024 * 1024, 4000, 3, 1536 * 1024)
for i in range(12):
    user(log, i)
    for j in range(28):
        call(log, i, "f%d-%d" % (i, j), size=60000)
    answer(log, i)
es = list(log.entries())
users = [e for e in es if e["o"]["params"]["update"]["sessionUpdate"] == "user_message_chunk"]
newest = [e["o"]["params"]["update"] for e in es if e["o"]["params"]["update"].get("toolCallId", "").startswith("f11-")]
out["fat"] = {
    "users": len(users),
    "dropped": log.dropped,
    "newestRaw": sum(1 for u in newest if "rawOutput" in u),
    "bytes": log.bytes,
}

# The soft budget, 600 heavy turns (140 KB each): every turn stays, only the
# newest is whole, the replay is skeletons plus one turn, and the cursor to
# the oldest untrimmed turn never goes back.
log = k.ReplayLog(64 * 1024 * 1024, 100000, 3, 1536 * 1024)
t0 = time.time()
for i in range(600):
    user(log, i)
    for j in range(28):
        call(log, i, "s%d-%d" % (i, j), size=5000)
    answer(log, i)
out["soft"] = {
    "seconds": time.time() - t0,
    "turns": len(log.turns),
    "dropped": log.dropped,
    "trimmed": log.trimmed,
    "bytes": log.bytes,
    "newestBytes": log.last.n,
}

# The hot path: 15000 turns through a log that holds 20000 entries.
log = k.ReplayLog(16 * 1024 * 1024, 20000, 3, 1536 * 1024)
t0 = time.time()
for i in range(15000):
    user(log, i)
    call(log, i, "h%d" % i, size=200)
    answer(log, i)
out["seconds"] = time.time() - t0
out["count"] = log.count
out["listed"] = len(list(log.entries()))
out["hotDropped"] = log.dropped
print(json.dumps(out))
''';

typedef RunResult = ({String out, String err, int code});

class KeeperHost {
  KeeperHost._(this.home, this.env, this._root);

  final Directory home;
  final Directory _root;
  final Map<String, String> env;
  final clients = <KeeperAttach>[];
  final views = <KeeperView>[];

  String get work => '${home.path}/work';
  String get keepers => '${home.path}/.herdr-mobile/keepers';
  String get hookOut => '${home.path}/hook.out';

  /// [homeLeaf] names the home folder inside the temp directory (a hostile
  /// name, for the paths the keeper types into a shell).
  static Future<KeeperHost> create(Map<String, String> extra, {String? homeLeaf}) async {
    final temp = Directory.systemTemp.createTempSync('keeper_test_');
    final home = homeLeaf == null ? temp : (Directory('${temp.path}/$homeLeaf')..createSync());
    final bin = Directory('${home.path}/bin')..createSync();
    Directory('${home.path}/work').createSync();
    final fake = File('test/support/fake_acp_agent.py').absolute.path;
    expect(File(fake).existsSync(), isTrue, reason: fake);
    for (final binary in ['omp', 'codex-acp', 'claude-agent-acp']) {
      final wrapper = File('${bin.path}/$binary')..writeAsStringSync('#!/bin/sh\nexec python3 \'$fake\' "\$@"\n');
      await Process.run('chmod', ['755', wrapper.path]);
    }
    final py = pythonDir()!;
    return KeeperHost._(home, {
      'HOME': home.path,
      'PATH': '${bin.path}:$py:/usr/bin:/bin',
      'FAKE_ACP_LOG': '${home.path}/agent.jsonl',
      'HERDR_KEEPER_ON_BLOCKED': '${home.path}/hook.sh',
      // A herdr on this machine must never get a pane from a test.
      'HERDR_MOBILE_NO_PANE': '1',
      // A test keeper stays a child of its starter: no launchd job on the
      // machine running the tests (one test turns this on).
      'HERDR_MOBILE_NO_LAUNCHD': '1',
      ...extra,
    }, temp);
  }

  /// The installed script, as `view` runs it.
  String get script => '${home.path}/.herdr-mobile/keeper-${keeperScriptVersion(keeperScript())}.py';

  String get herdrLog => '${home.path}/herdr.calls';
  String get fakeHerdr => '${home.path}/fake-herdr';

  /// Writes a fake herdr (once) and returns its path: it logs every argv to
  /// [herdrLog] and answers `workspace list`, `workspace create` and `tab
  /// create` with JSON shaped like herdr 0.9.3's (`src/api/schema`), keeping
  /// its workspaces in a file; any other command prints nothing and exits 0.
  Future<String> writeFakeHerdr() async {
    final f = File(fakeHerdr);
    if (!f.existsSync()) {
      f.writeAsStringSync(_fakeHerdr(herdrLog, '${home.path}/herdr.state'));
      await Process.run('chmod', ['755', f.path]);
    }
    return f.path;
  }

  /// Points the keeper at the fake herdr (before `start`), panes allowed.
  Future<void> useFakeHerdr() async {
    env['HERDR_MOBILE_HERDR'] = await writeFakeHerdr();
    env['HERDR_MOBILE_NO_PANE'] = '';
  }

  /// Every command the fake herdr ran, in order.
  List<List<String>> herdrCalls() {
    final f = File(herdrLog);
    if (!f.existsSync()) return [];
    return [
      for (final l in f.readAsLinesSync())
        if (l.trim().isNotEmpty) (jsonDecode(l) as List).cast<String>(),
    ];
  }

  /// `view ID` as herdr runs it in a pane, with [env] on top (HERDR_ENV,
  /// HERDR_PANE_ID, HERDR_BIN_PATH).
  Future<KeeperView> view(String id, {Map<String, String> env = const {}}) async {
    final p = await Process.start(
      'python3',
      [script, 'view', id],
      environment: {...this.env, ...env},
      includeParentEnvironment: false,
      workingDirectory: home.path,
    );
    final v = KeeperView(p);
    views.add(v);
    return v;
  }

  Future<RunResult> run(String command, {String input = ''}) async {
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
    return (out: await out, err: await err, code: code);
  }

  /// Installs the keeper script the way the app does before its first command:
  /// the command, with the script written to its stdin.
  Future<void> install({String? script}) async {
    final r = await run(keeperInstallCommand(script: script), input: keeperInstallPayload(script: script));
    expect(r.code, 0, reason: r.err);
    expect(r.out.trim(), '{"ok":true}');
  }

  /// A `start` that is not waited for: for tests that look at the keeper while
  /// its agent is still initialising.
  Future<KeeperRunning> startInBackground({String agent = 'omp'}) async {
    final p = await Process.start(
      '/bin/sh',
      ['-c', keeperStartCommand(agent: agent, cwd: work)],
      environment: env,
      includeParentEnvironment: false,
      workingDirectory: home.path,
    );
    await p.stdin.close();
    return KeeperRunning(p);
  }

  Future<KeeperInfo> start({String agent = 'omp', String? cwd}) async {
    final r = await run(keeperStartCommand(agent: agent, cwd: cwd ?? work));
    expect(r.code, 0, reason: r.err);
    expect(r.out.trim().split('\n'), hasLength(1));
    return KeeperInfo.fromJson(asJson(jsonDecode(r.out)));
  }

  Future<List<Json>> rawList() async {
    final r = await run(keeperListCommand());
    expect(r.code, 0, reason: r.err);
    return [for (final j in jsonDecode(r.out) as List) asJson(j)];
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

  /// Writes the alert hook; it appends one line per event to [hookOut].
  Future<void> writeHook(String body, {String? path}) async {
    final f = File(path ?? '${home.path}/hook.sh')..writeAsStringSync('#!/bin/sh\n$body\n');
    await Process.run('chmod', ['755', f.path]);
  }

  Future<KeeperAttach> attach(String id, {bool zipped = false}) async {
    final p = await Process.start(
      '/bin/sh',
      ['-c', keeperAttachCommand(id, zipped: zipped)],
      environment: env,
      includeParentEnvironment: false,
      workingDirectory: home.path,
    );
    final a = KeeperAttach(p, zipped: zipped);
    clients.add(a);
    return a;
  }

  Future<void> dispose() async {
    for (final a in clients) {
      a.process.kill();
    }
    for (final v in views) {
      v.process.kill();
    }
    try {
      for (final j in await rawList()) {
        await run(keeperKillCommand(j['id']! as String));
      }
    } on Object {
      // best effort: the temp home goes away next
    }
    try {
      _root.deleteSync(recursive: true);
    } on Object {
      // a keeper still writing its record: the OS temp cleaner takes it
    }
  }
}

/// A command started in the background: [finished] completes with its result.
class KeeperRunning {
  KeeperRunning(this.process) {
    final out = utf8.decodeStream(process.stdout);
    final err = utf8.decodeStream(process.stderr);
    finished = () async {
      final code = await process.exitCode;
      return (out: await out, err: await err, code: code);
    }();
  }

  final Process process;
  late final Future<RunResult> finished;
}

/// The phone's side of `attach`: a process whose stdout lines are parsed.
class KeeperAttach {
  KeeperAttach(this.process, {bool zipped = false}) {
    final text = process.stdout
        .map((chunk) {
          wire += chunk.length;
          return chunk;
        })
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    (zipped ? zippedLines(text) : text).listen((l) {
      if (l.trim().isNotEmpty) seen.add(asJson(jsonDecode(l)));
    });
    process.stderr.transform(utf8.decoder).listen(stderr.write);
  }

  final Process process;
  final seen = <Json>[];

  /// Bytes the command wrote to stdout.
  var wire = 0;
  final stderr = StringBuffer();
  Future<int> get exit => process.exitCode;
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

  void write(Json message) => process.stdin.writeln(jsonEncode({'jsonrpc': '2.0', ...message}));

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

  Future<Json> load(KeeperHost h, [String sessionId = 'sess-1']) =>
      request('session/load', {'sessionId': sessionId, 'cwd': h.work, 'mcpServers': <Object?>[]});

  int prompt(String text) => post('session/prompt', {
    'sessionId': 'sess-1',
    'prompt': [
      {'type': 'text', 'text': text},
    ],
  });

  /// Closes stdin (a detach) and returns the exit code.
  Future<int> close() async {
    await process.stdin.close();
    return exit.timeout(const Duration(seconds: 30));
  }
}

/// `view` in a terminal: what it printed, and lines typed into it.
class KeeperView {
  KeeperView(this.process) {
    process.stdout.transform(utf8.decoder).listen(out.write);
    process.stderr.transform(utf8.decoder).listen(err.write);
  }

  final Process process;
  final out = StringBuffer();
  final err = StringBuffer();

  /// Waits until the output, from [from] on, contains [text]; returns where
  /// it ends, for the next wait.
  Future<int> waitFor(String text, {int from = 0}) async {
    final end = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      final i = out.toString().indexOf(text, from);
      if (i >= 0) return i + text.length;
      if (DateTime.now().isAfter(end)) {
        throw TimeoutException('view never printed "$text"; it printed:\n$out\nstderr: $err');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  void type(String line) => process.stdin.writeln(line);
}

String _fakeHerdr(String log, String state) => '''
#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(${jsonEncode(log)}, "a") as f:
    f.write(json.dumps(args) + "\\n")
try:
    with open(${jsonEncode(state)}) as f:
        st = json.load(f)
except (OSError, ValueError):
    st = {"workspaces": [], "tabs": 0}
def arg(name):
    return args[args.index(name) + 1] if name in args else None
def tab(wid, label):
    st["tabs"] += 1
    t = "%s:t%d" % (wid, st["tabs"])
    return ({"tab_id": t, "workspace_id": wid, "number": st["tabs"], "label": label, "focused": False, "pane_count": 1, "agent_status": "unknown"},
            {"pane_id": "%s:p%d" % (wid, st["tabs"]), "terminal_id": "term", "workspace_id": wid, "tab_id": t, "focused": False, "cwd": arg("--cwd"), "agent_status": "unknown"})
out = None
if args[:2] == ["workspace", "list"]:
    out = {"type": "workspace_list", "workspaces": st["workspaces"]}
elif args[:2] == ["workspace", "create"]:
    wid = "w%d" % (len(st["workspaces"]) + 1)
    ws = {"workspace_id": wid, "number": len(st["workspaces"]) + 1, "label": arg("--label") or "", "focused": False,
          "pane_count": 1, "tab_count": 1, "active_tab_id": wid + ":t1", "agent_status": "unknown"}
    st["workspaces"].append(ws)
    t, p = tab(wid, "1")
    out = {"type": "workspace_created", "workspace": ws, "tab": t, "root_pane": p}
elif args[:2] == ["tab", "create"]:
    t, p = tab(arg("--workspace"), arg("--label") or "")
    out = {"type": "tab_created", "tab": t, "root_pane": p}
with open(${jsonEncode(state)}, "w") as f:
    json.dump(st, f)
if out is not None:
    print(json.dumps({"id": "cli", "result": out}))
''';
