import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/markdown/markdown.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_select.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_rows.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_view.dart';
import 'package:herdr_mobile/ui/features/agent_session/status_line.dart';
import 'package:herdr_mobile/ui/features/agent_session/work_log_rows.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../support/fake_agent_session.dart';
import '../support/memory_app_settings_store.dart';

// The transcript on the fast path: the message that streams is one row that listens to its own text, so
// a chunk costs the same however long the transcript is; text appears at an
// even pace; ending the message moves nothing; the reader's place, selection
// and finger are respected.

Future<void> pumpLive(
  WidgetTester tester,
  FakeAgentSession session, {
  AppSettings? settings,
  bool reducedMotion = false,
  Size size = const Size(412, 892),
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  Widget app = MaterialApp(
    theme: AppTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
      child: child!,
    ),
    home: AgentSessionScreen(key: ObjectKey(session), session: session),
  );
  if (settings != null) app = ChangeNotifierProvider<AppSettings>.value(value: settings, child: app);
  await tester.pumpWidget(app);
  await tester.pump(const Duration(milliseconds: 100));
}

/// A turn in progress: [history] settled messages, a prompt, a tool call, and
/// the answer [text] streaming (message `a1`, the live one).
AgentSessionState streaming(String text, {int history = 0}) =>
    stateWith(
      items: [
        for (var i = 0; i < history; i++) ...[userMsg('hu$i', 'question $i'), agentMsg('h$i', 'history message $i')],
        userMsg('u1', 'go'),
        toolItem('t1', title: 'Read file', kind: ToolKind.read),
      ],
      turnActive: true,
    ).apply(MessageChunk(MessageRole.agent, 'a1', TextBlock(text)));

MessageChunk chunk(String text) => MessageChunk(MessageRole.agent, 'a1', TextBlock(text));

/// 120 words and a mark at the end: far more than a frame reveals.
final lump = ' ${List.filled(120, 'word').join(' ')} ENDMARK';

Finder onScreen(String text) => find.textContaining(text, findRichText: true);

ScrollPosition transcriptPosition(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(of: find.byType(TranscriptView), matching: find.byType(Scrollable)).first)
    .position;

void main() {
  tearDown(() {
    debugRowBuilt = null;
    debugRegionBuilt = null;
    statusNow = DateTime.now;
  });

  group('the live row', () {
    testWidgets('a streaming answer shows every chunk, not only the first', (tester) async {
      final session = FakeAgentSession(state: stateWith(items: [userMsg('u1', 'go')], turnActive: true));
      await pumpLive(tester, session);
      session.apply(const MessageChunk(MessageRole.agent, 'a1', TextBlock('Hello')));
      await tester.pump();
      expect(onScreen('Hello'), findsOneWidget);
      session.apply(const MessageChunk(MessageRole.agent, 'a1', TextBlock(' world, this is the second chunk of it.')));
      await tester.pumpAndSettle();
      expect(onScreen('Hello world, this is the second chunk of it.'), findsOneWidget);
    });

    testWidgets('100 chunks rebuild the live row and nothing else: the list is not rebuilt', (tester) async {
      final session = FakeAgentSession(state: streaming('first paragraph\n\nsecond paragraph', history: 30));
      final key = session.state.liveKey!;
      await pumpLive(tester, session);
      final built = <String>[];
      final regions = <String>[];
      debugRowBuilt = built.add;
      debugRegionBuilt = regions.add;
      final items = session.state.items;

      for (var i = 0; i < 100; i++) {
        session.apply(chunk(' w$i'));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();

      expect(identical(session.state.items, items), isTrue, reason: 'the reducer left the list alone');
      expect(regions.where((r) => r == 'transcript'), isEmpty, reason: 'the transcript view was not built again');
      expect(built.toSet(), {'$key#live', '$key#1'}, reason: 'only the live row and its open tail: $built');
      expect(onScreen('w99'), findsOneWidget);
    });

    testWidgets('a block that freezes is built once and the rows above it are never built again', (tester) async {
      final session = FakeAgentSession(state: streaming('one\n\ntwo\n\nthree', history: 20));
      final key = session.state.liveKey!;
      await pumpLive(tester, session);
      final built = <String>[];
      debugRowBuilt = built.add;

      session.apply(chunk(' more\n\nfour\n\nfive'));
      await tester.pumpAndSettle();
      expect(built.where((k) => k == '$key#0' || k == '$key#1'), isEmpty, reason: 'frozen blocks are not built again: $built');
      expect(built.where((k) => k.startsWith('h') || k == 'u1' || k == 'tool:t1'), isEmpty);
      expect(built.toSet(), containsAll(['$key#2', '$key#3', '$key#4', '$key#live']));
      expect(onScreen('three more'), findsOneWidget);
      expect(onScreen('five'), findsOneWidget);
    });

    testWidgets('a live thought follows its text while it is open', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(items: [userMsg('u1', 'go')], turnActive: true)
            .apply(const MessageChunk(MessageRole.thought, 't1', TextBlock('weighing the options'))),
      );
      await pumpLive(tester, session);
      await tester.tap(find.text('Thinking'));
      await tester.pump();
      expect(
        find.descendant(of: find.byType(ThinkingRow), matching: onScreen('weighing the options')),
        findsOneWidget,
      );
      session.apply(const MessageChunk(MessageRole.thought, 't1', TextBlock(' and then some')));
      await tester.pump();
      expect(
        find.descendant(of: find.byType(ThinkingRow), matching: onScreen('weighing the options and then some')),
        findsOneWidget,
      );
    });
  });

  group('pacing', () {
    testWidgets('a lump is shown over several frames, and no frame is scheduled once it is all shown', (tester) async {
      final session = FakeAgentSession(state: streaming('Start.'));
      await pumpLive(tester, session);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse, reason: 'idle: nothing runs');

      session.apply(chunk(lump));
      await tester.pump();
      expect(onScreen('ENDMARK'), findsNothing, reason: 'held back');
      expect(onScreen('Start. word'), findsOneWidget, reason: 'the first frame already shows its share');
      expect(tester.binding.hasScheduledFrame, isTrue, reason: 'the ticker runs while text is held back');

      await tester.pumpAndSettle();
      expect(onScreen('ENDMARK'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse, reason: 'the ticker stopped with the backlog: no loop');
    });

    testWidgets('text that is there when the row first shows is history: shown whole, in the first frame', (tester) async {
      final session = FakeAgentSession(state: streaming('Start.$lump'));
      tester.view.physicalSize = const Size(412, 892) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.light(), home: AgentSessionScreen(key: ObjectKey(session), session: session)),
      );
      expect(onScreen('ENDMARK'), findsOneWidget);
    });

    testWidgets('snap: a touch on the transcript shows what is held back, at once', (tester) async {
      final session = FakeAgentSession(state: streaming('Start.'));
      await pumpLive(tester, session);
      session.apply(chunk(lump));
      await tester.pump();
      expect(onScreen('ENDMARK'), findsNothing);

      final finger = await tester.startGesture(const Offset(200, 200));
      await tester.pump();
      expect(onScreen('ENDMARK'), findsOneWidget);
      await finger.cancel();
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('snap: when the app resumes', (tester) async {
      final session = FakeAgentSession(state: streaming('Start.'));
      await pumpLive(tester, session);
      session.apply(chunk(lump));
      await tester.pump();
      expect(onScreen('ENDMARK'), findsNothing);

      // The order a phone goes through: away, then back one step at a time.
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      expect(onScreen('ENDMARK'), findsOneWidget);
    });

    testWidgets('snap: a backlog over the pacer limit (a paste, a replay as chunks) is shown at once', (tester) async {
      final session = FakeAgentSession(state: streaming('Start.'));
      await pumpLive(tester, session);
      session.apply(chunk(' ${List.filled(5000, 'x').join(' ')} ENDMARK'));
      await tester.pump();
      expect(onScreen('ENDMARK'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse, reason: 'it was shown at once: no ticker ran');
    });

    testWidgets('snap: when the message ends the settled rows show all of it', (tester) async {
      final session = FakeAgentSession(state: streaming('Start.'));
      await pumpLive(tester, session);
      session.apply(chunk(lump));
      await tester.pump();
      expect(onScreen('ENDMARK'), findsNothing);

      session.update((s) => s.withTurnEnded(StopReason.endTurn));
      await tester.pump();
      expect(onScreen('ENDMARK'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse, reason: 'the live row and its ticker are gone');
    });

    testWidgets('reduced motion reveals whole lines, the open line when it is due', (tester) async {
      final session = FakeAgentSession(state: streaming('Start.'));
      await pumpLive(tester, session, reducedMotion: true);
      session.apply(chunk('\nline two\npartial'));
      await tester.pump();
      expect(onScreen('line two'), findsOneWidget, reason: 'a complete line is shown');
      expect(onScreen('partial'), findsNothing, reason: 'the open line waits for its end');

      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(onScreen('partial'), findsOneWidget, reason: 'but not for ever');
    });

    testWidgets('Smooth text off: text is shown as it arrives', (tester) async {
      final settings = AppSettings(MemoryAppSettingsStore()..smoothText = false);
      await settings.load();
      final session = FakeAgentSession(state: streaming('Start.'));
      await pumpLive(tester, session, settings: settings);
      session.apply(chunk(lump));
      await tester.pump();
      expect(onScreen('ENDMARK'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse, reason: 'no ticker at all');
    });

    testWidgets('turning Smooth text off while text is held back shows it', (tester) async {
      final settings = AppSettings(MemoryAppSettingsStore());
      await settings.load();
      final session = FakeAgentSession(state: streaming('Start.'));
      await pumpLive(tester, session, settings: settings);
      session.apply(chunk(lump));
      await tester.pump();
      expect(onScreen('ENDMARK'), findsNothing);

      await settings.setSmoothText(false);
      await tester.pump();
      expect(onScreen('ENDMARK'), findsOneWidget);
    });
  });

  group('the end of a message', () {
    const text =
        'Intro with **bold** and `code`.\n\n## Heading\n\nA list:\n\n- one\n- two\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\n'
        '```dart\nint x = 1;\n```\n\nClosing words.';

    testWidgets('lays out the same: every block keeps its place and size when the live row becomes rows', (tester) async {
      final session = FakeAgentSession(state: streaming(text));
      await pumpLive(tester, session);
      List<Rect> blocks() => [
        for (var i = 0; i < tester.widgetList(find.byType(MdBlockView)).length; i++)
          tester.getRect(find.byType(MdBlockView).at(i)),
      ];
      final live = blocks();
      expect(live, hasLength(greaterThan(6)));
      expect(find.byKey(ValueKey('${session.state.liveKey}#live')), findsOneWidget);

      session.update((s) => s.withTurnEnded(StopReason.endTurn));
      await tester.pump();
      expect(find.byKey(ValueKey('${session.state.items.whereType<TranscriptMessage>().last.key}#live')), findsNothing);
      final settled = blocks();
      expect(settled, hasLength(live.length));
      for (var i = 0; i < live.length; i++) {
        expect(settled[i].left, closeTo(live[i].left, 0.01), reason: 'block $i');
        expect(settled[i].top, closeTo(live[i].top, 0.01), reason: 'block $i');
        expect(settled[i].width, closeTo(live[i].width, 0.01), reason: 'block $i');
        expect(settled[i].height, closeTo(live[i].height, 0.01), reason: 'block $i');
      }
    });

    testWidgets('lays out the same at 320 dp with a large text scale', (tester) async {
      final session = FakeAgentSession(state: streaming(text));
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpLive(tester, session, size: const Size(320, 640));
      List<Rect> blocks() => [
        for (var i = 0; i < tester.widgetList(find.byType(MdBlockView)).length; i++)
          tester.getRect(find.byType(MdBlockView).at(i)),
      ];
      final live = blocks();
      session.update((s) => s.withTurnEnded(StopReason.endTurn));
      await tester.pump();
      final settled = blocks();
      expect(settled, hasLength(live.length));
      for (var i = 0; i < live.length; i++) {
        expect(settled[i].left, closeTo(live[i].left, 0.01), reason: 'block $i');
        expect(settled[i].top, closeTo(live[i].top, 0.01), reason: 'block $i');
        expect(settled[i].width, closeTo(live[i].width, 0.01), reason: 'block $i');
        expect(settled[i].height, closeTo(live[i].height, 0.01), reason: 'block $i');
      }
    });

    testWidgets('moves no row, in a transcript that scrolls: the end of the turn does not slide the answer', (tester) async {
      final session = FakeAgentSession(state: streaming(text, history: 40));
      await pumpLive(tester, session, size: const Size(320, 640));
      expect(transcriptPosition(tester).extentAfter, 0);
      final closing = onScreen('Closing words.');
      final top = tester.getTopLeft(closing);
      expect(onScreen('Working'), findsOneWidget);

      session.update((s) => s.withTurnEnded(StopReason.endTurn));
      await tester.pump();
      expect(onScreen('Working'), findsNothing);
      final after = tester.getTopLeft(closing);
      expect(after.dx, closeTo(top.dx, 0.01));
      expect(after.dy, closeTo(top.dy, 0.01), reason: 'the line the reader looks at stays where it was');
      expect(transcriptPosition(tester).extentAfter, 0);
    });
  });

  group('selection', () {
    testWidgets('a word selected in a frozen block is still selected after 100 chunks', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

      Future<String?> copySelection() async {
        copied = null;
        final region = tester.state<SelectableRegionState>(find.byType(SelectableRegion).first);
        final items = region.contextMenuButtonItems.where((i) => i.type == ContextMenuButtonType.copy).toList();
        expect(items, isNotEmpty, reason: 'there is a selection to copy');
        items.single.onPressed!();
        await tester.pump();
        return copied;
      }

      Future<FakeAgentSession> select() async {
        final session = FakeAgentSession(state: streaming('Alpha beta gamma delta.\n\nSecond paragraph keeps going'));
        await pumpLive(tester, session);
        await tester.longPressAt(tester.getTopLeft(onScreen('Alpha beta')) + const Offset(16, 10));
        await tester.pump();
        return session;
      }

      var session = await select();
      final word = await copySelection();
      expect(word, isNotNull);
      expect(word, isNotEmpty);
      expect('Alpha beta gamma delta.', contains(word));

      session = await select();
      for (var i = 0; i < 100; i++) {
        session.apply(chunk(' more$i'));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect(onScreen('more99'), findsOneWidget);
      expect(await copySelection(), word, reason: 'the selection survived the live row changing under it');
    });
  });

  group('follow', () {
    testWidgets('away from the end, finished blocks turn the chevron into an "N new" pill', (tester) async {
      final handle = tester.ensureSemantics();
      final session = FakeAgentSession(state: streaming('First paragraph.', history: 60));
      await pumpLive(tester, session);

      await tester.drag(find.byType(TranscriptView), const Offset(0, 500));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byTooltip('Jump to latest'), findsOneWidget);
      expect(find.textContaining(' new'), findsNothing, reason: 'nothing finished since the reader left');
      final before = transcriptPosition(tester).pixels;

      // The live row is far out of view; its text keeps arriving.
      session.apply(chunk('\n\nSecond.\n\nThird.\n\nFourth, still open'));
      await tester.pumpAndSettle();
      expect(transcriptPosition(tester).pixels, before, reason: 'the reader is left alone');
      expect(find.text('3 new'), findsOneWidget, reason: 'three blocks froze');
      expect(find.bySemanticsLabel('3 new, jump to latest'), findsOneWidget);
      final target = find.ancestor(of: find.text('3 new'), matching: find.byType(PressBuilder)).first;
      expect(tester.getSize(target).height, greaterThanOrEqualTo(kMinTap));
      expect(tester.getSize(target).width, greaterThanOrEqualTo(kMinTap));

      session.apply(chunk('\n\nfifth'));
      await tester.pumpAndSettle();
      expect(find.text('4 new'), findsOneWidget);

      await tester.tap(find.text('4 new'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(transcriptPosition(tester).extentAfter, 0);
      expect(find.byTooltip('Jump to latest'), findsNothing);
      handle.dispose();
    });

    testWidgets('nothing moves while a finger is down; the view catches up when it lifts', (tester) async {
      final session = FakeAgentSession(state: streaming('Answer so far.', history: 40));
      await pumpLive(tester, session);
      final position = transcriptPosition(tester);
      expect(position.extentAfter, 0);

      final finger = await tester.startGesture(const Offset(200, 300));
      final pixels = position.pixels;
      session.apply(ToolCallStart(const ToolCall(toolCallId: 't2', title: 'Next step')));
      await tester.pump();
      await tester.pump();
      expect(position.pixels, pixels, reason: 'the finger is down: the view does not move');
      expect(position.extentAfter, greaterThan(0), reason: 'the content grew under it');

      await finger.cancel();
      await tester.pump();
      expect(position.extentAfter, 0, reason: 'the last finger is up: the end is in view again');
    });
  });

  group('immediate feedback', () {
    testWidgets('Send: the prompt, the cleared composer and Working are all there in the next frame', (tester) async {
      final session = FakeAgentSession(state: stateWith(items: [agentMsg('a0', 'ready')]));
      await pumpLive(tester, session);
      expect(find.textContaining('Working'), findsNothing);

      await tester.enterText(find.byType(TextField), 'do it');
      await tester.pump();
      await tester.tap(find.byIcon(LucideIcons.arrowUp));
      await tester.pump();
      expect(session.sent, ['do it']);
      expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text, isEmpty, reason: 'cleared in the same frame');
      expect(find.text('do it'), findsOneWidget, reason: 'the prompt is a row now');
      expect(find.textContaining('Working'), findsOneWidget, reason: 'the turn runs: the status row says so');
    });

    testWidgets('Working · 12s: elapsed from the start of the turn, stepping once a second, gone with the turn', (tester) async {
      final start = DateTime(2026, 10, 5, 12);
      statusNow = () => start.add(const Duration(seconds: 12));
      final session = FakeAgentSession(state: stateWith(items: [userMsg('u1', 'fix it')], turnActive: true))
        ..turnStart = start;
      await pumpLive(tester, session);
      expect(find.text('Working'), findsOneWidget);
      expect(find.text(' · 12s'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Working')).dy,
        greaterThan(tester.getBottomLeft(find.text('fix it')).dy),
        reason: 'at the tail of the transcript',
      );

      statusNow = () => start.add(const Duration(seconds: 13));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(' · 13s'), findsOneWidget);

      session.update((s) => s.withTurnEnded(StopReason.endTurn));
      await tester.pump();
      expect(find.textContaining('Working'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      expect(find.textContaining('Working'), findsNothing);
    });

    testWidgets('a running call is named with a verb and counted from its own start; a thought by its first sentence', (tester) async {
      final start = DateTime(2026, 10, 5, 12);
      statusNow = () => start.add(const Duration(seconds: 95));
      final run = TranscriptTool(
        const ToolCall(
          toolCallId: 'c1',
          title: 'flutter test',
          kind: ToolKind.execute,
          status: ToolStatus.inProgress,
          rawInput: {'command': 'flutter test'},
        ),
        at: start.add(const Duration(seconds: 80)),
      );
      final session = FakeAgentSession(
        state: stateWith(items: [
          TranscriptMessage(key: 'u1', role: MessageRole.user, blocks: const [TextBlock('fix it')], at: start),
          run,
        ], turnActive: true),
      )..turnStart = start;
      await pumpLive(tester, session);
      expect(find.text('Running flutter test'), findsOneWidget);
      expect(find.text(' · 15s'), findsOneWidget, reason: 'the call has run for 15 s; the turn for 95 s');

      session.update((s) => s.apply(ToolCallPatchUpdate(ToolCallPatch('c1', {'toolCallId': 'c1', 'status': 'completed'}))));
      session.apply(const MessageChunk(MessageRole.thought, 'th', TextBlock('Checking the locale files. Then more')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Running flutter test'), findsNothing, reason: 'the call is over');
      expect(find.text('Checking the locale files.'), findsOneWidget, reason: 'the first sentence of the thought');
    });

    testWidgets('quiet for a minute or more is said in words; never while waiting for the person', (tester) async {
      final start = DateTime(2026, 10, 5, 12);
      var now = start.add(const Duration(seconds: 30));
      statusNow = () => now;
      final session = FakeAgentSession(
        state: stateWith(
          items: [TranscriptMessage(key: 'u1', role: MessageRole.user, blocks: const [TextBlock('fix it')], at: start)],
          turnActive: true,
        ).apply(const ToolCallStart(ToolCall(toolCallId: 't', title: 'flutter test', kind: ToolKind.execute)), at: start),
      )..turnStart = start;
      await pumpLive(tester, session);
      expect(find.textContaining('Quiet'), findsNothing);

      now = start.add(const Duration(seconds: 150));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Quiet for 2m'), findsOneWidget);
      expect(find.text('Running flutter test'), findsOneWidget);

      // Something arrives: the silence starts over.
      session.update(
        (s) => s.apply(ToolCallPatchUpdate(ToolCallPatch('t', {'toolCallId': 't', 'status': 'in_progress'})), at: now),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('Quiet'), findsNothing);
    });

    testWidgets('the row is not shown while the agent waits for the person', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(
          items: [userMsg('u1', 'fix it')],
          turnActive: true,
          pending: [PendingPermission(7, permissionRequest())],
        ),
      );
      await pumpLive(tester, session);
      expect(find.textContaining('Working'), findsNothing);
    });

    test('elapsed time reads as seconds, minutes and hours', () {
      expect(elapsedLabel(Duration.zero), '0s');
      expect(elapsedLabel(const Duration(seconds: 59)), '59s');
      expect(elapsedLabel(const Duration(seconds: 60)), '1m 00s');
      expect(elapsedLabel(const Duration(seconds: 125)), '2m 05s');
      expect(elapsedLabel(const Duration(hours: 1, minutes: 2, seconds: 9)), '1h 02m');
      expect(elapsedLabel(const Duration(seconds: -4)), '0s');
    });
  });

  group('a recorded turn replayed through the screen', () {
    final root = Directory('test/fixtures/traces');
    final files = root.existsSync()
        ? (root.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.jsonl')).toList()
            ..sort((a, b) => a.path.compareTo(b.path)))
        : <File>[];

    test('there are traces to replay', () => expect(files, isNotEmpty));

    for (final file in files) {
      final name = file.uri.pathSegments.sublist(file.uri.pathSegments.length - 2).join('/');
      testWidgets('$name: ends with the text of the final state on screen', (tester) async {
        const size = Size(412, 30000);
        final session = FakeAgentSession(state: const AgentSessionState('s'));
        await pumpLive(tester, session, size: size);
        var step = 0;
        for (final event in _events(file)) {
          switch (event) {
            case SessionUpdate():
              session.apply(event);
            case String():
              session.update((s) => s.withUserMessage([TextBlock(event)]).withTurnStarted());
            case StopReason():
              session.update((s) => s.withTurnEnded(event));
          }
          if (++step % 3 == 0) await tester.pump(const Duration(milliseconds: 16));
        }
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        final replayed = _transcriptText(tester);
        expect(replayed, isNotEmpty);

        // The same final state, laid out in one go, with nothing streaming.
        final reference = FakeAgentSession(state: session.state);
        await tester.pumpWidget(const SizedBox());
        await pumpLive(tester, reference, size: size);
        expect(replayed, _transcriptText(tester));
      });
    }
  });
}

/// Every piece of text the transcript paints, in order, without the status
/// line and the fold lines (a fold line says what the session saw happen, and
/// a state laid out in one go did not see the plan change).
String _transcriptText(WidgetTester tester) => tester
    .widgetList<RichText>(find.descendant(of: find.byType(TranscriptView), matching: find.byType(RichText)))
    .map((r) => r.text.toPlainText())
    .where((t) => !t.startsWith('Working') && !t.startsWith('Worked') && t != '\u00A0' && !t.startsWith(' · '))
    .join('\n');

/// A trace as the client sees it: the agent's updates, and what the client did
/// (the prompt it sent, the response that ended the turn).
List<Object> _events(File file) {
  final out = <Object>[];
  Object? promptId;
  for (final row in const LineSplitter().convert(file.readAsStringSync())) {
    if (row.trim().isEmpty) continue;
    final j = jsonDecode(row) as Map<String, dynamic>;
    final msg = j['msg'] as Map<String, dynamic>;
    final received = j['dir'] == 'recv';
    if (!received && msg['method'] == 'session/prompt') {
      promptId = msg['id'];
      final prompt = (msg['params'] as Map)['prompt'] as List;
      out.add(prompt.map((b) => (b as Map)['text'] ?? '').join());
    } else if (received && msg['method'] == 'session/update') {
      out.add(SessionUpdate.parse((msg['params'] as Map)['update']));
    } else if (received && promptId != null && msg['id'] == promptId && msg.containsKey('result')) {
      out.add(StopReason.parse((msg['result'] as Map)['stopReason'] as String?));
      promptId = null;
    }
  }
  return out;
}
