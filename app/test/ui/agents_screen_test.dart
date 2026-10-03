// The agents tab through the real shell: filtering, collapsing, connection
// notices and the states around an empty or failing fleet.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/core/chrome.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/rows.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_screen.dart';

import '../support/shot.dart' show loadAppFonts;
import 'ui_harness.dart';

MachineProfile _machine(String id, String label) => MachineProfile(
      id: id,
      label: label,
      host: '$id.example',
      username: 'dev',
    );

Pane _pane(int i, String status, {String? agent = 'claude'}) =>
    (id: 'w1:p$i', ws: 'w1', agent: agent, status: status);

Finder _chip(String label) => find.widgetWithText(AppChip, label);

Finder _row(String title) => find.widgetWithText(ListRow, title);

/// Makes every machine fail like a rejected login, so each becomes a notice.
Future<void> _failAll(WidgetTester tester, UiHarness h, String error) async {
  for (final t in h.transports.values) {
    t.failure = HerdrTransportException(error, fatal: true);
  }
  for (final c in h.fleet.connections) {
    c.reconnect();
  }
  await settle(tester);
}

void main() {
  setUpAll(loadAppFonts);

  group('filter chips', () {
    Future<UiHarness> mixed() => UiHarness.create([
          (
            profile: _machine('a', 'workstation'),
            snapshot: snapshotWith(
              [
                _pane(1, 'blocked'),
                _pane(2, 'working'),
                _pane(3, 'working'),
                _pane(4, 'idle'),
              ],
              title: (id) => 'task ${id.split('p').last}',
            ),
          ),
        ]);

    testWidgets('one chip per status that has agents, with its count', (tester) async {
      final h = await mixed();
      await pumpUi(tester, h);

      expect(find.byType(AppChip), findsNWidgets(3));
      expect(find.descendant(of: _chip('Working'), matching: find.text('2')), findsOneWidget);
      expect(_chip('Done'), findsNothing, reason: 'no done agents, so no chip');
      await teardownUi(tester, h);
    });

    testWidgets('tapping a chip narrows the list, tapping it again restores it',
        (tester) async {
      final h = await mixed();
      await pumpUi(tester, h);
      expect(find.byType(ListRow), findsNWidgets(4));

      await tester.tap(_chip('Working'));
      await settle(tester);
      expect(find.byType(ListRow), findsNWidgets(2));
      expect(_row('task 2'), findsOneWidget);
      expect(_row('task 1'), findsNothing);

      // Choosing another chip replaces the filter instead of adding to it.
      await tester.tap(_chip('Idle'));
      await settle(tester);
      expect(find.byType(ListRow), findsNWidgets(1));
      expect(_row('task 4'), findsOneWidget);

      await tester.tap(_chip('Idle'));
      await settle(tester);
      expect(find.byType(ListRow), findsNWidgets(4));
      await teardownUi(tester, h);
    });

    testWidgets('a filter whose agents disappeared stops hiding everything',
        (tester) async {
      final h = await mixed();
      await pumpUi(tester, h);
      await tester.tap(_chip('Idle'));
      await settle(tester);
      expect(find.byType(ListRow), findsNWidgets(1));

      h.transports['a']!.snapshot = snapshotWith(
        [_pane(1, 'blocked'), _pane(2, 'working')],
        title: (id) => 'task ${id.split('p').last}',
      );
      h.transports['a']!.emit();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }

      expect(find.byType(ListRow), findsNWidgets(2));
      await teardownUi(tester, h);
    });
  });

  group('sections', () {
    testWidgets('are ordered by urgency and can be collapsed', (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'workstation'),
          snapshot: snapshotWith(
            [_pane(1, 'idle'), _pane(2, 'working'), _pane(3, 'blocked')],
            title: (id) => 'task ${id.split('p').last}',
          ),
        ),
      ]);
      await pumpUi(tester, h);

      double y(String t) => tester.getTopLeft(_row(t)).dy;
      expect(y('task 3'), lessThan(y('task 2')));
      expect(y('task 2'), lessThan(y('task 1')));

      await tester.tap(find.text('Working').last);
      await settle(tester);
      expect(_row('task 2'), findsNothing);
      expect(_row('task 3'), findsOneWidget, reason: 'other sections stay open');

      await tester.tap(find.text('Working').last);
      await settle(tester);
      expect(_row('task 2'), findsOneWidget);
      await teardownUi(tester, h);
    });

    testWidgets('a row with no title is named after its agent, never blank',
        (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'workstation'),
          snapshot: snapshotWith(
            [_pane(1, 'working'), _pane(2, 'idle', agent: 'codex')],
            title: (id) => id.endsWith('p1') ? '⠋' : '',
          ),
        ),
      ]);
      await pumpUi(tester, h);

      expect(_row('claude'), findsOneWidget);
      expect(_row('codex'), findsOneWidget);
      await teardownUi(tester, h);
    });

    testWidgets('a very long title stays on one line', (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'workstation'),
          snapshot: snapshotWith(
            [_pane(1, 'working')],
            title: (_) => 'Refactor ${'the webhook retry handling ' * 12}',
          ),
        ),
      ]);
      await pumpUi(tester, h);

      final row = find.byType(ListRow);
      expect(tester.getSize(row).height, lessThan(110));
      await teardownUi(tester, h);
    });

    testWidgets('120 agents in one section: counted in full, last row clears the tab bar',
        (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'workstation'),
          snapshot: snapshotWith(
            [for (var i = 1; i <= 120; i++) _pane(i, 'working')],
            title: (id) => 'task ${id.split('p').last}',
          ),
        ),
      ]);
      await pumpUi(tester, h);
      expect(find.descendant(of: _chip('Working'), matching: find.text('120')), findsOneWidget);

      await tester.fling(find.byType(CustomScrollView).first, const Offset(0, -20000), 20000);
      await settle(tester);
      await tester.fling(find.byType(CustomScrollView).first, const Offset(0, -20000), 20000);
      await settle(tester);

      final last = tester
          .widgetList(find.byType(ListRow))
          .map((w) => tester.getRect(find.byWidget(w)).bottom)
          .reduce((a, b) => a > b ? a : b);
      final bar = tester.getRect(find.byType(FloatingTabBar));
      expect(last, lessThanOrEqualTo(bar.top),
          reason: 'the last agent must not hide behind the floating tab bar');
      await teardownUi(tester, h);
    });
  });

  group('states', () {
    testWidgets('no machines offers to add one', (tester) async {
      final h = await UiHarness.create(const []);
      await pumpUi(tester, h);

      await tester.tap(find.text('Add your first machine'));
      await settle(tester);
      expect(find.byType(MachineFormScreen), findsOneWidget);
      await teardownUi(tester, h);
    });

    testWidgets('machines with no agents show no filters and say so', (tester) async {
      final h = await UiHarness.create([
        (profile: _machine('a', 'solo'), snapshot: snapshotWith(const [])),
        (profile: _machine('b', 'duo'), snapshot: snapshotWith(const [])),
      ]);
      await pumpUi(tester, h);

      expect(find.text('No agents running'), findsOneWidget);
      expect(find.byType(AppChip), findsNothing);
      expect(find.text('2 machines · no agents'), findsOneWidget);
      await teardownUi(tester, h);
    });

    testWidgets('every machine failing: each says why and can retry', (tester) async {
      final h = await UiHarness.create([
        for (final id in ['a', 'b', 'c'])
          (
            profile: _machine(id, id == 'a' ? 'x' : 'build-server-eu-west-2-primary-$id'),
            snapshot: snapshotWith(const []),
          ),
      ]);
      await pumpUi(tester, h);
      await _failAll(tester, h, 'Host key changed. ${'Check it. ' * 30}');

      expect(find.text('Needs attention'), findsNWidgets(3));
      expect(find.text('Retry'), findsNWidgets(3));
      expect(find.text('No agents running'), findsNothing,
          reason: 'the notices already explain the empty list');
      expect(find.textContaining('3 not connected'), findsOneWidget);

      // Retrying a machine that recovered clears only its notice.
      h.transports['a']!.failure = null;
      await tester.tap(find.text('Retry').first);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await settle(tester);
      expect(find.text('Retry'), findsNWidgets(2));
      expect(h.fleet.connections.first.state, LinkState.online);
      await teardownUi(tester, h);
    });

    testWidgets('an offline machine keeps its agents, dimmed, under a notice',
        (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'solo'),
          snapshot: snapshotWith([_pane(1, 'blocked')], title: (_) => 'Needs a decision'),
        ),
      ]);
      await pumpUi(tester, h);
      h.network.goOffline();
      await settle(tester);

      expect(find.text('No network'), findsOneWidget);
      expect(_row('Needs a decision'), findsOneWidget);
      expect(tester.widget<ListRow>(_row('Needs a decision')).dim, isTrue);
      await teardownUi(tester, h);
    });
  });

  testWidgets('the Agents tab badge counts agents that want you', (tester) async {
    final h = await UiHarness.create([
      (
        profile: _machine('a', 'solo'),
        snapshot: snapshotWith([
          _pane(1, 'blocked'),
          _pane(2, 'done'),
          _pane(3, 'working'),
        ]),
      ),
    ]);
    await pumpUi(tester, h);

    expect(
      find.descendant(of: find.byType(FloatingTabBar), matching: find.text('2')),
      findsOneWidget,
    );
    await teardownUi(tester, h);
  });
}
