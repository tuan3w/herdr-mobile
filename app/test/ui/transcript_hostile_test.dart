// Updates a real agent sends in an order or with content the transcript must
// still draw: a row that throws while building or laying out is a gray
// screenful (release builds) or a row that never appears.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/acp/turns/plain_text.dart' show safeEnd;
import 'package:herdr_mobile/ui/core/markdown/markdown.dart' show proseText;
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/code_panel.dart' show clipLine, textLines;
import 'package:herdr_mobile/ui/features/agent_session/transcript_view.dart';
import 'package:herdr_mobile/ui/features/agent_session/visible_text.dart';

import '../support/fake_agent_session.dart';

Map<String, Object?> _chunk(String kind, String id, String text) => {
  'sessionUpdate': kind,
  'messageId': id,
  'content': {'type': 'text', 'text': text},
};

Map<String, Object?> _tool(String id, String status) =>
    {'sessionUpdate': 'tool_call', 'toolCallId': id, 'title': 'Run ls', 'kind': 'execute', 'status': status};

AgentSessionState _play(List<Map<String, Object?>> updates) {
  var state = AgentSessionState('s');
  for (final u in updates) {
    state = state.apply(SessionUpdate.parse(u));
  }
  return state;
}

Future<void> _pump(WidgetTester tester, AgentSessionState state) async {
  tester.view
    ..physicalSize = const Size(412, 892) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: TranscriptView(session: FakeAgentSession(state: state))),
    ),
  );
  await tester.pump(const Duration(milliseconds: 200));
}

/// Opens every fold and "Show all" the screen offers.
Future<void> _openEverything(WidgetTester tester) async {
  for (final label in ['Worked', 'Show all', 'Read all', 'Thought']) {
    for (final e in find.textContaining(label).evaluate().toList()) {
      await tester.tap(find.byWidget(e.widget).first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 60));
    }
  }
}

void main() {
  group('the live message is not always the last row', () {
    testWidgets('a call that failed before the answer, text streaming while the turn is not running', (tester) async {
      await _pump(tester, _play([
        _chunk('user_message_chunk', 'u', 'go'),
        _tool('c1', 'failed'),
        _chunk('agent_message_chunk', 'm1', 'That failed, so '),
      ]));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('That failed, so'), findsOneWidget);
    });

    testWidgets('text after Stop: the cancelled call breaks out below the answer that is still arriving', (tester) async {
      await _pump(tester, _play([
        _chunk('user_message_chunk', 'u', 'go'),
        {'sessionUpdate': 'state_update', 'state': 'running'},
        _tool('c1', 'in_progress'),
        {'sessionUpdate': 'tool_call_update', 'toolCallId': 'c1', 'status': 'cancelled'},
        {'sessionUpdate': 'state_update', 'state': 'idle', 'stopReason': 'cancelled'},
        _chunk('agent_message_chunk', 'm1', 'Stopped, but '),
      ]));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Stopped, but'), findsOneWidget);
    });

    testWidgets('two messages whose chunks alternate: opening the fold brings the live one into the plan', (tester) async {
      await _pump(tester, _play([
        _chunk('user_message_chunk', 'u', 'go'),
        _chunk('agent_message_chunk', 'm1', 'first part'),
        _chunk('agent_message_chunk', 'm2', 'second part'),
        _chunk('agent_message_chunk', 'm1', ' and more'),
      ]));
      await _openEverything(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('text that is not well-formed UTF-16', () {
    final lone = '\u{1F680}'.substring(0, 1); // half of an emoji

    testWidgets('in a message, a prompt, a thought, a tool title and an embedded file: drawn, with the half marked', (tester) async {
      await _pump(tester, _play([
        _chunk('user_message_chunk', 'u', 'what is $lone this'),
        _chunk('agent_thought_chunk', 't', 'thinking $lone'),
        {
          'sessionUpdate': 'tool_call',
          'toolCallId': 'c1',
          'title': 'Run $lone',
          'kind': 'execute',
          'status': 'completed',
          'rawOutput': 'out $lone',
          'content': [
            {
              'type': 'content',
              'content': {
                'type': 'resource',
                'resource': {'uri': 'file:///a.txt', 'mimeType': 'text/plain', 'text': 'file $lone\nline two'},
              },
            },
            {'type': 'diff', 'path': 'a.dart', 'oldText': 'a $lone', 'newText': 'b $lone'},
          ],
        },
        _chunk('agent_message_chunk', 'm1', 'answer $lone here\n\n```\ncode $lone\n```'),
        {'sessionUpdate': 'state_update', 'state': 'idle', 'stopReason': 'end_turn'},
      ]));
      await _openEverything(tester);
      expect(tester.takeException(), isNull);
    });

    test('a half is replaced where text is read and made visible where it is quoted', () {
      expect(proseText('a${lone}b'), 'a\uFFFDb');
      expect(proseText('${lone}x'), '\uFFFDx');
      expect(proseText('x$lone'), 'x\uFFFD');
      expect(proseText('x\u{1F680}y'), 'x\u{1F680}y', reason: 'a whole emoji is left alone');
      expect(visibleText('a${lone}b'), contains('U+D83D'));
      expect(visibleText('x\u{1F680}y'), 'x\u{1F680}y');
      expect(clipLine('a${lone}b').codeUnits.every((u) => u < 0xD800 || u > 0xDFFF), isTrue);
      for (final line in textLines('a\n${lone}b\n$lone')) {
        expect(line.text.codeUnits.every((u) => u < 0xD800 || u > 0xDFFF), isTrue, reason: line.text);
      }
    });

    test('a cut never leaves half a pair at its end', () {
      const s = 'ab\u{1F680}cd';
      expect(safeEnd(s, 3), 2, reason: 'the cut would fall inside the emoji');
      expect(safeEnd(s, 4), 4);
      expect(s.substring(0, safeEnd(s, 3)), 'ab');
      expect(safeEnd(s, 99), s.length);
      expect(safeEnd(s, 0), 0);
    });
  });
}
