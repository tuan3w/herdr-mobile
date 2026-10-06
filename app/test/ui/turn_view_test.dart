import 'dart:math' show pow;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/repositories/last_seen.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/log_atoms.dart';
import 'package:herdr_mobile/ui/features/agent_session/plan_header.dart';
import 'package:herdr_mobile/ui/features/agent_session/status_line.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_rows.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_view.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/fake_agent_session.dart';
import '../support/turn_fixtures.dart';

// The turn model on screen: a finished turn
// folds its work log to one line and keeps the answer, the Changed card and the
// exceptions; the turn that runs shows its log open under a status line; the
// since-you-left divider; and streaming stays one row.

Future<void> pumpView(
  WidgetTester tester,
  FakeAgentSession session, {
  SinceLeft? sinceLeft,
  Size size = const Size(412, 892),
  double textScale = 1,
  bool reducedMotion = false,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(session, sinceLeft: sinceLeft, textScale: textScale, reducedMotion: reducedMotion));
  await tester.pump(const Duration(milliseconds: 100));
}

Widget _app(FakeAgentSession session, {SinceLeft? sinceLeft, double textScale = 1, bool reducedMotion = false}) =>
    MaterialApp(
      theme: AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale), disableAnimations: reducedMotion),
        child: child!,
      ),
      home: Scaffold(body: TranscriptView(session: session, sinceLeft: sinceLeft)),
    );

SinceLeft since(String? key, {int steps = 3}) => SinceLeft(
  since: at(0),
  steps: steps,
  tools: steps,
  messages: 0,
  stops: 0,
  notes: 0,
  needsYou: 0,
  firstUnseenKey: key,
);

ScrollPosition position(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(of: find.byType(TranscriptView), matching: find.byType(Scrollable)).first)
    .position;

Finder rich(String text) => find.textContaining(text, findRichText: true);

/// `n` finished turns, each a question, a read and an answer.
List<TranscriptItem> turns(int n) => [
  for (var i = 0; i < n; i++) ...[
    userAt('u$i', 'question $i', i * 10),
    readAt('r$i', '/a/lib/file_$i.dart', i * 10 + 1),
    agentAt('a$i', 'answer $i', i * 10 + 3),
  ],
];

/// The height of the tap target of the row whose text is [finder].
double targetHeight(WidgetTester tester, Finder finder) =>
    tester.getSize(find.ancestor(of: finder, matching: find.byType(PressBuilder)).first).height;

void main() {
  tearDown(() {
    debugRowBuilt = null;
    statusNow = DateTime.now;
  });

  group('the fold', () {
    testWidgets('a finished turn is one line; the answer, the card and the failure stay; a tap opens the log in place', (tester) async {
      await pumpView(tester, FakeAgentSession(state: stateWith(items: richTurn())));
      expect(rich('Worked 42s \u00b7 2 files \u00b7 2 commands \u00b7 1 failed'), findsOneWidget);
      expect(find.text('Thinking'), findsNothing);
      expect(find.text('dart format lib test'), findsNothing, reason: 'a command that went well folds');
      expect(find.textContaining('Read 3 files'), findsNothing);
      expect(rich('The parser lowercased'), findsOneWidget, reason: 'the answer');
      expect(rich('Changed'), findsOneWidget);
      expect(find.text('flutter test test/locale_test.dart'), findsOneWidget, reason: 'the failure breaks out');
      expect(find.text('exit 1'), findsNothing);
      expect(rich('exit 1'), findsOneWidget);

      final fold = rich('Worked 42s');
      final top = tester.getTopLeft(fold);
      await tester.tap(fold);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(fold), top, reason: 'the line under the thumb stays');
      expect(find.text('Thinking'), findsOneWidget);
      expect(find.text('dart format lib test'), findsOneWidget);
      expect(find.textContaining('Read 3 files'), findsOneWidget);
      expect(find.text('flutter test test/locale_test.dart'), findsOneWidget, reason: 'in its place in the log, not twice');

      await tester.tap(fold);
      await tester.pumpAndSettle();
      expect(find.text('Thinking'), findsNothing);
      expect(find.text('dart format lib test'), findsNothing);
    });

    testWidgets('the rows a fold brings are revealed over Motion.expand; reduced motion shows them at once', (tester) async {
      final session = FakeAgentSession(state: stateWith(items: richTurn()));
      await pumpView(tester, session);
      await tester.tap(rich('Worked 42s'));
      await tester.pump(const Duration(milliseconds: 40));
      FadeTransition fade() =>
          tester.widget<FadeTransition>(find.ancestor(of: find.text('Thinking'), matching: find.byType(FadeTransition)).first);
      expect(fade().opacity.value, lessThan(1));
      await tester.pump(const Duration(milliseconds: 400));
      expect(fade().opacity.value, 1);
      expect(tester.binding.hasScheduledFrame, isFalse, reason: 'it settles; nothing loops');

      await tester.pumpWidget(const SizedBox());
      await pumpView(tester, FakeAgentSession(state: stateWith(items: richTurn())), reducedMotion: true);
      await tester.tap(rich('Worked 42s'));
      await tester.pump(const Duration(milliseconds: 1));
      expect(fade().opacity.value, 1);
    });

    testWidgets('a turn that ran under a replay says no duration', (tester) async {
      final items = [
        userMsg('u', 'old question'),
        toolItem('r', title: 'Read', kind: ToolKind.read, rawInput: {'file_path': '/a/b.dart'}),
        toolItem('c', title: 'ls', kind: ToolKind.execute),
        agentMsg('a', 'done'),
      ];
      await pumpView(tester, FakeAgentSession(state: stateWith(items: items)));
      expect(rich('Worked \u00b7 1 command'), findsOneWidget);
      expect(rich('Worked 0'), findsNothing);
    });

    testWidgets('exceptions are never hidden: failed, cancelled, waiting calls, stops and notes', (tester) async {
      final items = [
        userAt('u', 'clean up', 0),
        readAt('ok', '/a/x.dart', 1),
        runAt('bad', 'make \u202Etest', 2, exitCode: 2, output: 'boom\nerror: nothing to do\n'),
        toolAt('cut', title: 'sleep 9', kind: ToolKind.execute, status: ToolStatus.cancelled, rawInput: {'command': 'sleep 9'}, start: 5),
        toolAt(
          't1',
          title: 'rm -rf build',
          kind: ToolKind.execute,
          status: ToolStatus.pending,
          rawInput: {'command': 'rm -rf build'},
          start: 6,
        ),
        const TranscriptStop(key: 'stop', reason: StopReason.maxTokens),
        const TranscriptNote(key: 'note', text: 'Mode changed to Plan'),
      ];
      final session = FakeAgentSession(state: stateWith(items: items, pending: [PendingPermission(7, permissionRequest())]));
      await pumpView(tester, session);
      expect(rich('Worked'), findsOneWidget);
      expect(find.text('/a/x.dart'), findsNothing);
      expect(rich('x.dart'), findsNothing, reason: 'the read that went well is folded');
      expect(find.text('make \u2039U+202E\u203atest'), findsOneWidget, reason: 'through visibleText');
      expect(rich('exit 2'), findsOneWidget);
      expect(rich('error: nothing to do'), findsOneWidget, reason: 'the reason: the last line it printed');
      expect(find.text('sleep 9'), findsOneWidget);
      expect(find.text('rm -rf build'), findsOneWidget, reason: 'waiting for the person');
      expect(find.text('The agent stopped: it hit the length limit.'), findsOneWidget);
      expect(find.text('Mode changed to Plan'), findsOneWidget);

      // The request is answered: the call is no longer waiting, and folds.
      session.update((s) => s.withoutPending(7));
      await tester.pump();
      expect(find.text('rm -rf build'), findsNothing);
      expect(find.text('make \u2039U+202E\u203atest'), findsOneWidget);
    });

    testWidgets('a turn with no user message renders without a user row', (tester) async {
      await pumpView(tester, FakeAgentSession(state: stateWith(items: [readAt('r', '/a/b.dart', 0), agentAt('a', 'Found it.', 2)])));
      expect(find.text('Found it.'), findsOneWidget);
      expect(find.byType(UserRow), findsNothing);
      expect(rich('Worked'), findsOneWidget);
    });

    testWidgets('the turn that runs shows its log open and no fold line; when it ends it folds', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(
          items: [userAt('u', 'go', 0), readAt('r', '/a/b.dart', 1), runAt('c', 'dart test', 2, exitCode: 0)],
          turnActive: true,
        ),
      );
      await pumpView(tester, session);
      expect(rich('b.dart'), findsOneWidget);
      expect(find.text('dart test'), findsOneWidget);
      expect(rich('Worked'), findsNothing);
      session.update((s) => s.withTurnEnded(StopReason.endTurn));
      await tester.pump();
      expect(rich('b.dart'), findsNothing);
      expect(rich('Worked'), findsOneWidget);
    });

    testWidgets('the open state survives scrolling away and back', (tester) async {
      final session = FakeAgentSession(state: stateWith(items: turns(60)));
      await pumpView(tester, session);
      // Open the last turn's log (it is on screen), scroll far away, come back.
      await tester.tap(rich('Worked').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('file_59.dart'), findsOneWidget);
      for (var i = 0; i < 6; i++) {
        await tester.fling(find.byType(TranscriptView), const Offset(0, 800), 4000);
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(find.textContaining('file_59.dart'), findsNothing);
      await tester.tap(find.byTooltip('Jump to latest'));
      await tester.pumpAndSettle();
      expect(find.textContaining('file_59.dart'), findsOneWidget, reason: 'still open');
    });
  });

  group('tool rows', () {
    testWidgets('quiet: no chevron, about 44 dp, a shape only when the call did not go well, one line per kind', (tester) async {
      final items = [
        userAt('u', 'go', 0),
        readAt('r', '/home/dev/payments-api/lib/locale/parse.dart', 1),
        editAt('e', '/home/dev/payments-api/lib/locale/parse.dart', 2, before: 'a\nb\n', after: 'a\nB\nc\n'),
        searchAt('s', 'toLowerCase', 3, hits: 4),
        toolAt('f', title: 'Fetch', kind: ToolKind.fetch, rawInput: {'url': 'https://pub.dev/packages/x'}, start: 4),
        runAt('c', 'dart test', 5, exitCode: 0),
        runAt('x', 'make', 6, exitCode: 2, output: 'cc: error\n'),
        toolAt('p', title: 'Slow', kind: ToolKind.execute, status: ToolStatus.inProgress, rawInput: {'command': 'sleep 99'}, start: 7),
      ];
      await pumpView(tester, FakeAgentSession(state: stateWith(items: items, turnActive: true)));
      expect(find.byIcon(LucideIcons.chevronRight), findsNothing);
      expect(find.byIcon(LucideIcons.chevronDown), findsNothing);
      expect(find.byIcon(LucideIcons.circleX), findsOneWidget, reason: 'only the failure has a shape of its own');
      expect(rich('parse.dart'), findsNWidgets(2));
      expect(find.text('+1'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('1 line added, 1 line removed')), findsNothing, reason: 'no semantics without the handle');
      expect(rich('toLowerCase'), findsOneWidget);
      expect(rich('4 matches'), findsOneWidget);
      expect(find.text('pub.dev'), findsOneWidget);
      expect(find.text('dart test'), findsOneWidget);
      for (final text in ['pub.dev', 'dart test', 'sleep 99']) {
        final h = targetHeight(tester, find.text(text));
        expect(h, greaterThanOrEqualTo(kMinTap));
        expect(h, lessThan(56), reason: text);
      }
      expect(targetHeight(tester, rich('toLowerCase')), inInclusiveRange(kMinTap, 55));
    });

    testWidgets('a row opens its body on a tap and keeps it where it is', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(items: [userAt('u', 'go', 0), runAt('c', 'dart test', 2, exitCode: 0, output: 'All tests passed!\n')], turnActive: true),
      );
      await pumpView(tester, session);
      expect(find.text('All tests passed!'), findsNothing);
      await tester.tap(find.text('dart test'));
      await tester.pumpAndSettle();
      expect(find.text('All tests passed!'), findsOneWidget);
    });

    testWidgets('adjacent reads and searches that went well are one line that opens to its calls', (tester) async {
      final items = [
        userAt('u', 'go', 0),
        readAt('r1', '/a/one.dart', 1),
        readAt('r2', '/a/two.dart', 2),
        readAt('r3', '/a/three.dart', 3),
        searchAt('s1', 'foo', 4),
        searchAt('s2', 'bar', 5),
        runAt('c', 'dart test', 6, exitCode: 0),
      ];
      await pumpView(tester, FakeAgentSession(state: stateWith(items: items, turnActive: true)));
      expect(find.text('Read 3 files \u00b7 searched 2\u00d7'), findsOneWidget);
      expect(rich('one.dart'), findsNothing);
      await tester.tap(find.text('Read 3 files \u00b7 searched 2\u00d7'));
      await tester.pumpAndSettle();
      for (final name in ['one.dart', 'two.dart', 'three.dart', 'foo', 'bar']) {
        expect(rich(name), findsOneWidget, reason: name);
      }
      expect(find.text('dart test'), findsOneWidget);
      await tester.tap(find.text('Read 3 files \u00b7 searched 2\u00d7'));
      await tester.pumpAndSettle();
      expect(rich('one.dart'), findsNothing);
    });

    testWidgets('a call that is running or failed never joins a group', (tester) async {
      final items = [
        userAt('u', 'go', 0),
        readAt('r1', '/a/one.dart', 1),
        readAt('r2', '/a/two.dart', 2),
        toolAt('r3', title: 'Read', kind: ToolKind.read, status: ToolStatus.inProgress, rawInput: {'file_path': '/a/three.dart'}, start: 3),
      ];
      await pumpView(tester, FakeAgentSession(state: stateWith(items: items, turnActive: true)));
      expect(find.text('Read 2 files'), findsOneWidget);
      expect(rich('three.dart'), findsNWidgets(2), reason: 'its own row, and the status line that reads it');
    });

    test('the added and removed tones reach 4.5:1 on the page and on the quiet fills', () {
      double lum(Color c) {
        double f(double v) => v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4).toDouble();
        return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
      }

      double ratio(Color a, Color b) {
        final la = lum(a), lb = lum(b);
        return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
      }

      for (final ds in [Ds.paper, Ds.ink]) {
        for (final bg in [ds.bg, ds.surface, ds.fill, ds.fillPressed]) {
          expect(ratio(addedText(ds), bg), greaterThanOrEqualTo(4.5), reason: '${ds.brightness} added on $bg');
          expect(ratio(removedText(ds), bg), greaterThanOrEqualTo(4.5), reason: '${ds.brightness} removed on $bg');
        }
      }
    });
  });

  group('the Changed card', () {
    testWidgets('files with stats and marks; a tap opens the diff; six at most, then how many more', (tester) async {
      final items = [
        userAt('u', 'go', 0),
        editAt('e0', '/a/lib/zero.dart', 1, before: 'a\n', after: 'b\nc\n'),
        toolAt('n', title: 'Write', kind: ToolKind.edit, content: const [ToolDiff(path: '/a/lib/fresh.dart', newText: 'one\ntwo\nthree\n')], start: 2),
        toolAt('d', title: 'Delete', kind: ToolKind.delete, rawInput: {'file_path': '/a/lib/gone.dart'}, start: 3),
        for (var i = 3; i < 8; i++) editAt('e$i', '/a/lib/f$i.dart', i + 1),
        agentAt('a', 'Done.', 20),
      ];
      await pumpView(tester, FakeAgentSession(state: stateWith(items: items)));
      expect(rich('Changed'), findsOneWidget);
      expect(rich('8 files'), findsWidgets);
      expect(rich('zero.dart'), findsOneWidget);
      expect(find.text('new'), findsOneWidget, reason: 'created by the turn');
      expect(find.text('deleted'), findsOneWidget);
      expect(rich('f4.dart'), findsOneWidget);
      expect(rich('f7.dart'), findsNothing, reason: 'the seventh file and beyond are not listed');
      expect(find.text('2 more'), findsOneWidget);
      expect(targetHeight(tester, rich('zero.dart')), greaterThanOrEqualTo(kMinTap));
      expect(targetHeight(tester, find.text('2 more')), greaterThanOrEqualTo(kMinTap));

      await tester.tap(rich('zero.dart'));
      await tester.pumpAndSettle();
      expect(find.text('/a/lib/zero.dart'), findsOneWidget, reason: 'the diff panel names the file');
      expect(find.text('+ b'), findsOneWidget);
      expect(find.text('- a'), findsOneWidget);

      await tester.tap(find.text('2 more'));
      await tester.pumpAndSettle();
      expect(rich('f7.dart'), findsOneWidget);
      expect(find.text('Show fewer'), findsOneWidget);
      await tester.tap(find.text('Show fewer'));
      await tester.pumpAndSettle();
      expect(rich('f7.dart'), findsNothing);
    });

    testWidgets('absent when nothing changed', (tester) async {
      await pumpView(tester, FakeAgentSession(state: stateWith(items: [userAt('u', 'go', 0), readAt('r', '/a/b.dart', 1), agentAt('a', 'Read it.', 2)])));
      expect(rich('Changed'), findsNothing);
    });

    testWidgets('300 files: six rows and the rest on demand, built lazily, nothing overflows at 320 dp and 160% text', (tester) async {
      final built = <String>[];
      final items = [
        userAt('u', 'rename', 0),
        for (var i = 0; i < 300; i++) editAt('e$i', '/home/dev/payments-api/lib/feature_${i ~/ 10}/a_rather_long_file_name_$i.dart', i + 1),
        agentAt('a', 'Done.', 400),
      ];
      await pumpView(tester, FakeAgentSession(state: stateWith(items: items)), size: const Size(320, 640), textScale: 1.6);
      debugRowBuilt = built.add;
      expect(find.text('294 more'), findsOneWidget);
      await tester.tap(find.text('294 more'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(built.length, lessThan(30), reason: 'only the rows in view are built: ${built.length}');
      expect(find.text('Show fewer'), findsNothing, reason: 'at the far end of 300 rows');
    });
  });

  group('the divider', () {
    testWidgets('above the first unseen item, "N new", in sight when the view opens', (tester) async {
      final session = FakeAgentSession(state: stateWith(items: turns(3)));
      await pumpView(tester, session, sinceLeft: since('u2', steps: 4));
      expect(find.text('4 new'), findsOneWidget);
      final divider = tester.getRect(find.text('4 new'));
      expect(divider.bottom, lessThan(tester.getTopLeft(find.text('question 2')).dy));
      expect(divider.top, greaterThan(tester.getBottomLeft(find.text('answer 1')).dy));
      expect(position(tester).extentAfter, 0, reason: 'what is after it fits: the view stays at the end');
    });

    testWidgets('no steps counted still marks the place', (tester) async {
      await pumpView(tester, FakeAgentSession(state: stateWith(items: turns(3))), sinceLeft: since('u2', steps: 0));
      expect(find.text('New'), findsOneWidget);
    });

    testWidgets('no marker, no divider; an unknown key, no divider', (tester) async {
      await pumpView(tester, FakeAgentSession(state: stateWith(items: turns(3))));
      expect(find.textContaining(' new'), findsNothing);
      await tester.pumpWidget(_app(FakeAgentSession(state: stateWith(items: turns(3))), sinceLeft: since('gone')));
      await tester.pump();
      expect(find.textContaining(' new'), findsNothing);
    });

    testWidgets('when more than a screen is new the view opens with the divider near the top, away from the end', (tester) async {
      final session = FakeAgentSession(state: stateWith(items: turns(60)));
      await pumpView(tester, session, sinceLeft: since('u20', steps: 120));
      await tester.pump();
      expect(find.text('120 new'), findsOneWidget);
      expect(tester.getTopLeft(find.text('120 new')).dy, lessThan(120), reason: 'near the top of the list');
      expect(position(tester).extentAfter, greaterThan(500));
      expect(find.byTooltip('Jump to latest'), findsOneWidget, reason: 'the way to the end');
      await tester.tap(find.byTooltip('Jump to latest'));
      await tester.pumpAndSettle();
      expect(position(tester).extentAfter, 0);
    });

    testWidgets('a divider inside a fold goes above the fold line', (tester) async {
      final session = FakeAgentSession(state: stateWith(items: [...turns(2), ...richTurn(prefix: 'n')]));
      await pumpView(tester, session, sinceLeft: since('tool:nc1'));
      final divider = tester.getRect(find.text('3 new'));
      expect(divider.bottom, lessThan(tester.getTopLeft(rich('Worked').last).dy));
      expect(divider.top, greaterThan(tester.getBottomLeft(find.text('Fix the Hà Nội locale bug in the parser and add a regression test.')).dy));
    });

    testWidgets('it arrives late: placed, the view does not move; a second value is ignored', (tester) async {
      final session = FakeAgentSession(state: stateWith(items: turns(60)));
      await pumpView(tester, session);
      for (var i = 0; i < 3; i++) {
        await tester.fling(find.byType(TranscriptView), const Offset(0, 500), 2000);
        await tester.pump(const Duration(milliseconds: 300));
      }
      final visible = find.textContaining('question ');
      final first = visible.evaluate().first.widget as Text;
      final before = tester.getTopLeft(find.text(first.data!)).dy;
      final pixels = position(tester).pixels;

      await tester.pumpWidget(_app(session, sinceLeft: since('u3', steps: 9)));
      await tester.pump();
      expect(position(tester).pixels, pixels, reason: 'the reader is left alone');
      expect(tester.getTopLeft(find.text(first.data!)).dy, closeTo(before, 0.5), reason: 'a row inserted above the screen moves nothing');

      await tester.pumpWidget(_app(session, sinceLeft: since('u40', steps: 2)));
      await tester.pump();
      await tester.fling(find.byType(TranscriptView), const Offset(0, 100000), 8000);
      await tester.pumpAndSettle();
      expect(find.text('9 new'), findsOneWidget, reason: 'the first value stays');
      expect(find.text('2 new'), findsNothing);
    });
  });

  group('streaming', () {
    testWidgets('a live turn of 200 steps: a chunk rebuilds the live row; scrolling builds only what comes into view', (tester) async {
      final built = <String>[];
      final items = [
        userAt('u', 'audit', 0),
        for (var i = 0; i < 200; i++)
          if (i.isEven) readAt('t$i', '/a/file_$i.dart', i + 1) else runAt('t$i', 'cmd $i', i + 1, exitCode: 0),
      ];
      final session = FakeAgentSession(state: stateWith(items: items, turnActive: true).apply(const MessageChunk(MessageRole.agent, 'a1', TextBlock('first paragraph\n\nsecond'))));
      await pumpView(tester, session, size: const Size(320, 640));
      debugRowBuilt = built.add;
      final key = session.state.liveKey!;

      for (var i = 0; i < 50; i++) {
        session.apply(MessageChunk(MessageRole.agent, 'a1', TextBlock(' w$i')));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(built.toSet().difference({'$key#live', '$key#1', '$key#0'}), isEmpty, reason: 'only the live row: $built');

      built.clear();
      for (var i = 0; i < 5; i++) {
        await tester.fling(find.byType(TranscriptView), const Offset(0, 600), 3000);
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(built.toSet().length, lessThan(160), reason: 'five flings must not build 200 steps: ${built.toSet().length}');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the answer that becomes narration (a call starts after it) does not move or re-flow', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(items: [userAt('u', 'go', 0), readAt('r1', '/a/one.dart', 1)], turnActive: true)
            .apply(const MessageChunk(MessageRole.agent, 'a', TextBlock('I will run the tests now.\n\nThen I fix what fails.'))),
      );
      await pumpView(tester, session);
      final text = rich('I will run the tests now.');
      final rect = tester.getRect(text);
      final above = tester.getRect(rich('one.dart'));

      session.apply(ToolCallStart(const ToolCall(toolCallId: 't2', title: 'dart test', kind: ToolKind.execute)));
      await tester.pump();
      expect(tester.getRect(text), rect, reason: 'the text keeps its place and size');
      expect(tester.getRect(rich('one.dart')), above, reason: 'nothing above it moved');
      expect(tester.getTopLeft(find.text('dart test')).dy, greaterThan(rect.bottom));
    });

    testWidgets('the end of the answer is not a visual event: the last lines stay where they were', (tester) async {
      final items = [...turns(30), userAt('ul', 'last', 400), readAt('rl', '/a/last.dart', 401)];
      final session = FakeAgentSession(state: stateWith(items: items, turnActive: true).apply(const MessageChunk(MessageRole.agent, 'a', TextBlock('Final words.'))));
      await pumpView(tester, session, size: const Size(320, 640));
      final final_ = find.text('Final words.');
      final top = tester.getTopLeft(final_);
      session.update((s) => s.withTurnEnded(StopReason.endTurn));
      await tester.pump();
      expect(tester.getTopLeft(final_).dy, closeTo(top.dy, 0.01));
      expect(position(tester).extentAfter, 0);
    });

    testWidgets('a word selected in an earlier answer survives the turn changing below it', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(
          items: [
            userAt('u0', 'first', 0),
            agentAt('a0', 'Alpha beta gamma delta.', 1),
            userAt('u1', 'second', 10),
            readAt('r1', '/a/one.dart', 11),
          ],
          turnActive: true,
        ),
      );
      await pumpView(tester, session);
      await tester.longPressAt(tester.getTopLeft(rich('Alpha beta')) + const Offset(16, 10));
      await tester.pump();
      final region = tester.state<SelectableRegionState>(find.byType(SelectableRegion).first);
      expect(region.contextMenuButtonItems.where((i) => i.type == ContextMenuButtonType.copy), isNotEmpty);
      session.apply(ToolCallStart(const ToolCall(toolCallId: 't2', title: 'dart test', kind: ToolKind.execute)));
      session.update((s) => s.withTurnEnded(StopReason.endTurn));
      await tester.pump();
      expect(region.contextMenuButtonItems.where((i) => i.type == ContextMenuButtonType.copy), isNotEmpty, reason: 'still selected');
    });
  });

  group('the plan', () {
    PlanEntry step(String text, PlanStatus status) => PlanEntry(content: text, status: status);
    Future<void> pumpScreen(WidgetTester tester, FakeAgentSession session) async {
      tester.view.physicalSize = const Size(412, 892) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: AgentSessionScreen(key: ObjectKey(session), session: session)));
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('takes room while it has steps to do, or changed in the turn that runs; a finished plan folds into the turn', (tester) async {
      final done = [step('One', PlanStatus.completed), step('Two', PlanStatus.completed), step('Three', PlanStatus.completed)];
      final open = [step('One', PlanStatus.completed), step('Two', PlanStatus.inProgress), step('Three', PlanStatus.pending)];
      final session = FakeAgentSession(state: stateWith(items: [userAt('u', 'go', 0)], plan: done));
      await pumpScreen(tester, session);
      expect(tester.getSize(find.byType(PlanHeader)).height, 0, reason: 'a finished plan of an earlier turn');

      session.update((s) => s.withUserMessage([const TextBlock('next')]).withTurnStarted());
      await tester.pump();
      expect(tester.getSize(find.byType(PlanHeader)).height, 0, reason: 'not changed in this turn');

      session.update((s) => s.apply(PlanUpdate(open)));
      await tester.pump();
      expect(tester.getSize(find.byType(PlanHeader)).height, greaterThan(0), reason: 'a plan in progress');
      expect(rich('1 of 3'), findsOneWidget);

      session.update(
        (s) => s
            .apply(PlanUpdate([...done]))
            .apply(ToolCallStart(const ToolCall(toolCallId: 'x', title: 'ls', kind: ToolKind.execute, status: ToolStatus.completed))),
      );
      await tester.pump();
      expect(tester.getSize(find.byType(PlanHeader)).height, greaterThan(0), reason: 'changed in the turn that runs');

      session.update((s) => s.withTurnEnded(StopReason.endTurn));
      await tester.pump();
      expect(tester.getSize(find.byType(PlanHeader)).height, 0, reason: 'the turn ended: the plan is part of its summary');
      expect(rich('Plan 3 of 3 done'), findsOneWidget);
    });

    testWidgets('a plan left unfinished stays above the conversation', (tester) async {
      final open = [step('One', PlanStatus.completed), step('Two', PlanStatus.pending)];
      final session = FakeAgentSession(state: stateWith(items: [userAt('u', 'go', 0), agentAt('a', 'stopped', 1)], plan: open));
      await pumpScreen(tester, session);
      expect(tester.getSize(find.byType(PlanHeader)).height, greaterThan(0));
    });
  });
}
