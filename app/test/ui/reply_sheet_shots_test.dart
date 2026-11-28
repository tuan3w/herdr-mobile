// Renders the board's reply sheet to PNGs for review: a question with its
// answers, and an agent that waits with no question read (the terminal's end
// and the keys). Light and dark at 412x892, and 320x640 at text scale 1.6. Off
// by default; it writes files:
//
//   REPLY_SHOTS=1 flutter test test/ui/reply_sheet_shots_test.dart
//
// Output: $REPLY_SHOTS_DIR (default /dev/shm/reply_shots)/<tag>-<case>-<light|dark>-<w>x<h>[-x1.6].png,
// tag from REPLY_SHOTS_TAG (`before` or `after`).
@TestOn('vm')
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/pane_preview.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../support/shot.dart' show loadAppFonts;
import 'board_support.dart';
import 'ui_harness.dart';

const _prompt = PromptInfo(
  question: 'Do you want to proceed?',
  subject: 'rm -rf build && flutter build apk --release --split-per-abi',
  replies: [
    QuickReply(label: '1. Yes', keys: ['1', 'enter']),
    QuickReply(label: '2. No', keys: ['2', 'enter']),
  ],
);

void main() {
  if (Platform.environment['REPLY_SHOTS'] == null) {
    test('reply sheet shots are off (set REPLY_SHOTS=1)', () {}, skip: 'set REPLY_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['REPLY_SHOTS_DIR'] ?? '/dev/shm/reply_shots';
  final tag = Platform.environment['REPLY_SHOTS_TAG'] ?? 'after';
  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  for (final (brightness, size, scale) in [
    (Brightness.light, const Size(412, 892), 1.0),
    (Brightness.dark, const Size(412, 892), 1.0),
    (Brightness.light, const Size(320, 640), 1.6),
  ]) {
    for (final (name, prompt) in [('question', _prompt), ('no-question', null)]) {
      final suffix = '${brightness.name}-${size.width.round()}x${size.height.round()}${scale == 1 ? '' : '-x$scale'}';
      testWidgets('$name: $suffix', (tester) async {
        const dpr = 2.625;
        tester.view.physicalSize = size * dpr;
        tester.view.devicePixelRatio = dpr;
        tester.view.padding = const FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr);
        tester.view.viewPadding = tester.view.padding;
        addTearDown(tester.view.reset);
        final h = await BoardHarness.create([
          (
            profile: const MachineProfile(id: 'a', label: 'studio-mac', host: 'a.example', username: 'dev'),
            snapshot: snapshotWith([
              (id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'blocked'),
            ], title: (_) => 'Release build for payments-api'),
          ),
        ]);
        h.previews.set('a/w1:p1', const [
          '\$ flutter build apk',
          'Running Gradle task assembleRelease…',
        ], prompt: prompt);
        final key = GlobalKey();
        await tester.pumpWidget(
          MultiProvider(
            providers: h.providers,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.light(),
              darkTheme: AppTheme.dark(),
              themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
              navigatorObservers: [ToastRouteObserver()],
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(key: key, child: child!),
              ),
              home: const HomeShell(),
            ),
          ),
        );
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.tap(replyTo('Release build for payments-api'));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('$out/$tag-$name-$suffix.png').writeAsBytes(data!.buffer.asUint8List());
        });
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 5));
        await teardownBoard(tester, h);
      });
    }
  }
}
