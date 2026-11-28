import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/files/match_ellipsis.dart';

import 'support/shot.dart' show loadAppFonts;

// A search result is cut to fit its row, and the cut must not hide the very thing
// the person typed: the part of the name that matched stays in view and is marked.
// The match rule is the machine's (`file_walk_search.dart`, `svc/search.rs`): a
// case-insensitive part of the name, accents not folded.

const _scaler = TextScaler.noScaling;

double _width(MatchedName m, TextStyle style) => (TextPainter(
  text: TextSpan(text: m.text, style: style),
  textDirection: TextDirection.ltr,
)..layout()).width;

void main() {
  setUpAll(loadAppFonts);

  group('matchSpan', () {
    test('finds the first part of the name that holds the query, whatever the case', () {
      expect(matchSpan('Report_final_report.md', 'REPORT'), (start: 0, end: 6));
      expect(matchSpan('payment_report.dart', ' Report '), (start: 8, end: 14), reason: 'the query is trimmed');
      expect(matchSpan('x.md', 'report'), isNull);
      expect(matchSpan('x.md', ''), isNull);
      expect(matchSpan('x.md', '   '), isNull);
    });

    test('Vietnamese: capitals find lower case, accents are not folded', () {
      const name = 'Báo cáo tổng hợp đã chỉnh sửa.docx';
      final span = matchSpan(name, 'CHỈNH')!;
      expect(name.substring(span.start, span.end), 'chỉnh');
      expect(matchSpan(name, 'chinh'), isNull, reason: 'the machine does not fold accents either');
      expect(matchSpan('Đồng hồ.txt', 'đồng'), (start: 0, end: 4));
    });

    test('an accent written as a separate mark stays inside the matched character', () {
      // `ỉ` as i + combining hook above (what a Mac writes) is one character on screen.
      const name = 'ch\u0069\u0309nh.txt';
      final span = matchSpan(name, 'i')!;
      expect(name.substring(span.start, span.end), '\u0069\u0309', reason: 'never half a character');
      expect(matchSpan('CHI\u0309NH.TXT', 'ch\u0069\u0309nh'), (start: 0, end: 6));
    });

    test('a name that changes length when lower-cased still maps to its own offsets', () {
      const name = 'İstanbul-report.md';
      final span = matchSpan(name, 'report')!;
      expect(name.substring(span.start, span.end), 'report');
    });
  });

  group('fitAroundMatch', () {
    final style = Type.row;

    MatchedName fit(String name, String query, double width, {int lines = 1}) =>
        fitAroundMatch(name, matchSpan(name, query)!, width, style, _scaler, maxLines: lines);

    test('a name that fits is left whole', () {
      final m = fit('report.md', 'report', 300);
      expect(m, const MatchedName('', 'report', '.md'));
    });

    test('the match stays whole and in view at every width that can hold it', () {
      const names = [
        ('payment_service_integration_report_with_the_ledger_and_retries....test.dart', 'report'),
        ('Báo cáo tổng hợp quý ba năm 2026 bản cuối cùng đã chỉnh sửa.docx', 'chỉnh'),
        ('a-very-long-prefix-before-the-part-you-typed-report.txt', 'report'),
        ('report-zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz.png', 'report'),
        ('Đồng hồ đo hiệu năng và độ trễ của toàn bộ hệ thống thanh toán.txt', 'ĐO HIỆU'),
      ];
      for (final (name, query) in names) {
        final span = matchSpan(name, query)!;
        final wanted = name.substring(span.start, span.end);
        for (var w = 120.0; w <= 420; w += 7) {
          final m = fit(name, query, w);
          expect(m.match, wanted, reason: '$name at $w: $m');
          expect(_width(m, style), lessThanOrEqualTo(w), reason: '$name at $w: $m');
        }
      }
    });

    test('keeps the extension and some of the start, each cut in its own middle', () {
      final m = fit('payment_service_integration_report_with_the_ledger_and_retries....test.dart', 'report', 330);
      expect(m.trail, endsWith('test.dart'));
      expect(m.trail, contains('…'));
      expect(m.lead, startsWith('pay'));
      expect(m.lead, contains('…'));
      expect(m.lead, endsWith('_'), reason: 'what sits next to the match is kept');
    });

    test('when the match is near the start, only the end is cut', () {
      final m = fit('report-zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz.png', 'report', 260);
      expect(m.lead, '');
      expect(m.match, 'report');
      expect(m.trail, startsWith('-'));
      expect(m.trail, endsWith('.png'));
    });

    test('when the match is at the end, only the start is cut', () {
      final m = fit('a-very-long-prefix-before-the-part-you-typed-report', 'report', 220);
      expect(m.trail, '');
      expect(m.lead, startsWith('a-'));
      expect(m.lead, contains('…'));
    });

    test('a query wider than the room keeps the start of the match and an ellipsis', () {
      final name = 'the-quarterly-report-for-the-board.md';
      final m = fit(name, 'quarterly-report-for-the-board', 90);
      expect(m.lead, '');
      expect(m.trail, '');
      expect(m.match, endsWith('…'));
      expect(m.match.length, greaterThan(2));
      expect('quarterly-report-for-the-board', startsWith(m.match.substring(0, m.match.length - 1)));
      expect(_width(m, style), lessThanOrEqualTo(90));
    });

    test('a second line holds more of the name, so more of it is kept', () {
      const name = 'payment_service_integration_report_with_the_ledger_and_retries....test.dart';
      final one = fit(name, 'report', 190);
      final two = fit(name, 'report', 190, lines: 2);
      expect(two.text.length, greaterThan(one.text.length));
      expect(two.match, 'report');
    });
  });

  group('MatchedNameText', () {
    const name = 'payment_service_integration_report_with_the_ledger_and_retries....test.dart';

    Future<void> pump(WidgetTester tester, {required double scale, required double width}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Center(
              child: SizedBox(
                width: width,
                child: MatchedNameText(name, span: matchSpan(name, 'report')!, style: Type.row),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('the match is the marked span, the screen reader hears the whole name', (tester) async {
      await pump(tester, scale: 1, width: 300);
      final rich = tester.widget<Text>(find.byType(Text)).textSpan!;
      final marked = [
        for (final s in (rich as TextSpan).children!.cast<TextSpan>())
          if (s.style?.backgroundColor != null) s.text,
      ];
      expect(marked, ['report']);
      expect(find.bySemanticsLabel(name), findsOneWidget);
    });

    testWidgets('one line at normal size, two at large text', (tester) async {
      await pump(tester, scale: 1, width: 200);
      expect(tester.widget<Text>(find.byType(Text)).maxLines, 1);
      await pump(tester, scale: 1.6, width: 200);
      expect(tester.widget<Text>(find.byType(Text)).maxLines, 2);
      expect(tester.takeException(), isNull);
    });
  });
}
