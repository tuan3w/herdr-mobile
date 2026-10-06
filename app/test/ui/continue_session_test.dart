// Continue on an ended session: when the strip offers it, what the tap asks
// the repository for, and what the person sees while it works and when it
// fails.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/acp/past_session.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/status_panel.dart';
import 'package:herdr_mobile/ui/core/toast.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';

import '../support/fake_agent_session.dart';
import 'history_support.dart';

const _target = ResumeTarget(agent: 'claude', cwd: '/home/dev/payments-api', sessionId: 'sess-old');

FakeAgentSession _ended({ResumeTarget? target = _target, AgentLink link = AgentLink.ended}) => FakeAgentSession(
  link: link,
  error: 'Claude Code exited with code 1.',
  state: stateWith(items: [userMsg('u', 'earlier prompt')]),
)..resumeTargetValue = target;

FakeAgentSession _fresh() => FakeAgentSession(
  key: 'm/k2',
  state: stateWith(items: [userMsg('u2', 'replayed prompt')]),
);

Finder get _continue => find.widgetWithText(AppButton, 'Continue');

Finder _strip(String text) =>
    find.descendant(of: find.byType(StatusStrip), matching: find.textContaining(text, findRichText: true));

bool _busy(WidgetTester tester) => tester.widget<AppButton>(_continue).loading;

Future<HistoryEnv> _open(WidgetTester tester, FakeAgentSession session) async {
  final e = await historyEnv();
  await pumpUnder(tester, e, AgentSessionScreen(key: ObjectKey(session), session: session));
  return e;
}

void main() {
  group('the offer', () {
    testWidgets('an ended session whose keeper is gone offers Continue and says what is kept', (tester) async {
      final e = await _open(tester, _ended());
      expect(_continue, findsOneWidget);
      expect(_strip('Session ended'), findsOneWidget);
      expect(_strip('exited with code 1'), findsOneWidget);
      expect(_strip('kept the conversation'), findsOneWidget);
      // The transcript and the composer's reason are as they were.
      expect(find.text('earlier prompt'), findsOneWidget);
      expect(find.text('Session ended · read only'), findsOneWidget);
      await e.tearDown(tester);
    });

    testWidgets('a tap on the strip shows the whole reason when the button leaves little room', (tester) async {
      final session = _ended()..setLink(AgentLink.ended, error: 'The host restarted and took Claude Code with it.');
      final e = await _open(tester, session);
      await tester.tap(find.byType(StatusStrip), warnIfMissed: false);
      await settleHistory(tester, 5);
      expect(
        find.widgetWithText(SelectableText, 'The agent kept the conversation. The host restarted and took Claude Code with it.'),
        findsOneWidget,
      );
      await e.tearDown(tester);
    });

    testWidgets('no Continue without a target, while live, or when another device took it over', (tester) async {
      var e = await _open(tester, _ended(target: null));
      expect(_continue, findsNothing);
      expect(_strip('conversation is kept'), findsNothing);
      await e.tearDown(tester);

      e = await _open(tester, _ended(link: AgentLink.live));
      expect(_continue, findsNothing);
      await e.tearDown(tester);

      final taken = _ended()..evict();
      e = await _open(tester, taken);
      expect(_continue, findsNothing);
      expect(find.widgetWithText(AppButton, 'Take over'), findsOneWidget);
      await e.tearDown(tester);
    });
  });

  group('the tap', () {
    testWidgets('resumes the saved session in its folder, replaces this chat with the new one, once', (tester) async {
      final old = _ended();
      final e = await _open(tester, old);
      final gate = Completer<AgentSessionView>();
      e.sessions.onResume = (_) => gate.future;

      await tester.tap(_continue);
      await tester.pump();
      expect(e.sessions.resumeCalls, [
        (machineId: 'm', agent: 'claude', cwd: '/home/dev/payments-api', sessionId: 'sess-old', replaces: 'm/k1'),
      ]);
      expect(_busy(tester), isTrue, reason: 'the spinner shows while the host works');
      expect(find.byType(BusySpinner), findsOneWidget);

      await tester.tap(_continue, warnIfMissed: false);
      await tester.pump();
      expect(e.sessions.resumeCalls, hasLength(1), reason: 'a second tap while it works does nothing');
      expect(find.text('earlier prompt'), findsOneWidget, reason: 'nothing changes until the host answers');

      final next = _fresh();
      e.sessions.hold(next);
      gate.complete(next);
      await settleHistory(tester, 10);
      expect(find.text('replayed prompt'), findsOneWidget);
      expect(find.text('earlier prompt'), findsNothing);
      expect(find.byType(AgentSessionScreen), findsOneWidget, reason: 'replaced, not stacked');
      expect(tester.widget<AgentSessionScreen>(find.byType(AgentSessionScreen)).session.key, 'm/k2');
      await e.tearDown(tester);
    });

    testWidgets('a refusal is a toast with the host\'s words, and the strip can be tapped again', (tester) async {
      final e = await _open(tester, _ended());
      e.sessions.onResume = (_) async => throw const AgentHostException('Claude Code is not installed on devbox.');

      await tester.tap(_continue);
      await settleHistory(tester, 3);
      expect(
        find.descendant(of: find.byKey(toastKey), matching: find.text('Claude Code is not installed on devbox.')),
        findsOneWidget,
      );
      expect(_busy(tester), isFalse);
      expect(find.text('earlier prompt'), findsOneWidget);
      expect(find.byType(AgentSessionScreen), findsOneWidget);

      await tester.tap(_continue);
      await settleHistory(tester, 3);
      expect(e.sessions.resumeCalls, hasLength(2), reason: 'Continue is offered again, not lost');
      await e.tearDown(tester);
    });
  });
}
