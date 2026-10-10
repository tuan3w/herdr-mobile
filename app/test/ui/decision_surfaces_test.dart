// What a decision shows (evidence in the dock), the mode and model chips above
// the composer, danger that stays, and where the person left the session.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/last_seen.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/hold_confirm.dart';
import 'package:herdr_mobile/ui/core/tap_guard.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/danger_announce.dart';
import 'package:herdr_mobile/ui/features/agent_session/permission_evidence_view.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_bar.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_chips_row.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_view.dart';
import 'package:provider/provider.dart';

import '../decision/support/trace_session.dart' show MemoryLastSeenStore;
import '../support/fake_agent_session.dart';
import 'hold_support.dart';

Future<void> pumpScreen(
  WidgetTester tester,
  FakeAgentSession session, {
  Size size = const Size(412, 892),
  double textScale = 1,
  LastSeen? lastSeen,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  Widget app = MaterialApp(
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: AgentSessionScreen(key: ObjectKey(session), session: session),
  );
  if (lastSeen != null) app = Provider<LastSeen>.value(value: lastSeen, child: app);
  await tester.pumpWidget(app);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(tapGuard);
}

FakeAgentSession asking(PermissionRequest request, {List<TranscriptItem> items = const []}) =>
    FakeAgentSession(state: stateWith(items: items, turnActive: true, pending: [PendingPermission(7, request)]));

Map<String, Object?> diff(String path, String? before, String after) => {
  'type': 'diff',
  'path': path,
  'oldText': ?before,
  'newText': after,
};

const _approve = 'Approve and execute';

ElicitationRequest planQuestion(String message) => ElicitationRequest.parse({
  'mode': 'form',
  'message': message,
  'requestedSchema': {
    'type': 'object',
    'properties': {
      'value': {
        'type': 'string',
        'enum': [_approve, 'Refine plan'],
      },
    },
  },
});

SelectConfigOption modeOption(String value, {List<(String, String)>? choices}) => SelectConfigOption(
  id: 'mode',
  name: 'Mode',
  category: 'mode',
  value: value,
  choices: [for (final (id, name) in choices ?? const [('default', 'Default'), ('bypassPermissions', 'Bypass Permissions')]) ConfigChoice(value: id, name: name)],
);

const modelOption = SelectConfigOption(
  id: 'model',
  name: 'Model',
  category: 'model',
  value: 'sonnet',
  choices: [ConfigChoice(value: 'sonnet', name: 'Claude Sonnet'), ConfigChoice(value: 'opus', name: 'Claude Opus')],
);

const effortOption = SelectConfigOption(
  id: 'effort',
  name: 'Effort',
  category: 'thought_level',
  value: 'high',
  choices: [ConfigChoice(value: 'high', name: 'High'), ConfigChoice(value: 'low', name: 'Low')],
);

const fastOption = BooleanConfigOption(id: 'fast', name: 'Fast', value: false);

FakeAgentSession withOptions(List<ConfigOption> options, {AgentLink link = AgentLink.live}) =>
    FakeAgentSession(state: stateWith(options: options), link: link);

void main() {
  group('evidence in the dock', () {
    testWidgets('the agent\'s last sentence leads in above the command; none said, none shown', (tester) async {
      final request = permissionRequest(title: 'Bash', rawInput: {'command': 'flutter test'});
      await pumpScreen(
        tester,
        asking(request, items: [userMsg('u1', 'fix it'), agentMsg('a1', 'I will run the suite before I change anything.')]),
      );
      final said = find.text('\u201cI will run the suite before I change anything.\u201d');
      expect(said, findsOneWidget);
      expect(
        tester.getTopLeft(said).dy,
        lessThan(tester.getTopLeft(find.text('flutter test')).dy),
        reason: 'the lead-in is above the command',
      );
      expect(find.text('flutter test'), findsOneWidget, reason: 'the command stays');

      await pumpScreen(tester, asking(request));
      expect(find.textContaining('\u201c'), findsNothing, reason: 'absent data is absent UI');
    });

    testWidgets('an edit shows its diff with the counts, and the command box stays', (tester) async {
      final request = permissionRequest(
        title: 'Edit lib/a.dart',
        kind: ToolKind.edit,
        rawInput: {'file_path': 'lib/a.dart', 'old_string': 'b', 'new_string': 'c'},
        content: [diff('lib/a.dart', 'a\nb\nd\n', 'a\nc\nd\n')],
      );
      await pumpScreen(tester, asking(request));
      expect(find.text('lib/a.dart'), findsOneWidget, reason: 'the diff names its file once (the path list does not repeat it)');
      expect(find.text('+1 \u22121'), findsOneWidget);
      expect(find.text('+ c'), findsOneWidget);
      expect(find.text('- b'), findsOneWidget);
      expect(find.textContaining('file_path: lib/a.dart'), findsOneWidget, reason: 'the subject is shown as before');
      expect(find.text('Read all'), findsNothing, reason: 'it fits');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a long diff scrolls inside its box and Read all opens all of it', (tester) async {
      final before = [for (var i = 0; i < 120; i++) 'old $i'].join('\n');
      final after = [for (var i = 0; i < 120; i++) 'new $i'].join('\n');
      final request = permissionRequest(
        title: 'Edit big.txt',
        kind: ToolKind.edit,
        rawInput: {'file_path': 'big.txt'},
        content: [diff('big.txt', before, after)],
      );
      await pumpScreen(tester, asking(request), size: const Size(320, 640));
      expect(find.text('Read all'), findsOneWidget);
      expect(find.textContaining('More below'), findsOneWidget);
      expect(find.text('+ new 119'), findsNothing, reason: 'rows are built lazily');
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Read all'));
      await tester.pumpAndSettle();
      expect(find.text('Everything it will change'), findsOneWidget);
      await tester.dragUntilVisible(find.text('+ new 119'), find.byType(ListView).last, const Offset(0, -600));
      expect(find.text('+ new 119'), findsOneWidget);
    });

    testWidgets('a text that hides itself is shown, not obeyed, in the diff', (tester) async {
      final request = permissionRequest(
        title: 'Edit x',
        kind: ToolKind.edit,
        content: [diff('x.txt', 'a', 'run\u202E gpj.exe')],
      );
      await pumpScreen(tester, asking(request));
      expect(find.textContaining('\u2039U+202E\u203a'), findsWidgets);
      expect(find.textContaining('\u202E'), findsNothing);
    });

    testWidgets('a plan is read as Markdown, not as the mono copy of its field', (tester) async {
      final request = permissionRequest(
        title: 'Approve Plan',
        rawInput: {'plan': '# Add the flag\n\n1. Parse `--verbose`\n2. Test it'},
      );
      await pumpScreen(tester, asking(request));
      expect(find.text('Add the flag', findRichText: true), findsOneWidget);
      expect(find.textContaining('plan: #', findRichText: true), findsNothing);
      expect(find.text('Read all'), findsNothing, reason: 'a short plan fits');
    });

    testWidgets('what else the plan call carries still shows as the command box', (tester) async {
      final request = permissionRequest(
        title: 'Approve Plan',
        rawInput: {'plan': '# P', 'note': 'also runs the build'},
      );
      await pumpScreen(tester, asking(request));
      expect(find.textContaining('note: also runs the build'), findsOneWidget);
      expect(find.textContaining('plan: '), findsNothing);
    });

    testWidgets('a 400-line plan scrolls in its box, Read all opens it, and an allow takes one tap', (tester) async {
      final plan = [for (var i = 0; i < 200; i++) '## Step $i\n\nDo thing $i in `lib/f$i.dart`.'].join('\n\n');
      final request = permissionRequest(title: 'Approve Plan', rawInput: {'plan': plan});
      final session = asking(request);
      await pumpScreen(tester, session, size: const Size(412, 700));
      expect(find.text('Step 0', findRichText: true), findsOneWidget);
      expect(find.text('Step 150', findRichText: true), findsNothing, reason: 'the box is bounded and lazy');
      expect(find.text('Read all'), findsOneWidget);
      expect(find.textContaining('More below'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.drag(find.byType(EvidenceBox), const Offset(0, -400));
      await tester.pump();
      expect(find.text('Step 0', findRichText: true), findsNothing, reason: 'the box scrolled');

      await tester.tap(find.text('Read all'));
      await tester.pumpAndSettle();
      expect(find.text('The plan'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Allow once'));
      await tester.pump();
      expect(session.permissionAnswers, hasLength(1), reason: 'a plan is not a command: no read-it-all hold');
    });

    testWidgets('the hold rules for a command are unchanged next to evidence', (tester) async {
      final request = permissionRequest(
        title: 'Bash',
        rawInput: {'command': List.generate(40, (i) => 'echo line $i').join('\n')},
      );
      final session = asking(request, items: [agentMsg('a1', 'Running the long script.')]);
      await pumpScreen(tester, session);
      expect(find.textContaining('More below'), findsOneWidget);
      await holdFor(tester, find.text('Allow once'));
      expect(session.permissionAnswers, isEmpty, reason: 'the first hold on an unread long command only reads');
      expect(find.text('Hold or tap again · long command, read it all'), findsOneWidget);
      await holdFor(tester, find.text('Hold or tap again · long command, read it all'));
      expect(session.permissionAnswers, hasLength(1), reason: 'the next one sends');
    });

    testWidgets('omp\'s plan question shows the plan as Markdown and says it is the first 12 lines', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(
          turnActive: true,
          items: [agentMsg('a1', 'The plan is ready.')],
          pending: [
            PendingQuestion(
              9,
              planQuestion('Approve plan "Add flag" and start implementation?\n\n# Plan\n\n1. Add the flag\n2. Test it\n\u2026'),
            ),
          ],
        ),
      );
      await pumpScreen(tester, session);
      expect(find.text('Approve plan "Add flag" and start implementation?'), findsOneWidget);
      expect(find.text('Plan', findRichText: true), findsOneWidget);
      expect(find.textContaining('# Plan', findRichText: true), findsNothing);
      expect(find.text(planPreviewNote), findsOneWidget);
      expect(find.text('\u201cThe plan is ready.\u201d'), findsOneWidget, reason: 'the agent\'s sentence leads in');
      expect(find.text(_approve), findsOneWidget, reason: 'the answers stay');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a long omp plan preview scrolls and Read all opens it', (tester) async {
      final body = [for (var i = 0; i < 12; i++) '$i. Do the step number $i of the plan'].join('\n');
      final session = FakeAgentSession(
        state: stateWith(
          turnActive: true,
          pending: [PendingQuestion(9, planQuestion('Approve plan "x" and start implementation?\n\n$body\n\u2026'))],
        ),
      );
      await pumpScreen(tester, session, size: const Size(320, 640));
      expect(find.text(planPreviewNote), findsOneWidget);
      expect(find.text('Read all'), findsOneWidget);
      await tester.tap(find.text('Read all'));
      await tester.pumpAndSettle();
      expect(find.text('The plan'), findsOneWidget);
      expect(find.text(planPreviewNote), findsNWidgets(2), reason: 'the sheet says it too');
    });

    testWidgets('an ordinary question is untouched', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(
          turnActive: true,
          pending: [PendingQuestion(9, planQuestion('Pick one'))],
        ),
      );
      await pumpScreen(tester, session);
      expect(find.text('Pick one'), findsOneWidget);
      expect(find.byType(PlanEvidence), findsNothing);
    });
  });

  group('mode and model chips', () {
    testWidgets('one row: mode, model, effort, switches, and +N for the rest', (tester) async {
      final session = withOptions([
        modeOption('default'),
        modelOption,
        effortOption,
        fastOption,
        const BooleanConfigOption(id: 'web', name: 'Web search', value: true),
      ]);
      await pumpScreen(tester, session);
      for (final label in ['Default', 'Claude Sonnet', 'High', 'Fast']) {
        expect(find.widgetWithText(AppChip, label), findsOneWidget, reason: label);
      }
      expect(find.widgetWithText(AppChip, 'Web search'), findsNothing, reason: 'four chips, then +N');
      expect(find.widgetWithText(AppChip, '+1'), findsOneWidget);
      final tops = {for (final c in tester.widgetList<AppChip>(find.byType(AppChip))) tester.getTopLeft(find.byWidget(c)).dy};
      expect(tops, hasLength(1), reason: 'a single row');
    });

    testWidgets('a tap on the model opens the sheet on its choices; picking sets it', (tester) async {
      final session = withOptions([modeOption('default'), modelOption]);
      await pumpScreen(tester, session);
      await tester.tap(find.widgetWithText(AppChip, 'Claude Sonnet'));
      await tester.pumpAndSettle();
      expect(find.text('Claude Opus'), findsOneWidget, reason: 'the choices, not the list of settings');
      expect(find.text('Duplicate'), findsNothing);
      await tester.tap(find.text('Claude Opus'));
      await tester.pumpAndSettle();
      expect(session.configs, [('model', 'opus')]);
    });

    // Seen on a phone: a model changed from the chip, and the person had to
    // tap the field to write with it. A pick from the chip now always puts
    // them back in the field with the keyboard up, focused before or not.
    testWidgets('a pick from the chip puts the person in the message field, keyboard up', (tester) async {
      final session = withOptions([modeOption('default'), modelOption]);
      await pumpScreen(tester, session);
      final composer = tester.state<EditableTextState>(find.byType(EditableText).first).widget.focusNode;
      expect(composer.hasFocus, isFalse);

      await tester.tap(find.widgetWithText(AppChip, 'Claude Sonnet'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Claude Opus'));
      await tester.pumpAndSettle();
      expect(session.configs, [('model', 'opus')]);
      expect(composer.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
    });

    testWidgets('closing the sheet without a pick leaves the field as it was', (tester) async {
      final session = withOptions([modeOption('default'), modelOption]);
      await pumpScreen(tester, session);
      final composer = tester.state<EditableTextState>(find.byType(EditableText).first).widget.focusNode;

      await tester.tap(find.widgetWithText(AppChip, 'Claude Sonnet'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('Claude Opus'), findsNothing, reason: 'the sheet closed');
      expect(session.configs, isEmpty);
      expect(composer.hasFocus, isFalse);
    });

    testWidgets('after a pick found through the search the message field has the focus again', (tester) async {
      final session = withOptions([
        modeOption('default'),
        SelectConfigOption(
          id: 'model',
          name: 'Model',
          category: 'model',
          value: 'm0',
          choices: [for (var i = 0; i < 40; i++) ConfigChoice(value: 'm$i', name: 'Model $i')],
        ),
      ]);
      await pumpScreen(tester, session);
      final composer = tester.state<EditableTextState>(find.byType(EditableText).first).widget.focusNode;
      await tester.tap(find.byType(EditableText).first);
      await tester.pump();
      expect(composer.hasFocus, isTrue);

      await tester.tap(find.widgetWithText(AppChip, 'Model 0'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Search 40 choices'), findsOneWidget);
      await tester.tap(find.byType(EditableText).last);
      await tester.enterText(find.byType(EditableText).last, 'Model 33');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Model 33').last);
      await tester.pumpAndSettle();
      expect(session.configs, [('model', 'm33')]);
      expect(composer.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue, reason: 'the keyboard comes back with it');
    });

    testWidgets('a mode the agent lists only as modes opens the same picker', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(
          modes: const ModeState(
            currentModeId: 'plan',
            availableModes: [SessionMode(id: 'plan', name: 'Plan'), SessionMode(id: 'code', name: 'Code')],
          ),
        ),
      );
      await pumpScreen(tester, session);
      await tester.tap(find.widgetWithText(AppChip, 'Plan'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Code'));
      await tester.pumpAndSettle();
      expect(session.modes, ['code']);
    });

    testWidgets('a switch flips in place', (tester) async {
      final session = withOptions([modeOption('default'), fastOption]);
      await pumpScreen(tester, session);
      await tester.tap(find.widgetWithText(AppChip, 'Fast'));
      await tester.pump();
      expect(session.configs, [('fast', true)]);
    });

    testWidgets('+N opens the whole list of settings', (tester) async {
      final session = withOptions([
        modeOption('default'),
        modelOption,
        effortOption,
        fastOption,
        const BooleanConfigOption(id: 'web', name: 'Web search', value: true),
      ]);
      await pumpScreen(tester, session);
      await tester.tap(find.widgetWithText(AppChip, '+1'));
      await tester.pumpAndSettle();
      expect(find.text('Web search'), findsOneWidget);
      expect(find.text('Mode and model'), findsOneWidget);
    });

    testWidgets('nothing to show takes no room', (tester) async {
      await pumpScreen(tester, FakeAgentSession());
      expect(find.byType(SessionChipsRow), findsOneWidget);
      expect(find.byType(AppChip), findsNothing);
      expect(tester.getSize(find.byType(SessionChipsRow)).height, 0);
    });

    testWidgets('a session that is not live shows the chips and takes no tap on them', (tester) async {
      final session = withOptions([modeOption('default'), modelOption], link: AgentLink.ended);
      await pumpScreen(tester, session);
      expect(find.widgetWithText(AppChip, 'Claude Sonnet'), findsOneWidget);
      await tester.tap(find.widgetWithText(AppChip, 'Claude Sonnet'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Claude Opus'), findsNothing);
    });

    testWidgets('left out in the compact layout: landscape with the keyboard up', (tester) async {
      final session = withOptions([modeOption('default'), modelOption]);
      await pumpScreen(tester, session, size: const Size(892, 412));
      expect(find.byType(AppChip), findsWidgets, reason: 'landscape without a keyboard has room');
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(AppChip), findsNothing);
    });

    testWidgets('worst case: long names, Vietnamese, 1.6 text, 320 wide: no overflow', (tester) async {
      final session = withOptions([
        modeOption('x', choices: const [('x', 'Chế độ tự động phê duyệt mọi thay đổi trong thư mục làm việc')]),
        const SelectConfigOption(
          id: 'model',
          name: 'Model',
          category: 'model',
          value: 'm',
          choices: [ConfigChoice(value: 'm', name: 'Mô hình ngôn ngữ lớn thế hệ mới nhất của nhà cung cấp')],
        ),
        effortOption,
        fastOption,
        const BooleanConfigOption(id: 'web', name: 'Tìm kiếm trên web', value: true),
      ]);
      await pumpScreen(tester, session, size: const Size(320, 640), textScale: 1.6);
      expect(tester.takeException(), isNull);
      expect(find.byType(SessionChipsRow), findsOneWidget);
    });
  });

  group('danger stays', () {
    testWidgets('a dangerous mode is a chip in the danger tint with a triangle, and its words', (tester) async {
      final handle = tester.ensureSemantics();
      final session = withOptions([modeOption('bypassPermissions'), modelOption]);
      await pumpScreen(tester, session);
      final chip = tester.widget<AppChip>(find.widgetWithText(AppChip, 'Bypass Permissions'));
      final ds = AppTheme.light().extension<Ds>()!;
      expect(chip.tint, ds.dangerText);
      expect(chip.leading, isA<Icon>(), reason: 'a shape, not only a colour');
      expect(
        find.bySemanticsLabel(RegExp(r'^Mode: Bypass Permissions, dangerous\.')),
        findsOneWidget,
        reason: 'the words say it too',
      );
      expect(tester.widget<AppChip>(find.widgetWithText(AppChip, 'Claude Sonnet')).tint, isNull);
      handle.dispose();
    });

    testWidgets('a dangerous mode is the first chip even when more chips queue behind it', (tester) async {
      final session = withOptions([
        modelOption,
        effortOption,
        fastOption,
        const BooleanConfigOption(id: 'web', name: 'Web search', value: false),
        modeOption('bypassPermissions'),
      ]);
      await pumpScreen(tester, session);
      final danger = tester.getTopLeft(find.widgetWithText(AppChip, 'Bypass Permissions')).dx;
      for (final label in ['Claude Sonnet', 'High', 'Fast']) {
        expect(danger, lessThan(tester.getTopLeft(find.widgetWithText(AppChip, label)).dx), reason: label);
      }
    });

    testWidgets('an elevated mode is neutral with a quiet marker; a plain one has neither', (tester) async {
      final elevated = withOptions([modeOption('acceptEdits', choices: const [('acceptEdits', 'Accept edits')])]);
      await pumpScreen(tester, elevated);
      final chip = tester.widget<AppChip>(find.widgetWithText(AppChip, 'Accept edits'));
      expect(chip.tint, isNull);
      expect(chip.leading, isA<Icon>());

      await pumpScreen(tester, withOptions([modeOption('default')]));
      final plain = tester.widget<AppChip>(find.widgetWithText(AppChip, 'Default'));
      expect(plain.tint, isNull);
      expect(plain.leading, isNull);
    });

    testWidgets('the bar says nothing more about the mode', (tester) async {
      final session = withOptions([modeOption('bypassPermissions')]);
      await pumpScreen(tester, session);
      expect(find.text('Bypass Permissions'), findsOneWidget, reason: 'one place: the chip');
    });

    testWidgets('the picker marks a dangerous mode and enters it only by a hold', (tester) async {
      final session = withOptions([
        modeOption(
          'default',
          choices: const [('default', 'Default'), ('acceptEdits', 'Accept edits'), ('bypassPermissions', 'Bypass Permissions')],
        ),
      ]);
      await pumpScreen(tester, session);
      await tester.tap(find.widgetWithText(AppChip, 'Default'));
      await tester.pumpAndSettle();
      expect(find.text('Every tool call runs without asking you.'), findsOneWidget, reason: 'why, in words');
      expect(find.text('File edits are accepted without asking you.'), findsOneWidget, reason: 'elevated says why too');

      await quickTap(tester, find.text('Bypass Permissions'));
      expect(session.configs, isEmpty, reason: 'a tap does not enter it');
      expect(find.text('Hold to switch to Bypass Permissions'), findsOneWidget);

      await holdFor(tester, find.byType(HoldToConfirm));
      await tester.pumpAndSettle();
      expect(session.configs, [('mode', 'bypassPermissions')]);
    });

    testWidgets('leaving a dangerous mode for a safe one is a tap', (tester) async {
      final session = withOptions([modeOption('bypassPermissions')]);
      await pumpScreen(tester, session);
      await tester.tap(find.widgetWithText(AppChip, 'Bypass Permissions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Default'));
      await tester.pumpAndSettle();
      expect(session.configs, [('mode', 'default')]);
    });

    testWidgets('a dangerous mode the agent lists as modes is held too', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(
          modes: const ModeState(
            currentModeId: 'default',
            availableModes: [SessionMode(id: 'default', name: 'Default'), SessionMode(id: 'bypassPermissions', name: 'Bypass')],
          ),
        ),
      );
      await pumpScreen(tester, session);
      await tester.tap(find.widgetWithText(AppChip, 'Default'));
      await tester.pumpAndSettle();
      await quickTap(tester, find.text('Bypass'));
      expect(session.modes, isEmpty);
      await holdFor(tester, find.byType(HoldToConfirm));
      await tester.pumpAndSettle();
      expect(session.modes, ['bypassPermissions']);
    });

    testWidgets('an agent that puts the session in a dangerous mode is felt once', (tester) async {
      final felt = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'HapticFeedback.vibrate') felt.add(call.arguments);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final session = FakeAgentSession(
        state: stateWith(
          modes: const ModeState(
            currentModeId: 'default',
            availableModes: [SessionMode(id: 'default', name: 'Default'), SessionMode(id: 'bypassPermissions', name: 'Bypass Permissions')],
          ),
        ),
      );
      await pumpScreen(tester, session);
      felt.clear();

      // The agent changes the mode on its own: the state gets a note.
      session.update((s) => s.apply(const ModeUpdate('bypassPermissions')));
      await tester.pump();
      expect(session.state.items.last, isA<TranscriptNote>());
      expect(felt.where((a) => a == 'HapticFeedbackType.mediumImpact'), hasLength(1));
      expect(find.widgetWithText(AppChip, 'Bypass Permissions'), findsOneWidget);
      felt.clear();

      // Later items do not announce it again.
      session.update(
        (s) => s.apply(const MessageUpsert(MessageRole.agent, 'a9', hasContent: true, content: [TextBlock('Done.')])),
      );
      await tester.pump();
      expect(felt, isEmpty);
    });

    test('announcesDanger looks only at the items that arrived', () {
      const bypass = ModeState(
        currentModeId: 'bypassPermissions',
        availableModes: [SessionMode(id: 'default', name: 'Default'), SessionMode(id: 'bypassPermissions', name: 'Bypass Permissions')],
      );
      final note = TranscriptNote(key: 'n1', text: 'Mode changed to Bypass Permissions', modeId: 'bypassPermissions');
      final state = stateWith(modes: bypass, items: [agentMsg('a', 'x'), note]);
      expect(announcesDanger(state, 1), isTrue);
      expect(announcesDanger(state, 2), isFalse, reason: 'already announced');
      const calm = ModeState(
        currentModeId: 'default',
        availableModes: [SessionMode(id: 'default', name: 'Default')],
      );
      expect(announcesDanger(stateWith(modes: calm, items: [TranscriptNote(key: 'n', text: 't', modeId: 'default')]), 0), isFalse);
    });
  });

  group('the bar says where once', () {
    test('the folder is left out when it is the title', () {
      final named = FakeAgentSession(title: 'payments-api');
      expect(sessionWhere(named), 'Claude Code · devbox');
      expect(sessionWhere(FakeAgentSession(title: 'Fix payments')), 'Claude Code · devbox · payments-api');
      expect(sessionWhere(FakeAgentSession(title: 'Payments-API ')), 'Claude Code · devbox', reason: 'case and spaces do not make it new');
    });

    testWidgets('the subtitle is agent · machine when the title is the folder', (tester) async {
      await pumpScreen(tester, FakeAgentSession(title: 'payments-api'));
      expect(find.text('Claude Code · devbox'), findsOneWidget);
      expect(find.text('payments-api'), findsOneWidget);
    });

    testWidgets('a long title and Vietnamese at 1.6 text and 320 wide do not overflow', (tester) async {
      await pumpScreen(
        tester,
        FakeAgentSession(title: 'Sửa lỗi định dạng ngày tháng ở màn hình thanh toán của khách hàng doanh nghiệp'),
        size: const Size(320, 640),
        textScale: 1.6,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('since you left', () {
    FakeAgentSession withHistory({int items = 3, AgentLink link = AgentLink.live}) => FakeAgentSession(
      link: link,
      state: stateWith(items: [for (var i = 0; i < items; i++) agentMsg('a$i', 'message $i')]),
    );

    Future<LastSeen> seen(MemoryLastSeenStore store, {int count = 2}) async {
      store.saved = {'m/k1': SeenMarker(DateTime(2026, 10, 5, 14, 2), count)};
      final lastSeen = LastSeen(store);
      await lastSeen.load();
      return lastSeen;
    }

    SinceLeft? passed(WidgetTester tester) => tester.widget<TranscriptView>(find.byType(TranscriptView)).sinceLeft;

    testWidgets('what is new is worked out once and given to the transcript', (tester) async {
      final lastSeen = await seen(MemoryLastSeenStore());
      final session = withHistory();
      await pumpScreen(tester, session, lastSeen: lastSeen);
      await tester.pump();
      final since = passed(tester);
      expect(since, isNotNull);
      expect(since!.steps, 1);
      expect(since.firstUnseenKey, 'a2');
      expect(since.since, DateTime(2026, 10, 5, 14, 2));

      session.update(
        (s) => s.apply(const MessageUpsert(MessageRole.agent, 'a9', hasContent: true, content: [TextBlock('and more')])),
      );
      await tester.pump();
      await tester.pump();
      expect(identical(passed(tester), since), isTrue, reason: 'once: later news is not the divider\'s business');
    });

    testWidgets('while the replay runs nothing is asked; it is asked when it has finished', (tester) async {
      final lastSeen = await seen(MemoryLastSeenStore());
      final session = FakeAgentSession(link: AgentLink.connecting, state: stateWith(items: [agentMsg('a0', 'old')]));
      await pumpScreen(tester, session, lastSeen: lastSeen);
      await tester.pump();
      expect(passed(tester), isNull);

      session.update((s) => stateWith(items: [for (var i = 0; i < 4; i++) agentMsg('a$i', 'm')]));
      session.setLink(AgentLink.live);
      await tester.pump();
      await tester.pump();
      expect(passed(tester)?.steps, 2, reason: 'the history up to the marker is not news');
    });

    testWidgets('no marker, no divider; no store, no crash', (tester) async {
      final lastSeen = LastSeen(MemoryLastSeenStore());
      await lastSeen.load();
      await pumpScreen(tester, withHistory(), lastSeen: lastSeen);
      await tester.pump();
      expect(passed(tester), isNull);

      await pumpScreen(tester, withHistory());
      await tester.pump();
      expect(passed(tester), isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('leaving the screen marks how much was seen', (tester) async {
      final store = MemoryLastSeenStore();
      final lastSeen = await seen(store);
      final session = withHistory(items: 5);
      await pumpScreen(tester, session, lastSeen: lastSeen);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      expect(lastSeen.markerOf('m/k1')!.itemCount, 5);
      expect(store.saved!['m/k1']!.itemCount, 5);
    });

    testWidgets('the app going to the background marks it too', (tester) async {
      final lastSeen = await seen(MemoryLastSeenStore());
      final session = withHistory(items: 4);
      await pumpScreen(tester, session, lastSeen: lastSeen);
      await tester.pump();
      session.update(
        (s) => s.apply(const MessageUpsert(MessageRole.agent, 'a9', hasContent: true, content: [TextBlock('x')])),
      );
      await tester.pump();
      final n = session.state.items.length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(lastSeen.markerOf('m/k1')!.itemCount, n);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    testWidgets('a session that never got its history does not overwrite where the person was', (tester) async {
      final lastSeen = await seen(MemoryLastSeenStore(), count: 9);
      final session = FakeAgentSession(link: AgentLink.connecting);
      await pumpScreen(tester, session, lastSeen: lastSeen);
      await tester.pumpWidget(const SizedBox());
      expect(lastSeen.markerOf('m/k1')!.itemCount, 9);
    });
  });
}
