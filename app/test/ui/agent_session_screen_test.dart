import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/command_source.dart';
import 'package:herdr_mobile/data/repositories/slash_usage.dart';
import 'package:herdr_mobile/data/models/slash_command.dart';
import 'package:herdr_mobile/ui/core/tap_guard.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agents/agent_navigation.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/core/status_panel.dart';
import 'package:herdr_mobile/ui/features/composer/command_model.dart';
import 'package:herdr_mobile/ui/features/agent_session/diff_lines.dart';
import 'package:herdr_mobile/ui/features/agent_session/plan_header.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_select.dart';
import 'package:herdr_mobile/ui/features/agent_session/tool_rows.dart' show FoldRail, commandOutputLines, toolTextLines;
import 'package:herdr_mobile/ui/features/agent_session/transcript_rows.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_view.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../support/fake_agent_session.dart';

Future<void> pumpScreen(
  WidgetTester tester,
  FakeAgentSession session, {
  Size size = const Size(412, 892),
  double textScale = 1,
  SlashUsage? usage,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final screen = AgentSessionScreen(key: ObjectKey(session), session: session);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: usage == null ? screen : ChangeNotifierProvider.value(value: usage, child: screen),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

/// A chat session of an agent in a terminal: it knows commands and skills
/// beyond what the agent advertised, and is asked for them.
class _CatalogSession extends FakeAgentSession implements SessionCommands {
  var wanted = 0;
  var _commands = const <SlashCommand>[];

  @override
  List<SlashCommand> get slashCommands => _commands;

  @override
  void wantCommands() => wanted++;

  void learn(List<SlashCommand> commands) {
    _commands = commands;
    notifyListeners();
  }
}

class _MemoryUsageStore implements SlashUsageStore {
  SlashUsageMemory memory = const SlashUsageMemory();

  @override
  Future<SlashUsageMemory> read() async => memory;

  @override
  Future<void> write(SlashUsageMemory value) async => memory = value;
}

ScrollPosition transcriptPosition(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(of: find.byType(TranscriptView), matching: find.byType(Scrollable)).first)
    .position;

TextField composerField(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField).last);

/// The haptics the screen asks for, as `HapticFeedbackType.*` names.
List<Object?> recordHaptics(WidgetTester tester) {
  final haptics = <Object?>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') haptics.add(call.arguments);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return haptics;
}

/// Text inside the link's status strip.
Finder strip(String text) =>
    find.descendant(of: find.byType(StatusStrip), matching: find.textContaining(text, findRichText: true));

void main() {
  tearDown(() {
    debugRowBuilt = null;
    debugRegionBuilt = null;
  });

  group('transcript', () {
    testWidgets('renders every kind of item', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(
          items: [
            userMsg('u1', 'Fix the “Hà Nội” locale'),
            thoughtMsg('th', 'weighing the options quietly'),
            TranscriptMessage(
              key: 'a1',
              role: MessageRole.agent,
              messageId: 'a1',
              blocks: [
                const TextBlock('## Result\n\nDone with **bold** and `code`.\n\n- first\n- second'),
                const ResourceLinkBlock(uri: 'file:///srv/app/notes.txt', name: 'notes.txt'),
                const ImageBlock(data: '', mimeType: 'image/png'),
                const UnknownBlock('video', {}),
              ],
            ),
            toolItem('t1', title: 'Read lib/main.dart', kind: ToolKind.read),
            toolItem('t2', title: 'Run the tests', kind: ToolKind.execute, status: ToolStatus.failed),
            toolItem('t3', title: 'Search for usages', kind: ToolKind.search, status: ToolStatus.inProgress),
            toolItem('t4', title: 'Fetch docs', kind: ToolKind.fetch, status: ToolStatus.pending),
          ],
          turnActive: true,
        ),
      );
      await pumpScreen(tester, session);

      expect(find.text('Fix the “Hà Nội” locale'), findsOneWidget);
      expect(find.text('Thinking'), findsOneWidget);
      expect(find.text('weighing the options quietly'), findsNothing);
      expect(find.text('Result'), findsOneWidget);
      expect(find.textContaining('Done with', findRichText: true), findsOneWidget);
      expect(find.text('first'), findsOneWidget);
      expect(find.textContaining('notes.txt', findRichText: true), findsOneWidget);
      expect(find.textContaining('Image', findRichText: true), findsOneWidget);
      expect(find.textContaining('can’t show', findRichText: true), findsOneWidget);
      for (final title in ['Read lib/main.dart', 'Run the tests', 'Search for usages', 'Fetch docs']) {
        expect(find.text(title), findsOneWidget);
      }
      expect(find.byIcon(LucideIcons.terminal), findsOneWidget);
      expect(find.byIcon(LucideIcons.circleX), findsOneWidget);

      await tester.tap(find.text('Thinking'));
      await tester.pump();
      expect(find.text('weighing the options quietly'), findsOneWidget);
    });

    testWidgets('an empty session says so', (tester) async {
      await pumpScreen(tester, FakeAgentSession());
      expect(find.text('Nothing said yet'), findsOneWidget);
    });

    testWidgets('a long user message folds and unfolds', (tester) async {
      final text = List.generate(30, (i) => 'row $i').join('\n');
      await pumpScreen(tester, FakeAgentSession(state: stateWith(items: [userMsg('u', text)])));
      expect(find.text('Show more'), findsOneWidget);
      expect(tester.widget<Text>(find.textContaining('row 0')).maxLines, 8);
      await tester.tap(find.text('Show more'));
      await tester.pump();
      expect(find.text('Show less'), findsOneWidget);
      expect(tester.widget<Text>(find.textContaining('row 0')).maxLines, isNull);
    });

    testWidgets('a short user message wraps instead of being cut to one line', (tester) async {
      const text = 'Rename the Vietnamese locale files and make sure everything about the payments service still renders properly afterwards';
      await pumpScreen(tester, FakeAgentSession(state: stateWith(items: [userMsg('u', text)])), size: const Size(320, 640));
      expect(tester.getSize(find.text(text)).height, greaterThan(30));
    });

    testWidgets('tool output shows its last lines and "Show all" the rest', (tester) async {
      final output = List.generate(100, (i) => 'out $i').join('\n');
      final session = FakeAgentSession(
        state: stateWith(
          items: [
            toolItem(
              't1',
              title: 'Run the build',
              kind: ToolKind.execute,
              content: [ToolContentBlock(TextBlock(output))],
            ),
          ],
          turnActive: true,
        ),
      );
      await pumpScreen(tester, session);
      expect(find.text('out 99'), findsNothing);
      await tester.tap(find.text('Run the build'));
      await tester.pump();
      expect(find.text('out 99'), findsOneWidget);
      expect(find.text('out ${100 - commandOutputLines}'), findsOneWidget);
      expect(find.text('out ${99 - commandOutputLines}'), findsNothing);
      expect(find.text('${100 - commandOutputLines} earlier lines'), findsOneWidget);

      await tester.tap(find.text('Show all'));
      await tester.pump();
      expect(find.text('out 0'), findsOneWidget);
      expect(find.text('Show less'), findsOneWidget);
    });

    testWidgets('a file the agent read shows its first lines and "Show all" the rest', (tester) async {
      final file = List.generate(100, (i) => 'line $i').join('\n');
      final session = FakeAgentSession(
        state: stateWith(
          items: [
            toolItem('t1', title: 'Read retry.go', kind: ToolKind.read, content: [ToolContentBlock(TextBlock(file))]),
          ],
          turnActive: true,
        ),
      );
      await pumpScreen(tester, session);
      await tester.tap(find.textContaining('retry.go'));
      await tester.pump();
      expect(find.text('line 0'), findsOneWidget);
      expect(find.text('line ${toolTextLines - 1}'), findsOneWidget);
      expect(find.text('line $toolTextLines'), findsNothing);
      expect(find.text('${100 - toolTextLines} more lines'), findsOneWidget);
    });

    testWidgets('an open tool folds from the rail beside its output, and its header comes back into view', (tester) async {
      final output = List.generate(100, (i) => 'out $i').join('\n');
      final session = FakeAgentSession(
        state: stateWith(
          items: [
            toolItem('t1', title: 'Run the build', kind: ToolKind.execute, content: [ToolContentBlock(TextBlock(output))]),
          ],
          turnActive: true,
        ),
      );
      await pumpScreen(tester, session);
      await tester.tap(find.text('Run the build'));
      await tester.pump();
      await tester.tap(find.text('Show all'));
      await tester.pumpAndSettle();
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      // Read down to the end of the output: the header is far above.
      await tester.dragUntilVisible(find.text('out 99'), find.byType(CustomScrollView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('Run the build')).bottom, lessThan(0), reason: 'the header scrolled away');

      final rail = tester.getRect(find.byType(FoldRail));
      await tester.tapAt(Offset(rail.center.dx, math.min(rail.bottom - 20, screen.height / 2)));
      await tester.pumpAndSettle();

      expect(find.text('out 99'), findsNothing, reason: 'folded');
      final header = tester.getRect(find.text('Run the build'));
      expect(header.top, greaterThanOrEqualTo(0));
      expect(header.bottom, lessThanOrEqualTo(screen.height));
    });

    testWidgets('a diff colours added and removed lines in the terminal palette of the theme', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(
          items: [
            toolItem(
              't1',
              title: 'Edit config',
              kind: ToolKind.edit,
              content: const [ToolDiff(path: 'config.yaml', oldText: 'a\nb\nc', newText: 'a\nB\nc')],
            ),
          ],
          turnActive: true,
        ),
      );
      await pumpScreen(tester, session);
      await tester.tap(find.text('config.yaml'));
      await tester.pump();
      expect(find.text('config.yaml'), findsNWidgets(2), reason: 'the row, and the label of its diff');
      expect(tester.widget<Text>(find.text('- b')).style!.color, TerminalPalette.light.ansi[1]);
      expect(tester.widget<Text>(find.text('+ B')).style!.color, TerminalPalette.light.ansi[2]);
      expect(find.text('  a'), findsOneWidget);
    });

    testWidgets('a call without content shows its raw output, then its input', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(
          items: [
            toolItem('t1', title: 'Lookup', rawOutput: {'found': 3}),
            toolItem('t2', title: 'Ping', status: ToolStatus.inProgress),
          ],
          turnActive: true,
        ),
      );
      await pumpScreen(tester, session);
      await tester.tap(find.text('Lookup'));
      await tester.pump();
      expect(find.textContaining('"found": 3'), findsOneWidget);
      await tester.tap(find.text('Ping').first);
      await tester.pump();
      expect(find.text('Waiting for output…'), findsOneWidget);
    });

    // omp wraps every result as `{content: [{type: text, text}], details}`. A
    // `wait` still running has empty text, and the row used to dump the whole
    // envelope as JSON (job ids, milliseconds) where the person looks for
    // what happened.
    testWidgets('an omp result shows its text, never its envelope', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(
          items: [
            toolItem('t1', title: 'Waiting for CI', status: ToolStatus.inProgress, rawOutput: {
              'content': [{'type': 'text', 'text': ''}],
              'details': {'op': 'wait', 'jobs': [{'id': 'bg_20', 'status': 'running', 'durationMs': 91542}]},
            }),
            toolItem('t2', title: 'Jobs', rawOutput: {
              'content': [{'type': 'text', 'text': 'bg_20 finished: success'}],
              'details': {'op': 'wait', 'jobs': [{'id': 'bg_20', 'status': 'completed'}]},
            }),
          ],
          turnActive: true,
        ),
      );
      await pumpScreen(tester, session);
      await tester.tap(find.text('Waiting for CI').first);
      await tester.pump();
      expect(find.textContaining('"content"', findRichText: true), findsNothing);
      expect(find.text('Waiting for output…'), findsOneWidget);
      await tester.tap(find.text('Jobs'));
      await tester.pump();
      expect(find.textContaining('bg_20 finished: success', findRichText: true), findsOneWidget);
      expect(find.textContaining('"details"', findRichText: true), findsNothing);
    });

    testWidgets('a streaming answer is one live row: a chunk rebuilds it alone, a structural change rebuilds the rows it changed', (tester) async {
      final built = <String>[];
      debugRowBuilt = built.add;
      final session = FakeAgentSession(
        state: stateWith(
          items: [userMsg('u1', 'go'), toolItem('t1', title: 'Read file', kind: ToolKind.read)],
          turnActive: true,
        ).apply(const MessageChunk(MessageRole.agent, 'a1', TextBlock('first paragraph\n\nsecond paragraph'))),
      );
      final key = session.state.liveKey!;
      await pumpScreen(tester, session);
      expect(built.toSet(), {'u1', 'tool:t1', '$key#live', '$key#0', '$key#1'});

      built.clear();
      session.apply(const MessageChunk(MessageRole.agent, 'a1', TextBlock(' grows')));
      await tester.pumpAndSettle();
      expect(built.toSet(), {'$key#live', '$key#1'}, reason: 'the live row and its open tail, nothing else');
      expect(find.textContaining('second paragraph grows', findRichText: true), findsOneWidget);

      // A tool call starts: the message is settled into the rows it keeps.
      built.clear();
      session.apply(ToolCallStart(const ToolCall(toolCallId: 't2', title: 'Next step')));
      await tester.pump();
      expect(built.toSet(), {'$key#0', '$key#1', 'tool:t2'}, reason: 'the settled message and the new tool; not the rows above');

      built.clear();
      session.apply(ToolCallPatchUpdate(ToolCallPatch('t2', {'toolCallId': 't2', 'status': 'completed'})));
      await tester.pump();
      expect(built, ['tool:t2']);
    });

    testWidgets('follows the end while the agent writes, and the keyboard moving rebuilds none of the rows in view', (tester) async {
      final built = <String>[];
      debugRowBuilt = built.add;
      final session = FakeAgentSession(
        state: stateWith(
          items: [for (var i = 0; i < 300; i++) ...[userMsg('u$i', 'question $i'), agentMsg('a$i', 'message number $i')]],
        ),
      );
      await pumpScreen(tester, session);
      expect(transcriptPosition(tester).extentAfter, 0);
      expect(find.text('message number 299'), findsOneWidget);

      // The newest message grows by several lines: the end stays in view.
      session.apply(MessageChunk(MessageRole.agent, 'a299', TextBlock('\n\n${List.filled(12, 'more words here').join('\n\n')}')));
      await tester.pump();
      expect(transcriptPosition(tester).extentAfter, 0);
      expect(find.textContaining('more words here'), findsWidgets);

      // The keyboard opens over several frames.
      built.clear();
      final regions = <String>[];
      debugRegionBuilt = regions.add;
      for (var i = 1; i <= 6; i++) {
        tester.view.viewInsets = FakeViewPadding(bottom: 100.0 * i);
        await tester.pump(const Duration(milliseconds: 16));
      }
      addTearDown(tester.view.resetViewInsets);
      // The window slides under the list as it shrinks, so a row at its top
      // edge can be mounted again; nothing in view at the bottom is rebuilt.
      expect(built.length, lessThanOrEqualTo(6), reason: 'rows rebuilt for an inset change: $built');
      expect(built.where((k) => int.parse(k.substring(1, k.indexOf('#'))) > 289), isEmpty, reason: '$built');
      expect(regions, isEmpty, reason: 'regions rebuilt for an inset change: $regions');
      expect(transcriptPosition(tester).extentAfter, 0);
    });

    testWidgets('reading earlier output is left alone; a button jumps to the latest', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(
          items: [for (var i = 0; i < 300; i++) ...[userMsg('u$i', 'question $i'), agentMsg('a$i', 'message number $i')]],
        ),
      );
      await pumpScreen(tester, session);
      expect(find.byTooltip('Jump to latest'), findsNothing);

      await tester.drag(find.byType(TranscriptView), const Offset(0, 500));
      await tester.pump(const Duration(milliseconds: 100));
      final position = transcriptPosition(tester);
      expect(position.extentAfter, greaterThan(300));
      expect(find.byTooltip('Jump to latest'), findsOneWidget);

      final before = position.pixels;
      session.apply(MessageChunk(MessageRole.agent, 'a299', TextBlock(' and more\n\nnew paragraph at the end')));
      await tester.pump();
      expect(transcriptPosition(tester).pixels, before, reason: 'the view moved under the reader');
      expect(find.byTooltip('Jump to latest'), findsOneWidget);

      await tester.tap(find.byTooltip('Jump to latest'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(transcriptPosition(tester).extentAfter, 0);
      expect(find.text('new paragraph at the end'), findsOneWidget);
      expect(find.byTooltip('Jump to latest'), findsNothing);
    });

    testWidgets('opening a tool at the end keeps it where it is', (tester) async {
      final output = List.generate(30, (i) => 'out $i').join('\n');
      final session = FakeAgentSession(
        state: stateWith(
          items: [
            for (var i = 0; i < 40; i++) ...[userMsg('u$i', 'question $i'), agentMsg('a$i', 'message $i')],
            userMsg('uL', 'run it'),
            toolItem('t1', title: 'Last tool', kind: ToolKind.execute, content: [ToolContentBlock(TextBlock(output))]),
          ],
          turnActive: true,
        ),
      );
      await pumpScreen(tester, session);
      final top = tester.getTopLeft(find.text('Last tool')).dy;
      await tester.tap(find.text('Last tool'));
      await tester.pump();
      expect(tester.getTopLeft(find.text('Last tool')).dy, top);
    });
  });

  group('plan', () {
    testWidgets('shows progress, the current step, and every step when opened', (tester) async {
      final plan = [
        for (var i = 0; i < 7; i++)
          PlanEntry(
            content: 'Step $i',
            status: i < 3 ? PlanStatus.completed : (i == 3 ? PlanStatus.inProgress : PlanStatus.pending),
          ),
      ];
      await pumpScreen(tester, FakeAgentSession(state: stateWith(plan: plan)));
      expect(find.textContaining('3 of 7', findRichText: true), findsOneWidget);
      expect(find.textContaining('Step 3', findRichText: true), findsOneWidget);
      expect(find.text('Step 0'), findsNothing);

      await tester.tap(find.textContaining('Plan', findRichText: true));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Step 0'), findsOneWidget);
      expect(find.text('Step 6'), findsOneWidget);
    });

    testWidgets('takes no room without a plan', (tester) async {
      await pumpScreen(tester, FakeAgentSession());
      expect(find.textContaining('Plan', findRichText: true), findsNothing);
    });
  });

  group('composer', () {
    testWidgets('sends the draft once, trimmed, and clears the field', (tester) async {
      final session = FakeAgentSession();
      await pumpScreen(tester, session);
      await tester.enterText(find.byType(TextField), '  hello there  ');
      await tester.pump();
      await tester.tap(find.byIcon(LucideIcons.arrowUp));
      await tester.pump();
      expect(session.sent, ['hello there']);
      expect(composerField(tester).controller!.text, isEmpty);
      expect(find.text('hello there'), findsOneWidget, reason: 'the transcript shows the prompt');
    });

    testWidgets('a send that fails gives the text back with no sent haptic; the next one goes and clears it', (tester) async {
      final haptics = recordHaptics(tester);
      final session = FakeAgentSession()..refuseSends = 'Not connected. The message was not sent.';
      await pumpScreen(tester, session);
      await tester.enterText(find.byType(TextField), 'fix the build');
      await tester.pump();
      await tester.tap(find.byIcon(LucideIcons.arrowUp));
      await tester.pump();
      expect(session.sent, isEmpty);
      expect(composerField(tester).controller!.text, 'fix the build');
      expect(haptics, isNot(contains('HapticFeedbackType.lightImpact')), reason: 'nothing went');
      expect(haptics, contains('HapticFeedbackType.heavyImpact'));

      session.refuseSends = null;
      haptics.clear();
      await tester.tap(find.byIcon(LucideIcons.arrowUp));
      await tester.pump();
      expect(session.sent, ['fix the build']);
      expect(composerField(tester).controller!.text, isEmpty);
      expect(haptics, contains('HapticFeedbackType.lightImpact'));
    });

    testWidgets('the field empties at once; a failure puts the text back ahead of what was typed meanwhile', (tester) async {
      final session = FakeAgentSession()
        ..holdSends = Completer<void>()
        ..refuseSends = 'Not connected. The message was not sent.';
      await pumpScreen(tester, session);
      await tester.enterText(find.byType(TextField), 'fix the build');
      await tester.pump();
      await tester.tap(find.byIcon(LucideIcons.arrowUp));
      await tester.pump();
      expect(composerField(tester).controller!.text, isEmpty, reason: 'nothing visible waits for the agent');

      await tester.enterText(find.byType(TextField), 'and run the tests');
      session.holdSends!.complete();
      await tester.pump();
      expect(composerField(tester).controller!.text, 'fix the build\nand run the tests');
    });

    testWidgets('nothing is sent for a blank draft', (tester) async {
      final session = FakeAgentSession();
      await pumpScreen(tester, session);
      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump();
      await tester.tap(find.byIcon(LucideIcons.arrowUp));
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(session.sent, isEmpty);
    });

    testWidgets('while the agent works the button stops it, once, and the keyboard cannot send', (tester) async {
      final session = FakeAgentSession(state: stateWith(turnActive: true));
      await pumpScreen(tester, session);
      expect(find.byIcon(LucideIcons.arrowUp), findsNothing);
      await tester.enterText(find.byType(TextField), 'steer left');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(session.sent, isEmpty);
      await tester.pump(tapGuard);
      await tester.tap(find.byIcon(LucideIcons.square));
      await tester.pump(const Duration(milliseconds: 50));
      expect(session.cancelCount, 1);
      // The stop is under way: its button is a spinner now and takes no tap.
      expect(find.byIcon(LucideIcons.square), findsNothing);
    });

    testWidgets('Stop takes no tap right after a turn starts: a double tap on Send cannot cancel it', (tester) async {
      final session = FakeAgentSession();
      await pumpScreen(tester, session);
      await tester.enterText(find.byType(TextField), 'go');
      await tester.pump();

      await tester.tap(find.byIcon(LucideIcons.arrowUp));
      await tester.pump(const Duration(milliseconds: 50));
      expect(session.sent, ['go']);
      expect(find.byIcon(LucideIcons.square), findsOneWidget, reason: 'Stop appeared beside Send');

      await tester.tap(find.byIcon(LucideIcons.square));
      await tester.pump(const Duration(milliseconds: 50));
      expect(session.cancelCount, 0, reason: 'the second tap of a double tap on Send');

      await tester.pump(tapGuard);
      await tester.tap(find.byIcon(LucideIcons.square));
      await tester.pump(const Duration(milliseconds: 50));
      expect(session.cancelCount, 1);
    });

    testWidgets('is disabled with the reason unless the link is live', (tester) async {
      final session = FakeAgentSession(link: AgentLink.reconnecting);
      await pumpScreen(tester, session);
      expect(composerField(tester).enabled, isFalse);
      expect(find.text('Reconnecting… you can write when it is back'), findsOneWidget);

      session.setLink(AgentLink.live);
      await tester.pump();
      expect(composerField(tester).enabled, isTrue);
      expect(find.text('Message Claude Code…'), findsOneWidget);
    });

    testWidgets('an ended session is read only and says why', (tester) async {
      final session = FakeAgentSession(
        link: AgentLink.ended,
        error: 'The agent exited with code 1',
        state: stateWith(items: [userMsg('u', 'earlier prompt')]),
      );
      await pumpScreen(tester, session);
      expect(find.text('earlier prompt'), findsOneWidget);
      expect(strip('Session ended'), findsOneWidget);
      expect(find.textContaining('exited with code 1', findRichText: true), findsOneWidget);
      expect(composerField(tester).enabled, isFalse);
      expect(find.text('Session ended · read only'), findsOneWidget);
    });
  });

  group('slash palette', () {
    const commands = [
      AcpCommand(name: 'compact', description: 'Summarise the conversation', inputHint: 'what to keep'),
      AcpCommand(name: 'review', description: 'Review the diff'),
      AcpCommand(name: 'skill:deploy', description: 'Ship it to production'),
    ];

    testWidgets('lists the agent\'s commands for a lone slash word and fills the pick', (tester) async {
      final session = FakeAgentSession(state: stateWith(commands: commands));
      await pumpScreen(tester, session);
      expect(find.text('/compact', findRichText: true), findsNothing);

      await tester.enterText(find.byType(TextField), '/');
      await tester.pump();
      expect(find.textContaining('/compact', findRichText: true), findsOneWidget);
      expect(find.textContaining('what to keep', findRichText: true), findsOneWidget);
      expect(find.text('Summarise the conversation'), findsOneWidget);
      expect(find.textContaining('/skill:deploy', findRichText: true), findsOneWidget);

      await tester.enterText(find.byType(TextField), '/rev');
      await tester.pump();
      expect(find.textContaining('/compact', findRichText: true), findsNothing);
      await tester.tap(find.textContaining('/review', findRichText: true));
      await tester.pump();
      expect(composerField(tester).controller!.text, '/review ');
      // The command is chosen: the palette steps aside for its arguments.
      expect(find.text('Review the diff'), findsNothing);
    });

    test('matching: starts, then contains, then description; a full word alone shows nothing', () {
      List<String> names(List<AcpCommand> list, String input) {
        final source = SessionCommandSource(FakeAgentSession(state: stateWith(commands: list)));
        final model = CommandPaletteModel(source: source);
        addTearDown(() {
          model.dispose();
          source.dispose();
        });
        return [for (final c in model.match(input)) c.name];
      }

      expect(names(commands, '/'), ['compact', 'review', 'skill:deploy']);
      expect(names(commands, '/e'), ['review', 'skill:deploy', 'compact']);
      expect(names(commands, '/prod'), ['skill:deploy']);
      expect(names(commands, '/review'), isEmpty);
      expect(names(commands, '/review now'), isEmpty);
      expect(names(commands, 'review'), isEmpty);
      expect(names(const [], '/'), isEmpty);
    });

    testWidgets('a session that knows more is asked on the first slash, and what it learns shows with its tag', (tester) async {
      final session = _CatalogSession();
      await pumpScreen(tester, session);
      expect(session.wanted, 0, reason: 'nothing is loaded for a chat that never starts a command');

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();
      expect(session.wanted, 0);

      await tester.enterText(find.byType(TextField), '/');
      await tester.pump();
      expect(session.wanted, 1);
      expect(find.textContaining('/ship', findRichText: true), findsNothing);

      session.learn(const [
        SlashCommand('ship', 'Ship it', SlashSource.project),
        SlashCommand('compact', 'Summarise', SlashSource.builtIn, hint: 'what to keep'),
      ]);
      await tester.pump();
      expect(find.textContaining('/ship', findRichText: true), findsOneWidget);
      expect(find.text('project'), findsOneWidget);
      expect(find.textContaining('what to keep', findRichText: true), findsOneWidget);
    });

    testWidgets('a long press pins in the chat, and a sent command is remembered under the agent', (tester) async {
      final usage = SlashUsage(_MemoryUsageStore());
      final session = FakeAgentSession(state: stateWith(commands: commands));
      await pumpScreen(tester, session, usage: usage);

      await tester.enterText(find.byType(TextField), '/');
      await tester.pump();
      await tester.longPress(find.textContaining('/review', findRichText: true));
      await tester.pump();
      expect(usage.isPinned('claude', 'review'), isTrue);
      expect(find.byIcon(LucideIcons.pin), findsOneWidget);

      await tester.enterText(find.byType(TextField), '/compact now');
      await tester.pump();
      await tester.tap(find.byIcon(LucideIcons.arrowUp));
      await tester.pump();
      expect(usage.count('claude', 'compact'), 1);
    });
  });

  group('link', () {
    testWidgets('strips for connecting, reconnecting, ended and failed; none when live', (tester) async {
      final session = FakeAgentSession(link: AgentLink.connecting);
      await pumpScreen(tester, session);
      expect(strip('Connecting…'), findsOneWidget);

      session.setLink(AgentLink.reconnecting, error: 'Wi-Fi dropped');
      await tester.pump();
      expect(strip('Reconnecting…'), findsOneWidget);
      expect(find.textContaining('Wi-Fi dropped', findRichText: true), findsOneWidget);

      session.setLink(AgentLink.failed, error: 'No route to host');
      await tester.pump();
      expect(strip('Couldn’t connect'), findsOneWidget);
      expect(find.textContaining('No route to host', findRichText: true), findsOneWidget);

      session.setLink(AgentLink.live);
      await tester.pump();
      expect(strip('Reconnecting…'), findsNothing);
      expect(strip('Couldn’t connect'), findsNothing);
    });

    testWidgets('a long reason opens in full', (tester) async {
      final reason = 'The agent exited: ${'x' * 200}';
      final session = FakeAgentSession(link: AgentLink.ended, error: reason);
      await pumpScreen(tester, session);
      await tester.tap(find.byType(StatusStrip));
      await tester.pumpAndSettle();
      expect(find.text(reason), findsOneWidget);
    });

    testWidgets('a session another device took over offers Take over, which attaches again', (tester) async {
      final session = FakeAgentSession()..evict();
      await pumpScreen(tester, session);
      expect(strip('Taken over'), findsOneWidget);
      expect(strip('Opened on another device.'), findsOneWidget);
      expect(composerField(tester).enabled, isFalse);

      await tester.tap(find.text('Take over'));
      await tester.pump();
      expect(session.reattachCount, 1);
      expect(find.byType(StatusStrip), findsNothing);
      expect(composerField(tester).enabled, isTrue);
    });

    testWidgets('a failed attach offers Retry; an ended session offers nothing', (tester) async {
      final session = FakeAgentSession(link: AgentLink.failed, error: 'No route to host');
      await pumpScreen(tester, session);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(session.reattachCount, 1);

      session.setLink(AgentLink.ended, error: 'Agent exited');
      await tester.pump();
      expect(find.text('Take over'), findsNothing);
      expect(find.text('Retry'), findsNothing);
    });
  });

  group('seen', () {
    testWidgets('marks the session seen on open, and again when a turn ends while it is open', (tester) async {
      final session = FakeAgentSession(unseenDone: true);
      await pumpScreen(tester, session);
      expect(session.markSeenCount, greaterThanOrEqualTo(1));
      expect(session.unseenDone, isFalse);

      final before = session.markSeenCount;
      session.setUnseenDone(true);
      await tester.pump();
      expect(session.markSeenCount, before + 1);
      expect(session.unseenDone, isFalse);
    });
  });

  group('bar and options', () {
    testWidgets('shows title over agent · machine · folder and the phase glyph', (tester) async {
      await pumpScreen(tester, FakeAgentSession(title: 'Fix payments'));
      expect(find.text('Fix payments'), findsOneWidget);
      expect(find.text('Claude Code · devbox · payments-api'), findsOneWidget);
      expect(find.byTooltip('Session options'), findsOneWidget, reason: 'Duplicate lives there, whatever the agent exposes');
    });

    testWidgets('picking a choice from a long list searches lazily and sets the option', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(
          options: [
            SelectConfigOption(
              id: 'model',
              name: 'Model',
              category: 'model',
              value: 'm5',
              choices: [for (var i = 0; i < 781; i++) ConfigChoice(value: 'm$i', name: 'Model $i')],
            ),
            const SelectConfigOption(
              id: 'mode',
              name: 'Approval mode',
              category: 'mode',
              value: 'ask',
              choices: [ConfigChoice(value: 'ask', name: 'Ask'), ConfigChoice(value: 'auto', name: 'Auto')],
            ),
            const BooleanConfigOption(id: 'fast', name: 'Fast mode', value: false),
          ],
        ),
      );
      await pumpScreen(tester, session);
      await tester.tap(find.byTooltip('Session options'));
      await tester.pumpAndSettle();
      // The chips above the composer say the same (they are the quick way in):
      // the sheet's own rows are what this test is about.
      final sheet = find.byType(BottomSheet);
      expect(find.descendant(of: sheet, matching: find.text('Model 5')), findsOneWidget, reason: 'the current value is on the row');
      expect(find.descendant(of: sheet, matching: find.text('Ask')), findsOneWidget);

      await tester.tap(find.descendant(of: sheet, matching: find.text('Fast mode')));
      await tester.pump();
      expect(session.configs, [('fast', true)]);

      await tester.tap(find.text('Model'));
      await tester.pumpAndSettle();
      expect(find.text('Model 700'), findsNothing, reason: 'rows are built lazily');
      await tester.enterText(find.byType(TextField).last, 'Model 700');
      await tester.pump();
      final row = find.descendant(of: find.byType(ListView), matching: find.text('Model 700'));
      expect(row, findsOneWidget);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(session.configs.last, ('model', 'm700'));
      expect(find.text('Approval mode'), findsNothing, reason: 'the sheet closed');
    });

    testWidgets('modes without a mode option are offered as one choice list', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(
          modes: const ModeState(
            currentModeId: 'plan',
            availableModes: [SessionMode(id: 'plan', name: 'Plan'), SessionMode(id: 'code', name: 'Code')],
          ),
        ),
      );
      await pumpScreen(tester, session);
      await tester.tap(find.byTooltip('Session options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mode'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Code'));
      await tester.pumpAndSettle();
      expect(session.modes, ['code']);
    });
  });

  group('diff', () {
    test('marks changed lines and folds long unchanged runs', () {
      final old = List.generate(20, (i) => 'line $i').join('\n');
      final changed = old.replaceFirst('line 10', 'LINE 10');
      final lines = diffLines(old, changed);
      expect([for (final l in lines) l.kind], [
        DiffKind.gap,
        DiffKind.same,
        DiffKind.same,
        DiffKind.del,
        DiffKind.add,
        DiffKind.same,
        DiffKind.same,
        DiffKind.gap,
      ]);
      expect(lines.first.text, '8 unchanged lines');
      expect(lines.last.text, '7 unchanged lines');
    });

    test('a new file is all additions, an identical file is one gap', () {
      expect(diffLines(null, 'a\nb\n').map((l) => l.kind), [DiffKind.add, DiffKind.add]);
      expect(diffLines('same\nfile', 'same\nfile').map((l) => l.kind), [DiffKind.gap]);
    });

    test('past the table limit the middle is shown as removed then added; under it the common lines are found', () {
      final a = [for (var i = 0; i < 30; i++) 'a$i', 'same', 'z'].join('\n');
      final b = [for (var i = 0; i < 30; i++) 'b$i', 'same', 'z'].join('\n');
      // Head and tail are cut first; the middle (30 x 30) is under the limit.
      final found = diffLines(a, b);
      expect(found.where((l) => l.kind == DiffKind.same && l.text == 'same'), hasLength(1));

      // Over the limit: no table is built, nothing is lost.
      final coarse = diffLines('${a}x', '${b}y', maxCells: 100);
      expect(coarse.where((l) => l.kind == DiffKind.del), hasLength(32));
      expect(coarse.where((l) => l.kind == DiffKind.add), hasLength(32));
      expect(coarse.where((l) => l.kind == DiffKind.same), isEmpty);

      final huge = diffLines(List.generate(20000, (i) => 'a$i').join('\n'), List.generate(20000, (i) => 'b$i').join('\n'));
      expect(huge.where((l) => l.kind == DiffKind.del), hasLength(20000));
      expect(huge.where((l) => l.kind == DiffKind.add), hasLength(20000));
    });

    test('a change in the middle keeps its neighbours and folds the rest', () {
      final lines = diffLines('a\nb\nc\nd\ne\nf\ng', 'a\nb\nX\nd\ne\nf\ng', context: 1);
      expect([for (final l in lines) (l.kind, l.text)], [
        (DiffKind.same, 'a'),
        (DiffKind.same, 'b'),
        (DiffKind.del, 'c'),
        (DiffKind.add, 'X'),
        (DiffKind.same, 'd'),
        (DiffKind.gap, '3 unchanged lines'),
      ]);
    });
  });

  group('worst case', () {
    testWidgets('300 messages in Vietnamese: a screenful is built, then only what scrolls into view', (tester) async {
      final built = <String>{};
      debugRowBuilt = built.add;
      final session = FakeAgentSession(
        state: stateWith(
          items: [
            for (var i = 0; i < 300; i++)
              if (i % 3 == 0)
                userMsg('u$i', 'Sửa lỗi hiển thị “Tiếng Việt” số $i')
              else if (i % 3 == 1)
                agentMsg('a$i', '## Kết quả $i\n\nĐã cập nhật **tệp** `vi-VN.json` ở thư mục Hà Nội.')
              else
                toolItem('t$i', title: 'Đọc tệp số $i', kind: ToolKind.read),
          ],
          turnActive: true,
        ),
      );
      await pumpScreen(tester, session, size: const Size(320, 640));
      expect(built.length, lessThan(80), reason: 'rows built for the first screen: ${built.length}');
      expect(find.text('Đọc tệp số 299'), findsOneWidget, reason: 'it starts at the end');
      final atEnd = transcriptPosition(tester).pixels;

      for (var i = 0; i < 5; i++) {
        await tester.fling(find.byType(TranscriptView), const Offset(0, 600), 3000);
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(transcriptPosition(tester).pixels, lessThan(atEnd), reason: 'it scrolled back');
      expect(built.length, lessThan(400), reason: 'five flings must not build the whole transcript');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a huge new file as a diff stays inside a bounded box', (tester) async {
      final big = List.generate(30000, (i) => 'line $i').join('\n');
      final session = FakeAgentSession(
        state: stateWith(
          items: [
            toolItem('t1', title: 'Write big.txt', kind: ToolKind.edit, content: [ToolDiff(path: 'big.txt', newText: big)]),
          ],
          turnActive: true,
        ),
      );
      await pumpScreen(tester, session);
      await tester.tap(find.text('big.txt'));
      await tester.pump();
      expect(find.text('+ line 0'), findsOneWidget);
      expect(find.text('+ line 100'), findsNothing);
      expect(find.text('29940 more lines'), findsOneWidget);
      await tester.ensureVisible(find.text('Show all'));
      await tester.pump();
      await tester.tap(find.text('Show all'));
      await tester.pump();
      expect(find.text('+ line 29999'), findsNothing, reason: 'rows past the box are not built');
      expect(find.text('+ line 0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('320 dp at twice the text size keeps everything inside the screen', (tester) async {
      final session = FakeAgentSession(
        title: 'Một tiêu đề rất dài cho phiên làm việc này, dài hơn màn hình rất nhiều',
        state: stateWith(
          items: [
            userMsg('u', 'Kiểm tra “Hà Nội” và Đà Nẵng'),
            toolItem('t1', title: 'Run ${'a-very-long-command-name ' * 8}', kind: ToolKind.execute, status: ToolStatus.failed),
            agentMsg('a1', '## Tiêu đề\n\nMột đoạn văn dài ${'từ ' * 60}\n\n```\n${'x' * 300}\n```'),
          ],
          plan: [for (var i = 0; i < 4; i++) PlanEntry(content: 'Một bước dài ${'chữ ' * 15}$i')],
          commands: [AcpCommand(name: 'compact', description: 'Một mô tả rất dài ${'chữ ' * 20}', inputHint: 'gợi ý')],
        ),
      );
      await pumpScreen(tester, session, size: const Size(320, 640), textScale: 2);
      expect(tester.takeException(), isNull);
      expect(transcriptPosition(tester).extentAfter, 0, reason: 'still at the end');
      expect(tester.getRect(find.byType(TextField)).right, lessThanOrEqualTo(320));
      expect(tester.getRect(find.byType(TextField)).bottom, lessThanOrEqualTo(640));

      await tester.enterText(find.byType(TextField), '/');
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('/compact', findRichText: true), findsOneWidget);
      expect(tester.getRect(find.byType(TextField)).bottom, lessThanOrEqualTo(640));

      session.setLink(AgentLink.failed, error: 'x' * 300);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Retry'), findsOneWidget);
      expect(tester.getRect(find.text('Retry')).right, lessThanOrEqualTo(320));
      expect(tester.getRect(find.byType(TextField)).bottom, lessThanOrEqualTo(640));
    });
  });

  group('layout', () {
    testWidgets('the screen holds the session while it is open, and gives it back', (tester) async {
      final session = FakeAgentSession();
      await pumpScreen(tester, session);
      expect(session.acquired, 1);
      expect(session.holds, 1);

      await tester.pumpWidget(const SizedBox());
      expect(session.released, 1);
      expect(session.holds, 0);
    });

    testWidgets('a short window keeps the composer in reach with the plan open and with the keyboard up', (tester) async {
      final plan = [for (var i = 0; i < 7; i++) PlanEntry(content: 'Step $i', status: PlanStatus.pending)];
      final session = FakeAgentSession(
        state: stateWith(
          plan: plan,
          items: [for (var i = 0; i < 20; i++) agentMsg('a$i', 'message $i')],
        ),
      );
      await pumpScreen(tester, session, size: const Size(640, 300));
      await tester.tap(find.textContaining('Plan', findRichText: true));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.byType(TextField)).bottom, lessThanOrEqualTo(300));
      final planHeight = tester.getSize(find.byType(PlanHeader)).height;
      expect(planHeight, greaterThan(0));
      expect(planHeight, lessThan(300 * 0.75), reason: 'the plan leaves the transcript a quarter of the room');

      // The keyboard takes half the window: the plan gives way, the composer stays.
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.byType(TextField)).bottom, lessThanOrEqualTo(150));
      expect(tester.getSize(find.byType(PlanHeader)).height, 0);
    });

    testWidgets('a link in the agent\'s text shows its whole address before anything opens', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(items: [agentMsg('a1', '[github.com/x](https://evil.tld/p?q=1)')]),
      );
      await pumpScreen(tester, session);
      expect(find.textContaining('evil.tld'), findsNothing, reason: 'the label says github.com/x');
      // The link is the start of a full-width row: tap its first letters.
      await tester.tapAt(tester.getTopLeft(find.textContaining('github.com/x', findRichText: true)) + const Offset(12, 10));
      await tester.pumpAndSettle();
      expect(find.textContaining('https://evil.tld/p?q=1'), findsWidgets);
      expect(find.text('Copy link'), findsOneWidget);
    });

    testWidgets('a plain http link is also shown first, not opened', (tester) async {
      final session = FakeAgentSession(state: stateWith(items: [agentMsg('a1', '[docs](http://plain.tld/a)')]));
      await pumpScreen(tester, session);
      // The link is the start of a full-width row: tap its first letters.
      await tester.tapAt(tester.getTopLeft(find.textContaining('docs', findRichText: true)) + const Offset(12, 10));
      await tester.pumpAndSettle();
      expect(find.textContaining('http://plain.tld/a'), findsWidgets);
    });

    testWidgets('hidden characters in a tool title are shown as escapes', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(items: [toolItem('t1', title: 'Read\u202E txt.exe', kind: ToolKind.read)], turnActive: true),
      );
      await pumpScreen(tester, session);
      expect(find.text('Read\u2039U+202E\u203a txt.exe'), findsOneWidget);
    });
  });

  group('navigation', () {
    Future<BuildContext> pumpHost(WidgetTester tester, FakeAgentSessions sessions) async {
      late BuildContext host;
      await tester.pumpWidget(
        ListenableProvider<AgentSessions>.value(
          value: sessions,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  host = context;
                  return const Text('board');
                },
              ),
            ),
          ),
        ),
      );
      return host;
    }

    testWidgets('pushes the screen for a known key', (tester) async {
      final session = FakeAgentSession(title: 'Known one');
      final context = await pumpHost(tester, FakeAgentSessions([session]));
      unawaited(openAgent(context, const SessionAgent('m/k1')));
      await tester.pumpAndSettle();
      expect(find.byType(AgentSessionScreen), findsOneWidget);
      expect(find.text('Known one'), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('board'), findsOneWidget);
    });

    testWidgets('an unknown key toasts and opens nothing', (tester) async {
      final context = await pumpHost(tester, FakeAgentSessions([FakeAgentSession()]));
      unawaited(openAgent(context, const SessionAgent('m/gone')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AgentSessionScreen), findsNothing);
      expect(find.text('That session is no longer available.'), findsOneWidget);
    });

    testWidgets('replace takes the place of the route underneath', (tester) async {
      final session = FakeAgentSession(title: 'Replacing');
      final context = await pumpHost(tester, FakeAgentSessions([session]));
      unawaited(openAgent(context, const SessionAgent('m/k1'), replace: true));
      await tester.pumpAndSettle();
      expect(find.byType(AgentSessionScreen), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      // The screen took the place of the route that opened it: back has nowhere to go.
      expect(find.byType(AgentSessionScreen), findsOneWidget);
      expect(find.text('board'), findsNothing);
    });
  });
}
