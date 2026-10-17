// Renders the picture of a terminal-log chat (idle, loading, failed, too large,
// loaded, not available) and the Settings Storage group to PNGs for review
// (light and dark, 412x892 and 320x640, text scale 1, 1.3 and 2). Off by
// default; it writes files:
//
//   LOG_IMAGE_SHOTS=1 flutter test test/ui/log_image_shots_test.dart
//
// Output: $LOG_IMAGE_SHOTS_DIR (default /tmp/log_image_shots)/<case>-<light|dark>-<w>x<h>-<scale>.png
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/observed/log_picture.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/notification_settings.dart';
import 'package:herdr_mobile/data/repositories/quick_phrases.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/notifier.dart';
import 'package:herdr_mobile/data/services/disk_cache.dart';
import 'package:herdr_mobile/ui/core/markdown/markdown.dart';
import 'package:herdr_mobile/ui/features/agent_session/content_image.dart';
import 'package:herdr_mobile/ui/features/agent_session/content_image_cache.dart';
import 'package:herdr_mobile/ui/features/agent_session/photo_thread.dart';
import 'package:herdr_mobile/ui/features/settings/settings_screen.dart';
import 'package:provider/provider.dart';

import '../support/fake_agent_session.dart';
import '../support/memory_app_settings_store.dart';
import '../support/memory_quick_phrases_store.dart';
import '../support/memory_terminal_settings_store.dart';
import '../support/settings_support.dart';
import '../support/shot.dart';

void main() {
  if (Platform.environment['LOG_IMAGE_SHOTS'] == null) {
    test('log image shots are off (set LOG_IMAGE_SHOTS=1)', () {}, skip: 'set LOG_IMAGE_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['LOG_IMAGE_SHOTS_DIR'] ?? '/tmp/log_image_shots';

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  /// A PNG of [w] x [h] pixels: a gradient with bars.
  Future<Uint8List> chart(WidgetTester tester, int w, int h) async {
    final data = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Paint()
          ..shader = ui.Gradient.linear(Offset.zero, Offset(0, h.toDouble()), const [Color(0xFF3366CC), Color(0xFFCC6633)]),
      );
      for (var i = 0; i < 6; i++) {
        canvas.drawRect(Rect.fromLTWH(w * (0.1 + i * 0.14), h * 0.3, w * 0.08, h * (0.1 + i * 0.1)), Paint()..color = const Color(0xCCFFFFFF));
      }
      final image = await recorder.endRecording().toImage(w, h);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return bytes!.buffer.asUint8List();
    });
    return data!;
  }

  const sizes = [(Size(412, 892), 1.0), (Size(320, 640), 1.3), (Size(320, 640), 2.0)];

  const keeper = KeeperPictureRef(start: 4096, hash: '0123456789abcdef', bytes: 107536);
  const png = LogImageBlock(mimeType: 'image/png', ref: keeper);
  // Worst case: an odd type, a big size.
  const odd = LogImageBlock(
    mimeType: 'image/svg+xml; charset=utf-8',
    ref: KeeperPictureRef(start: 9, hash: 'fedcba9876543210', bytes: 14 * 1024 * 1024),
  );
  const omp = LogImageBlock(mimeType: 'image/webp', ref: OmpPictureRef(sha256: 'ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12'));

  for (final (size, scale) in sizes) {
    for (final brightness in Brightness.values) {
      final tag = '${brightness.name}-${size.width.round()}x${size.height.round()}-$scale';

      testWidgets('states in a thread $tag', (tester) async {
        final dir = Directory.systemTemp.createTempSync('log_image_shots_');
        final saved = DiskCache.shared;
        final store = DiskCache.shared = DiskCache(() async => dir);
        addTearDown(() {
          DiskCache.shared = saved;
          dir.deleteSync(recursive: true);
        });
        await tester.runAsync(() => store.ready);
        final cache = ImagePreviewCache();
        addTearDown(cache.clear);
        final session = FakeAgentSession()
          ..logPictures[keeper.key] = await chart(tester, 640, 400);
        // `held` is a picture the phone already keeps: it shows by itself.
        final held = LogImageBlock(
          mimeType: 'image/png',
          ref: const KeeperPictureRef(start: 77, hash: '1111111111111111', bytes: 60000),
        );
        session.logPictures[held.key] = await chart(tester, 480, 300);
        await tester.runAsync(() => store.put(held.key, session.logPictures[held.key]!));

        Widget thread(List<Widget> rows) => ThreadPhotos(
          session: session,
          child: ListView(padding: const EdgeInsets.all(16), children: [for (final r in rows) Padding(padding: const EdgeInsets.only(bottom: 14), child: r)]),
        );

        await shoot(
          tester,
          Scaffold(
            body: MdActions(
              child: thread([
                ImageBlockView(block: png, cache: cache),
                ImageBlockView(block: odd, cache: cache),
                ImageBlockView(block: omp, cache: cache),
                ImageBlockView(block: held, cache: cache),
              ]),
            ),
          ),
          '$out/idle-$tag.png',
          brightness: brightness,
          size: size,
          wrap: (app) => MediaQuery(data: MediaQueryData(textScaler: TextScaler.linear(scale)), child: app),
          pump: (tester) async {
            // The held picture shows by itself; wait for its decode.
            for (var i = 0; i < 80; i++) {
              await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
              await tester.pump();
            }
          },
        );

        // Tap the first: the wait the person started shows the one spinner.
        session.logPictureGate = Completer<void>();
        await tester.tap(find.text('Tap to load').first);
        await tester.pump(const Duration(milliseconds: 100));
        await shoot(
          tester,
          Scaffold(
            body: MdActions(child: thread([ImageBlockView(block: png, cache: cache), ImageBlockView(block: omp, cache: cache)])),
          ),
          '$out/loading-$tag.png',
          brightness: brightness,
          size: size,
          wrap: (app) => MediaQuery(data: MediaQueryData(textScaler: TextScaler.linear(scale)), child: app),
        );
      });

      testWidgets('failed and too large $tag', (tester) async {
        final dir = Directory.systemTemp.createTempSync('log_image_shots_');
        final saved = DiskCache.shared;
        final store = DiskCache.shared = DiskCache(() async => dir);
        addTearDown(() {
          DiskCache.shared = saved;
          dir.deleteSync(recursive: true);
        });
        await tester.runAsync(() => store.ready);
        final cache = ImagePreviewCache();
        addTearDown(cache.clear);
        final session = FakeAgentSession()
          ..logPictureError = const LogPictureException(
            'The machine said something long about this picture: the log was rewritten since it was listed and the line is not there.',
          );

        Widget thread(List<Widget> rows) => ThreadPhotos(
          session: session,
          child: ListView(padding: const EdgeInsets.all(16), children: [for (final r in rows) Padding(padding: const EdgeInsets.only(bottom: 14), child: r)]),
        );
        // Both fail: the first with the sentence, the second is over the limit.
        session.logPictureError = const LogPictureException(
          'The machine said something long about this picture: the log was rewritten since it was listed and the line is not there.',
        );
        await shoot(
          tester,
          Scaffold(body: MdActions(child: thread([ImageBlockView(key: const ValueKey('png'), block: png, cache: cache)]))),
          '$out/failed-$tag.png',
          brightness: brightness,
          size: size,
          wrap: (app) => MediaQuery(data: MediaQueryData(textScaler: TextScaler.linear(scale)), child: app),
          pump: (tester) async {
            await tester.tap(find.text('Tap to load'));
            for (var i = 0; i < 10; i++) {
              await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
              await tester.pump();
            }
          },
        );
        session.logPictureError = const LogPictureTooLarge(14 * 1024 * 1024);
        await shoot(
          tester,
          Scaffold(body: MdActions(child: thread([ImageBlockView(key: const ValueKey('odd'), block: odd, cache: cache)]))),
          '$out/toolarge-$tag.png',
          brightness: brightness,
          size: size,
          wrap: (app) => MediaQuery(data: MediaQueryData(textScaler: TextScaler.linear(scale)), child: app),
          pump: (tester) async {
            await tester.tap(find.text('Tap to load'));
            for (var i = 0; i < 10; i++) {
              await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
              await tester.pump();
            }
          },
        );
      });

      testWidgets('not available here $tag', (tester) async {
        final dir = Directory.systemTemp.createTempSync('log_image_shots_');
        final saved = DiskCache.shared;
        final store = DiskCache.shared = DiskCache(() async => dir);
        addTearDown(() {
          DiskCache.shared = saved;
          dir.deleteSync(recursive: true);
        });
        await tester.runAsync(() => store.ready);
        await shoot(
          tester,
          Scaffold(
            body: MdActions(
              child: ListView(padding: const EdgeInsets.all(16), children: const [ImageBlockView(block: png)]),
            ),
          ),
          '$out/unavailable-$tag.png',
          brightness: brightness,
          size: size,
          wrap: (app) => MediaQuery(data: MediaQueryData(textScaler: TextScaler.linear(scale)), child: app),
        );
      });
    }
  }

  for (final brightness in Brightness.values) {
    testWidgets('settings storage ${brightness.name}', (tester) async {
      final dir = Directory.systemTemp.createTempSync('log_image_shots_');
      final saved = DiskCache.shared;
      final store = DiskCache.shared = DiskCache(() async => dir);
      addTearDown(() {
        DiskCache.shared = saved;
        dir.deleteSync(recursive: true);
      });
      await tester.runAsync(() async {
        for (var i = 0; i < 5; i++) {
          await store.put('k$i', Uint8List(10 * 1024 * 1024));
        }
      });
      final notifications = NotificationSettings(MemoryNotificationStore(const NotificationChoice()));
      await notifications.load();
      final quick = QuickPhrases(MemoryQuickPhrasesStore(const ['continue']));
      await quick.load();
      await shoot(
        tester,
        const SettingsScreen(),
        '$out/settings-storage-${brightness.name}.png',
        brightness: brightness,
        wrap: (app) => MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => AppSettings(MemoryAppSettingsStore())),
            ChangeNotifierProvider(create: (_) => TerminalSettings(MemoryTerminalSettingsStore())),
            ChangeNotifierProvider.value(value: notifications),
            ChangeNotifierProvider.value(value: quick),
            Provider<Notifier>.value(value: const NullNotifier()),
          ],
          child: app,
        ),
        pump: (tester) async {
          for (var i = 0; i < 20; i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
            await tester.pump();
          }
          await openSettingsGroup(tester, 'Storage');
          await tester.tap(find.text('Clear cache'));
          for (var i = 0; i < 40; i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
            await tester.pump(const Duration(milliseconds: 16));
          }
        },
      );
    });
  }
}
