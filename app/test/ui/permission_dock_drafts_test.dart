import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/core/tap_guard.dart';
import 'package:herdr_mobile/ui/features/agent_session/permission_dock.dart';

import '../support/fake_agent_session.dart';
import 'hold_support.dart';

ElicitationRequest _form() => ElicitationRequest.parse({
  'mode': 'form',
  'message': 'Which approach?',
  'requestedSchema': {
    'type': 'object',
    'properties': {
      'note': {'type': 'string', 'title': 'Your note'},
    },
  },
});

Future<void> _pump(WidgetTester tester, FakeAgentSession session) async {
  tester.view.physicalSize = const Size(824, 1784);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: PromptDock(session: session))),
    ),
  );
  await tester.pump(tapGuard);
}

void main() {
  group('a question the terminal refused', () {
    testWidgets('comes back under a new request id with what was typed still in the form', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(turnActive: true, pending: [PendingQuestion('ask:t:0', _form(), draftKey: 'ask:t')]),
      );
      await _pump(tester, session);
      await tester.enterText(find.byType(TextField), 'use the safe one');
      await tester.pump();

      // The terminal did not take the answer: the same question, a new request.
      session.push(stateWith(turnActive: true, pending: [PendingQuestion('ask:t:1', _form(), draftKey: 'ask:t')]));
      await tester.pump();
      await tester.pump(tapGuard);

      expect(find.text('use the safe one'), findsOneWidget);
    });

    testWidgets('once answered its draft is dropped: the next time it is asked the form is empty', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(turnActive: true, pending: [PendingQuestion('ask:t:0', _form(), draftKey: 'ask:t')]),
      );
      await _pump(tester, session);
      await tester.enterText(find.byType(TextField), 'use the safe one');
      await tester.pump();

      session.push(stateWith(turnActive: true));
      await tester.pump();
      session.push(stateWith(turnActive: true, pending: [PendingQuestion('ask:t:2', _form(), draftKey: 'ask:t')]));
      await tester.pump();
      await tester.pump(tapGuard);

      expect(find.text('use the safe one'), findsNothing);
    });

    testWidgets('a request without a draft key is its own question: another id starts a new form', (tester) async {
      final session = FakeAgentSession(state: stateWith(turnActive: true, pending: [PendingQuestion(1, _form())]));
      await _pump(tester, session);
      await tester.enterText(find.byType(TextField), 'first');
      await tester.pump();

      session.push(stateWith(turnActive: true, pending: [PendingQuestion(2, _form())]));
      await tester.pump();
      await tester.pump(tapGuard);

      expect(find.text('first'), findsNothing);
    });
  });

  group('a gate carried by the request', () {
    const gated = PermissionOption(
      optionId: '0',
      name: 'Yes',
      kind: PermissionOptionKind.allowOnce,
      gate: 'long command, check it all',
    );
    const refuse = PermissionOption(
      optionId: '1',
      name: 'No',
      kind: PermissionOptionKind.rejectOnce,
      gate: 'long command, check it all',
    );

    test('holds the allow it was set on, never a refusal, and never replaces a stricter reason', () {
      expect(optionGate(gated, null), 'long command, check it all');
      expect(optionGate(refuse, null), isNull);
      expect(optionGate(gated, 'force-pushes'), 'force-pushes');
    });

    testWidgets('a tap on such an allow answers nothing; the hold does', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(
          turnActive: true,
          pending: [
            PendingPermission(
              7,
              permissionRequest(rawInput: {'command': 'ls'}, options: const [gated, refuse]),
            ),
          ],
        ),
      );
      await _pump(tester, session);
      await quickTap(tester, find.text('Yes'));
      expect(session.permissionAnswers, isEmpty);

      await holdFor(tester, find.textContaining('Hold to send'));
      expect(session.permissionAnswers.single.$1, 7);
    });
  });
}
