// Renders a blocked board card to PNGs for review (light and dark, 412x892
// and 320x640, text scale 1 and 1.6), with prompts captured from real agents:
// claude's "don't ask again" with auto mode (a standing grant behind more),
// codex's command approval, and a plain yes/no. Off by default; it writes
// files:
//
//   CARD_SHOTS=1 flutter test test/ui/decision_card_shots_test.dart
//
// Output: $CARD_SHOTS_DIR (default /tmp/card_shots)/<case>-<light|dark>-<w>x<h>-x<scale>.png
@TestOn('vm')
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/pane_preview.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/repositories/prompt_detector.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../support/shot.dart' show loadAppFonts;
import 'board_support.dart';
import 'ui_harness.dart';

PromptInfo _captured(String name) {
  final rows = File('test/fixtures/prompts/$name.txt').readAsLinesSync();
  final screen = rows.skipWhile((r) => RegExp(r'^# [a-z_]+:').hasMatch(r)).join('\n');
  return detectPrompt(previewRows(screen, keep: 24))!;
}

void main() {
  if (Platform.environment['CARD_SHOTS'] == null) {
    test('decision card shots are off (set CARD_SHOTS=1)', () {}, skip: 'set CARD_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['CARD_SHOTS_DIR'] ?? '/tmp/card_shots';

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  final cases = <String, PromptInfo Function()>{
    'claude-dontask': () => _captured('claude/approvalfull-bash-multiline-dontask'),
    'codex-command': () => _captured('codex/approval-command'),
    'yes-no': () => const PromptInfo(
      question: 'Do you want to proceed?',
      subject: 'git push --force-with-lease origin feat/home-calm',
      replies: [
        QuickReply(label: '1. Yes', keys: ['1', 'enter'], needsConfirm: true, risk: 'pushes to a remote'),
        QuickReply(label: '2. No, and tell Claude what to do differently (esc)', keys: ['2', 'enter']),
      ],
    ),
  };

  const sizes = [Size(412, 892), Size(320, 640)];
  const scales = [1.0, 1.6];

  for (final MapEntry(key: name, value: prompt) in cases.entries) {
    for (final brightness in Brightness.values) {
      for (final size in sizes) {
        for (final scale in scales) {
          testWidgets('$name ${brightness.name} $size x$scale', (tester) async {
            final h = await BoardHarness.create([
              (
                profile: const MachineProfile(id: 'a', label: 'studio-mac', host: 'a.example', username: 'dev'),
                snapshot: snapshotWith([
                  (id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'blocked'),
                  (id: 'w1:p2', ws: 'w1', agent: 'codex', status: 'working'),
                ], title: (id) => id.endsWith('1') ? 'payments-api' : 'web-client'),
              ),
            ]);
            h.previews.set('a/w1:p1', ['…'], prompt: prompt());
            h.previews.set('a/w1:p2', ['reading schema.sql', 'running tests']);
            const dpr = 2.625;
            tester.view.physicalSize = size * dpr;
            tester.view.devicePixelRatio = dpr;
            tester.view.padding = const FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr);
            tester.view.viewPadding = tester.view.padding;
            addTearDown(tester.view.reset);
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
            for (var i = 0; i < 12; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
              final data = await image.toByteData(format: ui.ImageByteFormat.png);
              final tag = '${size.width.toInt()}x${size.height.toInt()}-x$scale';
              await File('$out/$name-${brightness.name}-$tag.png').writeAsBytes(data!.buffer.asUint8List());
            });
            expect(tester.takeException(), isNull);
            await teardownBoard(tester, h);
          });
        }
      }
    }
  }
}
