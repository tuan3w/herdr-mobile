import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/terminal_document.dart';
import 'package:herdr_mobile/ui/features/pane/scrollback_history.dart';

String _row(int a) {
  final r = math.Random(a * 7919 + 13);
  final b = StringBuffer('\x1b[2m${a.toString().padLeft(5)} \x1b[0m');
  for (var i = 0; i < 12; i++) {
    b.write('\x1b[38;2;${r.nextInt(256)};${r.nextInt(256)};${r.nextInt(256)}mword$i ');
  }
  b.write('\x1b[0m');
  return b.toString();
}

String _read(int newest) =>
    '${[for (var a = newest - 296; a < newest; a++) _row(a), 'f1', 'f2', 'f3', 'f4'].join('\r\n')}\r\n';

void main() {
  for (final depth in [300, 10000, 20000]) {
    test('depth $depth', () {
      final h = ScrollbackHistory();
      final doc = TerminalDocument();
      var newest = 1000;
      h.update(_read(newest), truncated: true);
      for (var i = 0; i < depth ~/ 30; i++) {
        newest += 30;
        h.update(_read(newest), truncated: true);
      }
      doc.update(h.rows, h.window);
      final snap = <int>[], upd = <int>[];
      for (var s = 0; s < 200; s++) {
        newest += 3;
        final text = _read(newest);
        h.update(text, truncated: true);
        final a = Stopwatch()..start();
        final rows = h.rows;
        snap.add(a.elapsedMicroseconds);
        final b = Stopwatch()..start();
        doc.update(rows, h.window);
        upd.add(b.elapsedMicroseconds);
      }
      snap.sort(); upd.sort();
      // ignore: avoid_print
      print('depth=${h.rows.length} rows(snapshot) p50=${snap[100]}us  doc.update p50=${upd[100]}us p95=${upd[190]}us');
    });
  }
}
