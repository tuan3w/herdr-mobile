import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/pane/live_edge.dart';

final _epoch = DateTime(2026, 1, 1, 12);

/// A [LiveEdge] whose clock the test moves, and every timer created while its
/// widget builds, ticks or updates (the zone sees them all).
class _Harness {
  _Harness(this.tester);

  final WidgetTester tester;
  var now = _epoch;
  DateTime? lastRead = _epoch;
  final timers = <Timer>[];

  /// Timers still waiting to fire.
  int get active => timers.where((t) => t.isActive).length;

  Future<T> _tracked<T>(Future<T> Function() body) => runZoned(
        body,
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, f) {
            final timer = parent.createTimer(zone, duration, f);
            timers.add(timer);
            return timer;
          },
        ),
      );

  Future<void> show({
    bool stale = false,
    bool failed = false,
    bool streaming = false,
    bool tickers = true,
    bool dark = true,
    bool reduceMotion = false,
  }) =>
      _tracked(
        () => tester.pumpWidget(
          MaterialApp(
            theme: dark ? AppTheme.dark() : AppTheme.light(),
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduceMotion),
              child: TickerMode(
                enabled: tickers,
                child: SizedBox(
                  width: 300,
                  height: 200,
                  child: LiveEdge(
                    stale: stale,
                    failed: failed,
                    streaming: streaming,
                    lastRead: () => lastRead,
                    now: () => now,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  /// Moves the clock and the test's clock by [by] together.
  Future<void> pass(Duration by) {
    now = now.add(by);
    return _tracked(() => tester.pump(by));
  }
}

Color _rule(WidgetTester tester) {
  final box = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
  return (box.decoration! as BoxDecoration).color!;
}

void main() {
  test('the label counts in the largest whole unit', () {
    expect(staleLabel(Duration.zero), 'stale · 0s');
    expect(staleLabel(const Duration(seconds: 12, milliseconds: 900)), 'stale · 12s');
    expect(staleLabel(const Duration(seconds: 59)), 'stale · 59s');
    expect(staleLabel(const Duration(seconds: 60)), 'stale · 1m');
    expect(staleLabel(const Duration(minutes: 59, seconds: 59)), 'stale · 59m');
    expect(staleLabel(const Duration(hours: 3)), 'stale · 3h');
    expect(staleLabel(const Duration(seconds: -4)), 'stale · 0s',
        reason: 'a clock that stepped back never shows a negative age');
  });

  group('live', () {
    testWidgets('has no label, and starts no timer', (tester) async {
      final h = _Harness(tester);
      await h.show(streaming: true);
      await h.pass(const Duration(seconds: 30));

      expect(find.textContaining('stale'), findsNothing);
      expect(h.timers, isEmpty);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('is tinted while output streams and a hairline while quiet',
        (tester) async {
      final h = _Harness(tester);
      final ds = AppTheme.dark().extension<Ds>()!;

      await h.show(streaming: true);
      await tester.pumpAndSettle();
      expect(_rule(tester).a, lessThan(1));
      expect(_rule(tester).toARGB32() & 0xFFFFFF, ds.accent.toARGB32() & 0xFFFFFF);

      await h.show();
      await tester.pumpAndSettle();
      expect(_rule(tester), ds.hairline);
      expect(h.timers, isEmpty);
    });

    testWidgets('the rule is 2 px at the bottom edge', (tester) async {
      await _Harness(tester).show();
      final rule = tester.getRect(find.byType(AnimatedContainer));
      final box = tester.getRect(find.byType(LiveEdge));
      expect(rule.height, 2);
      expect(rule.bottom, box.bottom);
      expect(rule.width, box.width);
    });
  });

  group('stale', () {
    testWidgets('says how long since the last read that worked', (tester) async {
      final h = _Harness(tester);
      h.now = _epoch.add(const Duration(seconds: 12, milliseconds: 400));
      await h.show(stale: true, failed: true);

      expect(find.text('stale · 12s'), findsOneWidget);
    });

    testWidgets('redraws once a second while stale, with one timer at a time',
        (tester) async {
      final h = _Harness(tester);
      h.now = _epoch.add(const Duration(seconds: 12));
      await h.show(stale: true, failed: true);
      expect(find.text('stale · 12s'), findsOneWidget);
      expect(h.active, 1);

      await h.pass(const Duration(milliseconds: 500));
      expect(find.text('stale · 12s'), findsOneWidget, reason: 'not before the second');
      await h.pass(const Duration(milliseconds: 500));
      expect(find.text('stale · 13s'), findsOneWidget);
      expect(h.active, 1);

      await h.pass(const Duration(seconds: 3));
      expect(find.text('stale · 16s'), findsOneWidget);
      expect(h.timers.length, 5, reason: 'one per second, never more than one waiting');
      expect(h.active, 1);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('goes quiet again the moment the pane is live', (tester) async {
      final h = _Harness(tester);
      await h.show(stale: true, failed: true);
      await h.pass(const Duration(seconds: 2));
      expect(h.active, 1);

      await h.show(streaming: true);
      expect(find.textContaining('stale'), findsNothing);
      expect(h.active, 0, reason: 'the timer was cancelled, not left to fire');
      final created = h.timers.length;
      await h.pass(const Duration(seconds: 10));
      expect(h.timers.length, created);
    });

    testWidgets('is shown again when it goes stale again', (tester) async {
      final h = _Harness(tester);
      await h.show();
      expect(h.timers, isEmpty);
      await h.show(stale: true, failed: true);
      expect(find.textContaining('stale · '), findsOneWidget);
      expect(h.active, 1);
    });

    testWidgets('does not tick while the tab is not on screen', (tester) async {
      final h = _Harness(tester);
      await h.show(stale: true, failed: true, tickers: false);
      await h.pass(const Duration(seconds: 5));
      expect(h.timers, isEmpty);

      await h.show(stale: true, failed: true);
      expect(h.active, 1, reason: 'back on screen: ticking again');
    });

    testWidgets('has no label (and no timer) before the first read', (tester) async {
      final h = _Harness(tester)..lastRead = null;
      await h.show(stale: true);
      await h.pass(const Duration(seconds: 3));

      expect(find.textContaining('stale'), findsNothing);
      expect(h.timers, isEmpty);
    });

    testWidgets('leaving stops the timer', (tester) async {
      final h = _Harness(tester);
      await h.show(stale: true, failed: true);
      expect(h.active, 1);

      await tester.pumpWidget(const SizedBox());
      expect(h.active, 0);
    });

    testWidgets('the rule is danger when a read failed, muted when only the '
        'link is down', (tester) async {
      final h = _Harness(tester);
      final ds = AppTheme.dark().extension<Ds>()!;

      await h.show(stale: true, failed: true);
      await tester.pumpAndSettle();
      expect(_rule(tester), ds.danger);

      await h.show(stale: true);
      await tester.pumpAndSettle();
      expect(_rule(tester), ds.textMuted);
    });

    testWidgets('colour changes snap under reduced motion', (tester) async {
      final h = _Harness(tester);
      final ds = AppTheme.dark().extension<Ds>()!;
      await h.show(reduceMotion: true);
      await h.show(stale: true, failed: true, reduceMotion: true);
      await tester.pump();
      expect(_rule(tester), ds.danger);
    });

    testWidgets('the label reads in a calm voice, not once a second',
        (tester) async {
      final semantics = tester.ensureSemantics();
      final h = _Harness(tester);
      await h.show(stale: true, failed: true);

      expect(find.bySemanticsLabel('Output is stale'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'\d+s')), findsNothing);
      semantics.dispose();
    });
  });
}
