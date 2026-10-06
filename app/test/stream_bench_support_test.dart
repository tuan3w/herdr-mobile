import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';

import '../benchmark/support/lag_probe.dart';
import '../benchmark/support/stream_session.dart';
import '../benchmark/support/trace_cadence.dart';

/// The pieces of `benchmark/stream_device_bench.dart` that can be checked off
/// the phone: the arrival profiles, the answer, and the probe that reads what
/// the real screen shows of it.
void main() {
  group('profiles', () {
    final text = syntheticAnswer(20000);

    test('the answer is 20 KB of markdown with a number in every unit', () {
      expect(text.length, 20000);
      expect(text, contains('## Section 001'));
      expect(text, contains('| alpha001 | 1 |'));
      expect(text, contains('```dart'));
      expect(text, contains('`lib/parse/step_001.dart:11`'));
    });

    for (final profile in StreamProfile.all) {
      test('$profile delivers the whole answer in order, on a forward clock', () {
        final arrivals = StreamProfile.schedule(profile, text);
        expect(arrivals.map((a) => a.text).join(), text);
        for (var i = 1; i < arrivals.length; i++) {
          expect(arrivals[i].atUs, greaterThanOrEqualTo(arrivals[i - 1].atUs));
        }
        expect(arrivals.every((a) => a.text.isNotEmpty), isTrue);
      });
    }

    test('synthetic is 40 tokens a second in 200 ms bursts', () {
      final arrivals = StreamProfile.schedule(StreamProfile.synthetic, text);
      final seconds = arrivals.last.atUs / 1e6;
      expect(text.length / seconds, closeTo(160, 5)); // 40 tokens x 4 characters
      expect({for (final a in arrivals) a.atUs}.length, (arrivals.length / 8).ceil());
    });

    test('every recorded agent is replayable', () {
      expect(traceCadence.keys, containsAll(['omp', 'claude', 'codex']));
      for (final cadence in traceCadence.values) {
        expect(cadence.length.isEven, isTrue);
        expect(cadence.every((n) => n >= 0), isTrue);
      }
    });

    test('an unknown profile is refused by name', () {
      expect(() => StreamProfile.schedule('nope', text), throwsA(isA<ArgumentError>()));
    });

    test('play delivers every chunk, a late timer delivering its backlog', () async {
      final got = <String>[];
      await play([
        (atUs: 0, text: 'a'),
        (atUs: 0, text: 'b'),
        (atUs: 30000, text: 'c'),
        (atUs: 31000, text: 'd'),
      ], got.add);
      expect(got, ['a', 'b', 'c', 'd']);
    });
  });

  test('the history has the rows asked for and ends on an answer', () {
    final state = historyState(2000);
    expect(state.items, hasLength(2000));
    expect((state.items.last as TranscriptMessage).role, MessageRole.agent);
    expect(historyState(7).items, hasLength(7));
  });

  group('the session', () {
    test('notifies once for a burst of chunks and costs are logged per chunk', () async {
      final session = StreamBenchSession(historyState(50));
      var told = 0;
      session.addListener(() => told++);
      for (var i = 0; i < 20; i++) {
        session.ingestText('word$i ');
      }
      expect(told, 0, reason: 'the notification waits for its timer, as in AcpAgentSession');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(told, 1);
      expect(session.chunkCostUs, hasLength(20));
      expect(session.notifyUs, hasLength(1));
      final answer = session.state.items.last as TranscriptMessage;
      expect((answer.blocks.single as TextBlock).text, startsWith('word0 word1'));
      session.dispose();
    });
  });

  testWidgets('the probe reads how much of a streamed answer the real screen shows', (tester) async {
    tester.view.physicalSize = const Size(412, 892) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final session = StreamBenchSession(historyState(300));
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light(), home: AgentSessionScreen(session: session)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final scrollables = tester.stateList<ScrollableState>(find.byType(Scrollable)).toList()
      ..sort((a, b) => b.position.viewportDimension.compareTo(a.position.viewportDimension));
    final root = scrollables.first.context.findRenderObject();
    final probe = LagProbe();
    final text = syntheticAnswer(4000);
    var us = 0;
    for (final a in StreamProfile.schedule(StreamProfile.synthetic, text).take(300)) {
      us = a.atUs;
      probe.record(a.text, us);
      session.ingestText(a.text);
    }
    expect(probe.received, greaterThan(500));
    expect(probe.lag(us).pending, probe.received, reason: 'nothing is painted before a frame');

    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 40));
    expect(probe.read(root, 892), isTrue, reason: 'a paragraph of the answer is on screen');
    expect(probe.painted, greaterThan(0));
    expect(probe.painted, lessThanOrEqualTo(probe.received));
    expect(probe.lag(us + 1000).pending, probe.received - probe.painted);
  });

  testWidgets('the probe sees the reveal of the live row: text waits behind the pacing, then all of it is shown', (tester) async {
    tester.view.physicalSize = const Size(412, 892) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final session = StreamBenchSession(historyState(300));
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light(), home: AgentSessionScreen(session: session)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final scrollables = tester.stateList<ScrollableState>(find.byType(Scrollable)).toList()
      ..sort((a, b) => b.position.viewportDimension.compareTo(a.position.viewportDimension));
    final root = scrollables.first.context.findRenderObject();
    final probe = LagProbe();
    final arrivals = StreamProfile.schedule(StreamProfile.synthetic, syntheticAnswer(4000));

    // The first chunk makes the live row (what is there when it shows is history).
    probe.record(arrivals.first.text, arrivals.first.atUs);
    session.ingestText(arrivals.first.text);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 40));

    var us = 0;
    for (final a in arrivals.skip(1).take(300)) {
      us = a.atUs;
      probe.record(a.text, us);
      session.ingestText(a.text);
    }
    await tester.pump(const Duration(milliseconds: 40));
    expect(probe.read(root, 892), isTrue, reason: 'the paragraphs of the live row are found');
    expect(probe.lag(us + 1000).pending, greaterThan(0), reason: 'the reveal is behind the arrival, as designed');

    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(probe.read(root, 892), isTrue);
    expect(probe.lag(us + 2000000).pending, lessThan(60), reason: 'everything that arrived is on screen');
  });
}
