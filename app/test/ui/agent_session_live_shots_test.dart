// Renders the transcript in the middle of a stream to PNGs for review (light
// and dark, 412x892 and 320x640): the open tail healed (`**bo`), an open code
// fence, a table that is half there, the `N new` pill, and `Working · 12s`.
// Off by default; it writes files:
//
//   CHAT_SHOTS=1 flutter test test/ui/agent_session_live_shots_test.dart
//
// Output: $CHAT_SHOTS_DIR (default /tmp/chat_shots)/<case>-<light|dark>-<w>x<h>.png
@TestOn('vm')
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_view.dart';
import 'package:herdr_mobile/ui/features/agent_session/status_line.dart';

import '../support/fake_agent_session.dart';
import '../support/shot.dart' show loadAppFonts;

const _intro =
    'I read the parser and the cause is in `normalize()`: it **lowercases** before it strips the marks, so '
    '`Hà Nội` loses its tone marks (see `lib/feature/parse.dart:42`).\n\n'
    'The plan:\n\n- move the call below `normalize()`\n- add a regression test for `Hà Nội`\n\n';

const _cases = <String, String>{
  'bold': '${_intro}Then I run the suite and check that **bo',
  'fence': '${_intro}The fix is small:\n\n```dart\nString fold(String s) {\n  final t = normalize(s);\n  return t.toLo',
  'table': '${_intro}Results so far:\n\n| file | tests |\n| --- | ---: |\n| parse_test.dart | 12 |\n| fold_te',
};

void main() {
  if (Platform.environment['CHAT_SHOTS'] == null) {
    test('chat shots are off (set CHAT_SHOTS=1)', () {}, skip: 'set CHAT_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['CHAT_SHOTS_DIR'] ?? '/tmp/chat_shots';

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });
  tearDown(() => statusNow = DateTime.now);

  Future<void> shoot(
    WidgetTester tester,
    String name,
    FakeAgentSession session,
    Size size,
    Brightness brightness, {
    Future<void> Function()? then,
  }) async {
    const dpr = 2.625;
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    tester.view.padding = const FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr);
    tester.view.viewPadding = tester.view.padding;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        builder: (context, child) => RepaintBoundary(key: key, child: child!),
        home: AgentSessionScreen(key: ObjectKey(session), session: session),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await then?.call();
    await tester.pump(const Duration(milliseconds: 600));
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final tag = '${size.width.toInt()}x${size.height.toInt()}';
      await File('$out/$name-${brightness.name}-$tag.png').writeAsBytes(data!.buffer.asUint8List());
    });
    expect(tester.takeException(), isNull, reason: '$name ${brightness.name} $size');
  }

  FakeAgentSession streamingSession(String text, {int history = 0}) {
    final start = DateTime(2026, 10, 5, 12);
    statusNow = () => start.add(const Duration(seconds: 12));
    return FakeAgentSession(
      state: stateWith(
        items: [
          for (var i = 0; i < history; i++) ...[
            userMsg('hu$i', 'Earlier question $i'),
            agentMsg('h$i', 'Earlier message $i: the build passed and the tests ran.'),
          ],
          userMsg('u1', 'Fix the Hà Nội locale bug in the parser and add a test.'),
          toolItem('t1', title: 'Read lib/feature/parse.dart', kind: ToolKind.read),
          toolItem('t2', title: 'flutter test test/parse_test.dart', kind: ToolKind.execute),
        ],
        turnActive: true,
      ).apply(MessageChunk(MessageRole.agent, 'a1', TextBlock(text))),
    )..turnStart = start;
  }

  for (final brightness in Brightness.values) {
    for (final size in const [Size(412, 892), Size(320, 640)]) {
      final tag = '${brightness.name} ${size.width.toInt()}';
      for (final entry in _cases.entries) {
        testWidgets('${entry.key} $tag', (tester) async {
          await shoot(tester, entry.key, streamingSession(entry.value), size, brightness);
        });
      }

      testWidgets('pill $tag', (tester) async {
        final session = streamingSession('${_intro}Next I look at the callers.', history: 30);
        await shoot(
          tester,
          'pill',
          session,
          size,
          brightness,
          then: () async {
            await tester.drag(find.byType(TranscriptView), const Offset(0, 420));
            await tester.pump(const Duration(milliseconds: 100));
            session.apply(const MessageChunk(MessageRole.agent, 'a1', TextBlock('\n\nThere are three of them.\n\n- `a.dart`\n- `b.dart`\n\nI start with the first')));
            for (var i = 0; i < 40; i++) {
              await tester.pump(const Duration(milliseconds: 40));
            }
          },
        );
      });
    }
  }
}
