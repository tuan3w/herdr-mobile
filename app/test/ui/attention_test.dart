// The board and its chrome tell one story about what needs you: the badge, the
// pill and the sections agree, what is out of reach says so instead of being
// counted, reviewing clears Done on this phone only, wait times are honest,
// rows follow the wait, and density follows the count.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/attention_set.dart';
import 'package:herdr_mobile/ui/core/chrome.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/rows.dart';
import 'package:herdr_mobile/ui/features/agents/agent_card.dart';
import 'package:herdr_mobile/ui/features/agents/reply_sheet.dart';
import 'package:herdr_mobile/ui/features/agents/triage_pill.dart';
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../support/shot.dart' show loadAppFonts;
import 'board_support.dart';
import 'ui_harness.dart';

MachineProfile _profile(String id) =>
    MachineProfile(id: id, label: 'box-$id', host: '$id.example', username: 'dev');

Pane _pane(int i, String status) => (id: 'w1:p$i', ws: 'w1', agent: 'claude', status: status);

String _title(String paneId) => 'task ${paneId.split('p').last}';

({MachineProfile profile, Map<String, dynamic> snapshot}) _machine(String id, List<Pane> panes) =>
    (profile: _profile(id), snapshot: snapshotWith(panes, title: _title));

const _tall = 2400.0;

Finder _card(String title) => find.widgetWithText(AgentCard, title);

Finder _row(String title) => find.widgetWithText(AgentCompactRow, title);

Finder _chip(String label) => find.widgetWithText(AppChip, label);

int _sectionCount(WidgetTester tester, String label) => tester
    .widget<SectionLabel>(find.byWidgetPredicate((w) => w is SectionLabel && w.label == label))
    .count!;

double _top(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

/// What the Agents tab's badge says, as a screen reader hears it.
String _badge(WidgetTester tester) =>
    tester.getSemantics(find.byKey(FloatingTabBar.tabKey('Agents'))).label;

/// Needs you plus to review, as the app's one set counts them.
int _wanted(WidgetTester tester) {
  final set = tester.element(find.byType(HomeShell, skipOffstage: false)).read<AttentionSet>();
  return set.needsYou.length + set.toReview.length;
}

/// Goes back from the pane screen to the board.
Future<void> _back(WidgetTester tester) async {
  Navigator.of(tester.element(find.byType(PaneScreen))).pop();
  await settle(tester);
}

void main() {
  setUpAll(loadAppFonts);

  group('one vocabulary', () {
    testWidgets('the badge, the pill and the sections add up', (tester) async {
      final semantics = tester.ensureSemantics();
      final h = await BoardHarness.create([
        _machine('a', [
          _pane(1, 'blocked'),
          _pane(2, 'blocked'),
          _pane(3, 'done'),
          _pane(4, 'done'),
          _pane(5, 'working'),
        ]),
      ]);
      await pumpBoard(tester, h, height: _tall);

      expect(find.text('2 need you · 2 to review'), findsOneWidget);
      expect(_sectionCount(tester, 'Needs you'), 2);
      expect(_sectionCount(tester, 'Done'), 2);
      expect(_badge(tester), 'Agents, 2 need you', reason: 'the badge is for questions only');
      expect(_wanted(tester), 4);
      expect(find.descendant(of: _chip('Needs you'), matching: find.text('2')), findsOneWidget);
      expect(find.descendant(of: _chip('Done'), matching: find.text('2')), findsOneWidget);
      semantics.dispose();
      await teardownBoard(tester, h);
    });

    testWidgets('one blocked agent: "1 needs you", and nothing to review adds nothing', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked'), _pane(2, 'working')]),
      ]);
      await pumpBoard(tester, h, height: _tall);

      expect(find.text('1 needs you'), findsOneWidget);
      expect(find.textContaining('to review'), findsNothing);
      await teardownBoard(tester, h);
    });

    testWidgets('with nothing blocked there is no pill and no badge: finished work is not a question',
        (tester) async {
      final semantics = tester.ensureSemantics();
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'done'), _pane(2, 'done'), _pane(3, 'working')]),
      ]);
      await pumpBoard(tester, h, height: _tall);

      expect(find.byType(TriagePill), findsNothing);
      expect(_badge(tester), 'Agents');
      expect(_sectionCount(tester, 'Done'), 2, reason: 'the board still lists it, quietly');
      semantics.dispose();
      await teardownBoard(tester, h);
    });

    testWidgets('the pill still starts the triage sheet over the blocked agents only', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked'), _pane(2, 'done'), _pane(3, 'done')]),
      ]);
      await pumpBoard(tester, h, height: _tall);

      await tester.tap(find.text('1 needs you · 2 to review'));
      await settle(tester);

      expect(find.byType(ReplySheet), findsOneWidget);
      expect(find.text('1 of 1 need you'), findsOneWidget, reason: 'finished agents are not walked');
      await teardownBoard(tester, h);
    });

    testWidgets('an offline machine\'s agents leave every count, and the board says they are offline',
        (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked'), _pane(2, 'done')]),
        _machine('b', [_pane(3, 'blocked')]),
      ]);
      await pumpBoard(tester, h, height: _tall);
      expect(find.text('2 need you · 1 to review'), findsOneWidget);
      expect(find.byKey(const ValueKey('mark-all-reviewed')), findsOneWidget);

      h.network.goOffline();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(TriagePill), findsNothing);
      expect(_wanted(tester), 0, reason: 'nothing out of reach can be answered or marked reviewed');
      expect(find.text('2 offline'), findsOneWidget, reason: 'Needs you lists them, last known');
      expect(find.text('1 offline'), findsOneWidget, reason: 'and so does Done');
      expect(find.byKey(const ValueKey('mark-all-reviewed')), findsNothing,
          reason: 'a button that would do nothing is not offered');
      h.network.goOnline();
      await teardownBoard(tester, h);
    });

    testWidgets('sections run Needs you, Done, Working, Idle; so do the chips', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [
          _pane(1, 'idle'),
          _pane(2, 'working'),
          _pane(3, 'done'),
          _pane(4, 'blocked'),
        ]),
      ]);
      await pumpBoard(tester, h, height: _tall);

      Finder section(String label) => find.widgetWithText(SectionLabel, label);
      final ys = [for (final s in ['Needs you', 'Done', 'Working', 'Idle']) _top(tester, section(s))];
      expect(ys, orderedEquals([...ys]..sort()), reason: 'top to bottom');
      expect(ys.toSet(), hasLength(4));

      final xs = [for (final s in ['Needs you', 'Done', 'Working', 'Idle']) tester.getTopLeft(_chip(s)).dx];
      expect(xs, orderedEquals([...xs]..sort()), reason: 'left to right');
      await teardownBoard(tester, h);
    });
  });

  group('reviewing', () {
    testWidgets('opening a finished agent clears Done everywhere on the phone, and herdr is told nothing',
        (tester) async {
      final semantics = tester.ensureSemantics();
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked'), _pane(2, 'done'), _pane(3, 'done')]),
      ]);
      await pumpBoard(tester, h, height: _tall);
      expect(find.text('1 needs you · 2 to review'), findsOneWidget);
      expect(_badge(tester), 'Agents, 1 need you');

      await tester.tap(_card('task 2'));
      await settle(tester);
      expect(find.byType(PaneScreen), findsOneWidget);
      expect(_wanted(tester), 2);
      await _back(tester);

      expect(find.text('1 needs you · 1 to review'), findsOneWidget);
      expect(_badge(tester), 'Agents, 1 need you', reason: 'reviewing does not touch what needs you');
      expect(_sectionCount(tester, 'Done'), 1);
      expect(_sectionCount(tester, 'Idle'), 1, reason: 'the reviewed agent is idle on this phone');
      expect(find.descendant(of: _chip('Done'), matching: find.text('1')), findsOneWidget);
      expect(h.fleet.agents.firstWhere((a) => a.pane.id == 'w1:p2').pane.status.name, 'idle');

      final calls = h.transports['a']!.calls.map((c) => c.$1);
      expect(calls.where((m) => m.contains('focus')), isEmpty,
          reason: 'focusing would clear herdr\'s own state and move the desktop view');
      final herdrStatuses = [
        for (final p in h.transports['a']!.snapshot['panes'] as List) (p as Map)['agent_status'],
      ];
      expect(herdrStatuses, ['blocked', 'done', 'done'], reason: 'herdr still says done');
      semantics.dispose();
      await teardownBoard(tester, h);
    });

    testWidgets('a compact row reviews too', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'done'), _pane(2, 'done')]),
      ]);
      await h.appSettings.setDensity(BoardDensity.compact);
      await pumpBoard(tester, h, height: _tall);
      expect(_wanted(tester), 2);

      await tester.tap(_row('task 1'));
      await settle(tester);

      expect(_wanted(tester), 1);
      await _back(tester);
      expect(_sectionCount(tester, 'Done'), 1);
      await teardownBoard(tester, h);
    });

    testWidgets('a reviewed agent that finishes again is Done again', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'done')]),
      ]);
      await pumpBoard(tester, h, height: _tall);
      await tester.tap(_card('task 1'));
      await settle(tester);
      await _back(tester);
      expect(_wanted(tester), 0);
      expect(find.byType(TriagePill), findsNothing);

      await h.changeStatuses(tester, 'a', [_pane(1, 'working')], title: _title);
      await h.changeStatuses(tester, 'a', [_pane(1, 'done')], title: _title);

      expect(_wanted(tester), 1);
      expect(_sectionCount(tester, 'Done'), 1);
      await teardownBoard(tester, h);
    });
  });

  group('honest wait time', () {
    testWidgets('a change found after a 30-minute gap reads ≤ 30m, never <1m', (tester) async {
      final h = await BoardHarness.create(
        [_machine('a', [_pane(1, 'working')])],
        observedAgo: const Duration(minutes: 30),
      );
      await pumpBoard(tester, h, height: _tall);

      // The app was away for half an hour (its clock then read 30 minutes
      // ago); while it was, the agent started waiting for the person.
      h.observedAgo = Duration.zero;
      h.transports['a']!.snapshot = snapshotWith([_pane(1, 'blocked')], title: _title);
      h.fleet.connection('a')!.reconnect();
      await settle(tester);

      expect(find.text('needs you ≤ 30m'), findsOneWidget);
      expect(find.textContaining('<1m'), findsNothing);
      await teardownBoard(tester, h);
    });

    testWidgets('a change seen live is exact', (tester) async {
      final h = await BoardHarness.create([_machine('a', [_pane(1, 'working')])]);
      await pumpBoard(tester, h, height: _tall);

      await h.changeStatuses(tester, 'a', [_pane(1, 'blocked')],
          ago: const Duration(minutes: 12), title: _title);

      expect(find.text('needs you 12m'), findsOneWidget);
      expect(find.textContaining('≤'), findsNothing);
      await teardownBoard(tester, h);
    });
  });

  group('order inside a section', () {
    testWidgets('Needs you: the one that has waited longest is on top, not the one with the lowest id',
        (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'working'), _pane(2, 'working'), _pane(3, 'working')]),
      ]);
      await pumpBoard(tester, h, height: _tall);

      await h.changeStatuses(
        tester,
        'a',
        [_pane(1, 'blocked'), _pane(2, 'working'), _pane(3, 'working')],
        ago: const Duration(minutes: 5),
        title: _title,
      );
      await h.changeStatuses(
        tester,
        'a',
        [_pane(1, 'blocked'), _pane(2, 'blocked'), _pane(3, 'working')],
        ago: const Duration(minutes: 20),
        title: _title,
      );
      await h.changeStatuses(
        tester,
        'a',
        [_pane(1, 'blocked'), _pane(2, 'blocked'), _pane(3, 'blocked')],
        ago: const Duration(minutes: 1),
        title: _title,
      );

      expect(find.text('needs you 20m'), findsOneWidget);
      expect(find.text('needs you 5m'), findsOneWidget);
      expect(find.text('needs you 1m'), findsOneWidget);
      final y = [for (final i in [1, 2, 3]) _top(tester, _card('task $i'))];
      expect(y[1], lessThan(y[0]), reason: '20 minutes above 5');
      expect(y[0], lessThan(y[2]), reason: '5 minutes above 1');
      await teardownBoard(tester, h);
    });

    testWidgets('Done: oldest first too', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'working'), _pane(2, 'working')]),
      ]);
      await pumpBoard(tester, h, height: _tall);

      await h.changeStatuses(tester, 'a', [_pane(1, 'done'), _pane(2, 'working')],
          ago: const Duration(minutes: 2), title: _title);
      await h.changeStatuses(tester, 'a', [_pane(1, 'done'), _pane(2, 'done')],
          ago: const Duration(minutes: 40), title: _title);

      expect(_top(tester, _card('task 2')), lessThan(_top(tester, _card('task 1'))));
      await teardownBoard(tester, h);
    });
  });

  group('quiet', () {
    testWidgets('a working agent quiet for minutes says so; the order moves with a refresh, not an event',
        (tester) async {
      // The stream went live 14 minutes ago (the connection's clock starts that
      // far behind) and has heard nothing since.
      final h = await BoardHarness.create(
        [_machine('a', [_pane(1, 'working'), _pane(2, 'working')])],
        observedAgo: const Duration(minutes: 14),
      );
      await pumpBoard(tester, h, height: _tall);
      expect(find.textContaining('quiet'), findsNothing, reason: 'on connecting, nothing has been listened to yet');

      final panes = [_pane(1, 'working'), _pane(2, 'working')];
      await h.changeStatuses(tester, 'a', panes, title: _title);
      expect(find.text('quiet 14m'), findsNWidgets(2), reason: 'the next refresh, 14 minutes on');
      expect(_top(tester, _card('task 1')), lessThan(_top(tester, _card('task 2'))),
          reason: 'equally quiet: machine, then pane');

      // task 1 speaks up: a burst of events, no refresh.
      var notified = 0;
      h.fleet.addListener(() => notified++);
      final pane = Map<String, dynamic>.of(
        ((h.transports['a']!.snapshot['panes'] as List).first as Map).cast<String, dynamic>(),
      );
      for (var i = 0; i < 300; i++) {
        h.transports['a']!.emit({
          'event': 'pane_updated',
          'data': {'type': 'pane_updated', 'pane': pane},
        });
      }
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(notified, 0, reason: 'no notification per event');
      expect(_top(tester, _card('task 1')), lessThan(_top(tester, _card('task 2'))),
          reason: 'the order waits for the next refresh');

      await h.changeStatuses(tester, 'a', panes, title: _title);
      expect(_top(tester, _card('task 2')), lessThan(_top(tester, _card('task 1'))),
          reason: 'now the quietest one is first');
      expect(find.text('quiet 14m'), findsOneWidget, reason: 'only task 2 is still quiet');
      await teardownBoard(tester, h);
    });

    testWidgets('an agent that is not working never says quiet', (tester) async {
      final h = await BoardHarness.create(
        [_machine('a', [_pane(1, 'blocked'), _pane(2, 'done'), _pane(3, 'idle')])],
        observedAgo: const Duration(minutes: 14),
      );
      await pumpBoard(tester, h, height: _tall);
      await h.changeStatuses(
          tester, 'a', [_pane(1, 'blocked'), _pane(2, 'done'), _pane(3, 'idle')], title: _title);

      expect(find.textContaining('quiet'), findsNothing);
      await teardownBoard(tester, h);
    });
  });

  group('density', () {
    Future<BoardHarness> auto(List<Pane> panes) async {
      final h = await BoardHarness.create([_machine('a', panes)]);
      await h.appSettings.setDensity(BoardDensity.auto);
      return h;
    }

    testWidgets('auto: cards up to four agents, compact from five', (tester) async {
      final h = await auto([for (var i = 1; i <= 4; i++) _pane(i, 'working')]);
      await pumpBoard(tester, h, height: _tall);
      expect(find.byType(AgentCard), findsNWidgets(4));
      expect(find.byType(AgentCompactRow), findsNothing);
      expect(find.byTooltip('Compact list'), findsOneWidget);

      await h.changeStatuses(tester, 'a', [for (var i = 1; i <= 5; i++) _pane(i, 'working')],
          title: _title);
      expect(find.byType(AgentCard), findsNothing);
      expect(find.byType(AgentCompactRow), findsNWidgets(5));
      expect(find.byTooltip('Cards with preview'), findsOneWidget);

      await h.changeStatuses(tester, 'a', [for (var i = 1; i <= 4; i++) _pane(i, 'working')],
          title: _title);
      expect(find.byType(AgentCard), findsNWidgets(4), reason: 'back under five');
      await teardownBoard(tester, h);
    });

    testWidgets('the button makes an explicit choice that the count no longer overrides',
        (tester) async {
      final h = await auto([for (var i = 1; i <= 6; i++) _pane(i, 'working')]);
      await pumpBoard(tester, h, height: _tall);
      expect(find.byType(AgentCompactRow), findsNWidgets(6));
      expect(h.appSettings.density, BoardDensity.auto);

      await tester.tap(find.byTooltip('Cards with preview'));
      await settle(tester);
      expect(find.byType(AgentCard), findsNWidgets(6));
      expect(h.appSettings.density, BoardDensity.cards);

      await h.changeStatuses(tester, 'a', [for (var i = 1; i <= 2; i++) _pane(i, 'working')],
          title: _title);
      expect(find.byType(AgentCard), findsNWidgets(2));
      await tester.tap(find.byTooltip('Compact list'));
      await settle(tester);
      expect(h.appSettings.density, BoardDensity.compact);

      await h.changeStatuses(tester, 'a', [for (var i = 1; i <= 2; i++) _pane(i, 'working')],
          title: _title);
      expect(find.byType(AgentCompactRow), findsNWidgets(2), reason: 'two agents, but compact was chosen');
      await teardownBoard(tester, h);
    });

    testWidgets('the saved choice is what the board opens with', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [for (var i = 1; i <= 2; i++) _pane(i, 'working')]),
      ]);
      await h.appSettings.setDensity(BoardDensity.compact);
      await pumpBoard(tester, h, height: _tall);

      expect(find.byType(AgentCompactRow), findsNWidgets(2));
      await teardownBoard(tester, h);
    });

    testWidgets('Settings > Appearance > Agent list sets Auto, Cards or Compact, so Auto can come back',
        (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [for (var i = 1; i <= 6; i++) _pane(i, 'working')]),
      ]);
      await pumpBoard(tester, h, height: _tall);
      expect(h.appSettings.density, BoardDensity.cards, reason: 'the harness pins cards');
      expect(find.byType(AgentCard), findsNWidgets(6));

      Finder option(String label) => find.descendant(
            of: find.byType(Segmented<BoardDensity>),
            matching: find.text(label),
          );
      Future<void> choose(String label) async {
        await tester.tap(find.byKey(FloatingTabBar.tabKey('Settings')));
        await settle(tester);
        await tester.tap(option(label));
        await settle(tester);
        await tester.tap(find.byKey(FloatingTabBar.tabKey('Agents')));
        await settle(tester);
      }

      await tester.tap(find.byKey(FloatingTabBar.tabKey('Settings')));
      await settle(tester);
      expect(find.text('Agent list'), findsOneWidget);
      expect(
        find.text('Auto uses cards up to 4 agents and the compact list from 5; '
            'a blocked agent always keeps its answers.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(FloatingTabBar.tabKey('Agents')));
      await settle(tester);

      await choose('Auto');
      expect(h.appSettings.density, BoardDensity.auto);
      expect(find.byType(AgentCompactRow), findsNWidgets(6), reason: 'six agents: compact from five');

      await choose('Compact');
      expect(h.appSettings.density, BoardDensity.compact);
      expect(find.byType(AgentCompactRow), findsNWidgets(6));

      await choose('Cards');
      expect(h.appSettings.density, BoardDensity.cards);
      expect(find.byType(AgentCard), findsNWidgets(6));

      // The board's own button still makes an explicit choice, and the
      // control in Settings shows it.
      await tester.tap(find.byTooltip('Compact list'));
      await settle(tester);
      expect(h.appSettings.density, BoardDensity.compact);
      await choose('Auto');
      expect(h.appSettings.density, BoardDensity.auto);
      await teardownBoard(tester, h);
    });
  });
}
