// The board and its chrome tell one story about what needs you: the status
// line, Needs you and its `to review` count agree, what is out of reach says
// so instead of being counted, reviewing clears to review on this phone only,
// wait times are honest, and only the first agent that needs you is a card.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/attention_set.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agents/agent_card.dart';
import 'package:herdr_mobile/ui/features/agents/reply_sheet.dart';
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../support/shot.dart' show loadAppFonts;
import 'board_support.dart';
import 'ui_harness.dart';

MachineProfile _profile(String id) => MachineProfile(id: id, label: 'box-$id', host: '$id.example', username: 'dev');

Pane _pane(int i, String status) => (id: 'w1:p$i', ws: 'w1', agent: 'claude', status: status);

String _title(String paneId) => 'task ${paneId.split('p').last}';

({MachineProfile profile, Map<String, dynamic> snapshot}) _machine(String id, List<Pane> panes) =>
    (profile: _profile(id), snapshot: snapshotWith(panes, title: _title));

const _tall = 2400.0;

Finder _card(String title) => find.widgetWithText(AgentCard, title);

Finder _row(String title) => find.widgetWithText(AgentCompactRow, title);

int? _sectionCount(WidgetTester tester, String label) =>
    tester.widget<SectionLabel>(find.byWidgetPredicate((w) => w is SectionLabel && w.label == label)).count;

/// The board's status line, under the title.
String _statusLine(WidgetTester tester) => statusLine(tester);

double _top(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

/// What the Agents tab's badge says, as a screen reader hears it.

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
    testWidgets('the badge, the status line and the sections add up, and the count is said once', (tester) async {
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

      expect(_statusLine(tester), startsWith('2 need you · 2 to review · 1 working'));
      expect(find.textContaining('need you'), findsOneWidget, reason: 'the board says it once');
      expect(_sectionCount(tester, 'Needs you'), isNull, reason: 'the status line counts it');
      expect(toReviewCount(tester), 2);
      expect(statusNeedsYou(tester), '2 need you', reason: 'questions only: finished work is not counted');
      expect(_wanted(tester), 4);
      expect(find.byType(AppChip), findsNothing, reason: 'no filter chips: they repeated the sections');
      expect(find.byType(FloatingPill), findsNothing, reason: 'no triage pill: it repeated the count');
      semantics.dispose();
      await teardownBoard(tester, h);
    });

    testWidgets('one blocked agent: "1 needs you", and nothing to review adds nothing', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked'), _pane(2, 'working')]),
      ]);
      await pumpBoard(tester, h, height: _tall);

      expect(_statusLine(tester), startsWith('1 needs you · 1 working'));
      expect(find.textContaining('to review'), findsNothing);
      await teardownBoard(tester, h);
    });

    testWidgets('with nothing blocked the board says no count: finished work is not a question', (tester) async {
      final semantics = tester.ensureSemantics();
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'done'), _pane(2, 'done'), _pane(3, 'working')]),
      ]);
      await pumpBoard(tester, h, height: _tall);

      expect(find.textContaining('need'), findsNothing);
      expect(_statusLine(tester), startsWith('2 to review · 1 working'));
      expect(statusNeedsYou(tester), isNull);
      expect(toReviewCount(tester), 2, reason: 'the board still says it, quietly');
      semantics.dispose();
      await teardownBoard(tester, h);
    });

    testWidgets('the Needs you header starts the triage sheet over the blocked agents only', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked'), _pane(2, 'blocked'), _pane(3, 'done'), _pane(4, 'done')]),
      ]);
      await pumpBoard(tester, h, height: _tall);

      await tester.tap(find.byKey(const ValueKey('answer-one-by-one')));
      await settle(tester);

      expect(find.byType(ReplySheet), findsOneWidget);
      expect(find.text('1 of 2 need you'), findsOneWidget, reason: 'finished agents are not walked');
      await teardownBoard(tester, h);
    });

    testWidgets('an offline machine\'s agents leave every count, and the board says they are offline', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked'), _pane(2, 'done')]),
        _machine('b', [_pane(3, 'blocked')]),
      ]);
      await pumpBoard(tester, h, height: _tall);
      expect(_statusLine(tester), startsWith('2 need you · 1 to review'));
      expect(find.byKey(toReviewKey), findsOneWidget);

      h.network.goOffline();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('need you'), findsNothing, reason: 'nothing out of reach is counted');
      expect(_wanted(tester), 0, reason: 'nothing out of reach can be answered or marked reviewed');
      expect(find.text('2 offline'), findsOneWidget, reason: 'Needs you lists them, last known');
      expect(_statusLine(tester), contains('1 offline to review'), reason: 'said, not counted');
      expect(find.byKey(toReviewKey), findsNothing, reason: 'a button that would pick nothing is not offered');
      h.network.goOnline();
      await teardownBoard(tester, h);
    });

    testWidgets('the board runs Needs you, Working, To review, then Idle', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'idle'), _pane(2, 'working'), _pane(3, 'done'), _pane(4, 'blocked')]),
      ]);
      await pumpBoard(tester, h, height: _tall);

      Finder section(String label) => find.widgetWithText(SectionLabel, label);
      final ys = [
        _top(tester, section('Needs you')),
        _top(tester, _card('task 4')),
        _top(tester, section('Working')),
        _top(tester, _row('task 2')),
        _top(tester, section('To review')),
        _top(tester, _row('task 3')),
        _top(tester, section('Idle')),
        _top(tester, _row('task 1')),
      ];
      expect(ys, orderedEquals([...ys]..sort()), reason: 'top to bottom');
      expect(ys.toSet(), hasLength(ys.length));
      await teardownBoard(tester, h);
    });
  });

  group('reviewing', () {
    testWidgets('opening a finished agent clears Done everywhere on the phone, and herdr is told nothing', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked'), _pane(2, 'done'), _pane(3, 'done')]),
      ]);
      await pumpBoard(tester, h, height: _tall);
      expect(toReviewCount(tester), 2);
      expect(statusNeedsYou(tester), '1 needs you');

      await tester.tap(_row('task 2'));
      await settle(tester);
      expect(find.byType(PaneScreen), findsOneWidget);
      expect(_wanted(tester), 2);
      await _back(tester);

      expect(_statusLine(tester), startsWith('1 needs you'));
      expect(statusNeedsYou(tester), '1 needs you', reason: 'reviewing does not touch what needs you');
      expect(toReviewCount(tester), 1);
      expect(h.fleet.agents.firstWhere((a) => a.pane.id == 'w1:p2').pane.status.name, 'idle');

      final calls = h.transports['a']!.calls.map((c) => c.$1);
      expect(
        calls.where((m) => m.contains('focus')),
        isEmpty,
        reason: 'focusing would clear herdr\'s own state and move the desktop view',
      );
      final herdrStatuses = [for (final p in h.transports['a']!.snapshot['panes'] as List) (p as Map)['agent_status']];
      expect(herdrStatuses, ['blocked', 'done', 'done'], reason: 'herdr still says done');
      semantics.dispose();
      await teardownBoard(tester, h);
    });

    testWidgets('a reviewed agent that finishes again is Done again', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'done')]),
      ]);
      await pumpBoard(tester, h, height: _tall);
      await tester.tap(_row('task 1'));
      await settle(tester);
      await _back(tester);
      expect(_wanted(tester), 0);

      await h.changeStatuses(tester, 'a', [_pane(1, 'working')], title: _title);
      await h.changeStatuses(tester, 'a', [_pane(1, 'done')], title: _title);

      expect(_wanted(tester), 1);
      expect(toReviewCount(tester), 1);
      await teardownBoard(tester, h);
    });
  });

  group('honest wait time', () {
    testWidgets('a change found after a 30-minute gap reads ≤ 30m, never <1m', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'working')]),
      ], observedAgo: const Duration(minutes: 30));
      await pumpBoard(tester, h, height: _tall);

      // The app was away for half an hour (its clock then read 30 minutes
      // ago); while it was, the agent started waiting for the person.
      h.observedAgo = Duration.zero;
      h.transports['a']!.snapshot = snapshotWith([_pane(1, 'blocked')], title: _title);
      h.fleet.connection('a')!.reconnect();
      await settle(tester);

      expect(_said('needs you, at most 30 minutes'), findsOneWidget);
      expect(find.textContaining('<1m'), findsNothing);
      await teardownBoard(tester, h);
    });

    testWidgets('a change seen live is exact', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'working')]),
      ]);
      await pumpBoard(tester, h, height: _tall);

      await h.changeStatuses(tester, 'a', [_pane(1, 'blocked')], ago: const Duration(minutes: 12), title: _title);

      expect(find.text('12m'), findsOneWidget);
      expect(_said('needs you, 12 minutes'), findsOneWidget);
      expect(find.textContaining('≤'), findsNothing);
      await teardownBoard(tester, h);
    });
  });

  group('order', () {
    testWidgets('Needs you: the one that has waited longest is on top, not the one with the lowest id', (tester) async {
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

      expect(_said('needs you, 20 minutes'), findsOneWidget);
      expect(_said('needs you, 5 minutes'), findsOneWidget);
      expect(_said('needs you, 1 minute'), findsOneWidget);
      final y = [
        for (final i in [1, 2, 3]) _top(tester, find.text('task $i')),
      ];
      expect(_card('task 2'), findsOneWidget, reason: 'the longest waiting is the one in front');
      expect(y[1], lessThan(y[0]), reason: '20 minutes above 5');
      expect(y[0], lessThan(y[2]), reason: '5 minutes above 1');
      await teardownBoard(tester, h);
    });

    // Owner decision: newest first within each section.
    testWidgets('an agent that finishes moves from Working to the top of To review', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'working'), _pane(2, 'working')]),
      ]);
      await pumpBoard(tester, h, height: _tall);
      final review = find.widgetWithText(SectionLabel, 'To review');

      await h.changeStatuses(
        tester,
        'a',
        [_pane(1, 'working'), _pane(2, 'done')],
        ago: const Duration(minutes: 40),
        title: _title,
      );
      expect(_top(tester, _row('task 1')), lessThan(_top(tester, review)), reason: 'still working');
      expect(_top(tester, _row('task 2')), greaterThan(_top(tester, review)));
      await h.changeStatuses(
        tester,
        'a',
        [_pane(1, 'done'), _pane(2, 'done')],
        ago: const Duration(minutes: 2),
        title: _title,
      );

      expect(find.widgetWithText(SectionLabel, 'Working'), findsNothing, reason: 'nothing works');
      expect(_top(tester, _row('task 1')), lessThan(_top(tester, _row('task 2'))), reason: 'the newest finished first');
      await teardownBoard(tester, h);
    });
  });

  group('quiet', () {
    testWidgets('a working agent quiet for minutes says so; the order never moves for it', (tester) async {
      // The stream went live 14 minutes ago (the connection's clock starts that
      // far behind) and has heard nothing since.
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'working'), _pane(2, 'working')]),
      ], observedAgo: const Duration(minutes: 14));
      await pumpBoard(tester, h, height: _tall);
      expect(_said(RegExp('quiet')), findsNothing, reason: 'on connecting, nothing has been listened to yet');

      final panes = [_pane(1, 'working'), _pane(2, 'working')];
      await h.changeStatuses(tester, 'a', panes, title: _title);
      expect(_said('working, quiet for 14 minutes'), findsNWidgets(2), reason: 'the next refresh, 14 minutes on');
      expect(
        _top(tester, _row('task 1')),
        lessThan(_top(tester, _row('task 2'))),
        reason: 'they started working together: pane order',
      );

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
      await h.changeStatuses(tester, 'a', panes, title: _title);
      expect(
        _top(tester, _row('task 1')),
        lessThan(_top(tester, _row('task 2'))),
        reason: 'quiet or not, a row keeps its place',
      );
      expect(_said('working, quiet for 14 minutes'), findsOneWidget, reason: 'only task 2 is still quiet');
      await teardownBoard(tester, h);
    });

    testWidgets('an agent that is not working never says quiet', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked'), _pane(2, 'done'), _pane(3, 'idle')]),
      ], observedAgo: const Duration(minutes: 14));
      await pumpBoard(tester, h, height: _tall);
      await h.changeStatuses(tester, 'a', [_pane(1, 'blocked'), _pane(2, 'done'), _pane(3, 'idle')], title: _title);

      expect(find.textContaining('quiet'), findsNothing);
      await teardownBoard(tester, h);
    });
  });

  group('cards and rows', () {
    testWidgets('the first agent that needs you is a card, every other agent a row', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [
          _pane(1, 'blocked'),
          _pane(2, 'blocked'),
          _pane(3, 'blocked'),
          _pane(4, 'working'),
          _pane(5, 'done'),
        ]),
      ]);
      await pumpBoard(tester, h, height: _tall);

      expect(find.byType(AgentCard), findsOneWidget, reason: 'one decision in front');
      expect(_card('task 1'), findsOneWidget, reason: 'the longest waiting');
      expect(find.byType(AgentCompactRow), findsNWidgets(4), reason: 'the other two waiting are named in rows');
      expect(_top(tester, _row('task 2')), greaterThan(_top(tester, _card('task 1'))));
      await teardownBoard(tester, h);
    });

    testWidgets('Needs you cannot be folded; Working can', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked'), _pane(2, 'working')]),
      ]);
      await pumpBoard(tester, h, height: _tall);

      await tester.tap(find.widgetWithText(SectionLabel, 'Needs you'));
      await settle(tester);
      expect(_card('task 1'), findsOneWidget, reason: 'still there');

      await tester.tap(find.byKey(const ValueKey('header/working')));
      await settle(tester);
      expect(_row('task 2').hitTestable(), findsNothing, reason: 'the section folds');
      await teardownBoard(tester, h);
    });

    testWidgets('the to-review count is a quiet button: secondary words, not the accent', (tester) async {
      final semantics = tester.ensureSemantics();
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'done'), _pane(2, 'done'), _pane(3, 'working')]),
      ]);
      await pumpBoard(tester, h, height: _tall);
      final ds = tester.element(find.byType(HomeShell)).ds;
      final words = tester.widget<Text>(find.descendant(of: find.byKey(toReviewKey), matching: find.byType(Text)));
      expect(words.style?.color, ds.textSecondary, reason: 'it tidies, it answers nothing');
      expect(
        tester.getSemantics(find.byKey(toReviewKey)),
        isSemantics(label: '2 to review, select them', isButton: true, hasTapAction: true),
      );
      semantics.dispose();
      await teardownBoard(tester, h);
    });

    testWidgets('the header holds two actions, + and Settings: no history button', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'working')]),
      ]);
      await pumpBoard(tester, h, height: _tall);

      final actions = find.descendant(of: find.byType(SliverLargeTitle), matching: find.byType(CircleButton));
      expect(actions, findsNWidgets(2), reason: 'the budget (DESIGN.md Hierarchy 6)');
      expect(find.byTooltip('New agent session'), findsOneWidget);
      expect(find.byTooltip('Settings'), findsOneWidget);
      await teardownBoard(tester, h);
    });
  });
}

/// A time label by what a screen reader hears: the visible text is the time
/// only, the words carry the state.
Finder _said(Pattern label) => find.byWidgetPredicate((w) {
  if (w is! Semantics) return false;
  final l = w.properties.label;
  return l != null && (label is String ? l == label : label.allMatches(l).isNotEmpty);
});
