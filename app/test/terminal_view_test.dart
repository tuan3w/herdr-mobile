import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/terminal_view.dart';
import 'package:herdr_mobile/ui/core/theme.dart';

String _lines(int from, int to) =>
    [for (var i = from; i < to; i++) 'line $i'].join('\r\n');

Future<void> _pump(
  WidgetTester tester,
  String text, {
  bool reduceMotion = false,
  double textScale = 1,
}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: reduceMotion,
              textScaler: TextScaler.linear(textScale),
            ),
            child: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 360,
                  height: 400,
                  child: TerminalView(text: text),
                ),
              ),
            ),
          ),
        ),
      ),
    );

AnimatedOpacity _jumpButtonFade(WidgetTester tester) => tester.widget(
      find.descendant(
        of: find.byType(TerminalView),
        matching: find.byType(AnimatedOpacity),
      ),
    );

double _contrast(Color a, Color b) {
  final hi = a.computeLuminance() > b.computeLuminance() ? a : b;
  final lo = identical(hi, a) ? b : a;
  return (hi.computeLuminance() + 0.05) / (lo.computeLuminance() + 0.05);
}

void main() {
  testWidgets('builds only the visible lines of a long pane', (tester) async {
    await _pump(tester, _lines(0, 300));

    expect(find.byType(Text).evaluate().length, inInclusiveRange(15, 70));
    expect(find.text('line 299'), findsOneWidget);
    expect(find.text('line 0'), findsNothing);
  });

  testWidgets('short output hugs the top', (tester) async {
    await _pump(tester, 'hi');

    expect(tester.getTopLeft(find.text('hi')).dy, lessThan(20));
  });

  testWidgets('follows the newest line while at the bottom', (tester) async {
    await _pump(tester, _lines(0, 100));
    final bottom = tester.getBottomLeft(find.text('line 99')).dy;

    await _pump(tester, _lines(0, 110));

    expect(find.text('line 109'), findsOneWidget);
    expect(tester.getBottomLeft(find.text('line 109')).dy, closeTo(bottom, 0.01));
  });

  testWidgets('does not move what you are reading when output arrives',
      (tester) async {
    await _pump(tester, _lines(0, 200));
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(find.text('line 150'), findsOneWidget);
    final reading = tester.getTopLeft(find.text('line 150')).dy;

    // Lines appended.
    await _pump(tester, _lines(0, 215));
    expect(tester.getTopLeft(find.text('line 150')).dy, closeTo(reading, 0.01));

    // The read window slid: ten lines left the top, ten arrived at the bottom.
    await _pump(tester, _lines(10, 225));
    expect(tester.getTopLeft(find.text('line 150')).dy, closeTo(reading, 0.01));

    // Text that shares nothing with the old window cannot be anchored, but
    // must not throw.
    await _pump(tester, _lines(1000, 1010));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the jump button shows only when scrolled up', (tester) async {
    await _pump(tester, _lines(0, 200));
    expect(_jumpButtonFade(tester).opacity, 0);

    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(_jumpButtonFade(tester).opacity, 1);
    expect(find.text('line 199'), findsNothing);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('line 199'), findsOneWidget);
    expect(_jumpButtonFade(tester).opacity, 0);
  });

  testWidgets('the jump button animates in 160 ms, or not at all', (tester) async {
    await _pump(tester, _lines(0, 20));
    expect(_jumpButtonFade(tester).duration, const Duration(milliseconds: 160));
    expect(_jumpButtonFade(tester).curve, const Cubic(0.23, 1, 0.32, 1));

    await _pump(tester, _lines(0, 20), reduceMotion: true);
    expect(_jumpButtonFade(tester).duration, Duration.zero);
  });

  testWidgets('renders SGR colours and attributes', (tester) async {
    await _pump(
      tester,
      '\x1b[31mred\x1b[0m plain \x1b[1;4mbold\x1b[0m\r\n',
    );

    final text = tester.widget<Text>(find.textContaining('red'));
    final runs = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(runs.map((r) => r.text), ['red', ' plain ', 'bold']);
    expect(runs[0].style!.color, TerminalColors.ansi[1]);
    expect(runs[1].style, isNull);
    expect(runs[2].style!.fontWeight, FontWeight.w700);
    expect(runs[2].style!.decoration, TextDecoration.underline);
  });

  testWidgets('dim text stays readable', (tester) async {
    await _pump(tester, '\x1b[2mdim\x1b[0m');

    final text = tester.widget<Text>(find.text('dim'));
    final color = (text.textSpan! as TextSpan).children!.single.style!.color!;
    expect(color, isNot(TerminalColors.foreground));
    expect(_contrast(color, TerminalColors.background), greaterThanOrEqualTo(4.5));
  });

  testWidgets('long lines scroll horizontally instead of wrapping', (tester) async {
    Finder scrollables() => find.descendant(
          of: find.byType(TerminalView),
          matching: find.byType(Scrollable),
        );

    await _pump(tester, 'x' * 200);
    final wide = tester.state<ScrollableState>(scrollables().first);
    expect(wide.position.axis, Axis.horizontal);
    expect(wide.position.maxScrollExtent, greaterThan(1000));

    await _pump(tester, 'short');
    final narrow = tester.state<ScrollableState>(scrollables().first);
    expect(narrow.position.maxScrollExtent, 0);
  });

  testWidgets('the line height follows the text scale, within limits',
      (tester) async {
    Future<double> pitch(double scale) async {
      await _pump(tester, 'line 0\r\nline 1', textScale: scale);
      return tester.getTopLeft(find.text('line 1')).dy -
          tester.getTopLeft(find.text('line 0')).dy;
    }

    expect(await pitch(1), closeTo(11.5 * 1.3, 0.01));
    expect(await pitch(1.5), closeTo(11.5 * 1.5 * 1.3, 0.01));
    expect(await pitch(3), closeTo(11.5 * 1.6 * 1.3, 0.01),
        reason: 'capped so a terminal stays usable');
  });
}
