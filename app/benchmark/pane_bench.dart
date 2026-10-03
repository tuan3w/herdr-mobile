// Deterministic benchmark of the pane hot path, run by `autoresearch.sh`:
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

const _window = 300;
const _warmup = 15;
const _steps = 120;
const _scrollFrames = 90;
const _scrolledSteps = 40;

final _out = <String>[];

void _metric(String name, num value) =>
    _out.add('METRIC $name=${value is int ? value : value.toStringAsFixed(3)}');

// ---------------------------------------------------------------------------
// Workload: fixed seed, built before any timing starts.

const _words = [
  'final', 'class', 'return', 'await', 'import', 'const', 'if', 'else',
  'struct', 'fn', 'let', 'match', 'Future', 'String', 'widget', 'paint',
  'herdr', 'agent', 'pane', 'socket', 'transport', 'notify', 'state',
  'Xin chào', 'tiếng Việt', 'đường dẫn', '✓', '●', '→', '…',
];

String _sgrFg(math.Random r) =>
    '\x1b[38;2;${r.nextInt(256)};${r.nextInt(256)};${r.nextInt(256)}m';

/// One row of syntax-highlighted looking output: ~100 cells, a colour change
/// every few words (about 470 bytes, which makes 300 rows ~140 KB).
String _codeRow(math.Random r, int n) {
  final b = StringBuffer();
  if (r.nextInt(6) == 0) b.write('\x1b[48;2;20;60;30m'); // diff-added row
  b.write('\x1b[2m${n.toString().padLeft(5)} \x1b[0m');
  var cells = 6;
  while (cells < 100) {
    final w = _words[r.nextInt(_words.length)];
    if (r.nextBool()) b.write(_sgrFg(r));
    if (r.nextInt(8) == 0) b.write('\x1b[1m');
    b.write(w);
    b.write(' ');
    if (r.nextInt(5) == 0) b.write('\x1b[0m');
    cells += w.length + 1;
  }
  b.write('\x1b[0m');
  return b.toString();
}

String _boxRow(int kind, int width) {
  const l = ['┌', '│', '└'];
  const f = ['─', ' ', '─'];
  const rr = ['┐', '│', '┘'];
  return '\x1b[38;5;244m${l[kind]}${f[kind] * (width - 2)}${rr[kind]}\x1b[0m';
}

String _plainRow(math.Random r) {
  final b = StringBuffer();
  while (b.length < 90) {
    b.write(_words[r.nextInt(_words.length)]);
    b.write(' ');
  }
  return b.toString();
}

/// The rows of "the pane" at read [step]: history grows by [_slide] rows per
/// read; the last [_footer] rows are a changing status area.
const _slide = 3;
const _footer = 4;

String _bodyRow(int absolute) {
  final r = math.Random(absolute * 7919 + 13);
  switch (absolute % 11) {
    case 0:
      return _boxRow(0, 96);
    case 1:
      return _boxRow(1, 96);
    case 2:
      return _boxRow(2, 96);
    case 3:
    case 4:
      return _plainRow(r);
    default:
      return _codeRow(r, absolute);
  }
}

List<String> _footerRows(int step) => [
      _boxRow(0, 96),
      '\x1b[38;5;214m${'⠋⠙⠹⠸⠼⠴⠦⠧'[step % 8]}\x1b[0m Working… ${step * 37 % 997}s '
          '\x1b[2m(esc to interrupt)\x1b[0m',
      _boxRow(1, 96),
      '\x1b[2m? for shortcuts\x1b[0m',
    ];

/// The text `pane.read` returns at [step]: the last [_window] rows.
String _read(int step) {
  final newest = 1000 + step * _slide;
  final rows = <String>[
    for (var a = newest - (_window - _footer); a < newest; a++) _bodyRow(a),
    ..._footerRows(step),
  ];
  return '${rows.join('\r\n')}\r\n';
}

// ---------------------------------------------------------------------------

double _pct(List<double> sorted, double p) =>
    sorted[math.min(sorted.length - 1, (sorted.length * p).floor())];

void _report(String name, List<double> ms) {
  final s = [...ms]..sort();
  _metric('${name}_p50_ms', _pct(s, 0.5));
  _metric('${name}_p95_ms', _pct(s, 0.95));
  _metric('${name}_max_ms', s.last);
}

Widget _app(String text, List<String> history, {required bool wrap}) =>
    MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 392,
            height: 760,
            child: TerminalView(text: text, history: history, wrap: wrap),
          ),
        ),
      ),
    );

/// Streams [steps] reads through history + view; returns per-step ms split
/// into (history merge, view update).
Future<({List<double> history, List<double> view})> _stream(
  WidgetTester tester,
  ScrollbackHistory history,
  int from,
  int steps, {
  required bool wrap,
}) async {
  final hist = <double>[];
  final view = <double>[];
  for (var s = from; s < from + steps; s++) {
    final text = _read(s);
    final sw = Stopwatch()..start();
    history.update(text, truncated: true);
    final a = sw.elapsedMicroseconds;
    await tester.pumpWidget(_app(history.window, history.rows, wrap: wrap));
    final b = sw.elapsedMicroseconds - a;
    hist.add(a / 1000);
    view.add(b / 1000);
  }
  return (history: hist, view: view);
}

Future<void> _scenario(
  WidgetTester tester,
  String name, {
  required bool wrap,
}) async {
  final history = ScrollbackHistory();

  // Cold open: first paint of a full tail.
  final cold = Stopwatch()..start();
  history.update(_read(0), truncated: true);
  await tester.pumpWidget(_app(history.window, history.rows, wrap: wrap));
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

  testWidgets('pane stream, native rows', (tester) async {
    tester.view
      ..physicalSize = const Size(392 * 2.75, 760 * 2.75)
      ..devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await _scenario(tester, 'nowrap', wrap: false);
  });

  testWidgets('pane stream, wrapped', (tester) async {
    tester.view
      ..physicalSize = const Size(392 * 2.75, 760 * 2.75)
      ..devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await _scenario(tester, 'wrap', wrap: true);
  });
}
