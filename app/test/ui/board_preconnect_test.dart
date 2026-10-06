// The Agents board and the pre-connect: a finger going down on a session row
// starts the attach before the tap completes, a finger that slides away gives
// the channel back, and a tap opens the screen on that very attach.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/agent_session_repository.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agents/agent_session_rows.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../support/fake_agent_host.dart';
import 'board_support.dart';
import 'ui_harness.dart';

Future<(FakeAgentHost, Future<void> Function())> _board(WidgetTester tester) async {
  tester.view
    ..physicalSize = const Size(720, 4800)
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final h = await BoardHarness.create([
    (
      profile: MachineProfile(id: 'a', label: 'studio-mac', host: 'a.example', username: 'dev'),
      snapshot: snapshotWith(const [], title: (id) => id),
    ),
  ]);
  final host = FakeAgentHost()..add(id: 'k1', title: 'Fix login', cwd: '/home/u/api', sessionId: 's1');
  final repo = AgentSessionRepository(
    fleet: h.fleet,
    hostFor: (_) => host,
    recentAttached: 0, // nothing is attached by the board's own rule
  );
  await tester.pumpWidget(
    MultiProvider(
      providers: [...h.providers, ListenableProvider<AgentSessions>.value(value: repo), attentionSetProvider()],
      child: MaterialApp(theme: AppTheme.dark(), home: const HomeShell()),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return (
    host,
    () async {
      await tester.pumpWidget(const SizedBox());
      repo.dispose();
      h.dispose();
    },
  );
}

void main() {
  final row = find.widgetWithText(AgentSessionRow, 'Fix login');

  testWidgets('a finger down attaches at once; the tap opens the screen on that attach; leaving gives it back', (tester) async {
    final (host, done) = await _board(tester);
    expect(row, findsOneWidget);
    expect(host.openLinks, 0, reason: 'nothing is attached before a finger touches the row');
    final calls = host.attachCalls;

    final gesture = await tester.startGesture(tester.getCenter(row));
    await tester.pump(const Duration(milliseconds: 50));
    expect(host.attachCalls, calls + 1, reason: 'attaching while the finger is still down');
    expect(host.openLinks, 1);

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AgentSessionScreen), findsOneWidget);
    expect(host.attachCalls, calls + 1, reason: 'the screen used the attach the finger started');
    expect(host.openLinks, 1);

    // Back to the board: the screen lets go, nothing else holds the channel.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.pop();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AgentSessionScreen), findsNothing);
    expect(host.openLinks, 0);
    await done();
  });

  testWidgets('a finger that slides away (a scroll) gives the channel back and opens nothing', (tester) async {
    final (host, done) = await _board(tester);
    final gesture = await tester.startGesture(tester.getCenter(row));
    await tester.pump(const Duration(milliseconds: 50));
    expect(host.openLinks, 1);
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump(const Duration(milliseconds: 50));
    expect(host.openLinks, 0, reason: 'past the touch slop: it is a scroll');
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(AgentSessionScreen), findsNothing);
    expect(host.openLinks, 0);
    await done();
  });
}
