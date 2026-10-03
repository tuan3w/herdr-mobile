import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/ui/core/terminal_cells.dart';
import 'package:herdr_mobile/ui/core/terminal_view.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'support/terminal_rows.dart';

/// The view is 360 wide with 12 px of padding on each side. How many cells fit
/// depends on the advance of whatever font `monoFamily` resolves to (Ahem, as
/// wide as it is high, unless the test loads the bundled fonts), so measure it.
double _advance(double fontSize) =>
    CellMetrics.measure(fontSize, 1).advance;

int _columns(double fontSize) => ((360 - 24) / _advance(fontSize)).floor();

String _lines(int from, int to, {String pad = ''}) =>
    [for (var i = from; i < to; i++) 'line $i$pad'].join('\r\n');

Widget _app(Widget Function() view) => MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 360, height: 400, child: view()),
        ),
      ),
    );

Future<void> _pump(
  WidgetTester tester,
  String text, {
  bool wrap = false,
  double fontSize = defaultTerminalFontSize,
}) =>
    tester.pumpWidget(_app(
      () => TerminalView(text: text, wrap: wrap, fontSize: fontSize),
    ));

/// Texts of the rows on screen, top to bottom.
List<String> _rowTexts(WidgetTester tester) {
  final rows = find.byType(TerminalLineView).evaluate().toList()
    ..sort((a, b) => (a.renderObject! as RenderBox)
        .localToGlobal(Offset.zero)
        .dy
        .compareTo((b.renderObject! as RenderBox).localToGlobal(Offset.zero).dy));
  return [
    for (final e in rows)
      (e.widget as TerminalLineView).line.span.toPlainText(),
  ];
}

/// Prepared line and element of every visible row.
Map<TerminalLine, Element> _visible(WidgetTester tester) => {
      for (final e in find.byType(TerminalLineView).evaluate())
        (e.widget as TerminalLineView).line: e,
    };

ScrollableState _horizontal(WidgetTester tester) => tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(TerminalView),
            matching: find.byType(Scrollable),
          )
          .first,
    );

ScrollableState _vertical(WidgetTester tester) => tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(TerminalView),
            matching: find.byType(Scrollable),
          )
          .last,
    );

void main() {
  group('wrap to screen', () {
    testWidgets('cuts long lines into rows of the viewport width',
        (tester) async {
      final columns = _columns(defaultTerminalFontSize);
      await _pump(tester, 'x' * (2 * columns + 5), wrap: true);

      expect(_rowTexts(tester), ['x' * columns, 'x' * columns, 'x' * 5]);
    });

    testWidgets('short lines stay one row, empty lines keep their row',
        (tester) async {
      await _pump(tester, 'one\r\n\r\ntwo', wrap: true);

      expect(_rowTexts(tester), ['one', '', 'two']);
    });

    testWidgets('without wrap the same text is one row', (tester) async {
      await _pump(tester, 'x' * 70);

      expect(_rowTexts(tester), ['x' * 70]);
    });

    testWidgets('does not scroll sideways, and fits the viewport', (tester) async {
      await _pump(tester, '${'x' * 400}\r\nshort', wrap: true);
      final horizontal = _horizontal(tester);
      expect(horizontal.position.maxScrollExtent, 0);

      await tester.drag(find.byType(TerminalView), const Offset(-200, 0));
      await tester.pump();
      expect(horizontal.position.pixels, 0);

      // The control: the exact layout does scroll.
      await _pump(tester, '${'x' * 400}\r\nshort');
      expect(_horizontal(tester).position.maxScrollExtent, greaterThan(1000));
    });

    testWidgets('a coloured run keeps its colour on every row it spans',
        (tester) async {
      final columns = _columns(defaultTerminalFontSize);
      final length = columns + 11;
      await _pump(tester, '\x1b[31m${'r' * length}\x1b[0m tail', wrap: true);

      final rows = find.byType(TerminalLineView).evaluate().toList();
      expect(rows, hasLength(2));
      final lines = [
        for (final e in rows) (e.widget as TerminalLineView).line,
      ]..sort((a, b) => b.runs.first.text.length.compareTo(a.runs.first.text.length));
      expect(lines[0].runs.first.fg, TerminalColors.ansi[1]);
      expect(lines[1].runs.first.fg, TerminalColors.ansi[1]);
      expect(lines[0].runs.first.text.length, columns);
      expect(lines[1].runs.first.text.length, length - columns);
    });

    testWidgets('rows keep the fixed height, and a long pane still virtualizes',
        (tester) async {
      await _pump(tester, _lines(0, 300, pad: ' ${'y' * 100}'), wrap: true);

      final rows = find.byType(TerminalLineView);
      expect(rows.evaluate().length, inInclusiveRange(15, 80));
      final heights = {
        for (final e in rows.evaluate()) tester.getSize(find.byWidget(e.widget)).height,
      };
      expect(heights, hasLength(1));
    });

    testWidgets('the window of rows adapts to the width of the viewport',
        (tester) async {
      await tester.pumpWidget(_app(
        () => const TerminalView(text: 'abcdefghij', wrap: true),
      ));
      expect(_rowTexts(tester), ['abcdefghij']);

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 24 + 4 * _advance(defaultTerminalFontSize) + 0.5,
              height: 400,
              child: const TerminalView(text: 'abcdefghij', wrap: true),
            ),
          ),
        ),
      ));
      expect(_rowTexts(tester), ['abcd', 'efgh', 'ij']);
    });

    testWidgets('unchanged lines keep their prepared rows when one line changes '
        '(so only that line is wrapped again)', (tester) async {
      // Twelve lines of three rows each; the change is among the visible ones
      // and past the first lines the anchoring compares.
      final long = 2 * _columns(defaultTerminalFontSize) + 10; // three rows
      String doc(String changed) => [
            for (var i = 0; i < 12; i++)
              i == 9 ? changed * long : String.fromCharCode(97 + i) * long,
          ].join('\r\n');
      await _pump(tester, doc('x'), wrap: true);
      final before = _visible(tester);

      await _pump(tester, doc('X'), wrap: true);
      final after = _visible(tester);

      final shared = before.keys.where(after.containsKey).toList();
      expect(after.length, before.length);
      expect(shared, hasLength(before.length - 3),
          reason: 'only the three rows of the changed line are new');
      for (final line in shared) {
        expect(after[line], same(before[line]), reason: 'same list item');
      }
    });

    testWidgets('continuation rows keep their list items as lines are appended '
        'and the window slides', (tester) async {
      String doc(int from, int to) => [
            for (var i = from; i < to; i++) '${'$i'.padLeft(3, '0')}${'x' * 60}',
          ].join('\r\n');
      await _pump(tester, doc(0, 60), wrap: true);
      final before = _visible(tester);

      await _pump(tester, doc(0, 62), wrap: true);
      final appended = _visible(tester);
      await _pump(tester, doc(2, 64), wrap: true);
      final slid = _visible(tester);

      for (final later in [appended, slid]) {
        final shared = before.keys.where(later.containsKey).toList();
        expect(shared.length, greaterThan(8));
        for (final line in shared) {
          expect(later[line], same(before[line]));
        }
      }
    });

    testWidgets('keeps what you are reading when the layout changes',
        (tester) async {
      final text = _lines(0, 200, pad: ' ${'y' * 60}');
      await _pump(tester, text);
      await tester.drag(find.byType(TerminalView), const Offset(0, 600));
      await tester.pumpAndSettle();
      // The line at the bottom edge of the view.
      String lowest() {
        final shown = terminalRowContaining('line ').evaluate().toList()
          ..sort((a, b) => (b.renderObject! as RenderBox)
              .localToGlobal(Offset.zero)
              .dy
              .compareTo((a.renderObject! as RenderBox).localToGlobal(Offset.zero).dy));
        final span = (shown.first.widget as TerminalLineView).text.toPlainText();
        return span.substring(0, span.indexOf(' y'));
      }

      final reading = lowest();
      final bottom = tester.getBottomLeft(terminalRowContaining('$reading ')).dy;

      await _pump(tester, text, wrap: true);
      expect(terminalRowContaining('$reading '), findsWidgets);
      expect(tester.getBottomLeft(terminalRowContaining('$reading ').first).dy,
          closeTo(bottom, 20));
    });
  });

  group('pinch to zoom', () {
    // Pumps a view whose font size follows the pinch, like the pane screen.
    Future<({ValueNotifier<double> size, List<double> changes, List<double> ends})>
        pumpZoom(WidgetTester tester, String text, {bool wrap = false}) async {
      final size = ValueNotifier(defaultTerminalFontSize);
      final changes = <double>[];
      final ends = <double>[];
      await tester.pumpWidget(_app(
        () => ValueListenableBuilder<double>(
          valueListenable: size,
          builder: (_, value, _) => TerminalView(
            text: text,
            wrap: wrap,
            fontSize: value,
            onFontSizeChanged: (v) {
              changes.add(v);
              size.value = v;
            },
            onFontSizeEnd: ends.add,
          ),
        ),
      ));
      return (size: size, changes: changes, ends: ends);
    }

    /// Two fingers down 100 px apart, centred on the view.
    Future<(TestGesture, TestGesture)> pinchStart(WidgetTester tester) async {
      final a = await tester.startGesture(const Offset(130, 200), pointer: 1);
      final b = await tester.startGesture(const Offset(230, 200), pointer: 2);
      await tester.pump();
      return (a, b);
    }

    testWidgets('the font size follows the distance between the fingers',
        (tester) async {
      final zoom = await pumpZoom(tester, _lines(0, 50));
      final (a, b) = await pinchStart(tester);

      await a.moveTo(const Offset(105, 200));
      await b.moveTo(const Offset(255, 200)); // 100 -> 150 px apart
      await tester.pump();
      expect(zoom.size.value, closeTo(defaultTerminalFontSize * 1.5, 0.25));

      await a.moveTo(const Offset(155, 200));
      await b.moveTo(const Offset(205, 200)); // back down to 50 px apart
      await tester.pump();
      expect(zoom.size.value, closeTo(defaultTerminalFontSize * 0.5, 4)); // clamped
      expect(zoom.size.value, minTerminalFontSize);

      await a.up();
      expect(zoom.ends, [minTerminalFontSize]);
      await b.up();
      expect(zoom.ends, hasLength(1), reason: 'one end per pinch');
    });

    testWidgets('is clamped to 8..22', (tester) async {
      final zoom = await pumpZoom(tester, _lines(0, 50));
      final (a, b) = await pinchStart(tester);

      await a.moveTo(const Offset(30, 200));
      await b.moveTo(const Offset(330, 200)); // 3x
      await tester.pump();
      expect(zoom.size.value, maxTerminalFontSize);
      expect(zoom.changes.every((v) => v >= minTerminalFontSize && v <= maxTerminalFontSize),
          isTrue);

      await a.up();
      await b.up();
      expect(zoom.ends.single, maxTerminalFontSize);
    });

    testWidgets('changes the cell size and the row height', (tester) async {
      final zoom = await pumpZoom(tester, 'a\r\nb');
      final before = tester.getSize(find.byType(TerminalLineView).first);

      final (a, b) = await pinchStart(tester);
      await a.moveTo(const Offset(105, 200));
      await b.moveTo(const Offset(255, 200));
      await tester.pump();

      expect(zoom.size.value, greaterThan(defaultTerminalFontSize));
      final after = tester.getSize(find.byType(TerminalLineView).first);
      expect(after.height, greaterThan(before.height));
      final dpr = tester.view.devicePixelRatio;
      expect(after.height * dpr, closeTo((after.height * dpr).roundToDouble(), 1e-9));
      await a.up();
      await b.up();
    });

    testWidgets('re-flows wrapped lines to the new cell size', (tester) async {
      final zoom = await pumpZoom(tester, 'x' * 70, wrap: true);
      expect(_rowTexts(tester), hasLength((70 / _columns(defaultTerminalFontSize)).ceil()));

      final (a, b) = await pinchStart(tester);
      await a.moveTo(const Offset(80, 200));
      await b.moveTo(const Offset(280, 200)); // 2x: clamped to 22
      await tester.pump();

      expect(zoom.size.value, 22);
      final columns = _columns(22);
      expect(columns, lessThan(_columns(defaultTerminalFontSize)));
      expect(_rowTexts(tester).first, 'x' * columns);
      expect(_rowTexts(tester), hasLength((70 / columns).ceil()));
      await a.up();
      await b.up();
    });

    testWidgets('keeps the line you are reading in place', (tester) async {
      final zoom = await pumpZoom(tester, _lines(0, 200));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
      await tester.pumpAndSettle();
      // The line at the bottom edge of the view, and where it is.
      Element lowest() => (terminalRowContaining('line ').evaluate().toList()
            ..sort((a, b) => (b.renderObject! as RenderBox)
                .localToGlobal(Offset.zero)
                .dy
                .compareTo((a.renderObject! as RenderBox).localToGlobal(Offset.zero).dy)))
          .first;
      String textOf(Element e) =>
          (e.widget as TerminalLineView).text.toPlainText();
      final reading = textOf(lowest());
      final bottom = tester.getBottomLeft(terminalRow(reading)).dy;
      final position = _vertical(tester).position.pixels;

      final (a, b) = await pinchStart(tester);
      await a.moveTo(const Offset(105, 200));
      await b.moveTo(const Offset(255, 200));
      await tester.pump();
      await tester.pump();

      expect(zoom.size.value, greaterThan(defaultTerminalFontSize));
      expect(_vertical(tester).position.pixels, greaterThan(position),
          reason: 'taller rows: the same lines sit further from the bottom');
      expect(terminalRow(reading), findsOneWidget);
      // Within a row of where it was (the new rows are taller).
      expect(tester.getBottomLeft(terminalRow(reading)).dy,
          closeTo(bottom, 15 * 2));
      await a.up();
      await b.up();
    });

    testWidgets('one finger scrolls, and does not zoom', (tester) async {
      final zoom = await pumpZoom(tester, _lines(0, 200));

      await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
      await tester.pumpAndSettle();

      expect(_vertical(tester).position.pixels, greaterThan(100));
      expect(zoom.changes, isEmpty);
      expect(zoom.ends, isEmpty);
      expect(zoom.size.value, defaultTerminalFontSize);
    });

    testWidgets('scrolling pauses during a pinch and works again after',
        (tester) async {
      final zoom = await pumpZoom(tester, _lines(0, 200));
      final (a, b) = await pinchStart(tester);

      // The fingers drift down together (one after the other, so the size
      // wobbles on the way): the list must not follow them.
      await a.moveBy(const Offset(0, 120));
      await b.moveBy(const Offset(0, 120));
      await tester.pump();
      expect(zoom.size.value, defaultTerminalFontSize,
          reason: 'same distance again');
      expect(_vertical(tester).position.pixels, 0);

      await a.up();
      await b.up();
      await tester.pump();
      expect(zoom.ends, [defaultTerminalFontSize]);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(_vertical(tester).position.pixels, greaterThan(100));
    });

    testWidgets('pinching over empty space below short output works',
        (tester) async {
      final zoom = await pumpZoom(tester, 'a\r\nb');
      final (a, b) = await pinchStart(tester);
      await a.moveTo(const Offset(105, 200));
      await b.moveTo(const Offset(255, 200));
      await tester.pump();
      expect(zoom.size.value, greaterThan(defaultTerminalFontSize));
      await a.up();
      await b.up();
    });

    testWidgets('a pinch started with no callbacks is harmless', (tester) async {
      await _pump(tester, _lines(0, 50));
      final (a, b) = await pinchStart(tester);
      await a.moveTo(const Offset(80, 200));
      await tester.pump();
      await a.up();
      await b.up();
      expect(tester.takeException(), isNull);
    });
  });
}
