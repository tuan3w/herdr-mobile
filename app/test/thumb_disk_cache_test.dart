import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/services/picture_store.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';
import 'package:herdr_mobile/ui/features/files/file_thumb.dart';
import 'package:herdr_mobile/ui/features/files/photo_thumbs.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';
import 'support/photo_support.dart';

/// A 600 x 450 "photo" (see [photoBytes]) that decodes to a 240 x 180 thumbnail.
final _original = photoBytes(600, 450, pad: 400);
final _thumb = photoBytes(240, 180);
final _modified = DateTime.utc(2026, 5, 20, 9, 30);

RemoteEntry _entry(Uint8List bytes, {DateTime? modified, String path = '/p/a.jpg'}) => RemoteEntry(
  name: 'a.jpg',
  path: path,
  kind: RemoteEntryKind.file,
  resolvedKind: RemoteEntryKind.file,
  size: bytes.length,
  modified: modified ?? _modified,
);

void main() {
  late Directory dir;
  late PictureStore store;
  late FakeFs fs;
  late RemoteFiles files;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('thumb_disk_');
    store = PictureStore(() async => dir);
    fs = FakeFs()..addFile('/p/a.jpg', _original, modified: _modified);
    files = RemoteFiles(FakeTransport()..fs = fs, machineId: 'm1');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  int reads() => fs.calls.where((c) => c.startsWith('read')).length;

  /// Real IO happens in `runAsync`; what a cache schedules in the test's fake
  /// zone needs a pump to continue.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(done(), isTrue, reason: 'timed out');
  }

  Future<Uint8List?> load(WidgetTester tester, ThumbLoader loader, RemoteEntry entry) async {
    Uint8List? bytes;
    var done = false;
    unawaited(loader.load(files, entry, cancelled: () => false).then((v) {
      bytes = v;
      done = true;
    }));
    await until(tester, () => done);
    return bytes;
  }

  PhotoThumbs grid(FakeDecoder decoder) => PhotoThumbs(
    autoLimit: 100000,
    decoder: decoder.call,
    encoder: (image, {required png}) async => _thumb,
    store: store,
  );

  testWidgets('a folder opened again draws its tiles without a read', (tester) async {
    final decoder = FakeDecoder();
    await decoder.prepare(tester, [(240, 180)]);
    final entry = _entry(_original);
    final key = PictureStore.thumbKey('m1', entry.path, entry.size!, _modified.millisecondsSinceEpoch);

    final first = grid(decoder);
    addTearDown(first.dispose);
    final e1 = first.acquire(files, entry);
    await until(tester, () => e1.phase == ThumbPhase.ready);
    await until(tester, () => store.knows(key));
    final firstReads = reads();
    expect(firstReads, 1);

    // A new cache (the app was restarted) over the same disk store.
    final second = grid(decoder);
    addTearDown(second.dispose);
    final e2 = second.acquire(files, entry);
    await until(tester, () => e2.phase == ThumbPhase.ready);
    expect(reads(), firstReads, reason: 'the second visit costs no radio');
    expect(e2.image!.width, 240);
  });

  testWidgets('a changed file is read again', (tester) async {
    final decoder = FakeDecoder();
    await decoder.prepare(tester, [(240, 180)]);
    final entry = _entry(_original);
    final key = PictureStore.thumbKey('m1', entry.path, entry.size!, _modified.millisecondsSinceEpoch);

    final first = grid(decoder);
    addTearDown(first.dispose);
    final e1 = first.acquire(files, entry);
    await until(tester, () => e1.phase == ThumbPhase.ready);
    await until(tester, () => store.knows(key));

    final second = grid(decoder);
    addTearDown(second.dispose);
    final e2 = second.acquire(files, _entry(_original, modified: _modified.add(const Duration(seconds: 5))));
    await until(tester, () => e2.phase == ThumbPhase.ready);
    expect(reads(), 2);
  });

  testWidgets('a damaged stored thumbnail is a miss: the file is read and the tile still draws', (tester) async {
    final decoder = FakeDecoder();
    await decoder.prepare(tester, [(240, 180)]);
    final entry = _entry(_original);
    final key = PictureStore.thumbKey('m1', entry.path, entry.size!, _modified.millisecondsSinceEpoch);
    await tester.runAsync(() => store.put(key, Uint8List.fromList([1, 2, 3])));

    final thumbs = grid(decoder);
    addTearDown(thumbs.dispose);
    final e = thumbs.acquire(files, entry);
    await until(tester, () => e.phase == ThumbPhase.ready);
    expect(reads(), 1);
  });

  testWidgets('without a machine id nothing is kept', (tester) async {
    final decoder = FakeDecoder();
    await decoder.prepare(tester, [(240, 180)]);
    final thumbs = grid(decoder);
    addTearDown(thumbs.dispose);
    final plain = RemoteFiles(FakeTransport()..fs = fs);
    final e = thumbs.acquire(plain, _entry(_original));
    await until(tester, () => e.phase == ThumbPhase.ready);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(await tester.runAsync(store.totalBytes), 0);
  });

  testWidgets('the list row and the grid tile of one file share one thumbnail and one read', (tester) async {
    final decoder = FakeDecoder();
    await decoder.prepare(tester, [(240, 180)]);
    final entry = _entry(_original);
    final loader = ThumbLoader(store: store, thumbnailer: (_) async => _thumb);

    final row = await load(tester, loader, entry);
    expect(row, _thumb, reason: 'the row holds the 240 px thumbnail, not the file');
    final key = PictureStore.thumbKey('m1', entry.path, entry.size!, _modified.millisecondsSinceEpoch);
    await until(tester, () => store.knows(key));

    final thumbs = grid(decoder);
    addTearDown(thumbs.dispose);
    final tile = thumbs.acquire(files, entry);
    await until(tester, () => tile.phase == ThumbPhase.ready);
    expect(reads(), 1, reason: 'one read of the original across both');

    // A new loader (restart): answered from disk.
    final again = await load(
      tester,
      ThumbLoader(store: store, thumbnailer: (_) async => fail('not needed')),
      entry,
    );
    expect(again, _thumb);
    expect(reads(), 1);
  });

  testWidgets('a picture the engine cannot shrink is handed to the row as it is, and not kept', (tester) async {
    final entry = _entry(_original);
    final loader = ThumbLoader(store: store, thumbnailer: (_) async => throw StateError('not an image'));
    final got = await load(tester, loader, entry);
    expect(got, _original);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(await tester.runAsync(store.totalBytes), 0);
  });
}
