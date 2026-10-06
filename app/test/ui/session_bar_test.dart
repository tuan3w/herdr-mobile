// The session bar says who the session is, once: the glyph, the title and
// where it lives. How long it has worked is the transcript's status row, not a
// second title squeezed beside the first.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_bar.dart';

import '../support/fake_agent_session.dart';

void main() {
  testWidgets('an agent in a terminal that works quietly does not put a second title in the bar', (tester) async {
    tester.view.physicalSize = const Size(360, 780) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final session = FakeAgentSession(
      title: 'Fix ingest logic for the planning skill',
      state: stateWith(turnActive: true),
    )
      ..observed = true
      ..paneId = 'w1:p1'
      ..live = ['npm test'];
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light(), home: AgentSessionScreen(key: ObjectKey(session), session: session)),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final inBar = find.descendant(of: find.byType(SessionBar), matching: find.textContaining('Working'));
    expect(inBar, findsNothing, reason: 'the status row below says how long; the bar names the session');

    final title = find.descendant(of: find.byType(SessionBar), matching: find.text('Fix ingest logic for the planning skill'));
    expect(title, findsOneWidget);
    final room = tester.getSize(find.byType(SessionBar)).width;
    expect(tester.getSize(title).width, greaterThan(room * 0.4), reason: 'the title gets the room, not a label');
  });
}
