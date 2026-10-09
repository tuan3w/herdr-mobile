// The agents tab through the real shell: filtering, collapsing, connection
// notices and the states around an empty or failing fleet.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/core/chrome.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/rows.dart';
import 'package:herdr_mobile/ui/core/status_panel.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agents/agent_card.dart';
import 'package:herdr_mobile/ui/features/agents/agents_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machines_screen.dart';
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

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

/// A status change event: herdr refreshes after a short delay, not the
/// 1.5 s churn spacing of title and cwd updates.
const _statusEvent = {'event': 'pane.agent_status_changed'};

/// Replaces what machine `a` reports and tells the connection it changed.
void _push(UiHarness h, List<Pane> panes) {
  h.transports['a']!.snapshot = snapshotWith(
    panes,
    title: (id) => 'task ${id.split('p').last}',
  );
  h.transports['a']!.emit(_statusEvent);
}

Finder _chip(String label) => find.widgetWithText(AppChip, label);

Finder _row(String title) => find.widgetWithText(AgentCard, title);

/// The card's tappable body: one semantics node reading the whole card.
Finder _body(String title) =>
    find.descendant(of: _row(title), matching: find.byType(PressBuilder)).first;

/// Tall enough to build every card of a small fleet at once (cards are ~170dp).
const _tall = 2400.0;

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
      await pumpUi(tester, h, height: _tall);

      expect(find.byType(AppChip), findsNWidgets(3));
      expect(find.descendant(of: _chip('Working'), matching: find.text('2')), findsOneWidget);
      expect(_chip('Done'), findsNothing, reason: 'no done agents, so no chip');
      await teardownUi(tester, h);
    });

    testWidgets('tapping a chip narrows the list, tapping it again restores it',
        (tester) async {
      final h = await mixed();
      await pumpUi(tester, h, height: _tall);
      expect(find.byType(AgentCard), findsNWidgets(4));

      await tester.tap(_chip('Working'));
      await settle(tester);
      expect(find.byType(AgentCard), findsNWidgets(2));
      expect(_row('task 2'), findsOneWidget);
      expect(_row('task 1'), findsNothing);

      // Choosing another chip replaces the filter instead of adding to it.
      await tester.tap(_chip('Idle'));
      await settle(tester);
      expect(find.byType(AgentCard), findsNWidgets(1));
      expect(_row('task 4'), findsOneWidget);

      await tester.tap(_chip('Idle'));
      await settle(tester);
      expect(find.byType(AgentCard), findsNWidgets(4));
      await teardownUi(tester, h);
    });

    testWidgets('a filter whose agents disappeared stops hiding everything',
        (tester) async {
      final h = await mixed();
      await pumpUi(tester, h, height: _tall);
      await tester.tap(_chip('Idle'));
      await settle(tester);
      expect(find.byType(AgentCard), findsNWidgets(1));

      _push(h, [_pane(1, 'blocked'), _pane(2, 'working')]);
      await settle(tester);

      expect(find.byType(AgentCard), findsNWidgets(2));
      await teardownUi(tester, h);
    });

    testWidgets('and does not come back when an agent of that status returns',
        (tester) async {
      final h = await mixed();
      await pumpUi(tester, h, height: _tall);
      await tester.tap(_chip('Idle'));
      await settle(tester);

      _push(h, [_pane(1, 'blocked'), _pane(2, 'working')]);
      await settle(tester);
      _push(h, [_pane(1, 'blocked'), _pane(2, 'working'), _pane(4, 'idle')]);
      await settle(tester);

      expect(find.byType(AgentCard), findsNWidgets(3), reason: 'the old filter must not re-apply');
      expect(tester.widget<AppChip>(_chip('Idle')).selected, isFalse);
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
      await pumpUi(tester, h, height: _tall);

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
      await pumpUi(tester, h, height: _tall);

      expect(_row('claude'), findsOneWidget);
      expect(_row('codex'), findsOneWidget);
      await teardownUi(tester, h);
    });

    testWidgets('a very long title stops at two lines', (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'workstation'),
          snapshot: snapshotWith(
            [_pane(1, 'working')],
            title: (_) => 'Refactor ${'the webhook retry handling ' * 12}',
          ),
        ),
      ]);
      await pumpUi(tester, h, height: _tall);

      final row = find.byType(AgentCard);
      expect(tester.getSize(row).height, lessThan(230));
      final title = find.descendant(of: row, matching: find.textContaining('Refactor'));
      expect(tester.widget<Text>(title).maxLines, 2);
      await teardownUi(tester, h);
    });

    testWidgets('a row says where it runs on one line, and names the machine only among several',
        (tester) async {
      Future<void> expectLine(List<String> machines, String line) async {
        final h = await UiHarness.create([
          for (final id in machines)
            (
              profile: _machine(id, 'box-$id'),
              snapshot: id == machines.first
                  ? snapshotWith([_pane(1, 'working')], title: (_) => 'Task', cwd: (_) => '/src/main')
                  : snapshotWith(const []),
            ),
        ]);
        await pumpUi(tester, h, height: _tall);
        expect(find.text(line), findsOneWidget);
        await teardownUi(tester, h);
      }

      await expectLine(['a'], 'claude · main');
      await expectLine(['a', 'b'], 'claude · box-a · main');
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
      await pumpUi(tester, h, height: _tall);
      expect(find.descendant(of: _chip('Working'), matching: find.text('120')), findsOneWidget);

      await tester.fling(find.byType(CustomScrollView).first, const Offset(0, -20000), 20000);
      await settle(tester);
      await tester.fling(find.byType(CustomScrollView).first, const Offset(0, -20000), 20000);
      await settle(tester);

      final last = tester
          .widgetList(find.byType(AgentCard))
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
      await pumpUi(tester, h, height: _tall);

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
      await pumpUi(tester, h, height: _tall);

      expect(find.text('No agents running'), findsOneWidget);
      expect(find.byType(AppChip), findsNothing);
      expect(find.text('2 machines · no agents'), findsOneWidget);
      await teardownUi(tester, h);
    });

    testWidgets('every machine failing: one strip sums it up and leads to the Machines tab',
        (tester) async {
      final h = await UiHarness.create([
        for (final id in ['a', 'b', 'c'])
          (
            profile: _machine(id, id == 'a' ? 'x' : 'build-server-eu-west-2-primary-$id'),
            snapshot: snapshotWith(
              [_pane(1, 'blocked'), _pane(2, 'working'), _pane(3, 'done')],
              title: (id) => 'task ${id.split('p').last}',
            ),
          ),
      ]);
      await pumpUi(tester, h, height: 640);
      await _failAll(tester, h, 'Host key changed. ${'Check it. ' * 30}');

      expect(find.byType(StatusStrip), findsOneWidget);
      expect(find.text('3 machines not connected'), findsOneWidget);
      expect(find.text('Retry'), findsNothing, reason: 'the Machines tab has the detail');
      expect(find.textContaining('3 not connected'), findsOneWidget);

      // The agents the person came for are still on the first screen.
      expect(tester.getTopLeft(find.byType(AgentCard).first).dy, lessThan(300));

      await tester.tap(find.byType(StatusStrip));
      await settle(tester);
      expect(find.byType(MachinesScreen).hitTestable(), findsOneWidget);
      await teardownUi(tester, h);
    });

    testWidgets('one machine failing: its own strip, and Retry works from there',
        (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'x'),
          snapshot: snapshotWith([_pane(1, 'working')], title: (_) => 'task'),
        ),
        (profile: _machine('b', 'duo'), snapshot: snapshotWith(const [])),
      ]);
      await pumpUi(tester, h, height: _tall);
      h.transports['a']!.failure = HerdrTransportException('Host key changed', fatal: true);
      h.fleet.connections.first.reconnect();
      await settle(tester);

      expect(find.byType(StatusStrip), findsOneWidget);
      expect(find.textContaining('Host key changed'), findsNothing);
      expect(find.textContaining('Needs attention'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      h.transports['a']!.failure = null;
      await tester.tap(find.text('Retry'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await settle(tester);
      expect(find.byType(StatusStrip), findsNothing);
      expect(h.fleet.connections.first.state, LinkState.online);
      await teardownUi(tester, h);
    });

    testWidgets('a failing machine and long rows fit at 320dp and double text size',
        (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'tailnet-build-server-eu-west-2-primary'),
          snapshot: snapshotWith(
            [_pane(1, 'blocked'), _pane(2, 'working')],
            title: (_) => 'Hôm nay chúng ta cập nhật và kiểm tra ${'dài ' * 20}',
          ),
        ),
        (profile: _machine('b', 'duo'), snapshot: snapshotWith(const [])),
      ]);
      await pumpUi(tester, h, width: 320, height: 640, textScale: 2);
      h.transports['a']!.failure = HerdrTransportException('Host key changed', fatal: true);
      h.fleet.connections.first.reconnect();
      await settle(tester);

      expect(find.byType(StatusStrip), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await teardownUi(tester, h);
    });

    testWidgets('a machine that was switched off is not a failure', (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'solo'),
          snapshot: snapshotWith([_pane(1, 'working')], title: (_) => 'task'),
        ),
        (
          profile: MachineProfile(
            id: 'b',
            label: 'old-laptop',
            host: 'b.example',
            username: 'dev',
            enabled: false,
          ),
          snapshot: snapshotWith(const []),
        ),
      ]);
      await pumpUi(tester, h, height: _tall);

      expect(h.fleet.connections.last.state, LinkState.disabled);
      expect(find.byType(StatusStrip), findsNothing);
      expect(find.textContaining('not connected'), findsNothing);
      await teardownUi(tester, h);
    });

    testWidgets('an offline machine keeps its agents under a strip, dimmed once',
        (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'solo'),
          snapshot: snapshotWith([_pane(1, 'blocked')], title: (_) => 'Needs a decision'),
        ),
      ]);
      await pumpUi(tester, h, height: _tall);
      h.network.goOffline();
      await settle(tester);

      expect(find.textContaining('No network'), findsOneWidget);
      expect(_row('Needs a decision'), findsOneWidget);
      // The row's own Opacity and no second one on the glyph: dimmed twice,
      // the status shape is all but invisible.
      expect(
        find.descendant(of: _row('Needs a decision'), matching: find.byType(Opacity)),
        findsOneWidget,
      );
      await teardownUi(tester, h);
    });
  });

  testWidgets('the Agents tab badge counts what needs you, not finished work', (tester) async {
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
    await pumpUi(tester, h, height: _tall);

    expect(
      find.descendant(of: find.byType(FloatingTabBar), matching: find.text('1')),
      findsOneWidget,
      reason: 'the loud colour is for a question; the finished one waits quietly on the board',
    );
    await teardownUi(tester, h);
  });

  group('motion and identity', () {
    Future<UiHarness> two() => UiHarness.create([
          (
            profile: _machine('a', 'workstation'),
            snapshot: snapshotWith(
              [_pane(1, 'working'), _pane(2, 'working'), _pane(3, 'idle')],
              title: (id) => 'task ${id.split('p').last}',
            ),
          ),
        ]);

    Future<void> change(WidgetTester tester, UiHarness h, List<Pane> panes) async {
      _push(h, panes);
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('closing a section animates its rows away instead of cutting them',
        (tester) async {
      final h = await two();
      await pumpUi(tester, h, height: _tall);

      await tester.tap(find.text('Working').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 110));
      expect(_row('task 2'), findsOneWidget, reason: 'still on its way out');

      await settle(tester);
      expect(_row('task 2'), findsNothing);
      await teardownUi(tester, h);
    });

    testWidgets('an agent moving between sections keeps every row in place',
        (tester) async {
      final h = await two();
      await pumpUi(tester, h, height: _tall);
      final before = {
        for (final t in ['task 1', 'task 2', 'task 3']) t: tester.element(_row(t)),
      };

      await change(tester, h, [_pane(1, 'blocked'), _pane(2, 'working'), _pane(3, 'idle')]);
      await settle(tester);

      for (final MapEntry(key: t, value: element) in before.entries) {
        expect(identical(tester.element(_row(t)), element), isTrue,
            reason: '$t was inflated again instead of moved');
      }
      await teardownUi(tester, h);
    });

    testWidgets('a collapsed section stays still when the one above it disappears',
        (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'workstation'),
          snapshot: snapshotWith(
            [_pane(1, 'blocked'), _pane(2, 'working')],
            title: (id) => 'task ${id.split('p').last}',
          ),
        ),
      ]);
      await pumpUi(tester, h, height: _tall);
      await tester.tap(find.text('Working').last);
      await settle(tester);

      await change(tester, h, [_pane(2, 'working')]);

      final chevron = find.descendant(
        of: find.widgetWithText(SectionLabel, 'Working'),
        matching: find.byType(RotationTransition),
      );
      expect(tester.widget<RotationTransition>(chevron).turns.value, -0.25,
          reason: 'the chevron must not spin to catch up');
      await teardownUi(tester, h);
    });

    testWidgets('the pull-to-refresh spinner starts below the whole header', (tester) async {
      final h = await two();
      await pumpUi(tester, h, height: _tall);

      final header = tester.getRect(
        find.descendant(of: find.byType(SliverPersistentHeader), matching: find.byType(ClipRect)).first,
      );
      final refresh = tester.widget<RefreshIndicator>(find.byType(RefreshIndicator));
      expect(refresh.edgeOffset, header.bottom);
      await teardownUi(tester, h);
    });
  });

  group('chips under the header', () {
    Future<UiHarness> many() => UiHarness.create([
          (
            profile: _machine('a', 'workstation'),
            snapshot: snapshotWith(
              [_pane(0, 'blocked'), for (var i = 1; i <= 40; i++) _pane(i, 'working')],
              title: (id) => 'task ${id.split('p').last}',
            ),
          ),
        ]);

    testWidgets('are tappable while visible and not once they slid under the bar',
        (tester) async {
      final h = await many();
      await pumpUi(tester, h, height: _tall);
      final scroll = find.byType(CustomScrollView).first;

      await tester.drag(scroll, const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(_chip('Working'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<AppChip>(_chip('Working')).selected, isTrue);
      await tester.tap(_chip('Working'));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.drag(scroll, const Offset(0, -400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.getCenter(_chip('Working')).dy, lessThan(56));
      await tester.tap(_chip('Working'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<AppChip>(_chip('Working')).selected, isFalse);
      await teardownUi(tester, h);
    });

    testWidgets('rows fading out behind the tab bar can still be tapped', (tester) async {
      final h = await many();
      await pumpUi(tester, h, height: _tall);

      final bar = tester.getRect(find.byType(FloatingTabBar));
      // Above the pill, in the strip the fade covers, left of the "needs you" pill.
      await tester.tapAt(Offset(24, bar.top - 8));
      await settle(tester);
      expect(find.byType(PaneScreen), findsOneWidget);
      await teardownUi(tester, h);
    });
  });

  group('rebuilds', () {
    /// Elements rebuilt under the agents tab while the next frame is pumped.
    Future<int> rebuiltUnderAgents(WidgetTester tester) async {
      var n = 0;
      final previous = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (e, _) {
        e.visitAncestorElements((a) {
          if (a.widget is! AgentsScreen) return true;
          n++;
          return false;
        });
      };
      try {
        await tester.pump(const Duration(milliseconds: 300));
      } finally {
        debugOnRebuildDirtyWidget = previous;
      }
      return n;
    }

    // Only the selected tab shows its label, so tabs are found by key.
    Finder tab(String label) => find.byKey(FloatingTabBar.tabKey(label));

    testWidgets('only a change to what the tab draws rebuilds it, and not while hidden',
        (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'workstation'),
          snapshot: snapshotWith(
            [_pane(1, 'working'), _pane(2, 'idle')],
            title: (id) => 'task ${id.split('p').last}',
          ),
        ),
      ]);
      await pumpUi(tester, h, height: _tall);

      // The fleet spoke but nothing the tab draws changed.
      _push(h, [_pane(1, 'working'), _pane(2, 'idle')]);
      expect(await rebuiltUnderAgents(tester), 0);

      // Something it does draw changed.
      _push(h, [_pane(1, 'done'), _pane(2, 'idle')]);
      expect(await rebuiltUnderAgents(tester), greaterThan(0));

      // The Machines tab is on screen: the Agents tab sleeps...
      await tester.tap(tab('Machines'));
      await settle(tester);
      _push(h, [_pane(1, 'blocked'), _pane(2, 'idle')]);
      expect(await rebuiltUnderAgents(tester), 0);

      // ...and is up to date the moment it returns.
      await tester.tap(tab('Agents'));
      await settle(tester);
      expect(find.text('Needs you'), findsWidgets);
      await teardownUi(tester, h);
    });
  });

  group('accessibility', () {
    testWidgets('a row reads as one label: title, status and where, each once',
        (tester) async {
      final handle = tester.ensureSemantics();
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'solo'),
          snapshot: snapshotWith([_pane(1, 'blocked')], title: (_) => 'Pick a strategy'),
        ),
      ]);
      await pumpUi(tester, h, height: _tall);

      final label = tester.getSemantics(_body('Pick a strategy')).label;
      for (final part in ['Pick a strategy', 'Needs you', 'claude']) {
        expect(RegExp(RegExp.escape(part)).allMatches(label), hasLength(1),
            reason: '"$part" in: $label');
      }
      handle.dispose();
      await teardownUi(tester, h);
    });
  });

  group('restoration', () {
    Future<void> pumpRestorable(WidgetTester tester, UiHarness h) async {
      tester.view
        ..physicalSize = const Size(360, 740) * 2
        ..devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: h.machines),
            ChangeNotifierProvider.value(value: h.fleet),
            ChangeNotifierProvider.value(value: h.appSettings),
            ChangeNotifierProvider.value(value: h.agentScreens),
            Provider<PanePreviews>.value(value: h.previews),
            attentionSetProvider(),
          ],
          child: MaterialApp(
            restorationScopeId: 'app',
            theme: AppTheme.dark(),
            home: const HomeShell(),
          ),
        ),
      );
      await settle(tester);
    }

    testWidgets('the open tab and the collapsed sections survive the process', (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'workstation'),
          snapshot: snapshotWith(
            [_pane(1, 'blocked'), _pane(2, 'working')],
            title: (id) => 'task ${id.split('p').last}',
          ),
        ),
      ]);
      await pumpRestorable(tester, h);
      await tester.tap(find.text('Working').last);
      await settle(tester);
      expect(_row('task 2'), findsNothing);

      await tester.restartAndRestore();
      await settle(tester);
      expect(_row('task 1'), findsOneWidget);
      expect(_row('task 2'), findsNothing, reason: 'Working stayed collapsed');

      await tester.tap(find.byKey(FloatingTabBar.tabKey('Machines')));
      await settle(tester);
      await tester.restartAndRestore();
      await settle(tester);
      expect(find.byType(MachinesScreen).hitTestable(), findsOneWidget);
      await teardownUi(tester, h);
    });
  });
}
