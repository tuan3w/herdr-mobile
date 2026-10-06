// The gallery's thumbnail cache: an LRU capped by count and bytes, at most N
// loads at once, scrolled-away requests dropped before they start, a held
// queue during a fling, and prefetch that never beats a tile on screen.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/phone_gallery.dart';
import 'package:herdr_mobile/data/services/thumb_cache.dart';

GalleryAsset asset(int i) => GalleryAsset(id: '$i', createdAt: DateTime(2026, 5, 20));

Uint8List bytes(int n) => Uint8List(n)..fillRange(0, n, 1);

/// A loader the test releases by hand.
class Loader {
  final started = <String>[];
  final _gates = <String, Completer<Uint8List?>>{};
  var running = 0;
  var peak = 0;

  Future<Uint8List?> call(GalleryAsset a) {
    started.add(a.id);
    running++;
    if (running > peak) peak = running;
    final c = Completer<Uint8List?>();
    _gates[a.id] = c;
    return c.future.whenComplete(() => running--);
  }

  void finish(int i, [Uint8List? data]) => _gates[i.toString()]!.complete(data ?? bytes(100));
}

Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  group('the LRU', () {
    test('keeps at most maxEntries and drops the least recently used', () async {
      final cache = ThumbCache(load: (a) async => bytes(10), maxEntries: 3);
      for (var i = 0; i < 3; i++) {
        await cache.request(asset(i));
      }
      cache.peek('0'); // 0 is the freshest now
      await cache.request(asset(3));
      expect(cache.length, 3);
      expect(cache.peek('1'), isNull, reason: '1 was the oldest untouched');
      expect(cache.peek('0'), isNotNull);
      expect(cache.peek('3'), isNotNull);
    });

    test('is capped in bytes too', () async {
      final cache = ThumbCache(load: (a) async => bytes(40), maxBytes: 100, maxEntries: 50);
      for (var i = 0; i < 5; i++) {
        await cache.request(asset(i));
      }
      expect(cache.bytes, lessThanOrEqualTo(100));
      expect(cache.length, 2);
    });

    test('a thumbnail that leaves the LRU is reported, so its decoded bitmap can go too', () async {
      final gone = <String>[];
      final cache = ThumbCache(load: (a) async => bytes(10), maxEntries: 2, onEvict: (id, b) => gone.add(id));
      for (var i = 0; i < 4; i++) {
        await cache.request(asset(i));
      }
      expect(gone, ['0', '1']);
      cache.clear();
      expect(gone, ['0', '1', '2', '3'], reason: 'clear gives all of them back');
    });

    test('clear gives everything back (memory pressure)', () async {
      final cache = ThumbCache(load: (a) async => bytes(10));
      await cache.request(asset(1));
      cache.clear();
      expect(cache.length, 0);
      expect(cache.bytes, 0);
    });
  });

  group('the queue', () {
    test('never runs more than `parallel` loads at once', () async {
      final loader = Loader();
      final cache = ThumbCache(load: loader.call, parallel: 3);
      for (var i = 0; i < 10; i++) {
        unawaited(cache.request(asset(i)));
      }
      await flush();
      expect(loader.started, hasLength(3));
      loader.finish(0);
      await flush();
      expect(loader.started, hasLength(4), reason: 'a finished load makes room for the next');
      expect(loader.peak, 3);
      expect(cache.peakRunning, 3);
    });

    test('two requests for one picture are one load', () async {
      final loader = Loader();
      final cache = ThumbCache(load: loader.call);
      final a = cache.request(asset(1));
      final b = cache.request(asset(1));
      await flush();
      expect(loader.started, ['1']);
      loader.finish(1);
      expect(await a, same(await b));
    });

    test('a tile that scrolled away before its turn is never loaded; one already loading finishes into the cache', () async {
      final loader = Loader();
      final cache = ThumbCache(load: loader.call, parallel: 1);
      final first = cache.request(asset(0));
      final queued = cache.request(asset(1));
      await flush();
      cache.cancel('1'); // gone before its turn
      cache.cancel('0'); // already running
      loader.finish(0);
      await first;
      expect(await queued, isNull, reason: 'the cancelled request completes empty');
      await flush();
      expect(loader.started, ['0'], reason: 'the cancelled one never reached the plugin');
      expect(cache.peek('0'), isNotNull, reason: 'a load that was running still lands in the cache for the way back');
    });

    test('a request two tiles want is not dropped by one of them leaving', () async {
      final loader = Loader();
      final cache = ThumbCache(load: loader.call, parallel: 1);
      unawaited(cache.request(asset(0)));
      final a = cache.request(asset(1));
      cache.request(asset(1)).ignore();
      await flush();
      cache.cancel('1');
      loader.finish(0);
      await flush();
      expect(loader.started, contains('1'));
      loader.finish(1);
      expect(await a, isNotNull);
    });

    test('paused holds the queue; resuming starts it', () async {
      final loader = Loader();
      final cache = ThumbCache(load: loader.call)..paused = true;
      unawaited(cache.request(asset(1)));
      await flush();
      expect(loader.started, isEmpty);
      cache.paused = false;
      await flush();
      expect(loader.started, ['1']);
    });

    test('prefetch waits for what is on screen and is replaced by the next prefetch', () async {
      final loader = Loader();
      final cache = ThumbCache(load: loader.call, parallel: 1);
      unawaited(cache.request(asset(0)));
      await flush(); // 0 runs
      cache.prefetch([asset(10), asset(11)]);
      unawaited(cache.request(asset(5))); // a tile on screen arrives after the prefetch was queued
      cache.prefetch([asset(20)]); // the person scrolled on: the old prefetch list goes
      loader.finish(0);
      await flush();
      expect(loader.started, ['0', '5'], reason: 'the visible tile before any prefetch');
      loader.finish(5);
      await flush();
      expect(loader.started, ['0', '5', '20']);
    });

    test('a prefetched picture that a tile then asks for jumps the queue and is not loaded twice', () async {
      final loader = Loader();
      final cache = ThumbCache(load: loader.call, parallel: 1);
      unawaited(cache.request(asset(0)));
      await flush();
      cache.prefetch([asset(7), asset(8)]);
      final wanted = cache.request(asset(8));
      loader.finish(0);
      await flush();
      expect(loader.started, ['0', '8']);
      loader.finish(8);
      expect(await wanted, isNotNull);
    });

    test('a picture with no thumbnail is remembered and not asked for again', () async {
      var calls = 0;
      final cache = ThumbCache(load: (a) async {
        calls++;
        return null;
      });
      expect(await cache.request(asset(1)), isNull);
      expect(await cache.request(asset(1)), isNull);
      expect(calls, 1);
      expect(cache.failed('1'), isTrue);
      cache.clear();
      await cache.request(asset(1));
      expect(calls, 2, reason: 'a new permission or a clear tries again');
    });

    test('a loader that throws is a failed thumbnail, not a stuck queue', () async {
      final cache = ThumbCache(load: (a) async => a.id == '1' ? throw StateError('boom') : bytes(5), parallel: 1);
      expect(await cache.request(asset(1)), isNull);
      expect(await cache.request(asset(2)), isNotNull);
    });
  });
}
