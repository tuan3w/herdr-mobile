@TestOn('linux || mac-os')
library;

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

Json _m(Object? v) => (v as Map).cast<String, Object?>();

String? _pythonDir() {
  for (final d in ['/usr/bin', '/bin', '/usr/local/bin', '/opt/homebrew/bin']) {
    if (File('$d/python3').existsSync()) return d;
  }
  return null;
}

Future<bool> _alive(int pid) async => (await Process.run('kill', ['-0', '$pid'])).exitCode == 0;

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

bool Function(Json) _method(String name) =>
    (m) => m['method'] == name;

bool Function(Json) _update(String kind) =>
    (m) => m['method'] == 'session/update' && _m(_m(m['params'])['update'])['sessionUpdate'] == kind;

/// The `update` objects of the `session/update` notifications in [messages].
List<Json> _updates(Iterable<Json> messages) => [
  for (final m in messages)
    if (m['method'] == 'session/update') _m(_m(m['params'])['update']),
];

String _text(Json update) => (_m(update['content'])['text'] ?? '') as String;

typedef Replay = ({Json load, List<Json> updates, int bytes});

/// One user message and what followed it in a replay.
class _Turn {
  _Turn(this.user);

  final String user;
  final tools = <Json>[];
  String? answer;
}

/// The replay cut at its user messages; whatever precedes the first one (a
/// turn whose start was lost) is a turn with an empty `user`.
List<_Turn> _turnsOf(List<Json> updates) {
  final turns = <_Turn>[];
  for (final u in updates) {
    if (u['sessionUpdate'] == 'user_message_chunk') {
      turns.add(_Turn(_text(u)));
      continue;
    }
    if (turns.isEmpty) turns.add(_Turn(''));
    switch (u['sessionUpdate']) {
      case 'tool_call' || 'tool_call_update':
        turns.last.tools.add(u);
      case 'agent_message_chunk':
        turns.last.answer = _text(u);
    }
  }
  return turns;
}

/// `_meta.herdr` of the answer to `session/load`: what the keeper gave up.
Map<String, Object?> _herdr(Json loadResponse) => _m(_m(_m(loadResponse['result'])['_meta'])['herdr']);

bool _isTrimmed(Json update) => update['_meta'] is Map && _m(update['_meta'])['herdr'] is Map && _m(_m(update['_meta'])['herdr'])['trimmed'] == true;

/// Loads the keeper script as a module and exercises `ReplayLog.remove`, the
/// way the keeper takes back the message of a prompt the agent refused.
const _removeProbe = r'''
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
const _logProbe = r'''
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

class _Host {
  _Host._(this.home, this.env);

  final Directory home;
  final Map<String, String> env;
  final clients = <_Attach>[];

  String get work => '${home.path}/work';
  String get keepers => '${home.path}/.herdr-mobile/keepers';
  String get hookOut => '${home.path}/hook.out';

  static Future<_Host> create(Map<String, String> extra) async {
    final home = Directory.systemTemp.createTempSync('keeper_test_');
    final bin = Directory('${home.path}/bin')..createSync();
    Directory('${home.path}/work').createSync();
    final fake = File('test/support/fake_acp_agent.py').absolute.path;
    expect(File(fake).existsSync(), isTrue, reason: fake);
    for (final binary in ['omp', 'codex-acp', 'claude-agent-acp']) {
      final wrapper = File('${bin.path}/$binary')..writeAsStringSync('#!/bin/sh\nexec python3 \'$fake\' "\$@"\n');
      await Process.run('chmod', ['755', wrapper.path]);
    }
    final py = _pythonDir()!;
    return _Host._(home, {
      'HOME': home.path,
      'PATH': '${bin.path}:$py:/usr/bin:/bin',
      'FAKE_ACP_LOG': '${home.path}/agent.jsonl',
      'HERDR_KEEPER_ON_BLOCKED': '${home.path}/hook.sh',
      ...extra,
    });
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
  Future<_Running> startInBackground({String agent = 'omp'}) async {
    final p = await Process.start(
      '/bin/sh',
      ['-c', keeperStartCommand(agent: agent, cwd: work)],
      environment: env,
      includeParentEnvironment: false,
      workingDirectory: home.path,
    );
    await p.stdin.close();
    return _Running(p);
  }

  Future<KeeperInfo> start({String agent = 'omp', String? cwd}) async {
    final r = await run(keeperStartCommand(agent: agent, cwd: cwd ?? work));
    expect(r.code, 0, reason: r.err);
    expect(r.out.trim().split('\n'), hasLength(1));
    return KeeperInfo.fromJson(_m(jsonDecode(r.out)));
  }

  Future<List<Json>> rawList() async {
    final r = await run(keeperListCommand());
    expect(r.code, 0, reason: r.err);
    return [for (final j in jsonDecode(r.out) as List) _m(j)];
  }

  Future<List<KeeperInfo>> list() async => [for (final j in await rawList()) KeeperInfo.fromJson(j)];

  /// What reached the agent, in order.
  List<Json> agentLog() {
    final f = File(env['FAKE_ACP_LOG']!);
    if (!f.existsSync()) return [];
    return [
      for (final l in f.readAsLinesSync())
        if (l.trim().isNotEmpty) _m(_m(jsonDecode(l))['recv']),
    ];
  }

  /// Writes the alert hook; it appends one line per event to [hookOut].
  Future<void> writeHook(String body, {String? path}) async {
    final f = File(path ?? '${home.path}/hook.sh')..writeAsStringSync('#!/bin/sh\n$body\n');
    await Process.run('chmod', ['755', f.path]);
  }

  Future<_Attach> attach(String id, {bool zipped = false}) async {
    final p = await Process.start(
      '/bin/sh',
      ['-c', keeperAttachCommand(id, zipped: zipped)],
      environment: env,
      includeParentEnvironment: false,
      workingDirectory: home.path,
    );
    final a = _Attach(p, zipped: zipped);
    clients.add(a);
    return a;
  }

  Future<void> dispose() async {
    for (final a in clients) {
      a.process.kill();
    }
    try {
      for (final j in await rawList()) {
        await run(keeperKillCommand(j['id']! as String));
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

/// A command started in the background: [finished] completes with its result.
class _Running {
  _Running(this.process) {
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
class _Attach {
  _Attach(this.process, {bool zipped = false}) {
    final text = process.stdout
        .map((chunk) {
          wire += chunk.length;
          return chunk;
        })
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    (zipped ? zippedLines(text) : text).listen((l) {
      if (l.trim().isNotEmpty) seen.add(_m(jsonDecode(l)));
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

  Future<Json> initialize() => request('initialize', {'protocolVersion': 1, 'clientCapabilities': <String, Object?>{}});

  Future<Json> newSession(_Host h) => request('session/new', {'cwd': h.work, 'mcpServers': <Object?>[]});

  Future<Json> load(_Host h, [String sessionId = 'sess-1']) =>
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

void main() {
  final hasPython = _pythonDir() != null;

  Future<_Host> newHost([Map<String, String> env = const {}, bool install = true]) async {
    final h = await _Host.create(env);
    addTearDown(h.dispose);
    if (install) await h.install();
    return h;
  }

  group('commands', skip: hasPython ? false : 'python3 is not installed', () {
    test('probe lists the routes the host can run', () async {
      final h = await newHost();
      final r = await h.run(keeperProbeCommand());
      expect(r.code, 0, reason: r.err);
      final routes = (_m(jsonDecode(r.out))['routes'] as List).cast<String>();
      expect(routes, contains('omp'));
      expect(agentRoutes.map((a) => a.id), containsAll(routes));
    });

    test('every command but install is short', () {
      final commands = [
        keeperProbeCommand(),
        keeperListCommand(),
        keeperStartCommand(agent: 'omp', cwd: '/tmp/${'x' * 200}'),
        keeperAttachCommand('abc234'),
        keeperKillCommand('abc234'),
      ];
      for (final c in commands) {
        expect(c.length, lessThan(1024));
      }
      expect(keeperInstallCommand().length, lessThan(2048)); // Dropbear refuses an exec over 9000 bytes
      final payload = keeperInstallPayload();
      expect(payload.length, inInclusiveRange(10000, 60000));
      expect(payload.trimRight().split('\n').every((l) => l.length <= 76), isTrue);
      expect(payload.endsWith('\n'), isTrue);
    });

    test('a broken payload installs nothing and says so', () async {
      final h = await newHost(const {}, false);
      final r = await h.run(keeperInstallCommand(), input: 'not base64 of a deflated script\n');
      expect(r.code, isNot(0));
      expect(r.out, isNot(contains('"ok"')));
      final dir = Directory('${h.home.path}/.herdr-mobile');
      expect(!dir.existsSync() || dir.listSync().isEmpty, isTrue);
    });

    test('a host without the keeper exits 65 until it is installed', () async {
      final h = await newHost(const {}, false);
      for (final c in [
        keeperProbeCommand(),
        keeperListCommand(),
        keeperStartCommand(agent: 'omp', cwd: h.work),
        keeperAttachCommand('abc234'),
        keeperKillCommand('abc234'),
      ]) {
        final r = await h.run(c);
        expect(r.code, 65, reason: r.err);
        expect(r.err, contains('not installed'));
        expect(r.out, isEmpty);
      }
      expect(Directory('${h.home.path}/.herdr-mobile').existsSync(), isFalse);
      await h.install();
      expect((await h.run(keeperProbeCommand())).code, 0);
    });

    test('install writes a private file, is idempotent and leaves no temp files', () async {
      final h = await newHost(const {}, false);
      final file = File('${h.home.path}/.herdr-mobile/keeper-${keeperScriptVersion(keeperScript())}.py');
      await h.install();
      expect(file.readAsStringSync(), keeperScript());
      expect(FileStat.statSync(file.path).mode & 0x1ff, 0x1c0); // 0700
      expect(FileStat.statSync('${h.home.path}/.herdr-mobile').mode & 0x1ff, 0x1c0);
      await h.install();
      expect(file.readAsStringSync(), keeperScript());
      expect(Directory('${h.home.path}/.herdr-mobile').listSync().map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last), [file.uri.pathSegments.last]);
    });

    test('installing is atomic: a reader never sees half a script', () async {
      final h = await newHost(const {}, false);
      final file = File('${h.home.path}/.herdr-mobile/keeper-${keeperScriptVersion(keeperScript())}.py');
      var installing = true;
      var reads = 0;
      final reader = () async {
        while (installing) {
          if (file.existsSync()) {
            reads++;
            expect(file.readAsStringSync(), keeperScript());
          }
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }();
      final results = await Future.wait([
        for (var i = 0; i < 4; i++) h.run(keeperInstallCommand(), input: keeperInstallPayload()),
      ]);
      installing = false;
      await reader;
      for (final r in results) {
        expect(r.code, 0, reason: r.err);
        expect(r.out.trim(), '{"ok":true}');
      }
      expect(reads, greaterThan(0));
      expect(file.readAsStringSync(), keeperScript());
    });

    test('another script version gets its own file; the old one is removed and its keeper lives on', () async {
      final h = await newHost();
      final v1 = keeperScriptVersion(keeperScript());
      final second = '${keeperScript()}\n# a later version\n';
      final v2 = keeperScriptVersion(second);
      expect(v2, isNot(v1));
      expect(v1, matches(RegExp(r'^[0-9a-f]{12}$')));
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);

      await h.install(script: second);
      final dir = '${h.home.path}/.herdr-mobile';
      expect(File('$dir/keeper-$v1.py').existsSync(), isFalse);
      expect(File('$dir/keeper-$v2.py').readAsStringSync(), second);
      // The app of the old version now finds nothing and installs again.
      expect((await h.run(keeperListCommand())).code, 65);

      // The keeper started by the old file still runs and serves.
      expect(await _alive(info.pid!), isTrue);
      expect((await a.request('session/list'))['result'], isNotNull);
      final listed = await h.run("exec python3 '$dir/keeper-$v2.py' list");
      expect(((jsonDecode(listed.out) as List).single as Map)['id'], info.id);
      final b = await h.run("exec python3 '$dir/keeper-$v2.py' kill ${info.id}");
      expect(b.out.trim(), '{"ok":true}');
    });

    test('rejects an unknown agent, a bad folder and a bad keeper id', () {
      for (final bad in ['', 'gpt', 'OMP', 'omp; id', r'$(id)', 'omp ', "omp'"]) {
        expect(() => keeperStartCommand(agent: bad, cwd: '/tmp'), throwsArgumentError, reason: bad);
      }
      for (final bad in ['', 'a\nb', 'a\u0000b', 'a\rb', 'x' * 5000]) {
        expect(() => keeperStartCommand(agent: 'omp', cwd: bad), throwsArgumentError, reason: bad.length > 20 ? 'long' : bad);
      }
      for (final bad in ['', 'a b', r'$(id)', '../x', 'A1b2c3', "ab'c", 'a;b', 'ab', 'x' * 33]) {
        expect(() => keeperAttachCommand(bad), throwsArgumentError, reason: bad);
        expect(() => keeperKillCommand(bad), throwsArgumentError, reason: bad);
      }
    });

    test('a folder name cannot break out of the command', () async {
      final h = await newHost();
      final marker = '${h.home.path}/pwned';
      for (final evil in [
        "x'; touch $marker; '",
        '\$(touch $marker)',
        '`touch $marker`',
        'x"; touch $marker; "',
        'a b; touch $marker',
        '-rf',
      ]) {
        final r = await h.run(keeperStartCommand(agent: 'omp', cwd: evil));
        expect(r.code, 66, reason: '$evil: ${r.err}');
        expect(r.err, contains('does not exist'));
        expect(File(marker).existsSync(), isFalse, reason: evil);
      }
      expect(await h.list(), isEmpty);
    });

    test('a folder with spaces and quotes works, and ~ expands on the host', () async {
      final h = await newHost();
      final odd = Directory('${h.home.path}/it\'s a "dir" \$HOME `x`')..createSync();
      final sub = Directory('${h.home.path}/sub dir')..createSync();
      final a = await h.start(cwd: odd.path);
      expect(a.cwd, odd.path);
      final b = await h.start(cwd: '~');
      expect(b.cwd, h.home.path);
      final c = await h.start(cwd: '~/sub dir');
      expect(c.cwd, sub.path);
    });

    test('unknown keeper ids exit 66', () async {
      final h = await newHost();
      expect((await h.run(keeperAttachCommand('zzzzzz'))).code, 66);
      final k = await h.run(keeperKillCommand('zzzzzz'));
      expect(k.code, 66);
      expect(k.err, contains('no such keeper'));
    });
  });

  group('keeper', skip: hasPython ? false : 'python3 is not installed', () {
    test('start prints the KeeperInfo, outlives the starter and ignores SIGHUP', () async {
      final h = await newHost();
      final info = await h.start();
      expect(info.id, matches(RegExp(r'^[a-hjkmnp-z2-9]{6}$')));
      expect(info.agent, 'omp');
      expect(info.cwd, h.work);
      expect(info.state, KeeperState.running);
      expect(info.pid, greaterThan(0));
      expect(info.pending, 0);
      expect(info.sessionId, isNull);
      expect(DateTime.now().difference(info.startedAt).inSeconds.abs(), lessThan(60));

      // The starter is gone; the keeper lives, also after SIGHUP.
      Process.killPid(info.pid!, ProcessSignal.sighup);
      // A SIGHUP was delivered when killPid returned; a keeper that did not
      // ignore it would not answer the attach below.
      final a = await h.attach(info.id);
      final init = _m((await a.initialize())['result']);
      expect(_m(init['agentInfo'])['name'], 'fake-acp');
      expect(await _alive(info.pid!), isTrue);
      final listed = (await h.list()).single;
      expect(listed.id, info.id);
      expect(listed.state, KeeperState.running);
    });

    test('directory, socket, record and log are private', () async {
      final h = await newHost();
      final info = await h.start();
      int mode(String path) => FileStat.statSync(path).mode & 0x1ff;
      expect(mode(h.keepers), 0x1c0); // 0700
      for (final ext in ['sock', 'json', 'log']) {
        expect(mode('${h.keepers}/${info.id}.$ext'), 0x180, reason: ext); // 0600
      }
    });

    test('the agent gets no stray file descriptors', skip: Directory('/proc/self/fd').existsSync() ? false : 'needs /proc', () async {
      final h = await newHost();
      await h.start();
      final agentPid = (await h.rawList()).single['agent_pid']! as int;
      final fds = Directory('/proc/$agentPid/fd').listSync().map((e) => e.uri.pathSegments.last).toSet();
      expect(fds, {'0', '1', '2'});
    });

    test('a slow start is listed while it initialises and is not swept as an orphan', () async {
      final h = await newHost({'FAKE_ACP_INIT_DELAY': '15', 'HERDR_KEEPER_ORPHAN_SECONDS': '1'});
      final s = await h.startInBackground();
      await eventually(
        () => Directory(h.keepers).existsSync() && Directory(h.keepers).listSync().any((f) => f.path.endsWith('.json')),
        what: 'the first record',
      );
      await Future<void>.delayed(const Duration(milliseconds: 2500)); // a minimum: past the 1 s orphan bound
      final starting = (await h.rawList()).single;
      expect(starting['state'], 'starting');
      expect(KeeperInfo.fromJson(starting).state, KeeperState.running);
      final id = starting['id']! as String;
      for (final ext in ['json', 'sock', 'log']) {
        expect(File('${h.keepers}/$id.$ext').existsSync(), isTrue, reason: ext);
      }
      final done = await s.finished;
      expect(done.code, 0, reason: done.err);
      expect(KeeperInfo.fromJson(_m(jsonDecode(done.out))).id, id);
      final a = await h.attach(id);
      expect(_m((await a.initialize())['result'])['protocolVersion'], 1);
      expect((await h.list()).single.state, KeeperState.running);
    });

    test('kill reaches a keeper whose agent is still starting', () async {
      final h = await newHost({'FAKE_ACP_INIT_DELAY': '60'});
      final s = await h.startInBackground();
      late Json rec;
      await eventually(() async {
        final l = await h.rawList();
        if (l.isEmpty || l.single['agent_pid'] == null) return false;
        rec = l.single;
        return true;
      }, what: 'a starting keeper that has its agent');
      expect(rec['state'], 'starting');
      final keeperPid = rec['pid']! as int;
      final agentPid = rec['agent_pid']! as int;
      final k = await h.run(keeperKillCommand(rec['id']! as String));
      expect(k.code, 0, reason: k.err);
      expect(_m(jsonDecode(k.out)), {'ok': true});
      await eventually(() async => !await _alive(keeperPid) && !await _alive(agentPid), what: 'keeper and agent to stop');
      final r = await s.finished;
      expect(r.code, 70);
      expect(await h.list(), isEmpty);
      expect(Directory(h.keepers).listSync(), isEmpty);
    });

    test('one huge update is cut down and never empties the replay log', () async {
      final h = await newHost({'HERDR_KEEPER_LOG_BYTES': '20000'});
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      await a.response(a.prompt('long:5'));
      await a.response(a.prompt('big:100000'));
      await a.response(a.prompt('long:3'));
      await a.close();

      final b = await h.attach(info.id);
      await b.initialize();
      await b.load(h);
      final replay = _updates(b.seen);
      final texts = replay.where((u) => u['sessionUpdate'] == 'agent_message_chunk').map(_text).toList();
      // The entries from before the huge one are still there, and after it.
      expect(texts, containsAll(['line 0 ', 'line 4 ', 'tail', 'line 2 ']));
      final tool = replay.singleWhere((u) => u['toolCallId'] == 'big-1');
      expect(tool['status'], 'completed');
      expect(tool['title'], 'Big output');
      expect(jsonEncode(tool['content']), contains('bytes omitted'));
      expect(jsonEncode(tool).length, lessThan(1000));
      final big = replay.singleWhere((u) => u['messageId'] == 'mbig');
      expect(_text(big), startsWith('zzzz'));
      expect(_text(big), contains('bytes omitted'));
      expect(_text(big).length, lessThan(2000));
    });

    test('list tells a turn in flight and a turn that ended unseen', () async {
      final h = await newHost();
      final info = await h.start();
      expect(info.turnActive, isFalse);
      expect(info.unseenDone, isFalse);
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      expect((await h.list()).single.turnActive, isFalse);
      a.prompt('sleep:2');
      await a.next(_update('agent_message_chunk'));
      var now = (await h.list()).single;
      expect(now.turnActive, isTrue);
      expect(now.unseenDone, isFalse);

      await a.close(); // detached, still working
      now = (await h.list()).single;
      expect(now.turnActive, isTrue);
      await eventually(() async => (await h.list()).single.unseenDone, what: 'the unseen end');
      now = (await h.list()).single;
      expect(now.turnActive, isFalse);
      expect(now.unseenDone, isTrue);

      final b = await h.attach(info.id);
      await b.initialize();
      expect((await h.list()).single.unseenDone, isTrue, reason: 'attaching alone has not shown the end');
      await b.load(h);
      await eventually(() async => !(await h.list()).single.unseenDone, what: 'the load to clear it');

      // A turn the attached client waits for is never "unseen".
      await b.response(b.prompt('plain'));
      now = (await h.list()).single;
      expect(now.turnActive, isFalse);
      expect(now.unseenDone, isFalse);
    });

    test('initialize is asked once and answered from the cache', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      final first = _m((await a.initialize())['result']);
      // The agent said loadSession false; the keeper answers the load itself.
      expect(_m(first['agentCapabilities'])['loadSession'], isTrue);
      expect(first['protocolVersion'], 1);
      await a.close();
      final b = await h.attach(info.id);
      expect(_m((await b.initialize())['result']), first);
      final inits = h.agentLog().where((m) => m['method'] == 'initialize').toList();
      expect(inits, hasLength(1));
      expect(inits.single['id'], 'keeper-init');
      final caps = _m(_m(inits.single['params'])['clientCapabilities']);
      expect(_m(caps['session']), {'configOptions': {'boolean': <String, Object?>{}}},
          reason: 'Claude Code and Codex send fast as a select unless the client opts in');
      expect(_m(caps['elicitation']), {'form': <String, Object?>{}});
    });

    test('a failing agent fails the start and leaves nothing behind', () async {
      final h = await newHost({'FAKE_ACP_FAIL_INIT': '1'});
      final r = await h.run(keeperStartCommand(agent: 'omp', cwd: h.work));
      expect(r.code, 70);
      expect(r.err, contains('cannot start: no login'));
      expect(r.out.trim(), isEmpty);
      expect(await h.list(), isEmpty);
      expect(Directory(h.keepers).listSync(), isEmpty);
    });

    test('racing starts get different ids', () async {
      final h = await newHost();
      final infos = await Future.wait([for (var i = 0; i < 5; i++) h.start()]);
      expect({for (final i in infos) i.id}, hasLength(5));
      expect(await h.list(), hasLength(5));
    });

    test('list is newest first', () async {
      final h = await newHost();
      final a = await h.start();
      await Future<void>.delayed(const Duration(milliseconds: 50)); // started_at has millisecond resolution
      final b = await h.start();
      expect((await h.list()).map((i) => i.id), [b.id, a.id]);
    });

    test('updates are replayed after a detach, with the prompt and merged chunks', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      final done = _m((await a.response(a.prompt('plain')))['result']);
      expect(done['stopReason'], 'end_turn');
      // Live, the chunks arrive as the agent wrote them.
      expect(_updates(a.seen).map(_text), ['Hel', 'lo']);
      await a.close();

      final b = await h.attach(info.id);
      await b.initialize();
      final loaded = _m((await b.load(h))['result']);
      expect(_m(loaded['modes'])['currentModeId'], 'default');
      final replay = _updates(b.seen);
      expect(replay.map((u) => u['sessionUpdate']), ['user_message_chunk', 'agent_message_chunk']);
      expect(_text(replay[0]), 'plain');
      expect(_text(replay[1]), 'Hello');
      // The agent could not load a live session: the keeper never asks it to.
      expect(h.agentLog().where((m) => m['method'] == 'session/load'), isEmpty);

      // Requests still reach the agent under the phone's own ids.
      final listed = await b.request('session/list');
      expect(_m(listed['result'])['sessions'], isEmpty);
    });

    group('a prompt the agent refuses as busy (-32003) is not a message in the log', () {
      // omp answers -32003 to a prompt that lands while a turn of its own (a
      // background subagent) runs. It took nothing, so a replay must not show
      // it: every refused attempt used to come back as one more identical
      // bubble.
      for (final noisy in [true, false]) {
        test(noisy ? 'the agent streamed output of its own before refusing' : 'the agent refused without a word', () async {
          final busy = File('${Directory.systemTemp.createTempSync('keeper_busy_').path}/busy');
          addTearDown(() => busy.parent.deleteSync(recursive: true));
          final h = await newHost({'FAKE_ACP_BUSY_FILE': busy.path});
          final info = await h.start();
          final a = await h.attach(info.id);
          await a.initialize();
          await a.newSession(h);

          busy.writeAsStringSync(noisy ? 'busy' : 'quiet');
          for (var i = 0; i < 3; i++) {
            final refused = await a.response(a.prompt('reply:fix it'));
            expect(_m(refused['error'])['code'], -32003);
          }
          busy.deleteSync();
          final ok = await a.response(a.prompt('reply:fix it'));
          expect(_m(ok['result'])['stopReason'], 'end_turn');
          await a.close();

          final b = await h.attach(info.id);
          await b.initialize();
          await b.load(h);
          final users = _updates(b.seen).where((u) => u['sessionUpdate'] == 'user_message_chunk');
          expect(users.map(_text), ['reply:fix it'], reason: 'the one the agent took');
          expect(_updates(b.seen).where((u) => u['sessionUpdate'] == 'agent_message_chunk').map(_text), [
            if (noisy) ...List.filled(3, 'subagent progress'),
            're: fix it',
          ]);
        });
      }
    });

    test('a prompt nothing has answered yet is in the replay of a client that attached meanwhile', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      a.prompt('quiet:2');
      await eventually(
        () => h.agentLog().any((m) => m['method'] == 'session/prompt'),
        what: 'the prompt to reach the agent',
      );

      final b = await h.attach(info.id);
      await b.initialize();
      await b.load(h);
      expect(
        _updates(b.seen).where((u) => u['sessionUpdate'] == 'user_message_chunk').map(_text),
        ['quiet:2'],
        reason: 'the agent has said nothing yet, the message is already part of the conversation',
      );
      await b.next((m) => m['method'] == 'session/update' && _m(_m(m['params'])['update'])['state'] == 'idle');
    });

    test('a permission asked while detached is re-issued and answered once', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      a.prompt('ask');
      final first = await a.next(_method('session/request_permission'));
      expect(_m(_m(first['params'])['toolCall'])['title'], 'Run: ls -la');
      expect(first['id'], isA<String>()); // a keeper id, not the agent's 7001
      await a.close();

      await eventually(() async => (await h.list()).single.pending == 1, what: 'one pending request');

      final b = await h.attach(info.id);
      await b.initialize();
      await b.load(h);
      final again = await b.next(_method('session/request_permission'));
      expect(again['id'], first['id']);
      expect(_m(again['params']), _m(first['params']));
      b.reply(again['id'], {
        'outcome': {'outcome': 'selected', 'optionId': 'allow'},
      });
      // A late duplicate (another device, a double tap) is ignored.
      b.reply(again['id'], {
        'outcome': {'outcome': 'selected', 'optionId': 'reject'},
      });

      final question = await b.next(_method('elicitation/create'));
      expect(_m(question['params'])['message'], 'Pick one?\nsecond line');
      b.reply(question['id'], {'action': 'accept', 'content': {'value': 'a'}});

      // The turn ended while no prompt request of this client was waiting.
      final idle = await b.next(_update('state_update'));
      expect(_m(_m(idle['params'])['update']), {'sessionUpdate': 'state_update', 'state': 'idle', 'stopReason': 'end_turn'});
      expect(_updates(b.seen).map((u) => u['sessionUpdate'] == 'agent_message_chunk' ? _text(u) : ''), contains('answered:allow/accept'));

      final log = h.agentLog();
      final permission = log.where((m) => !m.containsKey('method') && m['id'] == 7001).toList();
      expect(permission, hasLength(1));
      expect(_m(_m(permission.single['result'])['outcome'])['optionId'], 'allow');
      final answers = log.where((m) => !m.containsKey('method') && m['id'] == 'elic-1').toList();
      expect(answers, hasLength(1));
      expect(_m(answers.single['result'])['action'], 'accept');
      expect((await h.list()).single.pending, 0);
    });

    test('a turn that ended unseen is reported on the next load', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      a.prompt('sleep:1');
      await a.next(_update('agent_message_chunk'));
      await a.close();
      await eventually(() async => (await h.list()).single.unseenDone, what: 'the turn to end unseen');

      final b = await h.attach(info.id);
      await b.initialize();
      await b.load(h);
      final idle = await b.next(_update('state_update'));
      expect(_m(_m(idle['params'])['update'])['stopReason'], 'end_turn');
      // Seen now: a third client is told nothing.
      await b.close();
      final c = await h.attach(info.id);
      await c.initialize();
      await c.load(h);
      expect(c.seen.where(_update('state_update')), isEmpty);
    });

    test('a newer attach evicts the older one with a clear close', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      final b = await h.attach(info.id);
      await b.initialize();
      final evicted = await a.next(_method('_herdr/evicted'));
      expect(_m(evicted['params'])['reason'], contains('Another device'));
      expect(await a.exit.timeout(const Duration(seconds: 30)), 0);
      final listed = await b.request('session/list');
      expect(listed['result'], isNotNull);
    });

    test('garbage, partial lines and probes neither evict nor hurt', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();

      final g = await h.attach(info.id);
      g.process.stdin.write('garbage\n{"x":1}\n[1,2]\n\n{"jsonrpc":"2.0","id":1,"meth');
      await g.process.stdin.flush();
      await g.close();
      await h.list(); // connects to the socket and hangs up
      await h.list();

      final listed = await a.request('session/list');
      expect(listed['result'], isNotNull);
      expect(a.seen.where(_method('_herdr/evicted')), isEmpty);
      final log = File('${h.keepers}/${info.id}.log').readAsStringSync();
      expect(log, contains('not JSON'));
    });

    test('an agent that writes non-JSON is logged and skipped', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      final r = await a.response(a.prompt('noise'));
      expect(_m(r['result'])['stopReason'], 'end_turn');
      expect(_updates(a.seen).map(_text), ['after noise']);
      expect(File('${h.keepers}/${info.id}.log').readAsStringSync(), contains('not JSON'));
    });

    test('session/cancel is forwarded only when a client sends it', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      a.prompt('slow');
      await a.next(_update('agent_message_chunk'));
      await a.close(); // a detach
      // The keeper never cancels by itself. Fence: once the agent has read a
      // request that b sent after the detach, a cancel sent by the keeper on
      // the detach would be in the agent's log already.
      final b = await h.attach(info.id);
      await b.initialize();
      b.post('session/list');
      await eventually(() => h.agentLog().any((m) => m['method'] == 'session/list'), what: 'the agent to read b\'s session/list');
      expect(h.agentLog().where((m) => m['method'] == 'session/cancel'), isEmpty);

      await b.load(h);
      final running = await b.next(_update('state_update'));
      expect(_m(_m(running['params'])['update'])['state'], 'running');
      b.write({
        'method': 'session/cancel',
        'params': {'sessionId': 'sess-1'},
      });
      final idle = await b.next(_update('state_update'));
      expect(_m(_m(idle['params'])['update']), {'sessionUpdate': 'state_update', 'state': 'idle', 'stopReason': 'cancelled'});
      expect(h.agentLog().where((m) => m['method'] == 'session/cancel'), hasLength(1));
    });

    test('the title, session and activity reach list', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      a.prompt('ask');
      await a.next(_method('session/request_permission'));
      await eventually(() async {
        final i = (await h.list()).single;
        return i.title == 'Fake title' && i.sessionId == 'sess-1' && i.lastEventAt != null && i.pending == 1;
      }, what: 'title, session and pending in list');
    });

    test('an agent that exits with nobody attached shows in list with its exit code', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      a.prompt('exit:7');
      await a.close();
      await eventually(() async => (await h.list()).single.state == KeeperState.exited, what: 'exited keeper');
      final gone = (await h.list()).single;
      expect(gone.exitCode, 7);
      expect(gone.exitReason, contains('code 7'));
      expect(gone.pending, 0);
      expect(gone.sessionId, 'sess-1');
    });

    test('an agent that dies with a request pending: noted, announced, attach says why', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      a.prompt('die');
      await a.next(_method('session/request_permission'));
      final bye = await a.next(_method('_herdr/agent_exited'));
      expect(_m(bye['params'])['exitCode'], 3);
      expect(await a.exit.timeout(const Duration(seconds: 30)), 0);

      final gone = (await h.list()).single;
      expect(gone.state, KeeperState.exited);
      expect(gone.exitCode, 3);
      expect(gone.exitReason, allOf(contains('code 3'), contains('boom')));
      expect(gone.pending, 0);
      final log = File('${h.keepers}/${info.id}.log').readAsStringSync();
      expect(log, contains('cancelled'));
      expect(log, contains('boom'));

      final again = await h.run(keeperAttachCommand(info.id));
      expect(again.code, 67);
      expect(again.err, contains('code 3'));

      // Kill dismisses the record.
      final k = await h.run(keeperKillCommand(info.id));
      expect(k.out.trim(), '{"ok":true}');
      expect(await h.list(), isEmpty);
    });

    test('a keeper whose process vanished is listed as exited', () async {
      final h = await newHost();
      final info = await h.start();
      Process.killPid(info.pid!, ProcessSignal.sigkill);
      await eventually(() async => (await h.list()).single.state == KeeperState.exited, what: 'keeper to be marked exited');
      final gone = (await h.list()).single;
      expect(gone.state, KeeperState.exited);
      expect(gone.exitReason, contains('gone'));
    });

    test('kill stops the agent and forgets the keeper', () async {
      final h = await newHost();
      final info = await h.start();
      final agentPid = (await h.rawList()).single['agent_pid']! as int;
      final a = await h.attach(info.id);
      await a.initialize();
      final k = await h.run(keeperKillCommand(info.id));
      expect(k.code, 0, reason: k.err);
      expect(_m(jsonDecode(k.out)), {'ok': true});
      expect(await h.list(), isEmpty);
      expect(await _alive(info.pid!), isFalse);
      expect(await _alive(agentPid), isFalse);
      final bye = await a.next(_method('_herdr/agent_exited'));
      expect(_m(bye['params'])['reason'], 'Ended on request.');
    });

    test('kill escalates to SIGKILL for an agent that ignores SIGTERM', () async {
      final h = await newHost({'FAKE_ACP_IGNORE_TERM': '1'});
      final info = await h.start();
      final agentPid = (await h.rawList()).single['agent_pid']! as int;
      final watch = Stopwatch()..start();
      final k = await h.run(keeperKillCommand(info.id));
      expect(k.code, 0, reason: k.err);
      expect(watch.elapsed, greaterThan(const Duration(seconds: 2))); // SIGTERM ignored, so it waits out the 3 s ladder
      expect(watch.elapsed, lessThan(const Duration(seconds: 40)), reason: 'the kill command must still finish');
      expect(await _alive(agentPid), isFalse);
      expect(await h.list(), isEmpty);
    });

    test('the log is bounded by message count', () async {
      final h = await newHost({'HERDR_KEEPER_LOG_MESSAGES': '10'});
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      await a.response(a.prompt('long:50'));
      await a.close();
      final b = await h.attach(info.id);
      await b.initialize();
      await b.load(h);
      final texts = _updates(b.seen).map(_text).toList();
      expect(texts, hasLength(10));
      expect(texts.last, 'line 49 ');
      expect(texts, isNot(contains('line 0 ')));
    });

    test('the log is bounded by bytes', () async {
      final h = await newHost({'HERDR_KEEPER_LOG_BYTES': '2000'});
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      await a.response(a.prompt('long:50'));
      await a.close();
      final b = await h.attach(info.id);
      await b.initialize();
      await b.load(h);
      final replay = b.seen.where(_method('session/update')).toList();
      expect(replay, isNotEmpty);
      expect(replay.fold<int>(0, (n, m) => n + jsonEncode(m).length), lessThanOrEqualTo(2000));
      expect(_text(_updates(replay).last), 'line 49 ');
    });
  });

  // A long, tool-heavy chat used to lose its first turns: the log kept the
  // newest 4000 entries / 4 MB and dropped the oldest whole entries first.
  group('history', skip: hasPython ? false : 'python3 is not installed', () {
    Future<_Attach> detached(_Host h, String id, int turns, String spec) async {
      final a = await h.attach(id);
      await a.initialize();
      await a.newSession(h);
      for (var i = 0; i < turns; i++) {
        await a.response(a.prompt('heavy:$spec:$i'), timeout: const Duration(seconds: 120));
      }
      await a.close();
      return a;
    }

    Future<Replay> replay(_Host h, String id) async {
      final c = await h.attach(id);
      await c.initialize();
      final load = await c.load(h);
      final updates = c.seen.where(_method('session/update')).toList();
      await c.close();
      return (
        load: load,
        updates: _updates(updates),
        bytes: updates.fold(0, (n, m) => n + jsonEncode(m).length),
      );
    }

    test('a zipped attach replays the same messages in a fraction of the bytes, and leaves small ones alone', () async {
      final h = await newHost();
      final info = await h.start();
      await detached(h, info.id, 3, '28:20:100');

      Future<(_Attach, Json)> open({required bool zipped}) async {
        final c = await h.attach(info.id, zipped: zipped);
        await c.initialize();
        final load = await c.load(h);
        return (c, load);
      }

      // One at a time: a newer attach evicts the older one.
      final (plain, plainLoad) = await open(zipped: false);
      await plain.close();
      final (zipped, zippedLoad) = await open(zipped: true);
      addTearDown(zipped.close);

      expect(zipped.seen, plain.seen, reason: 'what the app reads is what it always read');
      expect(zippedLoad, plainLoad);
      expect(plain.wire, greaterThan(200 * 1024), reason: 'a replay worth zipping');
      expect(zipped.wire, lessThan(plain.wire ~/ 4), reason: 'plain JSON text deflates well');

      // A message that is not worth it travels as it is, a line of its own, and
      // the stream keeps working after it.
      final before = zipped.wire;
      final answer = await zipped.request('session/list');
      expect(_m(answer['result']), isNotNull);
      expect(zipped.wire - before, lessThan(1024));
    });

    test('twelve heavy turns: every question and answer comes back, the replay stays small', () async {
      final h = await newHost();
      final info = await h.start();
      await detached(h, info.id, 12, '28:20:100');
      final r = await replay(h, info.id);

      final turns = _turnsOf(r.updates);
      expect(turns.map((t) => t.user), [for (var i = 0; i < 12; i++) 'heavy:28:20:100:$i']);
      for (var i = 0; i < 12; i++) {
        expect(turns[i].answer, 'answer $i', reason: 'turn $i');
      }
      final herdr = _herdr(r.load);
      expect(herdr['droppedTurns'], 0);
      // The soft budget (1.5 MB) is what a replay costs: the 21 MB of output
      // of 12 turns became one whole turn (1.8 MB) and eleven skeletons.
      expect(r.bytes, lessThanOrEqualTo(2500 * 1024));
      expect(r.bytes, greaterThan(1024 * 1024), reason: 'the newest turn is whole');

      // Every turn but the newest kept its rows and lost what made it heavy.
      final trimmed = [for (final t in turns) if (t.tools.any(_isTrimmed)) t];
      expect(trimmed, hasLength(11));
      expect(herdr['trimmedTurns'], 11);
      for (final t in turns.take(11)) {
        expect(t.tools.every(_isTrimmed), isTrue, reason: t.user);
      }
      final first = turns.first.tools;
      expect(first.map((u) => u['toolCallId']).toSet(), hasLength(28), reason: 'every call keeps one row');
      expect(first, hasLength(28), reason: 'progress ticks of finished calls are merged');
      for (final u in first) {
        expect(u['status'], 'completed');
        expect(u['title'], startsWith('Run: step '));
        expect(u['locations'], isNotEmpty);
        expect(u.containsKey('rawOutput'), isFalse);
        expect(jsonEncode(u).length, lessThan(1500));
        expect(_m(_m(u['_meta'])['herdr'])['trimmed'], isTrue);
      }
      // The command a row is named by survives; the 3000-byte script does not.
      expect(_m(first.first['rawInput'])['command'], 'step 0');
      expect(_m(first.first['rawInput']).containsKey('script'), isFalse);

      // The newest turn is whole: every call's output is there, untouched.
      final newest = turns.last;
      expect(newest.tools.any(_isTrimmed), isFalse);
      final done = newest.tools.where((u) => u['status'] == 'completed').toList();
      expect(done, hasLength(28));
      for (final u in done) {
        final out = u['rawOutput'] ?? _text(_m((u['content'] as List).first));
        expect((out as String).length, greaterThanOrEqualTo(20 * 1024));
      }
      expect(newest.tools, hasLength(28 * 3), reason: 'nothing merged in a turn that was not cut');
    });

    test('with the soft budget raised to the hard one, detail stays until 16 MB: the newest turns are whole', () async {
      final h = await newHost({'HERDR_KEEPER_LOG_SOFT_BYTES': '${16 * 1024 * 1024}'});
      final info = await h.start();
      await detached(h, info.id, 12, '28:20:100');
      final r = await replay(h, info.id);

      final turns = _turnsOf(r.updates);
      expect(turns, hasLength(12));
      expect(turns.last.answer, 'answer 11');
      expect(r.bytes, lessThanOrEqualTo(16 * 1024 * 1024));
      expect(r.bytes, greaterThan(12 * 1024 * 1024));
      expect(_herdr(r.load)['trimmedTurns'], lessThan(5), reason: 'only what the hard bound forced');
      for (final t in turns.skip(9)) {
        expect(t.tools.any(_isTrimmed), isFalse, reason: t.user);
      }
    });

    test('a flood of 200 turns stays inside the bounds, keeps whole turns, and counts what it dropped', () async {
      final h = await newHost({'HERDR_KEEPER_LOG_BYTES': '2097152', 'HERDR_KEEPER_LOG_MESSAGES': '1500'});
      final info = await h.start();
      await detached(h, info.id, 200, '10:1:3');
      final r = await replay(h, info.id);

      expect(r.updates.length, lessThanOrEqualTo(1500));
      expect(r.bytes, lessThanOrEqualTo(2097152));
      final turns = _turnsOf(r.updates);
      final herdr = _herdr(r.load);
      final dropped = herdr['droppedTurns']! as int;
      expect(dropped, greaterThan(0));
      // Whole turns, newest first kept: nothing in the middle is missing.
      expect(dropped + turns.length, 200);
      expect(turns.map((t) => t.user), [for (var i = dropped; i < 200; i++) 'heavy:10:1:3:$i']);
      for (final t in turns) {
        expect(t.answer, 'answer ${t.user.split(':').last}', reason: t.user);
        expect(t.tools.map((u) => u['toolCallId']).toSet(), hasLength(10), reason: '${t.user} keeps every call');
      }
      expect(herdr['trimmedTurns'], turns.where((t) => t.tools.any(_isTrimmed)).length);
      // The newest turn is never cut. (The entry bound, unlike the byte
      // budgets, also cuts the turns before it, to save entries.)
      expect(turns.last.tools.any(_isTrimmed), isFalse, reason: turns.last.user);
      expect(turns.last.tools, hasLength(30));
    });

    test('a turn in flight that alone passes the soft budget is untouched; the older turns are trimmed', () async {
      final h = await newHost();
      final info = await h.start();
      await detached(h, info.id, 3, '28:20:100');
      final b = await h.attach(info.id);
      await b.initialize();
      await b.load(h);
      b.prompt('heavyhold:28:20:100:open');
      await b.next((m) {
        if (m['method'] != 'session/update') return false;
        final u = _m(_m(m['params'])['update']);
        return u['toolCallId'] == 'topen-27' && u['status'] == 'completed';
      });
      await b.close();

      final r = await replay(h, info.id);
      final turns = _turnsOf(r.updates);
      expect(turns.map((t) => t.user), [
        'heavy:28:20:100:0',
        'heavy:28:20:100:1',
        'heavy:28:20:100:2',
        'heavyhold:28:20:100:open',
      ]);
      final open = turns.last;
      expect(open.tools, hasLength(28 * 3));
      expect(open.tools.any(_isTrimmed), isFalse);
      expect(turns.take(3).every((t) => t.tools.every(_isTrimmed)), isTrue);
      expect(_herdr(r.load), {'droppedTurns': 0, 'trimmedTurns': 3});
      expect(r.bytes, greaterThan(1536 * 1024), reason: 'the open turn is over the soft budget by itself');
    });

    test('the turn in flight is never trimmed or dropped', () async {
      final h = await newHost({'HERDR_KEEPER_LOG_BYTES': '400000'});
      final info = await h.start();
      await detached(h, info.id, 40, '10:20:40');
      final b = await h.attach(info.id);
      await b.initialize();
      await b.load(h);
      b.prompt('heavyhold:10:20:40:open');
      await b.next((m) {
        if (m['method'] != 'session/update') return false;
        final u = _m(_m(m['params'])['update']);
        return u['toolCallId'] == 'topen-9' && u['status'] == 'completed';
      });
      await b.close();

      final r = await replay(h, info.id);
      final turns = _turnsOf(r.updates);
      final open = turns.last;
      expect(open.user, 'heavyhold:10:20:40:open');
      expect(open.answer, isNull, reason: 'it has not answered yet');
      expect(open.tools, hasLength(30));
      expect(open.tools.any(_isTrimmed), isFalse);
      for (final u in open.tools.where((u) => u['status'] == 'completed')) {
        expect(u['rawOutput'] ?? _text(_m((u['content'] as List).first)), isA<String>());
      }
      expect(_herdr(r.load)['droppedTurns']! as int, greaterThan(0), reason: 'older turns went, to make room');
      for (final t in turns.where((t) => t != open)) {
        expect(t.answer, 'answer ${t.user.split(':').last}', reason: 'older turns that stay are whole');
      }
    });

    test('taking a refused prompt back keeps the turns and counters consistent', () async {
      final dir = Directory.systemTemp.createTempSync('keeper_log_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final script = File('${dir.path}/keeper.py')..writeAsStringSync(keeperScript());
      final probe = File('${dir.path}/probe.py')..writeAsStringSync(_removeProbe);
      final r = await Process.run('python3', [probe.path, script.path]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final out = _m(jsonDecode(r.stdout as String));
      List<Object?> sound(Json t) => [t['bytesOk'], t['countOk'], t['lastOk']];

      final refused = _m(out['refused']);
      expect(refused['turns'], 1, reason: 'what the agent streamed meanwhile joins the turn before');
      expect(refused['texts'], ['first', 'answer', 'own 0', 'own 1', 'own 2']);
      expect(sound(refused), [true, true, true]);

      final alone = _m(out['alone']);
      expect(alone['turns'], 0);
      expect(sound(alone), [true, true, true]);
      final again = _m(out['aloneThenAdd']);
      expect(again['texts'], ['after']);
      expect(sound(again), [true, true, true]);

      expect(out['sameEntry'], isTrue);
      final two = _m(out['twoBlocks']);
      expect(two['texts'], ['before', 'reply']);
      expect(sound(two), [true, true, true]);

      expect(out['ghost'], [false, true]);

      final bounded = _m(out['bounded']);
      expect(sound(bounded), [true, true, true]);
      expect(out['boundedDropped'], 0, reason: 'forty refused attempts took no room from the four real turns');
      expect((bounded['texts'] as List).where((t) => (t as String).startsWith('q')), hasLength(4));
    });

    test('the log is plain python that can be loaded: pinned turns, state carry, and the hot path', () async {
      final dir = Directory.systemTemp.createTempSync('keeper_log_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final script = File('${dir.path}/keeper.py')..writeAsStringSync(keeperScript());
      final probe = File('${dir.path}/probe.py')..writeAsStringSync(_logProbe);
      final r = await Process.run('python3', [probe.path, script.path]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final out = _m(jsonDecode(r.stdout as String));

      // A request waits on a tool call of the OLDEST turn: that turn stays,
      // whole, while the others make room.
      final pinned = _m(out['pinned']);
      expect(pinned['oldHasRaw'], isTrue);
      expect(pinned['oldKept'], isTrue);
      expect(pinned['otherDropped'], greaterThan(0));
      expect(pinned['newestKept'], isTrue);
      expect(pinned["bytes"], lessThanOrEqualTo(30000));
      // The last mode and command list of the dropped turns still reach a replay.
      for (final key in ['carryWhole', 'carryCut']) {
        final c = _m(out[key]);
        expect(c['carry'], ['available_commands_update', 'current_mode_update'], reason: key);
        expect(c['mode'], ['plan'], reason: key);
        expect(['available_commands_update', 'current_mode_update'], contains(c['first']), reason: '$key: state replays before the turns');
      }
      expect(_m(out['carryWhole'])['dropped'], greaterThan(0));
      // Heavy turns: every question stays; the newest turn keeps all its output.
      final fat = _m(out['fat']);
      expect(fat['users'], 12);
      expect(fat['dropped'], 0);
      expect(fat['newestRaw'], 28);
      expect(fat['bytes'], lessThanOrEqualTo(2500 * 1024), reason: 'one whole turn and skeletons');
      // 600 heavy turns under the soft budget: all there, one whole, none dropped.
      final soft = _m(out['soft']);
      expect(soft['turns'], 600);
      expect(soft['dropped'], 0);
      expect(soft['trimmed'], 599);
      expect(soft['bytes'] as int, lessThanOrEqualTo((soft['newestBytes'] as int) + 600 * 12 * 1024));
      expect(soft['seconds'], lessThan(20));
      // Nothing re-scans the log per update: 60000 updates, bounded at 20000 entries.
      expect(out['seconds'], lessThan(20));
      expect(out['count'], lessThanOrEqualTo(20000));
      expect(out['hotDropped'], greaterThan(0));
    });
  });

  group('alert hook', skip: hasPython ? false : 'python3 is not installed', () {
    const record = r'''printf '%s|%s|%s|%s|%s|%s\n' "$KEEPER_EVENT" "$KEEPER_ID" "$KEEPER_AGENT" "$KEEPER_CWD" "$KEEPER_TITLE" "$KEEPER_SUMMARY" >> "$HOME/hook.out"''';

    List<List<String>> events(_Host h) {
      final f = File(h.hookOut);
      if (!f.existsSync()) return [];
      return [
        for (final l in f.readAsLinesSync())
          if (l.isNotEmpty) l.split('|'),
      ];
    }

    test('fires when a request is held, with the environment and a redacted summary', () async {
      final h = await newHost();
      await h.writeHook(record);
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      final p = a.prompt(
        'perm:curl -H "Authorization: Bearer abcdef1234567890" https://u:pw@x.io?token=zzz1234 sk-abcdefghijklmnop12',
      );
      final perm = await a.next(_method('session/request_permission'));
      await eventually(() => events(h).isNotEmpty, what: 'the hook to run');
      final e = events(h).single;
      expect(e[0], 'blocked');
      expect(e[1], info.id);
      expect(e[2], 'omp');
      expect(e[3], h.work);
      expect(e[5], contains('curl'));
      for (final secret in ['abcdef1234567890', 'pw@', 'zzz1234', 'sk-abcdefghijklmnop12']) {
        expect(e[5], isNot(contains(secret)), reason: e[5]);
      }
      expect(e[5].length, lessThanOrEqualTo(120));
      a.reply(perm['id'], {
        'outcome': {'outcome': 'cancelled'},
      });
      await a.response(p);
      // The user was looking: no "done".
      // Absence of a hook cannot be polled for: wait a minimum time (a loaded
      // machine only makes it longer, never flaky).
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(events(h), hasLength(1));
    });

    test('a question reports its first line', () async {
      final h = await newHost();
      await h.writeHook(record);
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      a.prompt('ask');
      final perm = await a.next(_method('session/request_permission'));
      a.reply(perm['id'], {
        'outcome': {'outcome': 'selected', 'optionId': 'allow'},
      });
      await eventually(() => events(h).length == 2, what: 'two hooks');
      // Each event runs the hook as a process of its own, started a moment
      // apart, and the file is appended to by whichever finishes first: its
      // line order is the order the processes ended, not the order of the
      // events. So the lines are told apart by what they say.
      final byLine = {for (final e in events(h)) e[5]: e};
      expect(byLine.keys, unorderedEquals(['Run: ls -la', 'Pick one?']));
      expect(byLine['Run: ls -la']![0], 'blocked');
      expect(byLine['Pick one?']![0], 'blocked');
      expect(byLine['Pick one?']![4], 'Fake title');
    });

    test('fires "done" when a turn ends while nobody is attached', () async {
      final h = await newHost();
      await h.writeHook(record);
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      a.prompt('sleep:1');
      await a.close();
      await eventually(() => events(h).isNotEmpty, what: 'the done hook');
      final e = events(h).single;
      expect(e.sublist(0, 4), ['done', info.id, 'omp', h.work]);
      expect(e[5], 'Turn finished (end_turn)');
    });

    test('~/.herdr-mobile/on-blocked is the default and must be executable', () async {
      final h = await newHost({'HERDR_KEEPER_ON_BLOCKED': ''});
      Directory('${h.home.path}/.herdr-mobile').createSync();
      final path = '${h.home.path}/.herdr-mobile/on-blocked';
      File(path).writeAsStringSync('#!/bin/sh\n$record\n'); // not executable yet
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      final p1 = a.prompt('perm:first');
      final perm1 = await a.next(_method('session/request_permission'));
      a.reply(perm1['id'], {
        'outcome': {'outcome': 'cancelled'},
      });
      await a.response(p1);
      // Absence of a hook cannot be polled for: wait a minimum time (a loaded
      // machine only makes it longer, never flaky).
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(events(h), isEmpty);

      await Process.run('chmod', ['755', path]);
      final p2 = a.prompt('perm:second');
      final perm2 = await a.next(_method('session/request_permission'));
      a.reply(perm2['id'], {
        'outcome': {'outcome': 'cancelled'},
      });
      await a.response(p2);
      await eventually(() => events(h).isNotEmpty, what: 'the default hook');
      expect(events(h).single[5], 'second');
    });

    test('a hook that hangs is killed after 5 s and never blocks the keeper', () async {
      final h = await newHost();
      await h.writeHook('echo \$\$ > "\$HOME/hook.pid"\nexec sleep 30');
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      final p = a.prompt('perm:slow hook');
      final perm = await a.next(_method('session/request_permission'));
      final pidFile = File('${h.home.path}/hook.pid');
      await eventually(() => pidFile.existsSync() && pidFile.readAsStringSync().trim().isNotEmpty, what: 'hook pid');
      final pid = int.parse(pidFile.readAsStringSync().trim());
      expect(await _alive(pid), isTrue);
      // The keeper still serves while the hook hangs: the answer reaches the
      // agent (blocked in its permission wait) and the turn ends.
      a.reply(perm['id'], {
        'outcome': {'outcome': 'cancelled'},
      });
      expect(_m((await a.response(p))['result'])['stopReason'], 'end_turn');
      await eventually(() async => !await _alive(pid), what: 'the hook process to be killed after its 5 s');
    });

    test('a 100 KB command in a permission request does not stall the keeper', () async {
      final h = await newHost();
      await h.writeHook(record);
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      final p = a.prompt('perm:${'a.' * 50000}');
      final perm = await a.next(_method('session/request_permission'));
      expect((_m(_m(perm['params'])['toolCall'])['title']! as String).length, 100000); // shown whole
      await eventually(() => events(h).isNotEmpty, what: 'the hook to run');
      expect(events(h).single[5].length, lessThanOrEqualTo(120));
      expect(events(h).single[5], startsWith('a.a.a.'));
      expect((await h.list()).single.pending, 1);
      a.reply(perm['id'], {
        'outcome': {'outcome': 'cancelled'},
      });
      expect(_m((await a.response(p))['result'])['stopReason'], 'end_turn');
    });

    test('redaction is instant on hostile lines and masks the secret whole', () async {
      final h = await newHost();
      final script = keeperScript();
      final probe = File('${h.home.path}/redact_probe.py')
        ..writeAsStringSync(
          '${script.substring(0, script.lastIndexOf('if __name__ == "__main__":'))}\n'
          '''
import time
cases = ["a." * 50000, "token" * 20000, "Authorization: Bearer " + "b" * 100000, "api_key=" + "k" * 100000,
         "http://u:" + "p" * 100000 + "@x", ("A1" * 14 + " ") * 5000, "\\n" * 50000 + "late line"]
out = []
for text in cases:
    t0 = time.perf_counter()
    r = redact_line(text)
    out.append([(time.perf_counter() - t0) * 1000, r])
print(json.dumps(out))
''',
        );
      final r = await h.run("python3 '${probe.path}'");
      expect(r.code, 0, reason: r.err);
      final out = [for (final e in jsonDecode(r.out) as List) (e as List).cast<Object?>()];
      for (final e in out) {
        // The quadratic version took 7800 ms on such a line; this is ~1 ms idle.
        expect(e[0]! as num, lessThan(1500), reason: '${e[1]}');
        expect((e[1]! as String).length, lessThanOrEqualTo(120));
      }
      expect(out[2][1], 'Authorization: *** ***');
      expect(out[3][1], 'api_key=***');
    });
  });

  group('KeeperInfo', () {
    test('reads what the script prints', () {
      final info = KeeperInfo.fromJson(
        _m(
          jsonDecode(
            '{"id":"abc234","agent":"omp","cwd":"/w","state":"exited","started_at":1791107532538,'
            '"pid":42,"pending":0,"agent_pid":43,"session_id":"s","title":"t","last_event_at":1791107547185,'
            '"exit_code":3,"exit_reason":"The agent exited with code 3. boom","exited_at":1791107567577}',
          ),
        ),
      );
      expect(info.id, 'abc234');
      expect(info.state, KeeperState.exited);
      expect(info.startedAt, DateTime.fromMillisecondsSinceEpoch(1791107532538));
      expect(info.lastEventAt, DateTime.fromMillisecondsSinceEpoch(1791107547185));
      expect(info.pid, 42);
      expect(info.exitCode, 3);
      expect(info.exitReason, contains('boom'));
      expect(info.sessionId, 's');
      expect(info.title, 't');
      final back = KeeperInfo.fromJson(info.toJson());
      expect(back.exitReason, info.exitReason);
      expect(back.exitCode, 3);
    });

    test('turn_active and unseen_done default to false and round-trip', () {
      final bare = KeeperInfo.fromJson({'id': 'abc234', 'state': 'running'});
      expect(bare.turnActive, isFalse);
      expect(bare.unseenDone, isFalse);
      final set = KeeperInfo.fromJson({'id': 'abc234', 'turn_active': true, 'unseen_done': true, 'state': 'starting'});
      expect(set.turnActive, isTrue);
      expect(set.unseenDone, isTrue);
      expect(set.state, KeeperState.running);
      final back = KeeperInfo.fromJson(set.toJson());
      expect(back.turnActive, isTrue);
      expect(back.unseenDone, isTrue);
      expect(KeeperInfo.fromJson({'id': 'x', 'turn_active': 'yes'}).turnActive, isFalse);
    });
  });
}
