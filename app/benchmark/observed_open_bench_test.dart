// What opening the chat of an agent that runs in a herdr pane (an "observed"
// session: the app reads the agent's own session log through the host helper)
// costs the phone: bytes on the wire, how long the open waits before the first
// line can be read, and how long the phone then spends parsing. Deterministic,
// no phone, no network.
//
//   BENCH_OUT=/tmp/obs.txt flutter test benchmark/observed_open_bench_test.dart
//
// What is REAL: the host helper (`herdr-host serve` and its `keeper.follow`, in
// a temp HOME, installed the way the app installs it) reads an omp session log
// built from the recorded traces (`support/omp_log_workload.dart`, fixed seed,
// the shape of a real omp log); `SshLogSource` over `SshAgentHost` (built the
// way `boot.dart` builds it: a new host object per session) opens the follow as
// a stream on the one `HostLink` the machine keeps (opened with zctx, as the app
// does); `ObservedAgentSession` with `OmpLogMapper` and the chat reducer turns
// the lines into the transcript. What is replaced: SSH. `serve` runs through
// `sh -c` here, and every byte it writes on the follow's stream is counted
// before anything reads it (`wire_kb`: frames with their headers, deflated as
// the stream's one zlib stream; SSH framing is not counted).
//
// Two scenarios per run:
//  * cold: a new session object, nothing on the phone (the first open of a
//    chat after the app started, or after the session was dropped), on a link
//    that is already up;
//  * relink: the chat was in front, the person left, the follow was dropped,
//    and they come back to the same session object (the log did not grow).
//
// The time of an open on a link is modelled from what was measured:
//
//     open_ms = STREAM_RTTS * RTT + max(gate_ms, first_byte_ms + wire_bytes * 8 / rate) + post_ms
//
// `STREAM_RTTS` is one round trip: the OPEN frame reaches the host (half) and
// the first record comes back (half); the link is already up, so there is no
// channel to open (the old model paid 2 for an SSH exec channel; a first use on
// a new connection pays about 3, once, and is not in these numbers).
// `first_byte_ms` is the time on this machine (measured) from the OPEN to the
// first frame of the stream (the host opening and reading the log), and the
// transfer cannot begin before it. `gate_ms` is how long the stream was held
// back from the session (from the OPEN to the first listener); the output
// buffers meanwhile, so it overlaps the transfer. `post_ms` is the time from
// the first batch reaching the session to a live link with the whole tail
// applied (the mapper and the reducer on the main isolate, the slices and the
// yields between them). `pre_ms`, from `acquire()` to that first batch, is
// reported as a diagnostic only.
// ASSUMPTIONS, not measurements: the links (`_links`), no loss, no slow
// start, and the `*_ms` above, which are wall time of THIS machine (JIT,
// asserts on: a phone is slower, and what it costs there is unverified).
// Compare changes with them; never quote them for a phone.
import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/observed/observed_contracts.dart';
import 'package:herdr_mobile/data/observed/omp_kind.dart';
import 'package:herdr_mobile/data/observed/omp_log_mapper.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/observed_session.dart';
import 'package:herdr_mobile/data/host/host_channels.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/ssh_agent_host.dart';
import 'package:herdr_mobile/data/services/ssh_log_source.dart';

import '../test/support/fake_log_source.dart';
import '../test/support/process_host.dart';
import 'support/cpu_clock.dart';
import 'support/local_keeper.dart';
import 'support/omp_log_workload.dart';
import 'support/session_workload.dart' show TracePools;

final _env = Platform.environment;
final _runs = int.parse(_env['OBS_RUNS'] ?? '5');
final _logKb = int.parse(_env['OBS_LOG_KB'] ?? '800');

/// Round trips before the first record of a stream on a link that is up: the
/// OPEN frame there and the first frame back.
const streamRtts = 1;

/// (name, round trip ms, megabits a second towards the phone)
const _links = [('fast', 40.0, 30.0), ('mid', 120.0, 10.0), ('slow', 300.0, 2.0)];

final _out = <String>[];

void _metric(String name, num value) => _out.add('METRIC $name=${value is int ? value : value.toStringAsFixed(3)}');

double _median(Iterable<double> v) {
  final s = [...v]..sort();
  return s.length.isOdd ? s[s.length ~/ 2] : (s[s.length ~/ 2 - 1] + s[s.length ~/ 2]) / 2;
}

/// One run's clock: every stamp is milliseconds since [start] was called, on
/// the meter's own clock (the frames' times are on it).
class _Clock {
  _Clock(this._meter);

  final WireMeter _meter;
  var _base = 0;

  void start() => _base = _meter.clock.elapsedMicroseconds;
  double get now => at(_meter.clock.elapsedMicroseconds);
  double at(int us) => (us - _base) / 1000;
}

/// What one follow stream did: the meter has its frames.
class _Probe {
  int? streamId;
  double? startedAt;
  double? listenedAt;
}

/// The stream as the transport hands it over, noting when it was first
/// listened to. It reads only while listened to (the link's own credit does the
/// rest), as the app's channel does.
class _TimedChannel implements ExecChannel {
  _TimedChannel(this._inner, this._probe, this._clock);

  final ExecChannel _inner;
  final _Probe _probe;
  final _Clock _clock;
  StreamSubscription<String>? _sub;

  @override
  late final Stream<String> lines = (() {
    late final StreamController<String> c;
    c = StreamController<String>(
      onListen: () {
        _probe.listenedAt ??= _clock.now;
        _sub = _inner.lines.listen(c.add, onError: c.addError, onDone: c.close);
      },
      onPause: () => _sub?.pause(),
      onResume: () => _sub?.resume(),
      onCancel: () => _sub?.cancel(),
    );
    return c.stream;
  })();

  @override
  void send(String line) => _inner.send(line);

  @override
  Future<void> closeInput() => _inner.closeInput();

  @override
  Future<int?> get exitCode => _inner.exitCode;

  @override
  String get stderrTail => _inner.stderrTail;

  @override
  Future<void> close() => _inner.close();
}

/// The machine's transport: the host link's streams, timed.
class _TimedTransport extends LinkTransport {
  _TimedTransport(this.host, this.clock, this.probes) : super(host.link);

  final LocalKeeperHost host;
  final _Clock clock;
  final List<_Probe> probes;

  @override
  Future<ExecChannel> openHostStream(String service, String method, [Map<String, Object?> args = const {}]) async {
    final probe = _Probe();
    probes.add(probe);
    final link = await host.link();
    // zctx, as the app's transport opens every stream.
    final stream = link.open(service, method, args, true);
    probe
      ..streamId = stream.id
      ..startedAt = clock.now;
    return _TimedChannel(HostLineChannel(stream), probe, clock);
  }
}

/// A [SessionLogSource] that notes when each batch reached the session.
class _Timed implements SessionLogSource {
  _Timed(this._inner, this._clock);

  final SessionLogSource _inner;
  final _Clock _clock;
  final lines = <String>[];
  double? firstBatchAt;
  var batches = 0;
  var follows = 0;

  @override
  Future<Uint8List> blob(String path, {required int start, required String hash}) =>
      _inner.blob(path, start: start, hash: hash);

  @override
  Stream<LogBatch> follow(String path, {int? from, int? until, bool digest = false, int? tailBytes}) {
    follows++;
    return _inner.follow(path, from: from, until: until, digest: digest, tailBytes: tailBytes).map((b) {
      firstBatchAt ??= _clock.now;
      batches++;
      lines.addAll(b.lines);
      return b;
    });
  }
}

/// What one open cost.
class _Open {
  _Open({
    required this.wireBytes,
    required this.preMs,
    required this.postMs,
    required this.cpuMs,
    required this.gateMs,
    required this.firstByteMs,
    required this.hostMs,
    required this.items,
    required this.batches,
  });

  final int wireBytes;
  final double preMs;
  final double firstByteMs;
  final double postMs;
  final double cpuMs;
  final double gateMs;
  final double hostMs;
  final int items;
  final int batches;

  double modelledMs(double rttMs, double mbit) =>
      streamRtts * rttMs + math.max(gateMs, firstByteMs + wireBytes * 8 / (mbit * 1000)) + postMs;
}

/// The session as the app makes it: a new `SshLogSource` over a new
/// `SshAgentHost` (what `boot.dart` does per session) and the omp mapper.
class _Held {
  _Held(this.rig, this.host, this.path) {
    clock = _Clock(host.meter);
    transport = _TimedTransport(host, clock, probes);
    source = _Timed(SshLogSource(SshAgentHost(transport)), clock);
    session = ObservedAgentSession(
      machine: rig.machine,
      paneId: 'w1:p1',
      kind: ompKind,
      source: source,
      mapper: OmpLogMapper.new,
      previews: rig.previews,
      linger: const Duration(milliseconds: 50),
    );
  }

  final ObservedRig rig;
  final LocalKeeperHost host;
  final String path;
  late final _Clock clock;
  final probes = <_Probe>[];
  late final _TimedTransport transport;
  late final _Timed source;
  late final ObservedAgentSession session;

  /// `acquire()` to a live link, measured from the probes of the channels that
  /// opened since [fromProbe].
  Future<_Open> acquire({int fromProbe = 0, int items = 1}) async {
    final live = Completer<double>();
    void listener() {
      // Live AND the whole tail applied: a session calls itself live after
      // the first batch, while more of the replay is still on its way.
      if (!live.isCompleted && session.link == AgentLink.live && session.state.items.length >= items) {
        live.complete(clock.now);
      }
    }

    session.addListener(listener);
    source
      ..firstBatchAt = null
      ..batches = 0;
    final probeBase = probes.length;
    clock.start();
    final c0 = threadCpuMicros();
    session.acquire();
    final liveAt = await live.future.timeout(const Duration(seconds: 30));
    final cpuMs = (threadCpuMicros() - c0) / 1000;
    session.removeListener(listener);
    final mine = probes.sublist(math.max(probeBase, fromProbe));
    final first = source.firstBatchAt;
    final probe = mine.isEmpty ? null : mine.first;
    final tally = probe?.streamId == null ? null : host.meter.stream(probe!.streamId!);
    final firstUs = tally?.firstUs;
    final lastUs = tally?.lastUs;
    final started = probe?.startedAt ?? 0;
    return _Open(
      wireBytes: mine.fold(0, (a, p) => a + (p.streamId == null ? 0 : host.meter.stream(p.streamId!).bytes)),
      preMs: first ?? liveAt,
      postMs: first == null ? 0 : liveAt - first,
      cpuMs: cpuMs,
      gateMs: probe == null ? 0 : (probe.listenedAt ?? liveAt) - started,
      firstByteMs: firstUs == null ? 0 : clock.at(firstUs) - started,
      hostMs: lastUs == null ? 0 : clock.at(lastUs) - started,
      items: session.state.items.length,
      batches: source.batches,
    );
  }

  /// The person leaves: the screen lets go and the follow is dropped after the
  /// linger.
  Future<void> leave() async {
    session.release();
    final until = DateTime.now().add(const Duration(seconds: 5));
    while (session.link == AgentLink.live && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(session.link, isNot(AgentLink.live), reason: 'the follow was dropped');
    // The channel closes and the process ends.
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  void dispose() => session.dispose();
}

void main() {
  LocalKeeperHost? host;
  ObservedRig? rig;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    host = await LocalKeeperHost.create();
  });

  tearDownAll(() async {
    rig?.dispose();
    await host?.dispose();
    final text = '${_out.join('\n')}\n';
    final path = _env['BENCH_OUT'];
    if (path != null) {
      File(path).writeAsStringSync(text);
    } else {
      stdout.write(text);
    }
  });

  test('what opening an observed chat costs the link', timeout: const Timeout(Duration(minutes: 20)), () async {
    final h = host!;
    final log = buildOmpLog(TracePools.load(), bytes: _logKb * 1024, cwd: h.work);
    final dir = Directory('${h.home.path}/.omp/agent/sessions/--work--')..createSync(recursive: true);
    final path = '${dir.path}/2026-10-06T13-32-37-946Z_bench.jsonl';
    File(path).writeAsStringSync('${log.join('\n')}\n');
    final fileKb = File(path).lengthSync() / 1024;
    _metric('obs_log_kb', fileKb);
    _metric('obs_log_entries', log.length);

    rig = await ObservedRig.create(log: path);
    final r = rig!;

    // The first open after the helper was installed also warms the page cache
    // and the JIT: not counted.
    final warm = _Held(r, h, path);
    final warmOpen = await warm.acquire();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final wantItems = warm.session.state.items.length;
    expect(wantItems, greaterThan(20), reason: 'the log maps to a transcript');
    expect(wantItems, greaterThanOrEqualTo(warmOpen.items));
    final replayed = List<String>.of(warm.source.lines);
    warm.dispose();

    // What deflate makes of the replay: held against the ~3x a real omp log
    // gives (see omp_log_workload.dart).
    final replayBytes = utf8.encode('${replayed.join('\n')}\n');
    _metric('obs_replay_kb', replayBytes.length / 1024);
    _metric('obs_replay_lines', replayed.length);
    _metric('obs_replay_zip_ratio', replayBytes.length / zlib.encode(replayBytes).length);

    // The parse alone: the mapper and the reducer over the replayed lines, in
    // thread CPU time (the load of the machine hardly moves it).
    final fold = <double>[];
    for (var i = 0; i < _runs + 1; i++) {
      final c0 = threadCpuMicros();
      final mapper = OmpLogMapper();
      var state = AgentSessionState('bench');
      for (final line in replayed) {
        for (final u in mapper.map(line)) {
          state = state.apply(u);
        }
      }
      final ms = (threadCpuMicros() - c0) / 1000;
      if (i > 0) fold.add(ms);
      if (i == 0) _metric('obs_items', state.items.length);
    }
    _metric('obs_fold_cpu_ms', _median(fold));

    final cold = <_Open>[];
    final relink = <_Open>[];
    for (var i = 0; i < _runs; i++) {
      final held = _Held(r, h, path);
      cold.add(await held.acquire(items: wantItems));
      await held.leave();
      final probesBefore = held.probes.length;
      relink.add(await held.acquire(fromProbe: probesBefore, items: wantItems));
      held.dispose();
    }
    _report('obs_cold', cold);
    _report('obs_relink', relink);

    var score = 0.0;
    for (final (_, rtt, mbit) in _links) {
      score += _median(cold.map((o) => o.modelledMs(rtt, mbit))) + _median(relink.map((o) => o.modelledMs(rtt, mbit)));
    }
    _metric('obs_score_ms', score);
  });
}

void _report(String q, List<_Open> runs) {
  _metric('${q}_wire_kb', runs.first.wireBytes / 1024);
  _metric('${q}_pre_ms', _median(runs.map((o) => o.preMs)));
  _metric('${q}_post_ms', _median(runs.map((o) => o.postMs)));
  _metric('${q}_gate_ms', _median(runs.map((o) => o.gateMs)));
  _metric('${q}_first_byte_ms', _median(runs.map((o) => o.firstByteMs)));
  _metric('${q}_host_ms', _median(runs.map((o) => o.hostMs)));
  _metric('${q}_phone_cpu_ms', _median(runs.map((o) => o.cpuMs)));
  _metric('${q}_batches', runs.first.batches);
  for (final (name, rtt, mbit) in _links) {
    _metric('${q}_open_${name}_ms', _median(runs.map((o) => o.modelledMs(rtt, mbit))));
  }
}
