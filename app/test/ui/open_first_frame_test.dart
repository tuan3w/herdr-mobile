// The first frame of a long thread: only its last turns are planned while the
// route moves, the older turns are made ready afterwards a few milliseconds at
// a time, and the view does not move when they join. When the keeper's replay
// replaces a saved copy the same holds.
import 'dart:math' as math;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/plan_warmup.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_view.dart';

import '../support/fake_agent_session.dart';

/// [n] turns: a question and a markdown answer each.
List<TranscriptItem> _turns(int n) => [
  for (var i = 0; i < n; i++) ...[
    userMsg('u$i', 'question $i'),
    agentMsg('a$i', 'Answer $i with a list:\n\n- one\n- two\n\n```dart\nvoid f$i() {}\n```\n\nand a closing line for $i.'),
  ],
];

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(of: find.byType(TranscriptView), matching: find.byType(Scrollable)).first)
    .position;

/// Scrolls up in steps of about a screen until [finder] is on screen or the top
/// is reached (a jump over thousands of pixels of rows never built asks the
/// viewport to correct its estimates more often than it allows; a finger does
/// not do that).
Future<void> _toTop(WidgetTester tester, [Finder? finder]) async {
  final position = _position(tester);
  for (var i = 0; i < 200; i++) {
    if (finder != null && finder.evaluate().isNotEmpty) return;
    if (position.pixels <= position.minScrollExtent + 1) return;
    position.jumpTo(math.max(position.minScrollExtent, position.pixels - 700));
    await tester.pump();
  }
}

Future<void> _open(WidgetTester tester, FakeAgentSession session) async {
  tester.view.physicalSize = const Size(824, 1784);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: AppTheme.light(), home: AgentSessionScreen(key: ObjectKey(session), session: session)),
  );
}

void main() {
  group('tailStart', () {
    test('the index where the last turns begin; a turn starts at a user message', () {
      final items = _turns(10);
      expect(tailStart(items, 3), 14, reason: 'turns 7, 8, 9 start at item 14');
      expect(tailStart(items, 1), 18);
      expect(tailStart(items, 10), 0, reason: 'not more turns than that: all of it');
      expect(tailStart(items, 50), 0);
      expect(tailStart(const [], 8), 0);
      // Things before the first question are a turn of their own.
      expect(tailStart([agentMsg('x', 'hi'), ...items], 10), 1);
    });
  });

  group('PlanWarmup', () {
    test('plans every turn before the tail, newest first, in slices of its budget, then says it is done', () {
      fakeAsync((async) {
        final items = _turns(40);
        final warm = PlanWarmup(open: {}, notes: {}, budget: Duration.zero, gap: const Duration(milliseconds: 2));
        var done = 0;
        warm.start(items, tailStart(items, 8), {}, () => done++);
        expect(warm.running, isTrue);
        async.elapse(const Duration(milliseconds: 1));
        expect(done, 0, reason: 'nothing runs inside the call; it waits for a timer between frames');
        // A zero budget still does one turn per tick: the work is spread out.
        async.elapse(const Duration(milliseconds: 20));
        expect(done, 0, reason: '32 turns, one per tick');
        async.elapse(const Duration(seconds: 1));
        expect(done, 1);
        expect(warm.running, isFalse);
      });
    });

    test('cancel stops it and done is never called', () {
      fakeAsync((async) {
        final items = _turns(40);
        final warm = PlanWarmup(open: {}, notes: {}, budget: Duration.zero);
        var done = 0;
        warm.start(items, tailStart(items, 8), {}, () => done++);
        async.elapse(const Duration(milliseconds: 5));
        warm.cancel();
        async.elapse(const Duration(seconds: 5));
        expect(done, 0);
        expect(warm.running, isFalse);
      });
    });

    test('a transcript with nothing before the tail is done at once', () {
      fakeAsync((async) {
        final items = _turns(5);
        final warm = PlanWarmup(open: {}, notes: {});
        var done = 0;
        warm.start(items, tailStart(items, 8), {}, () => done++);
        async.elapse(const Duration(milliseconds: 50));
        expect(done, 1);
      });
    });
  });

  group('the screen of a long thread', () {
    testWidgets('opens on the last turns; the older ones join later without moving the view', (tester) async {
      final session = FakeAgentSession(state: stateWith(items: _turns(250)));
      await _open(tester, session);
      await tester.pump();
      final position = _position(tester);
      final pixels = position.pixels;
      final max = position.maxScrollExtent;
      final min = position.minScrollExtent;
      expect(find.textContaining('closing line for 249', findRichText: true), findsOneWidget);
      expect(pixels, closeTo(max, 1), reason: 'the end is in view');

      // Not yet: scrolling to the top reaches the 8th turn from the end, no further.
      await _toTop(tester);
      expect(position.pixels, lessThanOrEqualTo(position.minScrollExtent + 1), reason: 'the top of what is planned');
      expect(find.textContaining('question 0', findRichText: true), findsNothing);
      expect(find.textContaining('question 242', findRichText: true), findsOneWidget, reason: 'the first planned turn');
      final min1 = position.minScrollExtent;
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();

      // The route is done, the older turns are made ready, the plan is whole.
      await tester.pump(const Duration(seconds: 3));
      expect(position.pixels, closeTo(position.maxScrollExtent, 1), reason: 'still at the end: nothing moved under the reader');
      expect(position.maxScrollExtent, closeTo(max, 40), reason: 'the end is where it was (rows below are the same)');
      expect(position.minScrollExtent, lessThan(min1 - 5000), reason: '242 more turns above the first one');
      expect(min1, closeTo(min, 1));
      expect(find.textContaining('closing line for 249', findRichText: true), findsOneWidget);

      await _toTop(tester, find.textContaining('question 0', findRichText: true));
      expect(find.textContaining('question 0', findRichText: true), findsOneWidget);
    });

    testWidgets('a short thread is planned whole at once', (tester) async {
      final session = FakeAgentSession(state: stateWith(items: _turns(40))); // 80 items
      await _open(tester, session);
      await tester.pump();
      await _toTop(tester, find.textContaining('question 0', findRichText: true));
      expect(find.textContaining('question 0', findRichText: true), findsOneWidget);
    });

    testWidgets('the replay replacing a saved copy: the reader at the end sees no jump, the older turns follow', (tester) async {
      final session = FakeAgentSession(state: stateWith(items: _turns(250)));
      await _open(tester, session);
      await tester.pump(const Duration(seconds: 3)); // the saved copy is whole
      final position = _position(tester);
      expect(position.pixels, closeTo(position.maxScrollExtent, 1));

      // The keeper's replay: the same thread, every item a new object, one more turn.
      session.push(stateWith(items: [..._turns(250), userMsg('u250', 'question 250'), agentMsg('a250', 'Answer 250 is new.')]));
      await tester.pump();
      expect(find.textContaining('Answer 250 is new.', findRichText: true), findsOneWidget);
      expect(position.pixels, closeTo(position.maxScrollExtent, 1), reason: 'still following the end');

      // The older turns are made ready again in the background.
      await tester.pump(const Duration(seconds: 3));
      await _toTop(tester, find.textContaining('question 0', findRichText: true));
      expect(find.textContaining('question 0', findRichText: true), findsOneWidget);
    });

    testWidgets('a reader away from the end keeps the place when the replay replaces the thread', (tester) async {
      final session = FakeAgentSession(state: stateWith(items: _turns(250)));
      await _open(tester, session);
      await tester.pump(const Duration(seconds: 3));
      final position = _position(tester);
      // The reader scrolled up a few screens.
      for (var i = 0; i < 5; i++) {
        position.jumpTo(position.pixels - 700);
        await tester.pump();
      }
      await tester.pump();
      final seen = find.textContaining(RegExp(r'^question \d+$'), findRichText: true).first;
      final label = tester.widget<RichText>(seen).text.toPlainText();
      final before = tester.getTopLeft(seen);

      session.push(stateWith(items: _turns(250)));
      await tester.pump(const Duration(seconds: 3));
      final after = tester.getTopLeft(find.textContaining(label, findRichText: true).first);
      expect((after.dy - before.dy).abs(), lessThan(1), reason: 'the row the reader looks at stays where it was');
    });
  });
}
