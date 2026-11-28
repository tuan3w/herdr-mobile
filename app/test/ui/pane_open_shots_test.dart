// Renders the first frame of opening an agent's terminal from the board, to
// PNGs for review: light and dark, 412x892 and 320x640 at text scale 1.6.
// Off by default; it writes files:
//
//   PANE_OPEN_SHOTS=1 flutter test --no-pub test/ui/pane_open_shots_test.dart
//
// Output: $PANE_OPEN_SHOTS_DIR (default /tmp/pane_open_shots)/<kind>-<theme>-<size>-<first|live>.png
//
// `first` is the page as it arrives (the transition's 260 ms are over) while the
// read has not come back, on a slow link; `live` is after it did. Kinds: `kept` (the agent's screen was open a while ago: its
// last tail is in memory) and `card` (only the board card's rows are known).
// The rows are invented (an agent session with colour); the link is slow
// because the read is held back, which the real radio does. The same file
// renders the "before" shots on the code without the pane tails.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pane_open_rig.dart';
import '../support/shot.dart';

const _sizes = [('412', Size(412, 892), 1.0), ('320', Size(320, 640), 1.6)];

/// An agent's screen: output with colour, a diff, a long path, then its input.
String _screen({String tail = ''}) {
  const esc = '\x1b';
  final rows = <String>[
    for (var i = 0; i < 24; i++)
      i % 6 == 0
          ? '$esc[2m  src/auth/session_store_$i.dart$esc[0m'
          : '  ${'processing token refresh and cookie jar'.substring(0, 18 + i % 20)}…',
    '$esc[1;36m● Update$esc[0m(lib/data/repositories/pane_tails.dart)',
    '  $esc[32m+  final Map<String, PaneTail> _tails = {};$esc[0m',
    '  $esc[31m-  final Map<String, String> _texts = {};$esc[0m',
    '  $esc[32m✓$esc[0m 12 tests passed',
    '  Edited /home/someone/projects/herdr-mobile/app/lib/ui/features/pane/pane_screen.dart',
    if (tail.isNotEmpty) tail,
    '$esc[2m╭──────────────────────────────────────────╮$esc[0m',
    '$esc[2m│$esc[0m > ',
    '$esc[2m╰──────────────────────────────────────────╯$esc[0m',
  ];
  return rows.join('\n');
}

void main() {
  if (Platform.environment['PANE_OPEN_SHOTS'] == null) {
    test('pane open shots are off (set PANE_OPEN_SHOTS=1)', () {}, skip: 'set PANE_OPEN_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['PANE_OPEN_SHOTS_DIR'] ?? '/tmp/pane_open_shots';
  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  for (final kind in const ['kept', 'card']) {
    for (final dark in const [false, true]) {
      for (final (name, size, scale) in _sizes) {
        final id = '$kind-${dark ? 'dark' : 'light'}-$name';
        testWidgets(id, (tester) async {
          final rig = await OpenRig.start(
            tester,
            brightness: dark ? Brightness.dark : Brightness.light,
            size: size * phoneDpr,
            ratio: phoneDpr,
            textScale: scale,
          );
          rig.herdr.paneText = _screen();
          if (kind == 'kept') {
            // Opened a while ago: its tail is in memory.
            await tester.tap(rig.row);
            await rig.elapse(const Duration(milliseconds: 600), step: const Duration(milliseconds: 100));
            await rig.back();
          } else {
            // A card of the pane was on screen a moment ago.
            final card = rig.previews.watch(openMachine.id, openPane);
            await rig.elapse(const Duration(seconds: 2));
            card.release();
          }
          // Twelve seconds on, a slow link: the read does not come back.
          rig.clock.now = rig.clock.now.add(const Duration(seconds: 12));
          rig.herdr
            ..gate = Completer<void>()
            ..paneText = _screen(tail: '  \x1b[32m✓\x1b[0m pushed to origin/main');
          await tester.tap(rig.row);
          await rig.firstFrame();
          // The page has come in (the transition is 260 ms) and the read, on a
          // slow link, has not: what the person looks at while they wait.
          await rig.elapse(const Duration(milliseconds: 300), step: const Duration(milliseconds: 50));
          await rig.shoot('$out/$id-first.png');

          rig.herdr.gate!.complete();
          await rig.elapse(const Duration(milliseconds: 700), step: const Duration(milliseconds: 100));
          await rig.shoot('$out/$id-live.png');
          await rig.close();
        });
      }
    }
  }
}
