import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/exif.dart';
import 'package:herdr_mobile/data/services/image_decode.dart';
import 'package:herdr_mobile/data/services/photo_export.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/photos/photo_item.dart';
import 'package:image/image.dart' as img;

/// A bitmap of [width] x [height] painted with a gradient and a corner mark:
/// a stand-in for a decoded photo. Needs `tester.runAsync`.
Future<ui.Image> paintBitmap(int width, int height, {int hue = 0}) {
  final pixels = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      pixels[i] = (40 + 180 * x / width + hue).round().clamp(0, 255);
      pixels[i + 1] = (60 + 150 * y / height).round().clamp(0, 255);
      pixels[i + 2] = (200 - 120 * x / width + hue ~/ 2).round().clamp(0, 255);
      pixels[i + 3] = 255;
      // A white square in the top-left corner shows orientation.
      if (x < width / 8 && y < height / 8) {
        pixels[i] = pixels[i + 1] = pixels[i + 2] = 255;
      }
    }
  }
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(pixels, width, height, ui.PixelFormat.rgba8888, done.complete);
  return done.future;
}

/// What a fake photo "file" holds: its size as text. [FakeDecoder] reads it, so
/// a 4000 x 3000 photo costs a few bytes.
Uint8List photoBytes(int width, int height, {int pad = 0}) =>
    Uint8List.fromList([...utf8.encode('${width}x$height'), ...List.filled(pad, 32)]);

/// A [FitDecoder] that makes bitmaps of the size the real one would (shrunk to
/// the box, never enlarged), from a pool of real ones painted up front, so a
/// test decodes without waiting for the engine. Sizes are looked up in the
/// pool: [prepare] what a test will ask for.
class FakeDecoder {
  FakeDecoder();

  final _pool = <(int, int), ui.Image>{};
  final calls = <({int width, int height, int boxW, int boxH})>[];
  final decoded = <DecodedImage>[];

  /// Fails every decode (a damaged file).
  var failing = false;

  Future<void> prepare(WidgetTester tester, Iterable<(int, int)> sizes) async {
    for (final s in sizes) {
      if (_pool.containsKey(s)) continue;
      late ui.Image image;
      await tester.runAsync(() async => image = await paintBitmap(s.$1, s.$2));
      _pool[s] = image;
    }
    addTearDown(() {
      for (final i in _pool.values) {
        i.dispose();
      }
      _pool.clear();
    });
  }

  Future<DecodedImage> call(Uint8List bytes, {required int maxWidth, required int maxHeight}) async {
    if (failing) throw StateError('not an image');
    final m = RegExp(r'^(\d+)x(\d+)').firstMatch(utf8.decode(bytes.take(24).toList(), allowMalformed: true));
    if (m == null) throw StateError('not a fake photo');
    final w = int.parse(m.group(1)!), h = int.parse(m.group(2)!);
    calls.add((width: w, height: h, boxW: maxWidth, boxH: maxHeight));
    final scale = fitScaleWithin(w, h, maxWidth, maxHeight);
    final key = (scale < 1 ? (w * scale).round().clamp(1, w) : w, scale < 1 ? (h * scale).round().clamp(1, h) : h);
    final bitmap = _pool[key] ?? (throw StateError('prepare ${key.$1}x${key.$2}'));
    final out = DecodedImage(image: bitmap.clone(), width: w, height: h, downscaled: scale < 1);
    decoded.add(out);
    return out;
  }
}

/// A [PhotoSource] a test can hold back, count and cancel. [log] gets
/// `start <name>` when the read begins, `done <name>` when it delivers and
/// `cancelled <name>` when its [ReadCancel] ended it.
class FakeSource implements PhotoSource {
  FakeSource(this.name, this.bytes, this.log, {this.gate, this.sizeOverride, this.error});

  final String name;
  final Uint8List bytes;
  final List<String> log;

  /// Holds the read until it completes.
  Completer<void>? gate;
  final int? sizeOverride;

  /// Thrown instead of delivering.
  Object? error;

  @override
  int? get size => sizeOverride ?? bytes.length;

  @override
  Future<Uint8List> read({void Function(int received)? onProgress, ReadCancel? cancel}) async {
    log.add('start $name');
    onProgress?.call(0);
    await gate?.future;
    if (cancel?.cancelled ?? false) {
      log.add('cancelled $name');
      throw const ReadCancelled();
    }
    if (error != null) throw error!;
    onProgress?.call(bytes.length);
    log.add('done $name');
    return bytes;
  }
}

/// One picture for a viewer: [FakeSource] and a name.
PhotoItem fakePhoto(
  String name,
  List<String> log, {
  int width = 600,
  int height = 400,
  Completer<void>? gate,
  int? size,
  Object? error,
  String? path,
  String? origin,
  DateTime? modified,
}) => PhotoItem(
  id: path ?? name,
  name: name,
  path: path,
  origin: origin,
  modified: modified,
  source: FakeSource(name, photoBytes(width, height), log, gate: gate, sizeOverride: size, error: error),
);

/// A [PhotoExport] that records instead of calling the platform.
class FakeExport implements PhotoExport {
  final saved = <String>[];
  final shared = <String>[];
  final large = <String>[];
  Object? failWith;

  @override
  Future<void> saveToGallery(Uint8List bytes, {required String name}) async {
    if (failWith != null) throw failWith!;
    saved.add('$name:${bytes.length}');
  }

  @override
  Future<void> share(Uint8List bytes, {required String name}) async {
    if (failWith != null) throw failWith!;
    shared.add('$name:${bytes.length}');
  }

  @override
  Future<void> shareLarge({
    required String name,
    required int size,
    required Future<Uint8List> Function(int offset, int length) read,
    required int chunk,
    void Function(int written)? onProgress,
    bool Function()? cancelled,
  }) async {
    if (failWith != null) throw failWith!;
    var at = 0;
    while (at < size) {
      final piece = await read(at, chunk < size - at ? chunk : size - at);
      if (piece.isEmpty) break;
      at += piece.length;
      onProgress?.call(at);
    }
    large.add('$name:$at');
  }
}

/// A JPEG of [width] x [height] with EXIF [orientation] (1-8) stored in it,
/// plus optional camera data: what a phone writes. The top-left [mark] pixels
/// are white so a test can see where the corner went.
Uint8List jpegWithExif(
  int width,
  int height, {
  int orientation = 1,
  String? make,
  String? model,
  String? taken,
}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(200, 60, 40));
  img.fillRect(image, x1: 0, y1: 0, x2: width ~/ 4, y2: height ~/ 4, color: img.ColorRgb8(255, 255, 255));
  image.exif.imageIfd.orientation = orientation;
  if (make != null) image.exif.imageIfd.make = make;
  if (model != null) image.exif.imageIfd.model = model;
  if (taken != null) image.exif.exifIfd.data[0x9003] = img.IfdValueAscii(taken);
  return img.encodeJpg(image, quality: 92);
}

/// A PNG of [width] x [height] with a see-through hole in the middle.
Uint8List pngWithAlpha(int width, int height) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(60, 160, 220, 255));
  // fillRect would blend a transparent colour into nothing: set the pixels.
  for (var y = height ~/ 4; y < height * 3 ~/ 4; y++) {
    for (var x = width ~/ 4; x < width * 3 ~/ 4; x++) {
      image.setPixelRgba(x, y, 0, 0, 0, 0);
    }
  }
  return img.encodePng(image);
}

/// Waits for real asynchronous work (the engine's codecs) while the test pumps.
Future<void> settleReal(WidgetTester tester, {int rounds = 6}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Pumps until [until] holds (real time passes between pumps).
Future<void> pumpUntil(WidgetTester tester, bool Function() until, {int limit = 120}) async {
  for (var i = 0; i < limit && !until(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// The phone-sized surface the viewer tests run on.
void usePhoneSurface(WidgetTester tester, {Size size = const Size(412, 892), double dpr = 2.625}) {
  tester.view
    ..physicalSize = size * dpr
    ..devicePixelRatio = dpr
    ..padding = FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr)
    ..viewPadding = FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr);
  addTearDown(tester.view.reset);
}

/// Pumps a viewer-shaped home in the app's theme.
Future<void> pumpApp(WidgetTester tester, Widget home, {Brightness brightness = Brightness.light, bool reduceMotion = false}) async {
  await tester.pumpWidget(
    MaterialApp(
      key: UniqueKey(),
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: home,
    ),
  );
  await tester.pump();
}

/// EXIF of an [orientation] jpeg, for assertions about what was read.
ExifInfo? exifOf(Uint8List bytes) => readExif(bytes);
