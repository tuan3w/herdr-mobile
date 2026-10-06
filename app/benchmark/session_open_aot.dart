// ignore_for_file: avoid_print
//
// The open-session benchmark's CPU half in an AOT PROFILE build, to say how
// much the `flutter test` numbers (JIT, asserts on) overstate a release build
// on the same CPU. It does not replace the phone: it only measures the
// desktop JIT/AOT factor, so the doc can state its scaling honestly.
//
//   SESSION_OPEN_DUMP=/tmp/dump flutter test benchmark/session_open_bench.dart
//   flutter build linux --profile -t benchmark/session_open_aot.dart
//   SESSION_OPEN_DUMP=/tmp/dump xvfb-run -a build/linux/x64/profile/bundle/herdr_mobile
//
// (`session_open_bench.dart` writes the replayed lines of each size to
// `$SESSION_OPEN_DUMP/replay_<n>.jsonl`.) Per size it prints METRIC lines:
//   * `aot_s<n>_fold_*`: jsonDecode, parse and apply of the replay, and
//     `splitLines` on its bytes, as in the JIT bench;
//   * `aot_s<n>_ui_*`: the real `AgentSessionScreen` pushed over a list page
//     with the page transition: UI-thread time (FrameTiming.buildDuration:
//     build, layout and paint recording) of the first frame and the largest
//     of the 260 ms; once with the state held, once empty then filled. Raster
//     is not reported: Xvfb renders in software.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/json_rpc.dart' show splitLines;
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';

import '../test/support/fake_agent_session.dart';

double _median(List<double> v) {
  final s = [...v]..sort();
  return s.length.isOdd ? s[s.length ~/ 2] : (s[s.length ~/ 2 - 1] + s[s.length ~/ 2]) / 2;
}

void _metric(String name, num value) => print('METRIC $name=${value is int ? value : value.toStringAsFixed(3)}');

final _timings = <FrameTiming>[];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dump = Platform.environment['SESSION_OPEN_DUMP'];
  if (dump == null) {
    print('set SESSION_OPEN_DUMP to the folder session_open_bench.dart wrote');
    exit(2);
  }
  SchedulerBinding.instance.addTimingsCallback(_timings.addAll);
  final nav = GlobalKey<NavigatorState>();
  runApp(
    MaterialApp(
      navigatorKey: nav,
      theme: AppTheme.light(),
      home: const Scaffold(body: Center(child: Text('Agents'))),
    ),
  );
  await Future<void>.delayed(const Duration(seconds: 1));

  final files = Directory(dump).listSync().whereType<File>().where((f) => RegExp(r'replay_\d+\.jsonl$').hasMatch(f.path)).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final bySize = {for (final f in files) int.parse(RegExp(r'replay_(\d+)').firstMatch(f.path)!.group(1)!): f};
  final sizes = bySize.keys.toList()..sort();
  const runs = 7;
  final setup = AcpSessionSetup.parse({});
  final states = <int, AgentSessionState>{};

  for (final n in sizes) {
    final bytes = bySize[n]!.readAsBytesSync();
    final lines = const LineSplitter().convert(utf8.decode(bytes));
    final p = 'aot_s${n}_';
    final decode = <double>[], parse = <double>[], apply = <double>[], split = <double>[];
    AgentSessionState? last;
    for (var r = 0; r < runs + 3; r++) {
      final sw = Stopwatch();
      var s = const AgentSessionState('bench-session', replaying: true);
      final at = DateTime.now();
      var d = 0, pa = 0, ap = 0;
      for (final line in lines) {
        sw
          ..reset()
          ..start();
        final j = jsonDecode(line) as Map;
        d += sw.elapsedMicroseconds;
        if (j['method'] != 'session/update') continue;
        sw
          ..reset()
          ..start();
        final u = SessionUpdate.parse((j['params'] as Map)['update']);
        pa += sw.elapsedMicroseconds;
        sw
          ..reset()
          ..start();
        s = s.apply(u, at: at);
        ap += sw.elapsedMicroseconds;
      }
      last = s.withSetup(setup);
      final w = Stopwatch()..start();
      var c = 0;
      await splitLines(Stream.fromIterable([
        for (var o = 0; o < bytes.length; o += 16384) Uint8List.sublistView(bytes, o, math.min(bytes.length, o + 16384)),
      ])).forEach((_) => c++);
      if (r >= 3) {
        decode.add(d / 1000);
        parse.add(pa / 1000);
        apply.add(ap / 1000);
        split.add(w.elapsedMicroseconds / 1000);
      }
    }
    states[n] = last!;
    _metric('${p}items', last.items.length);
    _metric('${p}fold_decode_ms', _median(decode));
    _metric('${p}fold_parse_ms', _median(parse));
    _metric('${p}fold_apply_ms', _median(apply));
    _metric('${p}fold_total_ms', _median(decode) + _median(parse) + _median(apply));
    _metric('${p}fold_split_ms', _median(split));
  }

  Future<List<FrameTiming>> frames(Future<void> Function() act) async {
    _timings.clear();
    final from = developer.Timeline.now;
    await act();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final got = [
      for (final t in _timings)
        if (t.timestampInMicroseconds(ui.FramePhase.buildStart) >= from) t,
    ];
    return got;
  }

  Future<void> open(AgentSessionView session, Future<void> Function()? after) async {
    final pushed = nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => AgentSessionScreen(session: session)));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (after != null) await after();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    nav.currentState!.pop();
    await pushed;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  double ms(FrameTiming t) => t.buildDuration.inMicroseconds / 1000;

  for (final n in sizes) {
    final p = 'aot_s${n}_ui_';
    final first = <double>[], maxT = <double>[], over = <double>[], fillFirst = <double>[], fillMax = <double>[];
    for (var r = 0; r < runs + 3; r++) {
      final held = await frames(() => open(FakeAgentSession(state: states[n]!), null));
      final heldFrames = held.where((t) => t.timestampInMicroseconds(ui.FramePhase.buildStart) < held.first.timestampInMicroseconds(ui.FramePhase.buildStart) + 260000).toList();
      final session = FakeAgentSession(link: AgentLink.reconnecting);
      List<FrameTiming> after = const [];
      final empty = await frames(() async {
        await open(session, () async {
          _timings.clear();
          final from = developer.Timeline.now;
          session
            ..setLink(AgentLink.live)
            ..push(states[n]!);
          await Future<void>.delayed(const Duration(milliseconds: 300));
          after = [
            for (final t in _timings)
              if (t.timestampInMicroseconds(ui.FramePhase.buildStart) >= from) t,
          ];
        });
      });
      expectNotEmpty(empty);
      if (r < 3) continue;
      first.add(ms(heldFrames.first));
      maxT.add(heldFrames.skip(1).map(ms).fold<double>(0, math.max));
      over.add(heldFrames.where((t) => ms(t) > 16.7).length.toDouble());
      if (after.isNotEmpty) {
        fillFirst.add(ms(after.first));
        fillMax.add(after.map(ms).fold<double>(0, math.max));
      }
    }
    _metric('${p}first_frame_ms', _median(first));
    _metric('${p}trans_max_ms', _median(maxT));
    _metric('${p}trans_over_16ms', _median(over));
    if (fillFirst.isNotEmpty) {
      _metric('${p}fill_first_ms', _median(fillFirst));
      _metric('${p}fill_max_ms', _median(fillMax));
    }
  }
  print('SESSIONOPEN_AOT_DONE');
  exit(0);
}

void expectNotEmpty(List<Object> l) {
  if (l.isEmpty) print('warning: no frame timings arrived');
}
