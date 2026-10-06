// Agent sessions on the Agents board: in the same status sections as the
// terminal agents (so the sections never trade places), one-line rows, the
// tab badge and the pill, and the sections' behaviour at the extremes.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/session_state.dart' show AgentPhase;
import 'package:herdr_mobile/data/models/herdr_models.dart' show AgentStatus;
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/agent_session_repository.dart';
import 'package:herdr_mobile/data/repositories/attention_set.dart';
import 'package:herdr_mobile/ui/core/chrome.dart';
import 'package:herdr_mobile/ui/core/controls.dart' show AppChip;
import 'package:herdr_mobile/ui/core/rows.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agents/agent_session_rows.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../support/fake_agent_host.dart';
import 'board_support.dart';
import 'ui_harness.dart';

const _tall = 2400.0;

Pane _pane(int i, String status) => (id: 'w1:p$i', ws: 'w1', agent: 'claude', status: status);

class _Env {
  _Env(this.h, this.hosts);

  final BoardHarness h;
  final Map<String, FakeAgentHost> hosts;

  /// Created by `_pump`, after the test seeded the host: a machine that is
  /// online when the repository starts is listed at once, so keepers added
  /// later would only show at the next refresh.
  late final AgentSessionRepository repo;

  FakeAgentHost get host => hosts['a']!;
}

/// One machine, `studio-mac`, with [panes] as terminal agents and the agent
/// session repository on top of its fleet.
Future<_Env> _env({List<Pane> panes = const []}) async {
  final h = await BoardHarness.create([
    (
      profile: MachineProfile(id: 'a', label: 'studio-mac', host: 'a.example', username: 'dev'),
      snapshot: snapshotWith(panes, title: (id) => 'terminal ${id.split('p').last}'),
    ),
  ]);
  return _Env(h, {'a': FakeAgentHost()});
}

Future<void> _pump(
  WidgetTester tester,
  _Env e, {
  double width = 360,
  double height = _tall,
  double textScale = 1,
}) async {
  tester.view
    ..physicalSize = Size(width, height) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  e.repo = AgentSessionRepository(fleet: e.h.fleet, hostFor: (c) => e.hosts.putIfAbsent(c.profile.id, FakeAgentHost.new));
  await tester.pumpWidget(
    MultiProvider(
      providers: [...e.h.providers, ListenableProvider<AgentSessions>.value(value: e.repo), attentionSetProvider()],
      child: MaterialApp(
        theme: AppTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const HomeShell(),
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester, [int steps = 6]) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _teardown(WidgetTester tester, _Env e) async {
  await tester.pumpWidget(const SizedBox());
  e.repo.dispose();
  e.h.dispose();
}

Finder _section(String label) => find.byWidgetPredicate((w) => w is SectionLabel && w.label == label);

Finder _row(String title) => find.widgetWithText(AgentSessionRow, title);

double _top(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

String _badge(WidgetTester tester) => tester.getSemantics(find.byKey(FloatingTabBar.tabKey('Agents'))).label;

/// Sessions whose finished turn nobody looked at.
int _toReview(_Env e) => e.repo.sessions.where(AttentionSet.sessionToReview).length;

/// What the Done header counts (0 when there is no Done section).
int _doneCount(WidgetTester tester) {
  final done = _section('Done');
  return done.evaluate().isEmpty ? 0 : tester.widget<SectionLabel>(done).count ?? 0;
}

void main() {
  group('the sections', () {
    testWidgets('sessions sit in the status sections with the terminal agents, as one-line rows', (tester) async {
      final e = await _env(panes: [_pane(1, 'working')]);
      e.host
        ..add(id: 'k1', title: 'Fix login', cwd: '/home/u/api')
        ..add(id: 'k2', title: 'Refactor billing', agent: 'claude', cwd: '/home/u/billing');
      await _pump(tester, e);
      e.host.keepers['k2']!.turn = Completer<String>();
      unawaited(e.repo.byKey('a/k2')!.send('go'));
      await _settle(tester);

      expect(_section('Agent sessions'), findsNothing, reason: 'one place per status, whatever started the agent');
      expect(tester.widget<SectionLabel>(_section('Working')).count, 2, reason: 'the pane and the session');
      expect(tester.widget<SectionLabel>(_section('Idle')).count, 1);
      expect(_row('Fix login'), findsOneWidget);
      expect(find.descendant(of: _row('Fix login'), matching: find.text('omp · studio-mac · api')), findsOneWidget);
      expect(find.descendant(of: _row('Refactor billing'), matching: find.text('Claude Code · studio-mac · billing')), findsOneWidget);
      expect(find.descendant(of: _row('Refactor billing'), matching: find.text('working <1m')), findsOneWidget);
      expect(find.descendant(of: _row('Fix login'), matching: find.text('idle <1m')), findsOneWidget);
      expect(_top(tester, _row('Refactor billing')), lessThan(_top(tester, _section('Idle'))), reason: 'working before idle');
      expect(_top(tester, _row('Fix login')), greaterThan(_top(tester, _section('Idle'))));
      await _teardown(tester, e);
    });

    testWidgets('a session that starts waiting joins Needs you after those waiting longer: nothing above moves', (tester) async {
      final e = await _env(panes: [_pane(1, 'working'), _pane(2, 'working')]);
      final keeper = e.host.add(id: 'k1', title: 'Deploy');
      await _pump(tester, e);
      await e.h.changeStatuses(
        tester,
        'a',
        [_pane(1, 'blocked'), _pane(2, 'working')],
        ago: const Duration(minutes: 5),
        title: (id) => 'terminal ${id.split('p').last}',
      );
      final card = find.text('terminal 1');
      final before = _top(tester, card);
      final header = _top(tester, _section('Needs you'));

      keeper.askPermission(command: 'npm test -- --coverage\n  --watchAll=false');
      await _settle(tester);

      expect(_top(tester, _section('Needs you')), header, reason: 'no section jumps above the terminal cards');
      expect(_top(tester, card), before, reason: 'the card that waited longer keeps its place under the thumb');
      expect(_top(tester, _row('Deploy')), greaterThan(before), reason: 'the newer wait comes after it');
      expect(_top(tester, _row('Deploy')), lessThan(_top(tester, _section('Working'))), reason: 'inside Needs you');
      expect(tester.widget<SectionLabel>(_section('Needs you')).count, 2);
      final row = _row('Deploy');
      expect(find.descendant(of: row, matching: find.text('npm test -- --coverage --watchAll=false')), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('needs you <1m')), findsOneWidget);
      expect(find.text('Allow'), findsNothing, reason: 'answers are given inside the session');
      expect(find.text('2 need you'), findsOneWidget, reason: 'the pill counts it');
      await _teardown(tester, e);
    });

    testWidgets('a question shows its message', (tester) async {
      final e = await _env();
      final keeper = e.host.add(id: 'k1', title: 'Plan');
      await _pump(tester, e);
      keeper.askQuestion(message: 'Which approach do you prefer?');
      await _settle(tester);

      expect(find.descendant(of: _row('Plan'), matching: find.text('Which approach do you prefer?')), findsOneWidget);
      await _teardown(tester, e);
    });

    testWidgets('the tab badge counts what needs you, panes and sessions; the pill adds what is to review', (tester) async {
      final semantics = tester.ensureSemantics();
      final e = await _env(panes: [_pane(1, 'blocked'), _pane(2, 'done')]);
      final blocked = e.host.add(id: 'k1', title: 'Blocked one');
      e.host.add(id: 'k2', title: 'Finished one');
      await _pump(tester, e);
      blocked.askPermission();
      unawaited(e.repo.byKey('a/k2')!.send('work'));
      await _settle(tester);

      expect(_badge(tester), 'Agents, 2 need you', reason: '1 pane + 1 session; finished work is not a question');
      expect(find.text('2 need you · 2 to review'), findsOneWidget);
      expect(tester.widget<SectionLabel>(_section('Needs you')).count, 2);
      expect(tester.widget<SectionLabel>(_section('Done')).count, 2);

      e.repo.byKey('a/k2')!.markSeen();
      await _settle(tester);
      expect(_badge(tester), 'Agents, 2 need you');
      expect(find.text('2 need you · 1 to review'), findsOneWidget);
      semantics.dispose();
      await _teardown(tester, e);
    });

    testWidgets('the status filter narrows sessions too', (tester) async {
      final e = await _env(panes: [_pane(1, 'working'), _pane(2, 'idle')]);
      e.host
        ..add(id: 'k1', title: 'Quiet one')
        ..add(id: 'k2', title: 'Busy one');
      await _pump(tester, e);
      e.host.keepers['k2']!.turn = Completer<String>();
      unawaited(e.repo.byKey('a/k2')!.send('go'));
      await _settle(tester);

      await tester.tap(find.widgetWithText(AppChip, 'Working'));
      await _settle(tester);
      expect(_row('Busy one'), findsOneWidget);
      expect(_row('Quiet one'), findsNothing, reason: 'an idle session is filtered out like an idle pane');
      await _teardown(tester, e);
    });

    testWidgets('a finished session is "done" until it is looked at', (tester) async {
      final e = await _env();
      e.host.add(id: 'k1', title: 'Write docs');
      await _pump(tester, e);
      unawaited(e.repo.byKey('a/k1')!.send('go'));
      await _settle(tester);

      expect(find.descendant(of: _row('Write docs'), matching: find.text('done <1m')), findsOneWidget);
      e.repo.byKey('a/k1')!.markSeen();
      await _settle(tester);
      expect(find.descendant(of: _row('Write docs'), matching: find.text('idle <1m')), findsOneWidget);
      await _teardown(tester, e);
    });

    testWidgets('a session whose link dropped or ended says so', (tester) async {
      final e = await _env();
      final dropped = e.host.add(id: 'k1', title: 'Dropped');
      final ended = e.host.add(id: 'k2', title: 'Ended');
      await _pump(tester, e);

      e.host.attachGate = Completer<void>();
      dropped.dropLink();
      ended.exit(code: 3);
      await _settle(tester, 12);

      expect(find.descendant(of: _row('Dropped'), matching: find.text('reconnecting')), findsOneWidget);
      expect(find.descendant(of: _row('Ended'), matching: find.text('ended')), findsOneWidget);
      e.host.attachGate!.complete();
      await _settle(tester, 40);
      expect(find.descendant(of: _row('Dropped'), matching: find.text('idle <1m')), findsOneWidget);
      await _teardown(tester, e);
    });

    testWidgets('no sessions: the board is as it was', (tester) async {
      final e = await _env(panes: [_pane(1, 'working')]);
      await _pump(tester, e);

      expect(find.byType(AgentSessionRow), findsNothing);
      expect(find.text('1 machine · 1 agent'), findsOneWidget);
      await _teardown(tester, e);
    });

    testWidgets('only sessions: the "no agents" empty state gives way', (tester) async {
      final e = await _env();
      e.host.add(id: 'k1', title: 'Only one');
      await _pump(tester, e);

      expect(find.text('No agents running'), findsNothing);
      expect(_row('Only one'), findsOneWidget);
      expect(find.text('1 machine · no agents · 1 agent session'), findsOneWidget);
      await _teardown(tester, e);
    });

    testWidgets('a session folds away and back with its section', (tester) async {
      final e = await _env(panes: [_pane(1, 'working')]);
      e.host.add(id: 'k1', title: 'Foldable');
      await _pump(tester, e);
      expect(_row('Foldable'), findsOneWidget);

      await tester.tap(_section('Idle'));
      await _settle(tester, 8);
      expect(_row('Foldable'), findsNothing);
      expect(tester.widget<SectionLabel>(_section('Idle')).expanded, isFalse);

      await tester.tap(_section('Idle'));
      await _settle(tester, 8);
      expect(_row('Foldable'), findsOneWidget);
      await _teardown(tester, e);
    });

    testWidgets('30 sessions with long and Vietnamese titles fit a small, large-text screen', (tester) async {
      final e = await _env();
      for (var i = 0; i < 30; i++) {
        e.host.add(
          id: 'k${i.toString().padLeft(2, '0')}',
          title: 'Sửa lỗi đăng nhập số $i ${'rất dài và khó đọc ' * 10}',
          cwd: '/home/dev/Dự án thử nghiệm ${'thư mục ' * 12}$i',
        );
      }
      await _pump(tester, e, width: 320, height: 640, textScale: 2);

      expect(tester.widget<SectionLabel>(_section('Idle')).count, 30);
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(CustomScrollView).first, const Offset(0, -3000));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      await _teardown(tester, e);
    });

    testWidgets('a blocked row with a very long command keeps to one line', (tester) async {
      final e = await _env();
      final keeper = e.host.add(id: 'k1', title: 'Long');
      await _pump(tester, e, width: 320, height: 640);
      keeper.askPermission(command: 'python -c "${'print(1) ' * 80}"');
      await _settle(tester);

      expect(tester.takeException(), isNull);
      final summary = find.descendant(of: _row('Long'), matching: find.textContaining('python -c'));
      expect(tester.getSize(summary).height, lessThan(24), reason: 'one line');
      await _teardown(tester, e);
    });
  });

  group('listing', () {
    testWidgets('the hosts are listed every refresh interval while the Agents tab is on screen, and not otherwise', (tester) async {
      final e = await _env();
      e.host.add(id: 'k1', title: 'One');
      await _pump(tester, e);
      final base = e.host.listCalls;

      final tick = e.repo.refreshEvery + const Duration(seconds: 1);
      await tester.pump(tick);
      expect(e.host.listCalls, base + 1);

      await tester.tap(find.byKey(FloatingTabBar.tabKey('Machines')));
      await _settle(tester);
      final away = e.host.listCalls;
      await tester.pump(const Duration(minutes: 3));
      expect(e.host.listCalls, away, reason: 'a hidden board lists nothing');

      await tester.tap(find.byKey(FloatingTabBar.tabKey('Agents')));
      await _settle(tester);
      await tester.pump(tick);
      expect(e.host.listCalls, away + 1);
      await _teardown(tester, e);
    });
  });

  group('reviewing without opening', () {
    const swipe = Offset(-260, 0);

    /// Sessions `Title` that finished a turn nobody looked at.
    Future<void> finish(WidgetTester tester, _Env e, String key) async {
      unawaited(e.repo.byKey('a/$key')!.send('go'));
      await _settle(tester);
    }

    Finder idleLabel(String title) => find.descendant(of: _row(title), matching: find.text('idle <1m'));
    Finder doneLabel(String title) => find.descendant(of: _row(title), matching: find.text('done <1m'));
    AgentStatus paneStatus(_Env e, int i) => e.h.fleet.connection('a')!.paneById('w1:p$i')!.status;

    testWidgets('swiping a finished session marks it reviewed, offers Undo, and Undo brings it back', (tester) async {
      final semantics = tester.ensureSemantics();
      final e = await _env();
      e.host.add(id: 'k1', title: 'Write docs');
      await _pump(tester, e);
      await finish(tester, e, 'k1');
      expect(doneLabel('Write docs'), findsOneWidget);
      expect(_toReview(e), 1);
      expect(_doneCount(tester), 1);

      await tester.drag(_row('Write docs'), swipe);
      await _settle(tester, 10);

      expect(idleLabel('Write docs'), findsOneWidget);
      expect(_toReview(e), 0, reason: 'the count drops at once');
      expect(_doneCount(tester), 0);
      expect(find.text('Marked reviewed'), findsOneWidget);
      expect(e.host.attachCalls, 1, reason: 'the session was not opened');

      await tester.tap(find.text('Undo'));
      await _settle(tester, 10);
      expect(doneLabel('Write docs'), findsOneWidget);
      expect(_toReview(e), 1);
      expect(_doneCount(tester), 1);
      expect(find.text('Marked reviewed'), findsNothing);

      await tester.drag(_row('Write docs'), swipe);
      await _settle(tester, 10);
      expect(idleLabel('Write docs'), findsOneWidget, reason: 'and it can be swiped again');
      semantics.dispose();
      await _teardown(tester, e);
    });

    testWidgets('a session swiped as reviewed is still reviewed after the board listed the host again', (tester) async {
      final e = await _env();
      final keeper = e.host.add(id: 'k1', title: 'Listed one');
      await _pump(tester, e);
      keeper.finishTurn();
      keeper.unseenDone = true;
      await e.repo.refresh();
      await _settle(tester);
      expect(doneLabel('Listed one'), findsOneWidget);

      await tester.drag(_row('Listed one'), swipe);
      await _settle(tester, 10);
      expect(idleLabel('Listed one'), findsOneWidget);

      await e.repo.refresh();
      await _settle(tester);
      expect(idleLabel('Listed one'), findsOneWidget, reason: 'the same listing is the same turn');
      await _teardown(tester, e);
    });

    testWidgets('screen readers get Mark reviewed on a finished session only', (tester) async {
      final semantics = tester.ensureSemantics();
      final e = await _env();
      e.host.add(id: 'k1', title: 'Finished');
      e.host.add(id: 'k2', title: 'Quiet');
      await _pump(tester, e);
      await finish(tester, e, 'k1');

      Iterable<String> actions(String title) {
        final data = tester.getSemantics(find.text(title)).getSemanticsData();
        return [
          for (final id in data.customSemanticsActionIds ?? const <int>[]) CustomSemanticsAction.getAction(id)!.label!,
        ];
      }

      expect(actions('Quiet'), isEmpty);
      expect(actions('Finished'), ['Mark reviewed']);

      final node = tester.getSemantics(find.text('Finished'));
      node.owner!.performAction(node.id, SemanticsAction.customAction, node.getSemanticsData().customSemanticsActionIds!.single);
      await _settle(tester, 10);
      expect(idleLabel('Finished'), findsOneWidget);
      expect(find.text('Marked reviewed'), findsOneWidget);
      expect(actions('Finished'), isEmpty, reason: 'nothing left to review');
      semantics.dispose();
      await _teardown(tester, e);
    });

    Future<void> swipeAway(WidgetTester tester, String title) async {
      final home = tester.getTopLeft(find.text(title)).dx;
      await tester.drag(find.text(title), swipe);
      await _settle(tester, 10);
      expect(tester.getTopLeft(find.text(title)).dx, home, reason: '$title does not move');
      expect(find.text('Marked reviewed'), findsNothing);
    }

    testWidgets('a working session and an unreachable one ignore the swipe', (tester) async {
      final e = await _env();
      e.host.add(id: 'k1', title: 'Busy');
      e.host.add(id: 'k2', title: 'Dropped');
      await _pump(tester, e);
      await finish(tester, e, 'k2');
      e.host.keepers['k1']!.turn = Completer<String>();
      unawaited(e.repo.byKey('a/k1')!.send('go'));
      await _settle(tester);
      expect(e.repo.byKey('a/k1')!.phase, AgentPhase.working);

      await swipeAway(tester, 'Busy');

      e.host.attachGate = Completer<void>();
      e.host.keepers['k2']!.dropLink();
      await _settle(tester, 12);
      expect(e.repo.byKey('a/k2')!.link, isNot(AgentLink.live));
      expect(e.repo.byKey('a/k2')!.unseenDone, isTrue, reason: 'it would be done, if it could be reached');
      await swipeAway(tester, 'Dropped');
      expect(e.repo.byKey('a/k2')!.unseenDone, isTrue, reason: 'still waiting for a look');
      e.host.attachGate!.complete();
      await _settle(tester, 40);
      await _teardown(tester, e);
    });

    testWidgets('while the board is picking, a swipe does nothing', (tester) async {
      final e = await _env();
      e.host.add(id: 'k1', title: 'Picked');
      e.host.add(id: 'k2', title: 'Other');
      await _pump(tester, e);
      await finish(tester, e, 'k1');
      await finish(tester, e, 'k2');
      expect(_toReview(e), 2);

      await tester.longPress(find.text('Picked'));
      await _settle(tester);
      expect(find.text('1 selected'), findsOneWidget);
      await swipeAway(tester, 'Other');
      expect(e.repo.byKey('a/k2')!.unseenDone, isTrue);
      await _teardown(tester, e);
    });

    testWidgets('Mark all reviewed clears finished panes and sessions with one toast and one Undo', (tester) async {
      final semantics = tester.ensureSemantics();
      final e = await _env(panes: [_pane(1, 'done'), _pane(2, 'done'), _pane(3, 'working')]);
      e.host.add(id: 'k1', title: 'Docs');
      e.host.add(id: 'k2', title: 'Billing');
      e.host.add(id: 'k3', title: 'Still going');
      await _pump(tester, e);
      await finish(tester, e, 'k1');
      await finish(tester, e, 'k2');
      e.host.keepers['k3']!.turn = Completer<String>();
      unawaited(e.repo.byKey('a/k3')!.send('go'));
      await _settle(tester);
      expect(_doneCount(tester), 4);

      await tester.tap(find.byKey(const ValueKey('mark-all-reviewed')));
      await _settle(tester, 10);

      expect(paneStatus(e, 1), AgentStatus.idle);
      expect(paneStatus(e, 2), AgentStatus.idle);
      expect(paneStatus(e, 3), AgentStatus.working);
      expect(idleLabel('Docs'), findsOneWidget);
      expect(idleLabel('Billing'), findsOneWidget);
      expect(_toReview(e), 0);
      expect(_doneCount(tester), 0);
      expect(find.text('Marked 4 reviewed'), findsOneWidget, reason: 'one toast for all of them');
      expect(find.text('Undo'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await _settle(tester, 10);
      expect(paneStatus(e, 1), AgentStatus.done);
      expect(paneStatus(e, 2), AgentStatus.done);
      expect(doneLabel('Docs'), findsOneWidget);
      expect(doneLabel('Billing'), findsOneWidget);
      expect(_toReview(e), 2);
      expect(_doneCount(tester), 4);
      expect(find.text('Marked 4 reviewed'), findsNothing);
      semantics.dispose();
      await _teardown(tester, e);
    });

    testWidgets('Mark all reviewed after a swipe joins its toast, and Undo takes back both', (tester) async {
      final e = await _env(panes: [_pane(1, 'done')]);
      e.host.add(id: 'k1', title: 'Docs');
      e.host.add(id: 'k2', title: 'Billing');
      await _pump(tester, e);
      await finish(tester, e, 'k1');
      await finish(tester, e, 'k2');

      await tester.drag(_row('Docs'), swipe);
      await _settle(tester, 10);
      expect(find.text('Marked reviewed'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('mark-all-reviewed')));
      await _settle(tester, 10);
      expect(find.text('Marked 3 reviewed'), findsOneWidget, reason: 'the swipe, the pane and the other session');

      await tester.tap(find.text('Undo'));
      await _settle(tester, 10);
      expect(paneStatus(e, 1), AgentStatus.done);
      expect(doneLabel('Docs'), findsOneWidget, reason: 'the swipe was not lost');
      expect(doneLabel('Billing'), findsOneWidget);
      await _teardown(tester, e);
    });

    testWidgets('with only sessions finished, the Done header carries Mark all reviewed', (tester) async {
      final e = await _env(panes: [_pane(1, 'working')]);
      e.host.add(id: 'k1', title: 'Docs');
      e.host.add(id: 'k2', title: 'Billing');
      await _pump(tester, e);
      expect(find.byKey(const ValueKey('mark-all-reviewed')), findsNothing, reason: 'nothing to clear');
      await finish(tester, e, 'k1');
      await finish(tester, e, 'k2');
      expect(find.byKey(const ValueKey('mark-all-reviewed')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('mark-all-reviewed')));
      await _settle(tester, 10);

      expect(find.text('Marked 2 reviewed'), findsOneWidget);
      expect(_toReview(e), 0);
      expect(find.byKey(const ValueKey('mark-all-reviewed')), findsNothing, reason: 'nothing left to clear');
      await _teardown(tester, e);
    });
  });
}
