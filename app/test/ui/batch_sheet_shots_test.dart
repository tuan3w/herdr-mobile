// Renders the batch confirm sheet in Japanese to PNGs for review: Stop,
// Message and Close, light and dark, 412x892 and 320x640, text scale 1 and
// 1.6. Off by default; it writes files:
//
//   BATCH_SHEET_SHOTS=1 flutter test test/ui/batch_sheet_shots_test.dart
//
// Output: $BATCH_SHEET_SHOTS_DIR (default /tmp/batch_sheet_shots)/
// <action>-<light|dark>-<w>x<h>-x<scale>.png
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/ui/features/agents/agent_card.dart';
import 'package:herdr_mobile/ui/features/agents/agent_session_rows.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../support/shot.dart' show loadAppFonts, shoot;
import 'board_support.dart';
import 'ui_harness.dart';

Pane _pane(int i, String status) => (id: 'w1:p$i', ws: 'w1', agent: 'claude', status: status);

/// Three working, two waiting, two done, three idle: every batch action has
/// something to run and something to skip.
List<Pane> _ten() => [
  for (var i = 1; i <= 3; i++) _pane(i, 'working'),
  for (var i = 4; i <= 5; i++) _pane(i, 'blocked'),
  for (var i = 6; i <= 7; i++) _pane(i, 'done'),
  for (var i = 8; i <= 10; i++) _pane(i, 'idle'),
];

String _title(String paneId) => 'task ${paneId.split('p').last}';

({MachineProfile profile, Map<String, dynamic> snapshot}) _machine(String id, List<Pane> panes) => (
  profile: MachineProfile(id: id, label: 'studio-mac', host: '$id.example', username: 'dev'),
  snapshot: snapshotWith(panes, title: _title),
);

Finder _row(String title) => find.descendant(
  of: find.byWidgetPredicate((w) => w is AgentCard || w is AgentCompactRow || w is AgentSessionRow),
  matching: find.text(title),
);

Future<void> _settle(WidgetTester tester, [int steps = 6]) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Long-presses a blocked agent (first on the board) and picks every agent,
/// so each action has a run group and a skipped group.
Future<void> _pickAll(WidgetTester tester) async {
  await tester.scrollUntilVisible(_row('task 4'), 200, scrollable: find.byType(Scrollable).first);
  await tester.longPress(_row('task 4'));
  await _settle(tester);
  await tester.tap(find.text('すべて'));
  await _settle(tester);
}

void main() {
  if (Platform.environment['BATCH_SHEET_SHOTS'] != '1') {
    test('batch sheet shots are off (set BATCH_SHEET_SHOTS=1)', () {}, skip: 'set BATCH_SHEET_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['BATCH_SHEET_SHOTS_DIR'] ?? '/tmp/batch_sheet_shots';

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  const cases = <({String action, String button})>[
    (action: 'stop', button: '停止'),
    (action: 'message', button: 'メッセージ'),
    (action: 'close', button: '閉じる'),
  ];
  for (final (:action, :button) in cases) {
    for (final brightness in Brightness.values) {
      for (final size in [const Size(412, 892), const Size(320, 640)]) {
        for (final scale in [1.0, 1.6]) {
          testWidgets('Japanese $action sheet, ${brightness.name}, ${size.width.toInt()}, $scale', (tester) async {
            final h = await BoardHarness.create([_machine('a', _ten())]);
            await shoot(
              tester,
              const HomeShell(),
              '$out/$action-${brightness.name}-${size.width.toInt()}x${size.height.toInt()}-x$scale.png',
              brightness: brightness,
              locale: const Locale('ja'),
              size: size,
              textScale: scale,
              wrap: (app) => MultiProvider(providers: h.providers, child: app),
              pump: (tester) async {
                await _pickAll(tester);
                await tester.tap(find.text(button));
                await _settle(tester);
                if (action == 'message') {
                  await tester.enterText(find.byType(TextField), 'テストを再実行して結果を教えてください');
                  await _settle(tester);
                }
              },
            );
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
            h.dispose();
          });
        }
      }
    }
  }
}
