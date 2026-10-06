import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/ui/core/terminal_view.dart';
import 'package:herdr_mobile/ui/core/theme.dart';

/// The haptics fired so far, by the platform's name for them.
List<String> _haptics(WidgetTester tester) {
  final fired = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') fired.add(call.arguments as String);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return fired;
}

const _tick = 'HapticFeedbackType.selectionClick';
const _hold = 'HapticFeedbackType.mediumImpact';

void main() {
  group('ZoomDetents', () {
    List<ZoomDetent> run(double start, List<double> sizes) {
      final d = ZoomDetents(start);
      return [for (final s in sizes) d.update(s)];
    }

    test('a step each time the size moves to another whole size, none inside one', () {
      expect(run(12, [12.25, 12.5, 12.5, 12.75, 13, 13.25, 13.75]), [
        ZoomDetent.none,
        ZoomDetent.none,
        ZoomDetent.none,
        ZoomDetent.step, // 12.75 is nearer 13
        ZoomDetent.none,
        ZoomDetent.none,
        ZoomDetent.step, // 13.75 is nearer 14
      ]);
    });

    test('wobbling across a boundary sounds once, not on every crossing', () {
      final r = run(12, [12.5, 12.75, 12.5, 12.75, 12.5, 12.75]);
      expect(r.where((d) => d == ZoomDetent.step), hasLength(1));
    });

    test('going back down sounds at the same distance, then once per step', () {
      expect(run(12, [12.75, 12.25, 11.5, 11.25]), [
        ZoomDetent.step, // up to 13
        ZoomDetent.step, // 12.25: 0.75 below the step it was on (13)
        ZoomDetent.none, // 11.5 is 0.5 from 12
        ZoomDetent.step, // 11.25: 0.75 from 12
      ]);
    });

    test('reaching the largest and smallest size is a stop, once until it leaves', () {
      expect(run(21, [21.75, 22, 22, 21.5, 22]), [
        ZoomDetent.none, // the step onto the end size stays silent
        ZoomDetent.stop,
        ZoomDetent.none,
        ZoomDetent.none, // not yet a whole step away: still disarmed
        ZoomDetent.none,
      ]);
      expect(run(21, [22, 20.75, 22]), [ZoomDetent.stop, ZoomDetent.step, ZoomDetent.stop]);
      expect(run(9, [8.25, 8, 8, 9.5, 8]), [
        ZoomDetent.none,
        ZoomDetent.stop,
        ZoomDetent.none,
        ZoomDetent.step,
        ZoomDetent.stop,
      ]);
    });

    test('a pinch that starts on an end-stop does not sound until it comes back', () {
      expect(run(maxTerminalFontSize, [22, 21.25]), [ZoomDetent.none, ZoomDetent.step]);
      expect(run(minTerminalFontSize, [8, 8.25, 8.75]), [ZoomDetent.none, ZoomDetent.none, ZoomDetent.step]);
    });
  });

  group('pinching the terminal', () {
    Future<ValueNotifier<double>> pump(WidgetTester tester) async {
      final size = ValueNotifier(defaultTerminalFontSize);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 360,
              height: 400,
              child: ValueListenableBuilder<double>(
                valueListenable: size,
                builder: (_, value, _) => TerminalView(
                  text: 'a\r\nb',
                  fontSize: value,
                  onFontSizeChanged: (v) => size.value = v,
                ),
              ),
            ),
          ),
        ),
      ));
      return size;
    }

    testWidgets('ticks on whole sizes, holds at the end-stops, silent between', (tester) async {
      final fired = _haptics(tester);
      await pump(tester);
      final a = await tester.startGesture(const Offset(130, 200), pointer: 1);
      final b = await tester.startGesture(const Offset(230, 200), pointer: 2);
      await tester.pump();
      Future<void> spread(double distance) async {
        await b.moveTo(Offset(130 + distance, 200));
        await tester.pump();
      }

      await spread(105); // 12.0: the step it started on
      expect(fired, isEmpty);

      await spread(110); // 12.75
      expect(fired, [_tick]);
      await spread(112); // 12.75 again, inside the step
      await spread(111);
      expect(fired, [_tick], reason: 'no haptic while the size stays put');

      await spread(120); // 13.75
      expect(fired, [_tick, _tick]);

      await spread(300); // clamped to 22
      expect(fired, [_tick, _tick, _hold]);
      await spread(320);
      await spread(350);
      expect(fired, [_tick, _tick, _hold], reason: 'the stop sounds once per visit');

      await spread(10); // all the way down to 8
      expect(fired, [_tick, _tick, _hold, _hold]);

      await a.up();
      await b.up();
    });

    testWidgets('a pinch that starts on the stop is silent', (tester) async {
      final fired = _haptics(tester);
      final size = await pump(tester);
      Future<void> pinchTo(double distance) async {
        final a = await tester.startGesture(const Offset(130, 200), pointer: 1);
        final b = await tester.startGesture(const Offset(230, 200), pointer: 2);
        await tester.pump();
        await b.moveTo(Offset(130 + distance, 200));
        await tester.pump();
        await a.up();
        await b.up();
        await tester.pump();
      }

      await pinchTo(300);
      expect(size.value, maxTerminalFontSize);
      expect(fired, [_hold]);

      await pinchTo(120); // the size is already the largest one
      expect(size.value, maxTerminalFontSize);
      expect(fired, [_hold]);
    });
  });
}
