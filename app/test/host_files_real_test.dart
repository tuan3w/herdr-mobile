@TestOn('linux || mac-os')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/app_info.dart';
import 'package:herdr_mobile/data/host/host_files.dart';
import 'package:herdr_mobile/data/host/host_link.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/models/remote_search.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';
import 'package:herdr_mobile/ui/features/files/file_thumb.dart';
import 'package:image/image.dart' as img;

import 'support/host_serve.dart';

// `HostFiles.thumbnail` and `HostFiles.search` against the REAL `herdr-host
// serve`: real JPEGs and trees on disk, what the host makes of them, and what
// the wire carried. The mapping and error degradation against a scripted host
// are in host_files_search_thumb_test.dart.
//
// Needs a host binary that has fs.thumb and fs.search:
// `cd rust && cargo build --release -p host`, or HERDR_HOST_BIN=/path/to/herdr-host.

/// A photo-like JPEG: a smooth gradient with grain, so it compresses the way a
/// camera picture does (several MB at 12 Mpx; here about 3 MB).
Uint8List _photo({int w = 2400, int h = 1800, int quality = 88, int? orientation}) {
  final image = img.Image(width: w, height: h);
  var seed = 12345;
  for (final p in image) {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
    final grain = (seed >> 16) % 40;
    p.setRgb(
      ((p.x * 255) ~/ w + grain) % 256,
      ((p.y * 255) ~/ h + grain) % 256,
      (((p.x + p.y) * 255) ~/ (w + h) + grain) % 256,
    );
  }
  if (orientation != null) image.exif.imageIfd.orientation = orientation;
  return Uint8List.fromList(img.encodeJpg(image, quality: quality));
}

/// Counts what the host writes to the phone: the bytes that would cross the radio.
class _Counting implements HostProcess {
  _Counting(this.inner);

  final SpyHostProcess inner;
  var received = 0;

  @override
  Stream<Uint8List> get stdout => inner.stdout.map((b) {
    received += b.length;
    return b;
  });

  @override
  Stream<Uint8List> get stderr => inner.stderr;

  @override
  StreamSink<Uint8List> get stdin => inner.stdin;

  @override
  Future<void> get done => inner.done;

  @override
  int? get exitCode => inner.exitCode;

  @override
  void close() => inner.close();
}

bool get _isRoot => Process.runSync('id', ['-u']).stdout.toString().trim() == '0';

void main() {
  final skip = hostBinarySkip();
  late ServedHost host;
  late _Counting wire;
  late HostLink link;
  late HostFiles files;
  late String tree;

  setUp(() async {
    host = ServedHost();
    tree = '${host.home}/tree';
    Directory(tree).createSync();
    if (skip == null) {
      wire = _Counting(await host.start());
      link = await HostLink.connect(wire, version: appVersion);
      files = HostFiles(link);
    }
  });
  tearDown(() => host.dispose());

  Future<HostException> rawFailure(String method, Map<String, Object?> args) async {
    final s = link.open('fs', method, args);
    final sub = s.messages.listen((_) {}, onError: (Object _) {});
    try {
      return (await s.done).error ?? fail('expected fs.$method to fail');
    } finally {
      await sub.cancel();
    }
  }

  group('thumbnail', () {
    test('a 3 MB photo comes back as a small JPEG at the size asked, and the wire carried only that', () async {
      final photo = File('$tree/IMG_0001.jpg')..writeAsBytesSync(_photo());
      expect(photo.lengthSync(), greaterThan(2 * 1024 * 1024), reason: 'over the 2 MB the grid used to refuse');
      final stat = await files.stat(photo.path);
      final before = wire.received;

      final bytes = await files.thumbnail(photo.path, maxPx: 256, expect: stat);

      final onWire = wire.received - before;
      expect(bytes, isNotNull);
      final decoded = img.decodeJpg(bytes!)!;
      expect((decoded.width, decoded.height), (256, 192), reason: 'longest edge 256, aspect kept');
      expect(bytes.length, lessThan(photo.lengthSync() ~/ 20));
      expect(onWire, lessThan(bytes.length + 2048), reason: 'the JPEG plus a few frame headers');
      // ignore: avoid_print
      print(
        'MEASURED fs.thumb 256px: source ${photo.lengthSync()} B -> thumbnail ${bytes.length} B, '
        '$onWire B received over the wire',
      );
    });

    test('the same file read the way thumbnails used to be made carries the whole file', () async {
      final photo = File('$tree/IMG_0002.jpg')..writeAsBytesSync(_photo(w: 1600, h: 1200, quality: 90));
      final size = photo.lengthSync();
      final before = wire.received;

      final got = await files.read(photo.path, 0, size);

      final onWire = wire.received - before;
      expect(got, hasLength(size));
      expect(onWire, greaterThan(size));
      // ignore: avoid_print
      print('MEASURED fs.read of the whole file: source $size B -> $onWire B received over the wire');
    });

    test('a picture smaller than the size asked is not enlarged', () async {
      final small = File('$tree/icon.png')..writeAsBytesSync(img.encodePng(img.Image(width: 100, height: 50)));

      final bytes = await files.thumbnail(small.path, maxPx: 512);

      final decoded = img.decodeJpg(bytes!)!;
      expect((decoded.width, decoded.height), (100, 50));
    });

    test('EXIF orientation is applied: a landscape photo turned by the camera is a portrait thumbnail', () async {
      final turned = File('$tree/turned.jpg')..writeAsBytesSync(_photo(w: 800, h: 600, orientation: 6));

      final bytes = await files.thumbnail(turned.path, maxPx: 200);

      final decoded = img.decodeJpg(bytes!)!;
      expect((decoded.width, decoded.height), (150, 200), reason: 'the thumbnail is upright');
    });

    test('the edge is clamped to what the host allows', () async {
      final photo = File('$tree/big.jpg')..writeAsBytesSync(_photo(w: 1500, h: 1000, quality: 60));

      final bytes = await files.thumbnail(photo.path, maxPx: 5000);

      final decoded = img.decodeJpg(bytes!)!;
      expect(decoded.width, 1024, reason: 'at most 1024 px');
    });

    test('a changed file is refused before anything is decoded: null, and the host says `changed`', () async {
      final photo = File('$tree/a.jpg')..writeAsBytesSync(_photo(w: 400, h: 300));
      final seen = await files.stat(photo.path);
      photo.writeAsBytesSync(_photo(w: 410, h: 300));

      expect(await files.thumbnail(photo.path, expect: seen), isNull);
      final raw = await rawFailure('thumb', {
        'path': photo.path,
        'if_match': {'size': seen.size, 'mtime_ms': seen.modified!.millisecondsSinceEpoch},
      });
      expect(raw.code, 'changed');
    });

    test('what is not a picture, is not there, or is a folder is null, with the host\u2019s own words', () async {
      File('$tree/notes.txt').writeAsStringSync('not an image');
      File('$tree/fake.png').writeAsStringSync('named like one');
      Directory('$tree/folder').createSync();

      expect(await files.thumbnail('$tree/notes.txt'), isNull);
      expect(await files.thumbnail('$tree/fake.png'), isNull);
      expect(await files.thumbnail('$tree/none.jpg'), isNull);
      expect(await files.thumbnail('$tree/folder'), isNull);

      final unsupported = await rawFailure('thumb', {'path': '$tree/notes.txt'});
      expect(unsupported.code, 'failed');
      expect(unsupported.message, startsWith('unsupported image'));
      expect((await rawFailure('thumb', {'path': '$tree/none.jpg'})).code, 'not_found');
      expect((await rawFailure('thumb', {'path': '$tree/folder'})).code, 'not_a_file');
    });

    test('permission denied is null', () async {
      final f = File('$tree/locked.jpg')..writeAsBytesSync(_photo(w: 100, h: 100));
      Process.runSync('chmod', ['000', f.path]);

      expect(await files.thumbnail(f.path), isNull);
      expect((await rawFailure('thumb', {'path': f.path})).code, 'permission');
    }, skip: skip ?? (_isRoot ? 'root can read anything' : null));

    test('a thumbnail cancelled at once leaves the link working', () async {
      final photo = File('$tree/c.jpg')..writeAsBytesSync(_photo());
      final stop = Completer<void>()..complete();

      expect(await files.thumbnail(photo.path, cancelled: stop.future), isNull);

      expect((await files.stat(photo.path)).size, photo.lengthSync(), reason: 'the connection carries on');
    });

    test('a dozen thumbnails at once on the one link all come back', () async {
      final paths = [
        for (var i = 0; i < 12; i++)
          (File('$tree/p$i.jpg')..writeAsBytesSync(_photo(w: 600 + i, h: 400, quality: 80))).path,
      ];

      final all = await Future.wait([for (final p in paths) files.thumbnail(p, maxPx: 128)]);

      expect(all.every((b) => b != null && img.decodeJpg(b)!.width == 128), isTrue);
    });
  }, skip: skip);

  group('search', () {
    Future<(List<RemoteEntry>, FileSearchDone)> run(FileSearchSpec spec) async {
      final events = await files.search(spec).toList();
      return (
        [for (final b in events.whereType<FileSearchBatch>()) ...b.entries],
        events.whereType<FileSearchDone>().single,
      );
    }

    void file(String rel, [String content = 'x']) {
      final f = File('$tree/$rel')..createSync(recursive: true);
      f.writeAsStringSync(content);
    }

    test('names match as a case-insensitive part; shallow ones first; entries carry size, time and kind', () async {
      file('top-Shot.txt', 'hello');
      file('a/Shots/deep.txt');
      file('a/Shots/MYSHOT.png', 'abc');
      file('b/unrelated.md');

      final (found, done) = await run(FileSearchSpec(root: tree, query: 'sHoT'));

      expect(found.map((e) => e.name).toList(), ['top-Shot.txt', 'Shots', 'MYSHOT.png']);
      final top = found.first;
      expect(top.path, '$tree/top-Shot.txt');
      expect(top.size, 5);
      expect(top.kind, RemoteEntryKind.file);
      expect(top.modified, isNotNull);
      expect(found[1].isDirectory, isTrue);
      expect(done.truncated, isFalse);
      expect(done.scanned, greaterThan(4));
    });

    test(
      'kind narrows it; hidden and ignored names follow the defaults, and no ignore list searches everything',
      () async {
        file('src/build.rs');
        file('build/out.o');
        file('node_modules/pkg/build.js');
        file('.hidden/build.txt');

        final plain = await run(FileSearchSpec(root: tree, query: 'build'));
        expect(plain.$1.map((e) => e.path).toList(), [
          '$tree/src/build.rs',
        ], reason: 'the build folder is ignored; so are dot names');
        final dirs = await run(FileSearchSpec(root: tree, query: 'build', kind: FileSearchKind.dir, ignore: const []));
        expect(dirs.$1.map((e) => e.name).toList(), ['build']);
        final all = await run(FileSearchSpec(root: tree, query: 'build', hidden: true, ignore: const []));
        expect(all.$1.map((e) => e.path).toSet(), {
          '$tree/build',
          '$tree/src/build.rs',
          '$tree/.hidden/build.txt',
          '$tree/node_modules/pkg/build.js',
        });
      },
    );

    test('an empty query with a time window finds what changed lately and nothing older', () async {
      file('fresh.log');
      file('old.log');
      File('$tree/old.log').setLastModifiedSync(DateTime.now().subtract(const Duration(days: 3)));

      final (found, _) = await run(FileSearchSpec(root: tree, modifiedWithin: const Duration(hours: 1)));

      expect(found.map((e) => e.name).toList(), ['fresh.log']);
    });

    test('a symbolic link is reported as a link and never entered, even a loop', () async {
      file('real/inside-x.txt');
      Link('$tree/loop-x').createSync(tree);
      Link('$tree/to-real-x').createSync('$tree/real');

      final (found, done) = await run(FileSearchSpec(root: tree, query: 'x'));

      final names = found.map((e) => e.name).toList();
      expect(names, containsAll(['loop-x', 'to-real-x', 'inside-x.txt']));
      expect(names.where((n) => n == 'inside-x.txt'), hasLength(1), reason: 'reached once, by its real folder only');
      expect(done.truncated, isFalse);
      final loop = found.firstWhere((e) => e.name == 'loop-x');
      expect(loop.kind, RemoteEntryKind.link);
      expect(loop.isDirectory, isTrue, reason: 'resolved by a stat: it points at a folder');
    });

    test('the result cap says there may be more', () async {
      for (var i = 0; i < 30; i++) {
        file('x$i.txt');
      }

      final (found, done) = await run(FileSearchSpec(root: tree, query: 'x', maxResults: 10));

      expect(found, hasLength(10));
      expect(done.truncated, isTrue);
    });

    test('depth: the entries of the root are depth 1', () async {
      file('top-x');
      file('a/one-x');
      file('a/b/two-x');

      expect((await run(FileSearchSpec(root: tree, query: 'x', maxDepth: 1))).$1.map((e) => e.name).toList(), [
        'top-x',
      ]);
      expect((await run(FileSearchSpec(root: tree, query: 'x', maxDepth: 2))).$1.map((e) => e.name).toSet(), {
        'top-x',
        'one-x',
      });
    });

    test('a folder that cannot be read is skipped and counted', () async {
      file('open/x-ok.txt');
      file('locked/x-hidden.txt');
      Process.runSync('chmod', ['000', '$tree/locked']);

      final (found, done) = await run(FileSearchSpec(root: tree, query: 'x'));

      expect(found.map((e) => e.name).toList(), ['x-ok.txt']);
      expect(done.skippedDirs, 1);
    }, skip: skip ?? (_isRoot ? 'root can read anything' : null));

    test('the root missing, a file or refused fails like a listing', () async {
      file('plain.txt');
      Directory('$tree/closed').createSync();

      await expectLater(
        files.search(FileSearchSpec(root: '$tree/none', query: 'x')).toList(),
        throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.notFound)),
      );
      await expectLater(
        files.search(FileSearchSpec(root: '$tree/plain.txt', query: 'x')).toList(),
        throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.notADirectory)),
      );
    });

    test('`~` and a relative root start at the home folder', () async {
      file('home-x.txt');

      expect((await run(const FileSearchSpec(root: '~/tree', query: 'x'))).$1.map((e) => e.name).toList(), [
        'home-x.txt',
      ]);
      expect((await run(const FileSearchSpec(root: 'tree', query: 'x'))).$1.map((e) => e.name).toList(), [
        'home-x.txt',
      ]);
    });

    test('a search cancelled after its first batch leaves the link working', () async {
      for (var i = 0; i < 400; i++) {
        file('d${i % 20}/x$i.txt');
      }
      final first = Completer<void>();
      final sub = files.search(FileSearchSpec(root: tree, query: 'x')).listen((e) {
        if (!first.isCompleted) first.complete();
      });
      await first.future;

      await sub.cancel();

      expect((await files.stat(tree)).isDirectory, isTrue, reason: 'the connection carries on');
      expect((await run(FileSearchSpec(root: tree, query: 'x0'))).$1, isNotEmpty);
    });

    test('a big tree streams in batches of at most 100, each result once', () async {
      for (var i = 0; i < 700; i++) {
        file('d${i % 35}/hit-$i.txt');
      }
      final sizes = <int>[];
      final paths = <String>[];
      FileSearchDone? done;
      await for (final e in files.search(FileSearchSpec(root: tree, query: 'hit', maxResults: 800))) {
        switch (e) {
          case FileSearchBatch(:final entries):
            sizes.add(entries.length);
            paths.addAll(entries.map((x) => x.path));
          case FileSearchDone():
            done = e;
        }
      }

      expect(paths.toSet(), hasLength(700));
      expect(sizes.every((n) => n <= 100), isTrue, reason: '$sizes');
      expect(sizes.length, greaterThanOrEqualTo(7));
      expect(done!.truncated, isFalse);
    });
  }, skip: skip);

  group('the Files screen\u2019s thumbnail loader, over the real host', () {
    test('a row for a 3 MB photo costs a few KB, and the photo itself is never read', () async {
      final photo = File('$tree/IMG_0001.jpg')..writeAsBytesSync(_photo());
      final remote = RemoteFiles(HostFilesTransport(files));
      final entry = (await remote.list(tree)).single;
      expect(ThumbLoader.eligible(entry), isTrue, reason: '${photo.lengthSync()} B: far over what a row reads itself');
      final before = wire.received;

      final bytes = await ThumbLoader().load(remote, entry, cancelled: () => false);

      final onWire = wire.received - before;
      expect(bytes, isNotNull);
      expect(img.decodeJpg(bytes!)!.width, 256);
      expect(onWire, lessThan(64 * 1024));
      expect(wire.inner.argsOf('fs.read'), isEmpty, reason: 'no byte of the photo was fetched');
      // ignore: avoid_print
      print('MEASURED loader, one row, ${photo.lengthSync()} B photo: $onWire B received, 0 fs.read');
    });

    test('twelve rows share the link three at a time and all get their picture', () async {
      for (var i = 0; i < 12; i++) {
        File('$tree/p$i.jpg').writeAsBytesSync(_photo(w: 1200 + i, h: 800, quality: 85));
      }
      final remote = RemoteFiles(HostFilesTransport(files));
      final entries = await remote.list(tree);
      final loader = ThumbLoader();
      final before = wire.received;

      final all = await Future.wait([for (final e in entries) loader.load(remote, e, cancelled: () => false)]);

      expect(all.every((b) => b != null && img.decodeJpg(b) != null), isTrue);
      expect(wire.received - before, lessThan(256 * 1024));
      expect(wire.inner.argsOf('fs.read'), isEmpty);
    });
  }, skip: skip);
}
