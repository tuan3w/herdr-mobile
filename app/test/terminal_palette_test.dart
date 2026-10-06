import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/ansi.dart';
import 'package:herdr_mobile/ui/core/terminal_cells.dart';
import 'package:herdr_mobile/ui/core/theme.dart';

double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  final dark = TerminalPalette.dark;
  final light = TerminalPalette.light;

  group('the light palette', () {
    test('every ANSI colour reads on its page', () {
      for (var i = 0; i < 16; i++) {
        expect(contrast(light.ansi[i], light.background), greaterThanOrEqualTo(4.5), reason: 'colour $i');
      }
      expect(contrast(light.foreground, light.background), greaterThanOrEqualTo(7));
      expect(contrast(light.dim, light.background), greaterThanOrEqualTo(4.5));
      expect(contrast(light.link, light.background), greaterThanOrEqualTo(4.5));
    });

    test('it is light and the other is dark', () {
      expect(light.isDark, isFalse);
      expect(dark.isDark, isTrue);
      expect(light.background.computeLuminance(), greaterThan(0.9));
      expect(dark.background.computeLuminance(), lessThan(0.05));
    });
  });

  group('recolor', () {
    test('the dark palette returns the run itself', () {
      const run = AnsiRun('x', fg: Color(0xFFE06C75));
      expect(identical(dark.recolor(run), run), isTrue);
    });

    test('parser colours become the palette\'s, text and background', () {
      final run = AnsiRun('x', fg: TerminalColors.ansi[1], bg: TerminalColors.ansi[4]);
      final out = light.recolor(run);
      expect(out.bg, light.ansi[4]);
      // Red text on blue: the colour is kept if it reads, else darkened.
      expect(out.text, 'x');
      expect(out.fg, isNotNull);
    });

    test('a plain run stays plain (the palette draws the defaults)', () {
      const run = AnsiRun('x');
      expect(identical(light.recolor(run), run), isTrue);
    });

    test('reverse video swaps to the light defaults', () {
      // The parser bakes the dark defaults into a reversed run.
      final reversed = AnsiRun('x', fg: TerminalColors.background, bg: TerminalColors.foreground);
      final out = light.recolor(reversed);
      expect(out.bg, light.foreground);
      expect(contrast(out.fg!, out.bg!), greaterThanOrEqualTo(TerminalPalette.minContrast));
    });

    test('text with a dark background of its own and no colour gets light text', () {
      final out = light.recolor(const AnsiRun('x', bg: Color(0xFF0B3D1E)));
      expect(out.fg, TerminalColors.foreground);
      expect(contrast(out.fg!, out.bg!), greaterThanOrEqualTo(7));
    });

    test('text with a pale background of its own and no colour gets the dark default', () {
      final out = light.recolor(const AnsiRun('x', bg: Color(0xFFFFF3B0)));
      expect(out.fg, light.foreground);
    });

    test('pale text meant for a dark screen is pulled to a readable shade', () {
      final out = light.recolor(const AnsiRun('x', fg: Color(0xFFE8E8E8)));
      expect(contrast(out.fg!, light.background), greaterThanOrEqualTo(TerminalPalette.minContrast));
      // Text that already reads is left alone.
      const fine = AnsiRun('x', fg: Color(0xFF204080));
      expect(identical(light.recolor(fine), fine), isTrue);
    });

    test('attributes and text survive', () {
      final out = light.recolor(
        AnsiRun('héllo', fg: TerminalColors.ansi[2], bold: true, dim: true, italic: true, underline: true, strike: true),
      );
      expect(out.text, 'héllo');
      expect([out.bold, out.dim, out.italic, out.underline, out.strike], everyElement(isTrue));
      expect(out.fg, light.ansi[2]);
    });
  });

  group('rows follow the palette', () {
    test('a light row is prepared in light colours; metrics differ by palette', () {
      final darkMetrics = CellMetrics.measure(12, 1);
      final lightMetrics = CellMetrics.measure(12, 1, palette: light);
      expect(darkMetrics, isNot(lightMetrics));
      expect(lightMetrics, CellMetrics.measure(12, 1, palette: light));
      expect(lightMetrics.textStyle.color, light.foreground);
      expect(darkMetrics.textStyle.color, dark.foreground);

      final runs = [AnsiRun('ok', fg: TerminalColors.ansi[2])];
      expect(TerminalLine(runs, darkMetrics).runs.single.fg, TerminalColors.ansi[2]);
      expect(TerminalLine(runs, lightMetrics).runs.single.fg, light.ansi[2]);
    });
  });
}
