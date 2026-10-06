// The Past sessions screen: what an agent remembers on a machine, the filters,
// bringing one back, and every state it can be in.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/acp/session_state.dart' show AgentSessionState;
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/toast.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/create/new_agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/history/past_session_row.dart';
import 'package:herdr_mobile/ui/features/history/past_sessions_screen.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';

import '../support/fake_agent_session.dart';
import 'history_support.dart';

Finder _row(String title) => find.widgetWithText(PastSessionRow, title);

Finder _chip(String label) => find.widgetWithText(AppChip, label);

Finder _inRow(String title, String text) => find.descendant(of: _row(title), matching: find.text(text));

bool _selected(WidgetTester tester, String label) => tester.widget<AppChip>(_chip(label)).selected;

/// A live session of [machine] holding [past]'s id, as the repository would.
FakeAgentSession _held(HistoryEnv e, String id, {AgentLink link = AgentLink.live, String key = 'a/k9'}) =>
    FakeAgentSession(
      key: key,
      machine: e.machine(),
      agent: 'omp',
      agentLabel: 'omp',
      link: link,
      state: AgentSessionState(id, items: [userMsg('h', 'the held conversation')]),
    );

FakeAgentSession _replay(HistoryEnv e, String id) => FakeAgentSession(
  key: 'a/k5',
  machine: e.machine(),
  agent: 'omp',
  agentLabel: 'omp',
  state: AgentSessionState(id, items: [userMsg('r', 'the replayed conversation')]),
);

void main() {
  group('the list', () {
    testWidgets('shows title, folder, when and how long; a session without a title or a count still reads', (tester) async {
      final e = await historyEnv();
      e.sessions.answers['omp'] = remembered([
        past('s1', title: 'Fix the parser'),
        past('s2', cwd: '/srv/billing', ago: null, messages: 0),
        past('s3', title: 'One line', messages: 1, ago: const Duration(minutes: 20)),
      ]);
      await pumpPast(tester, e);

      expect(e.sessions.historyCalls, [(machineId: 'a', agent: 'omp', cwd: null)]);
      expect(_inRow('Fix the parser', 'payments-api'), findsOneWidget);
      expect(_inRow('Fix the parser', '5 min ago · 14 messages'), findsOneWidget);
      expect(_inRow('Untitled session', 'billing'), findsOneWidget);
      expect(_inRow('Untitled session', 'No messages'), findsOneWidget, reason: 'no time known: only the count');
      expect(_inRow('One line', '20 min ago · 1 message'), findsOneWidget);
      await e.tearDown(tester);
    });

    testWidgets('offers the agents the machine has, and asks the one chosen', (tester) async {
      final e = await historyEnv();
      e.sessions
        ..installed = {'omp', 'codex'}
        ..answers['omp'] = remembered([past('o1', title: 'omp one')])
        ..answers['codex'] = remembered([past('c1', agent: 'codex', title: 'codex one')], agent: 'codex');
      await pumpPast(tester, e);

      expect(_chip('Claude Code'), findsNothing, reason: 'not installed there');
      expect(_selected(tester, 'omp'), isTrue);
      expect(_row('omp one'), findsOneWidget);

      await tester.tap(_chip('Codex'));
      await settleHistory(tester, 3);
      expect(_selected(tester, 'Codex'), isTrue);
      expect(_row('codex one'), findsOneWidget);
      expect(_row('omp one'), findsNothing);
      expect(e.sessions.historyCalls.last, (machineId: 'a', agent: 'codex', cwd: null));

      await tester.tap(_chip('omp'));
      await settleHistory(tester, 3);
      expect(_row('omp one'), findsOneWidget);
      expect(e.sessions.historyCalls, hasLength(2), reason: 'what was read is not read again');
      await e.tearDown(tester);
    });

    testWidgets('one machine needs no machine chips; two do, and the second is asked on its own', (tester) async {
      var e = await historyEnv();
      await pumpPast(tester, e);
      expect(_chip('studio-mac'), findsNothing);
      await e.tearDown(tester);

      e = await historyEnv(machines: [(id: 'a', label: 'studio-mac'), (id: 'b', label: 'build-box')]);
      e.sessions.answers['omp'] = remembered([past('s1', title: 'on the first')]);
      await pumpPast(tester, e);
      expect(_selected(tester, 'studio-mac'), isTrue);
      await tester.tap(_chip('build-box'));
      await settleHistory(tester, 3);
      expect(_selected(tester, 'build-box'), isTrue);
      expect(e.sessions.historyCalls.last.machineId, 'b');
      await e.tearDown(tester);
    });

    testWidgets('the search narrows by title or folder, and says when nothing matches', (tester) async {
      final e = await historyEnv();
      e.sessions.answers['omp'] = remembered([
        past('s1', title: 'Fix the parser'),
        past('s2', title: 'Write the billing report', cwd: '/srv/reports'),
        past('s3', title: 'Rename things', cwd: '/home/dev/billing-api'),
        for (var i = 4; i < 9; i++) past('s$i', title: 'Chore $i'),
      ]);
      await pumpPast(tester, e, size: const Size(360, 1600));

      await tester.enterText(find.byType(TextField), 'billing');
      await tester.pump();
      expect(find.byType(PastSessionRow), findsNWidgets(2), reason: 'one by its title, one by its folder');
      expect(_row('Write the billing report'), findsOneWidget);
      expect(_row('Rename things'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump();
      expect(find.byType(PastSessionRow), findsNothing);
      expect(find.text('No matches'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      expect(find.byType(PastSessionRow), findsNWidgets(8));
      await e.tearDown(tester);
    });

    testWidgets('a short list has no search field', (tester) async {
      final e = await historyEnv();
      e.sessions.answers['omp'] = remembered([past('s1', title: 'one'), past('s2', title: 'two')]);
      await pumpPast(tester, e);
      expect(find.byType(TextField), findsNothing);
      await e.tearDown(tester);
    });

    testWidgets('This folder is on when the opener named one; turning it off asks for every folder', (tester) async {
      final e = await historyEnv();
      e.sessions.answers['omp'] = remembered([past('s1', title: 'here')]);
      await pumpPast(tester, e, cwd: '/home/dev/payments-api');

      expect(e.sessions.historyCalls, [(machineId: 'a', agent: 'omp', cwd: '/home/dev/payments-api')]);
      expect(_selected(tester, 'This folder'), isTrue);
      await tester.tap(_chip('This folder'));
      await settleHistory(tester, 3);
      expect(_selected(tester, 'This folder'), isFalse);
      expect(e.sessions.historyCalls.last, (machineId: 'a', agent: 'omp', cwd: null));
      await e.tearDown(tester);
    });

    testWidgets('no folder chip when the opener named none, or a relative path', (tester) async {
      final e = await historyEnv();
      await pumpPast(tester, e, cwd: 'relative/path');
      expect(_chip('This folder'), findsNothing);
      expect(e.sessions.historyCalls.single.cwd, isNull);
      await e.tearDown(tester);
    });
  });

  group('bringing one back', () {
    testWidgets('the tap resumes that session in its folder, shows a spinner on the row, then opens the chat', (tester) async {
      final e = await historyEnv();
      e.sessions.answers['omp'] = remembered([
        past('s1', title: 'Fix the parser', cwd: '/home/dev/payments-api'),
        past('s2', title: 'Other thing', cwd: '/srv/billing'),
      ]);
      final gate = Completer<AgentSessionView>();
      e.sessions.onResume = (_) => gate.future;
      await pumpPast(tester, e);

      await tester.tap(_row('Fix the parser'));
      await tester.pump();
      expect(e.sessions.resumeCalls, [
        (machineId: 'a', agent: 'omp', cwd: '/home/dev/payments-api', sessionId: 's1', replaces: null),
      ]);
      expect(find.descendant(of: _row('Fix the parser'), matching: find.byType(BusySpinner)), findsOneWidget);
      expect(find.byType(BusySpinner), findsOneWidget, reason: 'only that row works');

      await tester.tap(_row('Fix the parser'));
      await tester.tap(_row('Other thing'));
      await tester.pump();
      expect(e.sessions.resumeCalls, hasLength(1), reason: 'taps while one comes back do nothing');

      final next = _replay(e, 's1');
      e.sessions.hold(next);
      gate.complete(next);
      await settleHistory(tester, 10);
      expect(find.byType(AgentSessionScreen), findsOneWidget);
      expect(find.text('the replayed conversation'), findsOneWidget);

      // Back on the list the session is held now: the row opens it.
      await tester.pageBack();
      await settleHistory(tester, 6);
      expect(find.byType(AgentSessionScreen), findsNothing);
      expect(_inRow('Fix the parser', 'Open'), findsOneWidget);
      expect(find.descendant(of: _row('Other thing'), matching: find.text('Open')), findsNothing);
      await e.tearDown(tester);
    });

    testWidgets('a refusal is a toast with the host\'s words; the row works again', (tester) async {
      final e = await historyEnv();
      e.sessions.answers['omp'] = remembered([past('s1', title: 'Fix the parser')]);
      e.sessions.onResume = (_) async => throw const AgentHostException('The folder /home/dev/payments-api is gone.');
      await pumpPast(tester, e);

      await tester.tap(_row('Fix the parser'));
      await settleHistory(tester, 3);
      expect(
        find.descendant(of: find.byKey(toastKey), matching: find.text('The folder /home/dev/payments-api is gone.')),
        findsOneWidget,
      );
      expect(find.byType(BusySpinner), findsNothing);
      expect(find.byType(AgentSessionScreen), findsNothing);

      await tester.tap(_row('Fix the parser'));
      await settleHistory(tester, 3);
      expect(e.sessions.resumeCalls, hasLength(2));
      await e.tearDown(tester);
    });

    testWidgets('a session a keeper holds already says Open and shows that chat instead of loading it twice', (tester) async {
      final e = await historyEnv();
      e.sessions.answers['omp'] = remembered([
        past('held', title: 'Already open'),
        past('gone', title: 'Ended one'),
      ]);
      e.sessions
        ..hold(_held(e, 'held'))
        ..hold(_held(e, 'gone', link: AgentLink.ended, key: 'a/k8'));
      await pumpPast(tester, e);

      expect(_inRow('Already open', 'Open'), findsOneWidget);
      expect(find.descendant(of: _row('Ended one'), matching: find.text('Open')), findsNothing, reason: 'ended: not held');

      await tester.tap(_row('Already open'));
      await settleHistory(tester, 8);
      expect(e.sessions.resumeCalls, isEmpty);
      expect(tester.widget<AgentSessionScreen>(find.byType(AgentSessionScreen)).session.key, 'a/k9');
      await e.tearDown(tester);
    });
  });

  group('states', () {
    testWidgets('nothing remembered', (tester) async {
      final e = await historyEnv();
      await pumpPast(tester, e);
      expect(find.text('Nothing remembered for omp here yet.'), findsOneWidget);
      await e.tearDown(tester);
    });

    testWidgets('nothing remembered in the folder asks to look wider', (tester) async {
      final e = await historyEnv();
      await pumpPast(tester, e, cwd: '/home/dev/payments-api');
      expect(find.text('Nothing remembered for omp in this folder yet.'), findsOneWidget);
      expect(_chip('This folder'), findsOneWidget);
      await e.tearDown(tester);
    });

    testWidgets('an agent that keeps no list says so, which is not "nothing remembered"', (tester) async {
      final e = await historyEnv();
      e.sessions.answers['omp'] = remembered(const [], canList: false);
      await pumpPast(tester, e);
      expect(find.text("omp doesn't keep a list the phone can read."), findsOneWidget);
      expect(find.textContaining('Nothing remembered'), findsNothing);
      await e.tearDown(tester);
    });

    testWidgets('an agent that cannot reopen shows its sessions with the note and no tap', (tester) async {
      final e = await historyEnv();
      e.sessions.answers['omp'] = remembered([past('s1', title: 'Fix the parser')], canLoad: false);
      await pumpPast(tester, e);

      expect(find.text("omp can't reopen a past session from the phone."), findsOneWidget);
      expect(_row('Fix the parser'), findsOneWidget);
      await tester.tap(_row('Fix the parser'));
      await settleHistory(tester, 3);
      expect(e.sessions.resumeCalls, isEmpty);
      expect(find.byType(AgentSessionScreen), findsNothing);
      await e.tearDown(tester);
    });

    testWidgets('a failed read says why and Retry asks again', (tester) async {
      final e = await historyEnv();
      e.sessions.historyError = const AgentHostException('omp did not answer in time.');
      await pumpPast(tester, e);
      expect(find.text('omp did not answer in time.'), findsOneWidget);
      expect(find.text('Couldn’t read past sessions'), findsOneWidget);

      e.sessions
        ..historyError = null
        ..answers['omp'] = remembered([past('s1', title: 'Back again')]);
      await tester.tap(find.widgetWithText(AppButton, 'Retry'));
      await settleHistory(tester, 3);
      expect(_row('Back again'), findsOneWidget);
      expect(find.text('Couldn’t read past sessions'), findsNothing);
      await e.tearDown(tester);
    });

    testWidgets('a machine that cannot say which agents it has is a failure; Retry asks again', (tester) async {
      final e = await historyEnv();
      e.sessions.availableError = const AgentHostException('python3 is missing on studio-mac.');
      await pumpPast(tester, e);
      expect(find.text('python3 is missing on studio-mac.'), findsOneWidget);
      expect(e.sessions.historyCalls, isEmpty);

      e.sessions
        ..availableError = null
        ..answers['omp'] = remembered([past('s1', title: 'Found it')]);
      await tester.tap(find.widgetWithText(AppButton, 'Retry'));
      await settleHistory(tester, 3);
      expect(_row('Found it'), findsOneWidget);
      await e.tearDown(tester);
    });

    testWidgets('a machine with none of the agents says so', (tester) async {
      final e = await historyEnv();
      e.sessions.installed = {};
      await pumpPast(tester, e);
      expect(find.text('No agent installed'), findsOneWidget);
      await e.tearDown(tester);
    });

    testWidgets('while the agent is asked, a quiet line with a spinner; more than the host read is said', (tester) async {
      final e = await historyEnv();
      final gate = Completer<void>();
      e.sessions
        ..historyGate = gate.future
        ..answers['omp'] = remembered([past('s1', title: 'late')], more: true);
      await pumpPast(tester, e);
      expect(find.text('Reading what omp remembers…'), findsOneWidget);
      expect(find.byType(BusySpinner), findsOneWidget);

      gate.complete();
      await settleHistory(tester, 3);
      expect(find.byType(BusySpinner), findsNothing);
      expect(_row('late'), findsOneWidget);
      expect(find.text('Showing the newest 1'), findsOneWidget);
      await e.tearDown(tester);
    });

    testWidgets('no machine online', (tester) async {
      final e = await historyEnv(machines: const []);
      await pumpPast(tester, e);
      expect(find.text('No machine is online'), findsOneWidget);
      expect(e.sessions.historyCalls, isEmpty);
      await e.tearDown(tester);
    });
  });

  group('the entries', () {
    testWidgets('the new agent session form opens it with the folder typed there', (tester) async {
      final e = await historyEnv();
      e.sessions.answers['omp'] = remembered([past('s1', title: 'In that folder')]);
      await pumpUnder(tester, e, const NewAgentSessionScreen());
      await tester.enterText(find.byType(TextFormField), '/work/x');
      await tester.pump();

      await tester.ensureVisible(find.text('Past sessions'));
      await tester.tap(find.text('Past sessions'));
      await settleHistory(tester, 8);
      expect(find.byType(PastSessionsScreen), findsOneWidget);
      expect(e.sessions.historyCalls.single, (machineId: 'a', agent: 'omp', cwd: '/work/x'));
      expect(_selected(tester, 'This folder'), isTrue);
      await e.tearDown(tester);
    });

    testWidgets('the Agents board reaches it from its own header button', (tester) async {
      final e = await historyEnv();
      await pumpUnder(tester, e, const HomeShell());
      await tester.tap(find.byTooltip('Past sessions'));
      await settleHistory(tester, 8);
      expect(find.byType(PastSessionsScreen), findsOneWidget);
      expect(e.sessions.historyCalls.single.cwd, isNull);
      await e.tearDown(tester);
    });
  });

  group('worst case', () {
    testWidgets('200 long Vietnamese titles with a direction override, a 300-character folder, 320 wide at 1.6x', (tester) async {
      final e = await historyEnv();
      final long = 'Sửa lỗi đồng bộ dữ liệu người dùng \u202Eexe.txt ${'rất dài '.padRight(400, 'ệ')}';
      e.sessions.answers['omp'] = remembered([
        for (var i = 0; i < 200; i++)
          past(
            's$i',
            title: i == 5 ? null : long,
            cwd: i == 3 ? '/home/${'đ' * 300}' : '/home/dev/thư-mục-$i',
            messages: i == 4 ? 0 : 1000000 + i,
            ago: Duration(hours: i),
          ),
      ], more: true);
      await pumpPast(tester, e, size: const Size(320, 640), textScale: 1.6);

      expect(find.byType(PastSessionRow), findsWidgets);
      expect(find.byWidgetPredicate((w) => w is Text && (w.data ?? '').contains('\u202E')), findsNothing);
      expect(find.textContaining('‹U+202E›'), findsWidgets);

      await tester.fling(find.byType(CustomScrollView), const Offset(0, -60000), 20000);
      await settleHistory(tester, 10);
      await tester.fling(find.byType(CustomScrollView), const Offset(0, -60000), 20000);
      await settleHistory(tester, 10);
      expect(find.text('Showing the newest 200'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await e.tearDown(tester);
    });
  });
}
