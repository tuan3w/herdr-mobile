import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/ui/core/kit.dart';

// A status or a count that changes again while its settle is still moving
// retargets from where it is: it never snaps back to the start and replays
// (docs/DESIGN.md "Motion": interruption starts from the live value).

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.light(),
  home: Scaffold(body: Center(child: child)),
);

/// How far the glyph's settle has got (null at rest).
double? _glyphProgress(WidgetTester tester) {
  final paints = tester.widgetList<CustomPaint>(
    find.descendant(of: find.byType(StatusGlyph), matching: find.byType(CustomPaint)),
  );
  final painter = paints.map((p) => p.painter).firstWhere((p) => p.runtimeType.toString() == '_GlyphPainter');
  return (painter as dynamic).progress?.value as double?;
}

/// How visible the arriving digits of a RollText are (the roll's own progress).
double _arriving(WidgetTester tester) =>
    tester.widgetList<Opacity>(find.descendant(of: find.byType(RollText), matching: find.byType(Opacity))).last.opacity;

void main() {
  const half = Duration(milliseconds: 120);

  testWidgets('a status that changes twice inside one settle never snaps back to the start', (tester) async {
    Widget glyph(AgentStatus s) => _app(StatusGlyph(status: s));
    await tester.pumpWidget(glyph(AgentStatus.idle));
    await tester.pumpWidget(glyph(AgentStatus.working));
    await tester.pump(half);
    final before = _glyphProgress(tester)!;
    expect(before, greaterThan(0.3), reason: 'the first settle is under way');
    expect(before, lessThan(1));

    await tester.pumpWidget(glyph(AgentStatus.blocked));
    final after = _glyphProgress(tester)!;
    expect(after, greaterThanOrEqualTo(before), reason: 'the second change continues from where the first got to');

    await tester.pump(Motion.settle * 2);
    expect(_glyphProgress(tester), isNull, reason: 'the settle ended and the glyph is at rest');
    expect(tester.hasRunningAnimations, isFalse, reason: 'no ticker left running');
  });

  testWidgets('a count that changes twice inside one roll keeps rolling from where it is', (tester) async {
    Widget count(String t) => _app(RollText(text: t));
    await tester.pumpWidget(count('3 agents'));
    await tester.pumpWidget(count('4 agents'));
    await tester.pump(half);
    final before = _arriving(tester);
    expect(before, greaterThan(0.3), reason: 'the first roll is under way');
    expect(before, lessThan(1));

    await tester.pumpWidget(count('5 agents'));
    final after = _arriving(tester);
    expect(after, greaterThanOrEqualTo(before), reason: 'the new digits do not restart from invisible');

    await tester.pump(Motion.settle * 2);
    expect(find.text('5 agents'), findsOneWidget, reason: 'it ends as one plain text');
    expect(tester.hasRunningAnimations, isFalse, reason: 'no ticker left running');
  });
}
