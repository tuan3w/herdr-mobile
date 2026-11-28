import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/render/terminal/ansi.dart';
import 'package:herdr_mobile/ui/render/terminal/terminal_cells.dart';
import 'package:herdr_mobile/ui/render/terminal/terminal_contrast.dart';

double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  final dark = TerminalPalette.dark;
  final light = TerminalPalette.light;

  group('each palette', () {
    // The palette holds the TRUE ANSI colours (black is a nord-ish slate, so a
    // TUI's black block looks like one); what promises legibility is the
    // render: text in any of them is lifted against its own background by the
    // contrast guard (`terminal_contrast.dart`). The dark palette once held
    // black at 1.96:1 under a comment that promised 4.5 because only the light
    // palette was ever measured, and then at 3.26 to keep a status line right.
    for (final (name, palette) in [('dark', dark), ('light', light)]) {
      test('$name: every ANSI colour, as text, reads on its page once drawn', () {
        for (var i = 0; i < 16; i++) {
          final drawn = palette.recolor([AnsiRun('x', fg: TerminalColors.ansi[i])]).single;
          expect(
            contrast(runForeground(drawn, palette), palette.background),
            greaterThanOrEqualTo(4.5),
            reason: 'colour $i',
          );
        }
        expect(contrast(palette.foreground, palette.background), greaterThanOrEqualTo(7));
        expect(contrast(palette.dim, palette.background), greaterThanOrEqualTo(4.5));
        expect(contrast(palette.link, palette.background), greaterThanOrEqualTo(4.5));
      });

      test('$name: every ANSI colour on every ANSI background, as text, reads once drawn', () {
        for (var fg = 0; fg < 16; fg++) {
          for (var bg = 0; bg < 16; bg++) {
            final drawn = palette.recolor([
              AnsiRun('x', fg: TerminalColors.ansi[fg], bg: TerminalColors.ansi[bg]),
            ]).single;
            expect(
              contrast(runForeground(drawn, palette), drawn.bg!),
              greaterThanOrEqualTo(4.5),
              reason: 'fg $fg on bg $bg',
            );
          }
        }
      });
    }

    test('dark: the palette keeps the true colours, so a black block is black', () {
      expect(dark.ansi, TerminalColors.ansi);
      expect(dark.ansi[0], const Color(0xFF3B4252));
      // The block is a shape against the page: it must be seen, as a block.
      expect(contrast(dark.ansi[0], dark.background), greaterThanOrEqualTo(1.8));
      // And it stays apart from bright black (the dim text TUIs draw), below it.
      expect(contrast(dark.ansi[8], dark.ansi[0]), greaterThanOrEqualTo(1.3), reason: 'bright black vs black');
      expect(dark.ansi[7].computeLuminance(), greaterThan(dark.ansi[8].computeLuminance()));
    });

    test('dark: text on a black background reads by the guard, not by tuning the palette', () {
      // The common status line: default text, and the white colour, on black.
      for (final run in [
        const AnsiRun('x', bg: Color(0xFF3B4252)),
        AnsiRun('x', fg: TerminalColors.ansi[7], bg: dark.ansi[0]),
      ]) {
        final drawn = dark.recolor([run]).single;
        expect(contrast(runForeground(drawn, dark), dark.ansi[0]), greaterThanOrEqualTo(4.5));
      }
      // Black text on the page needed a lift, and got one.
      final black = dark.recolor([AnsiRun('x', fg: dark.ansi[0])]).single;
      expect(black.fg, isNot(dark.ansi[0]));
    });

    test('it is light and the other is dark', () {
      expect(light.isDark, isFalse);
      expect(dark.isDark, isTrue);
      expect(light.background.computeLuminance(), greaterThan(0.9));
      expect(dark.background.computeLuminance(), lessThan(0.05));
    });
  });

  group('recolor', () {
    test('a run with nothing to lift is returned as it is, whatever the palette', () {
      const run = AnsiRun('x', fg: Color(0xFFE06C75));
      final runs = [run];
      expect(identical(dark.recolor(runs), runs), isTrue);
    });

    test('parser colours become the palette\'s, text and background', () {
      final run = AnsiRun('x', fg: TerminalColors.ansi[1], bg: TerminalColors.ansi[4]);
      final out = light.recolor([run]).single;
      expect(out.bg, light.ansi[4]);
      // Red text on blue: the colour is kept if it reads, else darkened.
      expect(out.text, 'x');
      expect(out.fg, isNotNull);
    });

    test('a plain run stays plain (the palette draws the defaults)', () {
      final runs = [const AnsiRun('x')];
      expect(identical(light.recolor(runs), runs), isTrue);
    });

    test('reverse video swaps to the light defaults', () {
      // The parser bakes the dark defaults into a reversed run.
      final reversed = AnsiRun('x', fg: TerminalColors.background, bg: TerminalColors.foreground);
      final out = light.recolor([reversed]).single;
      expect(out.bg, light.foreground);
      expect(contrast(out.fg!, out.bg!), greaterThanOrEqualTo(TerminalPalette.minContrast));
    });

    test('text with a dark background of its own and no colour gets light text', () {
      final out = light.recolor([const AnsiRun('x', bg: Color(0xFF0B3D1E))]).single;
      expect(out.fg, TerminalColors.foreground);
      expect(contrast(out.fg!, out.bg!), greaterThanOrEqualTo(7));
    });

    test('text with a pale background of its own and no colour gets the dark default', () {
      final out = light.recolor([const AnsiRun('x', bg: Color(0xFFFFF3B0))]).single;
      expect(out.fg, light.foreground);
    });

    test('pale text meant for a dark screen is pulled to a readable shade', () {
      final out = light.recolor([const AnsiRun('x', fg: Color(0xFFE8E8E8))]).single;
      expect(contrast(out.fg!, light.background), greaterThanOrEqualTo(TerminalPalette.minContrast));
      // Text that already reads is left alone.
      final fine = [const AnsiRun('x', fg: Color(0xFF204080))];
      expect(identical(light.recolor(fine), fine), isTrue);
    });

    test('attributes and text survive', () {
      final out = light.recolor([
        AnsiRun('héllo', fg: TerminalColors.ansi[2], bold: true, italic: true, underline: true, strike: true),
      ]).single;
      expect(out.text, 'héllo');
      expect([out.bold, out.italic, out.underline, out.strike], everyElement(isTrue));
      expect(out.fg, light.ansi[2]);
    });

    test('dim text is judged as drawn (blended), and a lifted dim colour is final', () {
      // Dim green on paper: the blend towards the page is paler than the green.
      final out = light.recolor([AnsiRun('x', fg: TerminalColors.ansi[2], dim: true)]).single;
      expect(contrast(runForeground(out, light), light.background), greaterThanOrEqualTo(4.5));
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
