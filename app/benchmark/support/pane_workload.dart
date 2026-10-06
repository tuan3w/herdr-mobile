// The pane content the benchmarks replay: seeded, deterministic ANSI rows, as
// `pane.read` returns them. Shared by `pane_bench.dart` (the test binding) and
// `keyboard_device_bench.dart` (a phone), so both stress the same bytes.
import 'dart:math' as math;

/// Rows of the live tail `PaneViewModel` reads.
const paneWindow = 300;

/// Rows the pane moves between two reads: history grows by this much per read.
const paneSlide = 3;

/// The last rows of every read are a status area that changes each read.
const paneFooter = 4;

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

/// The text `pane.read` returns when the pane's newest body row is [newest],
/// at animation [step]: the last [paneWindow] rows. [rows], when given,
/// remembers the body rows, so the next read of a sliding tail builds only the
/// rows that are new (what a phone-side fake wants: the real read is built off
/// the UI thread).
String paneReadAt(int newest, int step, {Map<int, String>? rows}) {
  final lines = <String>[
    for (var a = newest - (paneWindow - paneFooter); a < newest; a++)
      rows == null ? _bodyRow(a) : rows.putIfAbsent(a, () => _bodyRow(a)),
    ..._footerRows(step),
  ];
  return '${lines.join('\r\n')}\r\n';
}

/// The text `pane.read` returns at [step]: the last [paneWindow] rows.
String paneRead(int step) => paneReadAt(1000 + step * paneSlide, step);
