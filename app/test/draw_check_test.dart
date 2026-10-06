import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/draw_check.dart';

Widget _app({bool reduced = false}) => MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: child!,
      ),
      home: const Center(child: DrawCheck(color: Colors.green)),
    );

Finder get _paint => find.descendant(of: find.byType(DrawCheck), matching: find.byType(CustomPaint));

void main() {
  testWidgets('strokes the circle, then the check, once, and stops', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pump();
    expect(_paint, isNot(paints..path()), reason: 'nothing is drawn at the first frame');

    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
    expect(_paint, paints..path(), reason: 'the circle starts');
    expect(_paint, isNot(paints..path()..path()), reason: 'the check waits for the circle');

    await tester.pump(drawCheckDuration);
    expect(_paint, paints..path()..path());
    expect(tester.binding.transientCallbackCount, 0, reason: 'no loop: the ticker is done');
  });

  testWidgets('with reduced motion the finished mark is there at once', (tester) async {
    await tester.pumpWidget(_app(reduced: true));

    expect(_paint, paints..path()..path());
    expect(tester.binding.transientCallbackCount, 0);
  });
}
