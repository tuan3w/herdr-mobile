// `/clear` and `/new` typed into a chat: an agent that cannot clear over ACP
// (omp handles them only in its terminal, so the word went to the model as a
// prompt and nothing was cleared) gets a fresh conversation in the same
// folder; an agent that takes the command itself is sent it as before.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/ui/core/toast.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/fake_agent_session.dart';
import 'history_support.dart';

FakeAgentSession _old({List<AcpCommand> commands = const []}) => FakeAgentSession(
  agent: 'omp',
  agentLabel: 'omp',
  state: stateWith(items: [userMsg('u', 'earlier prompt')], commands: commands),
);

FakeAgentSession _fresh() => FakeAgentSession(key: 'm/k2', agent: 'omp', agentLabel: 'omp');

Future<HistoryEnv> _open(WidgetTester tester, FakeAgentSession session) async {
  final e = await historyEnv();
  await pumpUnder(tester, e, AgentSessionScreen(key: ObjectKey(session), session: session));
  return e;
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).last, text);
  await tester.pump();
  await tester.tap(find.byIcon(LucideIcons.arrowUp));
  await settleHistory(tester, 3);
}

void main() {
  testWidgets('/clear starts a fresh session in the same folder and replaces this chat', (tester) async {
    final old = _old();
    final e = await _open(tester, old);
    final next = _fresh();
    e.sessions.onStart = (_) async {
      e.sessions.hold(next);
      return next;
    };

    await _type(tester, '/clear');
    await settleHistory(tester, 10);

    expect(e.sessions.startCalls, [(machineId: 'm', agent: 'omp', cwd: '/home/dev/payments-api')]);
    expect(old.sent, isEmpty, reason: 'the word is not a prompt for the model');
    expect(tester.widget<AgentSessionScreen>(find.byType(AgentSessionScreen)).session.key, 'm/k2');
    expect(find.text('earlier prompt'), findsNothing);
    expect(
      find.descendant(of: find.byKey(toastKey), matching: find.textContaining('previous one is still on the board')),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 6));
    await e.tearDown(tester);
  });

  testWidgets('/new does the same', (tester) async {
    final old = _old();
    final e = await _open(tester, old);
    e.sessions.onStart = (_) async => _fresh();

    await _type(tester, '/new');
    await settleHistory(tester, 10);
    expect(e.sessions.startCalls, hasLength(1));
    expect(old.sent, isEmpty);
    await tester.pump(const Duration(seconds: 6));
    await e.tearDown(tester);
  });

  testWidgets('a word after it is an ordinary message', (tester) async {
    final old = _old();
    final e = await _open(tester, old);
    await _type(tester, '/new project plan');
    expect(e.sessions.startCalls, isEmpty);
    expect(old.sent, ['/new project plan']);
    await e.tearDown(tester);
  });

  testWidgets('an agent that advertises /clear is sent it, not replaced', (tester) async {
    final old = _old(commands: const [AcpCommand(name: 'clear', description: 'Clear the conversation')]);
    final e = await _open(tester, old);

    await _type(tester, '/clear');
    expect(e.sessions.startCalls, isEmpty);
    expect(old.sent, ['/clear']);
    await e.tearDown(tester);
  });

  testWidgets('a start that fails says why and gives the text back; this chat stays', (tester) async {
    final old = _old();
    final e = await _open(tester, old);
    e.sessions.onStart = (_) async => throw const AgentHostException('omp is not installed on devbox.');

    await _type(tester, '/clear');
    await settleHistory(tester, 5);

    expect(
      find.descendant(of: find.byKey(toastKey), matching: find.text('omp is not installed on devbox.')),
      findsOneWidget,
    );
    expect(find.text('earlier prompt'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text, '/clear');
    expect(old.sent, isEmpty);
    await tester.pump(const Duration(seconds: 6));
    await e.tearDown(tester);
  });
}
