import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/services/image_decode.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/files/file_browser_screen.dart';
import 'package:herdr_mobile/ui/features/files/file_row.dart';
import 'package:herdr_mobile/ui/features/files/photo_grid.dart';
import 'package:herdr_mobile/ui/features/files/photo_thumbs.dart';
import 'package:herdr_mobile/ui/features/photos/photo_viewer.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';
import 'support/files_support.dart';
import 'support/shot.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Files whose reads wait at a gate, so a test sees what is in flight.
class _GatedFiles extends RemoteFiles {
  _GatedFiles([Map<String, int>? sizes]) : sizes = sizes ?? {}, super(FakeTransport());

  /// Bytes each path holds (reads return that many, at most `length`).
  final Map<String, int> sizes;

  /// Paths in the order their reads began.
  final reads = <String>[];
  final lengths = <String, int>{};
  final failing = <String>{};
  var inFlight = 0;
  var maxInFlight = 0;
  var gated = true;
  final _gates = <String, Completer<void>>{};

  Completer<void> _gate(String path) => _gates.putIfAbsent(path, Completer.new);

  /// Lets the read of [path] finish (now, or when it begins).
  void open(String path) {
    final gate = _gate(path);
    if (!gate.isCompleted) gate.complete();
  }

  void openAll() {
    gated = false;
    for (final g in _gates.values) {
      if (!g.isCompleted) g.complete();
    }
  }

  @override
  Future<Uint8List> read(String path, {int offset = 0, int length = remoteReadCap}) async {
    reads.add(path);
    lengths[path] = length;
    inFlight++;
    maxInFlight = math.max(maxInFlight, inFlight);
    try {
      if (gated) await _gate(path).future;
      if (failing.contains(path)) {
        throw RemoteFileException(RemoteFileErrorKind.network, 'Connection lost', path: path);
      }
      return Uint8List(math.min(length, sizes[path] ?? 0));
    } finally {
      inFlight--;
    }
  }
}

Future<ui.Image> _pixel() {
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(Uint8List(4 * 4 * 4), 4, 4, ui.PixelFormat.rgba8888, done.complete);
  return done.future;
}

/// A decoder that makes a fresh 4 x 4 image per call, in the order of calls.
class _FakeDecoder {
  final made = <ui.Image>[];
  var calls = 0;

  Future<DecodedImage> call(Uint8List bytes, {required int maxWidth, required int maxHeight}) async {
    calls++;
    final image = await _pixel();
    made.add(image);
    return DecodedImage(image: image, width: 4000, height: 3000, downscaled: true);
  }
}

RemoteEntry _entry(String name, int? size, {DateTime? modified, String dir = '/p'}) => RemoteEntry(
      name: name,
      path: '$dir/$name',
      kind: RemoteEntryKind.file,
      resolvedKind: RemoteEntryKind.file,
      size: size,
      modified: modified ?? DateTime.utc(2026, 5, 20),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PhotoThumbs', () {
    late _GatedFiles files;
    late _FakeDecoder decoder;

    PhotoThumbs make({int maxConcurrent = 3, int autoLimit = 1000, int capacity = 120}) => PhotoThumbs(
          maxConcurrent: maxConcurrent,
          autoLimit: autoLimit,
          capacity: capacity,
          decoder: decoder.call,
        );

    setUp(() {
      files = _GatedFiles();
      decoder = _FakeDecoder();
    });

    /// [n] entries `p0..` of [size] bytes each, registered with the files.
    List<RemoteEntry> batch(int n, {int size = 100}) => [
          for (var i = 0; i < n; i++)
            () {
              final e = _entry('p$i.png', size);
              files.sizes[e.path] = size;
              return e;
            }(),
        ];

    test('never more than maxConcurrent reads are in flight', () async {
      final thumbs = make();
      final entries = batch(9);
      final held = [for (final e in entries) thumbs.acquire(files, e)];
      await flush();

      expect(files.inFlight, 3, reason: 'nine tiles asked, three reads began');
      expect(thumbs.inFlight, 3);
      expect(thumbs.queued, 6);

      // Let them through one at a time: a finished read starts the next, and
      // the count never passes three.
      for (var done = 0; done < 9; done++) {
        files.open(files.reads[done]);
        await flush();
        expect(files.inFlight, lessThanOrEqualTo(3));
      }
      files.openAll();
      await flush();

      expect(files.maxInFlight, 3);
      expect(files.reads.toSet(), entries.map((e) => e.path).toSet());
      expect(held.every((h) => h.phase == ThumbPhase.ready), isTrue);
      for (final h in held) {
        thumbs.release(h);
      }
      thumbs.dispose();
    });

    test('the smallest files are read first, whatever order the tiles were built in', () async {
      final thumbs = make(maxConcurrent: 1);
      final sizes = {'a': 900, 'b': 100, 'c': 500, 'd': 300, 'e': 700};
      final held = <ThumbEntry>[];
      for (final MapEntry(key: name, value: size) in sizes.entries) {
        final e = _entry('$name.png', size);
        files.sizes[e.path] = size;
        held.add(thumbs.acquire(files, e));
      }
      // An unknown size could be anything: after the known ones.
      final unknown = _entry('z.png', null);
      files.sizes[unknown.path] = 50;
      held.add(thumbs.acquire(files, unknown));

      for (var i = 0; i < 6; i++) {
        await flush();
        files.open(files.reads.last);
      }
      await flush();

      expect(files.reads, ['/p/b.png', '/p/d.png', '/p/c.png', '/p/e.png', '/p/a.png', '/p/z.png']);
      for (final h in held) {
        thumbs.release(h);
      }
      thumbs.dispose();
    });

    test('a file over the limit is never read on its own: it is skipped, and keeps its size', () async {
      final thumbs = make(autoLimit: 1000);
      final big = _entry('huge.png', 5000);
      final small = _entry('small.png', 200);
      files.sizes[small.path] = 200;
      final hugeHold = thumbs.acquire(files, big);
      final smallHold = thumbs.acquire(files, small);
      expect(hugeHold.phase, ThumbPhase.tooBig, reason: 'known from the listing, before any read');
      await flush();
      files.openAll();
      await flush();

      expect(files.reads, ['/p/small.png']);
      expect(hugeHold.phase, ThumbPhase.tooBig);
      expect(hugeHold.image, isNull);
      expect(hugeHold.size, 5000);
      expect(smallHold.phase, ThumbPhase.ready);
      thumbs.dispose();
    });

    test('a file of unknown size is read one byte past the limit and skipped when it is longer', () async {
      final thumbs = make(autoLimit: 1000);
      final e = _entry('mystery.png', null);
      files.sizes[e.path] = 4000;
      final held = thumbs.acquire(files, e);
      await flush();
      files.openAll();
      await flush();

      expect(files.lengths[e.path], 1001);
      expect(held.phase, ThumbPhase.tooBig);
      expect(decoder.calls, 0, reason: 'nothing to decode: it was not a thumbnail-sized file');
      thumbs.dispose();
    });

    test('a tile released before its turn is dequeued and its file is never read', () async {
      final thumbs = make(maxConcurrent: 1);
      final entries = batch(4);
      final held = [for (final e in entries) thumbs.acquire(files, e)];
      await flush();
      expect(files.reads, [entries[0].path]);
      expect(thumbs.queued, 3);

      thumbs.release(held[1]);
      thumbs.release(held[2]);
      expect(thumbs.queued, 1, reason: 'the two scrolled away are out of the queue');

      files.openAll();
      await flush();

      expect(files.reads, [entries[0].path, entries[3].path]);
      thumbs.release(held[0]);
      thumbs.release(held[3]);
      thumbs.dispose();
    });

    test('releasing a load in flight frees its slot at once; its late result is thrown away', () async {
      final thumbs = make(maxConcurrent: 1);
      final entries = batch(2);
      final first = thumbs.acquire(files, entries[0]);
      final second = thumbs.acquire(files, entries[1]);
      await flush();
      expect(files.reads, [entries[0].path]);
      expect(thumbs.inFlight, 1);

      thumbs.release(first);
      expect(thumbs.inFlight, 0, reason: 'the slot is free before the read has finished');
      await flush();
      expect(files.reads, [entries[0].path, entries[1].path], reason: 'the next tile begins at once');

      // The abandoned read lands: nothing is decoded for it.
      files.open(entries[0].path);
      files.open(entries[1].path);
      await flush();
      expect(decoder.calls, 1);
      expect(second.phase, ThumbPhase.ready);
      expect(first.image, isNull);
      expect(thumbs.inFlight, 0);

      // Asked for again later, it loads.
      final again = thumbs.acquire(files, entries[0]);
      files.openAll();
      await flush();
      expect(again.phase, ThumbPhase.ready);
      thumbs.release(again);
      thumbs.release(second);
      thumbs.dispose();
    });

    test('the oldest unheld thumbnails are disposed past capacity, and a held one never is', () async {
      final thumbs = make(capacity: 2);
      files.openAll();
      final entries = batch(4);
      final held = [for (final e in entries) thumbs.acquire(files, e)];
      await flush();
      final images = [for (final h in held) h.image!];
      expect(images.length, 4);

      thumbs.release(held[1]);
      thumbs.release(held[2]);
      expect(images.any((i) => i.debugDisposed), isFalse, reason: 'two unheld fit in the cache');
      thumbs.release(held[3]);
      expect(images[1].debugDisposed, isTrue, reason: 'the least recently used unheld one went');
      expect(images[0].debugDisposed, isFalse, reason: 'held by a tile that draws it');
      expect(images[2].debugDisposed, isFalse);
      expect(images[3].debugDisposed, isFalse);
      expect(thumbs.peek(entries[1].path), isNull);

      thumbs.release(held[0]);
      expect(images[2].debugDisposed, isTrue);
      expect(images[0].debugDisposed, isFalse);
      expect(thumbs.length, 2);

      thumbs.dispose();
      expect(images.every((i) => i.debugDisposed), isTrue, reason: 'disposing the cache frees the rest');
    });

    test('peek is null until a thumbnail is ready, then a clone the caller owns', () async {
      final thumbs = make(capacity: 1);
      final e = _entry('a.png', 100);
      files.sizes[e.path] = 100;
      expect(thumbs.peek(e.path), isNull);
      final held = thumbs.acquire(files, e);
      await flush();
      expect(thumbs.peek(e.path), isNull, reason: 'still loading');

      files.openAll();
      await flush();
      final clone = thumbs.peek(e.path)!;
      expect(clone.isCloneOf(held.image!), isTrue);
      expect(clone.width, 4);
      clone.dispose();
      expect(held.image!.debugDisposed, isFalse, reason: 'the clone is the caller\'s to dispose');

      // A clone outlives the cache entry (the viewer may still show it).
      final survivor = thumbs.peek(e.path)!;
      thumbs.release(held);
      thumbs.release(thumbs.acquire(files, _entry('b.png', 100)));
      expect(thumbs.peek(e.path), isNull, reason: 'evicted');
      expect(survivor.debugDisposed, isFalse);
      expect(survivor.width, 4);
      survivor.dispose();
      thumbs.dispose();
    });

    test('a changed size or modified time is a different picture: no stale thumbnail is served', () async {
      final thumbs = make();
      files.openAll();
      final v1 = _entry('a.png', 100, modified: DateTime.utc(2026, 1, 1));
      files.sizes[v1.path] = 100;
      final first = thumbs.acquire(files, v1);
      await flush();
      final firstImage = first.image!;
      thumbs.release(first);
      expect(thumbs.peek(v1.path), isNotNull);

      // Same size, newer file.
      final v2 = _entry('a.png', 100, modified: DateTime.utc(2026, 2, 1));
      final second = thumbs.acquire(files, v2);
      expect(identical(second, first), isFalse);
      expect(second.phase, ThumbPhase.queued);
      expect(thumbs.peek(v1.path), isNull, reason: 'the old picture is gone before the new one is ready');
      expect(firstImage.debugDisposed, isTrue);
      await flush();
      expect(files.reads, [v1.path, v1.path], reason: 'read again');
      expect(second.phase, ThumbPhase.ready);
      thumbs.release(second);

      // Another size, same time.
      final v3 = _entry('a.png', 150, modified: DateTime.utc(2026, 2, 1));
      files.sizes[v3.path] = 150;
      final third = thumbs.acquire(files, v3);
      expect(third.phase, ThumbPhase.queued);
      await flush();
      expect(files.reads.length, 3);

      // The same file again is served from the cache without a read.
      thumbs.release(third);
      final same = thumbs.acquire(files, v3);
      expect(same.phase, ThumbPhase.ready);
      await flush();
      expect(files.reads.length, 3);
      thumbs.release(same);
      thumbs.dispose();
    });

    test('a changed file replaces the entry a tile still holds without disturbing that tile', () async {
      final thumbs = make();
      files.openAll();
      final v1 = _entry('a.png', 100, modified: DateTime.utc(2026, 1, 1));
      files.sizes[v1.path] = 100;
      final held = thumbs.acquire(files, v1);
      await flush();
      final oldImage = held.image!;

      final v2 = _entry('a.png', 100, modified: DateTime.utc(2026, 3, 1));
      final fresh = thumbs.acquire(files, v2);
      expect(oldImage.debugDisposed, isFalse, reason: 'its tile has not let go yet');
      thumbs.release(held);
      expect(oldImage.debugDisposed, isTrue, reason: 'disposed when its last holder leaves');
      await flush();
      expect(fresh.phase, ThumbPhase.ready);
      thumbs.release(fresh);
      thumbs.dispose();
    });

    test('a read that fails (or a file that is no picture) is a failed tile, never a throw; asking again retries', () async {
      final thumbs = make();
      files.openAll();
      final broken = _entry('broken.png', 100);
      files.sizes[broken.path] = 100;
      files.failing.add(broken.path);
      final empty = _entry('empty.png', 0);
      final held = thumbs.acquire(files, broken);
      final emptyHeld = thumbs.acquire(files, empty);
      await flush();

      expect(held.phase, ThumbPhase.failed);
      expect(emptyHeld.phase, ThumbPhase.failed);
      expect(files.reads, [broken.path], reason: 'an empty file has nothing to read');
      expect(thumbs.inFlight, 0);
      thumbs.release(held);

      files.failing.clear();
      final retry = thumbs.acquire(files, broken);
      await flush();
      expect(retry.phase, ThumbPhase.ready);
      thumbs.release(retry);
      thumbs.release(emptyHeld);
      thumbs.dispose();
    });
  });

  group('PhotoGrid', () {
    setUpAll(loadAppFonts);

    late _GatedFiles files;
    late _FakeDecoder decoder;
    late PhotoThumbs thumbs;

    setUp(() {
      files = _GatedFiles();
      decoder = _FakeDecoder();
      thumbs = PhotoThumbs(autoLimit: 1000, decoder: decoder.call);
    });
    tearDown(() => thumbs.dispose());

    List<RemoteEntry> photos(int n, {int size = 100}) => [
          for (var i = 0; i < n; i++)
            () {
              final e = _entry('IMG_$i.png', size, dir: '/pics');
              files.sizes[e.path] = size;
              return e;
            }(),
        ];

    Future<void> pumpGrid(WidgetTester tester, List<RemoteEntry> entries, {ValueChanged<int>? onOpen, Size? size}) async {
      tester.view
        ..physicalSize = (size ?? const Size(412, 892)) * 2.625
        ..devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              PhotoGrid(files: files, entries: entries, thumbs: thumbs, onOpen: onOpen ?? (_) {}),
            ],
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('0 and 1 photos draw without a fuss', (tester) async {
      await pumpGrid(tester, const []);
      expect(find.byType(PressBuilder), findsNothing);
      expect(tester.takeException(), isNull);

      final one = photos(1);
      await pumpGrid(tester, one);
      expect(find.byType(PressBuilder), findsOneWidget);
      final box = tester.getSize(find.byType(PressBuilder));
      expect(box.width, box.height, reason: 'tiles are square');
      expect((box.width - (412 - 2 * PhotoGrid.gap) / 3).abs(), lessThan(0.01));
    });

    testWidgets('three columns, 2 dp apart, square, edge to edge', (tester) async {
      await pumpGrid(tester, photos(7));
      final tiles = find.byType(PressBuilder);
      final r = [for (var i = 0; i < 7; i++) tester.getRect(tiles.at(i))];
      expect(r[0].left, 0);
      expect(r[1].left - r[0].right, PhotoGrid.gap);
      expect(r[2].left - r[1].right, PhotoGrid.gap);
      expect(r[2].right, closeTo(412, 0.01));
      expect(r[3].top - r[0].bottom, PhotoGrid.gap, reason: 'the fourth starts the second row');
      expect(r[3].left, 0);
    });

    testWidgets('a tile shows a still placeholder while it waits, the picture when ready, and no spinner', (tester) async {
      await pumpGrid(tester, photos(4));
      await tester.pump();
      expect(find.byType(RawImage), findsNothing);
      expect(find.byType(BusySpinner), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      files.openAll();
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(RawImage), findsNWidgets(4));
      // The fade-in is a one-shot: the tree is at rest afterwards.
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('an over-limit file shows a glyph and its size and is never read; a failed one an off-glyph', (tester) async {
      final entries = [
        _entry('big.png', 5 * 1024 * 1024, dir: '/pics'),
        _entry('bad.png', 100, dir: '/pics'),
        _entry('ok.png', 100, dir: '/pics'),
      ];
      files.sizes['/pics/bad.png'] = 100;
      files.sizes['/pics/ok.png'] = 100;
      files.failing.add('/pics/bad.png');
      files.openAll();
      await pumpGrid(tester, entries);
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.text('5 MB'), findsOneWidget);
      expect(files.reads, isNot(contains('/pics/big.png')));
      expect(find.byType(RawImage), findsOneWidget, reason: 'only ok.png has a picture');
      expect(find.byIcon(LucideIcons.imageOff), findsOneWidget, reason: 'bad.png could not be read');
      expect(find.byIcon(LucideIcons.image), findsOneWidget, reason: 'big.png is too big to fetch');
    });

    testWidgets('each tile is a button labelled name and size; the name is never drawn', (tester) async {
      final handle = tester.ensureSemantics();
      final long = 'Ảnh kỷ niệm chuyến đi Hạ Long — ${'rất dài ' * 20}.png';
      final entries = [
        _entry(long, 2048, dir: '/pics'),
        _entry('b.png', 100, dir: '/pics'),
      ];
      var opened = -1;
      await pumpGrid(tester, entries, onOpen: (i) => opened = i);

      expect(find.text(long), findsNothing);
      final node = find.bySemanticsLabel('$long, 2 KB');
      expect(tester.getSemantics(node), isSemantics(isButton: true, hasTapAction: true));
      expect(find.bySemanticsLabel('b.png, 100 B'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('b.png, 100 B'));
      expect(opened, 1);
      handle.dispose();
    });

    testWidgets('5,000 photos build only the tiles near the screen, at the top and at the end', (tester) async {
      final entries = photos(5000);
      final handle = tester.ensureSemantics();
      await pumpGrid(tester, entries);
      expect(find.byType(PressBuilder).evaluate().length, lessThan(40));
      expect(thumbs.queued + thumbs.inFlight, lessThan(40), reason: 'only visible tiles asked for a picture');

      final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      await tester.pump();
      expect(find.byType(PressBuilder).evaluate().length, lessThan(40));
      expect(find.bySemanticsLabel(RegExp('IMG_4999.png')), findsOneWidget);
      expect(thumbs.queued + thumbs.inFlight, lessThan(40));
      handle.dispose();
    });

    testWidgets('scrolling away cancels the loads of the tiles that left; the ones now in view start', (tester) async {
      final entries = photos(300);
      await pumpGrid(tester, entries);
      await tester.pump();
      expect(files.inFlight, 3);
      final firstReads = List.of(files.reads);
      expect(firstReads.toSet().length, 3);

      final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      await tester.pump();

      expect(thumbs.inFlight, 3, reason: 'the three old slots were handed on at once');
      final newReads = files.reads.skip(3).toList();
      expect(newReads.length, greaterThanOrEqualTo(3));
      expect(newReads.every((p) => int.parse(RegExp(r'IMG_(\d+)').firstMatch(p)!.group(1)!) > 250), isTrue,
          reason: 'only tiles near the end were read after the jump: $newReads');
      // Nothing from the middle of the folder was ever fetched.
      expect(files.reads.length, lessThan(10));
    });

    testWidgets('320 dp wide: tiles stay square and 3 across, with the long size text fitting', (tester) async {
      await pumpGrid(tester, [_entry('huge-photo.png', 1234 * 1024 * 1024, dir: '/pics'), ...photos(5)],
          size: const Size(320, 640));
      final tiles = find.byType(PressBuilder);
      final first = tester.getRect(tiles.at(0));
      final third = tester.getRect(tiles.at(2));
      expect(first.width, first.height);
      expect(third.right, closeTo(320, 0.01));
      expect(find.text('1.2 GB'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('screenshot: tiles waiting for their turn are quiet blocks with a faint glyph', (tester) async {
      Directory('/tmp/photo_grid_shots').createSync(recursive: true);
      await shoot(
        tester,
        Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverSafeArea(sliver: PhotoGrid(files: files, entries: photos(14), thumbs: thumbs, onOpen: (_) {})),
            ],
          ),
        ),
        '/tmp/photo_grid_shots/grid_waiting_light.png',
      );
      expect(find.byType(RawImage), findsNothing);
    });
  });

  group('browser', () {
    setUpAll(loadAppFonts);

    final dirCounter = [0];

    /// A fresh folder name per test: the shared thumbnail cache outlives them.
    String freshDir() => '/home/dev/pics-${dirCounter[0]++}';

    /// [n] pictures `IMG_1.png`.. of real (small) PNG data, plus whatever [extra] adds.
    Future<(FakeFs, String)> photoFolder(
      WidgetTester tester,
      int n, {
      void Function(FakeFs fs, String dir)? extra,
    }) async {
      final fs = FakeFs();
      final dir = freshDir();
      final png = await _art(tester, 1);
      for (var i = 1; i <= n; i++) {
        fs.addFile('$dir/IMG_$i.png', png);
      }
      extra?.call(fs, dir);
      return (fs, dir);
    }

    Future<void> open(WidgetTester tester, FakeFs fs, String dir, {FileBrowserMode mode = FileBrowserMode.browse}) async {
      tester.view
        ..physicalSize = const Size(412, 892) * 2.625
        ..devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        key: UniqueKey(),
        theme: AppTheme.light(),
        home: FileBrowserScreen(machine: machineWithFiles(fs), path: dir, mode: mode),
      ));
      await tester.pump();
      await _settle(tester);
    }

    testWidgets('the Photos toggle appears from six photos, never below, and never when picking', (tester) async {
      final (fs5, dir5) = await photoFolder(tester, 5, extra: (fs, d) => fs.addFile('$d/notes.txt', 'x'));
      await open(tester, fs5, dir5);
      expect(find.byTooltip('Photos'), findsNothing);
      expect(find.byTooltip('Show hidden files'), findsOneWidget);

      final (fs6, dir6) = await photoFolder(tester, 6);
      await open(tester, fs6, dir6);
      expect(find.byTooltip('Photos'), findsOneWidget);
      expect(find.byTooltip('Show hidden files'), findsOneWidget);

      for (final mode in [FileBrowserMode.pickDirectory, FileBrowserMode.pickFile]) {
        await open(tester, fs6, dir6, mode: mode);
        expect(find.byTooltip('Photos'), findsNothing, reason: '$mode');
      }
    });

    testWidgets('hidden pictures count only while hidden files are shown', (tester) async {
      final (fs, dir) = await photoFolder(tester, 5, extra: (fs, d) {
        fs.addFile('$d/.secret.png', Uint8List(10));
        fs.addFile('$d/.second.png', Uint8List(10));
      });
      await open(tester, fs, dir);
      expect(find.byTooltip('Photos'), findsNothing);

      await tester.tap(find.byTooltip('Show hidden files'));
      await _settle(tester);
      expect(find.byTooltip('Photos'), findsOneWidget);

      await tester.tap(find.byTooltip('Hide hidden files'));
      await _settle(tester);
      expect(find.byTooltip('Photos'), findsNothing);
    });

    testWidgets('the grid replaces the list, the header counts photos, and the list comes back', (tester) async {
      final (fs, dir) = await photoFolder(tester, 8, extra: (fs, d) {
        fs.addDir('$d/raw');
        fs.addFile('$d/notes.txt', 'x');
      });
      await open(tester, fs, dir);
      expect(find.text('10 items'), findsOneWidget);
      expect(find.byType(FileRow), findsNWidgets(10));
      expect(find.byType(PhotoGrid), findsNothing);

      await tester.tap(find.byTooltip('Photos'));
      await _settle(tester);
      expect(find.byType(PhotoGrid), findsOneWidget);
      expect(find.byType(FileRow), findsNothing);
      expect(find.text('raw'), findsNothing, reason: 'folders are not in the grid');
      expect(find.text('8 photos · 1 folder in list'), findsOneWidget);
      expect(find.byTooltip('List'), findsOneWidget);
      expect(find.byTooltip('Photos'), findsNothing);

      await tester.tap(find.byTooltip('List'));
      await _settle(tester);
      expect(find.byType(PhotoGrid), findsNothing);
      expect(find.text('raw'), findsOneWidget);
      expect(find.text('10 items'), findsOneWidget);
    });

    testWidgets('tapping a tile opens the viewer on that photo, paging through the folder in natural order', (tester) async {
      final (fs, dir) = await photoFolder(tester, 12, extra: (fs, d) => fs.addFile('$d/readme.txt', 'x'));
      await open(tester, fs, dir);
      await tester.tap(find.byTooltip('Photos'));
      await _settle(tester);

      await tester.tap(find.descendant(of: find.byType(PhotoGrid), matching: find.byType(PressBuilder)).at(2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final viewer = tester.state<PhotoViewerState>(find.byType(PhotoViewer));
      expect(viewer.model.index, 2);
      expect(viewer.model.items.map((i) => i.path), [for (var i = 1; i <= 12; i++) '$dir/IMG_$i.png'],
          reason: 'IMG_2 before IMG_10, no readme');
      expect(viewer.model.current.name, 'IMG_3.png');
    });

    testWidgets('a picture tapped in the list pages through the folder as well', (tester) async {
      final (fs, dir) = await photoFolder(tester, 12, extra: (fs, d) => fs.addFile('$d/readme.txt', 'x'));
      await open(tester, fs, dir);

      final list = find.descendant(of: find.byType(FileBrowserScreen), matching: find.byType(Scrollable)).first;
      await tester.scrollUntilVisible(find.text('IMG_10.png'), 120, scrollable: list);
      await tester.drag(list, const Offset(0, -200));
      await tester.pump();
      await tester.tap(find.text('IMG_10.png'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final viewer = tester.state<PhotoViewerState>(find.byType(PhotoViewer));
      expect(viewer.model.index, 9);
      expect(viewer.model.items.length, 12);
      expect(viewer.model.current.path, '$dir/IMG_10.png');
    });

    testWidgets('a 5,000-picture folder: the grid builds a handful of tiles, never the whole folder', (tester) async {
      final fs = FakeFs();
      final dir = freshDir();
      final big = Uint8List(3 * 1024 * 1024); // over the limit: nothing is fetched
      for (var i = 0; i < 5000; i++) {
        fs.addFile('$dir/Ảnh số $i.jpg', big);
      }
      await open(tester, fs, dir);
      await tester.tap(find.byTooltip('Photos'));
      await _settle(tester);

      expect(find.text('5,000 photos'), findsOneWidget);
      expect(find.byType(PhotoGrid), findsOneWidget);
      expect(find.descendant(of: find.byType(PhotoGrid), matching: find.byType(PressBuilder)).evaluate().length, lessThan(40));
      expect(fs.calls.where((c) => c.startsWith('read')), isEmpty, reason: '3 MB files are not fetched for thumbnails');

      final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      await tester.pump();
      expect(find.descendant(of: find.byType(PhotoGrid), matching: find.byType(PressBuilder)).evaluate().length, lessThan(40));
    });

    group('screenshots', () {
      final out = Directory('/tmp/photo_grid_shots');
      setUpAll(() => out.createSync(recursive: true));

      /// Many photos: real pictures, some too big to fetch, one broken, a few
      /// folders, long and Vietnamese names.
      Future<(FakeFs, String)> trip(WidgetTester tester) async {
        final fs = FakeFs();
        final dir = freshDir();
        final art = [for (var s = 0; s < 9; s++) await _art(tester, s * 3 + 1, portrait: s % 4 == 2)];
        final huge = Uint8List(3 * 1024 * 1024 + 700 * 1024);
        fs.addDir('$dir/raw');
        fs.addDir('$dir/Bản sao lưu');
        for (var i = 1; i <= 33; i++) {
          final name = switch (i) {
            4 => 'Ảnh hoàng hôn trên vịnh Hạ Long, chuyến đi gia đình mùa hè 2026 (bản chỉnh sửa cuối cùng).jpg',
            9 => 'a.png',
            _ => 'IMG_${i.toString().padLeft(4, '0')}.${i % 5 == 0 ? 'jpg' : 'png'}',
          };
          if (i == 6) {
            fs.addFile('$dir/$name', Uint8List.fromList(List.generate(900, (j) => j % 7)));
          } else if (i == 8 || i == 17 || i == 26) {
            fs.addFile('$dir/$name', huge);
          } else {
            fs.addFile('$dir/$name', art[i % art.length]);
          }
        }
        return (fs, dir);
      }

      Future<void> loaded(WidgetTester tester) async {
        for (var i = 0; i < 120; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
          await tester.pump(const Duration(milliseconds: 30));
          if (i > 3 && PhotoThumbs.shared.inFlight == 0 && PhotoThumbs.shared.queued == 0) break;
        }
      }

      for (final (label, size) in [('412x892', const Size(412, 892)), ('320x640', const Size(320, 640))]) {
        for (final brightness in Brightness.values) {
          testWidgets('grid $label ${brightness.name}', (tester) async {
            final (fs, dir) = await trip(tester);
            await shoot(
              tester,
              FileBrowserScreen(machine: machineWithFiles(fs), path: dir),
              '${out.path}/grid_${label}_${brightness.name}.png',
              brightness: brightness,
              pump: (tester) async {
                tester.view.physicalSize = size * phoneDpr;
                await tester.pump();
                await _settle(tester);
                await tester.tap(find.byTooltip('Photos'));
                await _settle(tester);
                await loaded(tester);
              },
            );
          });
        }
      }

      testWidgets('a folder of five photos has no toggle (light and dark)', (tester) async {
        for (final brightness in Brightness.values) {
          final (fs, dir) = await photoFolder(tester, 5);
          await shoot(
            tester,
            FileBrowserScreen(machine: machineWithFiles(fs), path: dir),
            '${out.path}/five_${brightness.name}.png',
            brightness: brightness,
            pump: (tester) async => _settle(tester),
          );
        }
      });

      testWidgets('the list view of the trip folder, for comparison with the toggle on', (tester) async {
        final (fs, dir) = await trip(tester);
        await shoot(
          tester,
          FileBrowserScreen(machine: machineWithFiles(fs), path: dir),
          '${out.path}/list_412x892_light.png',
          pump: (tester) async => _settle(tester),
        );
      });
    });
  });
}

/// Lets reads, decodes and the cache's own scheduling run: the fakes are real
/// futures, and the engine's decoder answers from another thread.
Future<void> flush() async {
  await pumpEventQueue();
  await Future<void>.delayed(const Duration(milliseconds: 30));
  await pumpEventQueue();
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// A PNG of a coloured scene, drawn with the engine: [seed] picks the colours.
Future<Uint8List> _art(WidgetTester tester, int seed, {bool portrait = false}) async {
  late Uint8List out;
  await tester.runAsync(() async {
    final w = portrait ? 270 : 360;
    final h = portrait ? 360 : 270;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final rect = ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
    final hue = (seed * 47) % 360.0;
    canvas.drawRect(
      rect,
      ui.Paint()
        ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, [
          HSLColor.fromAHSL(1, hue, 0.7, 0.62).toColor(),
          HSLColor.fromAHSL(1, (hue + 70) % 360, 0.75, 0.32).toColor(),
        ]),
    );
    canvas.drawCircle(ui.Offset(w * (0.25 + 0.12 * (seed % 4)), h * 0.3), h * 0.12, ui.Paint()..color = const ui.Color(0xD9FFFFFF));
    canvas.drawRect(ui.Rect.fromLTWH(0, h * 0.72, w.toDouble(), h * 0.28), ui.Paint()..color = const ui.Color(0x59000000));
    canvas.drawRect(ui.Rect.fromLTWH(w * 0.1, h * 0.55, w * 0.2, h * 0.3), ui.Paint()..color = const ui.Color(0x99000000));
    final image = await recorder.endRecording().toImage(w, h);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    out = data!.buffer.asUint8List();
  });
  return out;
}
