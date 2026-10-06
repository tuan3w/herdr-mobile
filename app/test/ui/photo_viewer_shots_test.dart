// Renders the photo viewer to PNGs under /tmp/photo_viewer_shots/ (see
// docs/DESIGN.md "Checking a screen"): fit, zoomed, overlay and info sheet,
// loading, errors, see-through and tiny pictures, in light and dark, at
// 412 x 892 and 320 x 640. Run with `flutter test test/ui/photo_viewer_shots_test.dart`.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/core/toast.dart';
import 'package:herdr_mobile/ui/features/photos/photo_item.dart';
import 'package:herdr_mobile/ui/features/photos/photo_viewer.dart';
import 'package:image/image.dart' as img;

import '../support/fake_fs.dart';
import '../support/fake_transport.dart';
import '../support/photo_support.dart';
import '../support/shot.dart' show loadAppFonts;

const _out = '/tmp/photo_viewer_shots';

/// A landscape the eye can judge orientation and sharpness on: sky, sun,
/// mountains, a lake, a white mark in the top-left corner.
Uint8List scene(int w, int h, {int orientation = 1, String? make, String? model, String? taken}) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    final t = y / h;
    final c = t < 0.62
        ? img.ColorRgb8((120 + 110 * t).round(), (170 + 60 * t).round(), (235 - 40 * t).round())
        : img.ColorRgb8((30 + 20 * (t - 0.62)).round(), (80 + 90 * (t - 0.62)).round(), (120 + 60 * (t - 0.62)).round());
    img.drawLine(image, x1: 0, y1: y, x2: w, y2: y, color: c);
  }
  img.fillCircle(image, x: (w * 0.72).round(), y: (h * 0.28).round(), radius: (h * 0.09).round(), color: img.ColorRgb8(255, 236, 170));
  final ridge = img.ColorRgb8(52, 64, 82);
  for (var layer = 0; layer < 2; layer++) {
    final base = h * (0.62 - 0.08 * layer);
    final shade = img.ColorRgb8(52 + 40 * layer, 64 + 40 * layer, 82 + 36 * layer);
    for (var x = 0; x < w; x++) {
      final peak = base - h * 0.16 * (0.5 + 0.5 * math.sin(x / w * 9 + layer * 2)) * (0.6 + 0.4 * math.sin(x / w * 23));
      img.drawLine(image, x1: x, y1: peak.round(), x2: x, y2: (h * 0.62).round(), color: layer == 0 ? ridge : shade);
    }
  }
  // Fine detail to see sharpening: a grid of thin lines on the lake.
  for (var x = 0; x < w; x += math.max(6, w ~/ 80)) {
    img.drawLine(image, x1: x, y1: (h * 0.66).round(), x2: x, y2: h, color: img.ColorRgb8(40, 100, 150));
  }
  img.fillRect(image, x1: 0, y1: 0, x2: w ~/ 10, y2: h ~/ 10, color: img.ColorRgb8(255, 255, 255));
  image.exif.imageIfd.orientation = orientation;
  if (make != null) image.exif.imageIfd.make = make;
  if (model != null) image.exif.imageIfd.model = model;
  if (taken != null) image.exif.exifIfd.data[0x9003] = img.IfdValueAscii(taken);
  return img.encodeJpg(image, quality: 90);
}

Uint8List tinyIcon() {
  final image = img.Image(width: 24, height: 24, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(0, 0, 0, 0));
  img.fillCircle(image, x: 12, y: 12, radius: 10, color: img.ColorRgba8(76, 183, 130, 255));
  img.fillRect(image, x1: 8, y1: 8, x2: 15, y2: 15, color: img.ColorRgba8(255, 255, 255, 255));
  img.drawLine(image, x1: 2, y1: 2, x2: 21, y2: 21, color: img.ColorRgba8(94, 106, 210, 255));
  return img.encodePng(image);
}

PhotoItem _memory(String name, Uint8List bytes, {String? path, DateTime? modified, String? origin, int? size}) => PhotoItem(
  id: path ?? name,
  name: name,
  path: path,
  modified: modified,
  origin: origin,
  source: MemoryPhotoSource(() async => bytes, size: size ?? bytes.length),
);

Future<void> shootAt(
  WidgetTester tester,
  String name, {
  required List<PhotoItem> items,
  int index = 0,
  Size size = const Size(412, 892),
  Brightness brightness = Brightness.light,
  Future<void> Function(WidgetTester tester, PhotoViewerState viewer)? then,
  bool waitReady = true,
  double scale = 1.5,
}) async {
  final dpr = 2.625;
  tester.view
    ..physicalSize = size * dpr
    ..devicePixelRatio = dpr
    ..padding = FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr)
    ..viewPadding = FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr);
  addTearDown(tester.view.reset);

  final key = GlobalKey();
  late BuildContext host;
  await tester.pumpWidget(
    MaterialApp(
      key: UniqueKey(),
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      navigatorObservers: [ToastRouteObserver()],
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppTheme.systemBars(Theme.of(context).brightness),
        child: RepaintBoundary(key: key, child: child!),
      ),
      home: Builder(
        builder: (context) {
          host = context;
          final ds = context.ds;
          return Scaffold(
            backgroundColor: ds.bg,
            appBar: null,
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('payments-api', style: Type.title.copyWith(color: ds.text)),
                    const SizedBox(height: 8),
                    Text('The chat sits under the viewer.', style: Type.body.copyWith(color: ds.textSecondary)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
  await tester.pump();
  unawaited(Navigator.of(host).push(photoViewerRoute(items: items, initialIndex: index, export: FakeExport())));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  final viewer = tester.state<PhotoViewerState>(find.byType(PhotoViewer));
  if (waitReady) {
    await pumpUntil(tester, () => viewer.model.currentEntry.ready || viewer.model.currentEntry.failure != null);
    await tester.pump(const Duration(milliseconds: 200));
  } else {
    await tester.pump(const Duration(milliseconds: 100));
  }
  if (then != null) await then(tester, viewer);
  await tester.pump(const Duration(milliseconds: 500));

  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage(pixelRatio: scale);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$_out/$name.png').create(recursive: true);
    await File('$_out/$name.png').writeAsBytes(data!.buffer.asUint8List());
  });
}

Future<void> doubleTapAt(WidgetTester tester, Offset at) async {
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tapAt(at);
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  setUpAll(() async {
    await loadAppFonts();
    Directory(_out).createSync(recursive: true);
  });

  final photos = [
    _memory('IMG_20260520_093012.jpg', scene(1600, 1200, make: 'Google', model: 'Pixel 8 Pro', taken: '2026:05:20 09:30:12'),
        path: '/home/dev/Pictures/trip/IMG_20260520_093012.jpg', modified: DateTime.utc(2026, 5, 20, 9, 30, 14)),
    _memory('IMG_20260520_093044.jpg', scene(1200, 1600, orientation: 1), path: '/home/dev/Pictures/trip/IMG_20260520_093044.jpg'),
    _memory('IMG_20260520_093101.jpg', scene(1600, 900), path: '/home/dev/Pictures/trip/IMG_20260520_093101.jpg'),
  ];

  for (final (label, size) in [('412x892', const Size(412, 892)), ('320x640', const Size(320, 640))]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final tag = '$label-${brightness.name}';

      testWidgets('fit with the overlay: $tag', (tester) async {
        await shootAt(tester, 'fit-$tag', items: photos, index: 0, size: size, brightness: brightness);
      });

      testWidgets('portrait photo: $tag', (tester) async {
        await shootAt(tester, 'portrait-$tag', items: photos, index: 1, size: size, brightness: brightness);
      });

      testWidgets('zoomed 2.5x at a point, overlay shown and hidden: $tag', (tester) async {
        await shootAt(tester, 'zoomed-$tag', items: photos, index: 0, size: size, brightness: brightness, then: (t, v) async {
          await doubleTapAt(t, Offset(size.width * 0.72, size.height * 0.4));
          await pumpUntil(t, () => v.model.currentEntry.sharp != null);
          await t.pump(const Duration(milliseconds: 300));
        });
        await shootAt(tester, 'zoomed-bare-$tag', items: photos, index: 0, size: size, brightness: brightness, then: (t, v) async {
          await doubleTapAt(t, Offset(size.width * 0.72, size.height * 0.4));
          await pumpUntil(t, () => v.model.currentEntry.sharp != null);
          await t.tapAt(Offset(size.width / 2, size.height / 2));
          await t.pump(const Duration(milliseconds: 600));
        });
      });

      testWidgets('info sheet: $tag', (tester) async {
        await shootAt(tester, 'info-$tag', items: photos, index: 0, size: size, brightness: brightness, then: (t, v) async {
          await t.tap(find.byTooltip('Photo info'));
          await t.pumpAndSettle();
        });
      });

      testWidgets('save and share sheet: $tag', (tester) async {
        await shootAt(tester, 'share-$tag', items: photos, index: 0, size: size, brightness: brightness, then: (t, v) async {
          await t.tap(find.byTooltip('Save or share'));
          await t.pumpAndSettle();
        });
      });

      testWidgets('saved toast: $tag', (tester) async {
        await shootAt(tester, 'saved-$tag', items: photos, index: 0, size: size, brightness: brightness, then: (t, v) async {
          await t.tap(find.byTooltip('Save or share'));
          await t.pumpAndSettle();
          await t.tap(find.text('Save to phone'));
          await t.pump();
          await t.pump(const Duration(milliseconds: 500));
        });
      });

      testWidgets('loading with progress: $tag', (tester) async {
        final gate = Completer<void>();
        final item = PhotoItem(
          id: 'slow',
          name: 'IMG_20260520_093012.jpg',
          path: '/home/dev/Pictures/trip/IMG_20260520_093012.jpg',
          source: _Slow(gate, 11 * 1024 * 1024, 4.2 * 1024 * 1024),
        );
        await shootAt(tester, 'loading-$tag', items: [item, photos[1]], size: size, brightness: brightness, waitReady: false, then: (t, v) async {
          await t.pump(const Duration(milliseconds: 200));
        });
        gate.complete();
        await tester.pump(const Duration(milliseconds: 100));
      });

      testWidgets('loading with the thumbnail standing in: $tag', (tester) async {
        late ui.Image thumb;
        await tester.runAsync(() async => thumb = await paintBitmap(120, 90, hue: 20));
        addTearDown(thumb.dispose);
        final gate = Completer<void>();
        final item = PhotoItem(
          id: 'slow2',
          name: 'IMG_20260520_093101.jpg',
          path: '/home/dev/Pictures/trip/IMG_20260520_093101.jpg',
          source: _Slow(gate, 11 * 1024 * 1024, 7.7 * 1024 * 1024),
          placeholder: () => thumb.clone(),
        );
        await shootAt(tester, 'loading-thumb-$tag', items: [item, photos[1]], size: size, brightness: brightness, waitReady: false);
        gate.complete();
        await tester.pump(const Duration(milliseconds: 100));
      });

      testWidgets('over the read cap: $tag', (tester) async {
        final fs = FakeFs();
        final files = RemoteFiles(FakeTransport()..fs = fs);
        final item = PhotoItem(
          id: '/home/dev/Pictures/raw/DSC_0042.jpg',
          name: 'DSC_0042.jpg',
          path: '/home/dev/Pictures/raw/DSC_0042.jpg',
          source: RemotePhotoSource(files, '/home/dev/Pictures/raw/DSC_0042.jpg', size: 52 * 1024 * 1024),
        );
        await shootAt(tester, 'over-cap-$tag', items: [item], size: size, brightness: brightness);
      });

      testWidgets('damaged file: $tag', (tester) async {
        final item = _memory('error-page.png', Uint8List.fromList(List.filled(300, 3)), path: '/home/dev/Pictures/error-page.png');
        await shootAt(tester, 'not-a-picture-$tag', items: [item], size: size, brightness: brightness);
      });

      testWidgets('connection lost: $tag', (tester) async {
        final item = PhotoItem(
          id: 'x',
          name: 'IMG_0001.jpg',
          path: '/home/dev/Pictures/IMG_0001.jpg',
          source: _Failing(RemoteFileException(RemoteFileErrorKind.network, 'The connection was lost')),
        );
        await shootAt(tester, 'connection-lost-$tag', items: [item], size: size, brightness: brightness);
      });

      testWidgets('see-through PNG, a tiny icon, and a rotated photo: $tag', (tester) async {
        final alpha = pngWithAlpha(640, 480);
        final items = [
          _memory('overlay.png', alpha, path: '/home/dev/overlay.png'),
          _memory('icon-24.png', tinyIcon(), path: '/home/dev/icon-24.png'),
          _memory('Ảnh chụp màn hình rất dài của buổi họp ngày hai mươi tháng năm hai nghìn hai mươi sáu lần thứ 3 (bản cuối cùng).jpg',
              scene(1600, 1000, orientation: 6, make: 'Canon', model: 'Canon EOS R5', taken: '2026:05:20 09:30:12'),
              path: '/home/dev/Ảnh/dài.jpg'),
        ];
        await shootAt(tester, 'transparent-$tag', items: items, index: 0, size: size, brightness: brightness);
        await shootAt(tester, 'tiny-crisp-$tag', items: items, index: 1, size: size, brightness: brightness);
        await shootAt(tester, 'rotated-long-name-$tag', items: items, index: 2, size: size, brightness: brightness);
      });

      testWidgets('dragging down: the backdrop fades over the chat: $tag', (tester) async {
        await shootAt(tester, 'dismiss-drag-$tag', items: photos, index: 0, size: size, brightness: brightness, then: (t, v) async {
          final g = await t.startGesture(Offset(size.width / 2, size.height / 2));
          for (var i = 0; i < 10; i++) {
            await g.moveBy(const Offset(10, 18));
            await t.pump(const Duration(milliseconds: 16));
          }
          // Held: the capture happens with the finger down.
          addTearDown(() => g.up());
        });
      });
    }
  }
}

class _Slow implements PhotoSource {
  _Slow(this.gate, this.total, this.partial);

  final Completer<void> gate;
  final int total;
  final double partial;

  @override
  int? get size => total;

  @override
  Future<Uint8List> read({void Function(int received)? onProgress, ReadCancel? cancel}) async {
    onProgress?.call(partial.round());
    await gate.future;
    throw const ReadCancelled();
  }
}

class _Failing implements PhotoSource {
  _Failing(this.error);

  final Object error;

  @override
  int? get size => 3 * 1024 * 1024;

  @override
  Future<Uint8List> read({void Function(int received)? onProgress, ReadCancel? cancel}) async => throw error;
}
