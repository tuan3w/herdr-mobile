import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/disk_cache.dart';

Uint8List _bytes(int n, [int fill = 1]) => Uint8List(n)..fillRange(0, n, fill);

void main() {
  late Directory dir;

  DiskCache open({int maxBytes = 1000, int lowWater = 600, int maxEntryBytes = 400}) =>
      DiskCache(() async => dir, maxBytes: maxBytes, lowWater: lowWater, maxEntryBytes: maxEntryBytes);

  setUp(() => dir = Directory.systemTemp.createTempSync('disk_cache_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('keeps what it is given and says so', () async {
    final store = open();
    await store.put('a', _bytes(100, 7));
    expect(await store.get('a'), _bytes(100, 7));
    expect(store.knows('a'), isTrue);
    expect(store.knows('b'), isFalse);
    expect(await store.get('b'), isNull);
    expect(await store.totalBytes(), 100);
  });

  test('a picture over the per-entry limit, or empty, is not kept', () async {
    final store = open();
    await store.put('big', _bytes(401));
    await store.put('empty', Uint8List(0));
    expect(await store.get('big'), isNull);
    expect(await store.get('empty'), isNull);
    expect(await store.totalBytes(), 0);
  });

  test('past the cap the least recently used go, down to the low water mark', () async {
    final store = open();
    for (final k in ['a', 'b', 'c', 'd']) {
      await store.put(k, _bytes(300));
      if (k == 'c') {
        // Three entries: 900, under the cap. Using the oldest saves it.
        expect(await store.get('a'), isNotNull);
      }
    }
    // The fourth put reached 1200 > 1000: trim to <= 600 by dropping the
    // least recently used first: b, then c; a was used after them.
    expect(await store.totalBytes(), 600);
    expect(await store.get('b'), isNull);
    expect(await store.get('c'), isNull);
    expect(await store.get('a'), isNotNull);
    expect(await store.get('d'), isNotNull);
  });

  test('clear removes everything and reports the bytes freed', () async {
    final store = open();
    await store.put('a', _bytes(100));
    await store.put('b', _bytes(50));
    expect(await store.clear(), 150);
    expect(await store.get('a'), isNull);
    expect(store.knows('b'), isFalse);
    expect(await store.totalBytes(), 0);
    expect(await store.clear(), 0);
  });

  test('a directory that cannot be used never throws', () async {
    final file = File('${dir.path}/blocker')..writeAsStringSync('x');
    final store = DiskCache(() async => Directory('${file.path}/under'));
    await store.put('a', _bytes(10));
    expect(await store.get('a'), isNull);
    expect(await store.totalBytes(), 0);
    expect(await store.clear(), 0);
  });

  test('a new store on the same directory sees the files, and drops a stale temp file', () async {
    await (open()).put('a', _bytes(120, 3));
    final stale = File('${dir.path}/dead.tmp1-0')..writeAsBytesSync([1, 2, 3]);
    stale.setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 5)));
    final fresh = File('${dir.path}/live.tmp1-1')..writeAsBytesSync([1, 2, 3]);

    final again = open();
    await again.ready;
    expect(again.knows('a'), isTrue);
    expect(await again.get('a'), _bytes(120, 3));
    expect(stale.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
    expect(await again.totalBytes(), 120);
  });

  test('a restart keeps the order of use', () async {
    final first = open();
    await first.put('a', _bytes(300));
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await first.put('b', _bytes(300));
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(await first.get('a'), isNotNull); // a is now the newest

    final again = open(lowWater: 900);
    await again.put('c', _bytes(300));
    await again.put('d', _bytes(300)); // 1200: trims only b, the oldest
    expect(await again.get('b'), isNull);
    expect(await again.get('a'), isNotNull);
  });

  test('defaults: 300 MB of 10 MB pictures end under 192 MB with the newest kept', () async {
    final store = DiskCache(() async => dir);
    final ten = _bytes(10 << 20);
    for (var i = 0; i < 30; i++) {
      await store.put('k$i', ten);
    }
    expect(await store.totalBytes(), lessThanOrEqualTo(192 << 20));
    expect(store.knows('k29'), isTrue);
    expect(store.knows('k0'), isFalse);
  });

  test('keys carry what identifies the bytes', () {
    expect(DiskCache.fileKey('m', '/p', 1, 2), isNot(DiskCache.fileKey('m', '/p', 1, 3)));
    expect(DiskCache.fileKey('m', '/p', 1, 2), isNot(DiskCache.fileKey('n', '/p', 1, 2)));
    expect(DiskCache.fileKey('m', '/p', 1, 2), isNot(DiskCache.thumbKey('m', '/p', 1, 2)));
  });
}
