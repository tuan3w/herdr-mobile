// The render-time contrast guard: a cell's text is lifted towards readable
// against the cell's own background, so the palette can keep the true ANSI
// colours (a black block is black) and text in them still reads.
import 'dart:ui' show Color;

import 'package:flutter/painting.dart' show HSLColor;
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/render/terminal/ansi.dart';
import 'package:herdr_mobile/ui/render/terminal/terminal_cells.dart';
import 'package:herdr_mobile/ui/render/terminal/terminal_contrast.dart';

const _floor = 4.5;
const _esc = '\x1b';

final _page = TerminalColors.background;
final _black = TerminalColors.ansi[0];
final _white = const Color(0xFFFFFFFF);

double _hueGap(Color a, Color b) {
  final d = (HSLColor.fromColor(a).hue - HSLColor.fromColor(b).hue).abs();
  return d > 180 ? 360 - d : d;
}

/// What the guard draws [run] as: its pieces, in the dark palette.
List<AnsiRun> _dark(AnsiRun run) => TerminalPalette.dark.recolor([run]);

/// The colour the glyphs of [run] are painted in.
Color _ink(AnsiRun run) => runForeground(run, TerminalPalette.dark);

void main() {
  setUp(TerminalContrast.debugReset);

  group('liftToContrast', () {
    final backgrounds = <String, Color>{
      'page': _page,
      'white': _white,
      'black': const Color(0xFF000000),
      'ansi black': _black,
      'red': TerminalColors.ansi[1],
      'mid grey': const Color(0xFF808080),
      'pale yellow': const Color(0xFFFFF3B0),
      'dark green': const Color(0xFF0B3D1E),
    };
    final foregrounds = <Color>[
      ...TerminalColors.ansi,
      for (final r in const [0, 64, 128, 192, 255])
        for (final g in const [0, 64, 128, 192, 255])
          for (final b in const [0, 64, 128, 192, 255]) Color.fromARGB(255, r, g, b),
    ];

    test('the result reaches the floor, or the best the background allows', () {
      for (final MapEntry(key: name, value: bg) in backgrounds.entries) {
        final best = [
          contrastRatio(_white, bg),
          contrastRatio(const Color(0xFF000000), bg),
        ].reduce((a, b) => a > b ? a : b);
        for (final floor in const [3.0, _floor, 7.0, 12.0, 30.0]) {
          for (final fg in foregrounds) {
            final out = liftToContrast(fg, bg, floor);
            final want = floor < best ? floor : best;
            expect(contrastRatio(out, bg), greaterThanOrEqualTo(want - 1e-9), reason: '$fg on $name at $floor');
          }
        }
      }
    });

    test('a colour that already reads is returned as it is, the very same object', () {
      for (final MapEntry(key: name, value: bg) in backgrounds.entries) {
        for (final fg in foregrounds) {
          if (contrastRatio(fg, bg) < _floor) continue;
          expect(identical(liftToContrast(fg, bg, _floor), fg), isTrue, reason: '$fg on $name');
        }
      }
    });

    test('hue is kept: only lightness moves', () {
      var checked = 0;
      for (final MapEntry(key: name, value: bg) in backgrounds.entries) {
        for (final fg in foregrounds) {
          final out = liftToContrast(fg, bg, _floor);
          if (identical(out, fg)) continue;
          final from = HSLColor.fromColor(fg);
          final to = HSLColor.fromColor(out);
          // A grey has no hue, and 8-bit channels at the very ends of the
          // lightness scale cannot hold one.
          if (from.saturation < 0.15 || to.lightness < 0.08 || to.lightness > 0.92) continue;
          checked++;
          expect(_hueGap(fg, out), lessThanOrEqualTo(4), reason: '$fg on $name -> $out');
          expect(to.saturation, closeTo(from.saturation, 0.06), reason: '$fg on $name -> $out');
        }
      }
      expect(checked, greaterThan(100), reason: 'the sample has to exercise it');
    });

    test('it moves away from the background, and only as far as it must', () {
      // On the dark page text is lifted, never darkened; on white darkened.
      for (final fg in foregrounds) {
        final up = liftToContrast(fg, _page, _floor);
        expect(up.computeLuminance(), greaterThanOrEqualTo(fg.computeLuminance() - 1e-9));
        final down = liftToContrast(fg, _white, _floor);
        expect(down.computeLuminance(), lessThanOrEqualTo(fg.computeLuminance() + 1e-9));
      }
      // Minimal: one 8-bit step less lightness would not reach the floor.
      final out = liftToContrast(_black, _page, _floor);
      final l = HSLColor.fromColor(out).lightness;
      final below = HSLColor.fromColor(out).withLightness(l - 2 / 255).toColor();
      expect(contrastRatio(out, _page), greaterThanOrEqualTo(_floor));
      expect(contrastRatio(below, _page), lessThan(_floor + 0.15));
    });

    test('monotonic: a higher floor never gives a lower contrast', () {
      for (final bg in [_page, _white]) {
        for (final fg in foregrounds) {
          var last = 0.0;
          for (final floor in const [1.5, 3.0, 4.5, 7.0, 10.0]) {
            final c = contrastRatio(liftToContrast(fg, bg, floor), bg);
            expect(c, greaterThanOrEqualTo(last - 1e-9), reason: '$fg on $bg at $floor');
            last = c;
          }
        }
      }
    });

    test('black on black becomes readable, white on white too', () {
      final black = liftToContrast(const Color(0xFF000000), const Color(0xFF000000), _floor);
      expect(contrastRatio(black, const Color(0xFF000000)), greaterThanOrEqualTo(_floor));
      final same = liftToContrast(_white, _white, _floor);
      expect(contrastRatio(same, _white), greaterThanOrEqualTo(_floor));
      final ansi = liftToContrast(_black, _black, _floor);
      expect(contrastRatio(ansi, _black), greaterThanOrEqualTo(_floor));
      expect(_hueGap(ansi, _black), lessThanOrEqualTo(4));
    });

    test('a floor no colour can reach gives the best one there is', () {
      expect(liftToContrast(_black, _page, 30).computeLuminance(), closeTo(1, 1e-9));
      expect(liftToContrast(_white, _white, 30).computeLuminance(), closeTo(0, 1e-9));
    });
  });

  group('cell contrast, dark palette', () {
    test('ANSI black text on the page is lifted, hue kept, background untouched', () {
      final out = _dark(AnsiRun('x', fg: _black)).single;
      expect(out.bg, isNull);
      expect(contrastRatio(_ink(out), _page), greaterThanOrEqualTo(_floor));
      expect(_hueGap(out.fg!, _black), lessThanOrEqualTo(4));
    });

    test('ANSI black text on its own ANSI black background (invisible) is lifted', () {
      final out = _dark(AnsiRun('x', fg: _black, bg: _black)).single;
      expect(out.bg, _black, reason: 'backgrounds are never touched');
      expect(contrastRatio(_ink(out), _black), greaterThanOrEqualTo(_floor));
    });

    test('black text on a red background is lifted against the red, not the page', () {
      final red = TerminalColors.ansi[1];
      expect(contrastRatio(_black, red), lessThan(_floor), reason: 'the premise');
      final out = _dark(AnsiRun('x', fg: _black, bg: red)).single;
      expect(out.bg, red);
      expect(contrastRatio(out.fg!, red), greaterThanOrEqualTo(_floor));
      // Darker, not lighter: the red is the lighter of the two.
      expect(out.fg!.computeLuminance(), lessThan(_black.computeLuminance()));
    });

    test('default text on a black background is left alone: it already reads', () {
      final run = AnsiRun('status', bg: _black);
      final out = TerminalPalette.dark.recolor([run]);
      expect(identical(out.single, run), isTrue);
      expect(contrastRatio(TerminalColors.foreground, _black), greaterThanOrEqualTo(_floor));
    });

    test('reverse video: black text reversed is the page colour on a black block, and is lifted', () {
      final run = parseAnsi('$_esc[30;7mhello').lines.single.single;
      expect(run.bg, _black);
      expect(contrastRatio(run.fg!, run.bg!), lessThan(_floor), reason: 'the premise');
      final out = _dark(run).single;
      expect(out.bg, _black);
      expect(contrastRatio(out.fg!, _black), greaterThanOrEqualTo(_floor));
      // Plain reverse video reads and is returned as it came.
      final plain = parseAnsi('$_esc[7mhello').lines.single.single;
      expect(identical(_dark(plain).single, plain), isTrue);
    });

    test('every source of colour: ANSI, 256, truecolour, dim', () {
      final lines = parseAnsi(
        [
          '$_esc[90mbright black', // 8: reads already
          '$_esc[38;5;232mgrey 232', // 256 ramp, near black
          '$_esc[38;5;255mgrey 255', // 256 ramp, near white
          '$_esc[38;2;20;22;30mtruecolour dark',
          '$_esc[2;30mdim black',
          '$_esc[2mdim default',
        ].join('$_esc[0m\n'),
      ).lines;
      final out = [for (final l in lines) _dark(l.single).single];
      for (final (i, run) in out.indexed) {
        expect(contrastRatio(_ink(run), _page), greaterThanOrEqualTo(_floor), reason: 'row $i: ${run.text}');
      }
      expect(identical(out[0], lines[0].single), isTrue);
      expect(identical(out[2], lines[2].single), isTrue);
      expect(identical(out[5], lines[5].single), isTrue, reason: 'dim default reads, so it keeps its dim');
      expect(out[5].dim, isTrue);
      expect(out[4].dim, isFalse, reason: 'a lifted dim colour is final: blending it again would lose the lift');
    });

    test('shapes and blank cells are exempt', () {
      for (final text in ['┌────┐', '████', '▓▒░ ', '    ', '\u00A0']) {
        final run = AnsiRun(text, fg: _black);
        expect(identical(_dark(run).single, run), isTrue, reason: 'text "$text"');
      }
    });

    test('a run with a frame and a word: the word is lifted, the frame keeps its colour', () {
      final out = _dark(AnsiRun('│ hello │', fg: _black));
      expect(out.map((r) => r.text).join(), '│ hello │');
      expect(out.first.text.trim(), '│');
      expect(out.first.fg, _black);
      expect(out.last.text, '│');
      final word = out.firstWhere((r) => r.text.contains('hello'));
      expect(contrastRatio(word.fg!, _page), greaterThanOrEqualTo(_floor));
    });

    test('other attributes and text survive the lift', () {
      final out = _dark(AnsiRun('héllo', fg: _black, bold: true, italic: true, underline: true, strike: true)).single;
      expect(out.text, 'héllo');
      expect([out.bold, out.italic, out.underline, out.strike], everyElement(isTrue));
    });

    test('a pale background of its own and no colour of its own: the default text is darkened', () {
      const pale = Color(0xFFFFF3B0);
      final out = _dark(const AnsiRun('x', bg: pale)).single;
      expect(out.bg, pale);
      expect(contrastRatio(out.fg!, pale), greaterThanOrEqualTo(_floor));
    });
  });

  group('the common path', () {
    test('a run of default text is the same object, and so is its list', () {
      final runs = [const AnsiRun('plain'), const AnsiRun('bold', bold: true), const AnsiRun('under', underline: true)];
      final out = TerminalPalette.dark.recolor(runs);
      expect(identical(out, runs), isTrue);
      expect(TerminalContrast.debugComputed, 0, reason: 'no colour, nothing to ask');
    });

    test('colours that read: the list comes back as it is', () {
      final runs = [
        for (final c in [1, 2, 3, 4, 5, 6, 7, 8, 9]) AnsiRun('x', fg: TerminalColors.ansi[c]),
      ];
      expect(identical(TerminalPalette.dark.recolor(runs), runs), isTrue);
    });

    test('only the runs that need it are replaced; the others keep their identity', () {
      final runs = [AnsiRun('a', fg: TerminalColors.ansi[2]), AnsiRun('b', fg: _black), const AnsiRun('c')];
      final out = TerminalPalette.dark.recolor(runs);
      expect(out, hasLength(3));
      expect(identical(out[0], runs[0]), isTrue);
      expect(identical(out[1], runs[1]), isFalse);
      expect(identical(out[2], runs[2]), isTrue);
    });

    test('a colour pair is worked out once', () {
      final run = AnsiRun('x', fg: _black);
      for (var i = 0; i < 50; i++) {
        TerminalPalette.dark.recolor([run]);
      }
      expect(TerminalContrast.debugComputed, 1);
      TerminalPalette.dark.recolor([AnsiRun('y', fg: _black, bg: TerminalColors.ansi[1])]);
      expect(TerminalContrast.debugComputed, 2, reason: 'the same colour on another background is another pair');
    });

    test('rows are prepared through it, in both palettes', () {
      final metrics = CellMetrics.measure(12, 1);
      final runs = [AnsiRun('x', fg: _black)];
      expect(contrastRatio(TerminalLine(runs, metrics).runs.single.fg!, _page), greaterThanOrEqualTo(_floor));
      final fine = [AnsiRun('x', fg: TerminalColors.ansi[2])];
      expect(identical(TerminalLine(fine, metrics).runs, fine), isTrue);
    });
  });

  // Counts, not time: how much work a pane's worth of rows costs the guard. The
  // figures in the comment are from this test on the desktop and say what the
  // work is made of, not how fast a phone does it.
  group('a 300 x 120 screen of mixed cells', () {
    // 30 runs of 10 cells per row, 120 rows: 36 000 cells, 3 600 runs.
    // 16 styles, 5 of which draw text in a colour that fails on its background.
    final styles = <AnsiRun Function(String)>[
      (t) => AnsiRun(t),
      (t) => AnsiRun(t, bold: true),
      for (var i = 1; i < 8; i++) (t) => AnsiRun(t, fg: TerminalColors.ansi[i]),
      (t) => AnsiRun(t, fg: TerminalColors.ansi[8], dim: true),
      (t) => AnsiRun(t, bg: TerminalColors.ansi[0]),
      (t) => AnsiRun(t, fg: TerminalColors.ansi[0]), // fails
      (t) => AnsiRun(t, fg: TerminalColors.ansi[0], bg: TerminalColors.ansi[0]), // fails
      (t) => AnsiRun(t, fg: const Color(0xFF303030)), // fails: a 256 grey
      (t) => AnsiRun(t, fg: TerminalColors.ansi[0], dim: true), // fails
      (t) => AnsiRun('──────────', fg: TerminalColors.ansi[0]), // a shape
    ];
    final screen = [
      for (var row = 0; row < 120; row++)
        [for (var run = 0; run < 30; run++) styles[(row * 30 + run) % styles.length]('0123456789')],
    ];

    test('mixed: work is per colour pair, new objects only where a colour fails', () {
      final rows = screen;
      final prepared = [for (final row in rows) TerminalPalette.dark.recolor(row)];
      var runs = 0, replaced = 0, sameLists = 0;
      for (var i = 0; i < rows.length; i++) {
        runs += rows[i].length;
        if (identical(prepared[i], rows[i])) sameLists++;
        for (var j = 0; j < rows[i].length; j++) {
          if (prepared[i].length == rows[i].length && !identical(prepared[i][j], rows[i][j])) replaced++;
        }
      }
      // Desktop (a count, the same anywhere): 3600 runs over 36 000 cells; 13
      // colour pairs worked out, once each; 1125 runs replaced (5 of the 16
      // styles fail: black, black on black, a 256 grey, dim black, dim bright
      // black), the other 2475 are the very same objects; every row has at
      // least one replaced run, so none comes back as it was. The work per
      // run is a null check (no colour) or one map lookup; the 36 000 cells
      // are never visited, except the text of the runs that are replaced.
      // ignore: avoid_print
      print('mixed: runs=$runs computed=${TerminalContrast.debugComputed} replaced=$replaced rowsUntouched=$sameLists');
      expect(runs, 3600);
      expect(TerminalContrast.debugComputed, lessThanOrEqualTo(13));
      expect(replaced, 1125);
      expect(sameLists, 0);
      // The second pass (a refresh of the same colours) asks nothing new.
      TerminalContrast.debugResetCount();
      for (final row in rows) {
        TerminalPalette.dark.recolor(row);
      }
      expect(TerminalContrast.debugComputed, 0);
    });

    test('common: every colour reads: no run replaced, no list rebuilt, one compute per pair', () {
      final rows = [
        for (var row = 0; row < 120; row++) [for (var run = 0; run < 30; run++) styles[(row + run) % 9]('0123456789')],
      ];
      final prepared = [for (final row in rows) TerminalPalette.dark.recolor(row)];
      var rebuilt = 0;
      for (var i = 0; i < rows.length; i++) {
        if (!identical(prepared[i], rows[i])) rebuilt++;
      }
      // Desktop: 0 lists rebuilt of 120; computes = distinct colour pairs (7:
      // the 7 ANSI colours; default and bold ask nothing).
      // ignore: avoid_print
      print('common: rowsRebuilt=$rebuilt computed=${TerminalContrast.debugComputed}');
      expect(rebuilt, 0);
      expect(TerminalContrast.debugComputed, lessThanOrEqualTo(7));
    });
  });
}
