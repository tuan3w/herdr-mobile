import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha1;
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
    for (final k in ['a', 'b', 'c']) {
      await first.put(k, _bytes(300)); // 900: under the cap
    }
    // The order after a restart is read from the files' stamps (what a `get`
    // writes), so set them: b longest ago, then c, then a.
    final now = DateTime.now();
    for (final (key, ago) in [('b', 30), ('c', 20), ('a', 10)]) {
      File('${dir.path}/${sha1.convert(utf8.encode(key))}').setLastModifiedSync(now.subtract(Duration(seconds: ago)));
    }

    final again = open(lowWater: 900);
    await again.put('d', _bytes(300)); // 1200: only the least recently used goes
    expect(await again.get('b'), isNull);
    for (final k in ['a', 'c', 'd']) {
      expect(await again.get(k), isNotNull, reason: k);
    }
  });

  test('a directory removed under the running app is made again: the next put is kept, the size is true', () async {
    final store = open();
    await store.put('a', _bytes(100));
    expect(await store.totalBytes(), 100);

    dir.deleteSync(recursive: true); // the system's Clear cache, or space freed by the OS
    expect(await store.totalBytes(), 0, reason: 'the files went with the directory');
    expect(store.knows('a'), isFalse);
    expect(await store.clear(), 0);

    await store.put('b', _bytes(50, 2));
    expect(await store.get('b'), _bytes(50, 2));
    expect(await store.totalBytes(), 50);
  });

  test('a put into a directory that is gone is kept too, without a look at the size first', () async {
    final store = open();
    await store.put('a', _bytes(100));
    dir.deleteSync(recursive: true);
    await store.put('b', _bytes(50, 2));
    expect(await store.get('b'), _bytes(50, 2));
    expect(store.knows('a'), isFalse);
    expect(await store.totalBytes(), 50);
  });

  test('keys carry what identifies the bytes', () {
    expect(DiskCache.fileKey('m', '/p', 1, 2), isNot(DiskCache.fileKey('m', '/p', 1, 3)));
    expect(DiskCache.fileKey('m', '/p', 1, 2), isNot(DiskCache.fileKey('n', '/p', 1, 2)));
    expect(DiskCache.fileKey('m', '/p', 1, 2), isNot(DiskCache.thumbKey('m', '/p', 1, 2)));
  });
}
