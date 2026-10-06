import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/markdown/highlight/highlight.dart';
import 'package:herdr_mobile/ui/core/markdown/md_highlight.dart';
import 'package:herdr_mobile/ui/core/theme.dart';

Future<MdCodeColors> _colors(WidgetTester tester, ThemeData theme) async {
  late MdCodeColors colors;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      themeAnimationDuration: Duration.zero,
      home: Builder(
        builder: (context) {
          colors = MdCodeColors.of(context);
          return const SizedBox();
        },
      ),
    ),
  );
  return colors;
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

String _flat(TextSpan span) => span.toPlainText();

void main() {
  group('mdCodeLines', () {
    test('control and bidi characters become visible escapes', () {
      expect(mdCodeLines('a\u202Eb\u001B[0m'), ['a\u2039U+202E\u203ab\u2039U+001B\u203a[0m']);
    });

    test('tabs go to the next multiple of four', () {
      expect(mdCodeLines('\tx\nab\tc'), ['    x', 'ab  c']);
    });

    test('a very long line is cut and counted', () {
      final line = mdCodeLines('y' * (mdCodeLineLimit + 50)).single;
      expect(line, endsWith('… +50 characters'));
      expect(line.length, lessThan(mdCodeLineLimit + 30));
    });

    test('lines split on newlines only', () {
      expect(mdCodeLines('a\n\nb'), ['a', '', 'b']);
    });
  });

  group('MdCodeLines', () {
    testWidgets('a block that grows keeps the colours of the lines before it', (tester) async {
      final colors = await _colors(tester, AppTheme.light());
      final lines = MdCodeLines('dart')..setText("final a = 'x';\nint b = 2;");
      lines.highlightUpTo(2);
      final first = lines.span(0, colors);
      final second = lines.span(1, colors);
      expect(first.children, isNotEmpty, reason: 'dart is highlighted');

      expect(lines.setText("final a = 'x';\nint b = 2;\nreturn b;"), isTrue);
      lines.highlightUpTo(3);
      expect(identical(lines.span(0, colors), first), isTrue);
      expect(identical(lines.span(1, colors), second), isTrue);
      expect(_flat(lines.span(2, colors)), 'return b;');
      expect(lines.span(2, colors).children, isNotEmpty);
    });

    testWidgets('a changed line is tokenized again, and so is everything after it', (tester) async {
      final colors = await _colors(tester, AppTheme.light());
      final lines = MdCodeLines('dart')..setText('/* open\nstill comment\nint a = 1;');
      lines.highlightUpTo(3);
      final comment = lines.span(2, colors);
      // The comment closes on line 0: line 2 is code now, not comment.
      lines.setText('/* closed */\nstill comment\nint a = 1;');
      lines.highlightUpTo(3);
      expect(identical(lines.span(2, colors), comment), isFalse);
      expect(lines.span(2, colors).children!.length, greaterThan(1));
    });

    testWidgets('lines past what was asked for are plain, and a late line is coloured when asked for', (tester) async {
      final colors = await _colors(tester, AppTheme.light());
      final lines = MdCodeLines('dart')..setText('final a = 1;\nfinal b = 2;');
      lines.highlightUpTo(1);
      expect(lines.span(1, colors).children, isNull, reason: 'one plain span');
      lines.highlightUpTo(2);
      expect(lines.span(1, colors).children, isNotEmpty);
    });

    testWidgets('an unknown or missing language stays plain', (tester) async {
      final colors = await _colors(tester, AppTheme.light());
      for (final language in ['', 'klingon', 'mermaid']) {
        final lines = MdCodeLines(language)..setText('final a = 1;');
        lines.highlightUpTo(1);
        expect(lines.highlights, isFalse, reason: language);
        expect(lines.span(0, colors).children, isNull);
      }
    });

    testWidgets('a theme change draws the same lines in the new colours', (tester) async {
      final light = await _colors(tester, AppTheme.light());
      final dark = await _colors(tester, AppTheme.dark());
      final lines = MdCodeLines('dart')..setText("final a = 'x';");
      lines.highlightUpTo(1);
      final a = lines.span(0, light);
      final b = lines.span(0, dark);
      expect(identical(a, b), isFalse);
      expect(a.children!.first.style?.color ?? light.plain, isNot(b.children!.first.style?.color ?? dark.plain));
    });
  });

  group('colours', () {
    testWidgets('every token kind reads on the block background, light and dark', (tester) async {
      for (final (name, theme) in [('light', AppTheme.light()), ('dark', AppTheme.dark()), ('dark terminal on paper', AppTheme.light(terminal: TerminalPalette.dark)), ('light terminal on ink', AppTheme.dark(terminal: TerminalPalette.light))]) {
        final colors = await _colors(tester, theme);
        for (final kind in TokenKind.values) {
          expect(_contrast(colors.of(kind), colors.background), greaterThanOrEqualTo(4.5), reason: '$name ${kind.name}');
        }
        expect(_contrast(colors.muted, colors.background), greaterThanOrEqualTo(4.5), reason: '$name label');
      }
    });

    testWidgets('a dark terminal on paper takes the terminal page for the block', (tester) async {
      final colors = await _colors(tester, AppTheme.light(terminal: TerminalPalette.dark));
      expect(colors.background, TerminalPalette.dark.background);
      final normal = await _colors(tester, AppTheme.light());
      expect(normal.background, Ds.paper.fill);
    });
  });
}
