import 'dart:math';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/ansi.dart';
import 'package:herdr_mobile/ui/core/theme.dart';

const _esc = '\x1b';

String _sgr(String params) => '$_esc[${params}m';

/// Visible text of each line.
List<String> _plain(String input) => [
      for (final line in parseAnsi(input).lines) line.map((r) => r.text).join(),
    ];

/// The only run of a one-line, one-run document.
AnsiRun _run(String input) {
  final lines = parseAnsi(input).lines;
  expect(lines, hasLength(1), reason: input);
  expect(lines.single, hasLength(1), reason: input);
  return lines.single.single;
}

Color _rgb(int r, int g, int b) => Color.fromARGB(255, r, g, b);

double _contrast(Color a, Color b) {
  final hi = max(a.computeLuminance(), b.computeLuminance());
  final lo = min(a.computeLuminance(), b.computeLuminance());
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('colours', () {
    test('truecolor foreground and background', () {
      final run = _run('${_sgr('38;2;118;118;118;48;2;1;2;3')}text');
      expect(run.text, 'text');
      expect(run.fg, _rgb(118, 118, 118));
      expect(run.bg, _rgb(1, 2, 3));
    });

    test('16 colours: normal and bright, foreground and background', () {
      for (var i = 0; i < 8; i++) {
        expect(_run('${_sgr('3$i')}x').fg, TerminalColors.ansi[i], reason: '3$i');
        expect(_run('${_sgr('4$i')}x').bg, TerminalColors.ansi[i], reason: '4$i');
        expect(_run('${_sgr('9$i')}x').fg, TerminalColors.ansi[8 + i], reason: '9$i');
        expect(_run('${_sgr('10$i')}x').bg, TerminalColors.ansi[8 + i], reason: '10$i');
      }
    });

    test('256 colours: base 16 map to the palette', () {
      expect(_run('${_sgr('38;5;1')}x').fg, TerminalColors.ansi[1]);
      expect(_run('${_sgr('38;5;15')}x').fg, TerminalColors.ansi[15]);
      expect(_run('${_sgr('48;5;9')}x').bg, TerminalColors.ansi[9]);
    });

    test('256 colours: 6x6x6 cube corners and a middle cell', () {
      expect(_run('${_sgr('38;5;16')}x').fg, _rgb(0, 0, 0));
      expect(_run('${_sgr('38;5;21')}x').fg, _rgb(0, 0, 255));
      expect(_run('${_sgr('38;5;46')}x').fg, _rgb(0, 255, 0));
      expect(_run('${_sgr('38;5;196')}x').fg, _rgb(255, 0, 0));
      expect(_run('${_sgr('38;5;231')}x').fg, _rgb(255, 255, 255));
      // 123 = 16 + 36*2 + 6*5 + 5 -> levels 2, 5, 5 -> 135, 255, 255.
      expect(_run('${_sgr('38;5;123')}x').fg, _rgb(135, 255, 255));
      expect(_run('${_sgr('48;5;59')}x').bg, _rgb(95, 95, 95));
    });

    test('256 colours: greyscale ramp', () {
      expect(_run('${_sgr('38;5;232')}x').fg, _rgb(8, 8, 8));
      expect(_run('${_sgr('38;5;244')}x').fg, _rgb(128, 128, 128));
      expect(_run('${_sgr('38;5;255')}x').fg, _rgb(238, 238, 238));
    });

    test('colon-separated forms, with and without a colour-space id', () {
      expect(_run('${_sgr('38:2:10:20:30')}x').fg, _rgb(10, 20, 30));
      expect(_run('${_sgr('38:2::10:20:30')}x').fg, _rgb(10, 20, 30));
      expect(_run('${_sgr('48:2::1:2:3')}x').bg, _rgb(1, 2, 3));
      expect(_run('${_sgr('38:5:196')}x').fg, _rgb(255, 0, 0));
      expect(_run('${_sgr('48:5:232')}x').bg, _rgb(8, 8, 8));
    });

    test('a colon-form colour does not swallow the parameters after it', () {
      final run = _run('${_sgr('38:5:196;1;48:2::1:2:3')}x');
      expect(run.fg, _rgb(255, 0, 0));
      expect(run.bold, isTrue);
      expect(run.bg, _rgb(1, 2, 3));
    });

    test('39 and 49 restore the defaults', () {
      final run = _run('${_sgr('31;44')}${_sgr('39')}${_sgr('49')}x');
      expect(run.fg, isNull);
      expect(run.bg, isNull);
    });

    test('out-of-range colours are ignored and leave the old one alone', () {
      expect(_run('${_sgr('38;5;300')}x').fg, isNull);
      expect(_run('${_sgr('38;2;999;0;0')}x').fg, isNull);
      expect(_run('${_sgr('32;38;5;256')}x').fg, TerminalColors.ansi[2]);
      expect(_run('${_sgr('31;38;2;1')}x').fg, TerminalColors.ansi[1]);
    });

    test('the palette stays readable on the terminal background', () {
      for (var i = 1; i < 16; i++) {
        expect(
          _contrast(TerminalColors.ansi[i], TerminalColors.background),
          greaterThanOrEqualTo(4.5),
          reason: 'colour $i',
        );
      }
    });
  });

  group('attributes', () {
    test('set', () {
      expect(_run('${_sgr('1')}x').bold, isTrue);
      expect(_run('${_sgr('2')}x').dim, isTrue);
      expect(_run('${_sgr('3')}x').italic, isTrue);
      expect(_run('${_sgr('4')}x').underline, isTrue);
      expect(_run('${_sgr('9')}x').strike, isTrue);
      final plain = _run('x');
      expect([plain.bold, plain.dim, plain.italic, plain.underline, plain.strike],
          everyElement(isFalse));
    });

    test('22-29 reset only their own attribute', () {
      final all = _sgr('1;2;3;4;9;31');
      final bold = _run('$all${_sgr('22')}x');
      expect([bold.bold, bold.dim], everyElement(isFalse), reason: '22 clears both');
      expect([bold.italic, bold.underline, bold.strike], everyElement(isTrue));

      final italic = _run('$all${_sgr('23')}x');
      expect(italic.italic, isFalse);
      expect([italic.bold, italic.dim, italic.underline, italic.strike],
          everyElement(isTrue));

      final underline = _run('$all${_sgr('24')}x');
      expect(underline.underline, isFalse);
      expect([underline.bold, underline.italic, underline.strike],
          everyElement(isTrue));

      final strike = _run('$all${_sgr('29')}x');
      expect(strike.strike, isFalse);
      expect([strike.bold, strike.italic, strike.underline],
          everyElement(isTrue));

      for (final code in ['25', '26', '28']) {
        final other = _run('$all${_sgr(code)}x');
        expect(other.fg, TerminalColors.ansi[1], reason: code);
        expect(other.bold, isTrue, reason: code);
      }
    });

    test('0 and an empty parameter list reset everything', () {
      final everything = _sgr('1;2;3;4;9;7;31;44');
      for (final reset in [_sgr('0'), _sgr(''), '$_esc[m', _sgr(';')]) {
        final run = _run('$everything${reset}x');
        expect(run.fg, isNull, reason: reset);
        expect(run.bg, isNull, reason: reset);
        expect([run.bold, run.dim, run.italic, run.underline, run.strike],
            everyElement(isFalse), reason: reset);
      }
    });

    test('a reset mid-line splits the runs', () {
      final runs = parseAnsi('${_sgr('1;31')}a${_sgr('0')}b${_sgr('1')}c${_sgr('')}d')
          .lines
          .single;
      expect(runs.map((r) => r.text), ['a', 'b', 'c', 'd']);
      expect(runs.map((r) => r.bold), [true, false, true, false]);
      expect(runs.map((r) => r.fg), [TerminalColors.ansi[1], null, null, null]);
    });

    test('4:0 turns underline off and 4:3 (curly) turns it on', () {
      expect(_run('${_sgr('4:3')}x').underline, isTrue);
      expect(_run('${_sgr('4')}${_sgr('4:0')}x').underline, isFalse);
    });

    test('adjacent text in the same style is one run', () {
      final runs = parseAnsi('${_sgr('31')}a${_sgr('31')}b${_sgr('32')}c').lines.single;
      expect(runs.map((r) => r.text), ['ab', 'c']);
    });

    test('style carries over a line break', () {
      final lines = parseAnsi('${_sgr('31')}a\nb').lines;
      expect(lines[1].single.fg, TerminalColors.ansi[1]);
    });
  });

  group('reverse video', () {
    test('swaps the default colours for the theme ones', () {
      final run = _run('${_sgr('7')}x');
      expect(run.fg, TerminalColors.background);
      expect(run.bg, TerminalColors.foreground);
    });

    test('swaps explicit colours', () {
      final run = _run('${_sgr('31;44;7')}x');
      expect(run.fg, TerminalColors.ansi[4]);
      expect(run.bg, TerminalColors.ansi[1]);
    });

    test('27 undoes it', () {
      final run = _run('${_sgr('31;7;27')}x');
      expect(run.fg, TerminalColors.ansi[1]);
      expect(run.bg, isNull);
    });

    test('reversed padding is visible, so it is kept', () {
      expect(_plain('${_sgr('7')}ab   ${_sgr('0')}'), ['ab   ']);
    });
  });

  group('malformed input', () {
    final cases = <String, List<String>>{
      'a lone CSI introducer': ['a$_esc[', 'a'],
      'a truncated truecolor': ['a$_esc[38;2;1', 'a'],
      'a truncated 256 colour': ['a$_esc[38;5', 'a'],
      'a trailing separator': ['x$_esc[31;', 'x'],
      'a lone ESC': ['a$_esc', 'a'],
      'ESC ESC': ['a$_esc$_esc[31mb', 'ab'],
      'unknown final byte': ['a$_esc[2Jb', 'ab'],
      'a private-mode sequence': ['$_esc[?1049hX', 'X'],
      'a private SGR-looking sequence': ['$_esc[>4;2mX', 'X'],
      'an intermediate byte before m': ['$_esc[1 mX', 'X'],
      'a charset designation': ['$_esc(Bx', 'x'],
      'a two-byte escape': ['${_esc}7x${_esc}8y', 'xy'],
      'a huge parameter': ['$_esc[${'9' * 50};1mhi', 'hi'],
      'thousands of parameters': ['$_esc[${'1;' * 5000}mhi', 'hi'],
      'a bell and other C0 controls': ['a\x07\x08\x00b', 'ab'],
    };
    cases.forEach((name, io) {
      test('$name never throws and keeps the surrounding text', () {
        expect(_plain(io[0]), io[1].isEmpty ? isEmpty : [io[1]]);
      });
    });

    test('a huge parameter is not mistaken for a real code', () {
      final run = _run('$_esc[${'9' * 50};1mhi');
      expect(run.bold, isTrue);
      expect(run.fg, isNull);
    });

    test('a cut-off sequence does not eat the next line', () {
      expect(_plain('a$_esc[38;2;1\nb'), ['a', 'b']);
      expect(_plain('a$_esc[\r\nb'), ['a', 'b']);
      expect(_plain('a$_esc[38;2;1$_esc[31mb'), ['ab']);
    });

    test('unknown sequences do not change the style', () {
      final run = _run('${_sgr('31')}$_esc[2K$_esc[10;20H${_sgr('?25')}x');
      expect(run.fg, TerminalColors.ansi[1]);
    });

    test('random escape soup never throws or invents text', () {
      const alphabet = [
        _esc, _esc, '[', ']', ';', ':', '0', '1', '3', '8', '2', '5', '9', 'm',
        'H', '?', '\\', '\x07', '\n', '\r', 'a', ' ', '日', '─',
      ];
      final random = Random(7);
      for (var n = 0; n < 3000; n++) {
        final input = [
          for (var i = random.nextInt(40); i > 0; i--)
            alphabet[random.nextInt(alphabet.length)],
        ].join();
        final doc = parseAnsi(input);
        final visible = doc.lines.expand((l) => l).map((r) => r.text).join();
        expect(visible.length, lessThanOrEqualTo(input.length), reason: input);
        for (final line in doc.lines) {
          expect(line.every((r) => r.text.isNotEmpty), isTrue, reason: input);
        }
      }
    });
  });

  group('OSC and other strings', () {
    test('title terminated by BEL', () {
      expect(_plain('$_esc]0;my title\x07text'), ['text']);
    });

    test('title terminated by ST', () {
      expect(_plain('$_esc]2;my title$_esc\\text'), ['text']);
    });

    test('hyperlinks keep their label', () {
      expect(
        _plain('$_esc]8;;http://example.com\x07link$_esc]8;;\x07 after'),
        ['link after'],
      );
    });

    test('DCS and APC are stripped', () {
      expect(_plain('${_esc}Pq#0;2;0;0;0$_esc\\a${_esc}_Gi=1;x$_esc\\b'), ['ab']);
    });

    test('an unterminated one stops at the end of its line', () {
      expect(_plain('a$_esc]0;title\nb'), ['a', 'b']);
      expect(_plain('a$_esc]0;title'), ['a']);
    });

    test('an escape inside a string starts the next sequence', () {
      final run = _run('$_esc]0;title$_esc[31mx');
      expect(run.text, 'x');
      expect(run.fg, TerminalColors.ansi[1]);
    });
  });

  group('lines', () {
    test('CRLF, LF and mixed endings', () {
      expect(_plain('a\r\nb\r\nc'), ['a', 'b', 'c']);
      expect(_plain('a\nb\nc'), ['a', 'b', 'c']);
      expect(_plain('a\r\nb\nc\r\n'), ['a', 'b', 'c']);
    });

    test('a final line break does not add an empty line', () {
      expect(_plain('a\r\n'), ['a']);
      expect(_plain('a\r\n\r\n'), ['a', '']);
    });

    test('empty input has no lines; a lone break is one blank line', () {
      expect(parseAnsi('').lines, isEmpty);
      expect(parseAnsi('').columns, 0);
      expect(_plain('\n'), ['']);
      expect(_plain('${_sgr('0')}\r\n'), ['']);
      expect(_plain(_sgr('0')), isEmpty);
    });

    test('blank lines in the middle survive', () {
      expect(_plain('a\r\n\r\n\r\nb'), ['a', '', '', 'b']);
    });

    test('a lone CR redraws the line', () {
      expect(_plain('10%\r20%\r30%'), ['30%']);
      expect(_plain('abc\rxy'), ['xy']);
      expect(_plain('abc\r'), ['abc']);
      expect(_plain('abc\r\r\nd'), ['abc', 'd']);
      expect(_plain('a\rb\r\nc'), ['b', 'c']);
    });

    test('a tab becomes a single cell', () {
      expect(_plain('a\tb'), ['a b']);
    });
  });

  group('padding', () {
    test('trailing spaces on the default background are trimmed', () {
      expect(_plain('abc    \r\ndef  '), ['abc', 'def']);
    });

    test('inner and leading spaces are kept', () {
      expect(_plain('  a   b  '), ['  a   b']);
    });

    test('padding in a coloured foreground is still trimmed', () {
      final runs = parseAnsi('${_sgr('31')}abc   ${_sgr('0')}   ').lines.single;
      expect(runs, hasLength(1));
      expect(runs.single.text, 'abc');
    });

    test('background-coloured padding is kept; default padding after it is not', () {
      final runs = parseAnsi('${_sgr('44')}ab   ${_sgr('0')}   \r\n').lines.single;
      expect(runs, hasLength(1));
      expect(runs.single.text, 'ab   ');
      expect(runs.single.bg, TerminalColors.ansi[4]);
    });

    test('a padding-only line becomes an empty line, not a missing one', () {
      final lines = parseAnsi('   \r\nx').lines;
      expect(lines, hasLength(2));
      expect(lines.first, isEmpty);
    });

    test('underlined and struck padding is visible, so it is kept', () {
      expect(_plain('${_sgr('4')}a  '), ['a  ']);
      expect(_plain('${_sgr('9')}a  '), ['a  ']);
    });

    test('columns ignore the trimmed padding', () {
      expect(parseAnsi('ab      \r\nc').columns, 2);
    });
  });

  group('unicode', () {
    test('box drawing is untouched', () {
      const frame = '┌──┐\r\n│ab│\r\n└──┘';
      expect(_plain(frame), ['┌──┐', '│ab│', '└──┘']);
      expect(parseAnsi(frame).columns, 4);
    });

    test('CJK is untouched and counts two cells per glyph', () {
      expect(_plain('│日本語│'), ['│日本語│']);
      expect(parseAnsi('│日本語│').columns, 8);
    });

    test('astral characters stay whole', () {
      expect(_plain('a😀b'), ['a😀b']);
    });

    test('columns is the widest line', () {
      expect(parseAnsi('a\r\nabcd\r\nab').columns, 4);
    });
  });

  group('real herdr output', () {
    test('a captured line', () {
      final lines = parseAnsi('$_esc[0m$_esc[3m$_esc[38;2;118;118;118mtext$_esc[0m\r\n')
          .lines;
      expect(lines, hasLength(1));
      final run = lines.single.single;
      expect(run.text, 'text');
      expect(run.italic, isTrue);
      expect(run.fg, _rgb(118, 118, 118));
      expect(run.bold, isFalse);
    });

    test('padded, multi-style lines', () {
      const raw = '$_esc[0m$_esc[1m$_esc[38;2;94;234;212m● $_esc[0mready'
          '                    $_esc[0m\r\n'
          '$_esc[0m$_esc[2m└ $_esc[0m\r\n';
      final lines = parseAnsi(raw).lines;
      expect(lines, hasLength(2));
      expect(lines[0].map((r) => r.text), ['● ', 'ready']);
      expect(lines[0][0].bold, isTrue);
      expect(lines[0][0].fg, _rgb(94, 234, 212));
      expect(lines[1].single.text, '└');
      expect(lines[1].single.dim, isTrue);
    });
  });
}
