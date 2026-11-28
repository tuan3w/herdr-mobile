// Renders the board while a machine drops and the connection strip opens
// above the list (and again when it recovers), at the frames that matter: at
// rest, the first frame after the drop, half way, settled. Light and dark at
// 412x892, and 320x640 at text scale 1.6. Off by default; it writes files:
//
//   STRIP_SHOTS=1 flutter test test/ui/board_strip_shots_test.dart
//
// Output: $STRIP_SHOTS_DIR (default /dev/shm/board_strip_shots)/<name>-<light|dark>-<w>x<h>[-x1.6].png,
// name = `<tag><frame>`, tag from STRIP_SHOTS_TAG (`before` or `after`).
@TestOn('vm')
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../support/shot.dart' show loadAppFonts;
import 'board_support.dart';
import 'ui_harness.dart';

Pane _pane(int i, String status) => (id: 'w1:p$i', ws: 'w1', agent: 'claude', status: status);

void main() {
  if (Platform.environment['STRIP_SHOTS'] == null) {
    test('strip shots are off (set STRIP_SHOTS=1)', () {}, skip: 'set STRIP_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['STRIP_SHOTS_DIR'] ?? '/dev/shm/board_strip_shots';
  final tag = Platform.environment['STRIP_SHOTS_TAG'] ?? 'after';
  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  for (final (brightness, size, scale) in [
    (Brightness.light, const Size(412, 892), 1.0),
    (Brightness.dark, const Size(412, 892), 1.0),
    (Brightness.light, const Size(320, 640), 1.6),
  ]) {
    final suffix = '${brightness.name}-${size.width.round()}x${size.height.round()}${scale == 1 ? '' : '-x$scale'}';
    testWidgets('a machine drops under the board: $suffix', (tester) async {
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
            _pane(1, 'working'),
            _pane(2, 'working'),
            _pane(3, 'idle'),
            _pane(4, 'idle'),
          ], title: (id) => 'task ${id.split('p').last}: tidy the payments retries'),
        ),
      ]);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
          navigatorObservers: [ToastRouteObserver()],
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: RepaintBoundary(key: key, child: child!),
          ),
          home: _Board(h: h),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      Future<void> snap(String frame) async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('$out/$tag-$frame-$suffix.png').writeAsBytes(data!.buffer.asUint8List());
        });
      }

      await snap('1-rest');
      h.transports['a']!.failure = HerdrTransportException('Host key changed', fatal: true);
      h.fleet.connections.first.reconnect();
      // The drop reaches the board on the first frames; then one frame, half
      // the strip's opening, and the settled board.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await snap('2-first-frame');
      await tester.pump(const Duration(milliseconds: 100));
      await snap('3-mid');
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await snap('4-settled');
      expect(tester.takeException(), isNull);
      await teardownBoard(tester, h);
    });
  }
}

/// The board under the harness's providers.
class _Board extends StatelessWidget {
  const _Board({required this.h});

  final BoardHarness h;

  @override
  Widget build(BuildContext context) => MultiProvider(providers: h.providers, child: const HomeShell());
}
