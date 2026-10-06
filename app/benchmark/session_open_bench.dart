// Open-a-chat benchmark: where the time goes between a tap on a session and a
// transcript that is live.
//
//   flutter test benchmark/session_open_bench.dart
//
// Needs python3 (the keeper), and for the SSH calibration the sshd and key
// that `transfer_bench.dart` uses (skipped when they are not there). Results
// go to $BENCH_OUT as METRIC lines (`flutter test` decorates stdout); without
// it they are printed.
//
// What runs, per size (20, 150, 600, 1500 transcript items; the keeper's log
// holds at most 4 MB / 4000 entries, so a long session is the newest part of
// what happened, and `items` says what it really is):
//
//  1. the REAL keeper script (temp HOME, `bench_acp_agent.py` as its agent) is
//     seeded with a session built from the recorded traces
//     (`support/session_workload.dart`);
//  2. per run: attach to first byte, `initialize` round trip, `session/load`
//     to its answer with the bytes and line arrival times of the replay
//     (`attach_*`, `init_*`, `load_*`); what deflate would make of the replay
//     (`zip_*`); the reducer on the replayed lines (`fold_*`);
//  3. `AcpAgentSession.acquire()` to a live link on a machine at link RTT 0,
//     40, 120 ms (`open_*`), cold and with the transcript already held;
//  4. the screen: `AgentSessionScreen` pushed with the 260 ms page transition
//     over a final state, over an empty one that is then filled, and over a
//     state that grows while the replay arrives (`ui_*`);
//  5. memory held per state (`mem_*`) and the SSH exec channel's own cost for
//     the same bytes (`ssh_*`).
//
// Timings are milliseconds on THIS machine (JIT, asserts on: `flutter test`),
// medians over the runs. Steps that are CPU-bound (the reducer, zlib, frames)
// are thread CPU time, so the load of a shared machine does not move them;
// steps that wait (processes, the link model) are wall time and `loadavg1_*`
// says how quiet the box was. A phone is slower; see the doc for what that
// means.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/json_rpc.dart' show splitLines;
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/acp_agent_session.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/transport_factory.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';

import '../test/support/fake_agent_session.dart';
import '../test/support/fake_transport.dart';
import '../test/support/shot.dart' show loadAppFonts;
import 'support/cpu_clock.dart';
import 'support/local_keeper.dart';
import 'support/session_workload.dart' hide Json;

final _env = Platform.environment;
final _sizes = [for (final s in (_env['SESSION_OPEN_SIZES'] ?? '20,150,600,1500').split(',')) int.parse(s.trim())];
final _runs = int.parse(_env['SESSION_OPEN_RUNS'] ?? '7');
final _uiRuns = int.parse(_env['SESSION_OPEN_UI_RUNS'] ?? '5');
final _streamRuns = int.parse(_env['SESSION_OPEN_STREAM_RUNS'] ?? '3');
final _agent = _env['SESSION_OPEN_AGENT'] ?? 'mixed';

/// Share of tool calls with a 20-200 KB output. 2% is a long session of
/// ordinary work; `SESSION_OPEN_BIG=0.06` is a heavy one (big file reads,
/// test logs and whole-file diffs).
final _bigShare = double.parse(_env['SESSION_OPEN_BIG'] ?? '0.02');

/// Opens thrown away before the UI runs count: the JIT and the glyph caches.
const _warm = 3;

/// The links the open is repeated on. Bandwidth is an ASSUMPTION per link
/// (Wi-Fi to a LAN host; LTE/5G through a tunnel), not a measurement.
const _links = [
  LinkModel('local', 0, 0),
  LinkModel('rtt40', 40, 30),
  LinkModel('rtt120', 120, 10),
];

final _out = <String>[];

void _metric(String name, num value) => _out.add('METRIC $name=${value is int ? value : value.toStringAsFixed(3)}');

/// The machine's 1-minute load at the start and the end of the run: the
/// wall-clock numbers are only as quiet as this box was.
void _loadavg(String when) {
  final f = File('/proc/loadavg');
  if (f.existsSync()) _metric('loadavg1_$when', double.parse(f.readAsStringSync().split(' ').first));
}

double _min(List<double> v) => v.isEmpty ? double.nan : v.reduce(math.min);

double _median(List<double> v) {
  if (v.isEmpty) return double.nan;
  final s = [...v]..sort();
  return s.length.isOdd ? s[s.length ~/ 2] : (s[s.length ~/ 2 - 1] + s[s.length ~/ 2]) / 2;
}

double _pct(List<double> v, double p) {
  final s = [...v]..sort();
  return s.isEmpty ? double.nan : s[math.min(s.length - 1, (s.length * p).floor())];
}

/// utime + stime of every thread of this process, in ms.
double _cpuMs() {
  var ticks = 0;
  for (final t in Directory('/proc/self/task').listSync()) {
    final String stat;
    try {
      stat = File('${t.path}/stat').readAsStringSync();
    } on FileSystemException {
      continue; // the thread ended between the listing and the read
    }
    final f = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
    ticks += int.parse(f[11]) + int.parse(f[12]);
  }
  return ticks * 10.0; // CLK_TCK is 100
}

// ---------------------------------------------------------------------------
// A raw attach: the keeper's stdout with the time every chunk came.
// ---------------------------------------------------------------------------

class _Replay {
  _Replay(this.lines, this.arrivalMs, this.bytes, this.lineBytes, this.loadMs, this.firstLineMs);

  /// The lines of the replay (without the answer), as the client gets them.
  final List<String> lines;

  /// When each line (and the answer) was complete, ms after the request.
  final List<double> arrivalMs;
  final int bytes;
  final List<int> lineBytes;
  final double loadMs;
  final double firstLineMs;
}

class _Attach {
  _Attach(this.process, this.clock) {
    process.stdout.listen(_onData);
    process.stderr.drain<void>();
  }

  final Process process;
  final Stopwatch clock;
  final _bytes = BytesBuilder(copy: false);
  final _ends = <int>[];
  final _times = <int>[];
  var _tail = '';
  final _waiters = <({RegExp pattern, Completer<int> done})>[];
  var _next = 0;
  late final Future<int> firstByteUs = (() {
    final c = Completer<int>();
    _first = c;
    return c.future;
  })();
  Completer<int>? _first;

  void _onData(List<int> chunk) {
    final t = clock.elapsedMicroseconds;
    _first?.complete(t);
    _first = null;
    _bytes.add(chunk);
    _ends.add(_bytes.length);
    _times.add(t);
    final joined = _tail + latin1.decode(chunk);
    _tail = joined.length > 2048 ? joined.substring(joined.length - 2048) : joined;
    for (final w in [..._waiters]) {
      if (w.pattern.hasMatch(_tail)) {
        _waiters.remove(w);
        w.done.complete(t);
      }
    }
  }

  /// Sends a request; completes with (sent at µs, answered at µs, byte offset
  /// where the output of this request starts).
  Future<({int sent, int done, int from})> call(String method, Json params, {Duration timeout = const Duration(seconds: 120)}) async {
    final id = ++_next;
    final waiter = (pattern: RegExp('"id"\\s*:\\s*$id\\s*[,}]'), done: Completer<int>());
    _waiters.add(waiter);
    final from = _bytes.length;
    final sent = clock.elapsedMicroseconds;
    process.stdin.add(utf8.encode('${jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params})}\n'));
    final done = await waiter.done.future.timeout(timeout);
    return (sent: sent, done: done, from: from);
  }

  Future<void> close() async {
    await process.stdin.close();
    await process.exitCode.timeout(const Duration(seconds: 30));
  }

  /// The lines output since [from], up to and including the answer to request [id].
  _Replay replay(int id, int from, int sent, int done) {
    final all = _bytes.toBytes();
    final answer = RegExp('"id"\\s*:\\s*$id\\s*[,}]');
    final lines = <String>[];
    final arrivals = <double>[];
    final sizes = <int>[];
    var start = from;
    var k = 0;
    double? first;
    while (start < all.length) {
      final nl = all.indexOf(10, start);
      if (nl < 0) break;
      final end = nl + 1;
      while (_ends[k] < end) {
        k++;
      }
      final text = utf8.decode(Uint8List.sublistView(all, start, nl));
      final at = (_times[k] - sent) / 1000;
      start = end;
      if (text.trim().isEmpty) continue;
      if (text.length < 400 && !text.contains('"method"') && answer.hasMatch(text)) {
        arrivals.add(at);
        break;
      }
      first ??= at;
      lines.add(text);
      arrivals.add(at);
      sizes.add(utf8.encode(text).length + 1);
    }
    final wire = sizes.fold<int>(0, (a, b) => a + b);
    return _Replay(lines, arrivals, wire, sizes, (done - sent) / 1000, first ?? double.nan);
  }
}

// ---------------------------------------------------------------------------
// The reducer on a replay.
// ---------------------------------------------------------------------------

typedef _Fold = ({
  double decodeMs,
  double parseMs,
  double applyMs,
  List<double> applyUs,
  AgentSessionState state,
  List<SessionUpdate> updates,
});

_Fold _fold(List<String> lines, AcpSessionSetup setup) {
  var s = const AgentSessionState('bench-session', replaying: true);
  final decode = CpuWatch();
  final parse = CpuWatch();
  final apply = CpuWatch();
  final per = <double>[];
  final updates = <SessionUpdate>[];
  final at = DateTime.now();
  for (final line in lines) {
    decode.start();
    final j = jsonDecode(line) as Map;
    decode.stop();
    if (j['method'] != 'session/update') continue;
    parse.start();
    final u = SessionUpdate.parse((j['params'] as Map)['update']);
    parse.stop();
    updates.add(u);
    final t0 = apply.elapsedMicroseconds;
    apply.start();
    s = s.apply(u, at: at);
    apply.stop();
    per.add(apply.elapsedMicroseconds - t0.toDouble());
  }
  return (
    decodeMs: decode.elapsedMicroseconds / 1000,
    parseMs: parse.elapsedMicroseconds / 1000,
    applyMs: apply.elapsedMicroseconds / 1000,
    applyUs: per,
    state: s.withSetup(setup),
    updates: updates,
  );
}

/// Index of the first line of the shortest tail of [lines] that touches the
/// last [items] distinct messages/tool calls.
int _tailStart(List<String> lines, int items) {
  final seen = <String>{};
  for (var i = lines.length - 1; i >= 0; i--) {
    final j = jsonDecode(lines[i]) as Map;
    if (j['method'] != 'session/update') continue;
    final u = (j['params'] as Map)['update'] as Map;
    final kind = u['sessionUpdate'] as String;
    final key = switch (kind) {
      'tool_call' || 'tool_call_update' => 'tool/${u['toolCallId']}',
      'user_message_chunk' || 'agent_message_chunk' || 'agent_thought_chunk' => '$kind/${u['messageId']}',
      _ => null,
    };
    if (key == null) continue;
    if (seen.add(key) && seen.length > items) return i + 1;
  }
  return 0;
}

// ---------------------------------------------------------------------------
// Deflate.
// ---------------------------------------------------------------------------

/// Bytes after zlib over the whole replay as one buffer.
int _deflateWhole(Uint8List data, int level) => ZLibCodec(level: level).encode(data).length;

/// Bytes after zlib with a sync flush after every line: one continuous stream,
/// what the mux's `E<n>` frames do, and the fair number for lines that
/// arrive one by one.
int _deflateStream(List<String> lines, int level) {
  final filter = RawZLibFilter.deflateFilter(level: level);
  var n = 0;
  for (final l in lines) {
    final data = utf8.encode('$l\n');
    filter.process(data, 0, data.length);
    while (true) {
      final out = filter.processed(flush: true);
      if (out == null || out.isEmpty) break;
      n += out.length;
    }
  }
  return n;
}

class _Capture {
  _Capture(this.nominal, this.replay, this.setup, this.fold, this.keeperId);

  final int nominal;
  final _Replay replay;
  final AcpSessionSetup setup;
  final _Fold fold;
  final String keeperId;
  late final AgentSessionState state = fold.state;
}

final _captures = <int, _Capture>{};
LocalKeeperHost? _host;

Future<String> _seed(LocalKeeperHost host, int n, TracePools pools) async {
  final updates = buildSession(pools, n, agent: _agent, bigShare: _bigShare);
  final file = File('${host.home.path}/seed_$n.jsonl')..writeAsStringSync('${updates.map(jsonEncode).join('\n')}\n');
  final info = await host.start(agent: 'omp', cwd: host.work, seedFile: file.path);
  final clock = Stopwatch()..start();
  final a = _Attach(await host.attachProcess(info.id), clock);
  await a.call('initialize', {'protocolVersion': 1, 'clientCapabilities': <String, Object?>{}});
  await a.call('session/new', {'cwd': host.work, 'mcpServers': <Object?>[]});
  await a.call('session/prompt', {
    'sessionId': 'bench-session',
    'prompt': [
      {'type': 'text', 'text': 'seed'},
    ],
  }, timeout: const Duration(minutes: 5));
  await a.close();
  return info.id;
}

void main() {
  final outPath = _env['BENCH_OUT'];
  // Before anything asks for a binding: frames are timed by build and layout.
  _TimingBinding();

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadAppFonts();
    _host = await LocalKeeperHost.create();
    _loadavg('start');
  });

  tearDownAll(() async {
    _loadavg('end');
    await _host?.dispose();
    final text = '${_out.join('\n')}\n';
    if (outPath != null) {
      File(outPath).writeAsStringSync(text);
    } else {
      stdout.write(text);
    }
  });

  // -------------------------------------------------------------------------
  // Keeper and client protocol, no widgets.
  // -------------------------------------------------------------------------
  test('keeper start', timeout: const Timeout(Duration(minutes: 5)), () async {
    // `start`: the keeper claims its id, starts the agent and waits for its
    // `initialize`. The stand-in agent answers at once; a real one (omp, a
    // cold `npx -y`) takes however long it takes, and that is not here.
    final host = _host!;
    final ms = <double>[];
    for (var i = 0; i < _runs + 1; i++) {
      final w = Stopwatch()..start();
      final info = await host.start(agent: 'omp', cwd: host.work);
      if (i > 0) ms.add(w.elapsedMicroseconds / 1000);
      await host.kill(info.id);
    }
    _metric('keeper_start_ms', _median(ms));
  });

  for (final n in _sizes) {
    test('protocol, $n items', timeout: const Timeout(Duration(minutes: 30)), () async {
      final host = _host!;
      final pools = TracePools.load();
      final seedWatch = Stopwatch()..start();
      final id = await _seed(host, n, pools);
      final seedSeconds = seedWatch.elapsedMilliseconds / 1000;
      final p = 's${n}_';
      stdout.writeln('seeded $n in ${seedSeconds.toStringAsFixed(1)} s');

      final attachFirst = <double>[];
      final initRtt = <double>[];
      final loadMs = <double>[];
      final firstLine = <double>[];
      _Replay? last;
      for (var run = 0; run < _runs + 1; run++) {
        final clock = Stopwatch()..start();
        final a = _Attach(await host.attachProcess(id), clock);
        final first = a.firstByteUs;
        await a.call('initialize', {'protocolVersion': 1, 'clientCapabilities': <String, Object?>{}});
        final firstUs = await first;
        final rtts = <double>[];
        for (var i = 0; i < 5; i++) {
          final r = await a.call('initialize', {'protocolVersion': 1, 'clientCapabilities': <String, Object?>{}});
          rtts.add((r.done - r.sent) / 1000);
        }
        final load = await a.call('session/load', {'sessionId': 'bench-session', 'cwd': host.work, 'mcpServers': <Object?>[]});
        final replay = a.replay(7, load.from, load.sent, load.done);
        await a.close();
        if (run == 0) {
          // The first attach after seeding also carries the "turn ended while
          // nobody looked" state and warms the page cache: not counted.
          last = replay;
          continue;
        }
        attachFirst.add(firstUs / 1000);
        initRtt.add(_median(rtts));
        loadMs.add(replay.loadMs);
        firstLine.add(replay.firstLineMs);
        last = replay;
      }
      final replay = last!;
      expect(replay.lines, isNotEmpty);
      _metric('${p}seed_s', seedSeconds);
      _metric('${p}attach_first_byte_ms', _median(attachFirst));
      _metric('${p}init_rtt_ms', _median(initRtt));
      _metric('${p}attach_first_byte_min_ms', _min(attachFirst));
      _metric('${p}load_ms', _median(loadMs));
      _metric('${p}load_min_ms', _min(loadMs));
      _metric('${p}load_first_line_ms', _median(firstLine));
      _metric('${p}load_lines', replay.lines.length);
      _metric('${p}load_bytes', replay.bytes);
      _metric('${p}load_max_line_bytes', replay.lineBytes.fold<int>(0, math.max));

      // The answer to session/load is the setup (`modes`, `configOptions`...).
      final setup = AcpSessionSetup.parse({
        'modes': {
          'currentModeId': 'default',
          'availableModes': [
            {'id': 'default', 'name': 'Default'},
          ],
        },
      });

      // Deflate: the whole replay as bytes the phone would receive.
      final all = Uint8List.fromList(utf8.encode(replay.lines.map((l) => '$l\n').join()));
      for (final level in [1, 6]) {
        final sw = CpuWatch()..start();
        final whole = _deflateWhole(all, level);
        final encodeMs = sw.elapsedMicroseconds / 1000;
        final stream = _deflateStream(replay.lines, level);
        _metric('${p}zip${level}_whole_bytes', whole);
        _metric('${p}zip${level}_stream_bytes', stream);
        _metric('${p}zip${level}_encode_ms', encodeMs);
        if (level == 6) {
          final z = ZLibCodec(level: 6).encode(all);
          final decode = <double>[];
          for (var i = 0; i < _runs; i++) {
            final w = CpuWatch()..start();
            ZLibCodec().decode(z);
            decode.add(w.elapsedMicroseconds / 1000);
          }
          _metric('${p}zip6_decode_ms', _median(decode));
        }
      }

      // Bytes to lines, as the client does it (`splitLines` on 16 KB chunks).
      final split = <double>[];
      for (var i = 0; i < _runs + 1; i++) {
        final w = CpuWatch()..start();
        var n = 0;
        await splitLines(Stream.fromIterable([
          for (var o = 0; o < all.length; o += 16384) Uint8List.sublistView(all, o, math.min(all.length, o + 16384)),
        ])).forEach((_) => n++);
        if (i > 0) split.add(w.elapsedMicroseconds / 1000);
        expect(n, replay.lines.length);
      }
      _metric('${p}fold_split_ms', _median(split));

      // Reducer: decode, parse, apply, medians over runs after a warm-up.
      _fold(replay.lines, setup);
      final decodeMs = <double>[], parseMs = <double>[], applyMs = <double>[];
      _Fold? fold;
      for (var i = 0; i < _runs; i++) {
        fold = _fold(replay.lines, setup);
        decodeMs.add(fold.decodeMs);
        parseMs.add(fold.parseMs);
        applyMs.add(fold.applyMs);
      }
      final f = fold!;
      _metric('${p}items', f.state.items.length);
      _metric('${p}tool_items', f.state.items.whereType<TranscriptTool>().length);
      _metric('${p}updates', f.updates.length);
      _metric('${p}fold_decode_ms', _median(decodeMs));
      _metric('${p}fold_parse_ms', _median(parseMs));
      _metric('${p}fold_apply_ms', _median(applyMs));
      _metric('${p}fold_total_ms', _median(decodeMs) + _median(parseMs) + _median(applyMs));
      _metric('${p}fold_apply_p50_us', _median(f.applyUs));
      _metric('${p}fold_apply_p95_us', _pct(f.applyUs, .95));
      _metric('${p}fold_apply_max_us', f.applyUs.reduce(math.max));
      _metric('${p}fold_apply_first_us', f.applyUs.take(50).fold<double>(0, (a, b) => a + b) / math.min(50, f.applyUs.length));
      _metric('${p}fold_apply_last_us', f.applyUs.skip(math.max(0, f.applyUs.length - 50)).fold<double>(0, (a, b) => a + b) / math.min(50, f.applyUs.length));

      // Tail-first: what the last 30 items alone would cost.
      final tail = _tailStart(replay.lines, 30);
      final tailLines = replay.lines.sublist(tail);
      _fold(tailLines, setup);
      final tailFold = <double>[];
      _Fold? tf;
      for (var i = 0; i < _runs; i++) {
        tf = _fold(tailLines, setup);
        tailFold.add(tf.decodeMs + tf.parseMs + tf.applyMs);
      }
      _metric('${p}tail30_lines', tailLines.length);
      _metric('${p}tail30_bytes', replay.lineBytes.skip(tail).fold<int>(0, (a, b) => a + b));
      _metric('${p}tail30_items', tf!.state.items.length);
      _metric('${p}tail30_fold_ms', _median(tailFold));

      _captures[n] = _Capture(n, replay, setup, f, id);
      final dump = _env['SESSION_OPEN_DUMP'];
      if (dump != null) {
        Directory(dump).createSync(recursive: true);
        File('$dump/replay_$n.jsonl').writeAsStringSync('${replay.lines.join('\n')}\n');
      }

      // Memory: RSS growth per retained state (rough: includes garbage the
      // collector has not given back).
      final keep = <AgentSessionState>[];
      for (var i = 0; i < 3; i++) {
        keep.add(_fold(replay.lines, setup).state);
      }
      final rss = <double>[];
      for (var i = 0; i < 12; i++) {
        keep.add(_fold(replay.lines, setup).state);
        rss.add(ProcessInfo.currentRss / 1048576);
      }
      // The slope of RSS against retained copies: MB one more state holds.
      final mx = (rss.length - 1) / 2;
      final my = rss.reduce((a, b) => a + b) / rss.length;
      var num = 0.0, den = 0.0;
      for (var i = 0; i < rss.length; i++) {
        num += (i - mx) * (rss[i] - my);
        den += (i - mx) * (i - mx);
      }
      _metric('${p}mem_state_mb', num / den);
      expect(keep.length, 15);

      // AcpAgentSession: acquire() to a live link, on each link.
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
      final keeper = (await host.list()).singleWhere((k) => k.id == id);
      expect(keeper.sessionId, isNotEmpty);
      for (final link in _links) {
        final cold = <double>[], firstRows = <double>[], coldNotes = <double>[], warm = <double>[], warmNotes = <double>[], cpu = <double>[];
        for (var run = 0; run < _runs + 1; run++) {
          final session = AcpAgentSession(machine: machine, host: LinkedHost(host, link), info: keeper);
          var notes = 0;
          double? firstItems;
          final clock = Stopwatch();
          final live = Completer<void>();
          void listener() {
            notes++;
            if (firstItems == null && session.state.items.isNotEmpty) firstItems = clock.elapsedMicroseconds / 1000;
            if (!live.isCompleted && session.link == AgentLink.live && !session.state.replaying && session.state.items.isNotEmpty) {
              live.complete();
            }
          }

          session.addListener(listener);
          final c0 = _cpuMs();
          clock.start();
          session.acquire();
          await live.future.timeout(const Duration(minutes: 2));
          final ms = clock.elapsedMicroseconds / 1000;
          final cpuMs = _cpuMs() - c0;
          final itemsAtLive = session.state.items.length;
          // Let the transport finish its last frames before the next phase.
          session.release();
          await Future<void>.delayed(const Duration(milliseconds: 60));
          // The same session again: the held transcript is shown at once, the
          // replay replaces it when whole.
          var warmNote = 0;
          final warmLive = Completer<void>();
          final clock2 = Stopwatch();
          void warmListener() {
            warmNote++;
            if (!warmLive.isCompleted && session.link == AgentLink.live && !session.state.replaying) warmLive.complete();
          }

          session.removeListener(listener);
          session.addListener(warmListener);
          clock2.start();
          session.acquire();
          await warmLive.future.timeout(const Duration(minutes: 2));
          final warmMs = clock2.elapsedMicroseconds / 1000;
          session.release();
          session.removeListener(warmListener);
          session.dispose();
          await Future<void>.delayed(const Duration(milliseconds: 60));
          if (run == 0) continue;
          expect(itemsAtLive, greaterThan(0));
          cold.add(ms);
          firstRows.add(firstItems ?? double.nan);
          coldNotes.add(notes.toDouble());
          warm.add(warmMs);
          warmNotes.add(warmNote.toDouble());
          cpu.add(cpuMs);
        }
        final q = '${p}open_${link.name}_';
        _metric('${q}cold_ms', _median(cold));
        _metric('${q}cold_min_ms', _min(cold));
        _metric('${q}cold_first_items_ms', _median(firstRows));
        _metric('${q}cold_notifications', _median(coldNotes));
        _metric('${q}cold_cpu_ms', _median(cpu));
        _metric('${q}warm_ms', _median(warm));
        _metric('${q}warm_notifications', _median(warmNotes));
        stdout.writeln('  ${link.name}: cold ${_median(cold).toStringAsFixed(0)} ms, warm ${_median(warm).toStringAsFixed(0)} ms');
      }
      machine.dispose();

      // The SSH exec channel's own cost for these bytes, when an sshd is there.
      await _sshCalibration(n, all, p);
    });
  }

  // -------------------------------------------------------------------------
  // The screen.
  // -------------------------------------------------------------------------
  var uiWarmed = false;

  testWidgets('screen, heavy rows', semanticsEnabled: false, timeout: const Timeout(Duration(minutes: 20)), (tester) async {
    tester.view
      ..physicalSize = const Size(392 * 2.75, 760 * 2.75)
      ..devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final pools = TracePools.load();
    final setup = AcpSessionSetup.parse({});
    // One ordinary session of 30 items, then one heavy item last (the first
    // thing on screen), so the difference is that row alone.
    final cases = <String, List<({String kind, int bytes})>>{
      'plain_tool': [(kind: 'read', bytes: 2000)],
      'read_20k': [(kind: 'read', bytes: 20 * 1024)],
      'read_200k': [(kind: 'read', bytes: 200 * 1024)],
      'log_200k': [(kind: 'execute', bytes: 200 * 1024)],
      'diff_20k': [(kind: 'edit', bytes: 20 * 1024)],
      'diff_200k': [(kind: 'edit', bytes: 200 * 1024)],
      'answer_3k': [(kind: 'answer', bytes: 3 * 1024)],
      'answer_20k': [(kind: 'answer', bytes: 20 * 1024)],
      'thought_20k': [(kind: 'thought', bytes: 20 * 1024)],
    };
    for (final MapEntry(:key, :value) in cases.entries) {
      final updates = buildSession(pools, 30, bigShare: 0, tail: value);
      var state = const AgentSessionState('bench-session', replaying: true);
      final at = DateTime.now();
      for (final u in updates) {
        state = state.apply(SessionUpdate.parse(u), at: at);
      }
      state = state.withSetup(setup);
      final runs = <_Opening>[];
      final warm = key == cases.keys.first ? _warm + 6 : _warm;
      for (var run = 0; run < _uiRuns + warm; run++) {
        final o = await _open(tester, FakeAgentSession(state: state));
        if (run >= warm) runs.add(o);
      }
      final first = [for (final r in runs) r.frames.first];
      _metric('rows_${key}_first_frame_ms', _median([for (final f in first) f.total]));
      _metric('rows_${key}_first_build_ms', _median([for (final f in first) f.build]));
      _metric('rows_${key}_first_layout_ms', _median([for (final f in first) f.layout]));
      _metric('rows_${key}_trans_max_ms', _median([for (final r in runs) r.frames.skip(1).map((f) => f.total).reduce(math.max)]));
      _metric('rows_${key}_session_bytes', updates.map((u) => jsonEncode(u).length).fold<int>(0, (a, b) => a + b));
    }
  });

  for (final n in _sizes) {
    testWidgets('screen, $n items', semanticsEnabled: false, timeout: const Timeout(Duration(minutes: 30)), (tester) async {
      final cap = _captures[n];
      if (cap == null) fail('no capture for $n: the protocol test did not run');
      tester.view
        ..physicalSize = const Size(392 * 2.75, 760 * 2.75)
        ..devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final p = 's${n}_';
      final state = cap.state;
      if (!uiWarmed) {
        uiWarmed = true;
        final big = _captures[_sizes.last]!.state;
        for (var i = 0; i < 4; i++) {
          await _open(tester, FakeAgentSession(state: big));
          await _openFilled(tester, big);
        }
      }

      // 1. the final state is there when the route opens (held transcript).
      final finalStats = <_Opening>[];
      for (var run = 0; run < _uiRuns + _warm; run++) {
        final o = await _open(tester, FakeAgentSession(state: state));
        if (run >= _warm) finalStats.add(o);
      }
      _report('${p}ui_final', finalStats);

      // 2. the route opens empty and the whole transcript arrives at once.
      final fillStats = <_Opening>[];
      final fillFrame = <double>[], fillBuild = <double>[], fillLayout = <double>[], fillPaint = <double>[], fillAfterMax = <double>[];
      for (var run = 0; run < _uiRuns + _warm; run++) {
        final o = await _openFilled(tester, state);
        if (run < _warm) continue;
        fillStats.add(o);
        fillFrame.add(o.fill!.total);
        fillBuild.add(o.fill!.build);
        fillLayout.add(o.fill!.layout);
        fillPaint.add(o.fill!.paint);
        fillAfterMax.add(o.afterMax);
      }
      _report('${p}ui_empty', fillStats);
      _metric('${p}ui_fill_frame_ms', _median(fillFrame));
      _metric('${p}ui_fill_build_ms', _median(fillBuild));
      _metric('${p}ui_fill_layout_ms', _median(fillLayout));
      _metric('${p}ui_fill_paint_ms', _median(fillPaint));
      _metric('${p}ui_fill_after_max_ms', _median(fillAfterMax));

      // 3. only the newest 30 items (tail-first / lazy plan).
      final tailFold = _fold(cap.replay.lines.sublist(_tailStart(cap.replay.lines, 30)), cap.setup);
      final tailStats = <_Opening>[];
      for (var run = 0; run < _uiRuns + _warm; run++) {
        final o = await _open(tester, FakeAgentSession(state: tailFold.state));
        if (run >= _warm) tailStats.add(o);
      }
      _report('${p}ui_tail30', tailStats);

      // 4. the transcript grows while the replay arrives, frame by frame.
      for (final link in _links) {
        final arrivals = _arrivals(cap.replay, link);
        final frames = <double>[], reducer = <double>[], counts = <double>[], overs = <double>[], overs2 = <double>[], totals = <double>[], maxes = <double>[];
        for (var run = 0; run < _streamRuns + 2; run++) {
          final s = await _stream(tester, cap, arrivals);
          if (run < 2) continue;
          frames.add(_median(s.frames));
          counts.add(s.frames.length.toDouble());
          maxes.add(s.frames.reduce(math.max));
          overs.add(s.frames.where((f) => f > 16.7).length.toDouble());
          overs2.add(s.frames.where((f) => f > 33.4).length.toDouble());
          totals.add(s.frames.fold<double>(0, (a, b) => a + b));
          reducer.add(s.reducerMs);
        }
        final q = '${p}ui_stream_${link.name}_';
        _metric('${q}frames', _median(counts));
        _metric('${q}frame_median_ms', _median(frames));
        _metric('${q}frame_max_ms', _median(maxes));
        _metric('${q}frames_over_16ms', _median(overs));
        _metric('${q}frames_over_33ms', _median(overs2));
        _metric('${q}frame_total_ms', _median(totals));
        _metric('${q}reducer_ms', _median(reducer));
        _metric('${q}span_ms', arrivals.isEmpty ? 0 : arrivals.last);
      }
    });
  }
}

// ---------------------------------------------------------------------------
// Widget helpers.
// ---------------------------------------------------------------------------

/// The test binding with the frame cut into build and layout, timed. What is
/// left of a pumped frame (compositing bits, paint, compositing, unmounting,
/// the pump's own bookkeeping) is "paint".
class _TimingBinding extends AutomatedTestWidgetsFlutterBinding {
  int buildUs = 0;
  int layoutUs = 0;

  @override
  void drawFrame() {
    final sw = CpuWatch()..start();
    // The same first steps the base class takes, run here to be timed; its
    // own build and layout then find nothing left to do.
    if (rootElement != null) buildOwner!.buildScope(rootElement!);
    buildUs += sw.elapsedMicroseconds;
    sw
      ..reset()
      ..start();
    rootPipelineOwner.flushLayout();
    layoutUs += sw.elapsedMicroseconds;
    super.drawFrame();
  }
}

class _Frame {
  const _Frame(this.build, this.layout, this.paint);

  final double build, layout, paint;
  double get total => build + layout + paint;
}

/// One pumped frame. `layout` includes the rows a lazy list builds while it
/// lays out.
Future<_Frame> _frame(WidgetTester tester, Duration step) async {
  final b = tester.binding as _TimingBinding;
  b
    ..buildUs = 0
    ..layoutUs = 0;
  final sw = CpuWatch()..start();
  await tester.pump(step);
  final total = sw.elapsedMicroseconds / 1000;
  final build = b.buildUs / 1000;
  final layout = b.layoutUs / 1000;
  return _Frame(build, layout, math.max(0, total - build - layout));
}

class _Opening {
  _Opening(this.frames, {this.fill, this.afterMax = 0});

  /// The frames of the 260 ms page transition, the first included.
  final List<_Frame> frames;
  final _Frame? fill;
  final double afterMax;
}

/// Pushes the chat route over a list page and runs the page transition frame
/// by frame. [afterTransition] runs once it is done.
/// [_open] over a route that starts empty (link not live yet) and gets
/// [state] in one push right after the transition: a transcript that arrives
/// whole. `fill` is the frame that takes it in.
Future<_Opening> _openFilled(WidgetTester tester, AgentSessionState state) {
  final session = FakeAgentSession(link: AgentLink.reconnecting);
  return _open(tester, session, afterTransition: () async {
    session.setLink(AgentLink.live);
    session.push(state);
    final fill = await _frame(tester, const Duration(milliseconds: 16));
    final after = <double>[];
    for (var i = 0; i < 6; i++) {
      after.add((await _frame(tester, const Duration(milliseconds: 16))).total);
    }
    return (fill, after);
  });
}

Future<_Opening> _open(
  WidgetTester tester,
  FakeAgentSession session, {
  Future<(_Frame, List<double>)> Function()? afterTransition,
}) async {
  final nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: nav,
      theme: AppTheme.light(),
      home: const Scaffold(body: Center(child: Text('Agents'))),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  unawaited(nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => AgentSessionScreen(session: session))));
  final frames = <_Frame>[await _frame(tester, Duration.zero)];
  var elapsed = 0;
  while (elapsed < 260) {
    frames.add(await _frame(tester, const Duration(milliseconds: 16)));
    elapsed += 16;
  }
  _Frame? fill;
  var afterMax = 0.0;
  if (afterTransition != null) {
    final r = await afterTransition();
    fill = r.$1;
    afterMax = r.$2.fold<double>(0, math.max);
  }
  await tester.pump(const Duration(milliseconds: 100));
  // Unmount: the next opening starts from a clean tree.
  await tester.pumpWidget(const SizedBox());
  session.dispose();
  return _Opening(frames, fill: fill, afterMax: afterMax);
}

void _report(String name, List<_Opening> runs) {
  final first = [for (final r in runs) r.frames.first.total];
  _metric('${name}_first_frame_ms', _median(first));
  _metric('${name}_first_build_ms', _median([for (final r in runs) r.frames.first.build]));
  _metric('${name}_first_layout_ms', _median([for (final r in runs) r.frames.first.layout]));
  _metric('${name}_first_paint_ms', _median([for (final r in runs) r.frames.first.paint]));
  _metric('${name}_trans_frames', _median([for (final r in runs) r.frames.length.toDouble()]));
  _metric('${name}_trans_median_ms', _median([for (final r in runs) _median([for (final f in r.frames.skip(1)) f.total])]));
  _metric('${name}_trans_max_ms', _median([for (final r in runs) r.frames.skip(1).map((f) => f.total).reduce(math.max)]));
  _metric('${name}_trans_over_16ms', _median([for (final r in runs) r.frames.where((f) => f.total > 16.7).length.toDouble()]));
  _metric('${name}_trans_total_ms', _median([for (final r in runs) r.frames.fold<double>(0, (a, f) => a + f.total)]));
}

/// When each line of [replay] is complete on the phone, ms after the first
/// byte of the replay left the host: the link's latency and rate on top of the
/// local timeline (the same model as [LinkedTransport]).
List<double> _arrivals(_Replay replay, LinkModel link) {
  final out = <double>[];
  var last = 0.0;
  for (var i = 0; i < replay.lines.length; i++) {
    final local = replay.arrivalMs[i] - replay.firstLineMs;
    final start = local + link.rttMs / 2;
    final from = math.max(start, last);
    last = from + (link.mbit <= 0 ? 0 : replay.lineBytes[i] * 8 / (link.mbit * 1000));
    out.add(last);
  }
  return out;
}

/// The screen is up (route done) and the replay arrives as [arrivals] says:
/// every frame applies the lines that came and pushes the state, as
/// `AcpAgentSession` does once per frame.
Future<({List<double> frames, double reducerMs})> _stream(WidgetTester tester, _Capture cap, List<double> arrivals) async {
  final session = FakeAgentSession(link: AgentLink.connecting);
  final nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: nav,
      theme: AppTheme.light(),
      home: const Scaffold(body: Center(child: Text('Agents'))),
    ),
  );
  unawaited(nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => AgentSessionScreen(session: session))));
  for (var i = 0; i < 18; i++) {
    await tester.pump(i == 0 ? Duration.zero : const Duration(milliseconds: 16));
  }
  var s = const AgentSessionState('bench-session', replaying: true);
  final updates = cap.fold.updates;
  // arrivals are per line; map them to updates (every replay line is an update).
  final lineIsUpdate = [for (final l in cap.replay.lines) l.contains('"session/update"')];
  var u = 0;
  var line = 0;
  var t = 0.0;
  final frames = <double>[];
  final reducer = CpuWatch();
  final at = DateTime.now();
  while (line < arrivals.length) {
    t += 16;
    var changed = false;
    while (line < arrivals.length && arrivals[line] <= t) {
      if (lineIsUpdate[line]) {
        reducer.start();
        s = s.apply(updates[u++], at: at);
        reducer.stop();
        changed = true;
      }
      line++;
    }
    if (!changed) continue;
    session.push(s);
    frames.add((await _frame(tester, const Duration(milliseconds: 16))).total);
  }
  session.setLink(AgentLink.live);
  session.push(s.withSetup(cap.setup));
  frames.add((await _frame(tester, const Duration(milliseconds: 16))).total);
  await tester.pumpWidget(const SizedBox());
  session.dispose();
  return (frames: frames, reducerMs: reducer.elapsedMicroseconds / 1000);
}

// ---------------------------------------------------------------------------
// SSH calibration.
// ---------------------------------------------------------------------------

Future<void> _sshCalibration(int n, Uint8List replay, String p) async {
  final home = _env['HOME'];
  final user = _env['USER'] ?? _env['LOGNAME'];
  final keyFile = File('$home/.ssh/herdr-mobile');
  if (home == null || user == null || !keyFile.existsSync()) {
    stdout.writeln('  ssh calibration skipped: no ~/.ssh/herdr-mobile');
    return;
  }
  final dir = Directory.systemTemp.createTempSync('session_open_ssh_');
  final file = File('${dir.path}/replay.jsonl')..writeAsBytesSync(replay);
  final transport = createSshTransport(
    MachineProfile(id: 'bench', label: 'bench', host: '127.0.0.1', username: user),
    MachineSecrets(privateKeyPem: keyFile.readAsStringSync()),
    (_) {},
    (_) {},
  );
  try {
    Future<({double ms, double cpu, int lines})> once() async {
      final c0 = _cpuMs();
      final sw = Stopwatch()..start();
      final channel = await transport.openExec("cat '${file.path}'");
      var lines = 0;
      final done = Completer<void>();
      channel.lines.listen((_) => lines++, onDone: done.complete);
      await done.future.timeout(const Duration(minutes: 2));
      final ms = sw.elapsedMicroseconds / 1000;
      await channel.close();
      return (ms: ms, cpu: _cpuMs() - c0, lines: lines);
    }

    // The first exec opens the connection (key exchange, auth): not counted.
    final warm = await transport.openExec('true');
    await warm.exitCode.timeout(const Duration(seconds: 20));
    await once();
    final ms = <double>[], cpu = <double>[];
    var lines = 0;
    for (var i = 0; i < _runs; i++) {
      final r = await once();
      ms.add(r.ms);
      cpu.add(r.cpu);
      lines = r.lines;
    }
    _metric('${p}ssh_exec_ms', _median(ms));
    _metric('${p}ssh_exec_cpu_ms', _median(cpu));
    _metric('${p}ssh_exec_lines', lines);
    stdout.writeln('  ssh exec: ${_median(ms).toStringAsFixed(0)} ms, cpu ${_median(cpu).toStringAsFixed(0)} ms for ${replay.length} B');
  } on Object catch (e) {
    stdout.writeln('  ssh calibration skipped: $e');
  } finally {
    transport.close();
    dir.deleteSync(recursive: true);
  }
}
