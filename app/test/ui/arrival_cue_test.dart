// News that another agent needs you: one haptic for an agent that starts
// waiting (by key, so a handover is not news), quiet at start-up and in a
// burst, and a count that pops once when it rises.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/pop.dart';
import 'package:herdr_mobile/ui/shell/arrival_cue.dart';

const _armed = 'HapticFeedbackType.mediumImpact';

List<String> recordHaptics(WidgetTester tester) {
  final felt = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') felt.add(call.arguments as String);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return felt;
}

void main() {
  group('ArrivalCue', () {
    late DateTime clock;
    DateTime now() => clock;

    // [needsYou] wait and can be answered; [waiting] are last known to wait,
    // reachable or not.
    Future<void> keys(WidgetTester tester, Set<String> needsYou, {Set<String> waiting = const {}}) =>
        tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: ArrivalCue(needsYou: needsYou, waiting: {...waiting, ...needsYou}, now: now, child: const SizedBox()),
          ),
        );

    Future<void> show(WidgetTester tester, int n) => keys(tester, {for (var i = 0; i < n; i++) 'm/p$i'});

    setUp(() => clock = DateTime(2026, 10, 5, 12));

    testWidgets('an agent starting to wait is felt once; one stopping is not', (tester) async {
      final felt = recordHaptics(tester);
      await show(tester, 0);
      clock = clock.add(const Duration(seconds: 10));

      await show(tester, 1);
      expect(felt, [_armed]);

      clock = clock.add(const Duration(seconds: 10));
      await show(tester, 0);
      expect(felt, hasLength(1), reason: 'a count going down is not news');
    });

    testWidgets('not while the first snapshot arrives, and not for a burst', (tester) async {
      final felt = recordHaptics(tester);
      await show(tester, 0);

      clock = clock.add(const Duration(seconds: 1));
      await show(tester, 3);
      expect(felt, isEmpty, reason: 'the fleet catching up at start-up');

      clock = clock.add(const Duration(seconds: 5));
      await show(tester, 4);
      expect(felt, hasLength(1));

      clock = clock.add(const Duration(milliseconds: 500));
      await show(tester, 5);
      expect(felt, hasLength(1), reason: 'one tap on the shoulder for a burst');

      clock = clock.add(const Duration(seconds: 3));
      await show(tester, 6);
      expect(felt, hasLength(2));
    });

    testWidgets('not after the app came back to the front', (tester) async {
      final felt = recordHaptics(tester);
      await show(tester, 0);
      clock = clock.add(const Duration(seconds: 30));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      clock = clock.add(const Duration(seconds: 1));
      await show(tester, 2);
      expect(felt, isEmpty, reason: 'what was waiting while the app was away is not announced');

      clock = clock.add(const Duration(seconds: 5));
      await show(tester, 3);
      expect(felt, hasLength(1));
    });

    testWidgets('not while the app is in the background', (tester) async {
      final felt = recordHaptics(tester);
      await show(tester, 0);
      clock = clock.add(const Duration(seconds: 30));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await show(tester, 1);
      expect(felt, isEmpty);
    });

    testWidgets('a Wi-Fi to mobile handover is not news: the same agents back in reach are quiet', (tester) async {
      final felt = recordHaptics(tester);
      await keys(tester, {'a/p1', 'session/a/k1'});
      clock = clock.add(const Duration(seconds: 30));

      // The link drops: nothing can be answered, both are last known waiting.
      await keys(tester, {}, waiting: {'a/p1', 'session/a/k1'});
      clock = clock.add(const Duration(seconds: 5));
      await keys(tester, {'a/p1', 'session/a/k1'});
      expect(felt, isEmpty, reason: 'the set emptied and filled again with the same agents');
    });

    testWidgets('a new agent is felt even when another stopped at the same moment', (tester) async {
      final felt = recordHaptics(tester);
      await keys(tester, {'a/p1'});
      clock = clock.add(const Duration(seconds: 30));

      await keys(tester, {'session/a/k1'});
      expect(felt, [_armed], reason: 'one answered, another started waiting: the count stayed at 1');
    });

    testWidgets('an agent that stopped waiting and waits again is news again', (tester) async {
      final felt = recordHaptics(tester);
      await keys(tester, {'a/p1'});
      clock = clock.add(const Duration(seconds: 30));
      await keys(tester, {});
      clock = clock.add(const Duration(seconds: 30));
      await keys(tester, {'a/p1'});
      expect(felt, [_armed]);
    });
  });

  group('PopOnRise', () {
    Widget host(int value, {bool reduced = false}) => MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: PopOnRise(value: value, child: const SizedBox(key: ValueKey('badge'), width: 20, height: 20)),
      ),
    );

    double scaleOf(WidgetTester tester) {
      final scale = tester.widgetList<ScaleTransition>(find.byType(ScaleTransition));
      return scale.isEmpty ? 1.0 : scale.first.scale.value;
    }

    testWidgets('grows and settles once when the count rises; still at rest', (tester) async {
      await tester.pumpWidget(host(1));
      expect(find.byType(ScaleTransition), findsNothing, reason: 'nothing at rest, nothing on first show');

      await tester.pumpWidget(host(2));
      await tester.pump(const Duration(milliseconds: 60));
      expect(scaleOf(tester), greaterThan(1.05));
      await tester.pump(const Duration(milliseconds: 400));
      expect(scaleOf(tester), 1.0);
      expect(tester.hasRunningAnimations, isFalse, reason: 'it does not loop');
    });

    testWidgets('a count going down does not pop, and reduced motion skips it', (tester) async {
      await tester.pumpWidget(host(3));
      await tester.pumpWidget(host(2));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.byType(ScaleTransition), findsNothing);

      await tester.pumpWidget(host(2, reduced: true));
      await tester.pumpWidget(host(4, reduced: true));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.byType(ScaleTransition), findsNothing);
    });
  });
}
