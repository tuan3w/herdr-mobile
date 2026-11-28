import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';

import 'package:herdr_mobile/ui/features/agent_session/question_form.dart' show QuestionPanel;

import '../support/fake_agent_session.dart';
import '../support/shot.dart' show loadAppFonts;

// Nothing moves under the thumb: a failed Accept says what is missing without
// shifting Accept and Decline, so the second tap lands where the first did.

ElicitationRequest _form(Map<String, Object?> properties, {required List<String> required}) =>
    ElicitationRequest.parse({
      'mode': 'form',
      'message': 'A question',
      'requestedSchema': {'type': 'object', 'required': required, 'properties': properties},
    });

Future<FakeAgentSession> _pump(WidgetTester tester, ElicitationRequest request) async {
  final session = FakeAgentSession(state: stateWith(turnActive: true, pending: [PendingQuestion(9, request)]));
  tester.view.physicalSize = const Size(412, 892) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: AgentSessionScreen(key: ObjectKey(session), session: session),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(Dwell.tapGuard);
  return session;
}

/// The dock grows upward from the composer, so a field that gets taller shifts
/// everything above it, the field itself included, under the person's eye. A
/// failed Accept must say what is missing without moving [field] or the
/// answers.
Future<void> _expectNothingMoves(WidgetTester tester, Finder field, String reason) async {
  final accept = find.text('Accept');
  final fieldBefore = tester.getTopLeft(field);
  final acceptBefore = tester.getTopLeft(accept);
  await tester.tap(accept);
  await tester.pump();
  expect(find.text('Required'), findsOneWidget, reason: 'the failed Accept names what is missing');
  expect(tester.getTopLeft(accept), acceptBefore, reason: 'Accept: $reason');
  expect(tester.getTopLeft(field), fieldBefore, reason: 'the field: $reason');
}

/// The form's own field (the composer has one too).
final _formField = find.descendant(of: find.byType(QuestionPanel), matching: find.byType(TextField));

void main() {
  setUpAll(loadAppFonts);

  testWidgets('a text field that fails does not push Accept and Decline', (tester) async {
    await _pump(
      tester,
      _form(
        {
          'name': {'type': 'string', 'title': 'Your name', 'maxLength': 40},
        },
        required: ['name'],
      ),
    );
    await _expectNothingMoves(tester, _formField, 'the error appears in the room the field already holds');
  });

  testWidgets('a multi-line text field that fails does not push them either', (tester) async {
    await _pump(
      tester,
      _form(
        {
          'why': {'type': 'string', 'title': 'Why'},
        },
        required: ['why'],
      ),
    );
    await _expectNothingMoves(tester, _formField, 'multi-line field');
  });

  testWidgets('a choice that fails does not push them', (tester) async {
    await _pump(
      tester,
      _form(
        {
          'env': {
            'type': 'string',
            'title': 'Environment',
            'enum': ['staging', 'production'],
          },
        },
        required: ['env'],
      ),
    );
    await _expectNothingMoves(tester, find.text('Environment'), 'the choice names its error in reserved room');
  });
}
