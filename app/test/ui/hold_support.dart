import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/hold_confirm.dart';

/// How full the fill of the [chip]th hold chip on screen is (0..1).
double fillOf(WidgetTester tester, {int chip = 0}) {
  final paint = tester.widget<CustomPaint>(
    find.descendant(of: find.byType(HoldToConfirm).at(chip), matching: find.byKey(holdFillKey)),
  );
  return (paint.painter! as HoldFillPainter).progress.value;
}

/// Puts a finger on the centre of [finder] and keeps it there for [time], in
/// 50 ms frames (a fill only moves while frames come). Returns the gesture,
/// still down.
Future<TestGesture> pressAndHold(WidgetTester tester, Finder finder, Duration time) async {
  final gesture = await tester.startGesture(tester.getCenter(finder));
  await advance(tester, time);
  return gesture;
}

/// Frames of 50 ms until [time] has passed.
Future<void> advance(WidgetTester tester, Duration time) async {
  var left = time;
  while (left > Duration.zero) {
    final step = left < const Duration(milliseconds: 50) ? left : const Duration(milliseconds: 50);
    await tester.pump(step);
    left -= step;
  }
}

/// A whole hold: down, [time] (a hold is ~700 ms; the default is a little over
/// it), up, and a moment for the fill to go back.
Future<void> holdFor(
  WidgetTester tester,
  Finder finder, [
  Duration time = const Duration(milliseconds: 900),
]) async {
  final gesture = await pressAndHold(tester, finder, time);
  await gesture.up();
  await advance(tester, const Duration(milliseconds: 250));
}

/// A tap: down and up at once. Does not wait for the hint to go away.
Future<void> quickTap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump();
}
