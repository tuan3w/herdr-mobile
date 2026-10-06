import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/ansi.dart';
import 'package:herdr_mobile/ui/core/cell_width.dart';
import 'package:herdr_mobile/ui/core/line_wrap.dart';

const _red = Color(0xFFE06C75);
const _blue = Color(0xFF204060);

/// The text of each row.
List<String> _texts(List<List<AnsiRun>> rows) =>
    [for (final row in rows) row.map((r) => r.text).join()];

/// Cells in each row.
List<int> _widths(List<List<AnsiRun>> rows) =>
    [for (final row in rows) row.fold(0, (n, r) => n + columnsOf(r.text))];

List<List<AnsiRun>> _wrap(String ansi, int columns) =>
    wrapLine(parseAnsi(ansi).lines.single, columns);

void main() {
  group('plain text', () {
    test('a line shorter than the width is one row, the very same runs', () {
      final runs = parseAnsi('short').lines.single;
      final rows = wrapLine(runs, 10);
      expect(rows, hasLength(1));
      expect(rows.single, same(runs));
    });

    test('a line exactly as wide as the width is one row', () {
      final runs = parseAnsi('abcdefghij').lines.single;
      final rows = wrapLine(runs, 10);
      expect(rows, hasLength(1));
      expect(rows.single, same(runs));
    });

    test('an empty line is one empty row', () {
      final rows = wrapLine(const [], 10);
      expect(rows, hasLength(1));
      expect(rows.single, isEmpty);
    });

    test('a line one cell too wide breaks into a full row and one cell', () {
      final rows = _wrap('abcdefghijk', 10);
      expect(_texts(rows), ['abcdefghij', 'k']);
    });

    test('rows are exactly the width until the last', () {
      final rows = _wrap('abcdefghijklmnopqrstuvwxy', 7);
      expect(_texts(rows), ['abcdefg', 'hijklmn', 'opqrstu', 'vwxy']);
      expect(_widths(rows), [7, 7, 7, 4]);
    });

    test('a multiple of the width leaves no empty row at the end', () {
      final rows = _wrap('abcdefgh', 4);
      expect(_texts(rows), ['abcd', 'efgh']);
    });

    test('width 1 puts every character on its own row', () {
      final rows = _wrap('abc', 1);
      expect(_texts(rows), ['a', 'b', 'c']);
      expect(_widths(rows), [1, 1, 1]);
    });

    test('width 1 on a line of one character is that line', () {
      final rows = _wrap('x', 1);
      expect(_texts(rows), ['x']);
    });

    test('spaces are kept, also at the break', () {
      expect(_texts(_wrap('ab cd ef', 3)), ['ab ', 'cd ', 'ef']);
    });
  });

  group('styles', () {
    test('a run cut by the break keeps its style on both rows', () {
      final rows = _wrap('\x1b[1;31;44;4mabcdefgh\x1b[0m', 5);
      expect(_texts(rows), ['abcde', 'fgh']);
      for (final row in rows) {
        final run = row.single;
        expect(run.fg, _red);
        expect(run.bg, isNotNull);
        expect(run.bold, isTrue);
        expect(run.underline, isTrue);
      }
    });

    test('runs after the cut keep theirs, and rows hold several runs', () {
      final rows = _wrap('\x1b[31mabcd\x1b[0mef\x1b[44mgh\x1b[0mij', 5);
      expect(_texts(rows), ['abcde', 'fghij']);
      expect(rows[0].map((r) => (r.text, r.fg)), [('abcd', _red), ('e', null)]);
      expect(rows[1].map((r) => r.text), ['f', 'gh', 'ij']);
      expect(rows[1].map((r) => r.bg != null), [false, true, false]);
    });

    test('a break exactly between two runs cuts nothing', () {
      final rows = _wrap('\x1b[31mabcd\x1b[0mefgh', 4);
      expect(_texts(rows), ['abcd', 'efgh']);
      expect(rows[0].single.fg, _red);
      expect(rows[1].single.fg, isNull);
      expect(rows[0], hasLength(1));
      expect(rows[1], hasLength(1));
    });

    test('a run that fits a row is passed through untouched', () {
      final runs = parseAnsi('\x1b[31mab\x1b[0m\x1b[44mcd\x1b[0mefghij').lines.single;
      final rows = wrapLine(runs, 6);
      expect(rows[0][0], same(runs[0]));
      expect(rows[0][1], same(runs[1]));
    });

    test('every attribute survives a split', () {
      const run = AnsiRun(
        'abcdef',
        fg: _red,
        bg: _blue,
        bold: true,
        dim: true,
        italic: true,
        underline: true,
        strike: true,
      );
      final rows = wrapLine(const [run], 4);
      expect(_texts(rows), ['abcd', 'ef']);
      for (final row in rows) {
        final r = row.single;
        expect((r.fg, r.bg, r.bold, r.dim, r.italic, r.underline, r.strike),
            (_red, _blue, true, true, true, true, true));
      }
    });
  });

  group('wide characters', () {
    test('are never split, so the row is a cell short', () {
      final rows = _wrap('abc日def', 4);
      expect(_texts(rows), ['abc', '日de', 'f']);
      expect(_widths(rows), [3, 4, 1]);
    });

    test('one that fits exactly stays', () {
      final rows = _wrap('ab日cd', 4);
      expect(_texts(rows), ['ab日', 'cd']);
      expect(_widths(rows), [4, 2]);
    });

    test('at the very start of a row sits there', () {
      final rows = _wrap('日本語', 4);
      expect(_texts(rows), ['日本', '語']);
    });

    test('with width 1 sit alone, wider than the row', () {
      final rows = _wrap('a日b', 1);
      expect(_texts(rows), ['a', '日', 'b']);
    });

    test('with width 2 fill a row each', () {
      final rows = _wrap('日本語', 2);
      expect(_texts(rows), ['日', '本', '語']);
    });

    test('an emoji (a surrogate pair) is not cut in half', () {
      final rows = _wrap('🚀🚀🚀', 5);
      expect(_texts(rows), ['🚀🚀', '🚀']);
      expect(_widths(rows), [4, 2]);
    });

    test('a wide character carries its run style to the next row', () {
      final rows = _wrap('\x1b[31mabc日def\x1b[0m', 4);
      expect(_texts(rows), ['abc', '日de', 'f']);
      for (final row in rows) {
        expect(row.single.fg, _red);
      }
    });

    test('a wide character that starts a new run at the break moves whole', () {
      final rows = _wrap('abc\x1b[31m日\x1b[0mx', 4);
      expect(_texts(rows), ['abc', '日x']);
      expect(rows[1][0].fg, _red);
      expect(rows[1][1].fg, isNull);
    });
  });

  group('zero-width characters', () {
    test('a combining mark stays with its base across the break', () {
      final rows = _wrap('abcd\u0301e', 4);
      expect(_texts(rows), ['abcd\u0301', 'e']);
    });

    test('they never use up a cell', () {
      final rows = _wrap('a\u0301b\u0301c\u0301d\u0301', 4);
      expect(rows, hasLength(1));
    });
  });

  group('properties', () {
    // Deterministic pseudo-random mixed text.
    const alphabet = ['a', 'b', ' ', '日', '本', '🚀', 'é', '\u0301', '─', 'z'];

    test('no character is lost, reordered or split; rows never overflow', () {
      var seed = 12345;
      int next(int n) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        return seed % n;
      }

      for (var round = 0; round < 400; round++) {
        final length = next(40);
        final text = StringBuffer();
        for (var i = 0; i < length; i++) {
          text.write(alphabet[next(alphabet.length)]);
        }
        final columns = 1 + next(12);
        final runs = [
          if (text.isNotEmpty) AnsiRun(text.toString(), fg: _red),
        ];
        final rows = wrapLine(runs, columns);

        expect(_texts(rows).join(), text.toString(), reason: '$text @ $columns');
        expect(rows, isNotEmpty);
        for (var r = 0; r < rows.length; r++) {
          final width = _widths(rows)[r];
          final chars = _texts(rows)[r].runes.where((c) => cellWidth(c) > 0);
          // Only a lone wide character may be wider than the row.
          expect(width <= columns || chars.length == 1, isTrue,
              reason: 'row $r of "$text" @ $columns is $width wide');
          if (r < rows.length - 1 && columns >= 2) {
            // Full, or one short because a wide character did not fit.
            expect(width, anyOf(columns, columns - 1),
                reason: 'row $r of "$text" @ $columns');
          }
          for (final run in rows[r]) {
            expect(run.fg, _red);
            expect(run.text, isNotEmpty);
          }
        }
      }
    });
  });
}
