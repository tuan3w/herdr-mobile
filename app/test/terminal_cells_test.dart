import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/ui/core/ansi.dart';
import 'package:herdr_mobile/ui/core/terminal_cells.dart';
import 'package:herdr_mobile/ui/core/terminal_view.dart';
import 'package:herdr_mobile/ui/core/theme.dart';

/// Pixel densities of real phones (a Galaxy A51 is 2.625) and the test default.
const _densities = [1.0, 1.5, 2.0, 2.625, 3.0, 3.5];

const _light = Color(0xFFE8DFC8);
const _fg = Color(0xFF55D0C0);
final _bg = TerminalColors.background;

/// A rendered image whose pixels can be read back.
class _Pixels {
  _Pixels(this.width, this.height, this._data);

  final int width;
  final int height;
  final ByteData _data;

  Color at(int x, int y) {
    expect(x, inInclusiveRange(0, width - 1));
    expect(y, inInclusiveRange(0, height - 1));
    final i = (y * width + x) * 4;
    return Color.fromARGB(
      _data.getUint8(i + 3),
      _data.getUint8(i),
      _data.getUint8(i + 1),
      _data.getUint8(i + 2),
    );
  }

  bool isColor(int x, int y, Color color) => at(x, y) == color;

  /// Pixels in the box that are exactly [color].
  int count(Color color, {int x0 = 0, int y0 = 0, int? x1, int? y1}) {
    var n = 0;
    for (var y = y0; y < (y1 ?? height); y++) {
      for (var x = x0; x < (x1 ?? width); x++) {
        if (at(x, y) == color) n++;
      }
    }
    return n;
  }

  /// Every pixel of the box that is not [color], as `x,y`.
  List<String> notColor(Color color,
      {int x0 = 0, int y0 = 0, int? x1, int? y1}) {
    final out = <String>[];
    for (var y = y0; y < (y1 ?? height); y++) {
      for (var x = x0; x < (x1 ?? width); x++) {
        if (at(x, y) != color) out.add('$x,$y');
      }
    }
    return out;
  }
}

/// Renders [rows] (one ANSI string per terminal row) stacked in a column on a
/// [surface] background at [dpr], and reads the pixels back.
Future<({_Pixels pixels, CellMetrics metrics})> _render(
  WidgetTester tester,
  List<String> rows, {
  required double dpr,
  Color? surface,
  int columns = 8,
}) async {
  tester.view
    ..devicePixelRatio = dpr
    ..physicalSize = const Size(600, 400) * dpr;
  addTearDown(tester.view.reset);
  final metrics = CellMetrics.measure(defaultTerminalFontSize, dpr);
  final parser = AnsiParser();
  final key = GlobalKey();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: key,
          child: ColoredBox(
            color: surface ?? _bg,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final row in rows)
                  SizedBox(
                    width: (metrics.columnEdge(columns)) / dpr,
                    height: metrics.lineHeight,
                    child: TerminalLineView(
                      line: TerminalLine(
                        parser.parse(row).lines.single,
                        metrics,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  final pixels = await _capture(tester, key, dpr);
  return (pixels: pixels, metrics: metrics);
}

Future<_Pixels> _capture(WidgetTester tester, GlobalKey key, double dpr) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage(pixelRatio: dpr);
    final data = await image.toByteData();
    final result = _Pixels(image.width, image.height, data!);
    image.dispose();
    return result;
  }))!;
}

String _sgrBg(Color c) =>
    '\x1b[48;2;${(c.r * 255).round()};${(c.g * 255).round()};${(c.b * 255).round()}m';
String _sgrFg(Color c) =>
    '\x1b[38;2;${(c.r * 255).round()};${(c.g * 255).round()};${(c.b * 255).round()}m';

/// A cell's box in device pixels.
({int x0, int x1, int y0, int y1}) _cell(CellMetrics m, int column, int row) => (
      x0: m.columnEdge(column),
      x1: m.columnEdge(column + 1),
      y0: row * m.rowPx,
      y1: (row + 1) * m.rowPx,
    );

void main() {
  group('backgrounds fill the whole row', () {
    for (final dpr in _densities) {
      testWidgets('no seam between stacked rows at dpr $dpr', (tester) async {
        final row = '${_sgrBg(_light)}${' ' * 6}';
        final scene = await _render(tester, [row, row, row], dpr: dpr);
        final m = scene.metrics;
        final width = m.columnEdge(6);

        expect(
          scene.pixels.notColor(_light, x1: width, y1: 3 * m.rowPx),
          isEmpty,
          reason: 'every pixel of the block, rows and boundaries included',
        );
        // The strip right of the block is the surface.
        expect(scene.pixels.isColor(width, m.rowPx, _bg), isTrue);
      });

      testWidgets('rows of different backgrounds meet exactly at dpr $dpr',
          (tester) async {
        final a = '${_sgrBg(_light)}      ';
        final b = '${_sgrBg(const Color(0xFF204060))}      ';
        final scene = await _render(tester, [a, b], dpr: dpr);
        final m = scene.metrics;

        for (var x = 0; x < m.columnEdge(6); x++) {
          expect(scene.pixels.isColor(x, m.rowPx - 1, _light), isTrue);
          expect(scene.pixels.isColor(x, m.rowPx, const Color(0xFF204060)),
              isTrue);
        }
      });

      testWidgets('adjacent runs with different backgrounds touch at dpr $dpr',
          (tester) async {
        const blue = Color(0xFF204060);
        final row = '${_sgrBg(_light)}   ${_sgrBg(blue)}   ';
        final scene = await _render(tester, [row], dpr: dpr);
        final m = scene.metrics;
        final edge = m.columnEdge(3);

        expect(scene.pixels.notColor(_light, x1: edge, y1: m.rowPx), isEmpty);
        expect(
          scene.pixels.notColor(blue, x0: edge, x1: m.columnEdge(6), y1: m.rowPx),
          isEmpty,
        );
      });
    }

    testWidgets('control: TextSpan.backgroundColor leaves the seam the cell '
        'painter removes', (tester) async {
      const dpr = 2.625;
      tester.view
        ..devicePixelRatio = dpr
        ..physicalSize = const Size(600, 400) * dpr;
      addTearDown(tester.view.reset);
      final metrics = CellMetrics.measure(defaultTerminalFontSize, dpr);
      final key = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: key,
              child: ColoredBox(
                color: _bg,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < 3; i++)
                      SizedBox(
                        width: 100,
                        height: metrics.lineHeight,
                        child: Text.rich(
                          TextSpan(
                            text: ' ' * 6,
                            style: TextStyle(backgroundColor: _light),
                          ),
                          style: metrics.textStyle,
                          strutStyle: metrics.strut,
                          textScaler: TextScaler.noScaling,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final pixels = await _capture(tester, key, dpr);
      expect(pixels.notColor(_light, x1: 10, y1: 3 * metrics.rowPx),
          isNotEmpty);
    });
  });

  group('box drawing meets across cells', () {
    for (final dpr in _densities) {
      testWidgets('vertical lines continue through the row boundary at dpr $dpr',
          (tester) async {
        final row = '${_sgrFg(_fg)}│';
        final scene = await _render(tester, [row, row, row], dpr: dpr);
        final m = scene.metrics;
        final p = scene.pixels;
        final c = _cell(m, 0, 0);

        // The stroke columns, read from the first row.
        final xs = [
          for (var x = c.x0; x < c.x1; x++)
            if (p.isColor(x, 2, _fg)) x,
        ];
        expect(xs, isNotEmpty);
        expect(xs.length, m.lightPx);
        // Centred in the cell, to the pixel.
        expect(xs.first - c.x0, (c.x1 - c.x0 - m.lightPx) ~/ 2);
        for (var y = 0; y < 3 * m.rowPx; y++) {
          for (final x in xs) {
            expect(p.isColor(x, y, _fg), isTrue, reason: 'pixel $x,$y');
          }
          // Nothing beside the stroke.
          expect(p.isColor(xs.first - 1, y, _bg), isTrue);
          expect(p.isColor(xs.last + 1, y, _bg), isTrue);
        }
      });

      testWidgets('horizontal lines continue through the column boundary at '
          'dpr $dpr', (tester) async {
        final scene = await _render(tester, ['${_sgrFg(_fg)}───'], dpr: dpr);
        final m = scene.metrics;
        final p = scene.pixels;

        final ys = [
          for (var y = 0; y < m.rowPx; y++)
            if (p.isColor(2, y, _fg)) y,
        ];
        expect(ys.length, m.lightPx);
        expect(ys.first, (m.rowPx - m.lightPx) ~/ 2);
        for (var x = 0; x < m.columnEdge(3); x++) {
          for (final y in ys) {
            expect(p.isColor(x, y, _fg), isTrue, reason: 'pixel $x,$y');
          }
          expect(p.isColor(x, ys.first - 1, _bg), isTrue);
          expect(p.isColor(x, ys.last + 1, _bg), isTrue);
        }
        // The rule stops at the last cell.
        expect(p.isColor(m.columnEdge(3), ys.first, _bg), isTrue);
      });

      testWidgets('corners and junctions are filled at dpr $dpr',
          (tester) async {
        final scene = await _render(
          tester,
          [
            '${_sgrFg(_fg)}┌─┐ ╭╮ ┏┓',
            '${_sgrFg(_fg)}│ │ ╰╯ ┗┛',
            '${_sgrFg(_fg)}└┼┘ ╔╗ ╬┤',
          ],
          dpr: dpr,
          columns: 12,
        );
        final m = scene.metrics;
        final p = scene.pixels;

        // Where the lines of a glyph cross: the centre pixel of its cell.
        void junction(int column, int row) {
          final c = _cell(m, column, row);
          final x = c.x0 + (c.x1 - c.x0 - 1) ~/ 2;
          final y = c.y0 + (c.y1 - c.y0 - 1) ~/ 2;
          expect(p.isColor(x, y, _fg), isTrue,
              reason: 'junction of column $column row $row ($x,$y)');
        }

        junction(0, 0); // ┌
        junction(2, 0); // ┐
        junction(0, 2); // └
        junction(1, 2); // ┼
        junction(2, 2); // ┘
        junction(8, 2); // ┤
        junction(7, 0); // ┏
        junction(8, 0); // ┓
        junction(7, 1); // ┗
        junction(8, 1); // ┛

        // The arms of ┌ reach the right and bottom edges of the cell.
        final tl = _cell(m, 0, 0);
        final cy = tl.y0 + (tl.y1 - tl.y0 - 1) ~/ 2;
        expect(p.isColor(tl.x1 - 1, cy, _fg), isTrue);
        final cx = tl.x0 + (tl.x1 - tl.x0 - 1) ~/ 2;
        expect(p.isColor(cx, tl.y1 - 1, _fg), isTrue);
        // ...and not past the corner.
        expect(p.isColor(tl.x0, cy, _bg), isTrue);
        expect(p.isColor(cx, tl.y0, _bg), isTrue);

        // ┼ is a plus: all four arms reach the cell edges.
        final cross = _cell(m, 1, 2);
        final px = cross.x0 + (cross.x1 - cross.x0 - 1) ~/ 2;
        final py = cross.y0 + (cross.y1 - cross.y0 - 1) ~/ 2;
        expect(p.isColor(cross.x0, py, _fg), isTrue);
        expect(p.isColor(cross.x1 - 1, py, _fg), isTrue);
        expect(p.isColor(px, cross.y0, _fg), isTrue);
        expect(p.isColor(px, cross.y1 - 1, _fg), isTrue);
        expect(p.isColor(cross.x0, cross.y0, _bg), isTrue);

        // An arc ends on the middle of the cell edge, where ─ and │ do.
        final arc = _cell(m, 4, 0); // ╭
        final arcY = arc.y0 + (arc.y1 - arc.y0 - 1) ~/ 2;
        final arcX = arc.x0 + (arc.x1 - arc.x0 - 1) ~/ 2;
        bool mostlyFg(int x, int y) {
          final c = p.at(x, y);
          return c.g > (_fg.g + _bg.g) / 2;
        }

        expect(mostlyFg(arc.x1 - 1, arcY), isTrue);
        expect(mostlyFg(arcX, arc.y1 - 1), isTrue);
        // ...and bends away from the corner of the cell.
        expect(p.at(arc.x0, arc.y0), _bg);
      });
    }

    testWidgets('dashes keep their rhythm across cells', (tester) async {
      final scene =
          await _render(tester, ['${_sgrFg(_fg)}┄┄┄┄'], dpr: 2.625, columns: 4);
      final m = scene.metrics;
      final p = scene.pixels;
      final y = m.rowPx ~/ 2;

      // Alternating gap/dash lengths along the line, from the first pixel.
      final segments = <(bool, int)>[];
      var run = 0;
      var lit = false;
      for (var x = 0; x < m.columnEdge(4); x++) {
        final on = p.isColor(x, y, _fg);
        if (on != lit) {
          segments.add((lit, run));
          run = 0;
          lit = on;
        }
        run++;
      }
      segments.add((lit, run));
      // Three dashes per cell, four cells.
      expect(segments.where((s) => s.$1), hasLength(12));
      // Every gap between two dashes is alike, including those that fall on a
      // cell boundary.
      final gaps = [
        for (final (lit, length) in segments.skip(1).take(segments.length - 2))
          if (!lit) length,
      ];
      expect(gaps.toSet(), hasLength(1), reason: 'gaps $gaps');
      // The dashes are alike too, to the pixel.
      final dashes = [
        for (final (lit, length) in segments)
          if (lit) length,
      ];
      expect(dashes.reduce((a, b) => a > b ? a : b) -
          dashes.reduce((a, b) => a < b ? a : b), lessThanOrEqualTo(1));
    });
  });

  group('block elements', () {
    // Fraction of the cell filled with the foreground.
    Future<double> fill(WidgetTester tester, String glyph, double dpr) async {
      final scene = await _render(tester, ['${_sgrFg(_fg)}$glyph'],
          dpr: dpr, columns: 1);
      final c = _cell(scene.metrics, 0, 0);
      final lit = scene.pixels.count(_fg, x1: c.x1, y1: c.y1);
      return lit / ((c.x1 - c.x0) * (c.y1 - c.y0));
    }

    for (final dpr in [2.0, 2.625, 3.0]) {
      testWidgets('fractional blocks fill their share at dpr $dpr',
          (tester) async {
        const expected = {
          '█': 1.0,
          '▀': 0.5,
          '▄': 0.5,
          '▌': 0.5,
          '▐': 0.5,
          '▁': 1 / 8,
          '▂': 2 / 8,
          '▃': 3 / 8,
          '▅': 5 / 8,
          '▆': 6 / 8,
          '▇': 7 / 8,
          '▉': 7 / 8,
          '▊': 6 / 8,
          '▋': 5 / 8,
          '▍': 3 / 8,
          '▎': 2 / 8,
          '▏': 1 / 8,
          '▔': 1 / 8,
          '▕': 1 / 8,
          '▘': 0.25,
          '▝': 0.25,
          '▖': 0.25,
          '▗': 0.25,
          '▚': 0.5,
          '▞': 0.5,
          '▙': 0.75,
          '▛': 0.75,
          '▜': 0.75,
          '▟': 0.75,
        };
        final m = CellMetrics.measure(defaultTerminalFontSize, dpr);
        final w = m.columnEdge(1), h = m.rowPx;
        for (final MapEntry(key: glyph, value: share) in expected.entries) {
          final got = await fill(tester, glyph, dpr);
          // Within one pixel row/column of the exact share.
          expect(got, closeTo(share, 1 / w + 1 / h + 0.001),
              reason: '$glyph at dpr $dpr');
        }
      });
    }

    testWidgets('halves are drawn on the right side', (tester) async {
      final scene = await _render(
          tester, ['${_sgrFg(_fg)}▀▄▌▐'], dpr: 3, columns: 4);
      final m = scene.metrics;
      final p = scene.pixels;
      final upper = _cell(m, 0, 0), lower = _cell(m, 1, 0);
      final left = _cell(m, 2, 0), right = _cell(m, 3, 0);
      expect(p.isColor(upper.x0 + 1, 1, _fg), isTrue);
      expect(p.isColor(upper.x0 + 1, m.rowPx - 2, _bg), isTrue);
      expect(p.isColor(lower.x0 + 1, 1, _bg), isTrue);
      expect(p.isColor(lower.x0 + 1, m.rowPx - 2, _fg), isTrue);
      expect(p.isColor(left.x0 + 1, 3, _fg), isTrue);
      expect(p.isColor(left.x1 - 2, 3, _bg), isTrue);
      expect(p.isColor(right.x0 + 1, 3, _bg), isTrue);
      expect(p.isColor(right.x1 - 2, 3, _fg), isTrue);
    });

    testWidgets('shades blend the foreground over the background',
        (tester) async {
      final scene = await _render(tester, ['${_sgrFg(_fg)}░▒▓'],
          dpr: 3, columns: 3);
      final m = scene.metrics;
      for (var i = 0; i < 3; i++) {
        final c = _cell(m, i, 0);
        final got = scene.pixels.at(c.x0 + 3, 3);
        final want = Color.lerp(_bg, _fg, 0.25 * (i + 1))!;
        expect((got.r - want.r).abs() * 255, lessThan(3), reason: 'shade $i');
        expect((got.g - want.g).abs() * 255, lessThan(3), reason: 'shade $i');
        expect((got.b - want.b).abs() * 255, lessThan(3), reason: 'shade $i');
        // Uniform over the cell.
        expect(scene.pixels.at(c.x1 - 2, m.rowPx - 2), got);
      }
    });

    testWidgets('sprites draw over their own background and dim colour',
        (tester) async {
      final scene = await _render(
        tester,
        ['${_sgrBg(_light)}\x1b[2m${_sgrFg(_fg)}█'],
        dpr: 3,
        columns: 1,
      );
      final dim = Color.lerp(_light, _fg, 0.62)!;
      final got = scene.pixels.at(3, 3);
      expect((got.r - dim.r).abs() * 255, lessThan(2));
      expect((got.g - dim.g).abs() * 255, lessThan(2));
      expect((got.b - dim.b).abs() * 255, lessThan(2));
    });
  });

  group('whole view', () {
    testWidgets('a coloured block has no seams, still or mid-scroll',
        (tester) async {
      const dpr = 2.625;
      tester.view
        ..devicePixelRatio = dpr
        ..physicalSize = const Size(360, 400) * dpr;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      final row = '${_sgrBg(_light)}${' ' * 20}\x1b[0m';
      final text = List.filled(120, row).join('\r\n');

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: _bg,
              child: TerminalView(text: text),
            ),
          ),
        ),
      );
      final state = tester.state<ScrollableState>(find
          .descendant(
              of: find.byType(TerminalView), matching: find.byType(Scrollable))
          .last);

      final metrics = CellMetrics.measure(defaultTerminalFontSize, dpr);
      final padPx = (12 * dpr).round();
      for (final offset in [0.0, 7.3, 31.77, 100.5, 333.333]) {
        state.position.jumpTo(offset);
        await tester.pump();
        final pixels = await _capture(tester, key, dpr);
        final x0 = padPx;
        final x1 = padPx + metrics.columnEdge(20);
        // Skip the list's own padding (8 px at the ends of the list).
        final y0 = (8 * dpr).ceil() + 1;
        final bad = pixels.notColor(_light,
            x0: x0, x1: x1, y0: y0, y1: (390 * dpr).floor());
        expect(bad, isEmpty, reason: 'offset $offset');
      }
    });
  });
}
