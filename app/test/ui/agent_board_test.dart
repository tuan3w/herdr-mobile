// The agents home as a live board: the card in front and its preview, answers
// without leaving it, triage, and the cost of all that on a virtualised list.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/pane_preview.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/support/step_clock.dart';
import 'package:herdr_mobile/ui/features/agents/agent_card.dart';
import 'package:herdr_mobile/ui/features/agents/reply_sheet.dart';
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:herdr_mobile/data/repositories/attention_set.dart';
import 'package:provider/provider.dart';

import '../support/shot.dart' show loadAppFonts;
import 'board_support.dart';
import 'hold_support.dart';
import 'ui_harness.dart';

MachineProfile _profile(String id, String label) =>
    MachineProfile(id: id, label: label, host: '$id.example', username: 'dev');

Pane _pane(int i, String status, {String agent = 'claude'}) => (id: 'w1:p$i', ws: 'w1', agent: agent, status: status);

String _title(String paneId) => 'task ${paneId.split('p').last}';

({MachineProfile profile, Map<String, dynamic> snapshot}) _machine(String id, List<Pane> panes, {String? label}) =>
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
    testWidgets('the card in front shows the end of its terminal, the newest line strongest', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked')]),
      ]);
      h.previews.set('a/w1:p1', ['reading schema.sql', 'writing migration', 'running tests']);
      await pumpBoard(tester, h, height: _tall);

      final card = _card('task 1');
      expect(find.descendant(of: card, matching: find.text('reading schema.sql')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('running tests')), findsOneWidget);
      Color colour(String t) => tester.widget<Text>(find.descendant(of: card, matching: find.text(t))).style!.color!;
      expect(colour('running tests'), isNot(colour('reading schema.sql')), reason: 'the newest row is the one to read');
      await teardownBoard(tester, h);
    });

    testWidgets('working, finished and idle agents are rows: no preview, and their panes are never read', (
      tester,
    ) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'working'), _pane(2, 'done'), _pane(3, 'idle'), _pane(4, 'unknown')]),
      ]);
      h.previews.set('a/w1:p1', ['> ']);
      await pumpBoard(tester, h, height: _tall);

      expect(find.byType(AgentCard), findsNothing);
      expect(find.byType(AgentCompactRow), findsNWidgets(4));
      expect(h.previews.opened, isEmpty, reason: 'previews of rows are noise and traffic');
      expect(find.text('> '), findsNothing);
      expect(replyTo('task 1'), findsNothing, reason: 'Reply… is the waiting card\'s');
      await teardownBoard(tester, h);
    });

    testWidgets('the card keeps its height while lines arrive', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked')]),
      ]);
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

    testWidgets('an offline machine\'s rows say so', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'working')]),
      ]);
      await pumpBoard(tester, h, height: _tall);
      h.network.goOffline();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.descendant(of: find.byType(AgentCompactRow), matching: find.text('offline')), findsOneWidget);
      await teardownBoard(tester, h);
    });
  });

  group('watching', () {
    testWidgets('only the card in front is watched, and scrolling past releases it', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked'), for (var i = 2; i <= 40; i++) _pane(i, 'working')]),
      ]);
      await pumpBoard(tester, h);

      expect(h.previews.openCount, 1, reason: 'the card, not 40 rows');
      expect(h.previews.open['a/w1:p1'], 1);

      await tester.fling(find.byType(CustomScrollView).first, const Offset(0, -20000), 20000);
      await settle(tester);
      expect(h.previews.open['a/w1:p1'], 0, reason: 'scrolled far away: no reads for it');
      await teardownBoard(tester, h);
      expect(h.previews.openCount, 0, reason: 'a leaked watcher reads forever');
    });

    testWidgets('an agent that stops waiting stops being watched', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked')]),
      ]);
      await pumpBoard(tester, h, height: _tall);
      expect(h.previews.openCount, 1);

      await h.changeStatuses(tester, 'a', [_pane(1, 'idle')], title: _title);
      expect(h.previews.openCount, 0);
      await teardownBoard(tester, h);
    });

    testWidgets('rows watch nothing; the blocked agent in front keeps its card', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'working'), _pane(2, 'blocked')]),
      ]);
      await pumpBoard(tester, h, height: _tall);
      expect(find.byType(AgentCompactRow), findsOneWidget, reason: 'the working one');
      expect(find.byType(AgentCard), findsOneWidget, reason: 'the blocked one still asks');
      expect(h.previews.openCount, 1, reason: 'only the blocked card reads its pane');
      await teardownBoard(tester, h);
    });

    testWidgets('a blocked agent can be answered from the board', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked'), _pane(2, 'working')]),
      ]);
      h.previews.set('a/w1:p1', ['…context…'], prompt: _menu);
      await pumpBoard(tester, h, height: _tall);

      for (final r in _menu.replies) {
        expect(find.text(r.label), findsOneWidget);
      }
      await tester.tap(find.text('1. Yes'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_keysSent(h, 'a').single['keys'], ['1', 'enter']);
      await tester.pump(const Duration(seconds: 4));
      await teardownBoard(tester, h);
    });

    testWidgets('an offline machine’s blocked agent can’t be answered, so it is a row', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked')]),
      ]);
      await pumpBoard(tester, h, height: _tall);
      expect(find.byType(AgentCard), findsOneWidget);

      h.network.goOffline();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AgentCard), findsNothing);
      expect(find.byType(AgentCompactRow), findsOneWidget);
      await teardownBoard(tester, h);
    });
  });

  group('answering from the card', () {
    Future<BoardHarness> blocked(WidgetTester tester, {PromptInfo prompt = _menu}) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked')]),
      ]);
      h.previews.set('a/w1:p1', ['…context…'], prompt: prompt);
      await pumpBoard(tester, h, height: _tall);
      return h;
    }

    testWidgets('shows the question and one chip per option, labelled with the option', (tester) async {
      final h = await blocked(tester);
      expect(find.textContaining('Do you want to proceed?'), findsOneWidget);
      for (final r in _menu.replies) {
        expect(find.text(r.label), findsOneWidget);
      }
      await teardownBoard(tester, h);
    });

    testWidgets('tapping a chip sends that option to that pane, once, and the chip says so', (tester) async {
      final h = await blocked(tester);

      final chip = tester.getCenter(find.text('2. Yes, and don’t ask again'));
      await tester.tapAt(chip);
      await tester.pump();
      await tester.tapAt(chip); // a second tap on the same spot
      await tester.pump(const Duration(milliseconds: 50));

      expect(_keysSent(h, 'a'), [
        {
          'pane_id': 'w1:p1',
          'keys': ['2', 'enter'],
        },
      ]);
      expect(find.text('Sent: 2. Yes, and don’t ask again'), findsOneWidget);
      // The others step back: no second answer by accident.
      await tester.tap(find.text('3. No, and tell Claude what to do'), warnIfMissed: false);
      await tester.pump();
      expect(_keysSent(h, 'a'), hasLength(1));
      expect(h.previews.rechecked, ['a/w1:p1'], reason: 'the pane was read again before the keys went');
      await tester.pump(const Duration(seconds: 4));
      await teardownBoard(tester, h);
    });

    testWidgets('the card keeps its height through every state of the chips', (tester) async {
      final h = await blocked(tester, prompt: _risky);
      double height() => tester.getSize(find.byType(AgentCard)).height;
      final idle = height();

      final g = await pressAndHold(tester, find.text('2. Yes, delete everything'), const Duration(milliseconds: 400));
      expect(find.text('Hold to send'), findsOneWidget);
      expect(fillOf(tester), greaterThan(0));
      expect(height(), idle, reason: 'holding');

      await advance(tester, const Duration(milliseconds: 500));
      await g.up();
      await tester.pump();
      expect(find.text('Sent: 2. Yes, delete everything'), findsOneWidget);
      expect(height(), idle, reason: 'sent');
      await tester.pump(const Duration(seconds: 4));
      await teardownBoard(tester, h);
    });

    testWidgets('a risky option is held to send: a tap only says so, a hold sends, once', (tester) async {
      final h = await blocked(tester, prompt: _risky);

      await quickTap(tester, find.text('2. Yes, delete everything'));
      expect(_keysSent(h, 'a'), isEmpty);
      expect(find.text('Hold to send'), findsOneWidget);
      await advance(tester, Dwell.holdHint);
      expect(find.text('2. Yes, delete everything'), findsOneWidget, reason: 'the hint went away');

      await holdFor(tester, find.text('2. Yes, delete everything'));
      expect(_keysSent(h, 'a'), [
        {
          'pane_id': 'w1:p1',
          'keys': ['2', 'enter'],
        },
      ]);
      await tester.pump(const Duration(seconds: 4));
      await teardownBoard(tester, h);
    });

    testWidgets('releasing a hold half way sends nothing', (tester) async {
      final h = await blocked(tester, prompt: _risky);

      final g = await pressAndHold(tester, find.text('2. Yes, delete everything'), const Duration(milliseconds: 425));
      expect(fillOf(tester), greaterThan(0.2));
      await g.up();
      await advance(tester, const Duration(milliseconds: 300));
      expect(fillOf(tester), 0);
      expect(_keysSent(h, 'a'), isEmpty);
      await advance(tester, Dwell.holdHint);
      await teardownBoard(tester, h);
    });

    testWidgets('assistive activation of a risky option is two steps, and a hold on the primed chip sends', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final h = await blocked(tester, prompt: _risky);

      tester.semantics.tap(find.semantics.byLabel('2. Yes, delete everything, needs holding or a second activation'));
      await tester.pump();
      expect(_keysSent(h, 'a'), isEmpty);
      expect(find.text('Hold or tap again'), findsOneWidget);

      tester.semantics.tap(find.semantics.byLabel('Confirm: 2. Yes, delete everything'));
      await tester.pump();
      expect(_keysSent(h, 'a').single['keys'], ['2', 'enter']);
      await tester.pump(const Duration(seconds: 4));
      semantics.dispose();
      await teardownBoard(tester, h);
    });

    testWidgets('a chip primed through assistive activation also sends on a hold', (tester) async {
      final semantics = tester.ensureSemantics();
      final h = await blocked(tester, prompt: _risky);

      tester.semantics.tap(find.semantics.byLabel('2. Yes, delete everything, needs holding or a second activation'));
      await tester.pump();
      await holdFor(tester, find.text('Hold or tap again'));
      expect(_keysSent(h, 'a'), hasLength(1));
      await tester.pump(const Duration(seconds: 4));
      semantics.dispose();
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

    testWidgets('a new question replaces "Sent" at once instead of after the hold', (tester) async {
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

    testWidgets('a new question right after Sent takes no tap until it has been seen', (tester) async {
      final h = await blocked(tester);
      await tester.tap(find.text('1. Yes'));
      await tester.pump(const Duration(milliseconds: 50));

      h.previews.set('a/w1:p1', ['next'], prompt: _risky);
      await tester.pump();
      // The second tap of a quick double tap, meant for the old question.
      await tester.tap(find.text('1. Yes, once'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 50));
      expect(_keysSent(h, 'a'), hasLength(1), reason: 'only the answer to the first question went');

      await settle(tester);
      await tester.tap(find.text('1. Yes, once'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_keysSent(h, 'a'), hasLength(2), reason: 'once seen, the new answer takes a tap');
      await tester.pump(const Duration(seconds: 4));
      await teardownBoard(tester, h);
    });

    testWidgets('a question arriving grows the card: its answers take no tap until it has settled', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked')]),
      ]);
      h.previews.set('a/w1:p1', ['…thinking…']);
      await pumpBoard(tester, h, height: _tall);
      final before = tester.getSize(_card('task 1')).height;

      h.previews.set('a/w1:p1', ['…context…'], prompt: _menu);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getSize(_card('task 1')).height, greaterThan(before), reason: 'the card grew');
      await tester.tap(find.text('1. Yes'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 50));
      expect(_keysSent(h, 'a'), isEmpty);

      await settle(tester);
      await tester.tap(find.text('1. Yes'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_keysSent(h, 'a'), hasLength(1));
      await tester.pump(const Duration(seconds: 4));
      await teardownBoard(tester, h);
    });

    testWidgets('answers that moved because a line above them wrapped take no tap for a moment', (tester) async {
      final h = await blocked(tester);
      final before = tester.getCenter(find.text('1. Yes'));

      // The agent's title grows to two lines: everything under it moves down.
      h.transports['a']!.snapshot = snapshotWith([
        _pane(1, 'blocked'),
      ], title: (_) => 'task 1 with a much longer title that needs a second line on a phone');
      h.transports['a']!.emit(const {'event': 'pane.agent_status_changed'});
      for (var i = 0; i < 20 && tester.getCenter(find.text('1. Yes')) == before; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(tester.getCenter(find.text('1. Yes')).dy, greaterThan(before.dy), reason: 'the answers moved');
      await tester.tap(find.text('1. Yes'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 50));
      expect(_keysSent(h, 'a'), isEmpty);

      await settle(tester);
      await tester.pump(Dwell.tapGuard);
      await tester.tap(find.text('1. Yes'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_keysSent(h, 'a'), hasLength(1));
      await tester.pump(const Duration(seconds: 4));
      await teardownBoard(tester, h);
    });

    testWidgets('a question answered on the desktop gets no keys meant for it: the new one shows instead', (
      tester,
    ) async {
      final h = await blocked(tester);
      final felt = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'HapticFeedback.vibrate') felt.add(call.arguments);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      // The pane moved on to another question; the board has not read it yet.
      h.previews.asksNow['a/w1:p1'] = _risky;

      await tester.tap(find.text('1. Yes'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_keysSent(h, 'a'), isEmpty, reason: 'the keys were meant for the old question');
      expect(find.textContaining('Run this command?'), findsOneWidget, reason: 'the question asked now shows');
      expect(find.textContaining('Do you want to proceed?'), findsNothing);
      expect(find.text('1. Yes, once'), findsNothing, reason: 'the chip under the thumb says what happened');
      expect(find.text('2. Yes, delete everything'), findsOneWidget);
      expect(felt, contains('HapticFeedbackType.heavyImpact'), reason: 'felt as a refusal, not a send');

      await tester.pump(const Duration(seconds: 2));
      expect(find.text('1. Yes, once'), findsOneWidget);
      await tester.tap(find.text('1. Yes, once'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_keysSent(h, 'a'), [
        {
          'pane_id': 'w1:p1',
          'keys': ['1', 'enter'],
        },
      ]);
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

    testWidgets('a blocked agent with no prompt we understand still shows its terminal', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked')]),
      ]);
      h.previews.set('a/w1:p1', ['Allow the agent to edit 3 files?']);
      await pumpBoard(tester, h, height: _tall);

      expect(find.text('Allow the agent to edit 3 files?'), findsOneWidget);
      expect(replyTo('task 1'), findsOneWidget);
      await teardownBoard(tester, h);
    });

    testWidgets('Reply… keeps a full tap target and clear of the words it floats over', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked')]),
      ]);
      final long = 'npm run test -- --watch=false ${'x' * 200}';
      h.previews.set('a/w1:p1', [long]);
      await pumpBoard(tester, h, width: 320, height: _tall, textScale: 1.6);

      final reply = tester.getRect(replyTo('task 1'));
      expect(reply.height, greaterThanOrEqualTo(kMinTap));
      expect(reply.width, greaterThanOrEqualTo(kMinTap));
      final word = tester.getRect(find.text('Reply…'));
      final line = tester.getRect(find.textContaining('npm run test'));
      expect(line.right, lessThanOrEqualTo(word.left), reason: 'the last row ends before Reply… begins');
      expect(word.center.dy, moreOrLessEquals(line.center.dy, epsilon: 1), reason: 'on the last row');
      await teardownBoard(tester, h);
    });
  });

  group('time in state', () {
    testWidgets('says how long, by the minute, once a change was seen; nothing before', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'idle'), _pane(2, 'idle')]),
      ]);
      await pumpBoard(tester, h, height: _tall);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_said(RegExp(r'^idle, ')), findsNothing, reason: 'first sight: unknown, so unclaimed');

      await h.changeStatuses(
        tester,
        'a',
        [_pane(1, 'working'), _pane(2, 'idle')],
        ago: const Duration(minutes: 12),
        title: _title,
      );
      expect(_said('working, 12 minutes'), findsOneWidget);
      await teardownBoard(tester, h);
    });
  });

  group('triage', () {
    testWidgets('the status line counts agents that can be answered, and stops when none is', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked'), _pane(2, 'blocked'), _pane(3, 'working')]),
        _machine('b', [_pane(4, 'blocked')]),
      ]);
      await pumpBoard(tester, h, height: _tall);
      expect(find.textContaining('3 need you'), findsOneWidget);

      h.network.goOffline();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('need you'), findsNothing, reason: 'offline: nothing can be answered');
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

      await tester.tap(find.byKey(const ValueKey('answer-one-by-one')));
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

    testWidgets('answering advances to the next agent, and the last answer closes the sheet', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked'), _pane(2, 'blocked')]),
      ]);
      h.previews.set('a/w1:p1', ['x'], prompt: _menu);
      h.previews.set('a/w1:p2', ['y'], prompt: _risky);
      await pumpBoard(tester, h, height: _tall);

      await tester.tap(find.byKey(const ValueKey('answer-one-by-one')));
      await settle(tester);
      Finder inSheet(Finder f) => find.descendant(of: find.byType(ReplySheet), matching: f);
      expect(inSheet(find.text('task 1')), findsOneWidget);

      await tester.tap(inSheet(find.text('1. Yes')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(inSheet(find.text('Sent: 1. Yes')), findsOneWidget);
      expect(_keysSent(h, 'a').single, {
        'pane_id': 'w1:p1',
        'keys': ['1', 'enter'],
      });

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
      expect(find.textContaining('need you'), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      await teardownBoard(tester, h);
    });

    testWidgets('answers that moved under the thumb take no tap until the board has settled', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked'), _pane(2, 'blocked')]),
      ]);
      h.previews.set('a/w1:p1', ['x'], prompt: _menu);
      h.previews.set('a/w1:p2', ['y'], prompt: _menu);
      await pumpBoard(tester, h, height: _tall);
      Finder yes(String title) => find.descendant(of: _card(title), matching: find.text('1. Yes'));
      expect(_card('task 2'), findsNothing, reason: 'the second one waiting is a row');

      // Task 1 stops waiting (answered on the desktop): task 2 comes to the
      // front, its answers where task 1's were.
      h.transports['a']!.snapshot = snapshotWith([_pane(1, 'working'), _pane(2, 'blocked')], title: _title);
      h.transports['a']!.emit(const {'event': 'pane.agent_status_changed'});
      for (var i = 0; i < 60 && yes('task 2').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(yes('task 2'), findsOneWidget, reason: 'task 2 is in front');

      await tester.tap(yes('task 2'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_keysSent(h, 'a'), isEmpty, reason: 'a tap aimed at the place it left');

      await tester.pump(Dwell.tapGuard);
      await tester.tap(yes('task 2'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_keysSent(h, 'a').single, {
        'pane_id': 'w1:p2',
        'keys': ['1', 'enter'],
      });
      await tester.pump(const Duration(seconds: 4));
      await teardownBoard(tester, h);
    });

    testWidgets('a card that stops waiting folds away: the rows below glide up instead of jumping', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked'), _pane(2, 'blocked')]),
      ]);
      h.previews.set('a/w1:p1', ['x'], prompt: _menu);
      h.previews.set('a/w1:p2', ['y'], prompt: _menu);
      await pumpBoard(tester, h, height: _tall);
      double top(String title) => tester.getTopLeft(find.text(title)).dy;

      final was = top('task 2');
      h.transports['a']!.snapshot = snapshotWith([_pane(1, 'working'), _pane(2, 'blocked')], title: _title);
      h.transports['a']!.emit(const {'event': 'pane.agent_status_changed'});
      // The first frame in which task 1 has left its place.
      for (var i = 0; i < 60 && top('task 1') < top('task 2'); i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(top('task 1'), greaterThan(top('task 2')), reason: 'task 1 moved to Working');
      final first = top('task 2');

      await tester.pump(const Duration(milliseconds: 400));
      final resting = top('task 2');
      expect(resting, lessThan(was - 100), reason: 'task 2 took the place of task 1');
      expect(first - resting, greaterThan(20), reason: 'it was still on its way: the gap closes, not snaps');
      await tester.pump(const Duration(seconds: 4));
      await teardownBoard(tester, h);
    });

    testWidgets('an answered agent holds its place until Sent is read; the next one ignores a stray tap', (
      tester,
    ) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked'), _pane(2, 'blocked')]),
      ]);
      h.previews.set('a/w1:p1', ['x'], prompt: _menu);
      h.previews.set('a/w1:p2', ['y'], prompt: _menu);
      await pumpBoard(tester, h, height: _tall);
      await tester.tap(find.byKey(const ValueKey('answer-one-by-one')));
      await settle(tester);
      Finder inSheet(Finder f) => find.descendant(of: find.byType(ReplySheet), matching: f);

      await tester.tap(inSheet(find.text('1. Yes')));
      await tester.pump(const Duration(milliseconds: 100));
      // The agent reports back that it no longer waits.
      h.transports['a']!.snapshot = snapshotWith([_pane(1, 'working'), _pane(2, 'blocked')], title: _title);
      h.transports['a']!.emit(const {'event': 'pane.agent_status_changed'});
      await tester.pump(const Duration(milliseconds: 300));
      expect(inSheet(find.text('task 1')), findsOneWidget, reason: 'not replaced under the thumb');
      expect(inSheet(find.text('task 2')), findsNothing);
      expect(inSheet(find.text('Sent: 1. Yes')), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 400)); // 700 ms after the answer: moves on
      await tester.pump(const Duration(milliseconds: 100));
      expect(inSheet(find.text('task 2')), findsOneWidget);
      await tester.tap(inSheet(find.text('1. Yes')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_keysSent(h, 'a'), hasLength(1), reason: 'the stray tap landed on the next agent: ignored');

      await tester.pump(Dwell.tapGuard);
      await tester.tap(inSheet(find.text('1. Yes')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_keysSent(h, 'a').last, {
        'pane_id': 'w1:p2',
        'keys': ['1', 'enter'],
      });
      await tester.pump(const Duration(seconds: 4));
      await teardownBoard(tester, h);
    });

    testWidgets('esc and enter move through a menu; they never walk the sheet on to another agent', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked'), _pane(2, 'blocked')]),
      ]);
      h.previews.set('a/w1:p1', ['x'], prompt: _menu);
      h.previews.set('a/w1:p2', ['y'], prompt: _menu);
      await pumpBoard(tester, h, height: _tall);
      await tester.tap(find.byKey(const ValueKey('answer-one-by-one')));
      await settle(tester);

      await tester.tap(find.descendant(of: find.byType(ReplySheet), matching: find.text('esc')));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('1 of 2 need you'), findsOneWidget);
      expect(_keysSent(h, 'a').single, {
        'pane_id': 'w1:p1',
        'keys': ['esc'],
      });
      await teardownBoard(tester, h);
    });

    testWidgets('an agent starting to wait doesn’t rebuild the list or move its scroll position', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [for (var i = 1; i <= 12; i++) _pane(i, 'working')]),
      ]);
      await pumpBoard(tester, h);
      final scroll = find.byType(CustomScrollView).first;
      await tester.drag(scroll, const Offset(0, -900));
      await tester.pump(const Duration(milliseconds: 400));
      final offset = tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels;
      // A row clearly on screen (the first built one may be in the cache above).
      final visible = tester
          .widgetList<AgentCompactRow>(find.byType(AgentCompactRow))
          .firstWhere((w) => tester.getRect(find.byWidget(w)).top >= 160)
          .agent
          .title;
      Finder rowOf(String title) => find.widgetWithText(AgentCompactRow, title);
      final row = tester.element(rowOf(visible));

      await h.changeStatuses(tester, 'a', [
        for (var i = 1; i <= 12; i++) _pane(i, i == 12 ? 'blocked' : 'working'),
      ], title: _title);
      expect(
        tester.element(find.byType(AgentCompactRow).first).read<AttentionSet>().needsYou,
        hasLength(1),
        reason: 'it is counted',
      );
      expect(tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels, offset);
      expect(tester.element(rowOf(visible)), same(row), reason: 'rows were inflated again when one started waiting');
      await teardownBoard(tester, h);
    });

    testWidgets('the last row ends above the bottom edge, with room to spare', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked'), for (var i = 2; i <= 8; i++) _pane(i, 'working')]),
      ]);
      await pumpBoard(tester, h);
      for (var i = 0; i < 3; i++) {
        await tester.fling(find.byType(CustomScrollView).first, const Offset(0, -5000), 5000);
        await settle(tester);
      }
      final last = tester
          .widgetList(find.byType(AgentCompactRow))
          .map((w) => tester.getRect(find.byWidget(w)).bottom)
          .reduce((a, b) => a > b ? a : b);
      expect(find.byType(FloatingBarPill), findsNothing, reason: 'home has no bar over the list');
      expect(last, lessThanOrEqualTo(740 - Gap.xl + 0.01), reason: 'the list ends clear of the bottom edge');
      await teardownBoard(tester, h);
    });
  });

  group('reply sheet', () {
    // Waiting on a prompt the app does not read: the card shows the
    // terminal, and Reply… answers in words.
    Future<BoardHarness> working(WidgetTester tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked')]),
      ]);
      h.previews.set('a/w1:p1', ['step one', 'step two']);
      await pumpBoard(tester, h, height: _tall);
      await tester.tap(replyTo('task 1'));
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
      expect(input.single, {
        'pane_id': 'w1:p1',
        'text': 'use the staging db',
        'keys': ['enter'],
      });
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
      expect(find.textContaining('Sent:'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      semantics.dispose();
      await teardownBoard(tester, h);
    });

    testWidgets('send does nothing for an empty field; the quick keys send their keys', (tester) async {
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
      expect(
        [for (final c in _keysSent(h, 'a')) c['keys']],
        [
          ['esc'],
          ['up'],
        ],
      );
      semantics.dispose();
      await teardownBoard(tester, h);
    });

    testWidgets('a failed send is said in words, never silent', (tester) async {
      final h = await working(tester);
      h.transports['a']!.failure = const HerdrTransportException('Host unreachable');
      await tester.tap(find.text('esc'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('Couldn’t send: No connection to'), findsOneWidget);
      h.transports['a']!.failure = null;
      await tester.pump(const Duration(milliseconds: 100)); // the failure haptic's echo
      await teardownBoard(tester, h);
    });

    testWidgets('Open full closes the sheet and opens the pane', (tester) async {
      final h = await working(tester);
      await tester.tap(find.text('Open full'));
      await settle(tester);

      expect(find.byType(ReplySheet), findsNothing);
      expect(h.agentScreens.front, const FrontAgent(PaneAgent('a', 'w1:p1'), AgentView.terminal));
      expect(find.byType(PaneScreen), findsOneWidget);
      await teardownBoard(tester, h);
    });
  });

  group('opening an agent', () {
    testWidgets('tapping a row opens its pane', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'working')]),
      ]);
      await pumpBoard(tester, h, height: _tall);

      await tester.tap(find.text('task 1'));
      await settle(tester);
      expect(h.agentScreens.front, const FrontAgent(PaneAgent('a', 'w1:p1'), AgentView.terminal));
      expect(find.byType(PaneScreen), findsOneWidget);
      await teardownBoard(tester, h);
    });
  });

  group('the clock', () {
    testWidgets('working agents do not animate; labels tick only while the board shows', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'working'), _pane(2, 'working')]),
      ]);
      await pumpBoard(tester, h, height: _tall);
      // Only the minute labels hold the clock: no glyph does.
      expect(StepClock.minute.leases, lessThanOrEqualTo(2));

      await tester.tap(find.byKey(const ValueKey('machine-health')));
      await tester.pumpAndSettle();
      expect(StepClock.minute.running, isFalse, reason: 'the board under Machines must not tick');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await teardownBoard(tester, h);
      expect(StepClock.minute.leases, 0);
    });

    testWidgets('a pane on top of the board stops the labels too', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'working')]),
      ]);
      await pumpBoard(tester, h, height: _tall);
      await tester.tap(find.text('task 1'));
      await settle(tester);
      expect(StepClock.minute.running, isFalse, reason: 'the board is covered');
      await teardownBoard(tester, h);
    });

    testWidgets('reduced motion: the board is still, previews and labels still live', (tester) async {
      final h = await BoardHarness.create([
        _machine('a', [_pane(1, 'blocked')]),
      ]);
      h.previews.set('a/w1:p1', ['still readable']);
      await pumpBoard(tester, h, height: _tall, reduceMotion: true);
      expect(find.text('still readable'), findsOneWidget);
      await teardownBoard(tester, h);
    });
  });

  group('worst case', () {
    testWidgets('long titles, Vietnamese, 5 options, 320dp at 2x text: no overflow', (tester) async {
      const long = PromptInfo(
        question:
            'Bạn có muốn tiếp tục không? Lệnh sẽ chạy: '
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
          snapshot: snapshotWith([
            _pane(1, 'blocked'),
            _pane(2, 'working'),
            _pane(3, 'done'),
            _pane(4, 'idle'),
          ], title: (_) => 'Hôm nay chúng ta cập nhật và kiểm tra ${'dài ' * 30}'),
        ),
        _machine('b', const []),
      ]);
      h.previews.set('a/w1:p1', ['x' * 400], prompt: long);
      h.previews.set('a/w1:p2', ['Đường dẫn rất dài: /home/user/dự-án/${'tệp-tin/' * 20}', 'y' * 500]);
      h.previews.set('a/w1:p3', const []);
      await pumpBoard(tester, h, width: 320, height: _tall, textScale: 2);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Reply…').first);
      await settle(tester);
      expect(tester.takeException(), isNull);
      await teardownBoard(tester, h);
    });

    testWidgets('one agent, and none', (tester) async {
      var h = await BoardHarness.create([
        _machine('a', [_pane(1, 'working')]),
      ]);
      await pumpBoard(tester, h, height: _tall);
      expect(find.byType(AgentCompactRow), findsOneWidget);
      await teardownBoard(tester, h);

      h = await BoardHarness.create([_machine('a', const [])]);
      await pumpBoard(tester, h, height: _tall);
      expect(find.byType(AgentCompactRow), findsNothing);
      expect(find.text('No agents running'), findsOneWidget);
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
