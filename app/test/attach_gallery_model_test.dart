// The Gallery tab's state: the permission is read without asking, the first
// page and the first thumbnails are loaded when it is granted (a warm start),
// pages come in as the grid asks, and an album switch starts over.
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/phone_gallery.dart';
import 'package:herdr_mobile/data/services/thumb_cache.dart';
import 'package:herdr_mobile/ui/features/attach/gallery_model.dart';

import 'support/attach_fakes.dart';

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 5));

GalleryModel modelOf(FakeGallery g, {bool Function()? foreground, ThumbCache? cache}) =>
    GalleryModel(g, cache ?? ThumbCache(load: (a) => g.thumbnail(a)), foreground: foreground);

void main() {
  test('warm loads albums, the first page and the first 24 thumbnails when access is granted, and never asks', () async {
    final g = FakeGallery(count: 1000);
    final m = modelOf(g);
    await m.warm();
    await settle();
    expect(g.requests, 0);
    expect(g.pageQueries, 1);
    expect(m.count, 1000);
    expect(m.at(0)!.id, '1000', reason: 'newest first');
    expect(m.at(galleryPage - 1), isNotNull);
    expect(m.at(galleryPage), isNull, reason: 'the second page waits for the grid');
    expect(m.thumbs.length, galleryWarmThumbs);
  });

  test('warm does nothing when the permission was never given, was refused, or the app is in the background', () async {
    for (final state in [GalleryAccess.undetermined, GalleryAccess.denied, GalleryAccess.unavailable]) {
      final g = FakeGallery(state: state);
      final m = modelOf(g);
      await m.warm();
      await settle();
      expect(g.requests, 0, reason: '$state');
      expect(g.albumQueries, 0, reason: '$state');
      expect(g.thumbCalls, 0, reason: '$state');
    }
    final g = FakeGallery();
    final m = modelOf(g, foreground: () => false);
    await m.warm();
    expect(g.accessReads, 0, reason: 'not even a platform call in the background');
  });


  test('ensure loads the page of an index once, however often the grid asks', () async {
    final g = FakeGallery(count: 1000);
    final m = modelOf(g);
    await m.open();
    final before = g.pageQueries;
    for (var i = 0; i < 20; i++) {
      m.ensure(450);
    }
    await settle();
    expect(g.pageQueries, before + 1);
    expect(m.at(450), isNotNull);
    expect(m.at(galleryPage * 3 + 5), isNotNull, reason: 'page 3 holds 360..479');
    m.ensure(2000); // out of range: ignored
    m.ensure(-1);
    await settle();
    expect(g.pageQueries, before + 1);
  });

  test('revision moves when a page arrives, and the model itself does not notify for it', () async {
    final g = FakeGallery(count: 500);
    final m = modelOf(g);
    await m.open();
    var modelNotified = 0;
    var revisions = 0;
    m.addListener(() => modelNotified++);
    m.revision.addListener(() => revisions++);
    m.ensure(300);
    await settle();
    expect(revisions, 1);
    expect(modelNotified, 0, reason: 'the grid is not rebuilt for a page');
  });

  test('request asks the system once and loads when it is granted', () async {
    final g = FakeGallery(state: GalleryAccess.undetermined);
    final m = modelOf(g);
    await m.open();
    expect(m.access, GalleryAccess.undetermined);
    expect(m.checked, isTrue);
    expect(g.requests, 0);
    await m.request();
    await settle();
    expect(g.requests, 1);
    expect(m.access, GalleryAccess.granted);
    expect(m.at(0), isNotNull);
  });

  test('a refusal stays refused and loads nothing', () async {
    final g = FakeGallery(state: GalleryAccess.undetermined, afterRequest: GalleryAccess.denied);
    final m = modelOf(g);
    await m.open();
    await m.request();
    expect(m.access, GalleryAccess.denied);
    expect(g.pageQueries, 0);
  });

  test('coming back from the settings with the permission given loads the grid', () async {
    final g = FakeGallery(state: GalleryAccess.denied);
    final m = modelOf(g);
    await m.open();
    g.state = GalleryAccess.granted;
    await m.recheck();
    await settle();
    expect(m.access, GalleryAccess.granted);
    expect(m.count, 40);
  });

  test('picking an album replaces the pictures and starts at its first page', () async {
    final g = FakeGallery(
      count: 300,
      extraAlbums: const [GalleryAlbum(id: 'shots', name: 'Screenshots', count: 7)],
    );
    final m = modelOf(g);
    await m.open();
    await m.loadAlbums();
    expect(m.albums.map((a) => a.name), ['Recent', 'Screenshots']);
    await m.selectAlbum(m.albums[1]);
    await settle();
    expect(m.count, 7);
    expect(m.album!.name, 'Screenshots');
    expect(m.at(0), isNotNull);
    expect(m.at(7), isNull);
  });

  test('Manage re-opens the selector, drops the old thumbnails and reads the library again', () async {
    final g = FakeGallery(state: GalleryAccess.limited, count: 6);
    final m = modelOf(g);
    await m.open();
    await settle();
    expect(m.thumbs.length, 6);
    g.count = 3;
    await m.manage();
    await settle();
    expect(g.manageCalls, 1);
    expect(m.count, 3);
    expect(m.thumbs.length, 3, reason: 'what was shared before is not kept');
  });

  test('an empty library is an album of zero, not an error', () async {
    final g = FakeGallery(count: 0);
    final m = modelOf(g);
    await m.open();
    expect(m.access.canRead, isTrue);
    expect(m.count, 0);
    expect(m.loading, isFalse);
  });

  group('a picture taken after the first load', () {
    // The model lives for the whole app run. A screenshot taken while the app
    // was open (or in the background) must be on the grid the next time the
    // person reaches for the paperclip, without restarting the app.
    Future<(FakeGallery, GalleryModel)> loaded({int count = 40}) async {
      final g = FakeGallery(count: count);
      final m = modelOf(g);
      await m.warm();
      await settle();
      expect(m.at(0)!.id, '$count');
      return (g, m);
    }

    test('is on the grid when the paperclip warms it', () async {
      final (g, m) = await loaded();
      g.count = 41;
      await m.warm();
      await settle();
      expect(m.count, 41);
      expect(m.at(0)!.id, '41', reason: 'newest first');
      expect(m.at(1)!.id, '40');
    });

    test('is on the grid when the Gallery tab is shown', () async {
      final (g, m) = await loaded();
      g.count = 41;
      await m.open();
      await settle();
      expect(m.at(0)!.id, '41');
    });

    test('is on the grid when the app comes back with the sheet open', () async {
      final (g, m) = await loaded();
      g.count = 41;
      await m.recheck();
      await settle();
      expect(m.at(0)!.id, '41');
    });

    test('shows with the pictures that were already there, and tells the grid', () async {
      final (g, m) = await loaded(count: 500);
      m.ensure(300);
      await settle();
      var modelNotified = 0;
      var revisions = 0;
      m.addListener(() => modelNotified++);
      m.revision.addListener(() => revisions++);
      g.count = 501;
      await m.warm();
      await settle();
      expect(modelNotified, greaterThan(0), reason: 'the count changed, so the grid is rebuilt');
      expect(revisions, greaterThan(0));
      expect(m.at(0)!.id, '501');
      expect(m.at(300), isNull, reason: 'a page that moved is asked for again as the grid scrolls to it');
      m.ensure(300);
      await settle();
      expect(m.at(300)!.id, '201', reason: 'index 300 is now the picture that was at 299');
    });

    test('a library that did not change is left alone: no rebuild, no new thumbnails', () async {
      final (g, m) = await loaded();
      final thumbs = g.thumbCalls;
      var modelNotified = 0;
      var revisions = 0;
      m.addListener(() => modelNotified++);
      m.revision.addListener(() => revisions++);
      await m.warm();
      await m.open();
      await m.recheck();
      await settle();
      expect(modelNotified, 0);
      expect(revisions, 0);
      expect(g.thumbCalls, thumbs);
    });

    test('another album is read again too, and a vanished one falls back to Recent', () async {
      final g = FakeGallery(
        count: 300,
        extraAlbums: [const GalleryAlbum(id: 'shots', name: 'Screenshots', count: 7)],
      );
      final m = modelOf(g);
      await m.open();
      await m.loadAlbums();
      await m.selectAlbum(m.albums[1]);
      await settle();
      expect(m.count, 7);
      g.extraAlbums[0] = const GalleryAlbum(id: 'shots', name: 'Screenshots', count: 8);
      await m.open();
      await settle();
      expect(m.count, 8);
      g.extraAlbums.clear();
      await m.open();
      await settle();
      expect(m.album!.isRecent, isTrue);
      expect(m.count, 300);
    });

    test('two warms at once are one read', () async {
      final (g, m) = await loaded();
      g.count = 41;
      final before = g.pageQueries;
      await Future.wait([m.warm(), m.warm(), m.open()]);
      await settle();
      expect(g.pageQueries, before + 1);
      expect(m.at(0)!.id, '41');
    });
  });
}
