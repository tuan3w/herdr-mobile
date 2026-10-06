import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind, TapGestureRecognizer;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:flutter_test/flutter_test.dart' as ft show testWidgets;
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/ui/core/markdown/markdown.dart';
import 'package:herdr_mobile/ui/core/markdown/md_code_block.dart';
import 'package:herdr_mobile/ui/core/markdown/md_table_view.dart';
import 'package:herdr_mobile/ui/core/markdown/md_text.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/core/toast.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_md_scope.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_rows.dart';
import 'package:herdr_mobile/ui/features/agent_session/work_log_rows.dart';
import 'package:herdr_mobile/ui/features/files/markdown_view.dart';
import 'package:herdr_mobile/ui/features/files/text_document.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/fake_agent_session.dart';
import '../support/shot.dart' show phoneDpr;
import 'support/render_corpus.dart';

Widget _app(Widget child, {Brightness brightness = Brightness.light}) => MaterialApp(
  theme: AppTheme.light(),
  navigatorObservers: [ToastRouteObserver()],
  darkTheme: AppTheme.dark(),
  themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
  home: Scaffold(
    body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child),
  ),
);

Widget _doc(String markdown, {bool soft = true}) => MdDocumentView(document: parseMd(markdown, softBreaksAsNewlines: soft));

void _phone(WidgetTester tester, {double width = 412, double height = 892}) {
  tester.view.physicalSize = Size(width, height) * phoneDpr;
  tester.view.devicePixelRatio = phoneDpr;
  addTearDown(tester.view.reset);
}

/// `testWidgets` on a tall phone-wide screen: the rows under test are laid out
/// in a scroll view and must be on screen to be tapped.
void testWidgets(String description, Future<void> Function(WidgetTester tester) body, {bool semanticsEnabled = true}) {
  ft.testWidgets(description, (tester) async {
    _phone(tester, width: 412, height: 2400);
    await body(tester);
  }, semanticsEnabled: semanticsEnabled);
}

/// Every span of every RichText under [finder] as (text, colour).
List<(String, Color?)> _spans(WidgetTester tester, Finder finder) {
  final out = <(String, Color?)>[];
  for (final w in tester.widgetList<RichText>(finder)) {
    w.text.visitChildren((span) {
      if (span is TextSpan && span.text != null) out.add((span.text!, span.style?.color));
      return true;
    });
  }
  return out;
}

/// The tap recognizer of the first span whose text contains [text], or null.
/// (`tapOnText` hit-tests glyphs, which depends on the test font's metrics;
/// this asks what the renderer put on the span.)
TapGestureRecognizer? _recognizerOf(WidgetTester tester, String text) {
  TapGestureRecognizer? found;
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    rich.text.visitChildren((s) {
      if (found == null && s is TextSpan && (s.text?.contains(text) ?? false)) {
        final r = s.recognizer;
        if (r is TapGestureRecognizer) found = r;
        return found == null;
      }
      return true;
    });
    if (found != null) return found;
  }
  return null;
}

/// Taps the span containing [text] the way a pointer would: runs its recognizer.
Future<void> _tapSpan(WidgetTester tester, String text) async {
  final r = _recognizerOf(tester, text);
  if (r == null) fail('no tappable span contains "$text"');
  r.onTap!();
  await tester.pump();
}

String? _clipboard;

void _mockClipboard(WidgetTester tester) {
  _clipboard = null;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') _clipboard = (call.arguments as Map)['text'] as String?;
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
}

const _everything = '''
# Heading one

## Heading two

A paragraph with **bold**, *italic*, ~~gone~~, `code` and a [link](https://example.com/docs).
Second line of the same paragraph.

- bullet one
  - nested bullet
- bullet two

3. third
4. fourth

- [x] done task
- [ ] open task

> quoted text
> > nested quote

> [!WARNING]
> careful now

---

| Name | Count |
| :--- | ---: |
| alpha | 1 |
| beta | 22 |

```dart
final x = 1;
print(x);
```
''';

void main() {
  setUp(resetMdCodePreferences);

  group('blocks', () {
    testWidgets('every block type renders', (tester) async {
      await tester.pumpWidget(_app(_doc(_everything)));
      expect(tester.takeException(), isNull);

      bool has(String s) => find.textContaining(s, findRichText: true).evaluate().isNotEmpty;
      expect(has('Heading one'), isTrue);
      expect(has('Heading two'), isTrue);
      expect(has('A paragraph with bold, italic, gone, code and a link.\nSecond line'), isTrue, reason: 'soft breaks are newlines in chat prose');
      expect(has('bullet one'), isTrue);
      expect(has('nested bullet'), isTrue);
      expect(has('3.'), isTrue);
      expect(has('4.'), isTrue);
      expect(has('done task'), isTrue);
      expect(has('open task'), isTrue);
      expect(has('quoted text'), isTrue);
      expect(has('nested quote'), isTrue);
      expect(has('Warning'), isTrue);
      expect(has('careful now'), isTrue);
      expect(has('alpha'), isTrue);
      expect(has('22'), isTrue);
      expect(has('final x = 1;'), isTrue);
      expect(find.byType(MdTableView), findsOneWidget);
      expect(find.byType(MdCodeBlock), findsOneWidget);
    });

    testWidgets('inline styles are applied to the spans', (tester) async {
      await tester.pumpWidget(_app(_doc('A **bold**, *it*, ~~gone~~ and `code` [site](https://example.com).')));
      final text = tester.widgetList<RichText>(find.byType(RichText)).first.text as TextSpan;
      final spans = <TextSpan>[];
      text.visitChildren((s) {
        if (s is TextSpan && s.text != null) spans.add(s);
        return true;
      });
      TextSpan span(String t) => spans.firstWhere((s) => s.text == t);
      expect(span('bold').style!.fontWeight, FontWeight.w700);
      expect(span('it').style!.fontStyle, FontStyle.italic);
      expect(span('gone').style!.decoration, TextDecoration.lineThrough);
      expect(span('code').style!.fontFamily, monoFamily);
      expect(span('site').style!.decoration, TextDecoration.underline);
      expect(span('site').style!.color, Ds.paper.accentText);
    });

    testWidgets('an ordered list keeps its start and every item is numbered', (tester) async {
      await tester.pumpWidget(_app(_doc('7. seven\n8. eight\n9. nine\n10. ten')));
      for (final n in ['7.', '8.', '9.', '10.']) {
        expect(find.text(n), findsOneWidget);
      }
    });

    testWidgets('a task item is a status shape, not a checkbox', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(_doc('- [x] done\n- [ ] open')));
      expect(find.bySemanticsLabel('Done'), findsOneWidget);
      expect(find.bySemanticsLabel('Not done'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
      handle.dispose();
    });

    test('mdBlockGap: headings take room, a lead-in sits close to its list', () {
      final doc = parseMd('para\n\n# h1\n\n### h3\n\ntext\n\nlead:\n\n- a\n\n---\n\nend');
      final b = doc.blocks;
      expect(mdBlockGap(null, b[0]), 0);
      expect(mdBlockGap(b[0], b[1]), 16);
      expect(mdBlockGap(b[1], b[2]), 12);
      expect(mdBlockGap(b[2], b[3]), 6);
      expect(mdBlockGap(b[4], b[5]), 6);
      expect(mdBlockGap(b[5], b[6]), 12);
      expect(mdBlockGap(b[3], b[4]), 10);
    });
  });

  group('links, paths and images', () {
    testWidgets('a tapped link opens the link sheet with the full address', (tester) async {
      final session = FakeAgentSession();
      await tester.pumpWidget(
        _app(AgentMdScope(session: session, child: _doc('See the [docs](https://example.com/a/very/long/path?x=1) now.'))),
      );
      await _tapSpan(tester, 'docs');
      await tester.pumpAndSettle();
      expect(find.text('example.com'), findsOneWidget);
      expect(find.text('https://example.com/a/very/long/path?x=1'), findsOneWidget);
      expect(find.text('Open in browser'), findsOneWidget);
      expect(find.text('Copy link'), findsOneWidget);
    });

    testWidgets('a link target with a bidi override shows as visible characters in the sheet', (tester) async {
      // The engine percent-encodes the override, so the sheet cannot show it raw.
      final session = FakeAgentSession();
      await tester.pumpWidget(
        _app(AgentMdScope(session: session, child: _doc('[click](https://example.com/\u202Egpj.fdp)'))),
      );
      await _tapSpan(tester, 'click');
      await tester.pumpAndSettle();
      expect(find.text('https://example.com/%E2%80%AEgpj.fdp'), findsOneWidget);
    });

    testWidgets('only http and https links are followed', (tester) async {
      final tapped = <String>[];
      await tester.pumpWidget(
        _app(
          MdActions(
            onLink: (context, url) => tapped.add(url),
            onPath: (context, path, line) => tapped.add('path:$path'),
            child: _doc('[a](javascript:alert(1)) [b](mailto:x@y.z) [c](#section) [d](https://ok.dev/x)'),
          ),
        ),
      );
      for (final label in ['a', 'b', 'c']) {
        expect(_recognizerOf(tester, label), isNull, reason: '[$label] is not followed');
      }
      expect(_recognizerOf(tester, 'd'), isNotNull);
      await _tapSpan(tester, 'd');
      expect(tapped, ['https://ok.dev/x']);
    });

    testWidgets('a tapped path reaches the file callback with its line', (tester) async {
      final taps = <(String, int?)>[];
      await tester.pumpWidget(
        _app(
          MdActions(
            onPath: (context, path, line) => taps.add((path, line)),
            child: _doc('Open lib/a.dart:42 and `lib/b.dart` or [the doc](docs/c.md#L12) or plain words.'),
          ),
        ),
      );
      await _tapSpan(tester, 'lib/a.dart:42');
      await _tapSpan(tester, 'lib/b.dart');
      await _tapSpan(tester, 'the doc');
      expect(taps, [('lib/a.dart', 42), ('lib/b.dart', null), ('docs/c.md', 12)]);
    });

    testWidgets('a path in prose is underlined; a path in an inline-code badge is accent only', (tester) async {
      await tester.pumpWidget(
        _app(MdActions(onPath: (context, path, line) {}, child: _doc('Open lib/a.dart:42 and `lib/b.dart` now.'))),
      );
      TextSpan? spanOf(String text) {
        TextSpan? found;
        for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
          rich.text.visitChildren((s) {
            if (s is TextSpan && s.text == text) found = s;
            return true;
          });
        }
        return found;
      }

      final prose = spanOf('lib/a.dart:42')!.style!;
      final badge = spanOf('lib/b.dart')!.style!;
      expect(prose.decoration, TextDecoration.underline);
      expect(badge.decoration, TextDecoration.none, reason: 'the badge is already a mark');
      expect(badge.color, prose.color, reason: 'both still read as tappable');
      expect(badge.backgroundColor, isNotNull, reason: 'it is the badge');
    });

    testWidgets('slash commands, folders, versions and words with a slash stay plain text', (tester) async {
      await tester.pumpWidget(
        _app(
          MdActions(
            onPath: (context, path, line) {},
            child: _doc('Run /model then /compact in src/ (v1.2.3), and/or edit lib/a.dart:9, see `/resume` and `lib/ui/`.'),
          ),
        ),
      );
      final tappable = <String>[];
      for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
        rich.text.visitChildren((s) {
          if (s is TextSpan && s.recognizer != null) tappable.add(s.text ?? '');
          return true;
        });
      }
      expect(tappable, ['lib/a.dart:9']);
    });

    testWidgets('a tapped path goes to the file viewer navigation of the session machine', (tester) async {
      final session = FakeAgentSession();
      await tester.pumpWidget(_app(AgentMdScope(session: session, child: _doc('Look at lib/a.dart:42 please.'))));
      await _tapSpan(tester, 'lib/a.dart:42');
      await tester.pump();
      // The fake machine has no file system: openRemoteFile says so in a toast.
      expect(find.text('Files are not available on this machine.'), findsOneWidget);
    });

    testWidgets('without handlers paths stay plain text', (tester) async {
      await tester.pumpWidget(_app(_doc('Look at lib/a.dart:42 please.')));
      expect(_recognizerOf(tester, 'lib/a.dart:42'), isNull);
    });

    testWidgets('an image is a quiet chip with its host and is never fetched', (tester) async {
      final links = <String>[];
      final paths = <String>[];
      await tester.pumpWidget(
        _app(
          MdActions(
            onLink: (context, url) => links.add(url),
            onPath: (context, path, line) => paths.add(path),
            child: _doc('![diagram](https://img.example.org/a.png?token=abc) and ![local](shots/b.png)'),
          ),
        ),
      );
      expect(find.textContaining('Image: diagram · img.example.org', findRichText: true), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      await _tapSpan(tester, 'Image: diagram · img.example.org');
      await _tapSpan(tester, 'Image: local');
      expect(links, ['https://img.example.org/a.png?token=abc']);
      expect(paths, ['shots/b.png']);
    });

    test('classifyLink', () {
      expect(classifyLink('https://a.b/c').$1, MdLinkKind.web);
      expect(classifyLink('http://localhost:3000/x').$1, MdLinkKind.web);
      expect(classifyLink('lib/a.dart:42').$1, MdLinkKind.path);
      expect(classifyLink('lib/a.dart#L7').$2, (path: 'lib/a.dart', line: 7));
      expect(classifyLink('file:///home/u/a.md').$2?.path, '/home/u/a.md');
      expect(classifyLink('#top').$1, MdLinkKind.none);
      expect(classifyLink('javascript:alert(1)').$1, MdLinkKind.none);
      expect(classifyLink('data:text/html,<b>').$1, MdLinkKind.none);
      expect(classifyLink('//evil.example/x').$1, MdLinkKind.none);
      expect(classifyLink('').$1, MdLinkKind.none);
    });
  });

  group('code', () {
    testWidgets('the copy button copies the raw code and says so briefly', (tester) async {
      _mockClipboard(tester);
      await tester.pumpWidget(_app(_doc('```dart\nfinal a = 1;\n  print(a); // \u202Ex\n```')));
      expect(find.text('dart'), findsOneWidget);
      await tester.tap(find.byIcon(LucideIcons.copy));
      await tester.pump();
      expect(_clipboard, 'final a = 1;\n  print(a); // \u202Ex');
      expect(find.text('Copied'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Copied'), findsNothing);
      expect(find.byIcon(LucideIcons.copy), findsOneWidget);
    });

    testWidgets('bidi overrides and control characters are visible in code', (tester) async {
      await tester.pumpWidget(_app(_doc('```sh\necho hi\u202E\nrm \u001B[31m\n```')));
      final text = _spans(tester, find.byType(RichText)).map((s) => s.$1).join();
      expect(text, contains('\u2039U+202E\u203a'));
      expect(text, contains('\u2039U+001B\u203a'));
      expect(text, isNot(contains('\u202E')));
    });

    testWidgets('a long block shows 60 lines and Show all, driven by the caller', (tester) async {
      var expanded = false;
      final blocks = parseMd('```\n${List.generate(100, (i) => 'line $i').join('\n')}\n```').blocks;
      late StateSetter set;
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, setState) {
              set = setState;
              return MdBlockView(block: blocks.single, expanded: expanded, onToggleExpanded: () => setState(() => expanded = !expanded));
            },
          ),
        ),
      );
      expect(find.textContaining('line 59', findRichText: true), findsOneWidget);
      expect(find.textContaining('line 60\n', findRichText: true), findsNothing);
      expect(find.text('40 more lines'), findsOneWidget);
      await tester.tap(find.text('Show all'));
      await tester.pump();
      expect(find.textContaining('line 99', findRichText: true), findsOneWidget);
      expect(find.text('100 lines'), findsOneWidget);
      set(() => expanded = false);
      await tester.pump();
      expect(find.text('Show all'), findsOneWidget);
    });

    testWidgets('the wrap toggle switches a block between sideways scroll and wrapping', (tester) async {
      _phone(tester, width: 320, height: 640);
      final long = 'x' * 200;
      await tester.pumpWidget(_app(_doc('```\n$long\n```')));
      expect(find.byType(SingleChildScrollView), findsNWidgets(2), reason: 'the page and the code');
      final height = tester.getSize(find.byType(MdCodeBlock)).height;
      await tester.tap(find.bySemanticsLabel('Wrap long lines'));
      await tester.pump();
      expect(tester.getSize(find.byType(MdCodeBlock)).height, greaterThan(height));
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, semanticsEnabled: true);

    testWidgets('code in a streaming tail keeps its open last line plain', (tester) async {
      Future<List<(String, Color?)>> spansOf(String code, {required bool tail}) async {
        final block = parseMd('```dart\n$code\n```').blocks.single;
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(_app(MdBlockView(block: block, tail: tail)));
        return _spans(tester, find.byType(RichText)).where((s) => s.$1.contains('final') || s.$1.contains('class') || s.$1.contains('x')).toList();
      }

      final done = await spansOf('final a = 1;\nclass', tail: false);
      final open = await spansOf('final a = 1;\nclass', tail: true);
      // Complete lines are coloured either way.
      expect(done.any((s) => s.$1 == 'final' && s.$2 != null), isTrue);
      expect(open.any((s) => s.$1 == 'final' && s.$2 != null), isTrue);
      // The last line is a keyword only once it is complete.
      expect(done.any((s) => s.$1 == 'class' && s.$2 != null), isTrue);
      expect(open.any((s) => s.$1 == 'class' && s.$2 != null), isFalse);
      expect(open.any((s) => s.$1.contains('class')), isTrue, reason: 'still drawn, as plain text');
    });

    testWidgets('1000 lines: 60 are drawn, Show all opens a lazy box of 360 dp', (tester) async {
      final source = worstCases()['code1000']!;
      await tester.pumpWidget(_app(_doc(source)));
      expect(find.text('940 more lines'), findsOneWidget);
      await tester.tap(find.text('Show all'));
      await tester.pump();
      expect(find.text('1000 lines'), findsOneWidget);
      expect(find.byType(ListView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('tables', () {
    testWidgets('a 40-column table never overflows at 320 px and scrolls sideways', (tester) async {
      _phone(tester, width: 320, height: 640);
      await tester.pumpWidget(_app(_doc(worstCases()['table40']!)));
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(MdTableView)).width, lessThanOrEqualTo(320));
      final scroll = find.descendant(of: find.byType(MdTableView), matching: find.byType(SingleChildScrollView));
      expect(scroll, findsOneWidget);
      final position = tester.state<ScrollableState>(find.descendant(of: scroll, matching: find.byType(Scrollable))).position;
      expect(position.maxScrollExtent, greaterThan(1000));
      await tester.dragFrom(tester.getTopLeft(scroll) + const Offset(150, 20), const Offset(-300, 0));
      await tester.pump();
      expect(position.pixels, greaterThan(100));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a small table fits and does not scroll', (tester) async {
      _phone(tester, width: 320, height: 640);
      await tester.pumpWidget(_app(_doc('| a | b |\n| - | - |\n| 1 | 2 |')));
      expect(find.descendant(of: find.byType(MdTableView), matching: find.byType(SingleChildScrollView)), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cells wrap, alignment and header weight follow the table', (tester) async {
      _phone(tester, width: 320, height: 640);
      await tester.pumpWidget(
        _app(_doc('| Left | Right |\n| :-- | --: |\n| ${'a very long cell that has to wrap ' * 4} | 7 |')),
      );
      expect(tester.takeException(), isNull);
      RichText cell(String text) => tester.widget<RichText>(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == text));
      expect((cell('Left').text as TextSpan).style!.fontWeight, FontWeight.w600);
      expect(cell('Right').textAlign, TextAlign.right);
      expect(cell('7').textAlign, TextAlign.right);
      expect(cell('Left').textAlign, TextAlign.start);
    });

    testWidgets('past 40 rows it shows 40 and Show all', (tester) async {
      final rows = [for (var i = 1; i <= 55; i++) '| r$i | $i |'].join('\n');
      await tester.pumpWidget(_app(_doc('| a | b |\n| - | - |\n$rows')));
      expect(find.text('15 more rows'), findsOneWidget);
      expect(find.text('r41', findRichText: true), findsNothing);
      await tester.tap(find.text('Show all'));
      await tester.pump();
      expect(find.text('r55', findRichText: true), findsOneWidget);
    });

    testWidgets('a long press offers Markdown and TSV', (tester) async {
      _mockClipboard(tester);
      await tester.pumpWidget(_app(_doc('| Name | N |\n| :-- | --: |\n| a\\|b | 1 |')));
      await tester.longPress(find.byType(MdTableView), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Copy as Markdown'), findsOneWidget);
      await tester.tap(find.text('Copy as Markdown'));
      await tester.pumpAndSettle();
      expect(_clipboard, '| Name | N |\n| :-- | --: |\n| a\\|b | 1 |');
      await tester.longPress(find.byType(MdTableView), warnIfMissed: false);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy as TSV'));
      await tester.pumpAndSettle();
      expect(_clipboard, 'Name\tN\na|b\t1');
    });
  });

  group('selection and semantics', () {
    testWidgets('a selection across two blocks of a lazy list takes the text of both', (tester) async {
      String? selected;
      final blocks = [
        parseMd('First paragraph here.').blocks.single,
        parseMd('- a list item\n- another item').blocks.single,
        parseMd('```\ncode line\n```').blocks.single,
        parseMd('Last paragraph there.').blocks.single,
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SelectionArea(
              onSelectionChanged: (content) => selected = content?.plainText,
              child: ListView.builder(
                itemCount: blocks.length,
                itemBuilder: (context, i) => Padding(padding: const EdgeInsets.only(bottom: 8), child: MdBlockView(block: blocks[i])),
              ),
            ),
          ),
        ),
      );
      final first = find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == 'First paragraph here.');
      final last = find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == 'Last paragraph there.');
      final gesture = await tester.startGesture(tester.getTopLeft(first) + const Offset(2, 10), kind: PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.moveTo(tester.getBottomRight(last) - const Offset(2, 8));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(selected, contains('First paragraph here.'));
      expect(selected, contains('a list item'));
      expect(selected, contains('another item'));
      expect(selected, contains('code line'));
      expect(selected, contains('Last paragraph there.'));
    });

    testWidgets('semantics: headings, code, table and list items', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(_doc('# Title\n\nbody text\n\n- one\n- two\n\n```dart\na\nb\nc\n```\n\n| x | y | z |\n|-|-|-|\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |')));
      expect(tester.getSemantics(find.text('Title', findRichText: true)), matchesSemantics(label: 'Title', isHeader: true, textDirection: TextDirection.ltr));
      expect(find.bySemanticsLabel('body text'), findsOneWidget);
      expect(find.bySemanticsLabel('one'), findsOneWidget);
      expect(find.bySemanticsLabel('Code, dart, 3 lines'), findsOneWidget);
      expect(find.bySemanticsLabel('Table, 3 columns, 3 rows'), findsOneWidget);
      expect(find.bySemanticsLabel('Copy code'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a link is a tappable semantics node', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(MdActions(onLink: (c, u) {}, child: _doc('go to [the docs](https://a.dev) now'))));
      final nodes = <SemanticsNode>[];
      void walk(SemanticsNode n) {
        nodes.add(n);
        n.visitChildren((c) {
          walk(c);
          return true;
        });
      }

      walk(tester.getSemantics(find.byType(Scaffold)));
      final link = nodes.where((n) => n.label.contains('the docs') && n.getSemanticsData().hasAction(SemanticsAction.tap));
      expect(link, isNotEmpty);
      handle.dispose();
    });

    testWidgets('the open tail makes no semantics noise; a frozen block does', (tester) async {
      final handle = tester.ensureSemantics();
      final block = parseMd('hello streaming world').blocks.single;
      await tester.pumpWidget(_app(MdBlockView(block: block, tail: true)));
      expect(find.bySemanticsLabel('hello streaming world'), findsNothing);
      await tester.pumpWidget(_app(MdBlockView(block: block)));
      expect(find.bySemanticsLabel('hello streaming world'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('RTL paragraphs lay out right to left', (tester) async {
      await tester.pumpWidget(_app(_doc('مرحبا بالعالم\n\nhello')));
      final texts = tester.widgetList<RichText>(find.byType(RichText)).toList();
      expect(texts.first.textDirection, TextDirection.rtl);
      expect(texts.last.textDirection, isNot(TextDirection.rtl));
    });
  });

  group('text safety', () {
    test('proseText removes the overrides and keeps the marks', () {
      expect(proseText('a\u202Eb\u202Cc\u2066d\u2069'), 'abcd');
      expect(proseText('a\u200Fb'), 'a\u200Fb');
      const clean = 'nothing to remove';
      expect(identical(proseText(clean), clean), isTrue);
    });

    test('mdIsRtl reads the first strong character', () {
      expect(mdIsRtl('hello'), isFalse);
      expect(mdIsRtl('مرحبا'), isTrue);
      expect(mdIsRtl('123 שלום'), isTrue);
      expect(mdIsRtl('Hà Nội'), isFalse);
      expect(mdIsRtl('... :) hello مرحبا'), isFalse);
    });

    testWidgets('inline code and prose never show an override', (tester) async {
      await tester.pumpWidget(_app(_doc('prose \u202Ereversed and `code\u202Ehere`')));
      final text = _spans(tester, find.byType(RichText)).map((s) => s.$1).join();
      expect(text, contains('code\u2039U+202E\u203ahere'));
      expect(text, isNot(contains('\u202E')));
    });
  });

  group('file viewer markdown', () {
    TextDocument docOf(String text) {
      final doc = TextDocument()..append(Uint8List.fromList(text.codeUnits), last: true);
      return doc;
    }

    testWidgets('a README keeps CommonMark soft breaks (a newline is a space)', (tester) async {
      await tester.pumpWidget(
        _app(SizedBox(height: 400, child: MarkdownView(document: docOf('# herdr mobile\n\nline one\nline two\n\n- a\n- b')))),
      );
      expect(find.textContaining('line one line two', findRichText: true), findsOneWidget);
      expect(find.textContaining('line one\nline two', findRichText: true), findsNothing);
      expect(find.text('herdr mobile', findRichText: true), findsOneWidget);
    });

    testWidgets('a link in a README opens the link sheet', (tester) async {
      await tester.pumpWidget(_app(SizedBox(height: 400, child: MarkdownView(document: docOf('see [the site](https://example.com/x)')))));
      await _tapSpan(tester, 'the site');
      await tester.pumpAndSettle();
      expect(find.text('https://example.com/x'), findsOneWidget);
    });
  });

  group('rows', () {
    testWidgets('on a wide screen text keeps a reading width and code uses all of it', (tester) async {
      _phone(tester, width: 1200, height: 900);
      await tester.pumpWidget(
        _app(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MdBlockView(block: parseMd('A long paragraph of words. ' * 40).blocks.single),
              MdBlockView(block: parseMd('- a list item that also is long. ' * 30).blocks.single),
              MdBlockView(block: parseMd('```\ncode\n```').blocks.single),
            ],
          ),
        ),
      );
      final width = tester.getSize(find.byType(Scaffold)).width - 32;
      final paragraph = find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().startsWith('A long paragraph'));
      expect(tester.getSize(paragraph).width, lessThanOrEqualTo(560));
      expect(tester.getSize(paragraph).width, greaterThan(500));
      expect(tester.getSize(find.byType(MdCodeBlock)).width, width);
    });

    testWidgets('AgentTextRow draws a block and passes Show all through with its key; ThinkingRow reads Markdown', (tester) async {
      final toggled = <String>[];
      final code = parseMd('```\n${List.generate(80, (i) => 'l$i').join('\n')}\n```').blocks.single;
      await tester.pumpWidget(
        _app(
          AgentTextRow(rowKey: 'm#3', block: code, gap: 10, expanded: false, onToggle: toggled.add),
        ),
      );
      await tester.tap(find.text('Show all'));
      expect(toggled, [allKey('m#3')]);

      final message = TranscriptMessage(key: 't', role: MessageRole.thought, blocks: const [TextBlock('**Plan:** read `lib/a.dart`')]);
      await tester.pumpWidget(
        _app(ThinkingRow(rowKey: 't', thoughts: [message], gap: 0, open: true, onToggle: (_) {})),
      );
      final spans = _spans(tester, find.byType(RichText)).map((s) => s.$1);
      expect(spans, containsAll(['Plan:', 'lib/a.dart']));
      expect(spans.join(), isNot(contains('**')));
    });

    testWidgets('the worst cases build without an error at 320 px and 160% text', (tester) async {
      _phone(tester, width: 320, height: 640);
      for (final entry in worstCases().entries) {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)), child: child!),
            home: Scaffold(body: SingleChildScrollView(child: _doc(entry.value))),
          ),
        );
        expect(tester.takeException(), isNull, reason: entry.key);
      }
    });
  });
}
