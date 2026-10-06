import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/brand_mark.dart';

Widget _app({bool reduced = false}) => MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: child!,
      ),
      home: const Center(child: BrandMark()),
    );

Finder get _paint => find.descendant(of: find.byType(BrandMark), matching: find.byType(CustomPaint));

void main() {
  testWidgets('draws the crook, then the shoulder, then the dot lands, once, and stops', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pump();
    expect(_paint, paints..rrect(), reason: 'the tile is there from the first frame');
    expect(_paint, isNot(paints..rrect()..path()), reason: 'nothing of the mark at the first frame');

    await tester.pump(const Duration(milliseconds: 40));
    expect(_paint, paints..rrect()..path(), reason: 'the stem starts rising');
    expect(_paint, isNot(paints..rrect()..path()..path()), reason: 'the shoulder waits for the crook');
    expect(_paint, isNot(paints..circle()), reason: 'the dot lands last');

    await tester.pump(brandMarkDuration);
    expect(_paint, paints..rrect()..path()..path()..circle());
    expect(tester.binding.transientCallbackCount, 0, reason: 'no loop: the ticker is done');
  });

  testWidgets('with reduced motion the finished mark is there at once', (tester) async {
    await tester.pumpWidget(_app(reduced: true));

    expect(_paint, paints..rrect()..path()..path()..circle());
    expect(tester.binding.transientCallbackCount, 0);
  });
}
