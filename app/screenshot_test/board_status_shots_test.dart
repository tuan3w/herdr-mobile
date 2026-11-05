// Renders the board (status sections, rows, one decision card) to PNGs for
// review. Two fleets:
//
//  * `demo`: the demo fleet with payments-api's main checkout and three
//    worktrees (branches read from `worktree.list`).
//  * `owner`: the owner's board that 0.1.47's project grouping and Cards
//    density failed on: two machines, `fatman` and `tuannd12`, nothing
//    working, every agent idle, ages from 12 minutes to days.
//
// Light and dark at 412 dp, light at 320 dp with text 1.6, and tall frames that
// show the whole board. Not part of `flutter test` (the folder is
// `screenshot_test`):
//
//   BOARD_SHOTS_DIR=/tmp/board_shots flutter test screenshot_test/board_status_shots_test.dart
//
// Output: $BOARD_SHOTS_DIR (default /tmp/board_shots)/<case>-<tone>-<w>-x<scale>[-tall].png
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:herdr_mobile/ui/support/step_clock.dart';
import 'package:provider/provider.dart';

import '../test/support/shot.dart';
import '../test/ui/board_support.dart';
import '../test/ui/ui_harness.dart' show snapshotWith;
import 'demo_fleet.dart';

/// One agent of the owner's board: its pane, folder, title, and how long ago
/// it went idle (null: idle since before the app looked, no time known).
typedef _Agent = ({String id, String ws, String agent, String title, Duration? idle});

const _fatmanHome = '/home/fatman/workspace';
const _fatmanTrees = '/home/fatman/.herdr/worktrees';

/// fatman: herdr-mobile with two linked worktrees, and financetoolkit with a
/// research worktree, both grouped by herdr (so their branches are read).
const _fatmanWorkspaces = [
  (id: 'f1', label: 'herdr-mobile', path: '$_fatmanHome/herdr-mobile', repo: 'herdr-mobile', linked: false),
  (
    id: 'f2',
    label: 'fix-white-toast',
    path: '$_fatmanTrees/herdr-mobile/fix-white-toast',
    repo: 'herdr-mobile',
    linked: true,
  ),
  (id: 'f3', label: 'app-icons', path: '$_fatmanTrees/herdr-mobile/app-icons', repo: 'herdr-mobile', linked: true),
  (id: 'f4', label: 'financetoolkit', path: '$_fatmanHome/financetoolkit', repo: 'financetoolkit', linked: false),
  (
    id: 'f5',
    label: 'study-narrow-down',
    path: '$_fatmanTrees/financetoolkit/study-narrow-down',
    repo: 'financetoolkit',
    linked: true,
  ),
];

const _branches = {
  '$_fatmanHome/herdr-mobile': 'main',
  '$_fatmanTrees/herdr-mobile/fix-white-toast': 'fix/white-toast-snackbar',
  '$_fatmanTrees/herdr-mobile/app-icons': 'feat/app-icons-animations',
  '$_fatmanHome/financetoolkit': 'main',
  '$_fatmanTrees/financetoolkit/study-narrow-down': 'research/financetoolkit-study-narrow-down',
};

const _fatman = <_Agent>[
  (id: 'f5:p1', ws: 'f5', agent: 'omp', title: 'deep dive and learn', idle: Duration(minutes: 12)),
  (id: 'f2:p1', ws: 'f2', agent: 'omp', title: 'Fix white toast SnackBar theming', idle: Duration(days: 3, hours: 2)),
  (
    id: 'f3:p1',
    ws: 'f3',
    agent: 'omp',
    title: 'Redesign app icons and add animations',
    idle: Duration(days: 3, hours: 1),
  ),
  (id: 'f1:p1', ws: 'f1', agent: 'claude', title: '', idle: null),
  (id: 'f1:p2', ws: 'f1', agent: 'claude', title: 'emil-flutter-quality-review', idle: Duration(hours: 1, minutes: 42)),
  (id: 'f1:p3', ws: 'f1', agent: 'omp', title: 'herdr-mobile', idle: Duration(hours: 21, minutes: 20)),
  (id: 'f1:p4', ws: 'f1', agent: 'omp', title: 'Access phone via wireless debugging', idle: Duration(days: 6)),
];

const _tuannd12 = <_Agent>[
  (id: 't1:p1', ws: 't1', agent: 'omp', title: 'Tui calm and queue', idle: Duration(hours: 23, minutes: 31)),
  (
    id: 't1:p2',
    ws: 't1',
    agent: 'omp',
    title: 'we about make slide to teach others about using ai, one thing i want to show is agents in parallel',
    idle: Duration(minutes: 12, seconds: 30),
  ),
];

Map<String, dynamic> _snapshot(
  List<_Agent> agents,
  List<({String id, String label, String path, String? repo, bool linked})> workspaces,
) {
  final snapshot = snapshotWith(
    [for (final a in agents) (id: a.id, ws: a.ws, agent: a.agent, status: a.idle == null ? 'idle' : 'working')],
    workspaces: [for (final w in workspaces) (id: w.id, label: w.label)],
    title: (id) => agents.firstWhere((a) => a.id == id).title,
    cwd: (id) {
      final ws = agents.firstWhere((a) => a.id == id).ws;
      return workspaces.firstWhere((w) => w.id == ws).path;
    },
  );
  for (final w in snapshot['workspaces'] as List) {
    final ws = w as Map<String, dynamic>;
    final spec = workspaces.firstWhere((s) => s.id == ws['workspace_id']);
    final repo = spec.repo;
    if (repo == null) continue;
    final root = workspaces.firstWhere((s) => s.repo == repo && !s.linked).path;
    ws['worktree'] = {
      'checkout_path': spec.path,
      'is_linked_worktree': spec.linked,
      'repo_key': '$root/.git',
      'repo_name': repo,
      'repo_root': root,
    };
  }
  return snapshot;
}

/// The owner's two machines, every agent seen going idle as long ago as the
/// owner's board said.
Future<BoardHarness> _ownerBoard() async {
  final h = await BoardHarness.create([
    (
      profile: const MachineProfile(id: 'f', label: 'fatman', host: 'fatman.local', username: 'fatman'),
      snapshot: _snapshot(_fatman, _fatmanWorkspaces),
    ),
    (
      profile: const MachineProfile(id: 't', label: 'tuannd12', host: 'tuannd12.local', username: 'tuannd'),
      snapshot: _snapshot(_tuannd12, const [
        (id: 't1', label: 'herdr-mobile', path: '/home/tuannd/herdr-mobile', repo: null, linked: false),
      ]),
    ),
  ]);
  h.transports['f']!.answers['worktree.list'] = {
    'type': 'worktree_list',
    'worktrees': [
      for (final w in _fatmanWorkspaces)
        {'path': w.path, 'branch': _branches[w.path], 'label': w.label, 'is_linked_worktree': w.linked},
    ],
  };
  return h;
}

/// Moves every timed agent of the owner's board to idle, oldest first, each
/// seen going idle its time ago.
Future<void> _age(WidgetTester tester, BoardHarness h) async {
  final all = [for (final a in _fatman) ('f', a), for (final a in _tuannd12) ('t', a)]
    ..removeWhere((e) => e.$2.idle == null)
    ..sort((a, b) => b.$2.idle!.compareTo(a.$2.idle!));
  for (final (machine, a) in all) {
    final transport = h.transports[machine]!;
    h.observedAgo = a.idle!;
    for (final p in transport.snapshot['panes'] as List) {
      final pane = p as Map<String, dynamic>;
      if (pane['pane_id'] == a.id) pane['agent_status'] = 'idle';
    }
    transport.emit({'event': 'pane.agent_status_changed'});
    await tester.pump(const Duration(milliseconds: 350));
  }
  h.observedAgo = Duration.zero;
  for (final c in h.fleet.connections) {
    unawaited(c.refresh());
  }
  await tester.pump(const Duration(milliseconds: 350));
  StepClock.minute.steps.value++;
  await tester.pump();
}

void main() {
  final out = Directory(Platform.environment['BOARD_SHOTS_DIR'] ?? '/tmp/board_shots');

  setUpAll(() async {
    await loadAppFonts();
    out.createSync(recursive: true);
  });

  // (tone, width, height, scale, suffix): the phone frames, then the whole
  // board in one tall frame.
  const frames = [
    (Brightness.light, 412.0, 892.0, 1.0, ''),
    (Brightness.dark, 412.0, 892.0, 1.0, ''),
    (Brightness.light, 320.0, 640.0, 1.6, ''),
    (Brightness.light, 412.0, 1900.0, 1.0, '-tall'),
    (Brightness.dark, 412.0, 1900.0, 1.0, '-tall'),
    (Brightness.light, 320.0, 2600.0, 1.6, '-tall'),
  ];

  // The agents moved to their states under the board's eyes, so it holds
  // every row in view; the person opening the app looks afresh.
  Future<void> settleShot(WidgetTester t) async {
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  for (final (b, w, height, scale, suffix) in frames) {
    final name = '${b.name}-${w.toInt()}-x$scale$suffix';

    testWidgets('demo $name', (tester) async {
      final h = await DemoFleet.create(timed: true, worktrees: true);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await shoot(
        tester,
        const HomeShell(),
        '${out.path}/demo-$name.png',
        brightness: b,
        size: Size(w, height),
        imageScale: 2,
        wrap: demoProviders(h),
        pump: (t) async {
          await h.ageStatuses(t);
          await settleShot(t);
        },
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('owner $name', (tester) async {
      final h = await _ownerBoard();
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await shoot(
        tester,
        const HomeShell(),
        '${out.path}/owner-$name.png',
        brightness: b,
        size: Size(w, suffix.isEmpty ? height : 1200),
        imageScale: 2,
        wrap: (app) => MultiProvider(providers: h.providers, child: app),
        pump: (t) async {
          await _age(t, h);
          await settleShot(t);
        },
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });
  }

  // The owner's board with the idle fold open: every agent, newest first.
  testWidgets('owner light-412-x1.0-open', (tester) async {
    final h = await _ownerBoard();
    await shoot(
      tester,
      const HomeShell(),
      '${out.path}/owner-light-412-x1.0-open.png',
      size: const Size(412, 1200),
      imageScale: 2,
      wrap: (app) => MultiProvider(providers: h.providers, child: app),
      pump: (t) async {
        await _age(t, h);
        await settleShot(t);
        await t.tap(find.textContaining('more idle'));
        await settleShot(t);
      },
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    h.dispose();
  });
}
