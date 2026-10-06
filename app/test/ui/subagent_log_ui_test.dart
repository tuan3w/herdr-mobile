import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/acp/subagents/subagent_overlay.dart';
import 'package:herdr_mobile/data/acp/subagents/subagent_run.dart';
import 'package:herdr_mobile/data/observed/omp_log_mapper.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/subagent_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_view.dart';

import '../support/fake_agent_session.dart';
import '../support/subagent_fixtures.dart';

// The drill-in of an omp subagent whose log was read from the host: the
// conversation when there is one, said once
// where it came from, else the summary with at most a loading or a retry line.

Widget _app(Widget body) => MaterialApp(theme: AppTheme.light(), home: Scaffold(body: body));

Future<void> _pump(WidgetTester tester, Widget app) async {
  tester.view.physicalSize = const Size(412, 892) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  await tester.pump(const Duration(milliseconds: 100));
}

Finder _text(String s) => find.textContaining(s, findRichText: true);

const _id = 'call#0';

AgentSessionState _fromLog() {
  final mapper = OmpLogMapper();
  var s = const AgentSessionState('subagent-log');
  for (final line in File('test/fixtures/omp_logs/subagent_artifact_acp.jsonl').readAsLinesSync()) {
    for (final u in mapper.map(line)) {
      s = s.apply(u);
    }
  }
  return s;
}

FakeAgentSession _omp({SubagentLogInfo? attached, SubagentLogStatus? status}) {
  final session = FakeAgentSession(
    state: play(ompTask('call', [ompProgress(0, 'Alpha', 'running')])),
    agent: 'omp',
    agentLabel: 'omp',
  );
  if (attached != null) session.overlay.attach(_id, LoggedTranscript(_fromLog(), attached));
  if (status != null) session.logStatuses[_id] = status;
  return session;
}

void main() {
  group('a transcript read from the log', () {
    testWidgets('is the conversation, with its origin said once', (tester) async {
      final session = _omp(attached: const SubagentLogInfo(), status: SubagentLogStatus.shown);
      await _pump(tester, _app(SubagentRunScreen(session: session, runId: _id)));

      expect(find.byType(SubagentSummaryBody), findsNothing);
      expect(find.byType(PinnedPrompt), findsOneWidget);
      expect(find.byType(TranscriptView), findsOneWidget);
      expect(_text('Complete assignment thoroughly'), findsWidgets, reason: 'the subagent\'s own first message');
      expect(_text('From omp’s log on the host'), findsOneWidget);
      expect(_text('Earlier part not shown'), findsNothing);
      expect(find.byType(TextField), findsNothing, reason: 'read-only');
      expect(find.text('Loading…'), findsNothing);
    });

    testWidgets('says when the start of the log is missing, and when lines were left out', (tester) async {
      final session = _omp(attached: const SubagentLogInfo(earlierNotShown: true, skippedLines: 2), status: SubagentLogStatus.shown);
      await _pump(tester, _app(SubagentRunScreen(session: session, runId: _id)));
      expect(_text('From omp’s log on the host · Earlier part not shown · 2 oversized lines left out'), findsOneWidget);
    });

    testWidgets('a transcript the agent sent says nothing about a log', (tester) async {
      final session = FakeAgentSession(
        state: play([launch('t', type: 'Explore', prompt: 'Find it.', status: 'in_progress'), childTool('c', 't'), childText('t', 'Looking now.')]),
      );
      await _pump(tester, _app(SubagentRunScreen(session: session, runId: 't')));
      expect(find.byType(TranscriptView), findsOneWidget);
      expect(_text('Looking now.'), findsOneWidget);
      expect(_text('log on the host'), findsNothing);
    });
  });

  group('the summary', () {
    testWidgets('with no log to read stays as it was, and says nothing about one', (tester) async {
      for (final status in [null, SubagentLogStatus.idle, SubagentLogStatus.unavailable]) {
        final session = _omp(status: status);
        await _pump(tester, _app(SubagentRunScreen(session: session, runId: _id)));
        expect(find.byType(SubagentSummaryBody), findsOneWidget, reason: '$status');
        expect(_text('Summary only.'), findsOneWidget);
        expect(find.byType(LogStatusLine), findsOneWidget);
        expect(find.text('Loading…'), findsNothing);
        expect(_text('Couldn’t read the log'), findsNothing);
        expect(_text('log on the host'), findsNothing);
      }
    });

    testWidgets('while the first read is under way: a short loading line, the summary under it', (tester) async {
      final session = _omp(status: SubagentLogStatus.loading);
      await _pump(tester, _app(SubagentRunScreen(session: session, runId: _id)));
      expect(find.text('Loading…'), findsOneWidget);
      expect(find.byType(BusySpinner), findsOneWidget);
      expect(find.byType(SubagentSummaryBody), findsOneWidget);
    });

    testWidgets('a failed read offers a retry that is a real tap target', (tester) async {
      final session = _omp(status: SubagentLogStatus.failed);
      await _pump(tester, _app(SubagentRunScreen(session: session, runId: _id)));
      expect(_text('Couldn’t read the log'), findsOneWidget);
      expect(find.byType(SubagentSummaryBody), findsOneWidget);
      expect(tester.getSize(find.byType(LogStatusLine)).height, greaterThanOrEqualTo(44));
      await tester.tap(_text('Couldn’t read the log'));
      await tester.pump();
      expect(session.logRetries, [_id]);
    });
  });

  group('the screen asks for the log only while it is open', () {
    testWidgets('watch on open, off on leaving', (tester) async {
      final session = _omp();
      await _pump(tester, _app(SubagentRunScreen(session: session, runId: _id)));
      expect(session.logWatches, [(_id, true)]);
      await tester.pumpWidget(_app(const SizedBox()));
      expect(session.logWatches, [(_id, true), (_id, false)]);
    });
  });
}
