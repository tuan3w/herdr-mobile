import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/ui/core/tap_guard.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/question_form.dart';
import 'package:herdr_mobile/ui/features/agent_session/tool_rows.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_rows.dart';
import 'package:herdr_mobile/ui/features/agent_session/visible_text.dart';

import '../support/fake_agent_session.dart';

// Data the chat used to drop, as the person sees it: command output that
// codex-acp and pi-acp send only in `_meta`, the stop row and the countdown of
// a question that answers itself.

Future<void> pumpScreen(WidgetTester tester, FakeAgentSession session) async {
  tester.view.physicalSize = const Size(412, 892) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: AppTheme.light(), home: AgentSessionScreen(key: ObjectKey(session), session: session)),
  );
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(tapGuard);
}

SessionUpdate _u(Json json) => SessionUpdate.parse(json);

/// A command announced the way codex-acp and pi-acp do: terminal content,
/// output only in `_meta`.
AgentSessionState _command({
  List<String> chunks = const [],
  String key = 'terminal_output_delta',
  int? exitCode,
  bool exit = false,
  String status = 'in_progress',
}) {
  var s = const AgentSessionState('s1').apply(
    _u({
      'sessionUpdate': 'tool_call',
      'toolCallId': 'c1',
      'title': 'flutter test',
      'kind': 'execute',
      'status': 'in_progress',
      'rawInput': {'command': 'flutter test'},
      'content': [
        {'type': 'terminal', 'terminalId': 'c1'},
      ],
      '_meta': {
        'terminal_info': {'cwd': '/repo', 'terminal_id': 'c1'},
      },
    }),
  );
  for (final data in chunks) {
    s = s.apply(
      _u({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'c1',
        '_meta': {
          key: {'terminal_id': 'c1', 'data': data},
        },
      }),
    );
  }
  if (exit) {
    s = s.apply(
      _u({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'c1',
        'status': status,
        '_meta': {
          'terminal_exit': {'terminal_id': 'c1', 'exit_code': exitCode, 'signal': null},
        },
      }),
    );
  }
  return s.withTurnStarted();
}

ElicitationRequest _question({int? autoResolutionMs}) => ElicitationRequest.parse({
  'mode': 'form',
  'message': 'Which approach?',
  'requestedSchema': {
    'type': 'object',
    'properties': {
      'approach': {'type': 'string', 'enum': ['safe', 'fast']},
    },
  },
  '_meta': {
    'codex': {'autoResolutionMs': autoResolutionMs},
  },
});

void main() {
  group('command output from _meta', () {
    testWidgets('codex-acp: the streamed output is the command output, the host-terminal note is gone', (tester) async {
      final session = FakeAgentSession(
        state: _command(chunks: ['collecting…\n', '+12 -0: All tests passed!\n'], exit: true, exitCode: 0, status: 'completed'),
      );
      await pumpScreen(tester, session);
      await tester.tap(find.text('flutter test'));
      await tester.pump();

      expect(find.text('Output'), findsOneWidget);
      expect(find.text('collecting…'), findsOneWidget);
      expect(find.text('+12 -0: All tests passed!'), findsOneWidget);
      expect(find.text('The output is in a terminal on the host.'), findsNothing);
      expect(find.textContaining('Exited with code'), findsNothing, reason: 'a success says nothing about its exit');
    });

    testWidgets('pi-acp: terminal_output chunks, and the exit code of a failure', (tester) async {
      final session = FakeAgentSession(
        state: _command(
          chunks: ['FAIL test/a_test.dart\n', '1 failed\n'],
          key: 'terminal_output',
          exit: true,
          exitCode: 1,
          status: 'failed',
        ),
      );
      await pumpScreen(tester, session);
      await tester.tap(find.text('flutter test'));
      await tester.pump();

      expect(find.text('FAIL test/a_test.dart'), findsOneWidget);
      expect(find.text('1 failed'), findsOneWidget);
      expect(find.text('Exited with code 1.'), findsOneWidget);
    });

    testWidgets('a row that is open follows the output as it streams', (tester) async {
      final session = FakeAgentSession(state: _command(chunks: ['first\n']));
      await pumpScreen(tester, session);
      await tester.tap(find.text('flutter test'));
      await tester.pump();
      expect(find.text('first'), findsOneWidget);

      session.apply(
        _u({
          'sessionUpdate': 'tool_call_update',
          'toolCallId': 'c1',
          '_meta': {
            'terminal_output_delta': {'terminal_id': 'c1', 'data': 'second\n'},
          },
        }),
      );
      await tester.pump();
      expect(find.text('first'), findsOneWidget);
      expect(find.text('second'), findsOneWidget);
    });

    testWidgets('colour codes and progress rewrites are cleaned; hidden characters are shown', (tester) async {
      final session = FakeAgentSession(
        state: _command(chunks: ['\x1B[32mok\x1B[0m test\n', '10%\r50%\r100%\n', 'evil \u202Etxt\n']),
      );
      await pumpScreen(tester, session);
      await tester.tap(find.text('flutter test'));
      await tester.pump();

      expect(find.text('ok test'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
      expect(find.textContaining('10%'), findsNothing);
      expect(find.text('evil ‹U+202E›txt'), findsOneWidget);
      expect(find.textContaining('\x1B'), findsNothing);
    });

    testWidgets('a command that printed nothing says so; one still starting says it waits', (tester) async {
      final done = FakeAgentSession(state: _command(exit: true, exitCode: 0, status: 'completed'));
      await pumpScreen(tester, done);
      await tester.tap(find.text('flutter test'));
      await tester.pump();
      expect(find.text('No output.'), findsOneWidget);
      expect(find.text('The output is in a terminal on the host.'), findsNothing);

      final starting = FakeAgentSession(state: _command());
      await pumpScreen(tester, starting);
      await tester.tap(find.text('flutter test'));
      await tester.pump();
      expect(find.text('Waiting for output…'), findsOneWidget);
    });

    testWidgets('an agent that sent nothing in _meta keeps the host-terminal note once the call is over', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(
          turnActive: true,
          items: [
            TranscriptTool(
              const ToolCall(
                toolCallId: 'c1',
                title: 'flutter test',
                kind: ToolKind.execute,
                status: ToolStatus.completed,
                content: [ToolTerminal('term-1')],
              ),
            ),
          ],
        ),
      );
      await pumpScreen(tester, session);
      await tester.tap(find.text('flutter test'));
      await tester.pump();
      expect(find.text('The output is in a terminal on the host.'), findsOneWidget);
    });

    test('exitWords names a code or a signal', () {
      expect(exitWords(const ToolOutput(exited: true, exitCode: 127)), 'Exited with code 127.');
      expect(exitWords(const ToolOutput(exited: true, signal: 'SIGKILL')), 'Stopped by signal SIGKILL.');
    });

    test('terminalText strips escapes, keeps the last rewrite of a line and shows hidden characters', () {
      expect(terminalText('\x1B[1;31mred\x1B[0m\n'), 'red\n');
      expect(terminalText('\x1B]0;title\x07done'), 'done');
      expect(terminalText('a\r\nb\r\n'), 'a\nb\n');
      expect(terminalText('10%\r20%\r30%\nend'), '30%\nend');
      expect(terminalText('\r'), '');
      expect(terminalText('\r\r\n\n'), '\n\n');
      expect(terminalText('\u202E'), '‹U+202E›');
    });
  });

  group('stop rows', () {
    testWidgets('each stop reason is one quiet line in plain words', (tester) async {
      const expected = {
        StopReason.maxTokens: 'The agent stopped: it hit the length limit.',
        StopReason.refusal: 'The agent stopped: it refused to continue.',
        StopReason.maxTurnRequests: 'The agent stopped: it reached its limit of steps for one turn.',
      };
      for (final entry in expected.entries) {
        final s = const AgentSessionState('s1')
            .withUserMessage([const TextBlock('write the whole book')])
            .withTurnStarted()
            .withTurnEnded(entry.key);
        await pumpScreen(tester, FakeAgentSession(state: s));
        expect(find.text(entry.value), findsOneWidget, reason: '${entry.key}');
        expect(stopNoteText(entry.key), entry.value);
      }
    });

    testWidgets('a cancelled turn and a normal end show no stop row', (tester) async {
      for (final reason in [StopReason.cancelled, StopReason.endTurn, StopReason.error]) {
        final s = const AgentSessionState('s1').withUserMessage([const TextBlock('hi')]).withTurnStarted().withTurnEnded(reason);
        await pumpScreen(tester, FakeAgentSession(state: s));
        expect(find.textContaining('The agent stopped'), findsNothing, reason: '$reason');
      }
    });

    testWidgets('the row arrives with the end of the turn and rebuilds alone', (tester) async {
      final built = <String>[];
      debugRowBuilt = built.add;
      addTearDown(() => debugRowBuilt = null);
      final session = FakeAgentSession(
        state: const AgentSessionState('s1')
            .withUserMessage([const TextBlock('hi')])
            .withTurnStarted()
            .apply(_u({'sessionUpdate': 'agent_message_chunk', 'messageId': 'a', 'content': {'type': 'text', 'text': 'cut o'}})),
      );
      await pumpScreen(tester, session);
      expect(find.textContaining('The agent stopped'), findsNothing);

      built.clear();
      final live = session.state.liveKey!;
      session.update((s) => s.withTurnEnded(StopReason.maxTokens));
      await tester.pump();
      expect(find.text('The agent stopped: it hit the length limit.'), findsOneWidget);
      final stop = session.state.items.whereType<TranscriptStop>().single;
      expect(built, ['$live#0', stop.key], reason: 'the message that ended is settled into its rows, and the new row; nothing else');
    });
  });

  group('auto-resolving question', () {
    testWidgets('the panel says how long the agent waits, counted from when the request arrived', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(
          turnActive: true,
          pending: [PendingQuestion(9, _question(autoResolutionMs: 600000), receivedAt: DateTime.now().subtract(const Duration(minutes: 1)))],
        ),
      );
      await pumpScreen(tester, session);
      expect(find.text('Which approach?'), findsOneWidget);
      expect(find.textContaining('The agent goes on without an answer within 9 min'), findsOneWidget);
    });

    testWidgets('a request the agent withdraws takes the panel and its label with it', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(turnActive: true, pending: [PendingQuestion(9, _question(autoResolutionMs: 600000))]),
      );
      await pumpScreen(tester, session);
      expect(find.byType(AutoResolveLabel), findsOneWidget);
      session.update((s) => s.withoutPending(9));
      await tester.pump();
      expect(find.byType(QuestionPanel), findsNothing);
      expect(find.byType(AutoResolveLabel), findsNothing);
    });

    testWidgets('a question that never answers itself has no label', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(turnActive: true, pending: [PendingQuestion(9, _question())]),
      );
      await pumpScreen(tester, session);
      expect(find.text('Which approach?'), findsOneWidget);
      expect(find.byType(AutoResolveLabel), findsNothing);
    });

    testWidgets('the label counts down once a second and says so when the time is up', (tester) async {
      final start = DateTime.utc(2026, 10, 5, 10);
      var now = start;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: QuestionPanel(
              request: _question(autoResolutionMs: 60000),
              more: 0,
              receivedAt: start,
              now: () => now,
              onAnswer: (_) {},
            ),
          ),
        ),
      );
      expect(find.text('The agent goes on without an answer within 1 min.'), findsOneWidget);

      now = start.add(const Duration(seconds: 15));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('The agent goes on without an answer within 45 s.'), findsOneWidget);

      now = start.add(const Duration(seconds: 59, milliseconds: 200));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('The agent goes on without an answer within 1 s.'), findsOneWidget, reason: 'rounded up, never "0 s"');

      now = start.add(const Duration(seconds: 61));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('The agent is going on without an answer.'), findsOneWidget);
      // The clock is released after that frame; the panel itself stays until
      // the agent withdraws the request.
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(QuestionPanel), findsOneWidget);
    });

    test('autoResolveWords', () {
      expect(autoResolveWords(const Duration(seconds: 45)), 'The agent goes on without an answer within 45 s.');
      expect(autoResolveWords(const Duration(milliseconds: 44001)), 'The agent goes on without an answer within 45 s.');
      expect(autoResolveWords(const Duration(seconds: 60)), 'The agent goes on without an answer within 1 min.');
      expect(autoResolveWords(const Duration(seconds: 80)), 'The agent goes on without an answer within 1 min 20 s.');
      expect(autoResolveWords(Duration.zero), 'The agent is going on without an answer.');
      expect(autoResolveWords(const Duration(seconds: -3)), 'The agent is going on without an answer.');
    });
  });
}
