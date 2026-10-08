// Opening a file from the chat: the page pushed at once (waiting) is swapped for
// the viewer in a short cross-fade. Faded over nothing, each page is see-through
// for a moment and shows what is under the route: the chat, shifted by the
// slide, and the dark backdrop where it left a gap on the right.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/files/files_navigation.dart';

import '../support/fake_fs.dart';
import '../support/files_support.dart';

void main() {
  for (final brightness in [Brightness.light, Brightness.dark]) {
    for (final latency in [150, 260, 330]) {
      testWidgets(
        'nothing under the route shows through while the waiting page gives way to the viewer '
        '(${brightness.name}, the host answers in $latency ms)',
        (tester) async {
          const dpr = 2.0;
          tester.view
            ..physicalSize = const Size(360, 740) * dpr
            ..devicePixelRatio = dpr;
          addTearDown(tester.view.reset);

          final fs = FakeFs()
            ..mkdirs('/home/dev/app')
            ..latency = Duration(milliseconds: latency)
            ..addFile('/home/dev/app/main.dart', 'void main() {}\n', modified: DateTime.utc(2026, 5, 20));
          final machine = machineWithFiles(fs);
          final key = GlobalKey();
          late BuildContext home;
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.light(),
              darkTheme: AppTheme.dark(),
              themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
              builder: (context, child) => RepaintBoundary(key: key, child: child!),
              // A page nothing like the viewer: a loud colour that must never be
              // seen once the viewer's route is up.
              home: Scaffold(
                backgroundColor: const Color(0xFFFF00FF),
                body: Builder(
                  builder: (c) {
                    home = c;
                    return const SizedBox.expand();
                  },
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));

          // The colour at ([x], [y]) of what is on screen, as 0xRRGGBB.
          Future<int> colourAt(int x, int y) async {
            final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
            late ByteData data;
            late int width;
            await tester.runAsync(() async {
              final ui.Image image = await boundary.toImage();
              width = image.width;
              data = (await image.toByteData())!;
            });
            final i = (y * width + x) * 4;
            return (data.getUint8(i) << 16) | (data.getUint8(i + 1) << 8) | data.getUint8(i + 2);
          }

          openRemoteFile(home, machine, '/home/dev/app/main.dart');
          await tester.pump(); // the route's animation starts with its first frame
          // The slide takes 260 ms (the chat is shifted and leaves a gap on the
          // right while it runs, which is the slide's own business). After it
          // the route is all there is on screen, and a point on the right, where
          // both pages are empty, keeps the page colour in every frame until the
          // cross-fade has ended (the host is asked a few times, so that is some
          // time after [latency]). Faded over nothing, the pages dim it for a
          // moment.
          final seen = <int, int>{};
          await tester.pump(const Duration(milliseconds: 300));
          for (var ms = 300; ms <= 1500; ms += 20) {
            seen[ms] = await colourAt(350, 300);
            await tester.pump(const Duration(milliseconds: 20));
          }
          await tester.pump(const Duration(seconds: 2));
          final page = await colourAt(350, 300);
          expect(
            [for (final e in seen.entries) if (e.value != page) e.key],
            isEmpty,
            reason: 'frames (ms after the push) where the page colour was not what showed',
          );
        },
      );
    }
  }
}
