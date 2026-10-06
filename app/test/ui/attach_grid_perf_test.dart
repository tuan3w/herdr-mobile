// The gallery grid with 5,000 pictures, measured under the test binding
// (desktop, debug JIT: build + layout + paint recording, no rasterisation and
// no GPU). The numbers are printed; the assertions are on what does not
// depend on the machine: how many tiles are built and rebuilt, and the
// cache cap. The phone's numbers are a separate measurement (AGENTS.md
// "Measure on a phone").
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_select.dart';
import 'package:herdr_mobile/ui/features/attach/gallery_tab.dart';
import 'package:herdr_mobile/ui/features/attach/gallery_thumb.dart';
import 'package:herdr_mobile/ui/features/attach/selection_circle.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/attach_fakes.dart';
import '../support/fake_agent_session.dart';
import '../support/files_support.dart';

double percentile(List<double> sorted, double p) => sorted[math.min(sorted.length - 1, (sorted.length * p).floor())];

void main() {
  testWidgets('5,000 pictures: tiles built, rebuilds, frame cost while flinging, selection latency', (tester) async {
    tester.view
      ..physicalSize = const Size(1080, 2340)
      ..devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final gallery = FakeGallery(count: 5000)..picture = (a) => fakePicture(int.tryParse(a.id) ?? 0, w: 64, h: 64);
    final fake = FakeKit(gallery: gallery);
    final session = FakeAgentSession(machine: machineWithFiles(projectFs()), cwd: '/home/dev/herdr-mobile');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: AgentSessionScreen(key: ObjectKey(session), session: session, attachKit: fake.kit),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));

    // Time to the first frame of the sheet.
    final open = Stopwatch()..start();
    await tester.tap(find.byIcon(LucideIcons.paperclip).first);
    await tester.pump();
    open.stop();
    final firstFrameMs = open.elapsedMicroseconds / 1000;
    await tester.pump(const Duration(milliseconds: 400));

    // Thumbnails of the first screenful were warmed before the sheet opened.
    final warmed = fake.kit.thumbs.length;

    // Decode time of one thumbnail, off the UI thread (the engine's codec).
    final bytes = fake.kit.thumbs.peek(gallery.assetAt(0).id)!;
    final decodeMs = await tester.runAsync(() async {
      final sw = Stopwatch()..start();
      final done = Completer<void>();
      final stream = galleryThumbProvider(bytes).resolve(ImageConfiguration.empty);
      late ImageStreamListener listener;
      listener = ImageStreamListener((_, _) {
        stream.removeListener(listener);
        done.complete();
      });
      stream.addListener(listener);
      await done.future;
      return sw.elapsedMicroseconds / 1000;
    });

    final tiles = find.byType(PhotoTile).evaluate().length;

    // Close and open again: the library, the page and the thumbnails stay.
    await tester.tapAt(const Offset(200, 40));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final reopen = Stopwatch()..start();
    await tester.tap(find.byIcon(LucideIcons.paperclip).first);
    await tester.pump();
    reopen.stop();
    final reopenMs = reopen.elapsedMicroseconds / 1000;
    final queriesAfterReopen = gallery.pageQueries;
    await tester.pump(const Duration(milliseconds: 400));

    // Lift to full height, then fling the grid through 5,000 pictures.
    await tester.fling(find.text('Recent'), const Offset(0, -300), 2500);
    await tester.pump(const Duration(milliseconds: 700));
    final builds = <String, int>{};
    debugRegionBuilt = (r) => builds[r] = (builds[r] ?? 0) + 1;
    addTearDown(() => debugRegionBuilt = null);
    final frames = <double>[];
    var maxTiles = 0;
    final grid = find.descendant(of: find.byType(GalleryTab), matching: find.byType(CustomScrollView));
    for (var i = 0; i < 12; i++) {
      await tester.fling(grid, Offset(0, i.isEven ? -1400 : 1000), 4500);
      for (var f = 0; f < 45; f++) {
        final sw = Stopwatch()..start();
        await tester.pump(const Duration(milliseconds: 16));
        frames.add(sw.elapsedMicroseconds / 1000);
        maxTiles = math.max(maxTiles, find.byType(PhotoTile).evaluate().length);
      }
    }
    frames.sort();
    final scrollTileBuilds = builds['attach:tile'] ?? 0;
    final gridBuilds = builds['attach:grid'] ?? 0;

    // Selection to paint: a tap on a circle and the frame that shows it.
    await tester.pump(const Duration(seconds: 4)); // the last fling comes to rest
    builds.clear();
    final taps = <double>[];
    // Circles in the upper half of the screen, clear of the bars.
    final reachable = find.byType(SelectionCircle).evaluate().where((e) {
      final y = tester.getCenter(find.byWidget(e.widget)).dy;
      return y > 220 && y < 560;
    }).take(5).map((e) => e.widget).toList();
    expect(reachable, hasLength(5));
    for (final circle in reachable) {
      final sw = Stopwatch()..start();
      await tester.tap(find.byWidget(circle));
      await tester.pump();
      taps.add(sw.elapsedMicroseconds / 1000);
    }
    final selectionTileBuilds = builds['attach:tile'] ?? 0;
    final selectionGridBuilds = builds['attach:grid'] ?? 0;

    String f(double v) => v.toStringAsFixed(1);
    // ignore: avoid_print
    print('''
attach grid, 5,000 pictures, desktop test binding (debug JIT, no raster):
  tap -> first frame of the sheet        ${f(firstFrameMs)} ms
  thumbnails in memory at open (warmed)  $warmed
  decode of one 240 px thumbnail (codec) ${f(decodeMs!)} ms
  tiles built at half height             $tiles
  tap -> first frame, second opening     ${f(reopenMs)} ms (page queries so far: $queriesAfterReopen)
  most tiles alive while flinging        $maxTiles
  frame (build+layout+paint) p50/p95/max ${f(percentile(frames, .5))} / ${f(percentile(frames, .95))} / ${f(frames.last)} ms over ${frames.length} frames
  tile builds during the fling           $scrollTileBuilds   (grid rebuilds: $gridBuilds)
  selection tap -> frame                 ${f(taps.reduce((a, b) => a + b) / taps.length)} ms avg, ${f(taps.reduce(math.max))} ms max
  tile builds / grid builds per 5 picks  $selectionTileBuilds / $selectionGridBuilds
  thumbnail cache                        ${fake.kit.thumbs.length} entries, ${(fake.kit.thumbs.bytes / 1024).round()} KB
  plugin thumbnail calls / page queries  ${gallery.thumbCalls} / ${gallery.pageQueries}''');

    expect(queriesAfterReopen, 1, reason: 'the second opening asks the library for nothing');
    expect(maxTiles, lessThan(70), reason: 'a few screenfuls of tiles, whatever the library holds');
    expect(gridBuilds, 0, reason: 'the grid itself is never rebuilt by scrolling');
    expect(selectionGridBuilds, 0);
    expect(selectionTileBuilds, 5, reason: 'one tile per pick');
    expect(fake.kit.thumbs.length, lessThanOrEqualTo(200));
    expect(fake.kit.thumbs.bytes, lessThanOrEqualTo(60 * 1024 * 1024));
    expect(fake.kit.thumbs.peakRunning, lessThanOrEqualTo(4));
    expect(percentile(frames, .95), lessThan(100), reason: 'loose: this is a debug build on a shared machine');
    expect(ui.PlatformDispatcher.instance.views, isNotEmpty);
  });
}
