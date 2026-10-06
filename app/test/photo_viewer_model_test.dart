import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/services/photo_export.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';
import 'package:herdr_mobile/ui/features/photos/photo_item.dart';
import 'package:herdr_mobile/ui/features/photos/photo_viewer_view_model.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';
import 'support/photo_support.dart';

/// The sizes the fake decoder is asked for at a 100 x 200 dp, 1.0 dpr screen:
/// the box is 150 x 300 px, so a 600 x 400 photo decodes at 150 x 100.
const _base = (150, 100);

Future<void> _idle(WidgetTester tester) => tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));

PhotoViewerViewModel _model(
  List<PhotoItem> items,
  FakeDecoder decoder, {
  int index = 0,
  FakeExport? export,
  int sharpSide = 600,
  int preloadLimit = 12 * 1024 * 1024,
}) => PhotoViewerViewModel(
  items: items,
  initialIndex: index,
  decoder: decoder.call,
  exifReader: (_) => null,
  export: export ?? FakeExport(),
  sharpSide: sharpSide,
  preloadLimit: preloadLimit,
)..setViewport(const Size(100, 200), 1);

void main() {
  group('paging order and preload', () {
    testWidgets('the open photo loads first, then the next, then the previous: one at a time', (tester) async {
      final log = <String>[];
      final decoder = FakeDecoder();
      await decoder.prepare(tester, [_base]);
      final gates = {for (final n in ['a', 'b', 'c', 'd', 'e']) n: Completer<void>()};
      final model = _model([for (final n in gates.keys) fakePhoto(n, log, gate: gates[n])], decoder, index: 2);
      addTearDown(model.dispose);
      await _idle(tester);

      expect(log, ['start c'], reason: 'only the open photo at first; neighbours wait for it');
      gates['c']!.complete();
      await _idle(tester);
      expect(log, ['start c', 'done c', 'start d'], reason: 'then the next one, alone');
      expect(model.entryAt(2)!.ready, isTrue);
      gates['d']!.complete();
      await _idle(tester);
      expect(log.sublist(3), ['done d', 'start b']);
      gates['b']!.complete();
      await _idle(tester);
      expect(log.last, 'done b');
      expect(log.where((l) => l.startsWith('start')).toList(), ['start c', 'start d', 'start b'],
          reason: 'a and e are two away: never read');
      expect(model.entryAt(0), isNull);
      expect(model.entryAt(4), isNull);
    });

    testWidgets('going backwards preloads the previous photo first', (tester) async {
      final log = <String>[];
      final decoder = FakeDecoder();
      await decoder.prepare(tester, [_base]);
      final model = _model([for (final n in ['a', 'b', 'c', 'd', 'e']) fakePhoto(n, log)], decoder, index: 3);
      addTearDown(model.dispose);
      await _idle(tester);
      log.clear();

      model.goTo(1);
      await _idle(tester);
      await _idle(tester);
      expect(log.where((l) => l.startsWith('start')).toList(), ['start b', 'start a'],
          reason: 'the open one, then the one in the direction of travel; c was held already and is not read twice');
    });

    testWidgets('moving on cancels the read of a photo that is no longer a neighbour and frees it', (tester) async {
      final log = <String>[];
      final decoder = FakeDecoder();
      await decoder.prepare(tester, [_base]);
      final hold = Completer<void>();
      final model = _model([
        fakePhoto('a', log),
        fakePhoto('b', log),
        fakePhoto('c', log, gate: hold),
        fakePhoto('d', log),
        fakePhoto('e', log),
        fakePhoto('f', log),
      ], decoder, index: 1);
      addTearDown(model.dispose);
      await _idle(tester);
      // b done, c is held (a preload in flight).
      expect(log, containsAllInOrder(['start b', 'done b', 'start c']));
      final stale = model.entryAt(2)!;

      model.goTo(4); // c is now two away from the open photo
      await _idle(tester);
      expect(model.entryAt(2), isNull, reason: 'c is not held any more');
      hold.complete();
      await _idle(tester);
      expect(log, contains('cancelled c'), reason: 'the read was told to stop and did not deliver');
      expect(stale.ready, isFalse);
      expect(model.heldEntries, lessThanOrEqualTo(3));
    });

    testWidgets('only the open photo and its two neighbours are ever held, and the rest are freed', (tester) async {
      final log = <String>[];
      final decoder = FakeDecoder();
      await decoder.prepare(tester, [_base]);
      final model = _model([for (var i = 0; i < 12; i++) fakePhoto('p$i', log)], decoder);
      addTearDown(model.dispose);
      await _idle(tester);
      await _idle(tester);

      for (var i = 1; i < 12; i++) {
        model.goTo(i);
        await _idle(tester);
        await _idle(tester);
        expect(model.heldEntries, lessThanOrEqualTo(3), reason: 'at photo $i');
      }
      // 12 photos were decoded in all, and only the held ones still own a bitmap.
      final alive = decoder.decoded.where((d) => !d.image.debugDisposed).length;
      expect(decoder.decoded.length, greaterThanOrEqualTo(12));
      expect(alive, lessThanOrEqualTo(3), reason: 'bitmaps of photos that were left behind are disposed');
    });

    testWidgets('a big neighbour is not fetched ahead; it loads when the person gets there', (tester) async {
      final log = <String>[];
      final decoder = FakeDecoder();
      await decoder.prepare(tester, [_base]);
      final model = _model([
        fakePhoto('a', log),
        fakePhoto('big', log, size: 30 * 1024 * 1024),
        fakePhoto('c', log),
      ], decoder, index: 0);
      addTearDown(model.dispose);
      await _idle(tester);
      await _idle(tester);
      expect(log, ['start a', 'done a'], reason: 'the 30 MB neighbour waits');
      model.goTo(1);
      await _idle(tester);
      expect(log, contains('start big'));
    });

    testWidgets('the list can grow around the open photo without losing it', (tester) async {
      final log = <String>[];
      final decoder = FakeDecoder();
      await decoder.prepare(tester, [_base]);
      final here = fakePhoto('b', log);
      final model = _model([here], decoder);
      addTearDown(model.dispose);
      await _idle(tester);
      final entry = model.currentEntry;

      model.setItems([fakePhoto('a', log), here, fakePhoto('c', log)]);
      expect(model.index, 1);
      expect(model.count, 3);
      expect(identical(model.currentEntry, entry), isTrue, reason: 'the open photo keeps its loaded bitmap');
      expect(model.positionLabel, 'Photo 2 of 3');

      model.setItems([fakePhoto('x', log)]);
      expect(model.count, 3, reason: 'a list without the open photo is ignored');
    });

    testWidgets('a lone photo has no position', (tester) async {
      final decoder = FakeDecoder();
      await decoder.prepare(tester, [_base]);
      final model = _model([fakePhoto('only', [])], decoder);
      addTearDown(model.dispose);
      expect(model.positionLabel, 'Photo');
      expect(model.hasNext || model.hasPrevious, isFalse);
    });
  });

  group('decode size', () {
    testWidgets('the first bitmap is made for the screen: never more than 1.5x its pixels', (tester) async {
      final decoder = FakeDecoder();
      await decoder.prepare(tester, [_base, (150, 200)]);
      final model = _model([
        fakePhoto('wide', [], width: 600, height: 400),
        fakePhoto('tall', [], width: 3000, height: 4000),
      ], decoder);
      addTearDown(model.dispose);
      await _idle(tester);
      await _idle(tester);
      // 100 x 200 dp at 1.0 dpr: the box is 150 x 300 px.
      expect(decoder.calls.first.boxW, 150);
      expect(decoder.calls.first.boxH, 300);
      expect(model.entryAt(0)!.image!.image.width, 150);
      expect(model.entryAt(0)!.image!.width, 600, reason: 'the file is still 600 px wide');
      expect(model.entryAt(0)!.image!.downscaled, isTrue);
      expect(decoder.calls.every((c) => c.boxW <= 100 * 2 && c.boxH <= 200 * 2), isTrue);
    });

    testWidgets('zooming sharpens: a bigger decode joins the first, and only for the open photo', (tester) async {
      final decoder = FakeDecoder();
      await decoder.prepare(tester, [_base, (600, 400)]);
      final log = <String>[];
      final model = _model([fakePhoto('a', log), fakePhoto('b', log)], decoder);
      addTearDown(model.dispose);
      await _idle(tester);
      await _idle(tester);
      final a = model.entryAt(0)!;
      expect(a.sharp, isNull);
      final before = decoder.calls.length;

      await tester.runAsync(model.sharpen);
      expect(a.sharp, isNotNull);
      expect(a.sharp!.image.width, 600, reason: 'every pixel of the file');
      expect(a.shown, same(a.sharp!.image), reason: 'the sharp bitmap is what is drawn');
      expect(decoder.calls.length, before + 1);
      expect(decoder.calls.last.boxW, 600, reason: 'capped at the sharpen side');

      // A second ask while it is held does nothing.
      await tester.runAsync(model.sharpen);
      expect(decoder.calls.length, before + 1);

      // Zooming out gives it back.
      final sharp = a.sharp!;
      model.releaseSharp();
      expect(a.sharp, isNull);
      expect(sharp.image.debugDisposed, isTrue);
      expect(a.shown, same(a.image!.image));

      // Sharpen again, then leave the photo: the sharp bitmap does not follow.
      await tester.runAsync(model.sharpen);
      final again = a.sharp!;
      model.goTo(1);
      await _idle(tester);
      expect(again.image.debugDisposed, isTrue, reason: 'a sharp bitmap is only for the photo being looked at');
    });

    testWidgets('a photo that already holds every pixel is not decoded again', (tester) async {
      final decoder = FakeDecoder();
      await decoder.prepare(tester, [(100, 60)]);
      final model = _model([fakePhoto('small', [], width: 100, height: 60)], decoder);
      addTearDown(model.dispose);
      await _idle(tester);
      await _idle(tester);
      final calls = decoder.calls.length;
      await tester.runAsync(model.sharpen);
      expect(decoder.calls.length, calls);
      expect(model.currentEntry.image!.downscaled, isFalse);
    });
  });

  group('progress and failures', () {
    testWidgets('progress and the size are reported while the bytes arrive', (tester) async {
      final decoder = FakeDecoder();
      await decoder.prepare(tester, [_base]);
      final gate = Completer<void>();
      final model = _model([fakePhoto('a', [], gate: gate, size: 4400000)], decoder);
      addTearDown(model.dispose);
      await _idle(tester);
      final entry = model.currentEntry;
      expect(entry.total, 4400000);
      expect(entry.loading, isTrue);
      expect(entry.received, 0);
      gate.complete();
      await _idle(tester);
      expect(entry.ready, isTrue);
      expect(entry.received, greaterThan(0));
    });

    testWidgets('bytes that are not a picture say so and offer no retry', (tester) async {
      final decoder = FakeDecoder()..failing = true;
      final model = _model([fakePhoto('x.png', [])], decoder);
      addTearDown(model.dispose);
      await _idle(tester);
      final failure = model.currentEntry.failure!;
      expect(failure.kind, PhotoFailureKind.notAnImage);
      expect(failure.retryable, isFalse);
      expect(failure.message, contains("can't be shown"));
    });

    testWidgets('a dropped connection can be retried and then loads', (tester) async {
      final decoder = FakeDecoder();
      await decoder.prepare(tester, [_base]);
      final item = fakePhoto('a', [], error: RemoteFileException(RemoteFileErrorKind.network, 'The connection was lost'));
      final model = _model([item], decoder);
      addTearDown(model.dispose);
      await _idle(tester);
      expect(model.currentEntry.failure!.kind, PhotoFailureKind.network);
      expect(model.currentEntry.failure!.retryable, isTrue);

      (item.source as FakeSource).error = null;
      model.retry();
      await _idle(tester);
      expect(model.currentEntry.failure, isNull);
      expect(model.currentEntry.ready, isTrue);
    });

    testWidgets('a photo that is gone says it is gone', (tester) async {
      final decoder = FakeDecoder();
      final model = _model([
        fakePhoto('a', [], error: RemoteFileException(RemoteFileErrorKind.notFound, 'No such file or directory')),
      ], decoder);
      addTearDown(model.dispose);
      await _idle(tester);
      expect(model.currentEntry.failure!.message, contains('no longer there'));
    });
  });

  group('large files over SFTP', () {
    testWidgets('a 20 MB file (more than one 8 MB call) opens, in 2 MB reads, with progress', (tester) async {
      final bytes = Uint8List.fromList(List.generate(20 * 1024 * 1024, (i) => i % 251));
      final fs = FakeFs()..addFile('/p/big.jpg', bytes);
      final files = RemoteFiles(FakeTransport()..fs = fs);
      final progress = <int>[];
      final source = RemotePhotoSource(files, '/p/big.jpg', size: bytes.length);

      late Uint8List got;
      await tester.runAsync(() async => got = await source.read(onProgress: progress.add));

      expect(got.length, bytes.length);
      expect(got[8 * 1024 * 1024 + 5], bytes[8 * 1024 * 1024 + 5], reason: 'pieces stitched in order');
      final reads = fs.calls.where((c) => c.startsWith('read')).toList();
      expect(reads.length, 10, reason: '20 MB in 2 MB pieces, not one 8 MB call and then the rest');
      expect(reads.first, 'read /p/big.jpg@0+2097152');
      expect(progress.length, 10);
      expect(progress.last, bytes.length);
      expect(progress, orderedEquals([...progress]..sort()), reason: 'progress only goes up');
    });

    testWidgets('a cancel stops the reads between pieces', (tester) async {
      final bytes = Uint8List(10 * 1024 * 1024);
      final fs = FakeFs()..addFile('/p/big.jpg', bytes);
      final files = RemoteFiles(FakeTransport()..fs = fs);
      final cancel = ReadCancel();
      final source = RemotePhotoSource(files, '/p/big.jpg', size: bytes.length);

      Object? error;
      await tester.runAsync(() async {
        try {
          await source.read(onProgress: (n) => cancel.cancel(), cancel: cancel);
        } on Object catch (e) {
          error = e;
        }
      });
      expect(error, isA<ReadCancelled>());
      expect(fs.calls.where((c) => c.startsWith('read')).length, 1, reason: 'one piece, then it stopped');
    });

    test('over the cap it refuses before reading a byte, and says how big it is', () async {
      final fs = FakeFs();
      final files = RemoteFiles(FakeTransport()..fs = fs);
      final source = RemotePhotoSource(files, '/p/huge.jpg', size: 52 * 1024 * 1024);
      expect(photoReadCap, 40 * 1024 * 1024);

      await expectLater(
        source.read(),
        throwsA(
          isA<RemoteFileException>()
              .having((e) => e.kind, 'kind', RemoteFileErrorKind.tooLarge)
              .having((e) => e.message, 'message', allOf(contains('52 MB'), contains('40 MB'))),
        ),
      );
      expect(fs.calls, isEmpty);
    });

    test('an unknown size is asked for once', () async {
      final fs = FakeFs()..addFile('/p/a.png', Uint8List(2000));
      final files = RemoteFiles(FakeTransport()..fs = fs);
      final got = await RemotePhotoSource(files, '/p/a.png', size: null).read();
      expect(got.length, 2000);
      expect(fs.calls.first, 'stat /p/a.png');
    });

    testWidgets('over the cap the viewer shows the failure and shares the file in pieces', (tester) async {
      final bytes = Uint8List(5 * 1024 * 1024);
      final fs = FakeFs()..addFile('/p/huge.jpg', bytes);
      final files = RemoteFiles(FakeTransport()..fs = fs);
      final export = FakeExport();
      final decoder = FakeDecoder();
      final model = _model([
        PhotoItem(
          id: '/p/huge.jpg',
          name: 'huge.jpg',
          path: '/p/huge.jpg',
          source: RemotePhotoSource(files, '/p/huge.jpg', size: bytes.length, cap: 1024 * 1024),
        ),
      ], decoder, export: export);
      addTearDown(model.dispose);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));

      final entry = model.currentEntry;
      expect(entry.failure!.kind, PhotoFailureKind.tooLarge);
      expect(entry.failure!.retryable, isFalse);
      expect(model.canShareLarge, isTrue);
      expect(fs.calls.where((c) => c.startsWith('read')), isEmpty, reason: 'nothing was read to find out');

      late PhotoActionResult result;
      await tester.runAsync(() async => result = await model.shareLarge());
      expect(result.ok, isTrue);
      expect(export.large, ['huge.jpg:${bytes.length}']);
      expect(fs.calls.where((c) => c.startsWith('read')).length, 3, reason: '5 MB in 2 MB pieces: 2 + 2 + 1');
      expect(entry.exporting, isNull, reason: 'done');
    });
  });

  group('save and share', () {
    testWidgets('save and share hand the loaded bytes to the platform, with the file name', (tester) async {
      final decoder = FakeDecoder();
      await decoder.prepare(tester, [_base]);
      final export = FakeExport();
      final model = _model([fakePhoto('IMG_0042.jpg', [])], decoder, export: export);
      addTearDown(model.dispose);
      await _idle(tester);
      final size = model.currentEntry.bytes!.length;

      expect((await model.save()).message, 'Saved to Pictures/herdr');
      expect(export.saved, ['IMG_0042.jpg:$size']);
      expect((await model.share()).ok, isTrue);
      expect(export.shared, ['IMG_0042.jpg:$size']);
    });

    testWidgets('a failure comes back as words for the toast, not as an exception', (tester) async {
      final decoder = FakeDecoder();
      await decoder.prepare(tester, [_base]);
      final export = FakeExport()..failWith = const PhotoExportException('The phone is out of space.');
      final model = _model([fakePhoto('a.jpg', [])], decoder, export: export);
      addTearDown(model.dispose);
      await _idle(tester);
      final result = await model.save();
      expect(result.ok, isFalse);
      expect(result.message, 'The phone is out of space.');
    });

    testWidgets('nothing to save before the picture has loaded', (tester) async {
      final decoder = FakeDecoder();
      final model = _model([fakePhoto('a.jpg', [], gate: Completer<void>())], decoder);
      addTearDown(model.dispose);
      final result = await model.save();
      expect(result.ok, isFalse);
    });
  });

  group('real decode', () {
    testWidgets('EXIF orientation is applied: a landscape file flagged "rotate 90" is shown portrait', (tester) async {
      final upright = jpegWithExif(80, 40, orientation: 1);
      final turned = jpegWithExif(80, 40, orientation: 6, make: 'Canon', model: 'Canon EOS R5', taken: '2026:05:20 09:30:00');
      final model = PhotoViewerViewModel(
        items: [
          PhotoItem(id: 'u', name: 'u.jpg', source: MemoryPhotoSource(() async => upright, size: upright.length)),
          PhotoItem(id: 't', name: 't.jpg', source: MemoryPhotoSource(() async => turned, size: turned.length)),
        ],
        export: FakeExport(),
      )..setViewport(const Size(412, 892), 2.625);
      addTearDown(model.dispose);
      await pumpUntil(tester, () => model.entryAt(1)?.ready ?? false);

      final a = model.entryAt(0)!;
      final b = model.entryAt(1)!;
      expect((a.image!.width, a.image!.height), (80, 40));
      expect((b.image!.width, b.image!.height), (40, 80), reason: 'width and height swapped: the photo is upright');
      expect((b.image!.image.width, b.image!.image.height), (40, 80), reason: 'and so is the bitmap that is drawn');
      expect(b.exif!.orientation, 6);
      expect(b.exif!.camera, 'Canon EOS R5');
      expect(b.exif!.taken, DateTime(2026, 5, 20, 9, 30));
      expect(b.format, 'JPEG');
      expect(a.mayBeTransparent, isFalse);
    });

    testWidgets('a PNG with see-through pixels is flagged so the viewer draws a checkerboard', (tester) async {
      final png = pngWithAlpha(64, 64);
      final model = PhotoViewerViewModel(
        items: [PhotoItem(id: 'p', name: 'p.png', source: MemoryPhotoSource(() async => png, size: png.length))],
        export: FakeExport(),
      )..setViewport(const Size(412, 892), 2.625);
      addTearDown(model.dispose);
      await pumpUntil(tester, () => model.currentEntry.ready);
      expect(model.currentEntry.mayBeTransparent, isTrue);
      expect(model.currentEntry.format, 'PNG');
    });
  });
}
