// What opening an agent's chat costs the phone's link, deterministic and with
// no phone: bytes on the wire, sequential round trips and the phone-side CPU.
//
//   BENCH_OUT=/tmp/open.txt flutter test benchmark/session_open_wire_bench_test.dart
//
// The REAL keeper (the `herdr-host` binary, temp HOME, the testkit's
// `bench-acp-agent` as the agent) is seeded with a session built from the
// recorded traces (`support/session_workload.dart`, fixed seed), and the REAL
// `AcpAgentSession.acquire()` opens it the way the app does: `SshAgentHost`
// over one `HostLink` on a `herdr-host serve` process (`LocalKeeperHost`), a
// `keeper.attach` stream on it. Every byte the host writes on that stream is
// counted before anything reads it (frame headers included), so `wire_kb` is
// what the SSH channel would carry towards the phone (SSH framing and the
// requests towards the host, a few hundred bytes, are not counted).
//
//  * cold: the session is opened with nothing on the phone;
//  * copy: opened again by a new session object that holds the saved copy of
//    the first (`TranscriptCache`), as after a restart of the app, or when the
//    chat is tapped again after being let go. The copy is shown at once; what
//    matters is what the attach still costs and when the session can be
//    answered (`live`).
//
// Variants: `zip` opens the stream the way the app does (zctx: the host
// deflates it as one continuous zlib stream, sync-flushed per frame); `plain`
// opens it without zctx. The names are the old ones, from when the phone asked
// for a `zipped` attach. `plain` is NOT uncompressed: a stream without zctx
// still has every frame of 512 bytes or more deflated on its own by the host
// (`send` in rust/crates/host/src/session.rs), so the comparison is what the
// stream's shared zlib context saves over per-frame deflate. The uncompressed
// replay is `load_bytes` of `session_open_bench.dart` (about 1.4 MB here).
//
// `rtts` is the depth of the chain of requests the open waits on (a request
// sent after the answer to another has arrived is one level deeper). The app
// keeps one link to the host, so a stream costs no channel to open: its OPEN
// frame and the first request travel together and the first answer is the
// first level (the old model added 2 round trips for the SSH exec channel an
// attach used to be; a first use on a new connection pays about 3, once, and
// is not in these numbers). The modelled open time on a link is
//
//     rtts * RTT + wire_bytes * 8 / rate + phone_cpu_ms
//
// ASSUMPTIONS, not measurements: the links (`_links`), no loss, no slow start,
// and `phone_cpu_ms`, which is CPU time of the main thread on THIS machine
// (JIT, asserts on: a phone is slower, and what it costs there is unverified).
// Use the modelled time to compare changes, not to quote.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/acp/json_rpc.dart';
import 'package:herdr_mobile/data/acp/past_session.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/acp_agent_session.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import '../test/support/fake_transport.dart';
import '../test/support/memory_transcript_cache.dart';
import 'support/cpu_clock.dart';
import 'support/local_keeper.dart';
import 'support/session_workload.dart' hide Json;

final _env = Platform.environment;
final _items = int.parse(_env['OPEN_ITEMS'] ?? '600');
final _runs = int.parse(_env['OPEN_RUNS'] ?? '5');
final _agent = _env['OPEN_AGENT'] ?? 'mixed';

/// (name, round trip ms, megabits a second towards the phone)
const _links = [('fast', 40.0, 30.0), ('mid', 120.0, 10.0), ('slow', 300.0, 2.0)];

final _out = <String>[];

void _metric(String name, num value) => _out.add('METRIC $name=${value is int ? value : value.toStringAsFixed(3)}');

double _median(List<double> v) {
  final s = [...v]..sort();
  return s.length.isOdd ? s[s.length ~/ 2] : (s[s.length ~/ 2 - 1] + s[s.length ~/ 2]) / 2;
}

/// What one open of the session cost.
class _Open {
  _Open({required this.wireBytes, required this.depth, required this.cpuMs, required this.liveMs});

  final int wireBytes;
  final int depth;
  final double cpuMs;
  final double liveMs;

  int get rtts => depth;

  double modelledMs(double rttMs, double mbit) => rtts * rttMs + wireBytes * 8 / (mbit * 1000) + cpuMs;
}

/// The attach as the app reads it, noting how deep the chain of requests is.
/// The bytes are the meter's, per stream ([LocalKeeperHost.meter]).
class _Metered implements AcpTransport {
  _Metered(this._inner, this.streamId) {
    lines = _inner.lines.map(_seen);
  }

  final AcpTransport _inner;

  /// The attach's stream on the link.
  final int streamId;

  // The depth of the request chain: a request sent after the answer to
  // another arrived is one level deeper than that one.
  final _levels = <Object, int>{};
  var _answered = 0;
  var depth = 0;

  @override
  late final Stream<String> lines;

  String _seen(String line) {
    // Answers are small; the replay's notifications are not worth a decode.
    if (line.length < 16000 && line.contains('"id"')) {
      try {
        final j = jsonDecode(line);
        if (j is Map && !j.containsKey('method') && _levels.containsKey(j['id'])) {
          _answered = math.max(_answered, _levels[j['id']]!);
        }
      } on FormatException {
        // not JSON: nothing to learn
      }
    }
    return line;
  }

  @override
  void send(String line) {
    try {
      final j = jsonDecode(line);
      if (j is Map && j['method'] != null && j.containsKey('id')) {
        final level = _answered + 1;
        _levels[j['id'] as Object] = level;
        depth = math.max(depth, level);
      }
    } on FormatException {
      // not JSON
    }
    _inner.send(line);
  }

  @override
  Future<void> close() => _inner.close();
}

class _MeteredHost implements AgentHost {
  _MeteredHost(this.inner);

  final LocalKeeperHost inner;
  _Metered? last;

  @override
  Future<AcpTransport> attach(String keeperId) async {
    final attached = await inner.attach(keeperId);
    return last = _Metered(attached, inner.opens.last.id);
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

/// Plays the seed through the keeper: a session of [n] items in its log.
Future<String> _seed(LocalKeeperHost host, int n) async {
  final updates = buildSession(TracePools.load(), n, agent: _agent, bigShare: 0.02);
  final file = File('${host.home.path}/seed_$n.jsonl')..writeAsStringSync('${updates.map(jsonEncode).join('\n')}\n');
  final info = await host.start(agent: 'omp', cwd: host.work, seedFile: file.path);
  final t = await host.attach(info.id);
  var next = 0;
  final waiting = <int, Completer<void>>{};
  final sub = t.lines.listen((line) {
    if (line.length > 16000) return;
    final j = jsonDecode(line);
    if (j is Map && !j.containsKey('method') && waiting[j['id']] != null) waiting.remove(j['id'])!.complete();
  });
  Future<void> call(String method, Map<String, Object?> params) {
    final id = ++next;
    final c = waiting[id] = Completer<void>();
    t.send(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
    return c.future.timeout(const Duration(minutes: 5));
  }

  await call('initialize', {'protocolVersion': 1, 'clientCapabilities': <String, Object?>{}});
  await call('session/new', {'cwd': host.work, 'mcpServers': <Object?>[]});
  await call('session/prompt', {
    'sessionId': 'bench-session',
    'prompt': [
      {'type': 'text', 'text': 'seed'},
    ],
  });
  await sub.cancel();
  await t.close();
  return info.id;
}

/// One open of [info] by a new session object, to a live link. [cache] holds
/// the saved copy, if any.
Future<_Open> _open(
  MachineConnection machine,
  LocalKeeperHost host,
  KeeperInfo info, {
  MemoryTranscriptCache? cache,
}) async {
  final metered = _MeteredHost(host);
  final session = AcpAgentSession(machine: machine, host: metered, info: info, cache: cache);
  final live = Completer<void>();
  void listener() {
    if (!live.isCompleted &&
        session.link == AgentLink.live &&
        !session.state.replaying &&
        session.state.items.isNotEmpty) {
      live.complete();
    }
  }

  session.addListener(listener);
  final wall = Stopwatch()..start();
  final c0 = threadCpuMicros();
  session.acquire();
  await live.future.timeout(const Duration(minutes: 2));
  final cpuMs = (threadCpuMicros() - c0) / 1000;
  final liveMs = wall.elapsedMicroseconds / 1000;
  final m = metered.last!;
  final open = _Open(wireBytes: host.meter.stream(m.streamId).bytes, depth: m.depth, cpuMs: cpuMs, liveMs: liveMs);
  session.removeListener(listener);
  session.release();
  // Written when the last screen lets go; the copy of a later open.
  await Future<void>.delayed(const Duration(milliseconds: 120));
  session.dispose();
  return open;
}

void main() {
  LocalKeeperHost? host;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    host = await LocalKeeperHost.create();
  });

  tearDownAll(() async {
    await host?.dispose();
    final text = '${_out.join('\n')}\n';
    final path = _env['BENCH_OUT'];
    if (path != null) {
      File(path).writeAsStringSync(text);
    } else {
      stdout.write(text);
    }
  });

  test('what opening a chat costs the link', timeout: const Timeout(Duration(minutes: 20)), () async {
    final h = host!;
    final id = await _seed(h, _items);
    final machine = MachineConnection(
      profile: const MachineProfile(id: 'm', label: 'bench', host: 'h', username: 'u'),
      api: HerdrApi(FakeTransport()),
      backoff: (_) => const Duration(hours: 1),
      pollInterval: const Duration(hours: 1),
    )..start();
    for (var i = 0; i < 200 && !machine.isLive; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(machine.isLive, isTrue);
    final info = (await h.list()).singleWhere((k) => k.id == id);

    // The first attach after seeding also carries "a turn ended while nobody
    // looked" and warms the page cache: not counted.
    await _open(machine, h, info);

    for (final zctx in [false, true]) {
      h.zctx = zctx;
      final cold = <_Open>[];
      for (var i = 0; i < _runs; i++) {
        cold.add(await _open(machine, h, info));
      }
      final p = zctx ? 'zip' : 'plain';
      _report(p, 'cold', cold);

      // The same chat again, a copy on the phone.
      final cache = MemoryTranscriptCache();
      await _open(machine, h, info, cache: cache); // writes the copy
      expect(cache.stored, isNotEmpty, reason: 'the first open left a saved copy');
      final again = <_Open>[];
      for (var i = 0; i < _runs; i++) {
        again.add(await _open(machine, h, info, cache: cache));
      }
      _report(p, 'copy', again);
    }
    machine.dispose();
  });
}

void _report(String variant, String scenario, List<_Open> runs) {
  final q = '${variant}_$scenario';
  final wire = runs.first.wireBytes; // the replay is the same every time
  _metric('${q}_wire_kb', wire / 1024);
  _metric('${q}_rtts', runs.first.rtts);
  final cpu = _median([for (final r in runs) r.cpuMs]);
  _metric('${q}_phone_cpu_ms', cpu);
  final byLink = _Open(wireBytes: wire, depth: runs.first.depth, cpuMs: cpu, liveMs: 0);
  for (final (name, rtt, mbit) in _links) {
    _metric('${q}_open_${name}_ms', byLink.modelledMs(rtt, mbit));
  }
}
