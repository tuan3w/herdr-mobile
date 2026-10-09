// The top of an observed agent's transcript: earlier messages are read as the
// reader scrolls up, and the rows in view stay where they are when they come.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart' show EarlierHistory;
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_view.dart';

import '../support/fake_agent_session.dart';

/// Turns [from]..[to] (exclusive): a question and a two-line answer each.
AgentSessionState _turns(int from, int to) {
  var state = AgentSessionState('s');
  for (var i = from; i < to; i++) {
    for (final u in [
      {'sessionUpdate': 'user_message_chunk', 'messageId': 'u$i', 'content': {'type': 'text', 'text': 'question $i'}},
      {'sessionUpdate': 'agent_message_chunk', 'messageId': 'a$i', 'content': {'type': 'text', 'text': 'answer $i\n\nmore of answer $i'}},
    ]) {
      state = state.apply(SessionUpdate.parse(u));
    }
  }
  return state;
}

Future<FakeAgentSession> _open(WidgetTester tester, AgentSessionState state, EarlierHistory earlier) async {
  tester.view
    ..physicalSize = const Size(412, 892) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final session = FakeAgentSession(state: state)..earlierValue = earlier;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: TranscriptView(session: session)),
    ),
  );
  // The older turns are planned after the first frames. Not pumpAndSettle:
  // the spinner of a read under way never settles.
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return session;
}

Future<void> _scrollToTop(WidgetTester tester) async {
  for (var i = 0; i < 40 && find.textContaining('question 40').evaluate().isEmpty; i++) {
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a long transcript opened at its end reads nothing earlier until the reader nears the top', (tester) async {
    final session = await _open(tester, _turns(40, 100), EarlierHistory.available);
    expect(session.loadEarlierCalls, 0, reason: 'the reader is at the end: no read for what nobody looks at');
    await _scrollToTop(tester);
    expect(find.textContaining('question 40'), findsOneWidget);
    expect(session.loadEarlierCalls, greaterThan(0));
  });

  testWidgets('a transcript shorter than the screen reads the earlier messages at once', (tester) async {
    final session = await _open(tester, _turns(98, 100), EarlierHistory.available);
    expect(session.loadEarlierCalls, greaterThan(0));
  });

  testWidgets('the top row says what is going on, and nothing when the transcript is whole', (tester) async {
    final session = await _open(tester, _turns(98, 100), EarlierHistory.loading);
    expect(find.text('Loading earlier messages…'), findsOneWidget);
    session.setEarlier(EarlierHistory.tooLong);
    await tester.pump();
    expect(find.textContaining('last 64 MB'), findsOneWidget);
    session.setEarlier(EarlierHistory.none);
    await tester.pump();
    expect(find.textContaining('earlier', findRichText: true), findsNothing);
    expect(find.textContaining('64 MB'), findsNothing);
  });

  testWidgets('an empty end of the log reads earlier instead of saying nothing was said', (tester) async {
    final session = await _open(tester, const AgentSessionState('s'), EarlierHistory.available);
    expect(find.text('Nothing said yet'), findsNothing);
    expect(session.loadEarlierCalls, greaterThan(0));
  });

  testWidgets('the older turns arrive above: the row the reader looks at does not move', (tester) async {
    final shown = _turns(40, 100);
    final session = await _open(tester, shown, EarlierHistory.available);
    await _scrollToTop(tester);
    final row = find.textContaining('question 41');
    expect(row, findsOneWidget);
    final before = tester.getTopLeft(row);

    session.push(_turns(0, 100).withKeysOf(shown));
    session.setEarlier(EarlierHistory.none);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.textContaining('question 41')), before);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(find.textContaining('question 39'), findsOneWidget, reason: 'the turn before is just above');
  });
}
