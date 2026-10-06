import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/observed/observed_contracts.dart' show SubagentInfo;
import 'package:herdr_mobile/data/repositories/agent_session.dart' show SubagentEntry, SubagentState;
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/acp/subagents/subagent_run.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/permission_dock.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_bar.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_overview.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_overview_model.dart';
import 'package:herdr_mobile/ui/features/agent_session/status_line.dart';
import 'package:herdr_mobile/ui/features/agent_session/subagent_card.dart';
import 'package:herdr_mobile/ui/features/agent_session/subagent_format.dart';
import 'package:herdr_mobile/ui/features/agent_session/subagent_roster.dart';
import 'package:herdr_mobile/ui/features/agent_session/subagent_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_view.dart';

import '../acp/support/trace_state.dart';
import '../support/fake_agent_session.dart';
import '../support/subagent_fixtures.dart';
import '../support/turn_fixtures.dart';

// Subagents and the session overview on screen: the card in the work log,
// parallel groups, the roster, the
// drill-in (a conversation, or a summary), the origin line on the dock, the
// overview sheet and the context line of the bar. States come from the real
// reducer: the recorded Claude trace, and omp and Codex shapes from their
// sources (UNVERIFIED against a session).

Widget _app(Widget body, {double textScale = 1}) => MaterialApp(
  theme: AppTheme.light(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(body: body),
);

Future<void> _pump(WidgetTester tester, Widget app, {Size size = const Size(412, 892)}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _pumpTranscript(WidgetTester tester, FakeAgentSession session, {double textScale = 1}) => _pump(
  tester,
  _app(
    Column(
      children: [
        Expanded(child: TranscriptView(session: session)),
        PromptDock(session: session),
      ],
    ),
    textScale: textScale,
  ),
);

Finder _text(String s) => find.textContaining(s, findRichText: true);

void main() {
  tearDown(() => statusNow = DateTime.now);

  group('the line of a card', () {
    test('a Claude subagent: running, finished, failed, cancelled', () {
      final running = play([launch('t', type: 'Explore', status: 'in_progress'), childTool('c', 't')]).subagents.single;
      expect(toneOf(running, blocked: const {}, live: true), RunTone.running);
      expect(runLine(running, RunTone.running, now: at(43)), 'running 42s \u00b7 Grep \u00b7 1 tool');

      final done = play([launch('t', status: 'in_progress'), finished('t', seconds: 31, tools: 12)], active: false).subagents.single;
      expect(runLine(done, RunTone.done, now: at(60)), 'Explore \u00b7 done \u00b7 31s \u00b7 12 tools');

      final failed = play([launch('t', type: 'Explore', status: 'in_progress'), toolUpdate('t', status: 'failed')], active: false)
          .subagents
          .single;
      expect(toneOf(failed, blocked: const {}, live: true), RunTone.failed);
      expect(runLine(failed, RunTone.failed, now: at(30)), startsWith('Explore \u00b7 failed'));

      final cancelled = play([launch('t', status: 'in_progress')]).withCancelRequested(at: at(9)).subagents.single;
      expect(runLine(cancelled, toneOf(cancelled, blocked: const {}, live: true), now: at(30)), contains('cancelled'));
    });

    test('waiting for the person, and a link that went away', () {
      var s = play([launch('t', type: 'Explore', status: 'in_progress'), childTool('c', 't')]);
      s = s.withPending(PendingPermission(1, askFor('c')));
      final run = s.subagents.single;
      expect(blockedRunIds(s), {'t'});
      expect(toneOf(run, blocked: blockedRunIds(s), live: true), RunTone.waitingForYou);
      expect(runLine(run, RunTone.waitingForYou, now: at(30)), 'Waiting for you \u00b7 1 tool');
      expect(toneOf(run, blocked: blockedRunIds(s), live: false), RunTone.stale, reason: 'never says running for a dead link');
      expect(runLine(run, RunTone.stale, now: at(90)).startsWith('was running'), isTrue);
    });

    test('omp shows its percent and retry; codex has no elapsed it did not report', () {
      final omp = play(ompTask('call', [ompProgress(0, 'Alpha', 'running')])).subagents.single;
      expect(runLine(omp, RunTone.running, now: at(10)), contains('60%'));
      expect(runLine(omp, RunTone.running, now: at(10)), startsWith('running 9s'));
      final codex = play([codexSpawn('thread-paris', 'running')], start: 1).subagents.single;
      expect(codex.hasTranscript, isFalse);
    });

    test('figures: tokens and cost', () {
      expect([950, 1000, 12340, 123456, 1200000].map(formatTokens), ['950', '1k', '12k', '123k', '1.2M']);
      expect(formatCost(0.0512, 'USD'), '\$0.051');
      expect(formatCost(1.2345, 'USD'), '\$1.23');
      expect(formatCost(12, 'EUR'), '12.00 EUR');
      expect(formatCost(3), '3.00');
    });
  });

  group('groups and the roster', () {
    test('calls that follow each other are one group; a message between them splits it', () {
      final together = play([launch('a'), launch('b'), launch('c')]);
      final g = groupOf('a', together.items, together.subagents)!;
      expect(g.isGroup, isTrue);
      expect(g.toolCallIds, ['a', 'b', 'c']);
      expect(groupOf('c', together.items, together.subagents), same(g));

      final apart = play([launch('a'), mainText('ok, and another'), launch('b')]);
      expect(groupOf('a', apart.items, apart.subagents)!.isGroup, isFalse);
      expect(groupOf('b', apart.items, apart.subagents)!.isGroup, isFalse);
      expect(groupOf('zzz', apart.items, apart.subagents), isNull);
    });

    test('one omp call with two subagents is a group', () {
      final s = play(ompTask('call', [ompProgress(0, 'Alpha', 'running'), ompProgress(1, 'Beta', 'pending')]));
      final g = groupOf('call', s.items, s.subagents)!;
      expect(g.isGroup, isTrue);
      expect(groupTitle(g.runs, const {}), '2 subagents \u00b7 1 running \u00b7 1 starting');
    });

    test('group titles', () {
      var s = play([
        launch('a', status: 'in_progress'),
        launch('b', status: 'in_progress'),
        launch('c', status: 'in_progress'),
        finished('c'),
      ]);
      expect(groupTitle(s.subagents, const {}), '3 subagents \u00b7 2 running');
      expect(groupTitle(s.subagents, const {}, live: false), '3 subagents \u00b7 2 not updating');
      s = play([launch('a'), finished('a'), launch('b'), finished('b')], active: false);
      expect(groupTitle(s.subagents, const {}), '2 subagents \u00b7 all done');
    });

    test('roster: waiting first (the person\'s own before the not started), running, then finished with failures first', () {
      var s = play([
        launch('done', description: 'Done one', status: 'in_progress'),
        finished('done'),
        launch('failed', description: 'Failed one', status: 'in_progress'),
        toolUpdate('failed', status: 'failed'),
        launch('run', description: 'Running one', status: 'in_progress'),
        launch('ask', description: 'Asking one', status: 'in_progress'),
        childTool('askc', 'ask'),
        {...launch('new', description: 'Not started'), 'rawInput': <String, Object?>{}},
      ]);
      s = s.withPending(PendingPermission(1, askFor('askc')));
      final items = rosterOf(s.subagents, blocked: blockedRunIds(s), live: true);
      String name(RosterItem i) => switch (i) {
        RosterHeader(:final section, :final count) => '${section.title} $count',
        RosterEntry(:final run) => run.id,
      };
      expect(items.map(name).toList(), ['Waiting 2', 'ask', 'new', 'Running 1', 'run', 'Finished 2', 'failed', 'done']);
    });

    test('context warning: only from 85%, never without a window', () {
      expect(contextWarning(null), isNull);
      expect(contextWarning(const AcpUsage(used: 10, size: 0)), isNull);
      expect(contextWarning(const AcpUsage(used: 84, size: 100)), isNull);
      expect(contextWarning(const AcpUsage(used: 85, size: 100)), 85);
      expect(contextWarning(const AcpUsage(used: 182, size: 200)), 91);
      expect(contextWarning(const AcpUsage(used: 300, size: 200)), 100);
    });
  });

  group('the card in the work log', () {
    testWidgets('the recorded Claude trace: one card, the child\'s call stays out of the transcript', (tester) async {
      final session = FakeAgentSession(state: stateOfTrace('claude', 'subagent'));
      await _pumpTranscript(tester, session);
      await tester.tap(_text('Worked'));
      await tester.pumpAndSettle();

      expect(find.text('Run ls command and report filenames'), findsOneWidget);
      expect(_text('general-purpose \u00b7 done \u00b7 6s \u00b7 1 tool'), findsOneWidget);
      expect(_text('ls -1 /tmp/scratch'), findsNothing, reason: 'the child\'s own Bash call is not in the parent transcript');
      expect(find.byType(SubagentCard), findsOneWidget);
    });

    testWidgets('running: the seconds move with the clock, and the clock stops with the run', (tester) async {
      statusNow = () => at(43);
      final session = FakeAgentSession(
        state: play([launch('t', type: 'Explore', status: 'in_progress'), childTool('c', 't')]),
      );
      await _pumpTranscript(tester, session);
      expect(_text('running 42s \u00b7 Grep \u00b7 1 tool'), findsOneWidget);
      final leases = secondsClock.leases;
      expect(leases, greaterThan(0));

      statusNow = () => at(45);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 100));
      expect(_text('running 44s'), findsOneWidget);

      session.update((s) => s.apply(parse(finished('t')), at: at(50)).withTurnEnded(StopReason.endTurn, at: at(51)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(secondsClock.leases, lessThan(leases), reason: 'a card that is not running holds no clock');
    });

    testWidgets('failed: the card breaks out of the fold, in the danger tone, with why', (tester) async {
      final session = FakeAgentSession(
        state: play([launch('t', type: 'Explore', status: 'in_progress'), toolUpdate('t', status: 'failed')], active: false),
      );
      await _pumpTranscript(tester, session);
      expect(_text('Worked'), findsOneWidget);
      expect(_text('Explore \u00b7 failed'), findsOneWidget, reason: 'not folded away');
    });

    testWidgets('waiting for you: the card says so, and the dock names who asked', (tester) async {
      var s = play([launch('t', type: 'Explore', status: 'in_progress'), childTool('c', 't')]);
      s = s.withPending(PendingPermission(1, askFor('c')));
      final session = FakeAgentSession(state: s);
      await _pumpTranscript(tester, session);
      expect(_text('Waiting for you \u00b7 1 tool'), findsOneWidget);
      expect(find.text('From subagent: Explore'), findsOneWidget);
      expect(find.text('rtk ls -1 /tmp/scratch'), findsWidgets, reason: 'the command is still on the dock');
    });

    testWidgets('no origin, no line', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(items: [toolItem('x')], pending: [PendingPermission(1, permissionRequest())]),
      );
      await _pumpTranscript(tester, session);
      expect(_text('From subagent'), findsNothing);
    });

    testWidgets('three in parallel are grouped under one header', (tester) async {
      final session = FakeAgentSession(
        state: play([
          launch('a', description: 'First', status: 'in_progress'),
          launch('b', description: 'Second', status: 'in_progress'),
          launch('c', description: 'Third', status: 'in_progress'),
          finished('c'),
        ]),
      );
      await _pumpTranscript(tester, session);
      expect(find.text('3 subagents \u00b7 2 running'), findsOneWidget);
      expect(find.byType(SubagentCard), findsNWidgets(3));
      expect(find.text('First'), findsOneWidget);
      expect(find.text('Second'), findsOneWidget);
      expect(find.text('Third'), findsOneWidget);
    });

    testWidgets('a card opens to what it was asked and what it handed back; the call stays reachable', (tester) async {
      final session = FakeAgentSession(
        state: play([
          launch('t', type: 'Explore', prompt: 'Find where the locale is lowercased.', status: 'in_progress'),
          finished('t', text: '**Found** it in `parse.dart`.'),
        ]),
      );
      await _pumpTranscript(tester, session);
      expect(find.text('Find where the locale is lowercased.'), findsNothing);
      await tester.tap(find.text('Explore the parser'));
      await tester.pumpAndSettle();
      expect(find.text('Find where the locale is lowercased.'), findsOneWidget);
      expect(_text('Found it in parse.dart.'), findsOneWidget, reason: 'the result as Markdown');
      expect(find.text('Open conversation'), findsOneWidget);
      expect(find.text('Task'), findsNothing);
      await tester.tap(find.text('Call details'));
      await tester.pumpAndSettle();
      expect(find.text('Task'), findsOneWidget, reason: 'the tool call itself, with its body');
    });

    testWidgets('an open card stays open when it scrolls away and back', (tester) async {
      final session = FakeAgentSession(
        state: play(
          [launch('t', status: 'in_progress'), finished('t'), for (var i = 0; i < 1; i++) mainText('answer')],
          from: stateWith(items: [for (var i = 0; i < 40; i++) ...[userAt('u$i', 'q$i', i), agentAt('a$i', 'a$i', i)]]),
        ),
      );
      await _pumpTranscript(tester, session);
      await tester.tap(find.text('Explore the parser'));
      await tester.pumpAndSettle();
      expect(find.text('Open conversation'), findsOneWidget);
      await tester.fling(find.byType(TranscriptView), const Offset(0, 600), 6000);
      await tester.pumpAndSettle();
      await tester.fling(find.byType(TranscriptView), const Offset(0, -600), 6000);
      await tester.pumpAndSettle();
      expect(find.text('Open conversation'), findsOneWidget);
    });

    testWidgets('no card, no clock', (tester) async {
      final session = FakeAgentSession(state: stateWith(items: [userAt('u', 'hi', 0), agentAt('a', 'hello', 1)]));
      final before = secondsClock.leases;
      await _pumpTranscript(tester, session);
      expect(secondsClock.leases, before);
      expect(find.byType(SubagentCard), findsNothing);
    });
  });

  group('omp and Codex: a summary, said once', () {
    testWidgets('omp: the card opens to a summary that is not a chat', (tester) async {
      statusNow = () => at(30);
      final session = FakeAgentSession(
        state: play(ompTask('call', [ompProgress(0, 'Alpha', 'running')])),
      );
      await _pumpTranscript(tester, session);
      expect(_text('60%'), findsOneWidget);
      await tester.tap(find.text('Look into Alpha'));
      await tester.pumpAndSettle();
      expect(find.text('Open conversation'), findsNothing);
      expect(find.text('Summary only'), findsNothing, reason: 'said in the detail, not on the card');
      await tester.tap(find.text('Open summary'));
      await tester.pumpAndSettle();

      expect(find.byType(SubagentSummaryBody), findsOneWidget);
      expect(_text('Summary only.'), findsOneWidget);
      expect(find.byType(PinnedPrompt), findsNothing, reason: 'no conversation to pin a prompt over');
      expect(_text('Assignment for Alpha'), findsOneWidget);
      expect(_text('line two of the output'), findsOneWidget);
      expect(find.text('Recent output'), findsOneWidget);
      expect(_text('12k'), findsOneWidget, reason: 'tokens it reported');
      expect(_text('\$0.051'), findsOneWidget, reason: 'cost it reported');
      expect(find.byType(TranscriptView), findsNothing, reason: 'the detail is no chat: nothing but the main transcript, under it');
      expect(find.byType(TranscriptView, skipOffstage: false), findsOneWidget);
    });

    testWidgets('omp failed and codex: why it stopped, and the note', (tester) async {
      final failed = play(
        ompTask(
          'call',
          [ompProgress(0, 'Alpha', 'failed')],
          results: [
            {'index': 0, 'id': 'Alpha', 'agent': 'explore', 'exitCode': 1, 'output': '', 'error': 'Provider quota exhausted', 'durationMs': 9000},
          ],
          status: 'completed',
        ),
        active: false,
      );
      final session = FakeAgentSession(state: failed);
      await _pumpTranscript(tester, session);
      expect(_text('Provider quota exhausted'), findsOneWidget, reason: 'on the card, in a failed run, not folded');
      expect(failed.subagents.single.status, SubagentStatus.failed);

      final codex = FakeAgentSession(state: play([codexSpawn('thread-paris', 'running', message: 'Checking weather')]));
      await _pumpTranscript(tester, codex);
      expect(find.text('Find the current weather in Paris.'), findsOneWidget);
      await tester.tap(find.text('Find the current weather in Paris.'));
      await tester.pumpAndSettle();
      expect(_text('Checking weather'), findsOneWidget);
      expect(find.text('Open summary'), findsOneWidget);
    });
  });

  group('drill-in', () {
    testWidgets('a conversation: the prompt pinned, the child\'s own transcript, back to the same place', (tester) async {
      final session = FakeAgentSession(
        state: play(
          [
            launch('t', type: 'Explore', prompt: 'Find where the locale is lowercased.', status: 'in_progress'),
            childTool('c', 't'),
            childText('t', 'Looking at parser.dart now.'),
          ],
          from: stateWith(items: [for (var i = 0; i < 40; i++) ...[userAt('u$i', 'q$i', i), agentAt('a$i', 'a$i', i)]]),
        ),
      );
      await _pumpTranscript(tester, session);
      await tester.tap(find.text('Explore the parser'));
      await tester.pumpAndSettle();
      final main = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      final where = main.pixels;
      expect(where, greaterThan(0), reason: 'a long transcript, the card at its end');
      await tester.tap(find.text('Open conversation'));
      await tester.pumpAndSettle();

      expect(find.byType(SubagentRunScreen), findsOneWidget);
      expect(find.text('Asked to'), findsWidgets);
      expect(find.text('Find where the locale is lowercased.'), findsWidgets);
      expect(_text('Looking at parser.dart now.'), findsOneWidget, reason: 'the child\'s own words');
      expect(_text('running'), findsWidgets, reason: 'the state strip');
      expect(find.byType(TranscriptView), findsOneWidget, reason: 'the child\'s own; the main one is under it');
      expect(find.byType(TranscriptView, skipOffstage: false), findsNWidgets(2));
      expect(find.byType(TextField), findsNothing, reason: 'no composer');

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(SubagentRunScreen), findsNothing);
      expect(tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels, where);
    });

    testWidgets('the child\'s words arrive while the screen is open', (tester) async {
      final session = FakeAgentSession(
        state: play([launch('t', status: 'in_progress'), childTool('c', 't'), childText('t', 'First part.')]),
      );
      await _pumpTranscript(tester, session);
      await tester.tap(find.text('Explore the parser'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open conversation'));
      await tester.pumpAndSettle();
      session.update((s) => s.apply(parse(childText('t', ' Second part.')), at: at(20)));
      session.state.flushSubagentLive();
      await tester.pumpAndSettle();
      expect(_text('First part. Second part.'), findsOneWidget);
    });

    testWidgets('the child\'s request is answered from its own screen', (tester) async {
      var s = play([launch('t', type: 'Explore', status: 'in_progress'), childTool('c', 't')]);
      s = s.withPending(PendingPermission(7, askFor('c')));
      final session = FakeAgentSession(state: s);
      await _pump(tester, _app(SubagentRunScreen(session: session, runId: 't')));
      expect(find.text('From subagent: Explore'), findsOneWidget);
      expect(find.text('Yes'), findsOneWidget);
    });

    testWidgets('a subagent that is gone says so', (tester) async {
      final session = FakeAgentSession(state: stateWith());
      await _pump(tester, _app(SubagentRunScreen(session: session, runId: 'nope')));
      expect(find.text('Subagent gone'), findsOneWidget);
    });
  });

  group('the chip and the roster', () {
    FakeAgentSession many() {
      final updates = <Json>[];
      for (var i = 0; i < 25; i++) {
        updates.add(launch('r$i', description: 'Subagent number $i', type: 'Explore', status: 'in_progress'));
        if (i >= 4) updates.add(i % 7 == 0 ? toolUpdate('r$i', status: 'failed') : finished('r$i', seconds: 20 + i, tools: i));
      }
      updates.add(childTool('askc', 'r0'));
      return FakeAgentSession(state: play(updates).withPending(PendingPermission(1, askFor('askc'))));
    }

    testWidgets('the chip counts what needs you first', (tester) async {
      final session = many();
      await _pump(tester, _app(SubagentsChip(session: session)));
      expect(find.text('1 waiting for you'), findsOneWidget);
    });

    testWidgets('an ACP session with a few runs: the chip says running, the roster groups them', (tester) async {
      final session = FakeAgentSession(
        state: play([launch('a', description: 'Alpha', status: 'in_progress'), launch('b', description: 'Beta', status: 'in_progress'), finished('b')]),
      );
      await _pump(tester, _app(SubagentsChip(session: session)));
      expect(find.text('1 of 2 running'), findsOneWidget);
      await tester.tap(find.text('1 of 2 running'));
      await tester.pumpAndSettle();
      expect(find.text('Subagents \u00b7 2'), findsOneWidget);
      expect(find.text('Running \u00b7 1'), findsOneWidget);
      expect(find.text('Finished \u00b7 1'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
    });

    testWidgets('25 runs: grouped, virtualized, and a row opens the run', (tester) async {
      final session = many();
      await _pump(tester, _app(SubagentsChip(session: session)));
      await tester.tap(find.text('1 waiting for you'));
      await tester.pumpAndSettle();
      expect(find.text('Waiting \u00b7 1'), findsOneWidget);
      final waiting = tester.getTopLeft(find.text('Waiting \u00b7 1')).dy;
      expect(tester.getTopLeft(find.text('Running \u00b7 3')).dy, greaterThan(waiting));
      expect(find.byType(SubagentCard).evaluate().length, lessThan(25), reason: 'lazy');
      expect(find.text('Subagent number 0'), findsOneWidget, reason: 'the one that needs you is first');

      await tester.tap(find.text('Subagent number 0'));
      await tester.pumpAndSettle();
      expect(find.byType(SubagentRunScreen), findsOneWidget);
    });

    testWidgets('an observed session keeps its own roster', (tester) async {
      final session = FakeAgentSession()
        ..observed = true
        ..roster = const [
          SubagentEntry(info: SubagentInfo(name: 'PongReply', assignment: 'Reply pong', toolCount: 2, recentTools: ['read']), state: SubagentState.running),
          SubagentEntry(info: SubagentInfo(name: 'Other'), state: SubagentState.finished),
        ];
      await _pump(tester, _app(SubagentsChip(session: session)));
      expect(find.text('1 of 2 running'), findsOneWidget);
      await tester.tap(find.text('1 of 2 running'));
      await tester.pumpAndSettle();
      expect(find.text('PongReply'), findsOneWidget);
      expect(find.text('Reply pong'), findsOneWidget);
      expect(session.rosterWatchers, 1, reason: 'the artifact folder is watched while the sheet is open');
      expect(find.byType(SubagentCard), findsNothing);
    });

    testWidgets('no subagents, no chip', (tester) async {
      await _pump(tester, _app(SubagentsChip(session: FakeAgentSession())));
      expect(find.byType(Chip), findsNothing);
      expect(find.textContaining('subagent'), findsNothing);
    });
  });

  group('the overview', () {
    Future<void> open(WidgetTester tester, FakeAgentSession session, {double textScale = 1}) async {
      await _pump(
        tester,
        _app(Builder(builder: (context) => GestureDetector(onTap: () => showSessionOverview(context, session), child: const Text('open'))), textScale: textScale),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    AgentSessionState rich() => overviewState();

    testWidgets('everything present', (tester) async {
      await open(tester, FakeAgentSession(state: rich()));
      expect(find.text('Session overview'), findsOneWidget);
      expect(_text('Goal'), findsOneWidget);
      expect(_text('Plan'), findsOneWidget);
      expect(_text('1 of 3 done'), findsOneWidget);
      expect(find.text('Fix the Hà Nội locale bug in the parser module and add a test'), findsOneWidget, reason: 'the step in progress');
      expect(find.text('2 subagents \u00b7 1 running'), findsOneWidget);
      expect(_text('Changed'), findsOneWidget);
      expect(_text('Commands'), findsOneWidget);
      expect(_text('1 failed'), findsWidgets);
      expect(_text('exit 1'), findsOneWidget);
      expect(_text('Mode and model'), findsOneWidget);
      expect(_text('Bypass Permissions'), findsOneWidget);
      expect(_text('182k of 200k tokens \u00b7 91% of context'), findsOneWidget);
      expect(_text('\$1.23'), findsOneWidget);
      expect(_text('Last turn'), findsOneWidget);
      expect(_text('Waiting for you'), findsOneWidget);
      expect(_text('Run flutter test'), findsOneWidget);
    });

    testWidgets('almost nothing: only what exists', (tester) async {
      await open(tester, FakeAgentSession(state: stateWith(items: [userAt('u', 'Say hi', 0)])));
      expect(_text('Goal'), findsOneWidget);
      for (final absent in ['Plan', 'Changed', 'Commands', 'Subagents', 'Mode and model', 'Context and cost', 'Waiting for you']) {
        expect(_text(absent), findsNothing, reason: absent);
      }
    });

    testWidgets('the parts from the transcript: files across turns, commands failures first', (tester) async {
      final model = overviewOf(richTurn());
      expect(model.goal, isNotNull);
      expect(model.files, isNotEmpty);
      expect(model.commands.length, lessThanOrEqualTo(overviewCommands));
      expect(model.commands.first.failed, isTrue, reason: 'failures first');
      expect(model.failedCommands, 1);
      expect(identical(overviewOf(richTurn()), overviewOf(richTurn())), isFalse);
      final items = richTurn();
      expect(identical(overviewOf(items), overviewOf(items)), isTrue, reason: 'memoized per transcript list');
    });

    testWidgets('a file opens its diff in place', (tester) async {
      await open(tester, FakeAgentSession(state: rich()));
      final file = find.textContaining('parse.dart');
      expect(file, findsWidgets);
      await tester.tap(file.first);
      await tester.pumpAndSettle();
      expect(find.byType(Scrollable), findsWidgets);
    });

    testWidgets('worst case at the largest text on a narrow screen: nothing overflows', (tester) async {
      await _pump(
        tester,
        _app(
          Builder(builder: (context) => GestureDetector(onTap: () => showSessionOverview(context, FakeAgentSession(state: rich())), child: const Text('open'))),
          textScale: 1.6,
        ),
        size: const Size(320, 640),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('the bar', () {
    FakeAgentSession withContext(int used, {int size = 100}) => FakeAgentSession(
      state: const AgentSessionState('s1').apply(parse({'sessionUpdate': 'usage_update', 'used': used, 'size': size})),
    );

    testWidgets('the context line shows from 85% and only then', (tester) async {
      await _pump(tester, _app(SessionBar(session: withContext(84))));
      expect(_text('Context'), findsNothing);
      await _pump(tester, _app(SessionBar(session: withContext(91))));
      expect(find.text('Context 91%'), findsOneWidget);
      await _pump(tester, _app(SessionBar(session: FakeAgentSession())));
      expect(_text('Context'), findsNothing, reason: 'no usage, nothing');
    });

    testWidgets('a tap on the title opens the overview; the options sheet has it too', (tester) async {
      final session = withContext(40);
      await _pump(tester, _app(SessionBar(session: session)));
      await tester.tap(find.text('payments-api'));
      await tester.pumpAndSettle();
      expect(find.text('Session overview'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('Session overview'), findsNothing);

      await tester.tap(find.byTooltip('Session options'));
      await tester.pumpAndSettle();
      expect(find.text('Session overview'), findsOneWidget);
      await tester.tap(find.text('Session overview'));
      await tester.pumpAndSettle();
      expect(find.text('Session overview'), findsOneWidget, reason: 'the sheet that replaced the options');
      expect(find.text('Duplicate'), findsNothing);
    });
  });
}
