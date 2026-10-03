// The agents home as a live board: previews, answers without leaving it,
// triage, density, and the cost of all that on a virtualised list.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/pane_preview.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/core/chrome.dart';
import 'package:herdr_mobile/ui/core/step_clock.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agents/agent_card.dart';
import 'package:herdr_mobile/ui/features/agents/reply_sheet.dart';
import 'package:herdr_mobile/ui/features/agents/triage_pill.dart';
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/shot.dart' show loadAppFonts;
import 'board_support.dart';
import 'ui_harness.dart';

MachineProfile _profile(String id, String label) =>
    MachineProfile(id: id, label: label, host: '$id.example', username: 'dev');

Pane _pane(int i, String status, {String agent = 'claude'}) =>
    (id: 'w1:p$i', ws: 'w1', agent: agent, status: status);

String _title(String paneId) => 'task ${paneId.split('p').last}';

({MachineProfile profile, Map<String, dynamic> snapshot}) _machine(
  String id,
  List<Pane> panes, {
  String? label,
}) =>
    (profile: _profile(id, label ?? 'box-$id'), snapshot: snapshotWith(panes, title: _title));

const _tall = 2400.0;

const _menu = PromptInfo(
  question: 'Do you want to proceed?\nBash command: npm test',
  replies: [
    QuickReply(label: '1. Yes', keys: ['1', 'enter']),
    QuickReply(label: '2. Yes, and don’t ask again', keys: ['2', 'enter']),
    QuickReply(label: '3. No, and tell Claude what to do', keys: ['3', 'enter']),
  ],
);

const _risky = PromptInfo(
  question: 'Run this command?\nrm -rf build',
  replies: [
    QuickReply(label: '1. Yes, once', keys: ['1', 'enter']),
    QuickReply(label: '2. Yes, delete everything', keys: ['2', 'enter'], needsConfirm: true),
    QuickReply(label: '3. No', keys: ['3', 'enter']),
  ],
);

List<Map<String, dynamic>> _keysSent(BoardHarness h, String machine) => [
      for (final (m, p) in h.transports[machine]!.calls)
        if (m == 'pane.send_keys') p,
    ];

Finder _card(String title) => find.widgetWithText(AgentCard, title);

void main() {
  setUpAll(loadAppFonts);

  group('preview', () {
    testWidgets('a working card shows the end of the terminal, the newest line strongest',
        (tester) async {
      final h = await BoardHarness.create([_machine('a', [_pane(1, 'working')])]);
      h.previews.set('a/w1:p1', ['reading schema.sql', 'writing migration', 'running tests']);
      await pumpBoard(tester, h, height: _tall);

      final card = _card('task 1');
      expect(find.descendant(of: card, matching: find.text('reading schema.sql')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('running tests')), findsOneWidget);
      Color colour(String t) => tester
          .widget<Text>(find.descendant(of: card, matching: find.text(t)))
          .style!
          .color!;
      expect(colour('running tests'), isNot(colour('reading schema.sql')),
          reason: 'the newest row is the one to read');
      await teardownBoard(tester, h);
    });

    testWidgets('a done card keeps 3 rows, a working card 5', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'working'), _pane(2, 'done')]),
      ]);
      final lines = ['l1', 'l2', 'l3', 'l4', 'l5', 'l6', 'l7'];
      h.previews.set('a/w1:p1', lines);
      h.previews.set('a/w1:p2', lines);
      await pumpBoard(tester, h, height: _tall);

      int shown(String title) => lines
          .where((l) => find.descendant(of: _card(title), matching: find.text(l)).evaluate().isNotEmpty)
          .length;
      expect(shown('task 1'), 5);
      expect(shown('task 2'), 3);
      await teardownBoard(tester, h);
    });

    testWidgets('an idle agent shows no preview and its pane is never read', (tester) async {
      final h = await BoardHarness.create([_machine('a', [_pane(1, 'idle'), _pane(2, 'unknown')])]);
      h.previews.set('a/w1:p1', ['> ']);
      await pumpBoard(tester, h, height: _tall);

      expect(h.previews.opened, isEmpty, reason: 'previews of idle panes are noise and traffic');
      expect(find.text('> '), findsNothing);
      await teardownBoard(tester, h);
    });

    testWidgets('the card keeps its height while lines arrive', (tester) async {
      final h = await BoardHarness.create([_machine('a', [_pane(1, 'working')])]);
      await pumpBoard(tester, h, height: _tall);
      double height() => tester.getSize(find.byType(AgentCard)).height;

      final loading = height();
      for (final lines in [
        <String>[],
        ['one'],
        ['one', 'two', 'three'],
        ['1', '2', '3', '4', '5', '6', '7', '8'],
      ]) {
        h.previews.set('a/w1:p1', lines);
        await tester.pump();
        expect(height(), loading, reason: '${lines.length} lines moved the rows below it');
      }
      await teardownBoard(tester, h);
    });

    testWidgets('an offline machine dims its cards once and says so', (tester) async {
      final h = await BoardHarness.create([_machine('a', [_pane(1, 'working')])]);
      h.previews.set('a/w1:p1', ['last known line']);
      await pumpBoard(tester, h, height: _tall);
      h.network.goOffline();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.descendant(of: _card('task 1'), matching: find.text('offline')), findsOneWidget);
      expect(find.descendant(of: _card('task 1'), matching: find.byType(Opacity)), findsOneWidget);
      expect(find.text('last known line'), findsOneWidget, reason: 'the data stays, marked stale');
      expect(find.byTooltip('Reply to task 1'), findsNothing, reason: 'cannot answer offline');
      await teardownBoard(tester, h);
    });
  });

  group('watching', () {
    testWidgets('only built cards are watched, and scrolling past releases them', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [for (var i = 1; i <= 30; i++) _pane(i, 'working')]),
      ]);
      await pumpBoard(tester, h);

      expect(h.previews.openCount, inInclusiveRange(1, 10), reason: 'a screenful, not 30');
      expect(h.previews.open['a/w1:p1'], 1);

      await tester.fling(find.byType(CustomScrollView).first, const Offset(0, -20000), 20000);
      await settle(tester);
      expect(h.previews.open['a/w1:p1'], 0, reason: 'scrolled far away: no reads for it');
      expect(h.previews.openCount, inInclusiveRange(1, 10));
      await teardownBoard(tester, h);
      expect(h.previews.openCount, 0, reason: 'a leaked watcher reads forever');
    });

    testWidgets('collapsing a section releases its cards', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'working'), _pane(2, 'working'), _pane(3, 'done')]),
      ]);
      await pumpBoard(tester, h, height: _tall);
      expect(h.previews.openCount, 3);

      await tester.tap(find.text('Working').last);
      await tester.pump();
      await settle(tester);
      expect(h.previews.openCount, 1, reason: 'only the done card is still on the board');
      await teardownBoard(tester, h);
    });

    testWidgets('an agent that goes idle stops being watched', (tester) async {
      final h = await BoardHarness.create([_machine('a', [_pane(1, 'working')])]);
      await pumpBoard(tester, h, height: _tall);
      expect(h.previews.openCount, 1);

      await h.changeStatuses(tester, 'a', [_pane(1, 'idle')], title: _title);
      expect(h.previews.openCount, 0);
      await teardownBoard(tester, h);
    });

    testWidgets('compact rows watch nothing', (tester) async {
      final h = await BoardHarness.create([_machine('a', [_pane(1, 'working'), _pane(2, 'blocked')])]);
      await pumpBoard(tester, h, height: _tall);
      expect(h.previews.openCount, 2);

      await tester.tap(find.byTooltip('Compact list'));
      await settle(tester);
      expect(find.byType(AgentCard), findsNothing);
      expect(find.byType(AgentCompactRow), findsNWidgets(2));
      expect(h.previews.openCount, 0);

      await tester.tap(find.byTooltip('Cards with preview'));
      await settle(tester);
      expect(find.byType(AgentCard), findsNWidgets(2));
      expect(h.previews.openCount, 2);
      await teardownBoard(tester, h);
    });
  });

  group('answering from the card', () {
    Future<BoardHarness> blocked(WidgetTester tester, {PromptInfo prompt = _menu}) async {
      final h = await BoardHarness.create([_machine('a', [_pane(1, 'blocked')])]);
      h.previews.set('a/w1:p1', ['…context…'], prompt: prompt);
      await pumpBoard(tester, h, height: _tall);
      return h;
    }

    testWidgets('shows the question and one chip per option, labelled with the option',
        (tester) async {
      final h = await blocked(tester);
      expect(find.textContaining('Do you want to proceed?'), findsOneWidget);
      for (final r in _menu.replies) {
        expect(find.text(r.label), findsOneWidget);
      }
      await teardownBoard(tester, h);
    });

    testWidgets('tapping a chip sends that option to that pane, once, and the chip says so',
        (tester) async {
      final h = await blocked(tester);

      final chip = tester.getCenter(find.text('2. Yes, and don’t ask again'));
      await tester.tapAt(chip);
      await tester.pump();
      await tester.tapAt(chip); // a second tap on the same spot
      await tester.pump(const Duration(milliseconds: 50));

      expect(_keysSent(h, 'a'), [
        {'pane_id': 'w1:p1', 'keys': ['2', 'enter']},
      ]);
      expect(find.text('Sent: 2. Yes, and don’t ask again'), findsOneWidget);
      // The others step back: no second answer by accident.
      await tester.tap(find.text('3. No, and tell Claude what to do'), warnIfMissed: false);
      await tester.pump();
      expect(_keysSent(h, 'a'), hasLength(1));
      await tester.pump(const Duration(seconds: 4));
      await teardownBoard(tester, h);
    });

    testWidgets('the card keeps its height through every state of the chips', (tester) async {
      final h = await blocked(tester, prompt: _risky);
      double height() => tester.getSize(find.byType(AgentCard)).height;
      final idle = height();

      await tester.tap(find.text('2. Yes, delete everything'));
      await tester.pump();
      expect(find.text('Tap again to confirm'), findsOneWidget);
      expect(height(), idle);

      await tester.tap(find.text('Tap again to confirm'));
      await tester.pump();
      expect(find.text('Sent: 2. Yes, delete everything'), findsOneWidget);
      expect(height(), idle);
      await tester.pump(const Duration(seconds: 4));
      await teardownBoard(tester, h);
    });

    testWidgets('a risky option asks first and sends only on the second tap', (tester) async {
      final h = await blocked(tester, prompt: _risky);

      await tester.tap(find.text('2. Yes, delete everything'));
      await tester.pump();
      expect(_keysSent(h, 'a'), isEmpty);
      expect(find.text('Tap again to confirm'), findsOneWidget);

      await tester.tap(find.text('Tap again to confirm'));
      await tester.pump();
      expect(_keysSent(h, 'a').single['keys'], ['2', 'enter']);
      await tester.pump(const Duration(seconds: 4));
      await teardownBoard(tester, h);
    });

    testWidgets('a failed send says so on the chip and a tap retries it', (tester) async {
      final h = await blocked(tester);
      h.transports['a']!.failure = const HerdrTransportException('Connection reset');

      await tester.tap(find.text('1. Yes'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('Couldn’t send'), findsOneWidget);
      expect(find.text('1. Yes'), findsNothing, reason: 'the failure sits on the chip that failed');

      h.transports['a']!.failure = null;
      await tester.tap(find.textContaining('Couldn’t send'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Sent: 1. Yes'), findsOneWidget);
      expect(_keysSent(h, 'a'), hasLength(2), reason: 'one failed attempt, one retry');
      await tester.pump(const Duration(seconds: 4));
      await teardownBoard(tester, h);
    });

    testWidgets('a new question replaces "Sent" at once instead of after the hold',
        (tester) async {
      final h = await blocked(tester);
      await tester.tap(find.text('1. Yes'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Sent: 1. Yes'), findsOneWidget);

      h.previews.set('a/w1:p1', ['next'], prompt: _risky);
      await tester.pump();
      expect(find.text('Sent: 1. Yes'), findsNothing);
      expect(find.text('1. Yes, once'), findsOneWidget, reason: 'the agent asked again: answer that');
      await tester.pump(const Duration(seconds: 4));
      await teardownBoard(tester, h);
    });

    testWidgets('more than five options: four chips and a way to see them all', (tester) async {
      final seven = PromptInfo(
        question: 'Pick one',
        replies: [
          for (var i = 1; i <= 7; i++) QuickReply(label: 'option $i', keys: ['$i', 'enter']),
        ],
      );
      final h = await blocked(tester, prompt: seven);
      expect(find.text('option 4'), findsOneWidget);
      expect(find.text('option 5'), findsNothing);
      expect(find.text('3 more…'), findsOneWidget);

      await tester.tap(find.text('3 more…'));
      await settle(tester);
      expect(find.text('option 7'), findsOneWidget, reason: 'the sheet lists every option');
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('a blocked agent with no prompt we understand still shows its terminal',
        (tester) async {
      final h = await BoardHarness.create([_machine('a', [_pane(1, 'blocked')])]);
      h.previews.set('a/w1:p1', ['Allow the agent to edit 3 files?']);
      await pumpBoard(tester, h, height: _tall);

      expect(find.text('Allow the agent to edit 3 files?'), findsOneWidget);
      expect(find.byTooltip('Reply to task 1'), findsOneWidget);
      await teardownBoard(tester, h);
    });

    testWidgets('on an offline machine there are no chips to tap: only the last look remains',
        (tester) async {
      final h = await blocked(tester);
      expect(find.text('1. Yes'), findsOneWidget);
      h.network.goOffline();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('1. Yes'), findsNothing, reason: 'an old question must not be answerable');
      expect(find.text('…context…'), findsOneWidget);
      expect(_keysSent(h, 'a'), isEmpty);
      await teardownBoard(tester, h);
    });
  });

  group('time in state', () {
    testWidgets('says how long, by the minute, once a change was seen; nothing before',
        (tester) async {
      final h = await BoardHarness.create([_machine('a', [_pane(1, 'idle'), _pane(2, 'idle')])]);
      await pumpBoard(tester, h, height: _tall);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining(RegExp(r'idle \d')), findsNothing, reason: 'first sight: unknown, so unclaimed');

      await h.changeStatuses(tester, 'a', [_pane(1, 'working'), _pane(2, 'idle')],
          ago: const Duration(minutes: 12), title: _title);
      expect(find.text('working 12m'), findsOneWidget);
      await teardownBoard(tester, h);
    });
  });

  group('triage', () {
    testWidgets('the pill counts agents that can be answered, and goes when none is',
        (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked'), _pane(2, 'blocked'), _pane(3, 'working')]),
        _machine('b', [_pane(4, 'blocked')]),
      ]);
      await pumpBoard(tester, h, height: _tall);
      expect(find.text('3 need you'), findsOneWidget);

      h.network.goOffline();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(TriagePill), findsNothing, reason: 'offline: nothing can be answered');
      h.network.goOnline();
      await teardownBoard(tester, h);
    });

    testWidgets('the sheet walks the blocked agents across machines, prev and next', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked')]),
        _machine('b', [_pane(2, 'blocked')]),
      ]);
      h.previews.set('a/w1:p1', ['x'], prompt: _menu);
      h.previews.set('b/w1:p2', ['y'], prompt: _risky);
      await pumpBoard(tester, h, height: _tall);

      await tester.tap(find.text('2 need you'));
      await settle(tester);
      expect(find.text('1 of 2 need you'), findsOneWidget);
      expect(find.descendant(of: find.byType(ReplySheet), matching: find.text('task 1')), findsOneWidget);

      await tester.tap(find.byTooltip('Next agent'));
      await settle(tester);
      expect(find.text('2 of 2 need you'), findsOneWidget);
      expect(find.descendant(of: find.byType(ReplySheet), matching: find.text('task 2')), findsOneWidget);
      expect(find.descendant(of: find.byType(ReplySheet), matching: find.text('1. Yes, once')), findsOneWidget);

      await tester.tap(find.byTooltip('Next agent'));
      await settle(tester);
      expect(find.text('1 of 2 need you'), findsOneWidget, reason: 'wraps around');
      await tester.tap(find.byTooltip('Previous agent'));
      await settle(tester);
      expect(find.text('2 of 2 need you'), findsOneWidget);
      await teardownBoard(tester, h);
    });

    testWidgets('answering advances to the next agent, and the last answer closes the sheet',
        (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked'), _pane(2, 'blocked')]),
      ]);
      h.previews.set('a/w1:p1', ['x'], prompt: _menu);
      h.previews.set('a/w1:p2', ['y'], prompt: _risky);
      await pumpBoard(tester, h, height: _tall);

      await tester.tap(find.text('2 need you'));
      await settle(tester);
      Finder inSheet(Finder f) => find.descendant(of: find.byType(ReplySheet), matching: f);
      expect(inSheet(find.text('task 1')), findsOneWidget);

      await tester.tap(inSheet(find.text('1. Yes')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(inSheet(find.text('Sent: 1. Yes')), findsOneWidget);
      expect(_keysSent(h, 'a').single, {'pane_id': 'w1:p1', 'keys': ['1', 'enter']});

      await tester.pump(const Duration(milliseconds: 800));
      await settle(tester);
      expect(inSheet(find.text('task 2')), findsOneWidget, reason: 'moved on by itself');
      expect(find.text('2 of 2 need you'), findsOneWidget);

      // The agents report back that they no longer wait: nobody is left.
      await tester.tap(inSheet(find.text('3. No')));
      await tester.pump(const Duration(milliseconds: 100));
      await h.changeStatuses(tester, 'a', [_pane(1, 'working'), _pane(2, 'working')], title: _title);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(find.byType(ReplySheet), findsNothing, reason: 'all answered: the sheet leaves');
      expect(find.byType(TriagePill), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      await teardownBoard(tester, h);
    });

    testWidgets('the pill appearing does not rebuild the list or move its scroll position',
        (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [for (var i = 1; i <= 12; i++) _pane(i, 'working')]),
      ]);
      await pumpBoard(tester, h);
      final scroll = find.byType(CustomScrollView).first;
      await tester.drag(scroll, const Offset(0, -900));
      await tester.pump(const Duration(milliseconds: 400));
      final offset = tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels;
      // A card clearly on screen (the first built one may be in the cache above).
      final visible = tester
          .widgetList<AgentCard>(find.byType(AgentCard))
          .firstWhere((w) => tester.getRect(find.byWidget(w)).top >= 160)
          .agent
          .title;
      final card = tester.element(_card(visible));

      await h.changeStatuses(tester, 'a',
          [for (var i = 1; i <= 12; i++) _pane(i, i == 12 ? 'blocked' : 'working')],
          title: _title);
      expect(find.byType(TriagePill), findsOneWidget);
      expect(tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels, offset);
      expect(tester.element(_card(visible)), same(card),
          reason: 'cards were inflated again when the pill showed up');
      await teardownBoard(tester, h);
    });

    testWidgets('the last card clears both the pill and the tab bar', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked'), for (var i = 2; i <= 8; i++) _pane(i, 'working')]),
      ]);
      await pumpBoard(tester, h);
      for (var i = 0; i < 3; i++) {
        await tester.fling(find.byType(CustomScrollView).first, const Offset(0, -5000), 5000);
        await settle(tester);
      }
      final pill = tester.getRect(find.byType(TriagePill));
      final last = tester
          .widgetList(find.byType(AgentCard))
          .map((w) => tester.getRect(find.byWidget(w)).bottom)
          .reduce((a, b) => a > b ? a : b);
      expect(last, lessThanOrEqualTo(pill.top),
          reason: 'the pill must never cover the last agent');
      expect(pill.bottom, lessThanOrEqualTo(tester.getRect(find.byType(FloatingTabBar)).top));
      await teardownBoard(tester, h);
    });
  });

  group('reply sheet', () {
    Future<BoardHarness> working(WidgetTester tester) async {
      final h = await BoardHarness.create([_machine('a', [_pane(1, 'working')])]);
      h.previews.set('a/w1:p1', ['step one', 'step two']);
      await pumpBoard(tester, h, height: _tall);
      await tester.tap(find.byTooltip('Reply to task 1'));
      await settle(tester);
      return h;
    }

    testWidgets('shows the live preview and watches the pane only while open', (tester) async {
      final h = await working(tester);
      expect(find.descendant(of: find.byType(ReplySheet), matching: find.text('step two')), findsOneWidget);
      expect(h.previews.open['a/w1:p1'], 2, reason: 'the card and the sheet');

      h.previews.set('a/w1:p1', ['step one', 'step two', 'step three']);
      await tester.pump();
      expect(find.descendant(of: find.byType(ReplySheet), matching: find.text('step three')), findsOneWidget);

      await tester.tapAt(const Offset(200, 20));
      await settle(tester);
      expect(find.byType(ReplySheet), findsNothing);
      expect(h.previews.open['a/w1:p1'], 1, reason: 'the sheet let go of the pane');
      await teardownBoard(tester, h);
    });

    testWidgets('a typed line is sent with enter and the field clears', (tester) async {
      final semantics = tester.ensureSemantics();
      final h = await working(tester);
      await tester.enterText(find.byType(TextField), 'use the staging db');
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Send'));
      await tester.pump(const Duration(milliseconds: 50));

      final input = [
        for (final (m, p) in h.transports['a']!.calls)
          if (m == 'pane.send_input') p,
      ];
      expect(input.single, {'pane_id': 'w1:p1', 'text': 'use the staging db', 'keys': ['enter']});
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
      expect(find.textContaining('Sent:'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      semantics.dispose();
      await teardownBoard(tester, h);
    });

    testWidgets('send does nothing for an empty field; the quick keys send their keys',
        (tester) async {
      final semantics = tester.ensureSemantics();
      final h = await working(tester);
      await tester.tap(find.bySemanticsLabel('Send'), warnIfMissed: false);
      await tester.pump();
      expect(_keysSent(h, 'a'), isEmpty);

      await tester.tap(find.text('esc'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(seconds: 4));
      await tester.tap(find.bySemanticsLabel('Up'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(seconds: 4));
      expect([for (final c in _keysSent(h, 'a')) c['keys']], [
        ['esc'],
        ['up'],
      ]);
      semantics.dispose();
      await teardownBoard(tester, h);
    });

    testWidgets('a failed send is said in words, never silent', (tester) async {
      final h = await working(tester);
      h.transports['a']!.failure = const HerdrTransportException('Host unreachable');
      await tester.tap(find.text('esc'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Couldn’t send: Host unreachable'), findsOneWidget);
      h.transports['a']!.failure = null;
      await teardownBoard(tester, h);
    });

    testWidgets('Open full closes the sheet and opens the pane as a tab', (tester) async {
      final h = await working(tester);
      await tester.tap(find.text('Open full'));
      await settle(tester);

      expect(find.byType(ReplySheet), findsNothing);
      expect(h.openTabs.tabs.map((t) => t.paneId), ['w1:p1']);
      expect(find.byType(PaneScreen), findsOneWidget);
      await teardownBoard(tester, h);
    });
  });

  testWidgets('the chosen density survives the process being reclaimed', (tester) async {
    final h = await BoardHarness.create([_machine('a', [_pane(1, 'working')])]);
    tester.view
      ..physicalSize = const Size(360, 2400) * 2
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: h.providers,
        child: MaterialApp(
          restorationScopeId: 'app',
          theme: AppTheme.dark(),
          home: const HomeShell(),
        ),
      ),
    );
    await settle(tester);
    expect(find.byType(AgentCard), findsOneWidget);

    await tester.tap(find.byTooltip('Compact list'));
    await settle(tester);
    await tester.restartAndRestore();
    await settle(tester);
    expect(find.byType(AgentCompactRow), findsOneWidget);
    expect(find.byType(AgentCard), findsNothing);
    await teardownBoard(tester, h);
  });

  group('opening an agent', () {
    testWidgets('tapping the card opens its pane as a tab', (tester) async {
      final h = await BoardHarness.create([_machine('a', [_pane(1, 'working')])]);
      await pumpBoard(tester, h, height: _tall);

      await tester.tap(find.text('task 1'));
      await settle(tester);
      expect(h.openTabs.tabs.map((t) => t.paneId), ['w1:p1']);
      expect(find.byType(PaneScreen), findsOneWidget);
      await teardownBoard(tester, h);
    });

    testWidgets('a compact row does too', (tester) async {
      final h = await BoardHarness.create([_machine('a', [_pane(1, 'working')])]);
      await pumpBoard(tester, h, height: _tall);
      await tester.tap(find.byTooltip('Compact list'));
      await settle(tester);

      await tester.tap(find.text('task 1'));
      await settle(tester);
      expect(h.openTabs.tabs.map((t) => t.paneId), ['w1:p1']);
      await teardownBoard(tester, h);
    });
  });

  group('the clock', () {
    testWidgets('working agents do not animate; labels tick only while the Agents tab shows',
        (tester) async {
      final h = await BoardHarness.create([_machine('a', [_pane(1, 'working'), _pane(2, 'working')])]);
      await pumpBoard(tester, h, height: _tall);
      // Only the minute labels hold the clock: no glyph does.
      expect(StepClock.minute.leases, lessThanOrEqualTo(2));

      await tester.tap(find.byKey(FloatingTabBar.tabKey('Machines')));
      await settle(tester);
      expect(StepClock.minute.running, isFalse, reason: 'a hidden tab must not tick');

      await tester.tap(find.byKey(FloatingTabBar.tabKey('Agents')));
      await settle(tester);
      await teardownBoard(tester, h);
      expect(StepClock.minute.leases, 0);
    });

    testWidgets('a pane on top of the board stops the labels too', (tester) async {
      final h = await BoardHarness.create([_machine('a', [_pane(1, 'working')])]);
      await pumpBoard(tester, h, height: _tall);
      await tester.tap(find.text('task 1'));
      await settle(tester);
      expect(StepClock.minute.running, isFalse, reason: 'the board is covered');
      await teardownBoard(tester, h);
    });

    testWidgets('reduced motion: the board is still, previews and labels still live',
        (tester) async {
      final h = await BoardHarness.create([_machine('a', [_pane(1, 'working')])]);
      h.previews.set('a/w1:p1', ['still readable']);
      await pumpBoard(tester, h, height: _tall, reduceMotion: true);
      expect(find.text('still readable'), findsOneWidget);
      await teardownBoard(tester, h);
    });
  });

  group('worst case', () {
    testWidgets('long titles, Vietnamese, 5 options, 320dp at 2x text: no overflow',
        (tester) async {
      const long = PromptInfo(
        question: 'Bạn có muốn tiếp tục không? Lệnh sẽ chạy: '
            'rm -rf /home/user/dự-án/thư-mục-rất-dài-và-nhiều-tầng/ngày-hôm-nay',
        replies: [
          QuickReply(label: '1. Có, và đừng hỏi lại cho các lệnh tương tự như thế này nữa', keys: ['1']),
          QuickReply(label: '2. Không', keys: ['2']),
          QuickReply(label: '3. Có, xoá tất cả', keys: ['3'], needsConfirm: true),
          QuickReply(label: '4. Bỏ qua', keys: ['4']),
          QuickReply(label: '5. Hỏi lại sau', keys: ['5']),
        ],
      );
      final h = await BoardHarness.create([
        (
          profile: _profile('a', 'tailnet-build-server-eu-west-2-primary'),
          snapshot: snapshotWith(
            [_pane(1, 'blocked'), _pane(2, 'working'), _pane(3, 'done'), _pane(4, 'idle')],
            title: (_) => 'Hôm nay chúng ta cập nhật và kiểm tra ${'dài ' * 30}',
          ),
        ),
        _machine('b', const []),
      ]);
      h.previews.set('a/w1:p1', ['x' * 400], prompt: long);
      h.previews.set('a/w1:p2', ['Đường dẫn rất dài: /home/user/dự-án/${'tệp-tin/' * 20}', 'y' * 500]);
      h.previews.set('a/w1:p3', const []);
      await pumpBoard(tester, h, width: 320, height: _tall, textScale: 2);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(LucideIcons.reply).first);
      await settle(tester);
      expect(tester.takeException(), isNull);
      await teardownBoard(tester, h);
    });

    testWidgets('one agent, and none', (tester) async {
      var h = await BoardHarness.create([_machine('a', [_pane(1, 'working')])]);
      await pumpBoard(tester, h, height: _tall);
      expect(find.byType(AgentCard), findsOneWidget);
      await teardownBoard(tester, h);

      h = await BoardHarness.create([_machine('a', const [])]);
      await pumpBoard(tester, h, height: _tall);
      expect(find.byType(AgentCard), findsNothing);
      expect(find.text('No agents running'), findsOneWidget);
      await teardownBoard(tester, h);
    });
  });
}
