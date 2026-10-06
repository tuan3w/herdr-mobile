import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/ui/core/ansi.dart';
import 'package:herdr_mobile/ui/core/glyphs.dart';
import 'package:herdr_mobile/ui/core/motion.dart';
import 'package:herdr_mobile/ui/core/terminal_cells.dart';
import 'package:herdr_mobile/ui/core/terminal_jump.dart';
import 'package:herdr_mobile/ui/core/terminal_view.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'support/terminal_rows.dart';

String _lines(int from, int to) =>
    [for (var i = from; i < to; i++) 'line $i'].join('\r\n');

Future<void> _pump(
  WidgetTester tester,
  String text, {
  bool reduceMotion = false,
  double textScale = 1,
  bool blocked = false,
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
                  child: TerminalView(text: text, blocked: blocked),
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

    expect(find.byType(TerminalLineView).evaluate().length, inInclusiveRange(15, 70));
    expect(terminalRow('line 299'), findsOneWidget);
    expect(terminalRow('line 0'), findsNothing);
  });

  testWidgets('short output hugs the top', (tester) async {
    await _pump(tester, 'hi');

    expect(tester.getTopLeft(terminalRow('hi')).dy, lessThan(20));
  });

  testWidgets('follows the newest line while at the bottom', (tester) async {
    await _pump(tester, _lines(0, 100));
    final bottom = tester.getBottomLeft(terminalRow('line 99')).dy;

    await _pump(tester, _lines(0, 110));

    expect(terminalRow('line 109'), findsOneWidget);
    expect(tester.getBottomLeft(terminalRow('line 109')).dy, closeTo(bottom, 0.01));
  });

  testWidgets('does not move what you are reading when output arrives',
      (tester) async {
    await _pump(tester, _lines(0, 200));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(terminalRow('line 150'), findsOneWidget);
    final reading = tester.getTopLeft(terminalRow('line 150')).dy;

    // Lines appended.
    await _pump(tester, _lines(0, 215));
    expect(tester.getTopLeft(terminalRow('line 150')).dy, closeTo(reading, 0.01));

    // The read window slid: ten lines left the top, ten arrived at the bottom.
    await _pump(tester, _lines(10, 225));
    expect(tester.getTopLeft(terminalRow('line 150')).dy, closeTo(reading, 0.01));

    // Text that shares nothing with the old window cannot be anchored, but
    // must not throw.
    await _pump(tester, _lines(1000, 1010));
    expect(tester.takeException(), isNull);
  });

  group('unchanged lines are not rebuilt into another item', () {
    // The widget and render object showing [line], and what they show.
    ({Element element, RenderParagraph paragraph, String shown, InlineSpan span})
        probe(WidgetTester tester, String line) {
      final finder = terminalRow(line);
      final element = finder.evaluate().single;
      final paragraph = tester.renderObject<RenderParagraph>(finder);
      return (
        element: element,
        paragraph: paragraph,
        shown: paragraph.text.toPlainText(),
        span: rowSpan(element.widget),
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

      expect(terminalRow('building 10%'), findsNothing);
      expect(terminalRow('building 20%'), findsOneWidget);
      expect(terminalRow('line 49'), findsOneWidget);
    });

    testWidgets('text sharing nothing with the old is a fresh document',
        (tester) async {
      await _pump(tester, _lines(0, 100));
      await _pump(tester, _lines(500, 600));

      expect(tester.takeException(), isNull);
      expect(terminalRow('line 599'), findsOneWidget);
      expect(terminalRow('line 99'), findsNothing);
      expect(probe(tester, 'line 599').shown, 'line 599');
    });

    testWidgets('repeated identical lines do not collide', (tester) async {
      await _pump(tester, List.filled(40, 'same').join('\r\n'));
      await _pump(tester, List.filled(45, 'same').join('\r\n'));

      expect(tester.takeException(), isNull);
      expect(terminalRow('same'), findsWidgets);
    });
  });

  testWidgets('the jump button shows only when scrolled up', (tester) async {
    await _pump(tester, _lines(0, 200));
    expect(_jumpButtonFade(tester).opacity, 0);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(_jumpButtonFade(tester).opacity, 1);
    expect(terminalRow('line 199'), findsNothing);

    await tester.tap(find.byTooltip('Jump to latest'));
    await tester.pumpAndSettle();

    expect(terminalRow('line 199'), findsOneWidget);
    expect(_jumpButtonFade(tester).opacity, 0);
  });

  testWidgets('the jump button animates, unless the phone asks for reduced motion', (tester) async {
    await _pump(tester, _lines(0, 20));
    expect(_jumpButtonFade(tester).duration, greaterThan(Duration.zero));

    await _pump(tester, _lines(0, 20), reduceMotion: true);
    expect(_jumpButtonFade(tester).duration, Duration.zero);
  });

  testWidgets('renders SGR colours and attributes', (tester) async {
    await _pump(
      tester,
      '\x1b[31mred\x1b[0m plain \x1b[1;4mbold\x1b[0m\r\n',
    );

    final runs = rowSpan(tester.widget(terminalRowContaining('red')))
        .children!
        .cast<TextSpan>();
    expect(runs.map((r) => r.text), ['red', ' plain ', 'bold']);
    expect(runs[0].style!.color, TerminalColors.ansi[1]);
    expect(runs[1].style, isNull);
    expect(runs[2].style!.fontWeight, FontWeight.w700);
    expect(runs[2].style!.decoration, TextDecoration.underline);
  });

  testWidgets('dim text stays readable', (tester) async {
    await _pump(tester, '\x1b[2mdim\x1b[0m');

    final color =
        rowSpan(tester.widget(terminalRow('dim'))).children!.single.style!.color!;
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
      return tester.getTopLeft(terminalRow('line 1')).dy -
          tester.getTopLeft(terminalRow('line 0')).dy;
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
    // The prepared row showing [line].
    TerminalLine lineOf(WidgetTester tester, String line) =>
        tester.widget<TerminalLineView>(terminalRow(line)).line;

    testWidgets('box drawing is painted, and shows as spaces in the text layer',
        (tester) async {
      await _pump(tester, '┌──┐ ok\r\n│  │');

      expect(terminalRow('     ok'), findsOneWidget);
      expect(terminalRowContaining('┌'), findsNothing);
      expect(terminalRowContaining('─'), findsNothing);
      expect(blankSprites('a│b▀c'), 'a b c');
      expect(blankSprites('plain'), 'plain');
    });

    testWidgets('backgrounds are not part of the text style', (tester) async {
      await _pump(tester, '\x1b[44mblue\x1b[0m');

      final run =
          rowSpan(tester.widget(terminalRow('blue'))).children!.single as TextSpan;
      expect(run.style, isNull);
    });

    testWidgets('prepared rows are reused for unchanged lines', (tester) async {
      await _pump(tester, '${_lines(0, 50)}\r\n\x1b[44m┌─┐\x1b[0m\r\ntail');
      final before = lineOf(tester, 'line 45');
      final picture = lineOf(tester, '   ');
      expect(picture.picture, isNotNull);
      final recorded = picture.picture;

      await _pump(tester, '${_lines(0, 50)}\r\n\x1b[44m┌─┐\x1b[0m\r\ntail\r\nnew');

      expect(lineOf(tester, 'line 45'), same(before));
      expect(lineOf(tester, '   '), same(picture));
      expect(lineOf(tester, '   ').picture, same(recorded),
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

  group('the jump pill', () {
    ScrollPosition position(WidgetTester tester) => tester
        .state<ScrollableState>(find.descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        ))
        .position;

    Future<void> scrollUp(WidgetTester tester, [double by = 600]) async {
      await tester.drag(find.byType(CustomScrollView), Offset(0, by));
      await tester.pumpAndSettle();
    }

    bool shown(WidgetTester tester) => _jumpButtonFade(tester).opacity == 1;
    Finder says(String text) => find.text(text);
    final anyCount = find.textContaining(RegExp(r'\d+\+? new'));

    testWidgets('counts the rows that arrive only while the reader is away, and '
        'starts again from zero', (tester) async {
      await _pump(tester, _lines(0, 200));
      await _pump(tester, _lines(0, 205));
      expect(shown(tester), isFalse);

      await scrollUp(tester);
      expect(shown(tester), isTrue);
      expect(anyCount, findsNothing, reason: 'nothing arrived yet: the chevron');
      expect(find.byTooltip('Jump to latest'), findsOneWidget);

      await _pump(tester, _lines(0, 206));
      expect(says('1 new line'), findsOneWidget);
      await _pump(tester, _lines(0, 209));
      expect(says('4 new lines'), findsOneWidget);

      await tester.tap(find.byTooltip('Jump to latest'));
      await tester.pumpAndSettle();
      expect(shown(tester), isFalse);
      await _pump(tester, _lines(0, 215));
      expect(shown(tester), isFalse, reason: 'following: nothing to count');

      await scrollUp(tester);
      expect(shown(tester), isTrue);
      expect(anyCount, findsNothing, reason: 'the old count did not come back');
      await _pump(tester, _lines(0, 217));
      expect(says('2 new lines'), findsOneWidget);
    });

    testWidgets('reaching the end by scrolling resets it too', (tester) async {
      await _pump(tester, _lines(0, 200));
      await scrollUp(tester);
      await _pump(tester, _lines(0, 203));
      expect(says('3 new lines'), findsOneWidget);

      await scrollUp(tester, -2000); // back down to the newest row
      expect(shown(tester), isFalse);
      await scrollUp(tester);
      expect(anyCount, findsNothing);
    });

    testWidgets('caps the text at 99+', (tester) async {
      await _pump(tester, _lines(0, 200));
      await scrollUp(tester);

      await _pump(tester, _lines(0, 299));
      expect(says('99 new lines'), findsOneWidget);
      await _pump(tester, _lines(0, 300));
      expect(says('99+ new'), findsOneWidget);
      await _pump(tester, _lines(0, 900));
      expect(says('99+ new'), findsOneWidget);
    });

    testWidgets('rows the read window dropped from the top are not news, and '
        'new rows below them still count', (tester) async {
      await _pump(tester, _lines(0, 200));
      await scrollUp(tester);

      // The window slid: 5 rows left the top, 5 arrived at the bottom.
      await _pump(tester, _lines(5, 205));
      expect(says('5 new lines'), findsOneWidget);
      // Rows dropped without any arriving: still 5.
      await _pump(tester, _lines(8, 205));
      expect(says('5 new lines'), findsOneWidget);
    });

    testWidgets('a redraw in place adds nothing', (tester) async {
      await _pump(tester, '${_lines(0, 200)}\r\nbuilding 10%');
      await scrollUp(tester);

      await _pump(tester, '${_lines(0, 200)}\r\nbuilding 20%');
      expect(anyCount, findsNothing);
    });

    testWidgets('a question that arrives while the reader is away says '
        '"Needs you", and goes when it is answered', (tester) async {
      await _pump(tester, _lines(0, 200));
      await scrollUp(tester);
      await _pump(tester, _lines(0, 203));
      expect(says('3 new lines'), findsOneWidget);

      await _pump(tester, _lines(0, 203), blocked: true);
      expect(says('Needs you'), findsOneWidget);
      expect(says('3 new lines'), findsNothing);
      final glyph = tester.widget<StatusGlyph>(find.descendant(
        of: find.byType(TerminalView),
        matching: find.byType(StatusGlyph),
      ));
      expect(glyph.status, AgentStatus.blocked);

      await _pump(tester, _lines(0, 204), blocked: false);
      expect(says('Needs you'), findsNothing);
      expect(says('4 new lines'), findsOneWidget);
    });

    testWidgets('a question that was already there when the reader left is not '
        'announced; tapping Needs you jumps down', (tester) async {
      await _pump(tester, _lines(0, 200), blocked: true);
      await scrollUp(tester);
      expect(says('Needs you'), findsNothing);
      await _pump(tester, _lines(0, 202), blocked: true);
      expect(says('2 new lines'), findsOneWidget);

      await _pump(tester, _lines(0, 202), blocked: false);
      await _pump(tester, _lines(0, 202), blocked: true);
      expect(says('Needs you'), findsOneWidget);

      await tester.tap(says('Needs you'));
      await tester.pumpAndSettle();
      expect(position(tester).pixels, 0);
      expect(shown(tester), isFalse);
      expect(terminalRow('line 201'), findsOneWidget);
    });

    testWidgets('a question arriving while the reader is at the end is not a pill',
        (tester) async {
      await _pump(tester, _lines(0, 200));
      await _pump(tester, _lines(0, 200), blocked: true);
      expect(shown(tester), isFalse);

      await scrollUp(tester);
      expect(says('Needs you'), findsNothing);
    });

    testWidgets('is announced with what it counts', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pump(tester, _lines(0, 200));
      expect(find.bySemanticsLabel(RegExp('jump to latest')), findsNothing);
      await scrollUp(tester);
      await _pump(tester, _lines(0, 203));
      expect(find.bySemanticsLabel('3 new lines, jump to latest'), findsOneWidget);
      await _pump(tester, _lines(0, 203), blocked: true);
      expect(find.bySemanticsLabel('Needs you, jump to latest'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a short way scrolls, eased and quickly', (tester) async {
      await _pump(tester, _lines(0, 200));
      await scrollUp(tester); // 1.5 viewports
      final start = position(tester).pixels;
      expect(start, greaterThan(500));

      await tester.tap(find.byTooltip('Jump to latest'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final mid = position(tester).pixels;
      expect(mid, inExclusiveRange(0, start), reason: 'on its way');
      expect(terminalRow('line 199'), findsNothing);

      await tester.pump(const Duration(milliseconds: 250));
      expect(position(tester).pixels, 0, reason: 'done within 250 ms');
      expect(terminalRow('line 199'), findsOneWidget);
    });

    testWidgets('a long way lands at once', (tester) async {
      await _pump(tester, _lines(0, 2000));
      final view = position(tester);
      view.jumpTo(view.viewportDimension * 5);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Jump to latest'));
      await tester.pump();

      expect(position(tester).pixels, 0);
      expect(terminalRow('line 1999'), findsOneWidget);
    });

    testWidgets('reduced motion lands at once, however short the way',
        (tester) async {
      await _pump(tester, _lines(0, 200), reduceMotion: true);
      await scrollUp(tester);
      expect(position(tester).pixels, greaterThan(500));

      await tester.tap(find.byTooltip('Jump to latest'));
      await tester.pump();

      expect(position(tester).pixels, 0);
      expect(_jumpButtonFade(tester).duration, Duration.zero);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('a tap is a tick, and nothing else is', (tester) async {
      final haptics = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') haptics.add(call.arguments as String);
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await _pump(tester, _lines(0, 200));
      await scrollUp(tester);
      await _pump(tester, _lines(0, 203));
      expect(haptics, isEmpty, reason: 'new output and scrolling make no sound');

      await tester.tap(find.byTooltip('Jump to latest'));
      await tester.pumpAndSettle();

      expect(haptics, ['HapticFeedbackType.selectionClick']);
    });

    testWidgets('fades and scales in and out, never below 0.9', (tester) async {
      await _pump(tester, _lines(0, 200));
      AnimatedScale scale() => tester.widget(find.descendant(
            of: find.byType(TerminalView),
            matching: find.byType(AnimatedScale),
          ).first);
      expect(scale().scale, inInclusiveRange(0.9, 1));
      expect(scale().scale, lessThan(1));

      await scrollUp(tester);
      expect(scale().scale, 1);
      expect(scale().duration, greaterThan(Duration.zero));
      expect(scale().curve, Motion.easeOut);
    });

    testWidgets('keeps its words while it fades out', (tester) async {
      await _pump(tester, _lines(0, 200));
      await scrollUp(tester);
      await _pump(tester, _lines(0, 203));
      await tester.tap(find.byTooltip('Jump to latest'));
      await tester.pump(const Duration(milliseconds: 40));

      expect(says('3 new lines'), findsOneWidget,
          reason: 'it does not turn into a chevron on its way out');
      await tester.pumpAndSettle();
      expect(shown(tester), isFalse);
    });
  });

  test('the pill says how much arrived, in words', () {
    expect(newLinesLabel(1), '1 new line');
    expect(newLinesLabel(2), '2 new lines');
    expect(newLinesLabel(99), '99 new lines');
    expect(newLinesLabel(100), '99+ new');
  });

  testWidgets('a height that changes every frame (the keyboard) rebuilds no rows',
      (tester) async {
    final height = ValueNotifier(500.0);
    addTearDown(height.dispose);
    // One instance: only the viewport changes, as when the Scaffold above
    // lifts the pane for the keyboard.
    final view = TerminalView(text: _lines(0, 300));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: ValueListenableBuilder<double>(
              valueListenable: height,
              builder: (context, h, _) =>
                  SizedBox(width: 360, height: h, child: view),
            ),
          ),
        ),
      ),
    );
    final before = find.byType(TerminalLineView).evaluate().length;

    var rebuilt = 0;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (builtOnce && element.widget is KeyedSubtree) rebuilt++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    for (var i = 1; i <= 10; i++) {
      height.value = 500.0 - i * 20;
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(rebuilt, 0);

    // Smaller view: fewer rows, still pinned to the newest.
    expect(find.byType(TerminalLineView).evaluate().length, lessThan(before));
    expect(terminalRow('line 299'), findsOneWidget);

    height.value = 500;
    await tester.pump();
    expect(find.byType(TerminalLineView).evaluate().length, before);
    expect(terminalRow('line 299'), findsOneWidget);
  });
}
