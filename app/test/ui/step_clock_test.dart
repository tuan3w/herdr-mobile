// The working glyph's one shared clock: it must only run while a working glyph
// is on screen, never faster than 4 steps a second, never for a hidden tab or
// a user who asked for less motion, and never in the background.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/ui/core/glyphs.dart';
import 'package:herdr_mobile/ui/core/step_clock.dart';
import 'package:herdr_mobile/ui/core/theme.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  bool reduceMotion = false,
}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        builder: (context, app) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
          child: app!,
        ),
        home: Scaffold(body: Center(child: child)),
      ),
    );

Widget _glyphs(int n, {AgentStatus status = AgentStatus.working}) => Wrap(
      children: [for (var i = 0; i < n; i++) StatusGlyph(status: status, size: 22)],
    );

void main() {
  tearDown(() {
    // A leaked lease would keep a timer alive for every later test.
    expect(StepClock.glyph.leases, 0, reason: 'glyph clock lease leaked');
    expect(StepClock.minute.leases, 0, reason: 'minute clock lease leaked');
  });

  group('StepClock', () {
    testWidgets('ten working glyphs share one timer; it stops with the last of them',
        (tester) async {
      await _pump(tester, _glyphs(10));
      expect(StepClock.glyph.leases, 10);
      expect(StepClock.glyph.running, isTrue);

      await _pump(tester, const SizedBox());
      expect(StepClock.glyph.leases, 0);
      expect(StepClock.glyph.running, isFalse, reason: 'nothing animates, nothing ticks');
    });

    testWidgets('only a working glyph asks for the clock', (tester) async {
      for (final s in [AgentStatus.blocked, AgentStatus.done, AgentStatus.idle, AgentStatus.unknown]) {
        await _pump(tester, _glyphs(3, status: s));
        expect(StepClock.glyph.leases, 0, reason: '$s must stay static');
        expect(StepClock.glyph.running, isFalse);
      }
    });

    testWidgets('steps at most four times a second', (tester) async {
      await _pump(tester, _glyphs(10));
      final before = StepClock.glyph.steps.value;
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      final steps = StepClock.glyph.steps.value - before;
      expect(steps, inInclusiveRange(7, 8), reason: '2 s at <= 4 steps/s is 8 steps, not 100 frames; got $steps');
    });

    testWidgets('reduced motion: no lease, no timer, the arc rests', (tester) async {
      await _pump(tester, _glyphs(4), reduceMotion: true);
      expect(StepClock.glyph.leases, 0);
      expect(StepClock.glyph.running, isFalse);
    });

    testWidgets('a glyph in a hidden tab (TickerMode off) does not tick, and wakes when shown',
        (tester) async {
      Widget tree(bool visible) => TickerMode(enabled: visible, child: _glyphs(3));

      await _pump(tester, tree(false));
      expect(StepClock.glyph.leases, 0);
      expect(StepClock.glyph.running, isFalse);

      await _pump(tester, tree(true));
      expect(StepClock.glyph.leases, 3);
      expect(StepClock.glyph.running, isTrue);

      await _pump(tester, tree(false));
      expect(StepClock.glyph.leases, 0, reason: 'covered or hidden again: back to sleep');
    });

    testWidgets('a stale (dimmed) or non-animated glyph rests too', (tester) async {
      await _pump(
        tester,
        const Wrap(children: [
          StatusGlyph(status: AgentStatus.working, dim: true),
          StatusGlyph(status: AgentStatus.working, animate: false),
        ]),
      );
      expect(StepClock.glyph.leases, 0);
    });

    testWidgets('the timer pauses in the background and resumes in the foreground',
        (tester) async {
      await _pump(tester, _glyphs(2));
      expect(StepClock.glyph.running, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(StepClock.glyph.running, isFalse);
      final frozen = StepClock.glyph.steps.value;
      await tester.pump(const Duration(seconds: 5));
      expect(StepClock.glyph.steps.value, frozen, reason: 'no ticks while backgrounded');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(StepClock.glyph.running, isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(StepClock.glyph.steps.value, greaterThan(frozen));
    });

    testWidgets('inactive (a shade pulled down) does not pause it', (tester) async {
      await _pump(tester, _glyphs(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(StepClock.glyph.running, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    testWidgets('a lease taken while the app is backgrounded does not start the timer',
        (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      StepClock.glyph.acquire();
      expect(StepClock.glyph.leases, 1);
      expect(StepClock.glyph.running, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(StepClock.glyph.running, isTrue);
      StepClock.glyph.release();
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
  });

  group('painting cost', () {
    testWidgets('a step repaints the glyphs only, never their neighbours', (tester) async {
      final neighbour = GlobalKey();
      await _pump(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RepaintBoundary(key: neighbour, child: const Text('static neighbour')),
            _glyphs(10),
          ],
        ),
      );
      final boundaries = find.descendant(
        of: find.byType(Wrap),
        matching: find.byType(RepaintBoundary),
      );
      expect(boundaries, findsNWidgets(10), reason: 'one repaint boundary per glyph');

      int total(RenderRepaintBoundary b) => b.debugSymmetricPaintCount + b.debugAsymmetricPaintCount;
      int paints(Finder f) =>
          f.evaluate().map((e) => total(e.renderObject! as RenderRepaintBoundary)).fold(0, (a, b) => a + b);
      int neighbourPaints() => total(neighbour.currentContext!.findRenderObject()! as RenderRepaintBoundary);
      final glyphBefore = paints(boundaries);
      final neighbourBefore = neighbourPaints();

      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      final glyphPaints = paints(boundaries) - glyphBefore;
      final neighbourRepaints = neighbourPaints() - neighbourBefore;

      // 2 s at 4 steps/s = 8 steps; each repaints all ten glyphs.
      expect(glyphPaints, inInclusiveRange(10 * 7, 10 * 9));
      expect(neighbourRepaints, 0, reason: 'a clock step must not repaint the rest of the screen');
      // Nothing was rebuilt either: no widget listens to the clock.
      expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);
    });
  });
}
