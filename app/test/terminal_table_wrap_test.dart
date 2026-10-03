// Wrapping re-flows prose to the phone's width. A table or a box was laid out
// for a fixed width and means nothing cut in pieces, so its rows stay whole and
// the view scrolls sideways for them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/table_lines.dart';
import 'package:herdr_mobile/ui/core/terminal_document.dart';
import 'package:herdr_mobile/ui/core/terminal_cells.dart';
import 'package:herdr_mobile/ui/core/terminal_view.dart';
import 'package:herdr_mobile/ui/core/theme.dart';

const _wide = '│ crate   │ version │ description of what this crate is for and how │';

Widget _app(Widget view) => MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 360, height: 400, child: view),
        ),
      ),
    );

ScrollableState _horizontal(WidgetTester tester) => tester.state<ScrollableState>(
      find
          .descendant(of: find.byType(TerminalView), matching: find.byType(Scrollable))
          .first,
    );

int _rows(WidgetTester tester) =>
    find.byType(TerminalLineView).evaluate().length;

void main() {
  group('isTableRow', () {
    test('box and table rows drawn with line characters', () {
      for (final row in [
        '│ name │ value │',
        '┃ name ┃ value ┃',
        '║ a ║ b ║',
        '┌──────┬───────┐',
        '├──────┼───────┤',
        '└──────┴───────┘',
        '╭────────────╮',
        '╰────────────╯',
        '  │ nested │ cell │  ',
      ]) {
        expect(isTableRow(row), isTrue, reason: row);
      }
    });

    test('markdown and ASCII tables', () {
      for (final row in [
        '| a | b |',
        '|---|---|',
        '  | name | value | note |  ',
        '+-----+-----+',
      ]) {
        expect(isTableRow(row), isTrue, reason: row);
      }
    });

    test('prose is not', () {
      for (final row in [
        '',
        '  ',
        'The quick brown fox jumps over the lazy dog.',
        'a | b',
        '| just a pipe at the start',
        'x ─ y',
        'one │ bar only',
        '+ a list item',
        '- item',
        '● Read(lib/main.dart)',
        '2 + 2 = 4',
      ]) {
        expect(isTableRow(row), isFalse, reason: '"$row"');
      }
    });
  });

  group('the document', () {
    test('a wide table row is one row at any width; prose is cut', () {
      final doc = TerminalDocument()..update(const [], 'a long sentence that has to be wrapped\n$_wide\n');
      final prose = doc.lines[0];
      final table = doc.lines[1];
      expect(prose.tabular, isFalse);
      expect(table.tabular, isTrue);
      expect(prose.rowCount(10), greaterThan(1));
      expect(table.rowCount(10), 1);
      expect(table.rows(10).length, 1);
      expect(identical(table.rows(10).single, table.runs), isTrue);
      expect(doc.tableColumns, table.columns);
      expect(doc.columns, greaterThanOrEqualTo(doc.tableColumns));
    });

    test('no table, no table width', () {
      final doc = TerminalDocument()..update(const [], 'one\ntwo\n');
      expect(doc.tableColumns, 0);
    });
  });

  group('the view', () {
    testWidgets('prose wraps, the table row stays whole, and the view scrolls sideways', (tester) async {
      final reports = <bool>[];
      await tester.pumpWidget(_app(TerminalView(
        text: 'a long sentence that has to be wrapped over several rows of the phone\r\n$_wide',
        wrap: true,
        onSidewaysChanged: reports.add,
      )));
      await tester.pump();
      await tester.pump();

      // The prose took more than one row; the table took exactly one.
      expect(_rows(tester), greaterThan(2));
      expect(reports, [true]);
      expect(_horizontal(tester).position.maxScrollExtent, greaterThan(0));

      // Short output hugs the top of the view: touch where the rows are.
      await tester.dragFrom(const Offset(100, 14), const Offset(-120, 0));
      await tester.pump();
      expect(_horizontal(tester).position.pixels, greaterThan(0));
    });

    testWidgets('without a table wider than the view, wrapping does not scroll sideways',
        (tester) async {
      final reports = <bool>[];
      await tester.pumpWidget(_app(TerminalView(
        text: 'a long sentence that has to be wrapped over several rows of the phone\r\n│ a │ b │',
        wrap: true,
        onSidewaysChanged: reports.add,
      )));
      await tester.pump();
      await tester.pump();
      expect(reports, isEmpty);
      expect(_horizontal(tester).position.maxScrollExtent, 0);
    });

    testWidgets('not wrapping is unchanged: the whole output scrolls sideways', (tester) async {
      final reports = <bool>[];
      await tester.pumpWidget(_app(TerminalView(
        text: 'a long sentence that has to be wrapped over several rows of the phone\r\n$_wide',
        onSidewaysChanged: reports.add,
      )));
      await tester.pump();
      expect(reports, isEmpty, reason: 'only a wrapping view reports it');
      expect(_horizontal(tester).position.maxScrollExtent, greaterThan(0));
    });

    testWidgets('the table going away puts the view back to plain wrapping', (tester) async {
      final reports = <bool>[];
      Widget view(String text) =>
          _app(TerminalView(text: text, wrap: true, onSidewaysChanged: reports.add));
      await tester.pumpWidget(view('intro\r\n$_wide'));
      await tester.pump();
      await tester.pump();
      expect(reports, [true]);

      await tester.pumpWidget(view('intro\r\nplain text now'));
      await tester.pump();
      await tester.pump();
      expect(reports, [true, false]);
      expect(_horizontal(tester).position.maxScrollExtent, 0);
    });
  });
}
