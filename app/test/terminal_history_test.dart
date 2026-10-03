import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/terminal_view.dart';
import 'package:herdr_mobile/ui/core/theme.dart';

String _lines(int from, int to) =>
    [for (var i = from; i < to; i++) 'line $i'].join('\r\n');

/// Rows as a pane read gives them: each ends with a carriage return.
List<String> _rows(int from, int to) => [for (var i = from; i < to; i++) 'line $i\r'];

Future<void> _pump(
  WidgetTester tester, {
  required String text,
  List<String> history = const [],
  TerminalTop top = TerminalTop.none,
  bool wrap = false,
  double width = 360,
  ValueChanged<TerminalScroll>? onScrollChanged,
}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: 400,
              child: TerminalView(
                text: text,
                history: history,
                top: top,
                wrap: wrap,
                onScrollChanged: onScrollChanged,
              ),
            ),
          ),
        ),
      ),
    );

/// The widget and render object showing [line].
({Element element, RenderObject paragraph, double top}) _probe(
  WidgetTester tester,
  String line,
) {
  final finder = find.text(line);
  return (
    element: finder.evaluate().single,
    paragraph: tester.renderObject(
      find.descendant(of: finder, matching: find.byType(RichText)),
    ),
    top: tester.getTopLeft(finder).dy,
  );
}

Future<void> _scrollUp(WidgetTester tester, double pixels) async {
  await tester.drag(find.byType(TerminalView), Offset(0, pixels));
  await tester.pumpAndSettle();
}

/// Scrolls to the oldest row.
Future<void> _toTop(WidgetTester tester) async {
  final position = tester
      .state<ScrollableState>(find
          .descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable))
          .first)
      .position;
  position.jumpTo(position.maxScrollExtent);
  await tester.pumpAndSettle();
}

void main() {
  group('rows arriving above', () {
    testWidgets('older rows in the text do not move what is on screen', (tester) async {
      await _pump(tester, text: _lines(100, 300));
      await _scrollUp(tester, 600);
      final before = _probe(tester, 'line 250');

      await _pump(tester, text: _lines(0, 300));

      final after = _probe(tester, 'line 250');
      expect(after.top, closeTo(before.top, 0.01));
      expect(after.element, same(before.element), reason: 'the row kept its item');
      expect(after.paragraph, same(before.paragraph));
      expect(tester.takeException(), isNull);
    });

    testWidgets('rows handed over as history do not move what is on screen',
        (tester) async {
      await _pump(tester, text: _lines(100, 300));
      await _scrollUp(tester, 600);
      final before = _probe(tester, 'line 250');

      await _pump(tester, history: _rows(0, 100), text: _lines(100, 300));

      final after = _probe(tester, 'line 250');
      expect(after.top, closeTo(before.top, 0.01));
      expect(after.element, same(before.element));
      expect(tester.takeException(), isNull);
    });

    testWidgets('and the older rows are there to scroll to', (tester) async {
      await _pump(tester, text: _lines(100, 300));
      await _pump(tester, history: _rows(0, 100), text: _lines(100, 300));
      expect(find.text('line 0'), findsNothing);

      await _toTop(tester);

      expect(find.text('line 0'), findsOneWidget);
      expect(find.text('line 299'), findsNothing);
    });

    testWidgets('wrapped rows too: a wrapped line above shifts nothing', (tester) async {
      final long = 'long ${'word ' * 40}end';
      await _pump(tester, text: _lines(100, 300), wrap: true);
      await _scrollUp(tester, 600);
      final before = _probe(tester, 'line 250');

      await _pump(
        tester,
        history: [long, ..._rows(0, 50)],
        text: _lines(100, 300),
        wrap: true,
      );

      expect(_probe(tester, 'line 250').top, closeTo(before.top, 0.01));
    });

    testWidgets('while following, new history does not detach the view from the bottom',
        (tester) async {
      await _pump(tester, text: _lines(100, 300));
      final bottom = tester.getBottomLeft(find.text('line 299')).dy;

      await _pump(tester, history: _rows(0, 100), text: _lines(100, 300));

      expect(tester.getBottomLeft(find.text('line 299')).dy, closeTo(bottom, 0.01));
    });

    testWidgets('a slide that moves rows into the history changes nothing on screen',
        (tester) async {
      await _pump(tester, text: _lines(0, 300));
      await _scrollUp(tester, 600);
      final before = _probe(tester, 'line 250');

      // Ten rows left the window for the history, ten arrived at the bottom.
      await _pump(tester, history: _rows(0, 10), text: _lines(10, 310));

      final after = _probe(tester, 'line 250');
      expect(after.top, closeTo(before.top, 0.01));
      expect(after.element, same(before.element));
    });

    testWidgets('the oldest rows being let go does not move what is on screen',
        (tester) async {
      await _pump(tester, history: _rows(0, 100), text: _lines(100, 300));
      await _scrollUp(tester, 600);
      final before = _probe(tester, 'line 250');

      await _pump(tester, history: _rows(40, 100), text: _lines(100, 320));

      expect(_probe(tester, 'line 250').top, closeTo(before.top, 0.01));
    });

    testWidgets('a gap row in the history is an ordinary dim row', (tester) async {
      await _pump(
        tester,
        history: [..._rows(0, 3), '\x1b[0m\x1b[2m··· output not captured ···\x1b[0m'],
        text: _lines(1000, 1003),
      );

      expect(find.text('··· output not captured ···'), findsOneWidget);
    });
  });

  group('the note above the oldest row', () {
    testWidgets('says more is coming while it can be loaded', (tester) async {
      await _pump(tester, text: _lines(0, 300), top: TerminalTop.loading);
      expect(find.textContaining('Loading earlier output'), findsNothing,
          reason: 'only at the very top');

      await _toTop(tester);

      expect(find.textContaining('Loading earlier output'), findsOneWidget);
      expect(find.text('line 0'), findsOneWidget);
    });

    testWidgets('says why there is no more at herdr\'s limit', (tester) async {
      await _pump(tester, text: _lines(0, 300), top: TerminalTop.serverLimit);
      await _toTop(tester);

      expect(find.textContaining('Earlier output is not available'), findsOneWidget);
      expect(find.textContaining('1000 rows'), findsOneWidget);
    });

    testWidgets('says so when the phone let the oldest rows go', (tester) async {
      await _pump(tester, text: _lines(0, 300), top: TerminalTop.localLimit);
      await _toTop(tester);

      expect(find.textContaining('Earlier output is not kept'), findsOneWidget);
    });

    testWidgets('is absent when the first row is the pane\'s first', (tester) async {
      await _pump(tester, text: _lines(0, 300));
      await _toTop(tester);

      expect(find.textContaining('Earlier output'), findsNothing);
      expect(find.textContaining('Loading'), findsNothing);
    });

    testWidgets('is centred in the view, not in the width of wide output',
        (tester) async {
      await _pump(
        tester,
        text: '${_lines(0, 300)}\r\n${'x' * 300}',
        top: TerminalTop.serverLimit,
      );
      await _toTop(tester);

      final box = tester.getRect(find.textContaining('Earlier output is not available'));
      expect(box.center.dx, closeTo(180, 12));
    });

    testWidgets('cannot be selected along with the output', (tester) async {
      await _pump(tester, text: _lines(0, 300), top: TerminalTop.loading);
      await _toTop(tester);

      expect(
        find.ancestor(
          of: find.textContaining('Loading earlier output'),
          matching: find.byType(SelectionContainer),
        ),
        findsWidgets,
      );
      final text = tester.widget<Text>(find.textContaining('Loading earlier output'));
      expect(text.style?.color, TerminalColors.dim);
    });

    testWidgets('changing state while scrolled keeps what is on screen', (tester) async {
      await _pump(tester, text: _lines(0, 300), top: TerminalTop.loading);
      await _scrollUp(tester, 600);
      final before = _probe(tester, 'line 250');

      await _pump(tester, text: _lines(0, 300), top: TerminalTop.serverLimit);

      expect(_probe(tester, 'line 250').top, closeTo(before.top, 0.01));
    });
  });

  group('reporting where the user is', () {
    testWidgets('tells once, when the view lays out, and again only on a change',
        (tester) async {
      final reports = <TerminalScroll>[];
      await _pump(tester, text: _lines(0, 600), onScrollChanged: reports.add);
      await tester.pump();

      expect(reports, [(nearTop: false, following: true)]);

      await _scrollUp(tester, 200);
      expect(reports.last, (nearTop: false, following: false));
      final count = reports.length;

      await _scrollUp(tester, 30);
      expect(reports, hasLength(count), reason: 'nothing changed');
    });

    testWidgets('near the top means within about a viewport and a half', (tester) async {
      final reports = <TerminalScroll>[];
      await _pump(tester, text: _lines(0, 600), onScrollChanged: reports.add);
      await tester.pump();

      await _toTop(tester);

      expect(reports.last, (nearTop: true, following: false));
      final position = tester
          .state<ScrollableState>(find
              .descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable))
              .first)
          .position;
      expect(position.maxScrollExtent - position.pixels, lessThan(1.5 * 400));

      await tester.drag(find.byType(TerminalView), const Offset(0, -800));
      await tester.pumpAndSettle();
      expect(reports.last.nearTop, isFalse);
    });

    testWidgets('output that arrives above changes the answer', (tester) async {
      final reports = <TerminalScroll>[];
      await _pump(
        tester,
        text: _lines(0, 100),
        top: TerminalTop.loading,
        onScrollChanged: reports.add,
      );
      await _toTop(tester);
      expect(reports.last.nearTop, isTrue);

      await _pump(
        tester,
        history: _rows(1000, 1600),
        text: _lines(0, 100),
        onScrollChanged: reports.add,
      );
      await tester.pumpAndSettle();

      expect(reports.last, (nearTop: false, following: false));
    });

    testWidgets('a short pane is near its top and following, and says so once',
        (tester) async {
      final reports = <TerminalScroll>[];
      await _pump(tester, text: 'hello', onScrollChanged: reports.add);
      await tester.pump();

      expect(reports, [(nearTop: true, following: true)]);
    });
  });
}
