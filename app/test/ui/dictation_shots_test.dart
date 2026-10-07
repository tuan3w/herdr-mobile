// Renders the session composer with the mic and the learned chips to PNGs for
// review: idle (chips lead with what was sent most, a long Vietnamese one among
// them), listening (Vietnamese words arriving), and stopped with the words in the box
// (Send is back). Light and dark at 412x892, 320x640 at 1.6 text scale, and
// 892x412 with the keyboard up (the compact layout). Off by default; it writes
// files:
//
//   DICTATION_SHOTS=1 flutter test test/ui/dictation_shots_test.dart
//
// Output: $DICTATION_SHOTS_DIR (default /tmp/dictation_shots)/<case>-<light|dark>-<w>x<h>[-x1.6].png
@TestOn('vm')
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/quick_phrases.dart';
import 'package:herdr_mobile/data/repositories/sent_phrases.dart';
import 'package:herdr_mobile/data/services/dictation.dart';
import 'package:herdr_mobile/ui/core/tap_guard.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../support/fake_agent_session.dart';
import '../support/fake_dictation.dart';
import '../support/memory_quick_phrases_store.dart';
import '../support/memory_sent_phrases_store.dart';
import '../support/shot.dart' show loadAppFonts;

const _long = 'Sửa lỗi phân tích địa danh Hà Nội rồi chạy lại toàn bộ các bài kiểm tra nhé';

void main() {
  if (Platform.environment['DICTATION_SHOTS'] == null) {
    test('dictation shots are off (set DICTATION_SHOTS=1)', () {}, skip: 'set DICTATION_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['DICTATION_SHOTS_DIR'] ?? '/tmp/dictation_shots';

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  Future<void> shoot(
    WidgetTester tester,
    String name,
    Size size,
    Brightness brightness, {
    double scale = 1,
    double keyboard = 0,
    bool listen = false,
    bool stop = false,
  }) async {
    const dpr = 2.625;
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    tester.view.padding = const FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr);
    tester.view.viewPadding = tester.view.padding;
    if (keyboard > 0) tester.view.viewInsets = FakeViewPadding(bottom: keyboard * dpr);
    addTearDown(tester.view.reset);

    final session = FakeAgentSession(
      state: stateWith(items: [userMsg('u1', 'Fix the Hà Nội locale bug'), agentMsg('a1', 'Done. Want me to run the tests?')]),
    );
    final engine = FakeEngine();
    final dictation = Dictation(engine, MemoryDictationStore());
    await dictation.load();
    final phrases = QuickPhrases(MemoryQuickPhrasesStore());
    await phrases.load();
    final sent = SentPhrases(MemorySentPhrasesStore());
    await sent.load();
    for (final m in ['continue', _long, 'create pr']) {
      await sent.learn(m);
      await sent.learn(m);
    }
    final key = GlobalKey();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<Dictation>.value(value: dictation),
          ChangeNotifierProvider<QuickPhrases>.value(value: phrases),
          ChangeNotifierProvider<SentPhrases>.value(value: sent),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: RepaintBoundary(key: key, child: child!),
          ),
          home: AgentSessionScreen(key: ObjectKey(session), session: session),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(tapGuard);
    // Focus the field the way a finger does: the chips show while it is focused.
    await tester.tap(find.byType(TextField).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    if (listen) {
      await tester.tap(find.byIcon(LucideIcons.mic));
      await tester.pump();
      engine.hear('sửa lỗi dấu tiếng Việt trong ô nhập rồi chạy lại các bài kiểm tra');
      await tester.pump(const Duration(milliseconds: 300));
      // The box scrolls to the new words after the frame that laid them out;
      // one more frame paints it, as it does on a phone.
      await tester.pump();
    }
    if (stop) {
      await tester.tap(find.byIcon(LucideIcons.mic));
      await tester.pump(const Duration(milliseconds: 300));
    }
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final tag = '${size.width.toInt()}x${size.height.toInt()}${scale == 1 ? '' : '-x$scale'}';
      await File('$out/$name-${brightness.name}-$tag.png').writeAsBytes(data!.buffer.asUint8List());
    });
    expect(tester.takeException(), isNull, reason: '$name ${brightness.name} $size');
  }

  const sizes = [
    (Size(412, 892), 1.0, 0.0),
    (Size(320, 640), 1.6, 0.0),
    (Size(892, 412), 1.0, 220.0),
  ];
  for (final (size, scale, keyboard) in sizes) {
    for (final brightness in Brightness.values) {
      testWidgets('idle ${brightness.name} ${size.width}', (tester) async {
        await shoot(tester, 'idle', size, brightness, scale: scale, keyboard: keyboard);
      });
      testWidgets('listening ${brightness.name} ${size.width}', (tester) async {
        await shoot(tester, 'listening', size, brightness, scale: scale, keyboard: keyboard, listen: true);
      });
      testWidgets('stopped ${brightness.name} ${size.width}', (tester) async {
        await shoot(tester, 'stopped', size, brightness, scale: scale, keyboard: keyboard, listen: true, stop: true);
      });
    }
  }
}
