// Nothing in the app animates on a timer except the elapsed-time labels: a
// working agent's glyph is a still half ring, and the shared clock runs only
// for labels that are mounted, visible and in the foreground.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/ui/core/glyphs.dart';
import 'package:herdr_mobile/ui/core/step_clock.dart';
import 'package:herdr_mobile/ui/core/theme.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  tearDown(() {
    // A leaked lease would keep a timer alive for every later test.
    expect(StepClock.minute.leases, 0, reason: 'minute clock lease leaked');
  });

  group('status glyphs', () {
    testWidgets('no status animates: no clock, no running animation', (tester) async {
      for (final status in AgentStatus.values) {
        await _pump(tester, StatusGlyph(status: status, size: 22));
        expect(StepClock.minute.leases, 0, reason: '$status');
        expect(tester.binding.transientCallbackCount, 0, reason: '$status must be still');
      }
    });

    testWidgets('a working glyph is still across time', (tester) async {
      await _pump(tester, const StatusGlyph(status: AgentStatus.working, size: 22));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump(const Duration(seconds: 2));
      expect(tester.binding.transientCallbackCount, 0);
    });
  });

  group('StepClock', () {
    testWidgets('widgets share one timer; it stops with the last lease', (tester) async {
      final clock = StepClock(const Duration(milliseconds: 250));
      clock.acquire();
      clock.acquire();
      expect(clock.leases, 2);
      expect(clock.running, isTrue);
      final before = clock.steps.value;
      await tester.pump(const Duration(seconds: 1));
      expect(clock.steps.value - before, 4);
      clock.release();
      expect(clock.running, isTrue);
      clock.release();
      expect(clock.running, isFalse);
    });

    testWidgets('the timer pauses in the background and resumes in the foreground',
        (tester) async {
      final clock = StepClock(const Duration(milliseconds: 250))..acquire();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(clock.running, isFalse);
      final frozen = clock.steps.value;
      await tester.pump(const Duration(seconds: 5));
      expect(clock.steps.value, frozen, reason: 'no ticks while backgrounded');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(clock.running, isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(clock.steps.value, greaterThan(frozen));
      clock.release();
    });

    testWidgets('inactive (a shade pulled down) does not pause it', (tester) async {
      final clock = StepClock(const Duration(milliseconds: 250))..acquire();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(clock.running, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      clock.release();
    });

    testWidgets('a lease taken while the app is backgrounded does not start the timer',
        (tester) async {
      final clock = StepClock(const Duration(milliseconds: 250));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      clock.acquire();
      expect(clock.leases, 1);
      expect(clock.running, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(clock.running, isTrue);
      clock.release();
    });

    testWidgets('minute labels poll twice a minute and only while mounted', (tester) async {
      var builds = 0;
      await _pump(tester, MinuteBuilder(builder: (context, now) {
        builds++;
        return Text('${now.year}');
      }));
      expect(StepClock.minute.leases, 1);
      final first = builds;
      await tester.pump(const Duration(seconds: 29));
      expect(builds, first, reason: 'nothing before the first half-minute');
      await tester.pump(const Duration(seconds: 2));
      expect(builds, first + 1);

      await _pump(tester, const SizedBox());
      expect(StepClock.minute.running, isFalse);
    });

    testWidgets('a label in a hidden tab (TickerMode off) does not tick, and wakes when shown',
        (tester) async {
      Widget tree(bool visible) => TickerMode(
            enabled: visible,
            child: MinuteBuilder(builder: (context, now) => const Text('12m')),
          );

      await _pump(tester, tree(false));
      expect(StepClock.minute.leases, 0);
      await _pump(tester, tree(true));
      expect(StepClock.minute.leases, 1);
      expect(StepClock.minute.running, isTrue);
      await _pump(tester, tree(false));
      expect(StepClock.minute.leases, 0, reason: 'covered or hidden again: back to sleep');
    });
  });
}
