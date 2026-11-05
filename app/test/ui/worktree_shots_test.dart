// Renders the machine screen (repo -> checkouts -> agents) and the start form's
// Checkout row to PNGs for review, with worst-case data: a 40-character repo
// name, 12 checkouts, a 60-character branch, one checkout with 31 panes (past
// the `Show all` cap), a blocked agent in a collapsed repo, an offline machine,
// text scale 1 and 2, light and dark, 412 and 320 wide, plus the demo fleet's
// repo for the release still (demo-repo-light-412.png). Off by default; it
// writes files:
//
//   WORKTREE_SHOTS=1 flutter test test/ui/worktree_shots_test.dart
//
// Output: $WORKTREE_SHOTS_DIR (default /tmp/worktree_shots)/<case>.png
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/ui/features/create/new_agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/create/checkout_field.dart';
import 'package:herdr_mobile/ui/features/create/session_prefill.dart';
import 'package:herdr_mobile/ui/features/machines/machine_screen.dart';
import 'package:provider/provider.dart';

import '../../screenshot_test/demo_fleet.dart';
import '../support/create_harness.dart';
import '../support/shot.dart';
import '../support/worktree_fixtures.dart';
import 'ui_harness.dart';

const _repo1 = 'payments-platform-monorepo-eu-west-prod1';
const _root1 = '/srv/src/$_repo1';
const _root2 = '/srv/src/api-gateway';

String _wt(String repo, String name) => '/home/dev/.herdr/worktrees/$repo/$name';

Map<String, dynamic> _worktree(String key, String name, String root, String path, bool linked) => {
  'checkout_path': path,
  'is_linked_worktree': linked,
  'repo_key': '$root/.git',
  'repo_name': key,
  'repo_root': root,
};

final _longBranch = 'feature/PAY-1234-migrate-the-ledger-to-the-new-posting-engine'.substring(0, 60);

/// Repo one: a primary and 11 linked checkouts (the third holds 31 agents).
/// Repo two: a primary and a linked one with a blocked agent. Then Phone
/// sessions with one session in a checkout and one in no checkout.
Map<String, dynamic> _snapshot() {
  final workspaces = <Map<String, dynamic>>[];
  final tabs = <Map<String, dynamic>>[];
  final panes = <Map<String, dynamic>>[];
  final names = [
    'worktree-lucky-cloud-848c',
    'worktree-quiet-stone-dc35',
    'worktree-brave-river-a500',
    'Đồng-bộ-dữ-liệu-người-dùng',
    'worktree-proud-harbor-91ef',
    'worktree-calm-meadow-0b7d',
    'worktree-swift-pine-c3a1',
    'worktree-bold-ember-7742',
    'worktree-gentle-ridge-5e09',
    'worktree-keen-willow-d81c',
    'worktree-lively-brook-2fa6',
  ];
  void ws(String id, Map<String, dynamic>? worktree, {String? label}) {
    workspaces.add(wireWorkspace(id, worktree: worktree, label: label ?? id, number: workspaces.length + 1));
    tabs.add(wireTab('$id:t1', id));
  }

  void pane(String id, String ws, String cwd, {String? agent, String status = 'idle', String? title}) {
    panes.add({
      ...wirePaneIn(id, ws, '$ws:t1', cwd: cwd, agent: agent, status: status),
      'terminal_title_stripped': title ?? 'Task for $id',
    });
  }

  ws('w1', _worktree(_repo1, 'main', _root1, _root1, false), label: _repo1);
  pane('w1:p1', 'w1', _root1, agent: 'claude', status: 'idle', title: 'Review the ledger migration plan');
  for (var i = 0; i < names.length; i++) {
    final id = 'w${i + 2}';
    ws(id, _worktree(_repo1, names[i], _root1, _wt(_repo1, names[i]), true), label: names[i]);
    final n = i == 2 ? 31 : 1;
    for (var k = 0; k < n; k++) {
      pane(
        '$id:p$k',
        id,
        _wt(_repo1, names[i]),
        agent: i % 3 == 0 ? 'omp' : 'claude',
        status: k % 4 == 0 ? 'working' : 'idle',
      );
    }
  }
  ws('w20', _worktree('api-gateway', 'main', _root2, _root2, false), label: 'api-gateway');
  pane('w20:p1', 'w20', _root2, agent: 'omp', status: 'working');
  ws(
    'w21',
    _worktree('api-gateway', 'fix-rate-limit', _root2, _wt('api-gateway', 'fix-rate-limit'), true),
    label: 'fix-rate-limit',
  );
  pane(
    'w21:p1',
    'w21',
    _wt('api-gateway', 'fix-rate-limit'),
    agent: 'claude',
    status: 'blocked',
    title: 'Allow: rm -rf build/ ?',
  );
  ws('w22', null, label: 'Phone sessions');
  pane(
    'w22:p1',
    'w22',
    '${_wt(_repo1, names[1])}/app',
    agent: 'omp',
    status: 'working',
    title: 'Fix the flaky retry test',
  );
  pane('w22:p2', 'w22', '/tmp/scratch', agent: 'omp', status: 'done', title: 'Summarise the incident notes');
  return {'version': '0.9.3', 'workspaces': workspaces, 'tabs': tabs, 'panes': panes};
}

void main() {
  if (Platform.environment['WORKTREE_SHOTS'] == null) {
    test('worktree shots are off (set WORKTREE_SHOTS=1)', () {}, skip: 'set WORKTREE_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['WORKTREE_SHOTS_DIR'] ?? '/tmp/worktree_shots';

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

  Future<void> machineShot(
    WidgetTester tester,
    String name, {
    Brightness brightness = Brightness.light,
    Size size = phone,
    double scale = 1,
    bool offline = false,
    Future<void> Function(WidgetTester tester)? after,
  }) async {
    final h = await UiHarness.create([(profile: profileOf('a', 'build-box'), snapshot: _snapshot())]);
    final stub = h.transports['a']!;
    stub.answers['worktree.list'] = {
      'type': 'worktree_list',
      'worktrees': [
        {'path': _root1, 'branch': 'main', 'label': 'x', 'is_linked_worktree': false},
        {
          'path': _wt(_repo1, 'worktree-quiet-stone-dc35'),
          'branch': _longBranch,
          'label': 'x',
          'is_linked_worktree': true,
        },
        {
          'path': _wt(_repo1, 'worktree-lucky-cloud-848c'),
          'branch': 'autoresearch/ci-speed',
          'label': 'x',
          'is_linked_worktree': true,
        },
        {'path': _root2, 'branch': 'main', 'label': 'x', 'is_linked_worktree': false},
      ],
    };
    final machine = h.fleet.connection('a')!;
    machine.setKeeperPanes({'w22:p1': 'a/k1'});
    if (offline) machine.goOffline();
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await shoot(
      tester,
      MachineScreen(machine: machine),
      '$out/$name.png',
      brightness: brightness,
      size: size,
      wrap: (app) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: h.machines),
          ChangeNotifierProvider.value(value: h.fleet),
          attentionSetProvider(),
        ],
        child: app,
      ),
      pump: (t) async {
        await settle(t);
        if (after != null) await after(t);
      },
    );
    expect(tester.takeException(), isNull, reason: name);
    await tester.pumpWidget(const SizedBox());
    h.dispose();
  }

  testWidgets('machine: worst case, light 412', (tester) => machineShot(tester, 'machine-light-412'));
  testWidgets(
    'machine: worst case, dark 320 at 2x',
    (tester) =>
        machineShot(tester, 'machine-dark-320-2x', brightness: Brightness.dark, size: const Size(320, 640), scale: 2),
  );
  testWidgets(
    'machine: the 31-pane checkout past its cap',
    (tester) => machineShot(
      tester,
      'machine-show-all-light-412',
      after: (t) async {
        final f = find.text('Show all 31 panes');
        await t.ensureVisible(f);
        await settle(t);
      },
    ),
  );
  testWidgets(
    'machine: a blocked agent in a collapsed repo',
    (tester) => machineShot(
      tester,
      'machine-collapsed-blocked-dark-412',
      brightness: Brightness.dark,
      after: (t) async {
        await t.scrollUntilVisible(find.text('api-gateway'), 400, scrollable: find.byType(Scrollable).first);
        await t.tap(find.text('api-gateway').first);
        await settle(t);
        final f = find.text('Phone sessions');
        await t.ensureVisible(f);
        await settle(t);
      },
    ),
  );
  testWidgets(
    'machine: offline dims everything and turns the buttons off',
    (tester) => machineShot(tester, 'machine-offline-dark-412', brightness: Brightness.dark, offline: true),
  );

  // The release still: the invented demo fleet's studio-mac, where payments-api
  // has a main checkout and three worktrees (no private names).
  testWidgets('machine: the demo fleet\'s repo with its worktrees (release still)', (tester) async {
    final h = await DemoFleet.create(timed: true, worktrees: true);
    await shoot(
      tester,
      MachineScreen(machine: h.fleet.connection('a')!),
      '$out/demo-repo-light-412.png',
      size: const Size(412, 800),
      imageScale: 2,
      wrap: demoProviders(h),
      pump: (t) async {
        await h.ageStatuses(t);
        await settle(t);
      },
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    h.dispose();
  });

  Future<void> formShot(
    WidgetTester tester,
    String name, {
    Brightness brightness = Brightness.light,
    Size size = phone,
    double scale = 1,
  }) async {
    final h = await CreateHarness.create([
      (profile: profileOf('a', 'build-box'), snapshot: snapshotWith(const [])),
    ], waitOnline: false);
    h.stubs['a']!.on['worktree.list'] = (_) => {
      'type': 'worktree_list',
      'worktrees': [
        {'path': _root1, 'label': 'x', 'is_linked_worktree': false, 'branch': 'main', 'open_workspace_id': 'w1'},
        {
          'path': _wt(_repo1, 'worktree-quiet-stone-dc35'),
          'label': 'x',
          'is_linked_worktree': true,
          'branch': _longBranch,
          'open_workspace_id': 'w3',
        },
        {'path': '/tmp/proto-mermaid', 'label': 'x', 'is_linked_worktree': true},
        for (var i = 0; i < 9; i++)
          {'path': _wt(_repo1, 'worktree-extra-$i'), 'label': 'x', 'is_linked_worktree': true, 'branch': 'extra/$i'},
      ],
    };
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await shoot(
      tester,
      const NewAgentSessionScreen(
        machineId: 'a',
        prefill: SessionPrefill(machineId: 'a', folder: _root1),
      ),
      '$out/$name.png',
      brightness: brightness,
      size: size,
      wrap: (app) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: h.machines),
          ChangeNotifierProvider.value(value: h.fleet),
          ListenableProvider<AgentSessions>.value(value: h.agents),
          ChangeNotifierProvider.value(value: h.agentSettings),
        ],
        child: app,
      ),
      pump: (t) async {
        await settle(t);
        if (name.contains('picker')) {
          await t.ensureVisible(find.byType(CheckoutField));
          await t.drag(find.byType(Scrollable).first, const Offset(0, 160));
          await settle(t);
          await t.tap(find.byType(CheckoutField));
          await settle(t);
          expect(find.text('New worktree…'), findsOneWidget);
        } else if (name.contains('new')) {
          await t.ensureVisible(find.byType(CheckoutField));
          await t.tap(find.byType(CheckoutField));
          await settle(t);
          await t.ensureVisible(find.text('New worktree…'));
          await t.tap(find.text('New worktree…'));
          await settle(t);
          if (name.contains('prefilled')) {
            // The release still: what the Branch field starts with, nothing typed.
            await t.ensureVisible(find.byType(EditableText).at(1));
          } else {
            await t.enterText(find.byType(EditableText).at(1), _longBranch);
            t.view.viewInsets = FakeViewPadding(bottom: 300 * phoneDpr);
          }
          await settle(t);
        }
      },
    );
    expect(tester.takeException(), isNull, reason: name);
    await tester.pumpWidget(const SizedBox());
    h.dispose();
  }

  testWidgets('form: Checkout row with a repo folder', (tester) => formShot(tester, 'form-row-light-412'));
  testWidgets(
    'form: the picker with 12 checkouts, dark 320 at 2x',
    (tester) =>
        formShot(tester, 'form-picker-dark-320-2x', brightness: Brightness.dark, size: const Size(320, 640), scale: 2),
  );
  testWidgets('form: New worktree with the keyboard up', (tester) => formShot(tester, 'form-new-light-412'));
  testWidgets(
    'form: New worktree starts with a suggested branch (release still)',
    (tester) => formShot(tester, 'form-new-prefilled-light-412'),
  );
}
