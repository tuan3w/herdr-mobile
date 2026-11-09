// Renders what herdr's own metadata adds to PNGs for review, with worst-case
// data: the board's meta line (a hook's state label, pane tokens and
// workspace tokens of 80 chars with emoji, a hook's agent name and title), a
// machine screen with a pane herdr could not restore, and that pane's screen
// (the reason, Close pane, the veil, the composer off). Light and dark, 412
// and 320 wide, text scale 1, 1.3 and 1.6. Off by default; it writes files:
//
//   METADATA_SHOTS=1 flutter test test/ui/metadata_shots_test.dart
//
// Output: $METADATA_SHOTS_DIR (default /tmp/metadata_shots)/<case>.png
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/pane_preview.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/ui/features/machines/machine_screen.dart';
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../support/shot.dart';
import '../support/worktree_fixtures.dart';
import 'board_support.dart';

const _m = 'm1';
const _cwd = '/home/dev/src/payments-platform-monorepo';
const _restoreError = 'Saved directory is unavailable. Restore the directory and restart this session.';

Map<String, dynamic> _snapshot() => {
  'version': '0.9.5',
  'workspaces': [
    {
      ...wireWorkspace('w1', label: 'payments', status: 'blocked'),
      'pane_count': 3,
      'tokens': {
        // 80 chars each, herdr's cap; keys out of order on purpose.
        'stage': '🤖 building 24/165 ↻2 · ledger-posting-engine-eu-west · retrying flaky tests now',
        'branch': 'feature/PAY-1234-migrate-the-ledger-to-the-new-posting-engine-in-eu-west-prod',
      },
    },
    {...wireWorkspace('w2', label: 'Đồng bộ dữ liệu', number: 2), 'pane_count': 1},
  ],
  'tabs': [wireTab('w1:t1', 'w1'), wireTab('w2:t1', 'w2')],
  'panes': [
    {
      ...wirePaneIn('w1:p1', 'w1', 'w1:t1', cwd: _cwd, agent: 'claude', status: 'blocked'),
      'terminal_title_stripped': 'Fix the Hà Nội locale bug in the parser',
      'state_labels': {'blocked': '⏸ Waiting for approval: rm -rf build/ && flutter clean && flutter pub get'},
      'tokens': {'ci': '🧪 142/165 passing · 3 flaky · test_ledger_posting_engine_eu_west_rounding'},
    },
    {
      ...wirePaneIn('w1:p2', 'w1', 'w1:t1', cwd: _cwd, agent: 'codex', status: 'working'),
      'terminal_title_stripped': 'codex',
      'title': 'Migrate the ledger to the new posting engine, step 7 of 12: rounding rules',
      'display_agent': 'Codex (gpt-5.5 high)',
      'state_labels': {'working': '⚙︎ Running cargo test --workspace --all-features (3m12s)'},
    },
    {
      ...wirePaneIn('w1:p3', 'w1', 'w1:t1', cwd: _cwd, agent: 'claude', status: 'idle'),
      'terminal_title_stripped': 'Review the migration plan',
    },
    {
      ...wirePaneIn('w2:p1', 'w2', 'w2:t1', cwd: '/home/dev/src/gone-folder'),
      'terminal_title_stripped': 'zsh',
      'restore_error': _restoreError,
    },
  ],
};

void main() {
  if (Platform.environment['METADATA_SHOTS'] == null) {
    test('metadata shots are off (set METADATA_SHOTS=1)', () {}, skip: 'set METADATA_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['METADATA_SHOTS_DIR'] ?? '/tmp/metadata_shots';

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      for (var j = 0; j < 30; j++) {
        await Future<void>.value();
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> shot(
    WidgetTester tester,
    String name,
    Widget Function(BoardHarness h) home, {
    Brightness brightness = Brightness.light,
    Size size = phone,
    double scale = 1,
  }) async {
    final h = await BoardHarness.create([
      (profile: MachineProfile(id: _m, label: 'build-box', host: 'h', username: 'u'), snapshot: _snapshot()),
    ]);
    h.previews.set(
      '$_m/w1:p1',
      ['Bash command', '  rm -rf build/ && flutter clean', 'Do you want to proceed?', '❯ 1. Yes', '  2. No'],
      prompt: PromptInfo(
        question: 'Do you want to proceed?',
        subject: 'rm -rf build/ && flutter clean',
        replies: [
          QuickReply(label: '1. Yes', keys: const ['1']),
          QuickReply(label: '2. No', keys: const ['2']),
        ],
      ),
    );
    h.previews.set('$_m/w1:p2', ['running 412 tests', 'test ledger::rounding ... ok']);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await shoot(
      tester,
      home(h),
      '$out/$name.png',
      brightness: brightness,
      size: size,
      wrap: (app) => MultiProvider(providers: h.providers, child: app),
      pump: settle,
    );
    expect(tester.takeException(), isNull, reason: name);
    await tester.pumpWidget(const SizedBox());
    h.dispose();
  }

  Widget board(BoardHarness _) => const HomeShell();
  Widget machine(BoardHarness h) => MachineScreen(machine: h.fleet.connection(_m)!);
  Widget pane(BoardHarness _) => PaneScreen(agent: PaneAgent(_m, 'w2:p1'));

  for (final (name, home) in [('board', board), ('machine', machine), ('pane-unrestored', pane)]) {
    testWidgets('$name light 412', (t) => shot(t, '$name-light-412', home));
    testWidgets('$name dark 412', (t) => shot(t, '$name-dark-412', home, brightness: Brightness.dark));
    testWidgets('$name light 412 x1.3', (t) => shot(t, '$name-light-412-x1.3', home, scale: 1.3));
    testWidgets(
      '$name dark 320 x1.6',
      (t) => shot(t, '$name-dark-320-x1.6', home, brightness: Brightness.dark, size: const Size(320, 640), scale: 1.6),
    );
  }
}
