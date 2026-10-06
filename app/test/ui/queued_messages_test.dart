// Messages typed while an agent session works: they wait, can be edited or
// removed, go out when the turn ends, and Stop never gets in their way.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/tap_guard.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/fake_agent_session.dart';

Future<void> pump(WidgetTester tester, FakeAgentSession session) async {
  tester.view.physicalSize = const Size(412, 892) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: AgentSessionScreen(key: ObjectKey(session), session: session),
    ),
  );
  await tester.pump(tapGuard);
}

FakeAgentSession working() => FakeAgentSession(state: stateWith(turnActive: true));

/// The composer's field (the last one on the screen while no sheet is open).
Finder get field => find.byType(TextField).last;

Future<void> queue(WidgetTester tester, String text) async {
  await tester.enterText(field, text);
  await tester.pump();
  await tester.tap(find.byIcon(LucideIcons.listPlus));
  await settle(tester, 300);
}

/// A route or an animated size starts on the frame after the change.
Future<void> settle(WidgetTester tester, [int ms = 400]) async {
  await tester.pump();
  await tester.pump(Duration(milliseconds: ms));
}

void endTurn(FakeAgentSession session) => session.update((s) => s.withTurnEnded(StopReason.endTurn));

void main() {
  testWidgets('a working agent takes the next message into a queue; nothing is sent yet', (tester) async {
    final session = working();
    await pump(tester, session);
    await tester.tap(field);
    await settle(tester);
    expect(find.text('Will be queued until the turn ends'), findsOneWidget, reason: 'said before it is sent');
    expect(find.text('Message Claude Code\u2026'), findsOneWidget);

    await queue(tester, 'then run the tests');

    expect(session.sent, isEmpty);
    expect(session.queued.single.text, 'then run the tests');
    expect(find.text('then run the tests'), findsOneWidget, reason: 'the queue shows it');
    expect(tester.widget<TextField>(field).controller!.text, isEmpty, reason: 'the field is free for the next one');
  });

  testWidgets('it goes out by itself when the turn ends, and leaves the queue', (tester) async {
    final session = working();
    await pump(tester, session);
    await queue(tester, 'then run the tests');
    await queue(tester, 'and the linter');
    expect(session.queued.map((m) => m.text), ['then run the tests', 'and the linter']);

    endTurn(session);
    await settle(tester, 300);

    expect(session.sent, ['then run the tests'], reason: 'one at a time, in order');
    expect(session.queued.map((m) => m.text), ['and the linter']);
    expect(find.byTooltip('Remove queued message'), findsOneWidget);
  });

  testWidgets('a tap opens a queued message to edit; Save changes what will be sent', (tester) async {
    final session = working();
    await pump(tester, session);
    await queue(tester, 'then run the tests');

    await tester.tap(find.text('then run the tests'));
    await settle(tester);
    expect(find.text('Edit queued message'), findsOneWidget);
    final sheetField = find.descendant(of: find.byType(BottomSheet), matching: find.byType(TextField));
    expect(find.widgetWithText(AppButton, 'Save').evaluate(), isNotEmpty);
    expect(tester.widget<AppButton>(find.widgetWithText(AppButton, 'Save')).onPressed, isNull, reason: 'nothing changed yet');

    await tester.enterText(sheetField, 'then run the tests twice');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppButton, 'Save'));
    await settle(tester);
    expect(session.queued.single.text, 'then run the tests twice');
    expect(find.text('then run the tests twice'), findsOneWidget);

    endTurn(session);
    await settle(tester, 300);
    expect(session.sent, ['then run the tests twice']);
  });

  testWidgets('a message that went out while it was being edited says so and cannot be saved', (tester) async {
    final session = working();
    await pump(tester, session);
    await queue(tester, 'then run the tests');
    await tester.tap(find.text('then run the tests'));
    await settle(tester);
    final sheetField = find.descendant(of: find.byType(BottomSheet), matching: find.byType(TextField));
    await tester.enterText(sheetField, 'something else');
    await tester.pump();

    endTurn(session);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Already sent. It can no longer be changed.'), findsOneWidget);
    expect(tester.widget<AppButton>(find.widgetWithText(AppButton, 'Save')).onPressed, isNull);
    expect(tester.widget<AppButton>(find.widgetWithText(AppButton, 'Remove')).onPressed, isNull);
    expect(session.sent, ['then run the tests'], reason: 'what was queued is what went out');
  });

  testWidgets('the cross removes a queued message; Remove in the editor does too', (tester) async {
    final session = working();
    await pump(tester, session);
    await queue(tester, 'one');
    await queue(tester, 'two');

    await tester.tap(find.byTooltip('Remove queued message').first);
    await settle(tester, 300);
    expect(session.queued.map((m) => m.text), ['two']);

    await tester.tap(find.text('two'));
    await settle(tester);
    await tester.tap(find.widgetWithText(AppButton, 'Remove'));
    await settle(tester);
    expect(session.queued, isEmpty);

    endTurn(session);
    await settle(tester, 300);
    expect(session.sent, isEmpty);
  });

  testWidgets('after Stop the queue is held, says why, and goes out only when resumed', (tester) async {
    final session = working();
    await pump(tester, session);
    await queue(tester, 'then run the tests');

    session.cancel();
    endTurn(session);
    await settle(tester, 300);
    expect(session.sent, isEmpty, reason: 'the person stopped the turn: nothing goes out unasked');
    expect(find.textContaining('turn was stopped'), findsOneWidget);

    await tester.tap(find.widgetWithText(AppButton, 'Resume'));
    await settle(tester, 300);
    expect(session.sent, ['then run the tests']);
  });

  testWidgets('Stop stays one tap away with a draft in the field', (tester) async {
    final session = working();
    await pump(tester, session);
    await tester.enterText(field, 'a draft');
    await tester.pump();
    expect(find.byIcon(LucideIcons.listPlus), findsOneWidget);

    await tester.tap(find.byIcon(LucideIcons.square));
    await tester.pump(const Duration(milliseconds: 50));
    expect(session.cancelCount, 1);
    expect(tester.widget<TextField>(field).controller!.text, 'a draft', reason: 'Stop does not touch the draft');
  });

  testWidgets('Stop is its own button: Send keeps its place and a double tap on Queue cannot reach Stop', (tester) async {
    final session = working();
    await pump(tester, session);
    final sendAt = tester.getCenter(find.byIcon(LucideIcons.listPlus));
    final stopAt = tester.getCenter(find.byIcon(LucideIcons.square));
    expect(stopAt.dx, lessThan(sendAt.dx), reason: 'Stop sits left of Send');

    await tester.enterText(field, 'then run the tests');
    await tester.pump();
    expect(tester.getCenter(find.byIcon(LucideIcons.listPlus)), sendAt, reason: 'a draft moves nothing');
    await tester.tap(find.byIcon(LucideIcons.listPlus));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byIcon(LucideIcons.listPlus));
    await tester.pump(const Duration(milliseconds: 50));
    expect(session.queued, hasLength(1), reason: 'the second tap met an empty field');
    expect(session.cancelCount, 0);
    expect(tester.getCenter(find.byIcon(LucideIcons.square)), stopAt, reason: 'sending moves nothing');

    await tester.tap(find.byIcon(LucideIcons.square));
    await tester.pump(const Duration(milliseconds: 50));
    expect(session.cancelCount, 1);
  });

  testWidgets('Stop appearing with a turn takes no tap for 450 ms', (tester) async {
    final session = FakeAgentSession();
    await pump(tester, session);
    expect(find.byIcon(LucideIcons.square), findsNothing);

    session.update((s) => s.withTurnStarted());
    await tester.pump();
    await tester.tap(find.byIcon(LucideIcons.square));
    await tester.pump(const Duration(milliseconds: 50));
    expect(session.cancelCount, 0, reason: 'a tap meant for Send');

    await tester.pump(tapGuard);
    await tester.tap(find.byIcon(LucideIcons.square));
    await tester.pump(const Duration(milliseconds: 50));
    expect(session.cancelCount, 1);
  });

  testWidgets('an agent that takes input into the running turn says so and queues nothing', (tester) async {
    final session = working()..steerable = true;
    await pump(tester, session);
    await tester.tap(field);
    await settle(tester);
    expect(find.text('Goes into the running turn'), findsOneWidget);
    expect(find.text('Will be queued until the turn ends'), findsNothing);

    await tester.enterText(field, 'use the staging db');
    await tester.pump();
    await tester.tap(find.byIcon(LucideIcons.arrowUp));
    await settle(tester, 300);

    expect(session.steeredBlocks, hasLength(1));
    expect(session.queued, isEmpty);
  });

  testWidgets('an agent in a terminal has no queue: it only stops', (tester) async {
    final session = working()..observed = true;
    await pump(tester, session);
    expect(find.byIcon(LucideIcons.square), findsOneWidget);
    await tester.enterText(field, 'hello');
    await tester.pump();
    expect(find.byIcon(LucideIcons.listPlus), findsNothing);
    expect(find.text('Message Claude Code\u2026'), findsOneWidget);
  });

  testWidgets('more than three waiting: three show, the rest are one tap away', (tester) async {
    final session = working();
    await pump(tester, session);
    for (final t in ['one', 'two', 'three', 'four', 'five']) {
      await queue(tester, t);
    }
    expect(find.text('four'), findsNothing);
    expect(find.text('2 more queued'), findsOneWidget);

    await tester.tap(find.text('2 more queued'));
    await settle(tester, 300);
    expect(find.text('five'), findsOneWidget);
    expect(find.text('Show fewer'), findsOneWidget);
  });
}
