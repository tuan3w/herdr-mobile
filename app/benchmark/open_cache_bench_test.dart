// Time from opening a session screen to the first frame with transcript rows
// in it, for a 600-message session over the fake keeper, with and without the
// transcript cache. A desktop number, taken in the test binding (frames are
// pumped, nothing is rasterised): it counts what the app does on the UI thread
// and the disk read of the cache, not a phone's CPU, GPU or network.
//
//   flutter test benchmark/open_cache_bench_test.dart
//
// RTT is simulated: the fake host answers `attach` after OPEN_ATTACH_MS
// milliseconds (default 0 and 150: SSH exec channel + keeper start +
// `initialize`; the replay itself crosses an in-memory pipe, so a real link
// would add its transfer time for the ~0.5 MB log on top).
//
// Taken on a quiet desktop (median of 5, debug JIT, test binding; a 309 KB copy):
//
//   keeper answers after      0 ms     150 ms
//   before (no cache, whole plan)   130 ms    261 ms   first frame with transcript rows
//   tail-first plan, no cache        83 ms    216 ms
//   tail-first plan + cache          85 ms     54 ms
//
// The cache takes the keeper's answer out of the wait (54 ms is the disk read in
// a worker, the fold of 700 items and one frame, whatever the link does); the
// first-frame plan takes ~45 ms out of every open. With a keeper that answers
// at once there is nothing to hide, and the cache neither helps nor costs.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/acp_agent_session.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/transcript_cache.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';

import '../test/support/fake_agent_host.dart';
import '../test/support/fake_transport.dart';

const _turns = 300; // 300 user + 300 agent messages

String _markdown(int i) =>
    'Here is what I found for step $i.\n\n'
    '- the first thing: `lib/feature_$i.dart` reads the config twice\n'
    '- the second thing: the retry loop never backs off\n'
    '- the third thing: the test for it is missing\n\n'
    '```dart\nFuture<void> run$i() async {\n  final config = await load();\n  await apply(config);\n}\n```\n\n'
    'I will fix the retry loop first and add the test after. This is a longer closing '
    'paragraph so that the message has a realistic weight: it explains why the change is '
    'safe, names the files touched, and says what to run to check it.';

void _fill(FakeKeeper keeper) {
  for (var i = 0; i < _turns; i++) {
    keeper.update(userChunk('Please look at step $i and tell me what is wrong with it.', messageId: 'u$i'));
    if (i % 3 == 0) {
      keeper.update({
        'sessionUpdate': 'tool_call',
        'toolCallId': 't$i',
        'title': 'Run dart test test/feature_${i}_test.dart',
        'kind': 'execute',
        'status': 'completed',
        'rawInput': {'command': 'dart test test/feature_${i}_test.dart'},
      });
    }
    keeper.update(agentChunk(_markdown(i), messageId: 'a$i'));
  }
}

Future<void> _real(WidgetTester tester, int ms) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  final attachDelays = [
    for (final s in (Platform.environment['OPEN_ATTACH_MS'] ?? '0,150').split(',')) int.parse(s),
  ];

  for (final attachMs in attachDelays) {
    testWidgets('open a 600-message session, attach answers after $attachMs ms', (tester) => tester.runAsync(() async {
      tester.view.physicalSize = const Size(824, 1784);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final dir = Directory.systemTemp.createTempSync('open_cache_bench');
      addTearDown(() => dir.deleteSync(recursive: true));

      final host = FakeAgentHost();
      final keeper = host.add(id: 'k1', sessionId: 'sess-k1');
      _fill(keeper);
      final machine = MachineConnection(
        profile: const MachineProfile(id: 'm1', label: 'studio', host: 'm1.local', username: 'u'),
        api: HerdrApi(FakeTransport()),
        backoff: (_) => const Duration(hours: 1),
        pollInterval: const Duration(hours: 1),
      )..start();
      await _real(tester, 20);
      addTearDown(machine.dispose);

      final cache = FileTranscriptCache(() async => dir);
      AcpAgentSession make(TranscriptCache? c) => AcpAgentSession(
        machine: machine,
        host: host,
        info: keeper.info,
        cache: c,
        notifyEvery: const Duration(milliseconds: 1),
      );

      Future<void> release(AcpAgentSession s) async {
        s.release();
        await cache.flush();
        s.dispose();
      }

      // A first run reads the whole log and leaves its copy behind.
      {
        final first = make(cache);
        await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: AgentSessionScreen(session: first)));
        for (var i = 0; i < 400 && !first.attached; i++) {
          await _real(tester, 5);
          await tester.pump();
        }
        expect(first.attached, isTrue);
        expect(first.state.items.length, greaterThan(_turns * 2));
        await tester.pumpWidget(const SizedBox());
        await release(first);
      }
      final size = dir.listSync().whereType<File>().map((f) => f.lengthSync()).fold<int>(0, (a, b) => a + b);

      /// Mounts the screen over a fresh session and counts until a frame shows
      /// the last answer.
      Future<({int firstMs, int liveMs, int swapMs})> open(TranscriptCache? c) async {
        host.attachGate = Completer<void>();
        final s = make(c);
        final clock = Stopwatch()..start();
        // The route being pushed: the screen's initState acquires the session.
        await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: AgentSessionScreen(session: s)));
        if (Platform.environment['OPEN_TRACE'] != null) {
          // ignore: avoid_print
          print('    pumpWidget returned at ${clock.elapsedMilliseconds} ms');
        }
        // The keeper's answer arrives `attachMs` after the open.
        unawaited(Future<void>.delayed(Duration(milliseconds: attachMs), host.attachGate!.complete));
        var firstMs = -1;
        var liveMs = -1;
        while ((firstMs < 0 || liveMs < 0) && clock.elapsedMilliseconds < 20000) {
          await _real(tester, 1);
          final p = Stopwatch()..start();
          await tester.pump(const Duration(milliseconds: 16));
          if (Platform.environment['OPEN_TRACE'] != null) {
            // ignore: avoid_print
            print('    t=${clock.elapsedMilliseconds} pump=${p.elapsedMilliseconds}ms attached=${s.attached} items=${s.state.items.length}');
          }
          final shown = find.textContaining('longer closing paragraph', findRichText: true).evaluate().isNotEmpty;
          if (firstMs < 0 && shown) firstMs = clock.elapsedMilliseconds;
          if (liveMs < 0 && s.attached) liveMs = clock.elapsedMilliseconds;
        }
        // Let the swap to the live replay settle, and measure the frame it costs.
        final swap = Stopwatch()..start();
        await tester.pump(const Duration(milliseconds: 16));
        final swapMs = swap.elapsedMilliseconds;
        await tester.pumpWidget(const SizedBox());
        s.dispose();
        return (firstMs: firstMs, liveMs: liveMs, swapMs: swapMs);
      }

      // Warm the JIT with one throwaway open of each kind.
      await open(null);
      await open(cache);

      final without = <int>[];
      final withCache = <int>[];
      final live = <int>[];
      final swaps = <int>[];
      for (var i = 0; i < 5; i++) {
        without.add((await open(null)).firstMs);
        final r = await open(cache);
        withCache.add(r.firstMs);
        live.add(r.liveMs);
        swaps.add(r.swapMs);
      }
      without.sort();
      withCache.sort();
      live.sort();
      swaps.sort();
      // ignore: avoid_print
      print(
        'OPEN_CACHE attach=${attachMs}ms cacheFile=${(size / 1024).round()}KB '
        'first transcript (median of 5): without cache ${without[2]} ms (${without.join(',')}), '
        'with cache ${withCache[2]} ms (${withCache.join(',')}); live replay done at ${live[2]} ms; frame after it ${swaps[2]} ms',
      );
    }), timeout: const Timeout(Duration(minutes: 4)));
  }
}
