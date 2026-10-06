import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/box_drawing.dart';
import 'package:herdr_mobile/ui/core/cell_width.dart';

/// Cell sizes in device pixels: (width, height), as seen on phones.
const _sizes = [(8, 14), (12, 20), (18, 39), (30, 51), (31, 52), (45, 70)];

GlyphShape _glyph(String ch, int w, int h, {int x0 = 0, int y0 = 0}) =>
    boxGlyph(
      ch.runes.single,
      x0: x0,
      x1: x0 + w,
      y0: y0,
      y1: y0 + h,
      light: lightStroke(w.toDouble()),
    )!;

/// The filled pixels of [shape]'s rectangles in a [w]x[h] cell at the origin.
List<List<bool>> _raster(GlyphShape shape, int w, int h) {
  final grid = List.generate(h, (_) => List.filled(w, false));
  for (final r in shape.rects) {
    for (var y = r.top.toInt(); y < r.bottom.toInt(); y++) {
      for (var x = r.left.toInt(); x < r.right.toInt(); x++) {
        grid[y][x] = true;
      }
    }
  }
  return grid;
}

void main() {
  group('lightStroke', () {
    test('is an eighth of the cell, at least one pixel', () {
      expect(lightStroke(4), 1);
      expect(lightStroke(12), 2);
      expect(lightStroke(18), 2);
      expect(lightStroke(30.19), 4);
      expect(lightStroke(45), 6);
    });
  });

  group('every character of U+2500-259F has a shape', () {
    for (final (w, h) in _sizes) {
      test('in a ${w}x$h cell', () {
        for (var r = 0x2500; r <= 0x259f; r++) {
          final shape = boxGlyph(r,
              x0: 100, x1: 100 + w, y0: 200, y1: 200 + h, light: lightStroke(w.toDouble()));
          final name = r.toRadixString(16);
          expect(shape, isNotNull, reason: name);
          expect(shape!.rects.length + shape.strokes.length, greaterThan(0),
              reason: name);
          for (final rect in shape.rects) {
            expect(rect.left, rect.left.roundToDouble(), reason: name);
            expect(rect.top, rect.top.roundToDouble(), reason: name);
            expect(rect.right, rect.right.roundToDouble(), reason: name);
            expect(rect.bottom, rect.bottom.roundToDouble(), reason: name);
            expect(rect.width, greaterThan(0), reason: name);
            expect(rect.height, greaterThan(0), reason: name);
            expect(rect.left, greaterThanOrEqualTo(100), reason: name);
            expect(rect.right, lessThanOrEqualTo(100.0 + w), reason: name);
            expect(rect.top, greaterThanOrEqualTo(200), reason: name);
            expect(rect.bottom, lessThanOrEqualTo(200.0 + h), reason: name);
          }
        }
      });
    }

    test('and nothing else does', () {
      expect(isBoxGlyph(0x24ff), isFalse);
      expect(isBoxGlyph(0x25a0), isFalse);
      expect(isBoxGlyph(0x41), isFalse);
      expect(
          boxGlyph(0x41, x0: 0, x1: 10, y0: 0, y1: 20, light: 1), isNull);
    });
  });

  group('straight lines', () {
    for (final (w, h) in _sizes) {
      test('light lines span the cell, centred, in a ${w}x$h cell', () {
        final t = lightStroke(w.toDouble());
        final horizontal = _glyph('─', w, h);
        expect(horizontal.rects, hasLength(1));
        final rect = horizontal.rects.single;
        expect(rect.left, 0);
        expect(rect.right, w);
        expect(rect.height, t);
        expect(rect.top, (h - t) ~/ 2);

        final vertical = _glyph('│', w, h);
        expect(vertical.rects, hasLength(1));
        expect(vertical.rects.single.top, 0);
        expect(vertical.rects.single.bottom, h);
        expect(vertical.rects.single.width, t);
        expect(vertical.rects.single.left, (w - t) ~/ 2);
      });

      test('heavy is twice as thick, double is two strokes with a gap, in a '
          '${w}x$h cell', () {
        final t = lightStroke(w.toDouble());
        expect(_glyph('━', w, h).rects.single.height, 2 * t);
        expect(_glyph('┃', w, h).rects.single.width, 2 * t);

        final bands = _glyph('═', w, h).rects;
        expect(bands, hasLength(2));
        expect(bands[0].height, t);
        expect(bands[1].height, t);
        expect(bands[1].top - bands[0].bottom, t);
        expect(bands[0].left, 0);
        expect(bands[0].right, w);
      });
    }

    test('are the same wherever the cell is', () {
      final a = _glyph('┼', 18, 39);
      final b = _glyph('┼', 18, 39, x0: 360, y0: 780);
      final shifted = [for (final r in a.rects) r.shift(const Offset(360, 780))];
      expect(b.rects, shifted);
    });
  });

  group('lines reach the edges they point at', () {
    // glyph: which of left, right, up, down it extends to.
    const arms = {
      '─': (true, true, false, false),
      '━': (true, true, false, false),
      '│': (false, false, true, true),
      '┃': (false, false, true, true),
      '┌': (false, true, false, true),
      '┐': (true, false, false, true),
      '└': (false, true, true, false),
      '┘': (true, false, true, false),
      '├': (false, true, true, true),
      '┤': (true, false, true, true),
      '┬': (true, true, false, true),
      '┴': (true, true, true, false),
      '┼': (true, true, true, true),
      '┏': (false, true, false, true),
      '┛': (true, false, true, false),
      '╋': (true, true, true, true),
      '┞': (false, true, true, true),
      '╄': (true, true, true, true),
      '╴': (true, false, false, false),
      '╵': (false, false, true, false),
      '╶': (false, true, false, false),
      '╷': (false, false, false, true),
      '╸': (true, false, false, false),
      '╼': (true, true, false, false),
      '╿': (false, false, true, true),
      '═': (true, true, false, false),
      '║': (false, false, true, true),
      '╒': (false, true, false, true),
      '╓': (false, true, false, true),
      '╔': (false, true, false, true),
      '╗': (true, false, false, true),
      '╚': (false, true, true, false),
      '╝': (true, false, true, false),
      '╠': (false, true, true, true),
      '╣': (true, false, true, true),
      '╦': (true, true, false, true),
      '╩': (true, true, true, false),
      '╬': (true, true, true, true),
      '╪': (true, true, true, true),
      '╫': (true, true, true, true),
    };
    for (final MapEntry(key: ch, value: (l, r, u, d)) in arms.entries) {
      test(ch, () {
        const w = 30, h = 51;
        final grid = _raster(_glyph(ch, w, h), w, h);
        bool anyColumn(int x) => grid.any((row) => row[x]);
        bool anyRow(int y) => grid[y].any((v) => v);
        expect(anyColumn(0), l, reason: '$ch left');
        expect(anyColumn(w - 1), r, reason: '$ch right');
        expect(anyRow(0), u, reason: '$ch up');
        expect(anyRow(h - 1), d, reason: '$ch down');
      });
    }

    test('a corner is solid where its lines meet', () {
      const w = 30, h = 51;
      final t = lightStroke(w.toDouble());
      final grid = _raster(_glyph('┌', w, h), w, h);
      final x = (w - t) ~/ 2, y = (h - t) ~/ 2;
      for (var dy = 0; dy < t; dy++) {
        for (var dx = 0; dx < t; dx++) {
          expect(grid[y + dy][x + dx], isTrue);
        }
      }
      // The outside of the corner stays empty.
      expect(grid[y][x - 1], isFalse);
      expect(grid[y - 1][x], isFalse);
    });

    test('double corners join their outer lines and stop the inner ones', () {
      const w = 30, h = 51;
      final t = lightStroke(w.toDouble());
      final grid = _raster(_glyph('╔', w, h), w, h);
      final x = (w - 3 * t) ~/ 2, y = (h - 3 * t) ~/ 2;
      // Outer corner is solid.
      expect(grid[y][x], isTrue);
      // The inner corner joins too: the inner vertical stroke starts at the
      // inner horizontal one, so there is no gap above it.
      expect(grid[y + 2 * t][x + 2 * t], isTrue);
      expect(grid[y + 2 * t - 1][x + 2 * t], isFalse,
          reason: 'inner vertical does not poke into the gap');
      // The centre of the glyph is the gap between both pairs of strokes.
      expect(grid[y + t][x + t], isFalse);
    });
  });

  group('dashes', () {
    for (final ch in ['┄', '┈', '╌']) {
      for (final (w, h) in _sizes) {
        test('$ch tile with equal gaps across cells in a ${w}x$h cell', () {
          final a = _glyph(ch, w, h).rects;
          final b = _glyph(ch, w, h, x0: w).rects;
          final all = [...a, ...b]..sort((p, q) => p.left.compareTo(q.left));
          final gaps = [
            for (var i = 1; i < all.length; i++) all[i].left - all[i - 1].right,
          ];
          expect(gaps.every((g) => g >= 1), isTrue, reason: '$gaps');
          expect(gaps.reduce((p, q) => p > q ? p : q) -
              gaps.reduce((p, q) => p < q ? p : q), lessThanOrEqualTo(1),
              reason: '$gaps');
          // The whole cell edge is a gap, so the pattern repeats.
          expect(a.first.left, greaterThanOrEqualTo(0));
          expect(a.last.right, lessThanOrEqualTo(w));
        });
      }
    }

    test('count per cell', () {
      expect(_glyph('┄', 30, 51).rects, hasLength(3));
      expect(_glyph('┈', 30, 51).rects, hasLength(4));
      expect(_glyph('╌', 30, 51).rects, hasLength(2));
      expect(_glyph('┆', 30, 51).rects, hasLength(3));
      expect(_glyph('╏', 30, 51).rects, hasLength(2));
    });
  });

  group('block elements', () {
    double fraction(String ch, int w, int h) {
      final grid = _raster(_glyph(ch, w, h), w, h);
      final lit = grid.fold<int>(0, (n, row) => n + row.where((v) => v).length);
      return lit / (w * h);
    }

    test('fill their share of the cell', () {
      for (final (w, h) in _sizes) {
        expect(fraction('█', w, h), 1);
        expect(fraction('▀', w, h), closeTo(0.5, 1 / h));
        expect(fraction('▄', w, h), closeTo(0.5, 1 / h));
        expect(fraction('▌', w, h), closeTo(0.5, 1 / w));
        expect(fraction('▐', w, h), closeTo(0.5, 1 / w));
        expect(fraction('▁', w, h), closeTo(1 / 8, 1 / h));
        expect(fraction('▏', w, h), closeTo(1 / 8, 1 / w));
        expect(fraction('▛', w, h), closeTo(0.75, 2 / w + 2 / h));
        expect(fraction('▚', w, h), closeTo(0.5, 2 / w + 2 / h));
      }
    });

    test('halves tile the cell without overlap or gap', () {
      for (final (w, h) in _sizes) {
        final top = _raster(_glyph('▀', w, h), w, h);
        final bottom = _raster(_glyph('▄', w, h), w, h);
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            expect(top[y][x] != bottom[y][x], isTrue, reason: '$x,$y in ${w}x$h');
          }
        }
      }
    });

    test('shades are the foreground at a quarter, half and three quarters', () {
      expect(_glyph('░', 30, 51).alpha, 0.25);
      expect(_glyph('▒', 30, 51).alpha, 0.5);
      expect(_glyph('▓', 30, 51).alpha, 0.75);
      expect(_glyph('░', 30, 51).rects.single, const Rect.fromLTWH(0, 0, 30, 51));
      expect(_glyph('█', 30, 51).alpha, 1);
    });
  });

  group('curves', () {
    test('arcs and diagonals are strokes of the light width', () {
      for (final ch in ['╭', '╮', '╯', '╰']) {
        final shape = _glyph(ch, 30, 51);
        expect(shape.strokes, hasLength(1), reason: ch);
        expect(shape.strokes.single.width, lightStroke(30));
        expect(shape.rects, isEmpty);
      }
      expect(_glyph('╱', 30, 51).strokes, hasLength(1));
      expect(_glyph('╲', 30, 51).strokes, hasLength(1));
      expect(_glyph('╳', 30, 51).strokes, hasLength(2));
      expect(_glyph('╱', 30, 51).strokes.single.clip,
          const Rect.fromLTWH(0, 0, 30, 51));
    });
  });

  group('cellWidth', () {
    test('ASCII, Latin and box drawing are one cell', () {
      expect(columnsOf('hello'), 5);
      expect(columnsOf('é'), 1);
      expect(columnsOf('┌─┐│█'), 5);
      expect(columnsOf('→✓●'), 3);
    });

    test('CJK, fullwidth and emoji are two cells', () {
      expect(columnsOf('日本語'), 6);
      expect(columnsOf('한글'), 4);
      expect(columnsOf('ＡＢ'), 4);
      expect(columnsOf('🚀'), 2);
      expect(columnsOf('😀'), 2);
      expect(columnsOf('🦀'), 2);
      expect(columnsOf('⚡'), 2);
      expect(cellWidth(0x3000), 2);
    });

    test('combining and zero-width characters take no cell', () {
      expect(columnsOf('e\u0301'), 1);
      expect(columnsOf('a\u200bb'), 2);
      expect(columnsOf('👨\u200d👩'), 4);
      expect(columnsOf('\u{fe0f}'), 0);
      expect(columnsOf('\u20d0'), 0);
      expect(columnsOf('े'), 0);
    });

    test('ranges are found at their ends', () {
      expect(cellWidth(0x1100), 2);
      expect(cellWidth(0x115f), 2);
      expect(cellWidth(0x1160), 1);
      expect(cellWidth(0x20000), 2);
      expect(cellWidth(0x300), 0);
      expect(cellWidth(0x36f), 0);
      expect(cellWidth(0x370), 1);
    });
  });
}
