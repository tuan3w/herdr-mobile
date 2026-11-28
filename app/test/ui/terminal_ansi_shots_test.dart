// Renders a dark terminal full of the colours TUIs paint with, to judge the
// render-time contrast guard by eye (docs/DESIGN.md, "Colour roles"). Off by
// default; it writes files:
//
//   TERMINAL_ANSI_SHOTS=1 TERMINAL_ANSI_SHOTS_TAG=after flutter test test/ui/terminal_ansi_shots_test.dart
//
// TERMINAL_ANSI_SHOTS_DIR picks the folder (default /tmp/terminal_ansi_shots),
// TERMINAL_ANSI_SHOTS_TAG prefixes the names (before / after a change).
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/render/terminal/terminal_view.dart';

import '../support/shot.dart';

const _e = '\x1b';

String _sgr(String codes, String text) => '$_e[${codes}m$text$_e[0m';

/// What a TUI really paints: every ANSI foreground, a status line on black,
/// dim black, a black frame and block, the 232-255 grey ramp, truecolour near
/// black, a hidden word, black text on red, reverse video.
final _screen = [
  _sgr('1', 'foreground 0-7 / 8-15'),
  [for (var i = 0; i < 8; i++) _sgr('${30 + i}', 'c$i ')].join(),
  [for (var i = 0; i < 8; i++) _sgr('${90 + i}', 'c${8 + i}${i < 2 ? ' ' : ''} ')].join(),
  '',
  _sgr('1', 'status line (black bg, default text)'),
  _sgr('40', '  main  ~/work/app  claude  ready        '),
  _sgr('40;37', '  white on black                        '),
  '',
  _sgr('1', 'dim and black'),
  '${_sgr('2;30', 'dim black text')}  ${_sgr('2', 'dim default')}  ${_sgr('2;31', 'dim red')}',
  '${_sgr('30', 'black text')}  ${_sgr('30;40', 'black on black')}  ${_sgr('30;41', 'black on red')}',
  '${_sgr('30;7', ' reverse black ')}  ${_sgr('7', ' reverse default ')}',
  '',
  _sgr('1', 'shapes (not text)'),
  _sgr('30', '┌──────────┐ ████ ▓▓▓▓ ░░░░'),
  _sgr('30', '│ ') + _sgr('30', 'in frame') + _sgr('30', ' │ ') + _sgr('90', '▀▀▀▀'),
  _sgr('30', '└──────────┘'),
  '',
  _sgr('1', '256 greys 232-255 as text'),
  [for (var i = 232; i < 244; i++) _sgr('38;5;$i', '$i ')].join(),
  [for (var i = 244; i < 256; i++) _sgr('38;5;$i', '$i ')].join(),
  '',
  _sgr('1', 'truecolour near the page'),
  '${_sgr('38;2;20;22;30', 'rgb 20 22 30')}  ${_sgr('38;2;40;48;64', 'rgb 40 48 64')}  ${_sgr('38;2;90;60;60', 'rgb 90 60 60')}',
].join('\r\n');

void main() {
  if (Platform.environment['TERMINAL_ANSI_SHOTS'] == null) {
    test('terminal ANSI shots are off (set TERMINAL_ANSI_SHOTS=1)', () {}, skip: 'set TERMINAL_ANSI_SHOTS=1');
    return;
  }
  final out = Platform.environment['TERMINAL_ANSI_SHOTS_DIR'] ?? '/tmp/terminal_ansi_shots';
  final tag = Platform.environment['TERMINAL_ANSI_SHOTS_TAG'] ?? 'shot';
  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  const sizes = {'412': Size(412, 892), '320': Size(320, 640)};
  // (name, app brightness, the terminal drawn: dark on either theme, or the
  // paper one on the light app).
  for (final (name, brightness, dark) in [
    ('lightapp_darkterm', Brightness.light, true),
    ('darkapp_darkterm', Brightness.dark, true),
    ('lightapp_paperterm', Brightness.light, false),
  ]) {
    for (final MapEntry(key: w, value: size) in sizes.entries) {
      testWidgets('$tag $name $w', (tester) async {
        final theme = dark
            ? (brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(terminal: TerminalPalette.dark))
            : AppTheme.light();
        await shoot(
          tester,
          Theme(
            data: theme,
            child: Scaffold(
              backgroundColor: theme.extension<TerminalPalette>()!.background,
              body: SafeArea(child: TerminalView(text: _screen, fontSize: 12.5)),
            ),
          ),
          '$out/${tag}_${name}_$w.png',
          brightness: brightness,
          size: size,
        );
      });
    }
  }
}
