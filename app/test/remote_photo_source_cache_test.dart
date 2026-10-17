import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/picture_store.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';
import 'package:herdr_mobile/ui/features/photos/photo_item.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';

void main() {
  late Directory dir;
  late PictureStore store;
  late FakeFs fs;
  final modified = DateTime.utc(2026, 5, 20, 9, 30);
  final bytes = Uint8List.fromList(List.generate(3000, (i) => i % 251));

  setUp(() {
    dir = Directory.systemTemp.createTempSync('photo_source_');
    store = PictureStore(() async => dir);
    fs = FakeFs()..addFile('/p/a.jpg', bytes, modified: modified);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  RemotePhotoSource source({String machine = 'm1', int? size, DateTime? mtime, String path = '/p/a.jpg'}) =>
      RemotePhotoSource(
        RemoteFiles(FakeTransport()..fs = fs, machineId: machine),
        path,
        size: size ?? bytes.length,
        modified: mtime ?? modified,
        store: store,
      );

  int reads() => fs.calls.where((c) => c.startsWith('read')).length;

  Future<Uint8List> open(RemotePhotoSource s, {void Function(int)? onProgress}) async {
    final got = await s.read(onProgress: onProgress);
    await store.totalBytes(); // the store write is not awaited by the source
    return got;
  }

  test('the same file opened twice is read over SFTP once', () async {
    expect(await open(source()), bytes);
    final first = reads();
    expect(first, greaterThan(0));
    final progress = <int>[];
    expect(await open(source(), onProgress: progress.add), bytes);
    expect(reads(), first, reason: 'the second open is a local read');
    expect(progress, [bytes.length]);
  });

  test('a changed modified time or size reads again', () async {
    await open(source());
    final first = reads();
    await open(source(mtime: modified.add(const Duration(seconds: 1))));
    expect(reads(), greaterThan(first), reason: 'a newer mtime is another file');
    final second = reads();
    fs.addFile('/p/a.jpg', Uint8List(2000), modified: modified);
    await open(source(size: 2000));
    expect(reads(), greaterThan(second), reason: 'another size is another file');
  });

  test('two machines never share a stored file', () async {
    await open(source(machine: 'm1'));
    final first = reads();
    await open(source(machine: 'm2'));
    expect(reads(), greaterThan(first));
  });

  test('without a machine id the store is not used', () async {
    await open(source(machine: ''));
    expect(await store.totalBytes(), 0);
    final first = reads();
    await open(source(machine: ''));
    expect(reads(), 2 * first);
  });

  test('a stored copy of another length is read again', () async {
    final key = PictureStore.fileKey('m1', '/p/a.jpg', bytes.length, modified.millisecondsSinceEpoch);
    await store.put(key, Uint8List(10));
    expect(await open(source()), bytes);
    expect(reads(), greaterThan(0));
  });

  test('an unknown size is asked for once, and a stored file then needs no read', () async {
    final s = RemotePhotoSource(
      RemoteFiles(FakeTransport()..fs = fs, machineId: 'm1'),
      '/p/a.jpg',
      size: null,
      store: store,
    );
    expect(await open(s), bytes);
    final first = reads();
    expect(await open(s), bytes);
    expect(reads(), first);
    expect(fs.calls.where((c) => c.startsWith('stat')).length, 2);
  });

  test('a file larger than the store keeps is read every time', () async {
    final small = PictureStore(() async => dir, maxEntryBytes: 1000);
    final s = RemotePhotoSource(
      RemoteFiles(FakeTransport()..fs = fs, machineId: 'm1'),
      '/p/a.jpg',
      size: bytes.length,
      modified: modified,
      store: small,
    );
    await s.read();
    final first = reads();
    await s.read();
    expect(reads(), 2 * first);
  });
}
