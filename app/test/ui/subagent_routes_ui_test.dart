import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/subagents/run_facts.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agent_session/subagent_card.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_view.dart';

import '../acp/support/trace_state.dart';
import '../support/fake_agent_session.dart';
import '../support/subagent_fixtures.dart' show play;

// The card of a subagent of OpenCode (a recorded session) and of an agent that
// answers its launching call at once (a shape from the agent's source,
// UNVERIFIED against a session): what the person reads.

Widget _app(Widget body) => MaterialApp(
  theme: AppTheme.light(),
  home: Scaffold(body: body),
);

Future<void> _pump(WidgetTester tester, FakeAgentSession session) async {
  tester.view.physicalSize = const Size(412, 892) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(TranscriptView(session: session)));
  await tester.pump(const Duration(milliseconds: 100));
}

Finder _text(String s) => find.textContaining(s, findRichText: true);

void main() {
  testWidgets('the recorded OpenCode trace: one card, the child\'s words and call stay out of the parent', (
    tester,
  ) async {
    final session = FakeAgentSession(state: stateOfTrace('opencode', 'subagent'));
    await _pump(tester, session);
    await tester.tap(_text('Worked'));
    await tester.pumpAndSettle();

    expect(find.byType(SubagentCard), findsOneWidget);
    expect(find.text('List files with ls'), findsOneWidget);
    expect(_text('Here are the exact file names'), findsNothing, reason: 'that is the child talking');
    expect(_text('README.md, notes.txt, src'), findsOneWidget, reason: 'the parent\'s own answer');
    await tester.tap(find.text('List files with ls'));
    await tester.pumpAndSettle();
    expect(find.text('Open conversation'), findsOneWidget, reason: 'the tagged updates made a transcript');
  });

  testWidgets('an agent that answers at once and never says when it ends: the card says so', (tester) async {
    final s = play([
      {
        'sessionUpdate': 'tool_call',
        'toolCallId': 'd1',
        'title': 'subagent',
        'kind': 'other',
        'status': 'in_progress',
        'rawInput': {'description': 'Check the logs', 'prompt': 'look at the logs', 'name': 'agent-1'},
      },
      {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'd1',
        'status': 'completed',
        'content': [
          {
            'type': 'content',
            'content': {'type': 'text', 'text': 'started subagent agent-1'},
          },
        ],
      },
    ], active: false);
    await _pump(tester, FakeAgentSession(state: s));
    await tester.tap(_text('Worked'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check the logs'));
    await tester.pumpAndSettle();
    expect(_text(startedInBackgroundNote), findsOneWidget);
    expect(find.text('Open summary'), findsOneWidget);
    expect(find.text('Open conversation'), findsNothing);
  });
}
