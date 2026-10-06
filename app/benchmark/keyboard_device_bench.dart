// ignore_for_file: avoid_print, invalid_use_of_visible_for_testing_member
//
// The keyboard benchmark, on a phone: what tapping the composer of an agent's
// terminal costs, frame by frame. `autoresearch-keyboard.sh` builds and runs it:
//
//   flutter build apk --profile -t benchmark/keyboard_device_bench.dart
//
// It is the real app (`bootApp`, `configureSystemUi`, the shell, the agent
// screen put back at launch, the pane, the composer, the platform's keyboard handling) over seeded
// preferences and an in-memory herdr: one workspace, one `claude` pane showing
// a 300 row ANSI tail (the same bytes as `pane_bench.dart`). No network, no
// SSH, fixed content, so only the phone varies. Per cycle it taps the composer
// with synthetic pointer events through the real gesture binding (what a
// finger does), waits for the system keyboard to finish, then unfocuses the
// field to close it. Two scenarios: an idle agent, and a busy one whose pane
// changes and is re-read several times a second (what the pane view does while
// an agent works).
//
// `--dart-define=KB_CONTROL=true` swaps the app for the smallest Flutter screen
// with a text field (same window setup, same manifest). Whatever the control
// also shows is the platform's (engine, Android, the keyboard app), not this
// app's UI.
//
// Per keyboard animation it records
//   * the IME inset the framework saw at every frame: a smooth ramp, or jumps;
//   * every frame's build (UI thread) and raster time, from FrameTiming;
//   * the time from the tap to the first frame that moved.
// Results go to logcat as KBBENCH_* lines (profile builds still print them);
// `autoresearch-keyboard.sh` turns the KBBENCH_METRIC ones into METRIC lines.
//
// Time budget: a frame has 1000 / refresh rate ms in each stage (build and
// raster run in parallel on two threads). `jank_ms` is how far past that
// budget the frames of one animation ran, summed; `dropped` counts the vsyncs
// that passed between two consecutive frames without one. Motion is measured
// on the inset the layout obeys, `max(viewInsets, viewPadding).bottom` (the
// composer sits above the navigation bar until the keyboard rises past it).
// `snap_dp` is the opening's last step, dp: a smooth ease ends in tiny steps,
// while an animated inset that disagrees with the settled one ends in a jump.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:herdr_mobile/boot.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart' show MachineSecrets;
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/support/fake_network.dart';
import '../test/support/fake_transport.dart';
import '../test/support/memory_snapshot_cache.dart';
import '../test/support/memory_stores.dart';
import 'support/pane_workload.dart';

const _machineId = 'm0';
const _paneId = 'w1:p1';

/// The smallest screen with a text field, instead of the app.
const _control = bool.fromEnvironment('KB_CONTROL');

/// Opens the keyboard once and leaves it open, for a screenshot (no metrics).
const _holdOpen = bool.fromEnvironment('KB_HOLD_OPEN');

/// Prints every cycle's raw frame samples and the taps' absolute times
/// (`KBTRACE`/`KBTAP` lines on the monotonic clock of `Timeline.now`), to line
/// up with Android's own log, which timestamps the keyboard's start-up stages.
const _trace = bool.fromEnvironment('KB_TRACE');

/// Open + close cycles measured per scenario, after [_warmups] discarded ones
/// (the idle scenario also reports its very first, cold, keyboard).
const _cycles = 8;
const _warmups = 1;

/// Rest between a keyboard finishing and the next action.
const _hold = Duration(milliseconds: 500);

/// No inset change for this long: the keyboard is done.
const _quiet = Duration(milliseconds: 450);

/// How often a busy agent's pane announces a change.
const _activityEvery = Duration(milliseconds: 100);

/// herdr as the pane sees it: a workspace with one agent pane whose tail is
/// [paneReadAt] of the current [step].
class _BenchTransport extends FakeTransport {
  _BenchTransport()
      : super(
          snapshotJson(
            workspaces: [(id: 'w1', label: 'herdr-mobile')],
            panes: [(id: _paneId, ws: 'w1', agent: 'claude', status: 'working')],
          ),
        );

  final _rows = <int, String>{};
  var step = 0;

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) {
    if (method != 'pane.read') return super.request(method, params);
    final text = paneReadAt(1000 + step * paneSlide, step, rows: _rows);
    return Future.value({
      'type': 'pane_read',
      'read': {'text': text, 'truncated': false},
    });
  }

  /// The pane changed: the next read slides by [paneSlide] rows. The event
  /// carries the pane as the snapshot already has it, which herdr's
  /// `pane_updated` does too, so only the pane view reacts.
  void activity() {
    if (subscriptions == 0) return;
    step++;
    emit({
      'event': 'pane_updated',
      'data': {
        'type': 'pane_updated',
        'pane': (snapshot['panes'] as List).first,
      },
    });
  }
}

Map<String, Object> _seed() => {
      'machines.v1': jsonEncode([
        {
          'id': _machineId,
          'label': 'workstation',
          'host': 'bench.invalid',
          'port': 22,
          'username': 'bench',
          'auth': 'password',
          'session': 'default',
          'enabled': true,
        },
      ]),
      // The agent's terminal was in front: the app puts it back, as on a launch.
      'frontAgent.v1': FrontAgent(const PaneAgent(_machineId, _paneId), AgentView.terminal).encode(),
      'app.homeTab': 0,
    };

/// The smallest screen a keyboard can be asked for: a field under a filler.
class _ControlApp extends StatelessWidget {
  const _ControlApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(
                child: ColoredBox(color: Color(0xFFEEEEEE), child: SizedBox.expand()),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: TextField(
                    decoration: const InputDecoration(hintText: 'Message control…'),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configureSystemUi();
  if (_control) {
    runApp(const _ControlApp());
    unawaited(_Driver(null).run());
    return;
  }
  final transport = _BenchTransport();
  final secrets = MemorySecretStore()
    ..secrets[_machineId] = const MachineSecrets(password: 'x');
  SharedPreferences.setMockInitialValues(_seed());
  final app = await bootApp(
    network: FakeNetwork(),
    secrets: secrets,
    snapshotCache: MemorySnapshotCache(),
    connect: (profile, _) => MachineConnection(
      profile: profile,
      api: HerdrApi(transport),
      backoff: (_) => const Duration(seconds: 1),
      pollInterval: const Duration(hours: 1),
    ),
  );
  runApp(app);
  unawaited(_Driver(transport).run());
}

/// What the framework saw at one frame: when, the keyboard's height (physical
/// px), the layout's (what the composer sits above) and the view's height.
typedef _Sample = ({int us, double inset, double layout, double height});

/// One keyboard animation: asked for at [tapUs], finished (quiet) at [endUs].
class _Mark {
  _Mark(this.scenario, this.kind);

  final String scenario; // idle | busy
  final String kind; // open | close
  var cold = false; // the first keyboard of the process
  var measured = true; // false for warm-ups
  var tapUs = 0;
  var endUs = 0;
  var settled = false;
}

/// The frames of one [_Mark].
class _Win {
  var ok = false; // the inset moved at all
  var tapToFirstMs = 0.0;
  var settleMs = 0.0; // tap to the layout being within 10 dp of its end, for good
  var animMs = 0.0;
  var steps = 0; // frames in which the inset moved
  var dropped = 0;
  var jankMs = 0.0;
  var cacheMb = 0.0;
  var firstStepDp = 0.0;
  var lastStepDp = 0.0;
  var maxStepDp = 0.0;
  var ui = <double>[];
  var raster = <double>[];
  var vsync = <double>[]; // vsync to the start of the build
  var gaps = <double>[]; // between the ends of consecutive frames
  var insets = <double>[]; // dp, from before the tap to the last change
  var stepMs = <double>[]; // when each inset change was seen, from the first
  var heights = <double>{}; // the view's heights seen (dp)
  var platformSteps = 0; // distinct keyboard positions the platform reported
  var skipped = 0; // ... that no frame ever drew (two updates in one frame)
}

class _Driver with WidgetsBindingObserver {
  _Driver(this.transport);

  final _BenchTransport? transport;

  final _samples = <_Sample>[];
  final _timings = <ui.FrameTiming>[];
  final _skewUs = <int>[];

  /// Every metrics update Dart receives (the platform's own stream, one per
  /// vsync while the keyboard moves), as the layout inset at that moment.
  final _updates = <({int us, double layout})>[];
  var _inset = 0.0;
  var _lastChangeUs = 0;
  var _pointer = 100;
  var _budgetMs = 1000 / 60;
  var _dpr = 1.0;
  var _geometryLogged = false;
  Timer? _activity;

  ui.FlutterView get _view => ui.PlatformDispatcher.instance.implicitView!;

  Future<void> run() async {
    final watchdog = Timer(const Duration(seconds: 200), () {
      print('KBBENCH_ERROR watchdog: the run did not finish');
    });
    try {
      await _run();
    } catch (e, s) {
      print('KBBENCH_ERROR $e');
      print('KBBENCH_ERROR ${s.toString().split('\n').take(6).join(' | ')}');
    } finally {
      watchdog.cancel();
    }
  }

  Future<void> _run() async {
    final binding = SchedulerBinding.instance;
    binding.addPersistentFrameCallback(_onFrame);
    binding.addTimingsCallback(_onTimings);
    WidgetsBinding.instance.addObserver(this);
    final view = _view;
    _dpr = view.devicePixelRatio;
    final hz = view.display.refreshRate;
    if (hz >= 30 && hz <= 240) _budgetMs = 1000 / hz;
    print(
      'KBBENCH_ENV control=$_control dpr=$_dpr hz=${hz.toStringAsFixed(1)} '
      'budget_ms=${_budgetMs.toStringAsFixed(2)}',
    );

    // The route, the first read and the first parse are not what is measured.
    await _until(() => _composer() != null, 'the composer', const Duration(seconds: 40));
    await Future<void>.delayed(const Duration(seconds: 2));
    _geometry('closed');
    if (_holdOpen) {
      await _open(_Mark('idle', 'open'));
      _geometry('open');
      print('KBBENCH_HOLD the keyboard is open and stays open');
      await Future<void>.delayed(const Duration(minutes: 5));
      return;
    }

    final marks = <_Mark>[];
    await _scenario('idle', busy: false, marks: marks);
    if (transport != null) await _scenario('busy', busy: true, marks: marks);
    _activity?.cancel();

    // FrameTiming reaches the framework in batches, up to a second late.
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    _report(marks);
  }

  /// The window as the framework sees it, in physical px.
  void _geometry(String label) {
    final v = _view;
    String edges(ui.ViewPadding p) =>
        '${p.left.toInt()},${p.top.toInt()},${p.right.toInt()},${p.bottom.toInt()}';
    print(
      'KBBENCH_GEOM $label size=${v.physicalSize.width.toInt()}x${v.physicalSize.height.toInt()} '
      'display=${v.display.size.width.toInt()}x${v.display.size.height.toInt()} '
      'padding=${edges(v.padding)} viewPadding=${edges(v.viewPadding)} '
      'viewInsets=${edges(v.viewInsets)}',
    );
  }

  // -------------------------------------------------------------------------
  // Recording.

  void _onFrame(Duration _) {
    final v = _view;
    final inset = v.viewInsets.bottom;
    final us = Timeline.now;
    if ((inset - _inset).abs() > 0.5) _lastChangeUs = us;
    _inset = inset;
    _samples.add((
      us: us,
      inset: inset,
      layout: math.max(inset, v.viewPadding.bottom),
      height: v.physicalSize.height,
    ));
  }

  @override
  void didChangeMetrics() {
    final v = _view;
    _updates.add((
      us: Timeline.now,
      layout: math.max(v.viewInsets.bottom, v.viewPadding.bottom),
    ));
  }

  void _onTimings(List<ui.FrameTiming> timings) {
    _timings.addAll(timings);
    if (timings.isNotEmpty) {
      _skewUs.add(
        Timeline.now - timings.last.timestampInMicroseconds(ui.FramePhase.rasterFinish),
      );
    }
  }

  // -------------------------------------------------------------------------
  // Driving.

  Future<void> _scenario(
    String name, {
    required bool busy,
    required List<_Mark> marks,
  }) async {
    _activity?.cancel();
    if (busy) _activity = Timer.periodic(_activityEvery, (_) => transport?.activity());
    // Let the first update (or the quiet) settle in.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final cold = name == 'idle' ? 1 : 0;
    for (var i = 0; i < cold + _warmups + _cycles; i++) {
      final measured = i >= cold + _warmups;
      final open = _Mark(name, 'open')
        ..cold = i < cold
        ..measured = measured;
      await _open(open);
      marks.add(open);
      if (!_geometryLogged) {
        _geometryLogged = true;
        _geometry('open');
      }
      await Future<void>.delayed(_hold);
      final close = _Mark(name, 'close')..measured = measured;
      await _close(close);
      marks.add(close);
      await Future<void>.delayed(_hold);
    }
  }

  Future<void> _open(_Mark mark) async {
    final composer = _composer();
    if (composer == null) throw StateError('the composer is gone');
    final box = composer.renderObject! as RenderBox;
    final at = box.localToGlobal(box.size.center(Offset.zero));
    mark.tapUs = Timeline.now;
    if (_trace) {
      print('KBTAP open mono=${mark.tapUs} wall=${DateTime.now().toIso8601String()}');
    }
    await _tap(at);
    mark.settled = await _keyboard(open: true, since: mark.tapUs);
    mark.endUs = Timeline.now;
    _traceCycle('open', mark);
  }

  Future<void> _close(_Mark mark) async {
    mark.tapUs = Timeline.now;
    if (_trace) {
      print('KBTAP close mono=${mark.tapUs} wall=${DateTime.now().toIso8601String()}');
    }
    FocusManager.instance.primaryFocus?.unfocus();
    mark.settled = await _keyboard(open: false, since: mark.tapUs);
    mark.endUs = Timeline.now;
    _traceCycle('close', mark);
  }

  /// Each frame in which the inset moved, as `monotonic µs:px`.
  void _traceCycle(String kind, _Mark mark) {
    if (!_trace) return;
    final b = StringBuffer();
    var previous = -1.0;
    for (final s in _samples) {
      if (s.us < mark.tapUs - 50000 || s.us > mark.endUs) continue;
      if ((s.inset - previous).abs() > 0.5) {
        b.write('${s.us}:${s.inset.toStringAsFixed(1)} ');
        previous = s.inset;
      }
    }
    print('KBTRACE $kind tap=${mark.tapUs} frames=${b.toString().trim()}');
  }

  /// A finger: down, a short press, up.
  Future<void> _tap(Offset at) async {
    final id = ++_pointer;
    final viewId = _view.viewId;
    final binding = GestureBinding.instance;
    binding.handlePointerEvent(
      PointerDownEvent(
        viewId: viewId,
        timeStamp: Duration(microseconds: Timeline.now),
        pointer: id,
        kind: PointerDeviceKind.touch,
        position: at,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    binding.handlePointerEvent(
      PointerUpEvent(
        viewId: viewId,
        timeStamp: Duration(microseconds: Timeline.now),
        pointer: id,
        kind: PointerDeviceKind.touch,
        position: at,
      ),
    );
  }

  /// Waits for the keyboard to be up (or gone) and quiet.
  Future<bool> _keyboard({required bool open, required int since}) async {
    final watch = Stopwatch()..start();
    while (watch.elapsedMilliseconds < 6000) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final now = _view.viewInsets.bottom;
      final there = open ? now > 50 : now < 0.5;
      if (there &&
          now == _inset &&
          _lastChangeUs > since &&
          Timeline.now - _lastChangeUs >= _quiet.inMicroseconds) {
        return true;
      }
    }
    return false;
  }

  /// The composer's `TextField`, once its pane is online (hint "Message …").
  Element? _composer() {
    Element? found;
    void visit(Element e) {
      if (found != null) return;
      final w = e.widget;
      if (w is TextField &&
          (w.enabled ?? true) &&
          (w.decoration?.hintText?.startsWith('Message') ?? false)) {
        found = e;
        return;
      }
      e.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return found;
  }

  Future<void> _until(bool Function() test, String what, Duration timeout) async {
    final watch = Stopwatch()..start();
    while (!test()) {
      if (watch.elapsed > timeout) throw StateError('timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  // -------------------------------------------------------------------------
  // Analysis.

  int _raster(ui.FrameTiming t) => t.timestampInMicroseconds(ui.FramePhase.rasterFinish);

  /// The frames of [m]: those whose build overlaps the span in which the inset
  /// moved, and the inset series itself.
  _Win _analyse(_Mark m) {
    final w = _Win();
    var before = 0.0;
    for (final s in _samples) {
      if (s.us > m.tapUs) break;
      before = s.layout;
    }
    final moved = <_Sample>[];
    var previous = before;
    for (final s in _samples) {
      if (s.us < m.tapUs || s.us > m.endUs) continue;
      w.heights.add((s.height / _dpr).roundToDouble());
      if ((s.layout - previous).abs() > 0.5) {
        moved.add(s);
        previous = s.layout;
      }
    }
    if (moved.isEmpty) return w;
    w.ok = true;
    final first = moved.first;
    final last = moved.last;
    w.steps = moved.length;
    w.tapToFirstMs = (first.us - m.tapUs) / 1000;
    // When the layout got within 10 dp of where it ends, and stayed there.
    var settle = moved.length - 1;
    while (settle > 0 && (moved[settle - 1].layout - last.layout).abs() <= 10 * _dpr) {
      settle--;
    }
    w.settleMs = (moved[settle].us - m.tapUs) / 1000;
    w.animMs = (last.us - first.us) / 1000;
    w.insets = [before / _dpr, for (final s in moved) s.layout / _dpr];
    w.stepMs = [for (final s in moved) (s.us - first.us) / 1000];
    final deltas = [
      for (var i = 1; i < w.insets.length; i++) (w.insets[i] - w.insets[i - 1]).abs(),
    ];
    w.firstStepDp = deltas.first;
    w.lastStepDp = deltas.last;
    w.maxStepDp = deltas.fold<double>(0, math.max);

    // The platform's positions of the keyboard, and which of them a frame drew.
    var seen = before;
    final shown = [for (final s in moved) s.layout];
    for (final u in _updates) {
      if (u.us < m.tapUs || u.us > m.endUs) continue;
      if ((u.layout - seen).abs() <= 0.5) continue;
      seen = u.layout;
      w.platformSteps++;
      if (!shown.any((v) => (v - u.layout).abs() <= 0.5)) w.skipped++;
    }

    final frames = _timings.where((t) {
      final start = t.timestampInMicroseconds(ui.FramePhase.buildStart);
      final finish = t.timestampInMicroseconds(ui.FramePhase.buildFinish);
      return finish >= first.us && start <= last.us;
    }).toList()
      ..sort((a, b) => _raster(a).compareTo(_raster(b)));
    for (var i = 0; i < frames.length; i++) {
      final f = frames[i];
      final build = f.buildDuration.inMicroseconds / 1000;
      final raster = f.rasterDuration.inMicroseconds / 1000;
      w.ui.add(build);
      w.raster.add(raster);
      w.vsync.add(f.vsyncOverhead.inMicroseconds / 1000);
      w.jankMs += math.max(0, math.max(build, raster) - _budgetMs);
      w.cacheMb = math.max(w.cacheMb, f.layerCacheMegabytes + f.pictureCacheMegabytes);
      if (i > 0) {
        final gap = (_raster(f) - _raster(frames[i - 1])) / 1000;
        w.gaps.add(gap);
        w.dropped += math.max(0, (gap / _budgetMs).round() - 1);
      }
    }
    return w;
  }

  static double _median(List<double> v) {
    if (v.isEmpty) return 0;
    final s = [...v]..sort();
    return s[s.length ~/ 2];
  }

  static double _pct(List<double> v, double p) {
    if (v.isEmpty) return 0;
    final s = [...v]..sort();
    return s[math.min(s.length - 1, (s.length * p).floor())];
  }

  static String _list(List<double> v) => v.map((x) => x.toStringAsFixed(1)).join(',');

  void _metric(String name, num value) => print(
        'KBBENCH_METRIC $name=${value is int ? value : value.toStringAsFixed(3)}',
      );

  void _report(List<_Mark> marks) {
    if (_timings.isEmpty) throw StateError('no FrameTiming arrived');
    _skewUs.sort();
    final skewMs = _skewUs[_skewUs.length ~/ 2] / 1000;
    // FrameTiming and Timeline.now must share a clock: a report arrives soon
    // after its newest frame finished, never before and not minutes later.
    if (skewMs < 0 || skewMs > 5000) {
      print('KBBENCH_WARN clock skew between FrameTiming and Timeline: $skewMs ms');
    }
    _metric('clock_skew_ms', skewMs);
    _metric('frames_recorded', _timings.length);
    _geometry('end');

    var failed = 0;
    final snap = <String, double>{};
    for (final scenario in const ['idle', 'busy']) {
      for (final kind in const ['open', 'close']) {
        final all = marks.where((m) => m.scenario == scenario && m.kind == kind).toList();
        if (all.isEmpty) continue;
        final wins = [for (final m in all) (m, _analyse(m))];
        failed += wins.where((p) => !p.$2.ok || !p.$1.settled).length;

        // The first two cycles in full, to read the shape of an animation.
        var shown = 0;
        for (final (m, w) in wins) {
          if (!m.measured || shown >= 2) continue;
          shown++;
          print(
            'KBBENCH_CYCLE $scenario $kind tap_to_first=${w.tapToFirstMs.toStringAsFixed(0)}ms '
            'anim=${w.animMs.toStringAsFixed(0)}ms steps=${w.steps} frames=${w.ui.length} '
            'dropped=${w.dropped} jank=${w.jankMs.toStringAsFixed(1)}ms settled=${m.settled} '
            'platform_steps=${w.platformSteps} skipped=${w.skipped} '
            'view_h_dp=${w.heights.join('/')}',
          );
          print('KBBENCH_INSETS $scenario $kind dp=${_list(w.insets)}');
          print('KBBENCH_STEPMS $scenario $kind ms=${_list(w.stepMs)}');
          print('KBBENCH_UI $scenario $kind ms=${_list(w.ui)}');
          print('KBBENCH_RASTER $scenario $kind ms=${_list(w.raster)}');
          print('KBBENCH_VSYNC $scenario $kind ms=${_list(w.vsync)}');
        }

        final cold = wins.where((p) => p.$1.cold && p.$2.ok).toList();
        if (cold.isNotEmpty) {
          final w = cold.first.$2;
          _metric('cold_${kind}_tap_to_first_ms', w.tapToFirstMs);
          _metric('cold_${kind}_anim_ms', w.animMs);
          _metric('cold_${kind}_steps', w.steps);
          _metric('cold_${kind}_jank_ms', w.jankMs);
          _metric('cold_${kind}_dropped', w.dropped);
        }

        final ok = [
          for (final (m, w) in wins)
            if (m.measured && !m.cold && w.ok) w,
        ];
        if (ok.isEmpty) continue;
        final p = '${scenario}_$kind';
        double med(double Function(_Win) f) => _median([for (final w in ok) f(w)]);
        final ui = [for (final w in ok) ...w.ui];
        final raster = [for (final w in ok) ...w.raster];
        final gaps = [for (final w in ok) ...w.gaps];
        _metric('${p}_tap_to_first_ms', med((w) => w.tapToFirstMs));
        _metric('${p}_settle_ms', med((w) => w.settleMs));
        _metric('${p}_anim_ms', med((w) => w.animMs));
        _metric('${p}_steps', med((w) => w.steps.toDouble()));
        _metric('${p}_frames', med((w) => w.ui.length.toDouble()));
        _metric('${p}_dropped', med((w) => w.dropped.toDouble()));
        _metric('${p}_jank_ms', med((w) => w.jankMs));
        _metric('${p}_ui_p95_ms', _pct(ui, 0.95));
        _metric('${p}_ui_max_ms', ui.fold<double>(0, math.max));
        _metric('${p}_raster_p95_ms', _pct(raster, 0.95));
        _metric('${p}_raster_max_ms', raster.fold<double>(0, math.max));
        _metric('${p}_gap_p95_ms', _pct(gaps, 0.95));
        _metric('${p}_cache_mb', med((w) => w.cacheMb));
        _metric('${p}_first_step_dp', med((w) => w.firstStepDp));
        _metric('${p}_last_step_dp', med((w) => w.lastStepDp));
        _metric('${p}_max_step_dp', med((w) => w.maxStepDp));
        _metric('${p}_platform_steps', med((w) => w.platformSteps.toDouble()));
        _metric('${p}_skipped', med((w) => w.skipped.toDouble()));
        _metric(
          '${p}_render_ratio',
          med((w) => w.platformSteps == 0 ? 1 : 1 - w.skipped / w.platformSteps),
        );
        snap[p] = kind == 'open'
            ? med((w) => w.lastStepDp)
            : med((w) => w.firstStepDp);
      }
    }
    _metric('failed_cycles', failed);
    // The jump at the end of the opening, idle agent: ~0 when the animated
    // inset ends where the settled one is.
    final open = snap['idle_open'];
    if (open != null) _metric('snap_dp', open);
    print('KBBENCH_DONE');
  }
}
