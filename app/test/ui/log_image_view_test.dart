import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/observed/log_picture.dart';
import 'package:herdr_mobile/data/services/image_decode.dart' show DecodedImage;
import 'package:herdr_mobile/data/services/disk_cache.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/content_image.dart';
import 'package:herdr_mobile/ui/features/agent_session/content_image_cache.dart';
import 'package:herdr_mobile/ui/features/agent_session/photo_thread.dart';

import '../support/fake_agent_session.dart';
import '../support/photo_support.dart';
import '../support/shot.dart' show loadAppFonts;

// A picture of a terminal-log chat: a quiet line until the person taps, one
// fetch however often they tap, a failure that can be tried again, and a picture
// the phone already holds that simply shows.

late ui.Image _base;

Future<DecodedImage> _fakeBitmap(Uint8List bytes, {required int maxDimension}) async =>
    DecodedImage(image: _base.clone(), width: 4, height: 4, downscaled: false);

const _ref = KeeperPictureRef(start: 4096, hash: '0123456789abcdef', bytes: 107536);
const _block = LogImageBlock(mimeType: 'image/png', ref: _ref);

void main() {
  setUpAll(loadAppFonts);

  late Directory dir;
  late DiskCache store;
  late DiskCache savedStore;
  late FakeAgentSession session;
  late ImagePreviewCache cache;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('log_image_');
    savedStore = DiskCache.shared;
    store = DiskCache.shared = DiskCache(() async => dir);
    session = FakeAgentSession()..logPictures[_ref.key] = Uint8List.fromList([1, 2, 3]);
    cache = ImagePreviewCache(decoder: _fakeBitmap);
  });
  tearDown(() {
    cache.clear();
    DiskCache.shared = savedStore;
    dir.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester, {LogImageBlock block = _block, bool withSession = true, double textScale = 1}) async {
    _base = (await tester.runAsync(() => createTestImage(width: 4, height: 4)))!;
    addTearDown(_base.dispose);
    // The store's index load is real IO: done in the real zone, before the
    // widgets look at it (a future started in the fake zone waits for a pump).
    await tester.runAsync(() => store.ready);
    final view = ImageBlockView(block: block, cache: cache);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: withSession ? ThreadPhotos(session: session, child: view) : view,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester, bool Function() done) async {
    await pumpUntil(tester, done);
    expect(done(), isTrue);
  }

  testWidgets('it starts as a line with the type, the size and Tap to load, and fetches nothing', (tester) async {
    await pump(tester);
    expect(find.textContaining('Image', findRichText: true), findsOneWidget);
    expect(find.textContaining('image/png', findRichText: true), findsOneWidget);
    expect(find.textContaining('105 KB', findRichText: true), findsOneWidget);
    expect(find.text('Tap to load'), findsOneWidget);
    expect(find.byType(RawImage), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(session.logPictureCalls, isEmpty);
  });

  testWidgets('a tap fetches once, even when tapped twice, and then the picture draws', (tester) async {
    session.logPictureGate = Completer<void>();
    await pump(tester);
    await tester.tap(find.text('Tap to load'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget, reason: 'the wait the person started shows the one spinner');
    expect(find.text('Tap to load'), findsNothing);
    // A second tap lands on the picture frame, not on a line to load again.
    await tester.tap(find.byType(CircularProgressIndicator), warnIfMissed: false);
    await tester.pump();
    expect(session.logPictureCalls, [_ref.key]);

    session.logPictureGate!.complete();
    await settle(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
    expect(session.logPictureCalls, [_ref.key], reason: 'one fetch for the whole story');
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a failed fetch says why and Tap to retry. fetches again', (tester) async {
    session.logPictureError = logPictureGone;
    await pump(tester);
    await tester.tap(find.text('Tap to load'));
    await settle(tester, () => find.textContaining('Tap to retry.').evaluate().isNotEmpty);
    expect(find.text('The picture is no longer on the machine. Tap to retry.'), findsOneWidget);
    expect(session.logPictureCalls, hasLength(1));

    session.logPictureGate = Completer<void>();
    await tester.tap(find.textContaining('Tap to retry.'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget, reason: 'trying again is waiting again');
    session.logPictureGate!.complete();
    await settle(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
    expect(session.logPictureCalls, hasLength(2));
  });

  testWidgets('a picture over the limit says how large and offers no retry', (tester) async {
    session.logPictureError = const LogPictureTooLarge(14 * 1024 * 1024);
    await pump(tester);
    await tester.tap(find.text('Tap to load'));
    await settle(tester, () => find.textContaining('Too large').evaluate().isNotEmpty);
    expect(find.text('Too large to show here (14 MB).'), findsOneWidget);
    expect(find.textContaining('Tap to retry'), findsNothing);
  });

  testWidgets('a picture the phone already holds draws with no tap', (tester) async {
    await tester.runAsync(() => store.put(_ref.key, Uint8List.fromList([1, 2, 3])));
    await pump(tester);
    await settle(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
    expect(find.text('Tap to load'), findsNothing);
  });

  testWidgets('without a conversation to ask the line says so and does nothing', (tester) async {
    await pump(tester, withSession: false);
    expect(find.text('Not available here'), findsOneWidget);
    expect(find.text('Tap to load'), findsNothing);
    await tester.tap(find.textContaining('Image', findRichText: true));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(session.logPictureCalls, isEmpty);
  });

  testWidgets('an odd type and a very long reason wrap at large text instead of overflowing', (tester) async {
    session.logPictureError = const LogPictureException('The machine said something very long indeed about this picture. '
        'It went on and on about the log, the line, the offset and every other thing it knew.');
    await pump(
      tester,
      block: const LogImageBlock(mimeType: 'image/svg+xml; charset=utf-8', ref: KeeperPictureRef(start: 1, hash: 'fedcba9876543210', bytes: 14 * 1024 * 1024)),
      textScale: 2,
    );
    expect(find.text('Tap to load'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
