// Renders the dock's question form after a failed Accept, the session overview's
// `N more` row and the copy button's cross-fade to PNGs for review (light and
// dark, 412x892; the form also at 320x640 and 1.6 text). Off by default; it
// writes files:
//
//   SESSION_FIX_SHOTS=1 flutter test test/ui/session_fixes_shots_test.dart
//
// Output: $SESSION_FIX_SHOTS_DIR (default /dev/shm/session_fix_shots)/<case>-<light|dark>-<w>x<h>[-x1.6].png
@TestOn('vm')
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_overview.dart';
import 'package:herdr_mobile/ui/render/markdown/markdown.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/fake_agent_session.dart';
import '../support/shot.dart' show loadAppFonts;
import '../support/turn_fixtures.dart';

void main() {
  if (Platform.environment['SESSION_FIX_SHOTS'] == null) {
    test('session fix shots are off (set SESSION_FIX_SHOTS=1)', () {}, skip: 'set SESSION_FIX_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['SESSION_FIX_SHOTS_DIR'] ?? '/dev/shm/session_fix_shots';

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  Future<void> capture(
    WidgetTester tester,
    GlobalKey key,
    String name,
    Brightness brightness,
    Size size,
    double scale,
  ) async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final tag = '${size.width.toInt()}x${size.height.toInt()}${scale == 1 ? '' : '-x$scale'}';
      await File('$out/$name-${brightness.name}-$tag.png').writeAsBytes(data!.buffer.asUint8List());
    });
  }

  Future<GlobalKey> pump(WidgetTester tester, Widget home, Brightness brightness, Size size, double scale) async {
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
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: RepaintBoundary(key: key, child: child!),
        ),
        home: home,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    return key;
  }

  // A failed Accept on a form with a text field and a required choice.
  final form = ElicitationRequest.parse({
    'mode': 'form',
    'message': 'Which environment should I deploy to?',
    'requestedSchema': {
      'type': 'object',
      'required': ['name', 'env'],
      'properties': {
        'name': {'type': 'string', 'title': 'Release name', 'maxLength': 40},
        'env': {
          'type': 'string',
          'title': 'Environment',
          'enum': ['staging', 'production'],
        },
      },
    },
  });

  for (final brightness in Brightness.values) {
    for (final (size, scale) in const [(Size(412, 892), 1.0), (Size(320, 640), 1.6)]) {
      testWidgets('question-error ${brightness.name} ${size.width.toInt()} x$scale', (tester) async {
        final session = FakeAgentSession(
          state: stateWith(
            items: [userAt('u', 'Deploy it.', 0), agentAt('a', 'I need two answers before I deploy.', 2)],
            turnActive: true,
            pending: [PendingQuestion(9, form)],
          ),
        );
        final key = await pump(
          tester,
          AgentSessionScreen(key: ObjectKey(session), session: session),
          brightness,
          size,
          scale,
        );
        await tester.pump(Dwell.tapGuard);
        // Before the failed Accept: the fields are where they will stay.
        await capture(tester, key, 'question-rest', brightness, size, scale);
        await tester.tap(find.text('Accept'));
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(find.text('Required'), findsNWidgets(2), reason: 'both fields name what is missing');
        await capture(tester, key, 'question-error', brightness, size, scale);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('overview-more ${brightness.name}', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(
          items: [
            userAt('u', 'Rename everything', 0),
            for (var i = 0; i < 40; i++) editAt('e$i', '/home/dev/app/lib/feature/file_$i.dart', 10 + i),
          ],
        ),
      );
      final key = await pump(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: GestureDetector(onTap: () => showSessionOverview(context, session), child: const Text('open')),
          ),
        ),
        brightness,
        const Size(412, 892),
        1,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.drag(find.text('Session overview'), const Offset(0, -600));
      await tester.pumpAndSettle();
      await capture(tester, key, 'overview-more', brightness, const Size(412, 892), 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('copy-swap ${brightness.name}', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final block = parseMd('```dart\nString parse(String s) => fold(normalize(s));\n```').blocks.single;
      const size = Size(412, 160);
      final key = await pump(
        tester,
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Align(
              alignment: Alignment.topCenter,
              child: MdBlockView(block: block),
            ),
          ),
        ),
        brightness,
        size,
        1,
      );
      await capture(tester, key, 'copy-swap-rest', brightness, size, 1);
      await tester.tap(find.byIcon(LucideIcons.copy));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      // Mid-transition: the copy glyph fading out over the check fading in.
      await tester.pump(const Duration(milliseconds: 60));
      await capture(tester, key, 'copy-swap-mid', brightness, size, 1);
      await tester.pump(Motion.standard * 2);
      await capture(tester, key, 'copy-swap-done', brightness, size, 1);
      await tester.pump(Dwell.copied);
      await tester.pump(Motion.standard * 2);
    });
  }
}
