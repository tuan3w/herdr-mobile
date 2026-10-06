import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/streaming/flush_scheduler.dart';
import 'package:herdr_mobile/ui/core/frame_flush.dart';

void main() {
  testWidgets('nextFrame runs once, at the start of the next frame, not before', (tester) async {
    final flush = FrameFlush();
    var ran = 0;
    flush.nextFrame(() => ran++);
    expect(ran, 0);
    await tester.pump();
    expect(ran, 1);
    await tester.pump();
    expect(ran, 1);
  });

  testWidgets('a notification made by the flush is built in the same frame', (tester) async {
    final flush = FrameFlush();
    final text = ValueNotifier('old');
    var builds = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ValueListenableBuilder<String>(
          valueListenable: text,
          builder: (context, value, _) {
            builds++;
            return Text(value);
          },
        ),
      ),
    );
    builds = 0;
    // A chunk arrives between frames; the session asks for the next frame.
    flush.nextFrame(() => text.value = 'new');
    expect(find.text('old'), findsOneWidget);
    await tester.pump();
    expect(find.text('new'), findsOneWidget, reason: 'flush, build and paint in one frame');
    expect(builds, 1);
  });

  testWidgets('a cancelled flush never runs; cancelling after it ran is harmless', (tester) async {
    final flush = FrameFlush();
    var ran = 0;
    final cancel = flush.nextFrame(() => ran++);
    cancel();
    await tester.pump();
    expect(ran, 0);

    final late = flush.nextFrame(() => ran++);
    await tester.pump();
    expect(ran, 1);
    late();
    await tester.pump();
    expect(ran, 1);
  });

  testWidgets('a flush asked for while the frame callbacks run belongs to the next frame', (tester) async {
    final flush = FrameFlush();
    var inner = 0;
    flush.nextFrame(() => flush.nextFrame(() => inner++));
    await tester.pump();
    expect(inner, 0);
    await tester.pump();
    expect(inner, 1);
  });

  testWidgets('with the app hidden no frame comes: a timer carries the flush', (tester) async {
    final flush = FrameFlush(hiddenDelay: const Duration(milliseconds: 100));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    expect(tester.binding.framesEnabled, isFalse);
    var ran = 0;
    flush.nextFrame(() => ran++);
    await tester.pump(const Duration(milliseconds: 50));
    expect(ran, 0);
    await tester.pump(const Duration(milliseconds: 60));
    expect(ran, 1);
  });

  testWidgets('after runs on a timer, frames or not, and can be cancelled', (tester) async {
    final FlushScheduler flush = FrameFlush();
    var ran = 0;
    flush.after(const Duration(seconds: 2), () => ran++);
    final cancel = flush.after(const Duration(seconds: 1), () => ran += 10);
    cancel();
    await tester.pump(const Duration(seconds: 3));
    expect(ran, 1);
  });
}
