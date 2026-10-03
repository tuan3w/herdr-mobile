import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/features/pane/scrollback_history.dart';

const _gap = ScrollbackHistory.gapRow;

/// A row of the simulated pane. Unique per index, with a blank row, an
/// ANSI-coloured row and plain rows mixed in, and `\r` line endings as the
/// server sends them.
String _defaultRow(int i) => switch (i % 11) {
  0 => '\r',
  3 => '\x1b[31mrow $i\x1b[0m\r',
  _ => 'row $i\r',
};

/// A deterministic stand-in for a terminal: an ever-growing list of rows
/// that is read through a sliding window of the last `depth` rows.
class _Sim {
  _Sim(int initial, {this.trailingNewline = false, String Function(int)? rowOf})
    : _rowOf = rowOf ?? _defaultRow {
    append(initial);
  }

  final bool trailingNewline;
  final String Function(int) _rowOf;
  final List<String> out = [];
  int _spin = 0;

  void append(int count) {
    for (var i = 0; i < count; i++) {
      out.add(_rowOf(out.length));
    }
  }

  /// Rewrites the last [count] rows in place, like a spinner or progress bar.
  void rewriteTail(int count) {
    for (var i = 1; i <= min(count, out.length); i++) {
      out[out.length - i] = '\x1b[33mspin ${_spin++}\x1b[0m\r';
    }
  }

  String text(int depth) {
    final joined = out.sublist(max(0, out.length - depth)).join('\n');
    return trailingNewline ? '$joined\n' : joined;
  }

  void read(ScrollbackHistory history, int depth) =>
      history.update(text(depth), truncated: out.length > depth);
}

List<String> _known(ScrollbackHistory h) => [
  ...h.rows,
  ...ScrollbackHistory.splitRows(h.window),
];

/// Everything retained is exactly the newest rows of the real output.
void _expectTail(ScrollbackHistory h, _Sim sim, {String? reason}) {
  final known = _known(h);
  expect(known.length, lessThanOrEqualTo(sim.out.length), reason: reason);
  final tail = sim.out.sublist(sim.out.length - known.length);
  for (var i = 0; i < known.length; i++) {
    if (known[i] != tail[i]) {
      fail(
        '${reason ?? ''} row $i of ${known.length}: '
        '${known[i]} != ${tail[i]}',
      );
    }
  }
}

/// Structural rules that hold after any update.
void _expectInvariants(ScrollbackHistory h, {String? reason}) {
  final rows = h.rows;
  if (rows.isNotEmpty) {
    expect(rows.first, isNot(_gap), reason: reason);
  }
  for (var i = 1; i < rows.length; i++) {
    if (rows[i] == _gap && rows[i - 1] == _gap) {
      fail('${reason ?? ''} adjacent gap rows at $i');
    }
  }
  expect(
    h.contiguousRows,
    rows.length - 1 - rows.lastIndexOf(_gap) + h.windowRows,
    reason: reason,
  );
}

int _count(List<String> rows, String row) => rows.where((r) => r == row).length;

void main() {
  group('splitRows', () {
    for (final (text, rows) in <(String, List<String>)>[
      ('', []),
      ('\n', ['']),
      ('a', ['a']),
      ('a\n', ['a']),
      ('a\nb', ['a', 'b']),
      ('a\nb\n', ['a', 'b']),
      ('a\n\n', ['a', '']),
      ('\n\n', ['', '']),
      ('a\r\nb\r\n', ['a\r', 'b\r']),
    ]) {
      test(text.replaceAll('\n', r'\n').replaceAll('\r', r'\r'), () {
        expect(ScrollbackHistory.splitRows(text), rows);
      });
    }
  });

  group('sliding windows', () {
    test('history + window is always the true tail of the output', () {
      const depths = [20, 50, 300, 1000];
      var deepest = 0;
      for (var seed = 0; seed < 40; seed++) {
        final random = Random(seed);
        final sim = _Sim(
          100 + random.nextInt(200),
          trailingNewline: seed.isOdd,
        );
        final h = ScrollbackHistory();
        var depth = depths[random.nextInt(depths.length)];
        sim.read(h, depth);
        var revision = h.revision;
        for (var step = 0; step < 80; step++) {
          final reason = 'seed $seed step $step';
          // Depth varies per read: the app mixes 300 and 1000 row reads.
          if (random.nextInt(3) == 0) {
            depth = depths[random.nextInt(depths.length)];
          }
          // Keep at least 12 rows shared with what is known so that at most
          // five rewritten ones leave enough to align on.
          final shared = min(depth, _known(h).length) - 12;
          sim.append(
            random.nextInt(10) < 8
                ? random.nextInt(min(8, shared + 1))
                : random.nextInt(shared + 1),
          );
          sim.rewriteTail(random.nextInt(6));
          sim.read(h, depth);

          _expectTail(h, sim, reason: reason);
          _expectInvariants(h, reason: reason);
          expect(h.rows, isNot(contains(_gap)), reason: reason);
          expect(
            _known(h).length,
            greaterThanOrEqualTo(min(depth, sim.out.length)),
            reason: reason,
          );
          expect(h.dropped, 0, reason: reason);
          expect(h.revision, greaterThanOrEqualTo(revision), reason: reason);
          revision = h.revision;
          deepest = max(deepest, h.rows.length);
        }
      }
      expect(deepest, greaterThan(1000));
    });

    test(
      'a deep read that covers everything leaves the history to the window',
      () {
        final sim = _Sim(700);
        final h = ScrollbackHistory();
        sim.read(h, 300);
        expect(h.rows, isEmpty);
        expect(h.windowRows, 300);
        expect(h.truncated, isTrue);

        sim.read(h, 1000);
        expect(h.windowRows, 700);
        expect(h.rows, isEmpty);
        expect(h.truncated, isFalse);
        _expectTail(h, sim);

        // Back to 300 rows: the 400 older rows now sit above the window.
        sim.append(20);
        sim.read(h, 300);
        expect(h.rows, sim.out.sublist(0, 420));
        _expectTail(h, sim);
      },
    );

    test('a deep read replaces the newest history with fresher rows', () {
      final sim = _Sim(300);
      final h = ScrollbackHistory();
      sim.read(h, 300);
      for (var i = 0; i < 17; i++) {
        sim.append(100);
        sim.read(h, 300);
      }
      expect(h.rows.length, 1700);

      sim.read(h, 1000);
      expect(h.rows.length, 1000);
      expect(h.windowRows, 1000);
      _expectTail(h, sim);
      expect(_known(h).length, 2000);
    });
  });

  group('gaps', () {
    for (final (initial, depth, jump, expectGap) in <(int, int, int, bool)>[
      (1000, 300, 400, true),
      (1000, 300, 300, true),
      (1000, 300, 5000, true),
      (100, 300, 500, false),
      (1000, 300, 299, false),
    ]) {
      test('jump $jump after $initial rows read $depth deep', () {
        final sim = _Sim(initial);
        final h = ScrollbackHistory();
        sim.read(h, depth);
        final previousWindow = ScrollbackHistory.splitRows(h.window);
        final wasTruncated = h.truncated;
        sim.append(jump);
        sim.read(h, depth);

        _expectInvariants(h);
        expect(h.windowRows, depth);
        if (expectGap) {
          expect(wasTruncated, isTrue);
          expect(h.rows, [...previousWindow, _gap]);
          expect(h.contiguousRows, depth);
        } else if (jump >= depth) {
          // Previous read was the whole pane: it is replaced, not kept.
          expect(h.rows, isEmpty);
        } else {
          expect(h.rows, sim.out.sublist(initial - depth, initial - 1));
          _expectTail(h, sim);
        }
        expect(_count(h.rows, _gap), expectGap ? 1 : 0);
      });
    }

    test('repeated jumps never put two gap rows side by side', () {
      final sim = _Sim(1000);
      final h = ScrollbackHistory();
      sim.read(h, 300);
      for (var i = 0; i < 5; i++) {
        sim.append(900);
        sim.read(h, 300);
        _expectInvariants(h);
      }
      expect(_count(h.rows, _gap), 5);
      expect(h.rows.length, 5 * 301);
    });

    test('an empty window after a gap does not stack a second gap row', () {
      final h = ScrollbackHistory();
      h.update(List.generate(10, (i) => 'a$i').join('\n'), truncated: true);
      h.update(List.generate(10, (i) => 'b$i').join('\n'), truncated: true);
      h.update('', truncated: true);
      h.update(List.generate(10, (i) => 'c$i').join('\n'), truncated: true);
      _expectInvariants(h);
      expect(h.windowRows, 10);
      expect(_count(h.rows, _gap), 2);
    });

    test('a deep read that reveals all missing rows closes the gap', () {
      final sim = _Sim(1000);
      final h = ScrollbackHistory();
      sim.read(h, 300);
      sim.append(500);
      sim.read(h, 300);
      expect(h.rows, [...sim.out.sublist(700, 1000), _gap]);

      sim.read(h, 1000);
      expect(h.rows, isEmpty);
      expect(h.windowRows, 1000);
      expect(h.contiguousRows, 1000);
      _expectTail(h, sim);
    });

    test('a deep read that also reaches the old rows trims the duplicates', () {
      final sim = _Sim(1000);
      final h = ScrollbackHistory();
      sim.read(h, 300);
      sim.append(600);
      sim.read(h, 300);

      sim.read(h, 750);
      expect(h.rows, sim.out.sublist(700, 850));
      expect(h.windowRows, 750);
      expect(h.contiguousRows, 900);
      _expectTail(h, sim);
      _expectInvariants(h);
    });

    test('a deep read that does not reach the old rows keeps the gap', () {
      final sim = _Sim(1000);
      final h = ScrollbackHistory();
      sim.read(h, 300);
      sim.append(1200);
      sim.read(h, 300);
      expect(h.contiguousRows, 300);

      sim.read(h, 1000);
      expect(h.rows, [...sim.out.sublist(700, 1000), _gap]);
      expect(h.windowRows, 1000);
      expect(h.contiguousRows, 1000);

      sim.append(10);
      sim.read(h, 300);
      expect(h.rows, [
        ...sim.out.sublist(700, 1000),
        _gap,
        ...sim.out.sublist(1200, sim.out.length - 300),
      ]);
      expect(h.contiguousRows, sim.out.length - 1200);
      _expectInvariants(h);
    });
  });

  group('full-screen redraws', () {
    test('never accumulate history', () {
      final screens = [
        for (var k = 0; k < 40; k++)
          List.generate(24, (j) => 'screen $k line $j\r').join('\n'),
      ];
      final h = ScrollbackHistory();
      for (var i = 0; i < 400; i++) {
        h.update(screens[i % screens.length], truncated: false);
        expect(h.rows, isEmpty);
        expect(h.contiguousRows, 24);
        expect(h.windowRows, 24);
      }
    });

    test('in-place edits of a screen stay one screen', () {
      final h = ScrollbackHistory();
      for (var i = 0; i < 100; i++) {
        final rows = List.generate(
          24,
          (j) => j == 23 ? 'status $i\r' : 'line $j\r',
        );
        h.update(rows.join('\n'), truncated: false);
        expect(h.rows, isEmpty);
      }
    });
  });

  group('caps', () {
    test('maxRows keeps the newest rows before the window', () {
      final sim = _Sim(100);
      final h = ScrollbackHistory(maxRows: 50);
      sim.read(h, 300);
      for (var i = 0; i < 200; i++) {
        sim.append(5);
        sim.read(h, 300);
        expect(h.rows.length, lessThanOrEqualTo(50));
        expect(
          h.dropped,
          sim.out.length - h.windowRows - h.rows.length,
          reason: 'step $i',
        );
        _expectTail(h, sim, reason: 'step $i');
        _expectInvariants(h, reason: 'step $i');
      }
      expect(h.rows.length, 50);
      expect(h.dropped, 1000 + 100 - 300 - 50);
    });

    test('maxBytes keeps the newest rows that fit', () {
      const maxBytes = 1000;
      final sim = _Sim(100, rowOf: (i) => '${'x' * 90}$i\r');
      final h = ScrollbackHistory(maxBytes: maxBytes);
      sim.read(h, 300);
      for (var i = 0; i < 100; i++) {
        sim.append(7);
        sim.read(h, 300);
        final bytes = h.rows.fold<int>(0, (sum, r) => sum + r.length);
        expect(bytes, lessThanOrEqualTo(maxBytes));
        final oldest = sim.out.length - h.windowRows - h.rows.length - 1;
        if (oldest >= 0) {
          expect(bytes + sim.out[oldest].length, greaterThan(maxBytes));
        }
        expect(
          h.dropped,
          sim.out.length - h.windowRows - h.rows.length,
          reason: 'step $i',
        );
        _expectTail(h, sim, reason: 'step $i');
      }
      expect(h.rows, isNotEmpty);
    });

    test(
      'a gap row is never left at the top and is not counted as dropped',
      () {
        final sim = _Sim(1000);
        final h = ScrollbackHistory(maxRows: 1);
        sim.read(h, 300);
        sim.append(400);
        sim.read(h, 300);
        // History would be [... 300 rows, gap]; capped to one row that is the
        // gap, which describes nothing above it.
        expect(h.rows, isEmpty);
        expect(h.dropped, 300);
        expect(h.contiguousRows, h.windowRows);
      },
    );

    test('contiguousRows follows the gap out of the history', () {
      final sim = _Sim(1000);
      final h = ScrollbackHistory(maxRows: 50);
      sim.read(h, 300);
      sim.append(400);
      sim.read(h, 300);
      expect(h.rows.length, 50);
      expect(h.rows.last, _gap);
      expect(h.contiguousRows, 300);

      var gapGone = false;
      for (var i = 0; i < 20; i++) {
        sim.append(10);
        sim.read(h, 300);
        _expectInvariants(h, reason: 'step $i');
        gapGone = gapGone || !h.rows.contains(_gap);
        if (!h.rows.contains(_gap)) {
          expect(h.contiguousRows, h.rows.length + h.windowRows);
        }
      }
      expect(gapGone, isTrue);
    });
  });

  group('ambiguous rows', () {
    test(
      'a pane of identical blank rows is a no-op until something differs',
      () {
        final blank = List.filled(300, '\r').join('\n');
        final h = ScrollbackHistory();
        h.update(blank, truncated: true);
        final revision = h.revision;
        h.update(blank, truncated: true);
        expect(h.revision, revision);
        expect(h.rows, isEmpty);

        // Output scrolled by 11 rows but only the marker is distinguishable:
        // the least-scrolling reading wins, so no duplicates and no gap.
        final marked = [...List.filled(299, '\r'), 'marker\r'].join('\n');
        h.update(marked, truncated: true);
        expect(h.rows, isNot(contains(_gap)));
        expect(h.rows, isEmpty);
        expect(h.windowRows, 300);
      },
    );

    test('blank rows alone never close a short overlap', () {
      final h = ScrollbackHistory();
      h.update('a\r\n\r\n\r', truncated: true);
      h.update('\r\n\r\nz', truncated: true);
      expect(h.rows, contains(_gap));
    });
  });

  group('API behaviour', () {
    test('an identical read is a no-op', () {
      final sim = _Sim(500);
      final h = ScrollbackHistory();
      sim.read(h, 300);
      sim.append(40);
      sim.read(h, 300);
      final snapshot = h.rows;
      final revision = h.revision;
      sim.read(h, 300);
      expect(h.revision, revision);
      expect(identical(h.rows, snapshot), isTrue);
    });

    test('only a changed truncated flag bumps the revision', () {
      final h = ScrollbackHistory();
      h.update('a\nb', truncated: false);
      final snapshot = h.rows;
      final revision = h.revision;
      h.update('a\nb', truncated: true);
      expect(h.truncated, isTrue);
      expect(h.revision, revision + 1);
      expect(identical(h.rows, snapshot), isTrue);
    });

    test('rows is the same immutable instance until the history changes', () {
      final sim = _Sim(500);
      final h = ScrollbackHistory();
      sim.read(h, 300);
      sim.append(10);
      sim.read(h, 300);
      final snapshot = h.rows;
      expect(() => snapshot.add('x'), throwsUnsupportedError);

      sim.rewriteTail(2);
      sim.read(h, 300);
      expect(identical(h.rows, snapshot), isTrue);

      sim.append(10);
      sim.read(h, 300);
      expect(identical(h.rows, snapshot), isFalse);
      expect(h.rows.length, 20);
    });

    test('clear forgets everything', () {
      final sim = _Sim(1000);
      final h = ScrollbackHistory(maxRows: 30);
      sim.read(h, 300);
      sim.append(500);
      sim.read(h, 300);
      final revision = h.revision;
      expect(h.dropped, greaterThan(0));

      h.clear();
      expect(h.rows, isEmpty);
      expect(h.window, '');
      expect(h.windowRows, 0);
      expect(h.truncated, isFalse);
      expect(h.dropped, 0);
      expect(h.contiguousRows, 0);
      expect(h.revision, greaterThan(revision));

      // The next read is a first read again, never merged with old rows.
      h.update('x\ny', truncated: false);
      expect(h.rows, isEmpty);
      expect(h.windowRows, 2);
    });

    test('empty text', () {
      final h = ScrollbackHistory();
      h.update('', truncated: false);
      expect(h.windowRows, 0);
      expect(h.rows, isEmpty);
      expect(h.contiguousRows, 0);

      h.update('a\r\nb\r', truncated: false);
      h.update('', truncated: false);
      expect(h.windowRows, 0);
      expect(h.rows, isEmpty);

      h.update('a\r\nb\r', truncated: true);
      h.update('', truncated: true);
      expect(h.windowRows, 0);
      _expectInvariants(h);
    });

    test('a text that is only a newline is one blank row', () {
      final h = ScrollbackHistory();
      h.update('\n', truncated: false);
      expect(h.window, '\n');
      expect(h.windowRows, 1);
      expect(h.rows, isEmpty);
    });

    test('first read with one row', () {
      final h = ScrollbackHistory();
      h.update('only\r', truncated: false);
      expect(h.windowRows, 1);
      expect(h.rows, isEmpty);
      expect(h.contiguousRows, 1);
      expect(h.window, 'only\r');
    });

    test('a trailing newline does not change the rows', () {
      final h = ScrollbackHistory();
      h.update('a\nb\nc\nd\n', truncated: false);
      final revision = h.revision;
      h.update('a\nb\nc\nd', truncated: false);
      expect(h.windowRows, 4);
      expect(h.rows, isEmpty);
      expect(h.window, 'a\nb\nc\nd');
      expect(h.revision, greaterThan(revision));
    });

    test('rows deleted at the bottom keep the window aligned', () {
      // Whole pane shrinks.
      var sim = _Sim(200);
      var h = ScrollbackHistory();
      sim.read(h, 300);
      sim.out.removeRange(190, 200);
      sim.read(h, 300);
      expect(h.rows, isEmpty);
      expect(h.windowRows, 190);
      _expectTail(h, sim);

      // Window with scrollback above it.
      sim = _Sim(300);
      h = ScrollbackHistory();
      sim.read(h, 300);
      sim.append(100);
      sim.read(h, 300);
      sim.out.removeRange(390, 400);
      sim.read(h, 300);
      expect(h.rows, sim.out.sublist(0, 90));
      _expectTail(h, sim);
    });

    test('window, truncated and revision reflect the latest read', () {
      final h = ScrollbackHistory();
      expect(h.revision, 0);
      h.update('a\nb', truncated: true);
      expect(h.window, 'a\nb');
      expect(h.truncated, isTrue);
      expect(h.revision, 1);
      h.update('a\nb\nc', truncated: false);
      expect(h.window, 'a\nb\nc');
      expect(h.truncated, isFalse);
      expect(h.revision, 2);
    });
  });

  group('performance', () {
    test('updates do not copy the whole history', () {
      final sim = _Sim(1000);
      final h = ScrollbackHistory();
      sim.read(h, 1000);
      while (h.rows.length < 20000) {
        sim.append(500);
        sim.read(h, 1000);
      }
      expect(h.rows.length, 20000);

      var rowCount = 0;
      final watch = Stopwatch();
      for (var i = 0; i < 200; i++) {
        sim.rewriteTail(2);
        sim.append(5);
        final text = sim.text(1000);
        watch.start();
        h.update(text, truncated: true);
        // The snapshot is the only O(history) step, and only when read.
        rowCount = h.rows.length;
        watch.stop();
      }
      expect(watch.elapsedMilliseconds, lessThan(1500));
      expect(rowCount, 20000);
      expect(h.dropped, greaterThan(0));
      _expectTail(h, sim);
    });
  });
}
