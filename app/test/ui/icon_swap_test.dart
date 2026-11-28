import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/render/markdown/markdown.dart';
import 'package:herdr_mobile/ui/render/mermaid/mermaid_cache.dart';
import 'package:herdr_mobile/ui/render/mermaid/mermaid_layout.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// A control whose icon says its state (copy, then check) changes it with one
// cross-fade, not a jump: while it runs both glyphs are on screen, and when it
// is over only the new one is. Under reduced motion it is replaced at once.

Widget _app(Widget body, {bool reduced = false}) => MaterialApp(
  theme: AppTheme.light(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
    child: child!,
  ),
  home: Scaffold(
    body: Align(alignment: Alignment.topLeft, child: body),
  ),
);

class _Swapper extends StatefulWidget {
  const _Swapper();

  @override
  State<_Swapper> createState() => _SwapperState();
}

class _SwapperState extends State<_Swapper> {
  bool done = false;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => setState(() => done = !done),
    child: IconSwap(icon: done ? LucideIcons.check : LucideIcons.copy, size: 20, color: Colors.black),
  );
}

void _mockClipboard(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
}

final _copy = find.byIcon(LucideIcons.copy);
final _check = find.byIcon(LucideIcons.check);

void main() {
  group('IconSwap', () {
    testWidgets('both glyphs are on screen while it runs, and only the new one when it is over', (tester) async {
      await tester.pumpWidget(_app(const _Swapper()));
      expect(_copy, findsOneWidget);
      expect(_check, findsNothing);

      await tester.tap(find.byType(_Swapper));
      await tester.pump();
      await tester.pump(Motion.standard ~/ 2);
      expect(_copy, findsOneWidget, reason: 'the old glyph is still leaving');
      expect(_check, findsOneWidget, reason: 'the new glyph is arriving');

      await tester.pump(Motion.standard);
      expect(_copy, findsNothing);
      expect(_check, findsOneWidget);
    });

    testWidgets('the arriving glyph grows from slightly smaller and fades in', (tester) async {
      await tester.pumpWidget(_app(const _Swapper()));
      await tester.tap(find.byType(_Swapper));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final scale = tester.widget<ScaleTransition>(find.ancestor(of: _check, matching: find.byType(ScaleTransition)));
      final fade = tester.widget<FadeTransition>(find.ancestor(of: _check, matching: find.byType(FadeTransition)));
      expect(scale.scale.value, inInclusiveRange(0.9, 1));
      expect(fade.opacity.value, lessThan(1));
    });

    testWidgets('under reduced motion the glyph is replaced at once', (tester) async {
      await tester.pumpWidget(_app(const _Swapper(), reduced: true));
      await tester.tap(find.byType(_Swapper));
      await tester.pump();
      expect(_copy, findsNothing);
      expect(_check, findsOneWidget);
    });
  });

  group('its two callers', () {
    Future<void> copyAndLook(WidgetTester tester, Finder button, {required String semantics}) async {
      _mockClipboard(tester);
      await tester.tap(button);
      // The clipboard write is awaited before the button says Copied.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(_check, findsOneWidget, reason: '$semantics: the check arrives');
      expect(_copy, findsOneWidget, reason: '$semantics: the copy glyph is still leaving');
      await tester.pump(Motion.standard * 2);
      expect(_copy, findsNothing);
      expect(_check, findsOneWidget);
      // Let the "copied" window run out so no timer is left behind.
      await tester.pump(Dwell.copied);
      await tester.pump(Motion.standard * 2);
      expect(_copy, findsOneWidget, reason: '$semantics: and it goes back');
    }

    testWidgets('a code block cross-fades copy into check', (tester) async {
      final block = parseMd('```dart\nvoid main() {}\n```').blocks.single;
      await tester.pumpWidget(_app(SizedBox(width: 328, child: MdBlockView(block: block))));
      await copyAndLook(tester, _copy, semantics: 'code block');
    });

    testWidgets('a diagram cross-fades copy into check', (tester) async {
      MermaidCache.shared = MermaidCache((job) async => layoutMermaid(job));
      final block = parseMd('```mermaid\nflowchart TD\n A --> B\n```').blocks.single;
      await tester.pumpWidget(_app(SizedBox(width: 328, child: MdBlockView(block: block))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await copyAndLook(tester, _copy, semantics: 'diagram');
    });
  });
}
