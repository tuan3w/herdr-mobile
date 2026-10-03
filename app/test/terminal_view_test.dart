import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/ansi.dart';
import 'package:herdr_mobile/ui/core/terminal_cells.dart';
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
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
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

  group('unchanged lines are not rebuilt into another item', () {
    // The widget and render object showing [line], and what they show.
    ({Element element, RenderParagraph paragraph, String shown, InlineSpan span})
        probe(WidgetTester tester, String line) {
      final finder = find.text(line);
      final element = finder.evaluate().single;
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: finder, matching: find.byType(RichText)),
      );
      return (
        element: element,
        paragraph: paragraph,
        shown: paragraph.text.toPlainText(),
        span: (element.widget as Text).textSpan!,
      );
    }

    const watched = ['line 99', 'line 98', 'line 90', 'line 85'];

    testWidgets('when lines are appended', (tester) async {
      await _pump(tester, _lines(0, 100));
      final before = {for (final l in watched) l: probe(tester, l)};
      // Appending moves every line up by five items; these stay on screen.
      await _pump(tester, _lines(0, 105));

      for (final line in watched) {
        final after = probe(tester, line);
        expect(after.element, same(before[line]!.element), reason: line);
        expect(after.paragraph, same(before[line]!.paragraph), reason: line);
        expect(after.shown, line);
      }
      // Only lines that did not change reuse their span.
      expect(probe(tester, 'line 98').span, same(before['line 98']!.span));
      expect(probe(tester, 'line 90').span, same(before['line 90']!.span));
    });

    testWidgets('when the read window slides', (tester) async {
      await _pump(tester, _lines(0, 100));
      final before = {for (final l in watched) l: probe(tester, l)};
      // Ten lines left the top, ten arrived at the bottom.
      await _pump(tester, _lines(10, 110));

      for (final line in watched) {
        final after = probe(tester, line);
        expect(after.element, same(before[line]!.element), reason: line);
        expect(after.paragraph, same(before[line]!.paragraph), reason: line);
        expect(after.shown, line);
      }
    });

    testWidgets('while scrolled up, and across repeated updates', (tester) async {
      await _pump(tester, _lines(0, 200));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
      await tester.pumpAndSettle();
      final before = probe(tester, 'line 150');

      for (var step = 1; step <= 6; step++) {
        await _pump(tester, _lines(step * 3, 200 + step * 4));
        final after = probe(tester, 'line 150');
        expect(after.element, same(before.element), reason: 'step $step');
        expect(after.paragraph, same(before.paragraph), reason: 'step $step');
        expect(after.shown, 'line 150');
      }
    });

    testWidgets('a changed line is shown with its new text', (tester) async {
      await _pump(tester, '${_lines(0, 50)}\r\nbuilding 10%');
      await _pump(tester, '${_lines(0, 50)}\r\nbuilding 20%');

      expect(find.text('building 10%'), findsNothing);
      expect(find.text('building 20%'), findsOneWidget);
      expect(find.text('line 49'), findsOneWidget);
    });

    testWidgets('text sharing nothing with the old is a fresh document',
        (tester) async {
      await _pump(tester, _lines(0, 100));
      await _pump(tester, _lines(500, 600));

      expect(tester.takeException(), isNull);
      expect(find.text('line 599'), findsOneWidget);
      expect(find.text('line 99'), findsNothing);
      expect(probe(tester, 'line 599').shown, 'line 599');
    });

    testWidgets('repeated identical lines do not collide', (tester) async {
      await _pump(tester, List.filled(40, 'same').join('\r\n'));
      await _pump(tester, List.filled(45, 'same').join('\r\n'));

      expect(tester.takeException(), isNull);
      expect(find.text('same'), findsWidgets);
    });
  });

  testWidgets('the jump button shows only when scrolled up', (tester) async {
    await _pump(tester, _lines(0, 200));
    expect(_jumpButtonFade(tester).opacity, 0);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(_jumpButtonFade(tester).opacity, 1);
    expect(find.text('line 199'), findsNothing);

    await tester.tap(find.byTooltip('Jump to latest'));
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

  testWidgets('the line height follows the text scale, within limits, in whole '
      'device pixels', (tester) async {
    Future<double> pitch(double scale) async {
      await _pump(tester, 'line 0\r\nline 1', textScale: scale);
      return tester.getTopLeft(find.text('line 1')).dy -
          tester.getTopLeft(find.text('line 0')).dy;
    }

    // The row height is the font size times 1.3, rounded to device pixels.
    final dpr = tester.view.devicePixelRatio;
    double snapped(double fontSize) =>
        (fontSize * 1.3 * dpr).roundToDouble() / dpr;

    expect(await pitch(1), closeTo(snapped(11.5), 0.001));
    expect(await pitch(1.5), closeTo(snapped(11.5 * 1.5), 0.001));
    expect(await pitch(3), closeTo(snapped(11.5 * 1.6), 0.001),
        reason: 'capped so a terminal stays usable');
  });

  group('cell grid', () {
    // The painter of the row showing [line].
    TerminalLinePainter painterOf(WidgetTester tester, String line) =>
        tester
            .widget<CustomPaint>(find.descendant(
              of: find.ancestor(
                  of: find.text(line), matching: find.byType(TerminalLineView)),
              matching: find.byType(CustomPaint),
            ))
            .painter! as TerminalLinePainter;

    testWidgets('box drawing is painted, and shows as spaces in the text layer',
        (tester) async {
      await _pump(tester, '┌──┐ ok\r\n│  │');

      expect(find.text('     ok'), findsOneWidget);
      expect(find.textContaining('┌'), findsNothing);
      expect(find.textContaining('─'), findsNothing);
      expect(blankSprites('a│b▀c'), 'a b c');
      expect(blankSprites('plain'), 'plain');
    });

    testWidgets('backgrounds are not part of the text style', (tester) async {
      await _pump(tester, '\x1b[44mblue\x1b[0m');

      final text = tester.widget<Text>(find.text('blue'));
      final run = (text.textSpan! as TextSpan).children!.single as TextSpan;
      expect(run.style, isNull);
    });

    testWidgets('prepared rows are reused for unchanged lines', (tester) async {
      await _pump(tester, '${_lines(0, 50)}\r\n\x1b[44m┌─┐\x1b[0m\r\ntail');
      final before = painterOf(tester, 'line 45').line;
      final picture = painterOf(tester, '   ').line;
      expect(picture.picture, isNotNull);
      final recorded = picture.picture;

      await _pump(tester, '${_lines(0, 50)}\r\n\x1b[44m┌─┐\x1b[0m\r\ntail\r\nnew');

      expect(painterOf(tester, 'line 45').line, same(before));
      expect(painterOf(tester, '   ').line, same(picture));
      expect(painterOf(tester, '   ').line.picture, same(recorded),
          reason: 'not recorded again');
    });

    test('the cache keeps the rows used most recently and disposes the rest', () {
      final metrics = CellMetrics.measure(11.5, 3);
      final cache = TerminalLineCache(metrics);
      final runs = [
        for (var i = 0; i < 700; i++) parseAnsi('\x1b[44m$i\x1b[0m').lines.single,
      ];
      final first = cache.lineFor(runs[0]);
      expect(first.picture, isNotNull);
      expect(cache.lineFor(runs[0]), same(first));

      for (var i = 1; i < 600; i++) {
        cache.lineFor(runs[i]);
        if (i % 100 == 0) cache.lineFor(runs[0]); // still on screen
      }

      expect(cache.length, lessThanOrEqualTo(600));
      expect(cache.length, greaterThan(100), reason: 'a good way around the screen');
      expect(cache.lineFor(runs[0]), same(first), reason: 'used lately, so kept');
      expect(first.hasPicture, isTrue);

      final evicted = cache.lineFor(runs[1]);
      expect(evicted.hasPicture, isFalse, reason: 'a fresh row, not recorded yet');
      cache.dispose();
      expect(cache.length, 0);
      expect(first.hasPicture, isFalse);
    });

    testWidgets('lines are repainted only when their prepared row changes',
        (tester) async {
      final metrics = CellMetrics.measure(11.5, 3);
      final runs = parseAnsi('┌').lines.single;
      final a = TerminalLine(runs, metrics);
      final b = TerminalLine(runs, metrics);
      expect(TerminalLinePainter(a).shouldRepaint(TerminalLinePainter(a)),
          isFalse);
      expect(TerminalLinePainter(a).shouldRepaint(TerminalLinePainter(b)),
          isTrue);
    });

    testWidgets('rows are as tall as the snapped line height, at any density',
        (tester) async {
      for (final dpr in [1.0, 2.625, 3.0]) {
        tester.view
          ..devicePixelRatio = dpr
          ..physicalSize = Size(360, 400) * dpr;
        await _pump(tester, 'a\r\nb');
        final row = tester.getSize(find.byType(TerminalLineView).first);
        final device = row.height * dpr;
        expect(device, closeTo(device.roundToDouble(), 1e-9), reason: 'dpr $dpr');
      }
      addTearDown(tester.view.reset);
    });
  });
}
