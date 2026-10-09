// A message whose send fails after the person left the screen (Back, or a
// swipe to the next agent) is not lost: it goes back to the agent's draft and a
// toast says it was not sent.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_view.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../support/fake_agent_session.dart';

const _agent = SessionAgent('a/k1');

class _Rig {
  _Rig(this.session, this.screens);

  final FakeAgentSession session;
  final AgentScreens screens;
}

Future<_Rig> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(412, 892) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final session = FakeAgentSession()
    ..holdSends = Completer<void>()
    ..refuseSends = 'Not connected. The message was not sent.';
  final screens = AgentScreens();
  addTearDown(screens.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<AgentScreens>.value(
      value: screens,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => AgentSessionScreen(session: session, agent: _agent)),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.byType(TranscriptView), findsOneWidget);
  return _Rig(session, screens);
}

Future<void> _sendThenLeave(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.tap(find.byIcon(LucideIcons.arrowUp));
  await tester.pump();
  tester.state<NavigatorState>(find.byType(Navigator)).pop();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.byType(AgentSessionScreen), findsNothing);
}

void main() {
  testWidgets('a send that fails after the screen was left puts the text in the draft and says so', (tester) async {
    final rig = await _open(tester);
    await _sendThenLeave(tester, 'fix the build');
    expect(rig.screens.draftOf(_agent), '', reason: 'the field emptied when it was sent');

    rig.session.holdSends!.complete();
    await tester.pump();

    expect(rig.screens.draftOf(_agent), 'fix the build');
    expect(find.textContaining('Not sent'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('what was typed for the agent meanwhile stays, after the text that came back', (tester) async {
    final rig = await _open(tester);
    await _sendThenLeave(tester, 'fix the build');
    rig.screens.keepDraft(_agent, 'and run the tests');

    rig.session.holdSends!.complete();
    await tester.pump();

    expect(rig.screens.draftOf(_agent), 'fix the build\nand run the tests');
    expect(find.textContaining('Not sent'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
  });
}
