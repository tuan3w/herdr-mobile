// The subagent roster of an observed session: what runs first, the finished
// ones capped, a held stop per running row and one Stop all, and the words that
// say the log is partly read.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/background/background_work.dart';
import 'package:herdr_mobile/data/observed/observed_contracts.dart' show SubagentInfo;
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agent_session/observed_roster.dart';
import 'package:herdr_mobile/ui/features/agent_session/subagent_roster.dart';

import '../support/fake_agent_session.dart';
import '../support/shot.dart' show loadAppFonts;
import 'hold_support.dart';

SubagentEntry _e(String name, SubagentState state, {int tools = 0, String assignment = ''}) => SubagentEntry(
  info: SubagentInfo(name: name, assignment: assignment, toolCount: tools),
  state: state,
);

BackgroundTask _task(String id, {StopRoute stop = StopRoute.message}) =>
    BackgroundTask(id: id, kind: BackgroundKind.agent, status: BackgroundStatus.running, title: id, stop: stop);

/// 2 waiting, 6 running, 3 failed, 55 finished: a swarm as the log names it,
/// oldest first.
List<SubagentEntry> _swarm() => [
  for (var i = 0; i < 55; i++) _e('Rev${i.toString().padLeft(2, '0')}', SubagentState.finished, tools: i),
  for (var i = 0; i < 3; i++) _e('Bad$i', SubagentState.failed),
  for (var i = 0; i < 6; i++)
    _e('SecFix$i', SubagentState.running, tools: 3 + i, assignment: 'Sửa lỗi bảo mật ${'rất dài ' * 30}'),
  _e('Next0', SubagentState.waiting),
  _e('Next1', SubagentState.waiting),
];

FakeAgentSession _session(List<SubagentEntry> roster, {List<BackgroundTask> tasks = const []}) => FakeAgentSession()
  ..observed = true
  ..paneId = 'p1'
  ..roster = roster
  ..backgroundWork = BackgroundWork(tasks: tasks);

Future<void> _openRoster(WidgetTester tester, FakeAgentSession session, {Size size = const Size(412, 892)}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: SubagentsChip(session: session)),
    ),
  );
  await tester.pump(Dwell.tapGuard);
}

Future<void> _tapChip(WidgetTester tester) async {
  await tester.tap(find.byType(SubagentsChip));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(loadAppFonts);

  test('sections: waiting and running as they came, done with the failed first, each newest first', () {
    final s = rosterSections([
      _e('a', SubagentState.running),
      _e('b', SubagentState.finished),
      _e('c', SubagentState.failed),
      _e('d', SubagentState.waiting),
      _e('e', SubagentState.finished),
      _e('f', SubagentState.failed),
    ]);
    expect(s.waiting.map((e) => e.name), ['d']);
    expect(s.running.map((e) => e.name), ['a']);
    expect(s.done.map((e) => e.name), ['f', 'c', 'e', 'b']);
  });

  testWidgets('a link that is down claims nothing is running', (tester) async {
    final session = _session(_swarm());
    await _openRoster(tester, session);
    session.setLink(AgentLink.reconnecting);
    await tester.pump();
    expect(find.text('6 running'), findsNothing);
    expect(find.text('66 subagents'), findsOneWidget);
  });
  group('the chip', () {
    testWidgets('says what runs; the total is one tap down', (tester) async {
      await _openRoster(tester, _session(_swarm()));
      expect(find.text('6 running'), findsOneWidget);
    });

    testWidgets('nothing runs: the count of the subagents, with a + while only the end of the log is read', (
      tester,
    ) async {
      final done = [for (var i = 0; i < 66; i++) _e('R$i', SubagentState.finished)];
      final session = _session(done);
      await _openRoster(tester, session);
      expect(find.text('66 subagents'), findsOneWidget);
      session.setEarlier(EarlierHistory.available);
      await tester.pump();
      expect(find.text('66+ subagents'), findsOneWidget);
    });
  });

  group('the sheet', () {
    testWidgets('a swarm: Waiting, Running, then Done with 8 shown and the failed first', (tester) async {
      final session = _session(_swarm());
      await _openRoster(tester, session);
      await _tapChip(tester);
      expect(find.text('Subagents · 66'), findsOneWidget);
      final running = tester.getTopLeft(find.text('Running · 6')).dy;
      expect(
        running,
        lessThan(tester.getTopLeft(find.text('SecFix0')).dy),
        reason: 'running first: the few that run now are not below the waiting',
      );
      expect(session.rosterWatchers, 1);

      await tester.drag(find.byType(ListView).last, const Offset(0, -2000));
      await tester.pump();
      expect(find.text('Waiting · 2'), findsOneWidget);
      expect(find.text('Done · 58'), findsOneWidget);
      expect(find.text('Bad2'), findsOneWidget, reason: 'the failed ones lead the done list');
      expect(find.text('Rev46'), findsNothing, reason: 'the ninth done row is behind Show more');
      expect(find.text('Show 50 more'), findsOneWidget);

      await tester.tap(find.text('Show 50 more'));
      await tester.pump();
      await tester.drag(find.byType(ListView).last, const Offset(0, -6000));
      await tester.pump();
      expect(find.text('Show less'), findsOneWidget);
    });

    testWidgets('a log read in part says so and offers the rest', (tester) async {
      final session = _session(_swarm())..setEarlier(EarlierHistory.available);
      await _openRoster(tester, session);
      await _tapChip(tester);
      expect(find.text('Subagents · 66+'), findsOneWidget);
      await tester.drag(find.byType(ListView).last, const Offset(0, -4000));
      await tester.pump();
      expect(find.text('Subagents from earlier in this chat are not listed.'), findsOneWidget);
      await tester.tap(find.text('Read earlier messages'));
      expect(session.loadEarlierCalls, 1);
    });

    testWidgets('a held Stop asks for that subagent only', (tester) async {
      final roster = [for (var i = 0; i < 3; i++) _e('Sub$i', SubagentState.running)];
      final session = _session(roster, tasks: [for (var i = 0; i < 3; i++) _task('Sub$i')]);
      await _openRoster(tester, session);
      await _tapChip(tester);
      expect(find.text('Ask to stop'), findsNWidgets(3));
      await holdFor(tester, find.text('Ask to stop').first);
      expect(session.stopped, ['Sub0']);
    });

    testWidgets('Stop all stops subagents, in one request', (tester) async {
      final roster = [for (var i = 0; i < 3; i++) _e('Sub$i', SubagentState.running)];
      final session = _session(roster, tasks: [for (var i = 0; i < 3; i++) _task('Sub$i')]);
      await _openRoster(tester, session);
      await _tapChip(tester);
      await holdFor(tester, find.text('Stop all'));
      expect(session.stopAllCount, 1);
      expect(session.stopAllOnly, [BackgroundKind.agent]);
    });

    testWidgets('a subagent the log lists no task for has no stop control; one task alone has no Stop all', (
      tester,
    ) async {
      final session = _session([_e('A', SubagentState.running), _e('B', SubagentState.running)], tasks: [_task('A')]);
      await _openRoster(tester, session);
      await _tapChip(tester);
      expect(find.text('Ask to stop'), findsOneWidget);
      expect(find.text('Stop all'), findsNothing);
    });

    testWidgets('a link that is down: no actions, and the words are in the past', (tester) async {
      final roster = [for (var i = 0; i < 3; i++) _e('Sub$i', SubagentState.running)];
      final session = _session(roster, tasks: [for (var i = 0; i < 3; i++) _task('Sub$i')]);
      await _openRoster(tester, session);
      await _tapChip(tester);
      session.setLink(AgentLink.reconnecting);
      await tester.pump();
      expect(find.text('Ask to stop'), findsNothing);
      expect(find.text('Stop all'), findsNothing);
      expect(find.text('Not connected. This is the last known list.'), findsOneWidget);
      expect(find.text('Was running'), findsNWidgets(3));
      expect(find.text('Was running · 3'), findsOneWidget, reason: 'the header too');
    });
  });
}
