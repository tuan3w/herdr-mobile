import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/keyboard_frames.dart';

void main() {
  testWidgets(
      'a frame is asked for at every vsync while the keyboard moves, and none once it is still',
      (tester) async {
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const KeyboardFrames(child: SizedBox()));
    expect(tester.binding.hasScheduledFrame, isFalse, reason: 'nothing moves');

    // The platform's update lands after the vsync it was meant for: the frame
    // it asks for would come one vsync late, so one must already be armed.
    tester.view.viewInsets = const FakeViewPadding(bottom: 120);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isTrue);

    for (final inset in [300.0, 520.0, 640.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.binding.hasScheduledFrame, isTrue, reason: 'still moving at $inset');
    }

    // The keyboard has stopped: it stays armed for a few frames, then lets go.
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.hasScheduledFrame, isTrue, reason: 'not mid-animation');
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.hasScheduledFrame, isFalse, reason: 'no looping animation');
  });

  testWidgets('a change that is not the keyboard does not start frames', (tester) async {
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const KeyboardFrames(child: SizedBox()));

    tester.view.padding = const FakeViewPadding(top: 80);
    await tester.pump();

    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
