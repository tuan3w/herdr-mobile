// The pane's chrome: one slim bar in portrait, and the answers to a blocked
// agent's question docked above the key row.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/pane_preview.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/ui/core/tap_guard.dart';
import 'package:herdr_mobile/ui/core/terminal_view.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agents/agent_navigation.dart';
import 'package:herdr_mobile/ui/features/agents/reply_chips.dart';
import 'package:herdr_mobile/ui/features/agents/reply_sheet.dart';
import 'package:herdr_mobile/ui/features/pane/answer_dock.dart';
import 'package:herdr_mobile/ui/features/pane/pane_bar.dart';
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:herdr_mobile/ui/features/pane/quick_keys.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'board_support.dart';
import 'hold_support.dart';
import 'ui_harness.dart';
import '../support/shot.dart' show loadAppFonts;

const _machine = 'm1';

String _id(int i) => 'w1:p$i';

/// `machine/pane`, as the previews and the app key a pane.
String _key(int i) => '$_machine/${_id(i)}';

Pane _pane(int i, String status) =>
    (id: _id(i), ws: 'w1', agent: 'claude', status: status);

String _title(String id) => 'task ${id.split('p').last}';

Map<String, dynamic> _snapshot(List<Pane> panes) =>
    snapshotWith(panes, title: _title);

QuickReply _reply(String label) =>
    QuickReply(label: label, keys: [label.substring(0, 1), 'enter']);

PromptInfo _prompt({
  String question = 'Do you want to run this command?',
  String subject = '',
  List<String> options = const ['1. Yes', '2. No'],
}) =>
    PromptInfo(question: question, subject: subject, replies: [for (final o in options) _reply(o)]);

/// A fleet of one machine with [statuses] as its panes' states (pane 1, 2…).
Future<BoardHarness> _harness(List<String> statuses) async {
  final h = await BoardHarness.create([
    (
      profile: MachineProfile(
        id: _machine,
        label: 'box',
        host: 'h',
        username: 'u',
      ),
      snapshot: _snapshot([
        for (final (i, s) in statuses.indexed) _pane(i + 1, s),
      ]),
    ),
  ]);
  h.transports[_machine]!.paneText = 'hello from the pane';
  return h;
}

/// Pane 1, the one every test shows.
final _agent = PaneAgent(_machine, _id(1));

/// Shows pane 1's screen. [fromBoard]: a screen under it, opened from there,
/// so Back leads somewhere.
Future<void> _pump(
  WidgetTester tester,
  BoardHarness h, {
  Size size = const Size(412, 892),
  bool fromBoard = false,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: h.providers,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: fromBoard
            ? Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => openAgent(context, _agent, view: AgentView.terminal),
                    child: const Text('board'),
                  ),
                ),
              )
            : PaneScreen(agent: _agent),
      ),
    ),
  );
  if (fromBoard) {
    await tester.tap(find.text('board'));
  }
  await settle(tester);
  // Past the dock's guard, which starts when its question first shows.
  await tester.pump(tapGuard);
}

Future<void> _tearDown(WidgetTester tester, BoardHarness h) async {
  await tester.pumpWidget(const SizedBox());
  h.dispose();
}

Finder _barText(String text) =>
    find.descendant(of: find.byType(PaneTopBar), matching: find.text(text));

/// `pane.send_keys` the machine received, as `a+b`.
List<String> _keysSent(BoardHarness h) => [
  for (final (method, params) in h.transports[_machine]!.calls)
    if (method == 'pane.send_keys') (params['keys']! as List).join('+'),
];

/// Moves the panes to [statuses] the way a snapshot change does.
Future<void> _setStatuses(
  WidgetTester tester,
  BoardHarness h,
  List<String> statuses,
) async {
  await h.changeStatuses(tester, _machine, [
    for (final (i, s) in statuses.indexed) _pane(i + 1, s),
  ], title: _title);
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUpAll(loadAppFonts);

  group('the bar', () {
    testWidgets(
      'is one 56dp bar that names the pane once and shows no pane id',
      (tester) async {
        final h = await _harness(['idle']);
        await _pump(tester, h);

        expect(find.byType(PaneTopBar), findsOneWidget);
        expect(tester.getSize(find.byType(PaneTopBar)).height, 56);
        expect(find.text('task 1'), findsOneWidget, reason: 'the title is on screen once');
        expect(_barText('claude · box'), findsOneWidget);
        expect(find.textContaining(_id(1)), findsNothing);
        await _tearDown(tester, h);
      },
    );

    testWidgets('the terminal starts at least 40dp higher than under the old '
        'bar and strip (60dp bar + 44dp strip)', (tester) async {
      final h = await _harness(['idle']);
      await _pump(tester, h);

      const oldTop = 60.0 + 44.0;
      final top = tester.getTopLeft(find.byType(TerminalView)).dy;
      expect(top, lessThanOrEqualTo(oldTop - 40 + 4), reason: '4dp of padding above the panel');
      await _tearDown(tester, h);
    });

    testWidgets('the options button opens the pane\'s actions, with the pane id '
        'they alone show', (tester) async {
      final h = await _harness(['idle']);
      await _pump(tester, h);
      expect(find.text('Duplicate'), findsNothing);

      await tester.tap(find.byTooltip('Pane options'));
      await settle(tester);

      expect(find.text('Duplicate'), findsOneWidget);
      expect(find.text('Copy pane id ${_id(1)}'), findsOneWidget);
      await _tearDown(tester, h);
    });

    testWidgets('a short screen gets a 52dp bar and keeps its buttons', (
      tester,
    ) async {
      final h = await _harness(['idle']);
      await _pump(tester, h, size: const Size(740, 360));

      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(PaneTopBar)).height, 52);
      expect(find.byTooltip('Back'), findsOneWidget);
      expect(find.byTooltip('Wrap lines to screen'), findsOneWidget);
      await _tearDown(tester, h);
    });
  });

  group('docked answers', () {
    Finder dockText(String text) =>
        find.descendant(of: find.byType(AnswerDock), matching: find.text(text));

    testWidgets('a blocked pane with an understood prompt shows the question '
        'and its chips directly above the key row', (tester) async {
      final h = await _harness(['blocked']);
      h.previews.set(_key(1), ['Do you want to run this command?'], prompt: _prompt());
      await _pump(tester, h);

      expect(dockText('Do you want to run this command?'), findsOneWidget);
      expect(dockText('1. Yes'), findsOneWidget);
      expect(dockText('2. No'), findsOneWidget);
      final dock = tester.getRect(find.byType(AnswerDock));
      final keys = tester.getRect(find.byType(QuickKeys));
      expect(dock.bottom, lessThanOrEqualTo(keys.top));
      expect(keys.top - dock.bottom, lessThan(12), reason: 'directly above');
      expect(
        tester.getSize(find.byType(ReplyChips)).height,
        ReplyChips.heightFor(2),
      );
      await _tearDown(tester, h);
    });

    testWidgets('a risky answer in the dock is held to send; a tap only says how', (tester) async {
      final h = await _harness(['blocked']);
      h.previews.set(
        _key(1),
        ['q'],
        prompt: const PromptInfo(
          question: 'Do you want to run this command?',
          subject: 'git push origin main',
          replies: [
            QuickReply(label: '1. Yes', keys: ['1', 'enter'], needsConfirm: true, risk: 'pushes to a remote'),
            QuickReply(label: '2. No', keys: ['2', 'enter']),
          ],
        ),
      );
      await _pump(tester, h);

      await quickTap(tester, dockText('1. Yes'));
      expect(dockText('Hold to send · pushes to a remote'), findsOneWidget);
      expect(_keysSent(h), isEmpty);

      await holdFor(tester, dockText('Hold to send · pushes to a remote'));
      expect(_keysSent(h), ['1+enter']);
      await tester.pump(const Duration(seconds: 4));
      await _tearDown(tester, h);
    });

    testWidgets('the command the answer approves sits in the dock, above the chips', (tester) async {
      final h = await _harness(['blocked']);
      const command = 'git push origin main\nPush to remote';
      h.previews.set(_key(1), ['q'], prompt: _prompt(subject: command));
      await _pump(tester, h);

      final subject = find.descendant(of: find.byType(AnswerDock), matching: find.text(command));
      expect(subject, findsOneWidget);
      final question = tester.getRect(dockText('Do you want to run this command?'));
      final shown = tester.getRect(subject);
      final chips = tester.getRect(find.byType(ReplyChips));
      expect(question.bottom, lessThanOrEqualTo(shown.top), reason: 'question, then the command');
      expect(shown.bottom, lessThan(chips.top), reason: 'and the command, then the chips');
      final text = tester.widget<Text>(subject);
      expect(text.maxLines, 2);
      expect(text.style?.fontFamily, monoFamily, reason: 'a command is read in mono');
      await _tearDown(tester, h);
    });

    testWidgets('a tap on a chip sends its keys to that pane', (tester) async {
      final h = await _harness(['blocked']);
      h.previews.set(_key(1), ['Do you want to run this command?'], prompt: _prompt());
      await _pump(tester, h);
      expect(_keysSent(h), isEmpty);

      await tester.tap(dockText('1. Yes'));
      await settle(tester);

      expect(_keysSent(h), ['1+enter']);
      final sent = h.transports[_machine]!.calls
          .where((c) => c.$1 == 'pane.send_keys')
          .single;
      expect(sent.$2['pane_id'], _id(1));
      expect(dockText('Sent: 1. Yes'), findsOneWidget);

      // Only one answer goes out while "Sent" shows.
      await tester.tap(dockText('Sent: 1. Yes'), warnIfMissed: false);
      await settle(tester);
      expect(_keysSent(h), ['1+enter']);
      await _tearDown(tester, h);
    });

    testWidgets('answers that just came up under the thumb take no tap until the '
        'guard is over, and a new question starts it again', (tester) async {
      final h = await _harness(['blocked']);
      h.previews.set(_key(1), ['the agent is thinking']);
      await _pump(tester, h);

      // The question arrives while the thumb is at the key row.
      h.previews.set(_key(1), ['q'], prompt: _prompt());
      await tester.pump();
      await tester.tap(dockText('1. Yes'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_keysSent(h), isEmpty, reason: 'a tap on a dock that just appeared');

      await tester.pump(tapGuard);
      await tester.tap(dockText('1. Yes'));
      await settle(tester);
      expect(_keysSent(h), ['1+enter']);
      expect(dockText('Sent: 1. Yes'), findsOneWidget);

      // The agent asks again in the same pane: new answers, under the same thumb.
      h.previews.set(
        _key(1),
        ['q2'],
        prompt: _prompt(question: 'Overwrite lib/main.dart?', options: ['1. Overwrite', '2. Skip']),
      );
      await tester.pump();
      await tester.tap(dockText('2. Skip'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_keysSent(h), ['1+enter'], reason: 'a tap on a question that just changed');

      await tester.pump(tapGuard);
      await tester.tap(dockText('2. Skip'));
      await settle(tester);
      expect(_keysSent(h), ['1+enter', '2+enter']);
      await tester.pump(const Duration(seconds: 4));
      await _tearDown(tester, h);
    });

    testWidgets('while the dock asks, Enter on the key row or an empty send '
        'answers nothing; once the agent moves on, Enter presses enter', (tester) async {
      final h = await _harness(['blocked']);
      h.previews.set(_key(1), ['q'], prompt: _prompt());
      await _pump(tester, h);
      final enter = find.descendant(
        of: find.byType(QuickKeys),
        matching: find.byIcon(LucideIcons.cornerDownLeft),
      );

      await tester.tap(enter);
      await settle(tester);
      await tester.showKeyboard(find.byType(TextField));
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await settle(tester);
      expect(_keysSent(h), isEmpty, reason: 'Enter would pick the highlighted option');

      await _setStatuses(tester, h, ['working']);
      await tester.tap(enter);
      await settle(tester);
      expect(_keysSent(h), ['enter']);
      await tester.pump(const Duration(seconds: 4));
      await _tearDown(tester, h);
    });

    testWidgets('goes when the prompt goes, and comes back with the next one', (
      tester,
    ) async {
      final h = await _harness(['blocked']);
      h.previews.set(_key(1), ['q'], prompt: _prompt());
      await _pump(tester, h);
      expect(dockText('1. Yes'), findsOneWidget);

      h.previews.set(_key(1), ['the agent is thinking']);
      await tester.pump();
      expect(find.byType(ReplyChips), findsNothing);
      expect(tester.getSize(find.byType(AnswerDock)), Size.zero);

      h.previews.set(
        _key(1),
        ['q2'],
        prompt: _prompt(question: 'Overwrite lib/main.dart?', options: ['1. Overwrite', '2. Skip']),
      );
      await tester.pump();
      expect(dockText('Overwrite lib/main.dart?'), findsOneWidget);
      expect(dockText('2. Skip'), findsOneWidget);
      await _tearDown(tester, h);
    });

    testWidgets('a pane that is not blocked has no dock and reads nothing for it', (
      tester,
    ) async {
      final h = await _harness(['working']);
      h.previews.set(_key(1), ['q'], prompt: _prompt());
      await _pump(tester, h);

      expect(find.byType(ReplyChips), findsNothing);
      expect(tester.getSize(find.byType(AnswerDock)), Size.zero);
      expect(h.previews.opened, isEmpty);
      await _tearDown(tester, h);
    });

    testWidgets('a blocked pane whose prompt is not understood has none either', (
      tester,
    ) async {
      final h = await _harness(['blocked']);
      h.previews.set(_key(1), ['some free text']);
      await _pump(tester, h);

      expect(find.byType(ReplyChips), findsNothing);
      expect(h.previews.open[_key(1)], 1, reason: 'it did look');
      await _tearDown(tester, h);
    });

    testWidgets('follows the pane: watched while blocked, released once it is not', (
      tester,
    ) async {
      final h = await _harness(['working']);
      h.previews.set(_key(1), ['q'], prompt: _prompt());
      await _pump(tester, h);
      expect(h.previews.openCount, 0);

      await _setStatuses(tester, h, ['blocked']);
      expect(h.previews.open[_key(1)], 1);
      expect(dockText('1. Yes'), findsOneWidget);

      // The prompt still sits in the preview, but the agent moved on: gone at
      // once, without waiting for a new read.
      await _setStatuses(tester, h, ['working']);
      expect(find.byType(ReplyChips), findsNothing);
      expect(h.previews.open[_key(1)], 0);
      await _tearDown(tester, h);
    });

    testWidgets('leaving the pane releases its watch', (tester) async {
      final h = await _harness(['blocked']);
      h.previews.set(_key(1), ['q'], prompt: _prompt());
      await _pump(tester, h, fromBoard: true);
      expect(dockText('1. Yes'), findsOneWidget);
      expect(h.previews.open[_key(1)], 1);

      await tester.tap(find.byTooltip('Back'));
      await settle(tester);

      expect(find.byType(PaneScreen), findsNothing);
      expect(h.previews.openCount, 0);
      await _tearDown(tester, h);
    });

    testWidgets('shows three answers and a "more" chip that opens the reply sheet', (
      tester,
    ) async {
      final h = await _harness(['blocked']);
      h.previews.set(
        _key(1),
        ['q'],
        prompt: _prompt(options: ['1. One', '2. Two', '3. Three', '4. Four', '5. Five', '6. Six']),
      );
      await _pump(tester, h);

      expect(dockText('1. One'), findsOneWidget);
      expect(dockText('2. Two'), findsOneWidget);
      expect(dockText('3. Three'), findsOneWidget);
      expect(dockText('4. Four'), findsNothing);
      expect(dockText('3 more…'), findsOneWidget);
      expect(
        tester.getSize(find.byType(ReplyChips)).height,
        ReplyChips.heightFor(dockChipLimit),
      );

      await tester.tap(dockText('3 more…'));
      await settle(tester);
      expect(find.byType(ReplySheet), findsOneWidget);
      expect(_keysSent(h), isEmpty, reason: '"more" answers nothing');
      await _tearDown(tester, h);
    });

    testWidgets('a long question keeps to two lines', (tester) async {
      final h = await _harness(['blocked']);
      final long = List.filled(30, 'Allow the agent to edit this file').join(' ');
      h.previews.set(_key(1), ['q'], prompt: _prompt(question: long));
      await _pump(tester, h);

      final text = tester.widget<Text>(dockText(long));
      expect(text.maxLines, 2);
      expect(tester.takeException(), isNull);
      final lineHeight = tester.getSize(dockText(long)).height;
      expect(lineHeight, lessThan(2 * 14 * 1.35 + 1));
      await _tearDown(tester, h);
    });

    testWidgets('is hidden when the layout is compact (landscape with the '
        'keyboard), and on a short screen, where it would eat the terminal', (
      tester,
    ) async {
      final h = await _harness(['blocked']);
      h.previews.set(_key(1), ['q'], prompt: _prompt());
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      addTearDown(tester.view.reset);
      await _pump(tester, h, size: const Size(740, 360));

      expect(find.byType(AnswerDock), findsNothing);
      expect(find.byType(ReplyChips), findsNothing);
      expect(h.previews.opened, isEmpty, reason: 'and nothing watches for it');

      // The keyboard goes: landscape is not compact, but still short.
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      await settle(tester);
      expect(find.text('1. Yes'), findsNothing);
      expect(tester.takeException(), isNull);

      tester.view.physicalSize = const Size(412, 892);
      await tester.pump();
      await settle(tester);

      expect(find.text('1. Yes'), findsOneWidget, reason: 'back in portrait, it is there');
      await _tearDown(tester, h);
    });

    testWidgets('a keyboard moving takes the terminal\'s height one for one, and '
        'rebuilds neither the dock nor the terminal', (tester) async {
      final h = await _harness(['blocked']);
      h.previews.set(_key(1), ['q'], prompt: _prompt());
      await _pump(tester, h);
      final dockBefore = tester.getSize(find.byType(AnswerDock));
      final terminalBefore = tester.getSize(find.byType(TerminalView));
      final chipsBefore = tester.getSize(find.byType(ReplyChips));

      final rebuilt = <String>[];
      var keyedRebuilds = 0;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        rebuilt.add(element.widget.runtimeType.toString());
        if (builtOnce && element.widget is KeyedSubtree) keyedRebuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);

      // The keyboard opens over ten frames.
      for (var i = 1; i <= 10; i++) {
        tester.view.viewInsets = FakeViewPadding(bottom: 30.0 * i);
        await tester.pump();
      }

      final terminal = tester.getSize(find.byType(TerminalView));
      expect(terminal.width, terminalBefore.width);
      expect(terminal.height, terminalBefore.height - 300);
      expect(tester.getSize(find.byType(AnswerDock)), dockBefore);
      expect(tester.getSize(find.byType(ReplyChips)), chipsBefore);
      expect(
        rebuilt.where({'AnswerDock', '_Dock', 'ReplyChips', '_PaneView', '_TerminalPanel'}.contains),
        isEmpty,
      );
      expect(keyedRebuilds, 0, reason: 'no row of the terminal rebuilt');

      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      expect(tester.getSize(find.byType(TerminalView)), terminalBefore);
      await _tearDown(tester, h);
    });
  });
}
