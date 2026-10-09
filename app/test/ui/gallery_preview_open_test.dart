// Tapping a gallery tile opens the viewer on that picture, however the album's
// pages happened to arrive, and an album with nothing loaded opens nothing.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/thumb_cache.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/attach/gallery_model.dart';
import 'package:herdr_mobile/ui/features/attach/gallery_preview.dart';
import 'package:herdr_mobile/ui/features/attach/tray.dart';
import 'package:herdr_mobile/ui/features/photos/photo_viewer.dart';

import '../support/attach_fakes.dart';

Future<BuildContext> _host(WidgetTester tester) async {
  late BuildContext host;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) {
          host = context;
          return const Scaffold();
        },
      ),
    ),
  );
  return host;
}

Future<GalleryModel> _model(WidgetTester tester, FakeGallery g, {List<int> ensure = const []}) async {
  final m = GalleryModel(g, ThumbCache(load: (a) => g.thumbnail(a)));
  addTearDown(m.dispose);
  await tester.runAsync(() async {
    await m.open();
    for (final i in ensure) {
      m.ensure(i);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  return m;
}

void main() {
  testWidgets('a tile past an unloaded page opens its own picture, not another one', (tester) async {
    final g = FakeGallery(count: 1000);
    // Pages 0 and 2 are in; page 1 never arrived (the grid scrolled past it).
    final m = await _model(tester, g, ensure: [300]);
    expect(m.at(300), isNotNull);
    expect(m.at(150), isNull, reason: 'the page between is not loaded');

    final tray = AttachTray(capacity: 5);
    addTearDown(tray.dispose);
    final host = await _host(tester);
    unawaited(openGalleryPreview(host, model: m, tray: tray, cache: ThumbCache(load: (a) => g.thumbnail(a)), index: 300, gallery: g));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final viewer = tester.state<PhotoViewerState>(find.byType(PhotoViewer)).model;
    expect(viewer.current.id, m.at(300)!.id);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an album with nothing loaded opens nothing and does not throw', (tester) async {
    final g = FakeGallery(count: 0);
    final m = await _model(tester, g);
    final tray = AttachTray(capacity: 5);
    addTearDown(tray.dispose);
    final host = await _host(tester);

    await openGalleryPreview(host, model: m, tray: tray, cache: ThumbCache(load: (a) => g.thumbnail(a)), index: 0, gallery: g);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(PhotoViewer), findsNothing);
  });
}
