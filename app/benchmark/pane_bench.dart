// Deterministic benchmark of the pane hot path:
//
//   flutter test benchmark/pane_bench.dart
//
// It replays a seeded stream of ~140 KB ANSI reads (a 300 row tail sliding by
// a few rows per read, plus a spinner/status area that changes every read)
// through the same objects the pane screen uses: ScrollbackHistory, then
// TerminalDocument inside a real TerminalView, laid out and painted by the test
// binding at a phone viewport. No network, no clock, fixed seed.
//
// Results go to the file named by $BENCH_OUT (METRIC lines), because
// `flutter test` decorates stdout.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/terminal_cells.dart';
import 'package:herdr_mobile/ui/core/terminal_view.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/pane/scrollback_history.dart';

import '../test/support/shot.dart' show loadAppFonts;
import 'support/pane_workload.dart';

const _warmup = 15;
const _steps = 120;
const _scrollFrames = 90;
const _scrolledSteps = 40;

final _out = <String>[];

void _metric(String name, num value) =>
    _out.add('METRIC $name=${value is int ? value : value.toStringAsFixed(3)}');

// ---------------------------------------------------------------------------
// Workload: fixed seed (support/pane_workload.dart), built before any timing.
// ---------------------------------------------------------------------------

double _pct(List<double> sorted, double p) =>
    sorted[math.min(sorted.length - 1, (sorted.length * p).floor())];

void _report(String name, List<double> ms) {
  final s = [...ms]..sort();
  _metric('${name}_p50_ms', _pct(s, 0.5));
  _metric('${name}_p95_ms', _pct(s, 0.95));
  _metric('${name}_max_ms', s.last);
}

/// What the pane shows. The app stays mounted and only this changes, as in
/// the real pane screen, where a ChangeNotifier rebuilds the pane and not the
/// app around it (pumping a new MaterialApp per read would measure re-walking
/// the theme and scaffold, which a read never does).
final _shown = ValueNotifier<({String text, List<String> history})>(
  (text: '', history: const []),
);
var _mounted = false;

Widget _app(ScrollbackHistory h, {required bool wrap}) {
  _shown.value = (text: h.window, history: h.rows);
  return MaterialApp(
    theme: AppTheme.dark(),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 392,
          height: 760,
          child: ValueListenableBuilder(
            valueListenable: _shown,
            builder: (context, shown, _) => TerminalView(
              text: shown.text,
              history: shown.history,
              wrap: wrap,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Mounts the app on the first call; afterwards only swaps the content.
Future<void> _show(
  WidgetTester tester,
  ScrollbackHistory h, {
  required bool wrap,
}) async {
  if (!_mounted) {
    _mounted = true;
    await tester.pumpWidget(_app(h, wrap: wrap));
    return;
  }
  _shown.value = (text: h.window, history: h.rows);
  await tester.pump();
}

/// Streams [steps] reads through history + view; returns per-step ms split
/// into (history merge, view update). [read] gives the text of read `s`.
Future<({List<double> history, List<double> view})> _stream(
  WidgetTester tester,
  ScrollbackHistory history,
  int from,
  int steps, {
  required bool wrap,
  String Function(int s) read = paneRead,
}) async {
  final hist = <double>[];
  final view = <double>[];
  for (var s = from; s < from + steps; s++) {
    final text = read(s);
    final sw = Stopwatch()..start();
    history.update(text, truncated: true);
    final a = sw.elapsedMicroseconds;
    await _show(tester, history, wrap: wrap);
    final b = sw.elapsedMicroseconds - a;
    hist.add(a / 1000);
    view.add(b / 1000);
  }
  return (history: hist, view: view);
}

/// The vertical scroll position of the terminal's row list.
ScrollPosition _rows(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.byWidgetPredicate(
        (w) =>
            w is Scrollable &&
            axisDirectionToAxis(w.axisDirection) == Axis.vertical,
      ),
    )
    .position;

/// Rows of history the deep scenario builds up before it starts measuring: a
/// pane that has been busy for a long while (the history keeps up to 20000).
const _deepRows = 10000;

/// Rows the pane moves between two reads while the history builds up (a busy
/// agent between two throttled reads); streaming at depth uses [paneSlide].
const _deepSlide = 30;
const _deepFlings = 8;
const _deepSteps = 60;

/// The same pane after ~[_deepRows] rows of history: what streaming, opening,
/// dragging, flinging and jumping cost when there is a lot to scroll through.
Future<void> _deepScenario(
  WidgetTester tester,
  String name, {
  required bool wrap,
}) async {
  _mounted = false;
  final history = ScrollbackHistory();
  var newest = 1000;
  var step = 0;
  history.update(paneReadAt(newest, step), truncated: true);
  final fill = <double>[];
  for (var i = 0; i < _deepRows ~/ _deepSlide; i++) {
    newest += _deepSlide;
    step++;
    final text = paneReadAt(newest, step); // not timed
    final sw = Stopwatch()..start();
    history.update(text, truncated: true);
    fill.add(sw.elapsedMicroseconds / 1000);
  }
  expect(history.rows.length, greaterThan(_deepRows - 400));
  _report('${name}_history', fill);

  // Cold open: parse (and, wrapping, flow) every line, lay out one screen.
  final cold = Stopwatch()..start();
  await _show(tester, history, wrap: wrap);
  _metric('${name}_open_ms', cold.elapsedMicroseconds / 1000);

  // Streaming with the whole history in the view.
  final base = newest;
  final baseStep = step;
  String read(int s) => paneReadAt(base + (s - baseStep) * paneSlide, s);
  await _stream(tester, history, step + 1, _warmup, wrap: wrap, read: read);
  final streamed = await _stream(
    tester,
    history,
    step + 1 + _warmup,
    _deepSteps,
    wrap: wrap,
    read: read,
  );
  step += _warmup + _deepSteps;
  _report('${name}_step', [
    for (var i = 0; i < _deepSteps; i++)
      streamed.history[i] + streamed.view[i],
  ]);

  // Fling back through the history: every row that comes on screen is new.
  final view = find.byType(TerminalView);
  final frames = <double>[];
  for (var f = 0; f < _deepFlings; f++) {
    await tester.fling(view, const Offset(0, 300), 8000);
    for (var i = 0; i < 400 && tester.binding.hasScheduledFrame; i++) {
      final sw = Stopwatch()..start();
      await tester.pump(const Duration(milliseconds: 16));
      frames.add(sw.elapsedMicroseconds / 1000);
    }
  }
  _report('${name}_fling', frames);
  final flung = _rows(tester);
  _metric('${name}_fling_reach_px', flung.pixels);
  _metric('${name}_extent_px', flung.maxScrollExtent);
  expect(flung.maxScrollExtent, greaterThan(_deepRows * 10.0));
  expect(flung.pixels, greaterThan(20 * flung.viewportDimension));

  // Jump a long way in one go (a scrollbar-style drag to the far end and
  // back): the frame that lands somewhere never seen.
  final jumps = <double>[];
  // Enough jumps for a median that is not decided by a few frames (a run of
  // four was swayed by when the JIT happened to tier up).
  for (var j = 0; j < 24; j++) {
    final gesture = await tester.startGesture(const Offset(200, 300));
    // Many pointer moves, then one frame: the scroll position has already
    // moved when the frame lays out, as when the finger outruns the display.
    for (var k = 0; k < 150; k++) {
      await gesture.moveBy(Offset(0, j.isEven ? 1000 : -1000));
    }
    final sw = Stopwatch()..start();
    await tester.pump(const Duration(milliseconds: 16));
    jumps.add(sw.elapsedMicroseconds / 1000);
    await gesture.up();
    await tester.pumpAndSettle();
  }
  _report('${name}_jump', jumps);
  _metric('${name}_jump_end_px', _rows(tester).pixels);

  // Slow drag at depth.
  final gesture = await tester.startGesture(const Offset(200, 300));
  final drag = <double>[];
  for (var i = 0; i < _scrollFrames; i++) {
    final sw = Stopwatch()..start();
    await gesture.moveBy(const Offset(0, 14));
    await tester.pump(const Duration(milliseconds: 16));
    drag.add(sw.elapsedMicroseconds / 1000);
  }
  _report('${name}_drag', drag);

  // Keep streaming while the user is reading deep in the history.
  final scrolled = await _stream(
    tester,
    history,
    step + 1,
    _deepSteps,
    wrap: wrap,
    read: read,
  );
  _report('${name}_scrolled_step', [
    for (var i = 0; i < _deepSteps; i++)
      scrolled.history[i] + scrolled.view[i],
  ]);
  await gesture.up();

  expect(find.byType(TerminalLineView).evaluate().length, greaterThan(20));
}

Future<void> _scenario(
  WidgetTester tester,
  String name, {
  required bool wrap,
}) async {
  _mounted = false;
  final history = ScrollbackHistory();

  // Cold open: first paint of a full tail.
  final cold = Stopwatch()..start();
  history.update(paneRead(0), truncated: true);
  await _show(tester, history, wrap: wrap);
  _metric('${name}_open_ms', cold.elapsedMicroseconds / 1000);

  await _stream(tester, history, 1, _warmup, wrap: wrap);
  final streamed =
      await _stream(tester, history, 1 + _warmup, _steps, wrap: wrap);
  _report('${name}_history', streamed.history);
  _report('${name}_view', streamed.view);
  _report('${name}_step', [
    for (var i = 0; i < _steps; i++) streamed.history[i] + streamed.view[i],
  ]);

  // Scroll back through history: rows are prepared as they come on screen.
  final gesture = await tester.startGesture(const Offset(200, 300));
  final frames = <double>[];
  for (var i = 0; i < _scrollFrames; i++) {
    final sw = Stopwatch()..start();
    await gesture.moveBy(const Offset(0, 14));
    await tester.pump(const Duration(milliseconds: 16));
    frames.add(sw.elapsedMicroseconds / 1000);
  }
  _report('${name}_scroll', frames);

  // Keep streaming while the user is reading back (anchoring path).
  final scrolled = await _stream(
    tester,
    history,
    1 + _warmup + _steps,
    _scrolledSteps,
    wrap: wrap,
  );
  _report('${name}_scrolled_step', [
    for (var i = 0; i < _scrolledSteps; i++)
      scrolled.history[i] + scrolled.view[i],
  ]);
  await gesture.up();

  // Guard against "optimising" by drawing nothing.
  expect(find.byType(TerminalLineView).evaluate().length, greaterThan(20));
}

void main() {
  final outPath = Platform.environment['BENCH_OUT'];

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadAppFonts();
  });

  tearDownAll(() {
    final text = '${_out.join('\n')}\n';
    if (outPath != null) {
      File(outPath).writeAsStringSync(text);
    } else {
      stdout.write(text);
    }
  });

  testWidgets('pane stream, native rows', semanticsEnabled: false, (tester) async {
    tester.view
      ..physicalSize = const Size(392 * 2.75, 760 * 2.75)
      ..devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await _scenario(tester, 'nowrap', wrap: false);
  });

  testWidgets('pane stream, wrapped', semanticsEnabled: false, (tester) async {
    tester.view
      ..physicalSize = const Size(392 * 2.75, 760 * 2.75)
      ..devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await _scenario(tester, 'wrap', wrap: true);
  });

  testWidgets('deep history, native rows', semanticsEnabled: false, (tester) async {
    tester.view
      ..physicalSize = const Size(392 * 2.75, 760 * 2.75)
      ..devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await _deepScenario(tester, 'deep', wrap: false);
  });

  testWidgets('deep history, wrapped', semanticsEnabled: false, (tester) async {
    tester.view
      ..physicalSize = const Size(392 * 2.75, 760 * 2.75)
      ..devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await _deepScenario(tester, 'deepwrap', wrap: true);
  });
}
