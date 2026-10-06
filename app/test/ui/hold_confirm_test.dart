// HoldToConfirm: the press-and-hold that gates a risky answer.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/hold_confirm.dart';
import 'package:herdr_mobile/ui/core/theme.dart';

import 'hold_support.dart';

class _Probe {
  int confirmed = 0;
  int activated = 0;
  bool enabled = true;
}

const _chip = Key('chip');

Future<void> _pump(WidgetTester tester, _Probe probe, {bool reduced = false}) async {
  Widget app() => MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: HoldToConfirm(
                enabled: probe.enabled,
                onConfirmed: () => probe.confirmed++,
                onActivate: () => probe.activated++,
                builder: (context, hold) => ColoredBox(
                  key: _chip,
                  color: Colors.white,
                  child: SizedBox(
                    height: 44,
                    child: Stack(
                      children: [
                        hold.fill,
                        Text(hold.holding ? 'holding' : (hold.hint ? 'hint' : 'rest')),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
  await tester.pumpWidget(app());
}

void main() {
  testWidgets('a full hold confirms exactly once, however long the finger stays', (tester) async {
    final probe = _Probe();
    await _pump(tester, probe);

    final g = await pressAndHold(tester, find.byKey(_chip), const Duration(milliseconds: 900));
    expect(probe.confirmed, 1);
    await advance(tester, const Duration(seconds: 2));
    expect(probe.confirmed, 1, reason: 'one press, one confirmation');
    expect(fillOf(tester), 0, reason: 'the fill goes back after it confirmed');
    await g.up();
    await advance(tester, const Duration(milliseconds: 300));
    expect(probe.confirmed, 1);
    expect(find.text('hint'), findsNothing, reason: 'lifting after a confirmation is not an early release');

    await holdFor(tester, find.byKey(_chip));
    expect(probe.confirmed, 2, reason: 'a new press is a new hold');
  });

  testWidgets('letting go at half way sends nothing, says how, and the fill snaps back', (tester) async {
    final probe = _Probe();
    await _pump(tester, probe);

    final g = await pressAndHold(tester, find.byKey(_chip), const Duration(milliseconds: 425));
    expect(find.text('holding'), findsOneWidget);
    expect(fillOf(tester), closeTo(0.5, 0.2));

    await g.up();
    await tester.pump();
    expect(find.text('hint'), findsOneWidget);
    await advance(tester, holdSnapBack + const Duration(milliseconds: 50));
    expect(fillOf(tester), 0);
    expect(probe.confirmed, 0);
    await advance(tester, const Duration(seconds: 2));
    expect(probe.confirmed, 0);

    await advance(tester, holdHintWindow);
    expect(find.text('hint'), findsNothing, reason: 'the hint is short-lived');
  });

  testWidgets('a quick tap confirms nothing, fills nothing, and shows the hint', (tester) async {
    final probe = _Probe();
    await _pump(tester, probe);

    await tester.tap(find.byKey(_chip));
    await tester.pump();
    expect(find.text('hint'), findsOneWidget);
    expect(fillOf(tester), 0);
    await advance(tester, const Duration(seconds: 1));
    expect(probe.confirmed, 0);
    expect(probe.activated, 0, reason: 'a pointer tap is never the assistive activation');
    await advance(tester, holdHintWindow);
  });

  testWidgets('under reduced motion the fill still shows but goes back at once', (tester) async {
    final probe = _Probe();
    await _pump(tester, probe, reduced: true);

    final g = await pressAndHold(tester, find.byKey(_chip), const Duration(milliseconds: 425));
    expect(fillOf(tester), greaterThan(0.2), reason: 'progress is information, not decoration');
    await g.up();
    await tester.pump();
    expect(fillOf(tester), 0);
    await advance(tester, holdHintWindow);
  });

  testWidgets('only the first finger counts: another one neither restarts nor ends the hold', (tester) async {
    final probe = _Probe();
    await _pump(tester, probe);

    final first = await pressAndHold(tester, find.byKey(_chip), const Duration(milliseconds: 300));
    final second = await tester.startGesture(tester.getCenter(find.byKey(_chip)) + const Offset(40, 0));
    await advance(tester, const Duration(milliseconds: 100));
    await second.up();
    await tester.pump();
    expect(find.text('hint'), findsNothing, reason: 'the extra finger left without a word');
    expect(find.text('holding'), findsOneWidget);
    expect(probe.confirmed, 0);

    await advance(tester, const Duration(milliseconds: 500));
    expect(probe.confirmed, 1);
    await first.up();
    await advance(tester, const Duration(milliseconds: 300));
    expect(probe.confirmed, 1);
  });

  testWidgets('a finger that leaves the chip drops the hold without a hint or a send', (tester) async {
    final probe = _Probe();
    await _pump(tester, probe);

    final g = await pressAndHold(tester, find.byKey(_chip), const Duration(milliseconds: 400));
    expect(find.text('holding'), findsOneWidget);
    await g.moveBy(const Offset(0, 80));
    await tester.pump();
    expect(find.text('holding'), findsNothing);
    await advance(tester, const Duration(milliseconds: 300));
    expect(fillOf(tester), 0);
    await advance(tester, const Duration(seconds: 1));
    await g.up();
    await tester.pump();
    expect(probe.confirmed, 0);
    expect(find.text('hint'), findsNothing, reason: 'dragging away is not a tap');
  });

  testWidgets('a scroll that starts on the chip drops the hold', (tester) async {
    final probe = _Probe();
    await _pump(tester, probe);

    final g = await pressAndHold(tester, find.byKey(_chip), const Duration(milliseconds: 300));
    // Further than a touch slop, still over the chip.
    await g.moveBy(const Offset(60, 0));
    await advance(tester, const Duration(seconds: 1));
    await g.up();
    await tester.pump();
    expect(probe.confirmed, 0);
  });

  testWidgets('disabling the chip mid-hold cancels it', (tester) async {
    final probe = _Probe();
    await _pump(tester, probe);

    final g = await pressAndHold(tester, find.byKey(_chip), const Duration(milliseconds: 400));
    expect(find.text('holding'), findsOneWidget);
    probe.enabled = false;
    await _pump(tester, probe);
    expect(find.text('holding'), findsNothing);
    await advance(tester, const Duration(seconds: 1));
    await g.up();
    await tester.pump();
    expect(probe.confirmed, 0);

    // And a disabled chip takes no hold at all.
    await holdFor(tester, find.byKey(_chip));
    expect(probe.confirmed, 0);
  });

  testWidgets('the accessibility activation goes to onActivate, never to onConfirmed', (tester) async {
    final semantics = tester.ensureSemantics();
    final probe = _Probe();
    await _pump(tester, probe);

    tester.semantics.tap(find.semantics.byLabel('rest'));
    await tester.pump();
    expect(probe.activated, 1);
    expect(probe.confirmed, 0);
    semantics.dispose();
  });
}
