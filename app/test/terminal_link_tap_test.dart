import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/terminal_cells.dart';
import 'package:herdr_mobile/ui/core/terminal_links.dart';
import 'package:herdr_mobile/ui/core/terminal_view.dart';
import 'package:herdr_mobile/ui/core/theme.dart';

/// The pane is drawn in the dark palette here (the harness theme is dark).
final terminalLinkColor = TerminalPalette.dark.link;

/// Taps seen by the view under test.
final _taps = <TerminalLink>[];

Future<void> _pump(
  WidgetTester tester,
  String text, {
  bool wrap = false,
  double fontSize = 11.5,
  double width = 900,
  bool tappable = true,
}) {
  _taps.clear();
  return tester.pumpWidget(
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
              wrap: wrap,
              fontSize: fontSize,
              onLinkTap: tappable ? _taps.add : null,
            ),
          ),
        ),
      ),
    ),
  );
}

/// The row showing text that contains [needle].
Finder _row(String needle) => find.byWidgetPredicate(
      (w) => w is TerminalLineView && w.line.span.toPlainText().contains(needle),
    );

/// Where cell [column] of the row sits on screen.
Offset _cell(WidgetTester tester, Finder row, int column, double fontSize) {
  final metrics = CellMetrics.measure(fontSize, tester.view.devicePixelRatio);
  final rect = tester.getRect(row.first);
  return Offset(rect.left + (column + 0.5) * metrics.advance, rect.center.dy);
}

Future<void> _tapCell(WidgetTester tester, Finder row, int column, [double fontSize = 11.5]) async {
  await tester.tapAt(_cell(tester, row, column, fontSize));
  await tester.pump(const Duration(milliseconds: 400));
}

/// Pixels of the view, as 0xAARRGGBB at (x, y) in device pixels.
Future<({int width, int height, int Function(int x, int y) at})> _capture(
  WidgetTester tester,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find
        .descendant(of: find.byType(TerminalView), matching: find.byType(RepaintBoundary))
        .first,
  );
  final dpr = tester.view.devicePixelRatio;
  return (await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage(pixelRatio: dpr);
    final data = (await image.toByteData())!;
    final width = image.width;
    final height = image.height;
    image.dispose();
    return (
      width: width,
      height: height,
      at: (int x, int y) {
        final i = (y * width + x) * 4;
        return (data.getUint8(i + 3) << 24) |
            (data.getUint8(i) << 16) |
            (data.getUint8(i + 1) << 8) |
            data.getUint8(i + 2);
      },
    );
  }))!;
}

void main() {
  group('a tap on a link', () {
    testWidgets('reports a URL, only from the cells it covers', (tester) async {
      await _pump(tester, 'see https://example.com/docs for more');
      final row = _row('https://');

      await _tapCell(tester, row, 3);
      await _tapCell(tester, row, 36 - 1 + 1); // beyond the link: ' for more'
      expect(_taps, isEmpty);

      for (final column in [4, 10, 4 + 'https://example.com/docs'.length - 1]) {
        await _tapCell(tester, row, column);
      }
      expect(_taps, hasLength(3));
      expect(_taps.map((l) => l.target).toSet(), {'https://example.com/docs'});
      expect(_taps.first.kind, TerminalLinkKind.url);

      _taps.clear();
      await _tapCell(tester, row, 4 + 'https://example.com/docs'.length);
      expect(_taps, isEmpty, reason: 'the cell after the last one');
    });

    testWidgets('reports a path with its line and column', (tester) async {
      await _pump(tester, 'error in lib/src/main.dart:42:7 here');
      await _tapCell(tester, _row('main.dart'), 12);

      expect(_taps.single.kind, TerminalLinkKind.path);
      expect(_taps.single.target, 'lib/src/main.dart');
      expect(_taps.single.line, 42);
      expect(_taps.single.column, 7);
    });

    testWidgets('lands on the right link when a line has two', (tester) async {
      await _pump(tester, 'a.dart then https://x.dev/y end');
      final row = _row('x.dev');

      await _tapCell(tester, row, 1);
      await _tapCell(tester, row, 15);

      expect(_taps.map((l) => l.target), ['a.dart', 'https://x.dev/y']);
    });

    for (final size in [8.0, 11.5, 14.0, 18.0, 24.0]) {
      testWidgets('hits the first and last cell at font size $size', (tester) async {
        await _pump(tester, 'go lib/ui/core/ansi.dart now', fontSize: size);
        final row = _row('ansi.dart');
        const start = 3;
        const end = start + 'lib/ui/core/ansi.dart'.length;

        await _tapCell(tester, row, start, size);
        await _tapCell(tester, row, end - 1, size);
        expect(_taps, hasLength(2), reason: 'size $size');

        _taps.clear();
        await _tapCell(tester, row, start - 1, size);
        await _tapCell(tester, row, end, size);
        expect(_taps, isEmpty, reason: 'size $size');
      });
    }

    testWidgets('respects the text scale', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      _taps.clear();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 900,
                height: 400,
                child: TerminalView(
                  text: 'go lib/ui/core/ansi.dart now',
                  onLinkTap: _taps.add,
                ),
              ),
            ),
          ),
        ),
      );
      final row = _row('ansi.dart');

      await _tapCell(tester, row, 3, 11.5 * 1.3);
      await _tapCell(tester, row, 3 + 'lib/ui/core/ansi.dart'.length - 1, 11.5 * 1.3);
      expect(_taps, hasLength(2));
    });

    testWidgets('follows wide characters: cells, not characters', (tester) async {
      await _pump(tester, '日本語 /tmp/x.txt');
      final row = _row('/tmp/x.txt');

      for (final column in [0, 2, 5]) {
        await _tapCell(tester, row, column);
      }
      expect(_taps, isEmpty, reason: 'on the CJK characters');

      await _tapCell(tester, row, 7);
      await _tapCell(tester, row, 7 + '/tmp/x.txt'.length - 1);
      expect(_taps.map((l) => l.target), ['/tmp/x.txt', '/tmp/x.txt']);
    });

    testWidgets('a link in a Vietnamese file name', (tester) async {
      await _pump(tester, 'mở ~/Tài_liệu/báo-cáo.md ngay');
      await _tapCell(tester, _row('báo-cáo'), 8);

      expect(_taps.single.target, '~/Tài_liệu/báo-cáo.md');
    });

    testWidgets('is found after scrolling sideways', (tester) async {
      await _pump(tester, '${'x' * 100} https://example.com/far away');
      final row = _row('https://');
      await tester.dragFrom(_cell(tester, row, 3, 11.5), const Offset(-1000, 0));
      await tester.pumpAndSettle();

      final column = 101 + 6;
      final at = _cell(tester, row, column, 11.5);
      expect(at.dx, inInclusiveRange(0, 900), reason: 'the link is on screen now');
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 400));

      expect(_taps.single.target, 'https://example.com/far');
    });

    testWidgets('does nothing without a handler, and draws no underline',
        (tester) async {
      await _pump(tester, 'see https://example.com/docs', tappable: false);
      final line = (tester.widget(_row('https://').first) as TerminalLineView).line;

      expect(line.links, isEmpty);
      await tester.tapAt(_cell(tester, _row('https://'), 8, 11.5));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_taps, isEmpty);
    });
  });

  group('wrapped lines', () {
    const url = 'https://example.com/a/very/long/path/that/wraps/over/rows.html';

    /// The rows holding a piece of a link, top to bottom.
    Future<List<Finder>> rowsOfLink(WidgetTester tester) async {
      final rows = [
        for (final e in find
            .byWidgetPredicate((w) => w is TerminalLineView && w.line.links.isNotEmpty)
            .evaluate())
          find.byWidget(e.widget),
      ]..sort((a, b) => tester.getTopLeft(a).dy.compareTo(tester.getTopLeft(b).dy));
      return rows;
    }

    testWidgets('every row of a wrapped URL opens the whole URL', (tester) async {
      await _pump(tester, 'see $url ok', wrap: true, width: 360);
      final rows = await rowsOfLink(tester);
      expect(rows.length, greaterThan(1), reason: 'the URL wraps');

      for (final row in rows) {
        final links = (tester.widget(row) as TerminalLineView).line.links;
        await _tapCell(tester, row, (links.first.start + links.first.end) ~/ 2);
      }

      expect(_taps, hasLength(rows.length));
      expect(_taps.map((l) => l.target).toSet(), {url});
    });

    testWidgets('only the cells of the link on a wrapped row count', (tester) async {
      await _pump(tester, 'see $url ok', wrap: true, width: 360);
      final first = (await rowsOfLink(tester)).first;
      final line = (tester.widget(first) as TerminalLineView).line;
      final link = line.links.single;
      expect(link.start, 4);

      await _tapCell(tester, first, link.start - 1);
      expect(_taps, isEmpty);
      await _tapCell(tester, first, link.start);
      expect(_taps, hasLength(1));
    });

    testWidgets('after zooming, rows wrap elsewhere and still hit', (tester) async {
      for (final size in [9.0, 13.0, 20.0]) {
        await _pump(tester, 'see $url ok', wrap: true, fontSize: size, width: 360);
        final rows = await rowsOfLink(tester);
        for (final row in rows) {
          final links = (tester.widget(row) as TerminalLineView).line.links;
          await _tapCell(tester, row, links.first.start, size);
        }
        expect(_taps, hasLength(rows.length), reason: 'size $size');
        expect(_taps.map((l) => l.target).toSet(), {url});
      }
    });

    testWidgets('a wide character at the break does not shift the link', (tester) async {
      // Nine cells fill a row but for the last one, which a wide character
      // cannot use: that row is a cell short.
      await _pump(tester, 'abcdef日本語 /tmp/file.txt end', wrap: true, width: 130);
      final rows = await rowsOfLink(tester);
      expect(rows, isNotEmpty);
      for (final row in rows) {
        final links = (tester.widget(row) as TerminalLineView).line.links;
        await _tapCell(tester, row, links.first.start);
      }
      expect(_taps.map((l) => l.target).toSet(), {'/tmp/file.txt'});
    });
  });

  group('gestures', () {
    String linkRows(int count) => [
          for (var i = 0; i < count; i++) 'row $i https://example.com/page/$i end',
        ].join('\r\n');

    testWidgets('a vertical drag that starts on a link scrolls and opens nothing',
        (tester) async {
      await _pump(tester, linkRows(200));
      final position = tester
          .state<ScrollableState>(find
              .descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable))
              .first)
          .position;
      expect(position.pixels, 0);

      final row = _row('row 199');
      await tester.dragFrom(_cell(tester, row, 12, 11.5), const Offset(0, 200));
      await tester.pumpAndSettle();

      expect(position.pixels, greaterThan(100));
      expect(_taps, isEmpty);
    });

    testWidgets('a horizontal drag that starts on a link scrolls and opens nothing',
        (tester) async {
      await _pump(tester, '${'x' * 4} https://example.com/${'y' * 100}');
      final horizontal = tester
          .state<ScrollableState>(find
              .descendant(of: find.byType(TerminalView), matching: find.byType(Scrollable))
              .first)
          .position;

      await tester.dragFrom(_cell(tester, _row('https://'), 12, 11.5), const Offset(-120, 0));
      await tester.pumpAndSettle();

      expect(horizontal.pixels, greaterThan(50));
      expect(_taps, isEmpty);
    });

    testWidgets('a fling that starts on a link opens nothing', (tester) async {
      await _pump(tester, linkRows(300));
      final row = _row('row 299');
      await tester.flingFrom(_cell(tester, row, 12, 11.5), const Offset(0, 300), 2000);
      await tester.pumpAndSettle();

      expect(_taps, isEmpty);
    });

    testWidgets('a touch that stops a fling does not open what is under it',
        (tester) async {
      await _pump(tester, linkRows(300));
      await tester.fling(find.byType(TerminalView), const Offset(0, 300), 2000);
      await tester.pump(const Duration(milliseconds: 50));

      final visible = find.byWidgetPredicate(
        (w) => w is TerminalLineView && w.line.links.isNotEmpty,
      );
      final row = visible.at(visible.evaluate().length ~/ 2);
      await tester.tapAt(_cell(tester, row, 12, 11.5));
      await tester.pump(const Duration(milliseconds: 100));
      expect(_taps, isEmpty, reason: 'it only stopped the scroll');

      await tester.pumpAndSettle();
      final settled = visible.at(visible.evaluate().length ~/ 2);
      await tester.tapAt(_cell(tester, settled, 12, 11.5));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_taps, hasLength(1), reason: 'at rest a tap opens it');
    });

    testWidgets('a long press selects instead of opening', (tester) async {
      await _pump(tester, linkRows(5));
      final at = _cell(tester, _row('row 4'), 12, 11.5);
      final gesture = await tester.startGesture(at);
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(_taps, isEmpty);
    });

    testWidgets('a tap beside the link is left to the selection', (tester) async {
      await _pump(tester, linkRows(5));
      await _tapCell(tester, _row('row 4'), 1);

      expect(_taps, isEmpty);
    });

    testWidgets('two fingers on a link pinch instead of opening it', (tester) async {
      var size = 0.0;
      _taps.clear();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 900,
                height: 400,
                child: TerminalView(
                  text: linkRows(40),
                  onLinkTap: _taps.add,
                  onFontSizeChanged: (s) => size = s,
                ),
              ),
            ),
          ),
        ),
      );
      final at = _cell(tester, _row('row 39'), 12, 11.5);
      final a = await tester.startGesture(at);
      final b = await tester.startGesture(at + const Offset(0, -80));
      await a.moveBy(const Offset(0, 120));
      await b.moveBy(const Offset(0, -120));
      await a.up();
      await b.up();
      await tester.pumpAndSettle();

      expect(size, greaterThan(11.5));
      expect(_taps, isEmpty);
    });
  });

  group('drawing', () {
    /// Longest run of [color] pixels on one pixel row between [x0] and [x1].
    int longestRun(
      ({int width, int height, int Function(int, int) at}) pixels,
      Color color,
      int x0,
      int x1,
    ) {
      var best = 0;
      for (var y = 0; y < pixels.height; y++) {
        var run = 0;
        for (var x = x0; x < x1 && x < pixels.width; x++) {
          run = pixels.at(x, y) == color.toARGB32() ? run + 1 : 0;
          if (run > best) best = run;
        }
      }
      return best;
    }

    testWidgets('links are underlined across their cells and nowhere else',
        (tester) async {
      // Text in the terminal's own colour, so only the underline and the
      // recoloured link text can be the link colour.
      await _pump(tester, 'plain words https://example.com/docs and more words');
      final dpr = tester.view.devicePixelRatio;
      final metrics = CellMetrics.measure(11.5, dpr);
      final pad = (12 * dpr).roundToDouble();
      int px(int column) => (pad + metrics.columnEdge(column)).round();
      const start = 12;
      const end = start + 'https://example.com/docs'.length;
      final pixels = await _capture(tester);

      final inside = longestRun(pixels, terminalLinkColor, px(start), px(end));
      expect(inside, greaterThanOrEqualTo(px(end) - px(start) - 2),
          reason: 'one unbroken line under the link');
      expect(longestRun(pixels, terminalLinkColor, px(0), px(start - 1)), lessThan(metrics.advancePx),
          reason: 'none under the words before');
      expect(longestRun(pixels, terminalLinkColor, px(end + 1), px(end + 20)), lessThan(metrics.advancePx),
          reason: 'none under the words after');
    });

    testWidgets('link text is in the link colour; coloured text keeps its own',
        (tester) async {
      await _pump(
        tester,
        'plain https://a.dev/x \x1b[31mred https://b.dev/y\x1b[0m',
      );
      final line = (tester.widget(_row('a.dev').first) as TerminalLineView).line;
      final spans = line.span.children!.cast<TextSpan>();
      final byText = {for (final s in spans) s.text: s.style?.color};

      expect(byText['https://a.dev/x'], terminalLinkColor);
      expect(byText['plain '], isNull);
      expect(byText['https://b.dev/y'], TerminalColors.ansi[1], reason: 'it is red already');
      expect(spans.map((s) => s.text).join(), 'plain https://a.dev/x red https://b.dev/y');
    });

    testWidgets('a dim line stays dim under its link', (tester) async {
      await _pump(tester, '\x1b[2mdim https://a.dev/x\x1b[0m');
      final line = (tester.widget(_row('a.dev').first) as TerminalLineView).line;
      final link = line.span.children!.cast<TextSpan>().last;

      expect(link.style!.color, isNot(terminalLinkColor));
      expect(link.style!.color!.computeLuminance(),
          lessThan(terminalLinkColor.computeLuminance()));
    });

    testWidgets('the text layer keeps its cells: the span only splits', (tester) async {
      await _pump(tester, 'ab https://a.dev/x│cd');
      final line = (tester.widget(_row('a.dev').first) as TerminalLineView).line;

      expect(line.span.toPlainText(), 'ab https://a.dev/x cd', reason: 'box glyphs stay blanked');
    });
  });
}
