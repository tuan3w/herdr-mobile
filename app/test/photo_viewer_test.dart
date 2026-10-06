import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/services/photo_export.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/features/photos/photo_item.dart';
import 'package:herdr_mobile/ui/features/photos/photo_math.dart';
import 'package:herdr_mobile/ui/features/photos/photo_pictures.dart';
import 'package:herdr_mobile/ui/features/photos/photo_stage.dart';
import 'package:herdr_mobile/ui/features/photos/photo_viewer.dart';
import 'package:herdr_mobile/ui/features/photos/photo_viewer_view_model.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';
import 'support/photo_support.dart';
import 'support/shot.dart' show loadAppFonts;

/// Fake photos on a 412 x 892 dp screen at 2.625 dpr: the decode box is
/// 1622 x 3512 px, so a 4000 x 3000 photo decodes at 1622 x 1217 and zooming
/// asks for 4000 x 3000.
const _screenBitmap = (1622, 1217);
const _full = (4000, 3000);

/// A finger on the screen with its own clock: pointer events carry time
/// stamps, which is what a release velocity is made of (a gesture without
/// them has none).
class _Finger {
  _Finger(this.tester, this.gesture);

  final WidgetTester tester;
  final TestGesture gesture;
  var _t = Duration.zero;

  /// Moves by [delta] and lets [ms] pass (pumping a frame unless [ms] is 0,
  /// for the first of two fingers that move in the same frame).
  Future<void> by(Offset delta, {int ms = 16}) async {
    _t += Duration(milliseconds: ms);
    await gesture.moveBy(delta, timeStamp: _t);
    if (ms > 0) await tester.pump(Duration(milliseconds: ms));
  }

  Future<void> to(Offset at, {int ms = 16, bool pump = true}) async {
    _t += Duration(milliseconds: ms);
    await gesture.moveTo(at, timeStamp: _t);
    if (pump && ms > 0) await tester.pump(Duration(milliseconds: ms));
  }

  Future<void> up() => gesture.up(timeStamp: _t);
}

class _Rig {
  _Rig(this.tester, this.decoder, this.export, this.log);

  final WidgetTester tester;
  final FakeDecoder decoder;
  final FakeExport export;
  final List<String> log;

  PhotoViewerState get viewer => tester.state<PhotoViewerState>(find.byType(PhotoViewer));
  PhotoStageState get stage => tester.state<PhotoStageState>(find.byType(PhotoStage));
  PhotoViewerViewModel get model => viewer.model;
  PhotoPose get pose => stage.pose;

  Offset get center => tester.getCenter(find.byType(PhotoStage));

  Future<void> settle([int ms = 800]) async {
    for (var t = 0; t < ms; t += 16) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// A finger down at [at], moved by [delta] in [steps] steps [stepMs] apart (a
  /// flick when the steps are few and short). Not released.
  Future<_Finger> drag(Offset at, Offset delta, {int steps = 8, int stepMs = 16, int? pointer}) async {
    final f = _Finger(tester, await tester.startGesture(at, pointer: pointer));
    for (var i = 1; i <= steps; i++) {
      await f.by(delta / steps.toDouble(), ms: stepMs);
    }
    return f;
  }

  /// Two fingers [from] apart (each side of [at]) moved to [to] apart, in
  /// [steps] frames. Not released.
  Future<(_Finger, _Finger)> pinch(Offset at, {required double from, required double to, int steps = 12, int stepMs = 16}) async {
    final a = _Finger(tester, await tester.startGesture(at - Offset(from, 0), pointer: 11));
    final b = _Finger(tester, await tester.startGesture(at + Offset(from, 0), pointer: 12));
    for (var i = 1; i <= steps; i++) {
      final half = from + (to - from) * i / steps;
      await a.to(at - Offset(half, 0), ms: stepMs, pump: false);
      await b.to(at + Offset(half, 0), ms: stepMs);
    }
    return (a, b);
  }

  Future<void> doubleTap(Offset at) async {
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(at);
    await tester.pump();
  }
}

/// Opens a viewer on [items] as a route over a plain page (so a dismissal has
/// somewhere to go back to).
Future<_Rig> _open(
  WidgetTester tester,
  List<PhotoItem> items,
  FakeDecoder decoder, {
  int index = 0,
  FakeExport? export,
  bool reduceMotion = false,
  Future<List<PhotoItem>> Function()? moreItems,
  Widget Function()? viewAsText,
  Brightness brightness = Brightness.light,
  Size size = const Size(412, 892),
  List<String>? log,
}) async {
  usePhoneSurface(tester, size: size);
  final fake = export ?? FakeExport();
  late BuildContext host;
  await pumpApp(
    tester,
    Builder(
      builder: (context) {
        host = context;
        return const Scaffold(body: Center(child: Text('chat')));
      },
    ),
    reduceMotion: reduceMotion,
    brightness: brightness,
  );
  unawaited(Navigator.of(host).push(photoViewerRoute(
    items: items,
    initialIndex: index,
    moreItems: moreItems,
    viewAsText: viewAsText,
    export: fake,
    decoder: decoder.call,
    exifReader: (_) => null,
  )));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  final rig = _Rig(tester, decoder, fake, log ?? []);
  await pumpUntil(tester, () => rig.model.currentEntry.ready || rig.model.currentEntry.failure != null);
  await rig.settle(100);
  return rig;
}

List<PhotoItem> _three(List<String> log, {int w = 4000, int h = 3000}) => [
  fakePhoto('IMG_0001.jpg', log, width: w, height: h, path: '/home/dev/shots/IMG_0001.jpg', modified: DateTime.utc(2026, 5, 20, 9, 30)),
  fakePhoto('IMG_0002.jpg', log, width: w, height: h, path: '/home/dev/shots/IMG_0002.jpg'),
  fakePhoto('IMG_0003.jpg', log, width: w, height: h, path: '/home/dev/shots/IMG_0003.jpg'),
];

/// Haptic calls the platform got, as their type names.
List<String> _captureHaptics(WidgetTester tester) {
  final out = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') out.add(call.arguments as String);
    if (call.method == 'Clipboard.setData') out.add('copy:${(call.arguments as Map)['text']}');
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return out;
}

bool _chromeShown(WidgetTester tester) {
  final opacity = find.ancestor(of: find.byTooltip('Back', skipOffstage: false), matching: find.byType(Opacity), matchRoot: false);
  if (opacity.evaluate().isEmpty) return true;
  return tester.widget<Opacity>(opacity.first).opacity > 0.5;
}

void main() {
  setUpAll(loadAppFonts);

  Future<(FakeDecoder, List<String>)> prepared(WidgetTester tester, [Iterable<(int, int)> extra = const []]) async {
    final decoder = FakeDecoder();
    await decoder.prepare(tester, [_screenBitmap, _full, ...extra]);
    return (decoder, <String>[]);
  }

  group('overlay', () {
    testWidgets('a tap hides the bars and the caption, another brings them back', (tester) async {
      final (decoder, log) = await prepared(tester);
      final rig = await _open(tester, _three(log), decoder);

      expect(find.text('Photo 1 of 3'), findsOneWidget);
      expect(find.byTooltip('Back'), findsOneWidget);
      expect(find.byTooltip('Photo info'), findsOneWidget);
      expect(find.byTooltip('Save or share'), findsOneWidget);
      expect(find.textContaining('IMG_0001.jpg'), findsOneWidget, reason: 'the caption names the file');
      expect(_chromeShown(tester), isTrue);

      await tester.tapAt(rig.center);
      await rig.settle(500);
      expect(_chromeShown(tester), isFalse);
      expect(rig.model.index, 0);

      await tester.tapAt(rig.center);
      await rig.settle(500);
      expect(_chromeShown(tester), isTrue);
    });

    testWidgets('the caption is one line: the name, then the dimensions', (tester) async {
      final (decoder, log) = await prepared(tester);
      await _open(tester, _three(log), decoder);
      final caption = find.textContaining('4,000 × 3,000', findRichText: true);
      expect(caption, findsOneWidget);
      final rich = tester.widget<RichText>(caption);
      expect(rich.text.toPlainText(), 'IMG_0001.jpg  ·  4,000 × 3,000');
      expect(rich.maxLines, 1);
    });

    testWidgets('a very long name is cut in the middle: the end and the extension stay', (tester) async {
      final (decoder, log) = await prepared(tester, [(1260, 945)]);
      const name = 'Ảnh chụp màn hình rất dài của buổi họp ngày hai mươi tháng năm hai nghìn hai mươi sáu lần thứ 3 (bản cuối cùng).png';
      await _open(tester, [fakePhoto(name, log, width: 4000, height: 3000)], decoder, size: const Size(320, 640));
      final caption = tester.widget<RichText>(find.textContaining('4,000 × 3,000', findRichText: true)).text.toPlainText();
      expect(caption, contains('…'));
      expect(caption, contains('.png  ·  4,000 × 3,000'));
      expect(caption, startsWith('Ảnh'));
      expect(caption.length, lessThan(name.length));
    });

    testWidgets('a lone photo is titled by its name, not by a position', (tester) async {
      final (decoder, log) = await prepared(tester);
      await _open(tester, [fakePhoto('solo.png', log, width: 4000, height: 3000)], decoder);
      expect(find.text('Photo 1 of 1'), findsNothing);
      expect(find.text('solo.png'), findsWidgets);
    });
  });

  group('info sheet', () {
    testWidgets('says where the photo is, how big, when: the right one or not', (tester) async {
      final (decoder, log) = await prepared(tester);
      final out = _captureHaptics(tester);
      final rig = await _open(tester, _three(log), decoder);

      await tester.tap(find.byTooltip('Photo info'));
      await tester.pumpAndSettle();

      expect(find.text('Photo info'), findsOneWidget);
      for (final text in ['Name', 'IMG_0001.jpg', 'Path', '/home/dev/shots/IMG_0001.jpg', 'Dimensions', '4,000 × 3,000 · 12.0 MP', 'Size', 'Modified', 'May 20, 2026 at']) {
        expect(find.textContaining(text), findsWidgets, reason: text);
      }
      expect(find.textContaining('Screen-size preview'), findsOneWidget, reason: 'it says the bitmap is a preview until zoomed');

      await tester.tap(find.byTooltip('Copy path'));
      await tester.pump();
      expect(out, contains('copy:/home/dev/shots/IMG_0001.jpg'), reason: 'the full path is copyable');
      expect(rig.model.index, 0);
    });

    testWidgets('a chat picture says which message or tool produced it', (tester) async {
      final (decoder, log) = await prepared(tester);
      await _open(tester, [
        fakePhoto('image-1.png', log, width: 4000, height: 3000, origin: 'Tool result · Read screenshot.png'),
      ], decoder);
      await tester.tap(find.byTooltip('Photo info'));
      await tester.pumpAndSettle();
      expect(find.text('From'), findsOneWidget);
      expect(find.text('Tool result · Read screenshot.png'), findsOneWidget);
      expect(find.text('Path'), findsNothing, reason: 'a chat picture has no path');
    });

    testWidgets('EXIF date and camera appear when the file has them', (tester) async {
      final jpg = jpegWithExif(80, 40, orientation: 6, make: 'Canon', model: 'Canon EOS R5', taken: '2026:05:20 09:30:00');
      usePhoneSurface(tester);
      late BuildContext host;
      await pumpApp(tester, Builder(builder: (c) {
        host = c;
        return const SizedBox();
      }));
      unawaited(Navigator.of(host).push(photoViewerRoute(
        items: [PhotoItem(id: 'a', name: 'a.jpg', source: MemoryPhotoSource(() async => jpg, size: jpg.length))],
        export: FakeExport(),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await pumpUntil(tester, () => tester.state<PhotoViewerState>(find.byType(PhotoViewer)).model.currentEntry.ready);
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byTooltip('Photo info'));
      await tester.pumpAndSettle();
      expect(find.text('Camera'), findsOneWidget);
      expect(find.text('Canon EOS R5'), findsOneWidget);
      expect(find.text('Taken'), findsOneWidget);
      expect(find.text('May 20, 2026 at 09:30'), findsOneWidget);
      expect(find.text('40 × 80 · 0.0 MP'.replaceAll(' · 0.0 MP', '')), findsOneWidget, reason: 'upright size, orientation applied');
      expect(find.textContaining('EXIF 6'), findsOneWidget);
    });
  });

  group('paging', () {
    testWidgets('a swipe turns the page: order, position, and the neighbours were read ahead', (tester) async {
      final (decoder, log) = await prepared(tester);
      final rig = await _open(tester, _three(log), decoder);
      expect(log.where((l) => l.startsWith('start')), ['start IMG_0001.jpg', 'start IMG_0002.jpg'],
          reason: 'the next one is read ahead; the previous does not exist');

      final g = await rig.drag(rig.center, const Offset(-260, 0));
      await g.up();
      await rig.settle();
      expect(rig.model.index, 1);
      expect(find.text('Photo 2 of 3'), findsOneWidget);
      expect(rig.pose.pageDx, 0, reason: 'settled');
      expect(rig.pose.scale, 1);
      expect(log.where((l) => l.startsWith('start')), ['start IMG_0001.jpg', 'start IMG_0002.jpg', 'start IMG_0003.jpg']);

      final back = await rig.drag(rig.center, const Offset(300, 0));
      await back.up();
      await rig.settle();
      expect(rig.model.index, 0);
      expect(find.text('Photo 1 of 3'), findsOneWidget);
    });

    testWidgets('a short slow pull does not turn the page: it springs back', (tester) async {
      final (decoder, log) = await prepared(tester);
      final rig = await _open(tester, _three(log), decoder);
      final g = await rig.drag(rig.center, const Offset(-60, 0), stepMs: 60);
      expect(rig.pose.pageDx, lessThan(-30), reason: 'the page follows the finger');
      await g.up();
      await rig.settle();
      expect(rig.model.index, 0);
      expect(rig.pose.pageDx, 0);
    });

    testWidgets('a flick turns the page even when it is short', (tester) async {
      final (decoder, log) = await prepared(tester);
      final rig = await _open(tester, _three(log), decoder);
      final g = await rig.drag(rig.center, const Offset(-90, 0), steps: 3, stepMs: 8);
      await g.up();
      await rig.settle();
      expect(rig.model.index, 1);
    });

    testWidgets('past the first and the last photo the page gives like rubber and comes back', (tester) async {
      final (decoder, log) = await prepared(tester);
      final rig = await _open(tester, _three(log), decoder);

      final g = await rig.drag(rig.center, const Offset(400, 0));
      final pulled = rig.pose.pageDx;
      expect(pulled, greaterThan(20));
      expect(pulled, lessThan(400 * 0.4), reason: 'resists: bounded by 40% of the width');
      expect(pulled, lessThan(250), reason: 'and well short of the finger');
      await g.up();
      await rig.settle();
      expect(rig.model.index, 0, reason: 'there is nothing before the first photo');
      expect(rig.pose.pageDx, 0);

      rig.model.goTo(2);
      await rig.settle(100);
      final end = await rig.drag(rig.center, const Offset(-400, 0));
      expect(rig.pose.pageDx, lessThan(-20));
      expect(rig.pose.pageDx, greaterThan(-165));
      await end.up();
      await rig.settle();
      expect(rig.model.index, 2);
      expect(rig.pose.pageDx, 0);
    });

    testWidgets('neighbours are built lazily: a page enters the tree when a finger pulls it into view', (tester) async {
      final (decoder, log) = await prepared(tester);
      final rig = await _open(tester, _three(log), decoder);
      expect(find.byType(PhotoPage), findsOneWidget, reason: 'the next photo is read ahead but is off screen: not built');

      final g = await rig.drag(rig.center, const Offset(-100, 0), stepMs: 30);
      expect(find.byType(PhotoPage), findsNWidgets(2));
      await g.up();
      await rig.settle();
      expect(find.byType(PhotoPage), findsOneWidget, reason: 'sprang back: gone again');

      rig.model.goTo(1);
      await rig.settle(100);
      final both = await rig.drag(rig.center, const Offset(-60, 0), stepMs: 30);
      final other = await rig.drag(rig.center + const Offset(0, 200), const Offset(0, 0), steps: 0, pointer: 99);
      expect(find.byType(PhotoPage), findsNWidgets(2));
      await other.up();
      await both.up();
      await rig.settle();
    });

    testWidgets('the folder arrives after the photo opened: the position appears', (tester) async {
      final (decoder, log) = await prepared(tester);
      final all = _three(log);
      final rig = await _open(tester, [all[1]], decoder, moreItems: () async => all);
      await rig.settle(100);
      expect(find.text('Photo 2 of 3'), findsOneWidget);
      expect(rig.model.index, 1);
    });
  });

  group('zoom', () {
    testWidgets('double tap zooms to 2.5x at the tapped point with a spring, and again returns to fit', (tester) async {
      final (decoder, log) = await prepared(tester);
      final rig = await _open(tester, _three(log), decoder);
      final at = rig.center + const Offset(80, 0);

      await rig.doubleTap(at);
      await tester.pump(const Duration(milliseconds: 60));
      expect(rig.pose.scale, inExclusiveRange(1.0, 2.5), reason: 'it is on its way, not jumped');
      await rig.settle();
      expect(rig.pose.scale, closeTo(2.5, 0.001));
      // The point that was 80 px right of the centre is still there.
      expect(rig.pose.offset.dx, closeTo(-80 * 1.5, 0.5));

      await rig.doubleTap(at);
      await rig.settle();
      expect(rig.pose.scale, closeTo(1, 0.001));
      expect(rig.pose.offset, Offset.zero);
    });

    testWidgets('a finger landing stops an in-flight double-tap zoom where it is: they do not fight', (tester) async {
      final (decoder, log) = await prepared(tester);
      final rig = await _open(tester, _three(log), decoder);
      await rig.doubleTap(rig.center);
      await tester.pump(const Duration(milliseconds: 50));
      final mid = rig.pose.scale;
      expect(mid, inExclusiveRange(1.0, 2.5));

      final finger = await tester.startGesture(rig.center + const Offset(0, 200));
      final held = rig.pose;
      await rig.settle(600);
      expect(rig.pose, held, reason: 'nothing moves the picture while a finger is on it');
      expect(rig.pose.scale, mid);

      // The next movement starts from there, not from the target.
      await finger.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 16));
      await finger.up();
      await rig.settle();
      expect(rig.pose.scale, closeTo(mid, 0.001), reason: 'a pan does not zoom');
    });

    testWidgets('pinch zooms around the fingers\' centre', (tester) async {
      final (decoder, log) = await prepared(tester);
      final rig = await _open(tester, _three(log), decoder);
      final c = rig.center + const Offset(40, 0);
      final (a, b) = await rig.pinch(c, from: 40, to: 100);
      final scale = rig.pose.scale;
      expect(scale, greaterThan(1.5));
      // The point of the picture that was under the middle of the fingers is
      // still under it (give or take the few pixels the first frames moved it).
      final focal = c - rig.center;
      expect(rig.pose.offset.dx, closeTo(focal.dx * (1 - scale), 8), reason: 'anchored at the fingers, not at the centre of the picture');
      expect(rig.pose.offset.dx, lessThan(-15), reason: 'a centre-anchored zoom would leave 0');
      await a.up();
      await b.up();
      await rig.settle();
      expect(rig.pose.scale, closeTo(scale, 0.05), reason: 'inside the limits: it stays');
    });

    testWidgets('pinched below fit it springs back to fit on release (never rests smaller)', (tester) async {
      final (decoder, log) = await prepared(tester);
      final rig = await _open(tester, _three(log), decoder);
      final (a, b) = await rig.pinch(rig.center, from: 80, to: 20);
      expect(rig.pose.scale, lessThan(1), reason: 'it gives under the fingers');
      expect(rig.pose.scale, greaterThan(0.6), reason: 'but resists');
      await a.up();
      await b.up();
      await rig.settle();
      expect(rig.pose.scale, closeTo(1, 0.001));
      expect(rig.pose.offset, Offset.zero);
    });

    testWidgets('pinched past the largest size it gives, then returns to the largest size', (tester) async {
      final (decoder, log) = await prepared(tester);
      final rig = await _open(tester, _three(log), decoder);
      final max = PhotoGeometry.forImage(
        viewport: const Size(412, 892),
        image: const Size(4000, 3000),
        devicePixelRatio: 2.625,
      ).maxScale;
      final (a, b) = await rig.pinch(rig.center, from: 30, to: 30 * max * 3, steps: 40);
      expect(rig.pose.scale, greaterThan(max));
      expect(rig.pose.scale, lessThan(max * 1.45));
      await a.up();
      await b.up();
      await rig.settle();
      expect(rig.pose.scale, closeTo(max, 0.01));
    });

    testWidgets('a pan has momentum: it keeps going after the finger lifts, and stops at the edge', (tester) async {
      final (decoder, log) = await prepared(tester);
      final rig = await _open(tester, _three(log), decoder);
      await rig.doubleTap(rig.center);
      await rig.settle();
      expect(rig.pose.scale, closeTo(2.5, 0.001));
      final limit = PhotoGeometry.forImage(
        viewport: const Size(412, 892),
        image: const Size(4000, 3000),
        devicePixelRatio: 2.625,
      ).panLimit(2.5);
      expect(limit.dx, closeTo(309, 0.5));

      final g = await rig.drag(rig.center, const Offset(-100, 0), steps: 5, stepMs: 8);
      final atRelease = rig.pose.offset.dx;
      await g.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(rig.pose.offset.dx, lessThan(atRelease - 5), reason: 'momentum carries it on');
      await rig.settle(1500);
      expect(rig.pose.offset.dx, greaterThanOrEqualTo(-limit.dx - 0.5));
      expect(rig.pose.offset.dx, lessThan(atRelease));
      expect(rig.pose.pageDx, 0);
    });

    testWidgets('dragged past the picture\'s edge it gives like rubber and returns', (tester) async {
      final (decoder, log) = await prepared(tester);
      final rig = await _open(tester, [fakePhoto('only.jpg', log, width: 4000, height: 3000)], decoder);
      await rig.doubleTap(rig.center);
      await rig.settle();
      final left = await rig.drag(rig.center, const Offset(-600, 0), steps: 10, stepMs: 40);
      expect(rig.pose.offset.dx, closeTo(-309, 0.01), reason: 'the picture is at its edge...');
      expect(rig.pose.pageDx, lessThan(-20), reason: '...and the rest of the pull stretches the page');
      expect(rig.pose.pageDx, greaterThan(-165), reason: 'only a rubber band past it: bounded by 40% of the width');
      await left.up();
      await rig.settle(1200);
      expect(rig.pose.offset.dx, closeTo(-309, 1));
      expect(rig.pose.pageDx, 0);
    });

    testWidgets('at the edge of a zoomed photo a further swipe turns to the next photo', (tester) async {
      final (decoder, log) = await prepared(tester);
      final rig = await _open(tester, _three(log), decoder);
      await rig.doubleTap(rig.center);
      await rig.settle();
      // Pan to the right-hand edge, then pull on past it.
      final pan = await rig.drag(rig.center, const Offset(-900, 0), steps: 12, stepMs: 30);
      expect(rig.pose.offset.dx, closeTo(-309, 0.01));
      expect(rig.pose.pageDx, lessThan(-100), reason: 'the next photo is coming in');
      await pan.up();
      await rig.settle();
      expect(rig.model.index, 1);
      expect(rig.pose.scale, 1, reason: 'the new photo opens at fit');
    });

    testWidgets('the zoom is sharpened: a bigger decode arrives once the picture is stretched, and goes when zoomed out', (tester) async {
      final (decoder, log) = await prepared(tester);
      final rig = await _open(tester, _three(log), decoder);
      expect(rig.model.currentEntry.sharp, isNull);
      expect(decoder.calls.last.boxW, 1622, reason: 'first decode: 1.5x the screen');

      await rig.doubleTap(rig.center);
      await rig.settle(300);
      await pumpUntil(tester, () => rig.model.currentEntry.sharp != null);
      expect(rig.model.currentEntry.sharp, isNotNull, reason: '2.5x of fit is 2703 px: more than the 1622 px decoded');
      expect(decoder.calls.last.boxW, 4096);

      await rig.doubleTap(rig.center);
      await rig.settle(800);
      expect(rig.model.currentEntry.sharp, isNotNull, reason: 'kept for a moment in case the person zooms again');
      await tester.pump(const Duration(seconds: 3));
      expect(rig.model.currentEntry.sharp, isNull, reason: 'given back after the hold');
    });

    testWidgets('haptic detents: a click as the picture reaches fit, and as it reaches its largest size', (tester) async {
      final (decoder, log) = await prepared(tester);
      final out = _captureHaptics(tester);
      final rig = await _open(tester, _three(log), decoder);
      await rig.doubleTap(rig.center);
      await rig.settle();
      out.clear();

      // Pinch in through fit: one click.
      final (a, b) = await rig.pinch(rig.center, from: 150, to: 30, steps: 24);
      await a.up();
      await b.up();
      await rig.settle();
      expect(out.where((h) => h.contains('selectionClick')).length, 1, reason: 'a detent at fit, once: $out');

      // Pinch out to the largest size: another.
      out.clear();
      final (c, d) = await rig.pinch(rig.center, from: 30, to: 30 * 25, steps: 40);
      await c.up();
      await d.up();
      await rig.settle();
      expect(out.where((h) => h.contains('selectionClick')).length, greaterThanOrEqualTo(1), reason: 'a detent at the largest size: $out');
    });
  });

  group('dismiss', () {
    testWidgets('a drag down fades the backdrop, and past the threshold the viewer closes', (tester) async {
      final (decoder, log) = await prepared(tester);
      final rig = await _open(tester, _three(log), decoder);
      expect(find.byType(PhotoViewer), findsOneWidget);

      final g = await rig.drag(rig.center, const Offset(0, 140), stepMs: 40);
      expect(rig.stage.widget.dismissProgress.value, closeTo(140 / (892 / 3), 0.08), reason: 'the backdrop fades with the drag');
      expect(rig.pose.drag.dy, greaterThan(100));
      await g.up();
      await rig.settle();
      expect(rig.stage.widget.dismissProgress.value, 0, reason: '140 px at a crawl is short of the threshold: it springs back');
      expect(find.byType(PhotoViewer), findsOneWidget);

      final far = await rig.drag(rig.center, const Offset(0, 300), stepMs: 40);
      await far.up();
      await rig.settle(600);
      expect(find.byType(PhotoViewer), findsNothing, reason: 'dismissed');
      expect(find.text('chat'), findsOneWidget);
    });

    testWidgets('a short fast flick up closes it too', (tester) async {
      final (decoder, log) = await prepared(tester);
      final rig = await _open(tester, _three(log), decoder);
      final g = await rig.drag(rig.center, const Offset(0, -80), steps: 3, stepMs: 8);
      await g.up();
      await rig.settle(600);
      expect(find.byType(PhotoViewer), findsNothing);
    });

    testWidgets('a drag that turns back before release does not close, whatever the distance', (tester) async {
      final (decoder, log) = await prepared(tester);
      final rig = await _open(tester, _three(log), decoder);
      final g = await rig.drag(rig.center, const Offset(0, 260), stepMs: 30);
      for (var i = 0; i < 4; i++) {
        await g.by(const Offset(0, -45), ms: 8);
      }
      await g.up();
      await rig.settle(600);
      expect(find.byType(PhotoViewer), findsOneWidget);
    });

    testWidgets('a zoomed picture is panned, not dismissed', (tester) async {
      final (decoder, log) = await prepared(tester);
      final rig = await _open(tester, _three(log), decoder);
      await rig.doubleTap(rig.center);
      await rig.settle();
      final g = await rig.drag(rig.center, const Offset(0, 300), stepMs: 30);
      await g.up();
      await rig.settle(800);
      expect(find.byType(PhotoViewer), findsOneWidget);
      expect(rig.pose.drag, Offset.zero);
    });
  });

  group('reduced motion', () {
    testWidgets('a double tap lands at once, a release lands at once, and a dismissal closes at once', (tester) async {
      final (decoder, log) = await prepared(tester);
      final rig = await _open(tester, _three(log), decoder, reduceMotion: true);

      await rig.doubleTap(rig.center);
      expect(rig.pose.scale, closeTo(2.5, 0.001), reason: 'no travel');
      await rig.doubleTap(rig.center);
      expect(rig.pose.scale, 1);

      final g = await rig.drag(rig.center, const Offset(-60, 0), stepMs: 60);
      await g.up();
      expect(rig.pose.pageDx, 0, reason: 'a pull that is let go is back at once');

      final page = await rig.drag(rig.center, const Offset(-260, 0));
      await page.up();
      await tester.pump();
      expect(rig.model.index, 1);
      expect(rig.pose.pageDx, 0, reason: 'a page turn does not slide');

      final far = await rig.drag(rig.center, const Offset(0, 300), stepMs: 40);
      await far.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(PhotoViewer), findsNothing);
    });
  });

  group('loading and failures', () {
    testWidgets('while the bytes arrive: the size, and a spinner that stops when the picture is there', (tester) async {
      final (decoder, log) = await prepared(tester);
      final gate = Completer<void>();
      usePhoneSurface(tester);
      late BuildContext host;
      await pumpApp(tester, Builder(builder: (c) {
        host = c;
        return const SizedBox();
      }));
      unawaited(Navigator.of(host).push(photoViewerRoute(
        items: [fakePhoto('IMG_9.jpg', log, width: 4000, height: 3000, gate: gate, size: 4400000)],
        export: FakeExport(),
        decoder: decoder.call,
      )));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(BusySpinner), findsOneWidget);
      expect(find.text('4.2 MB'), findsOneWidget, reason: 'the size to expect');
      expect(find.text('IMG_9.jpg  ·  4.2 MB'), findsOneWidget, reason: 'the caption already says which file, and how big');

      gate.complete();
      await pumpUntil(tester, () => find.byType(BusySpinner).evaluate().isEmpty);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(BusySpinner), findsNothing, reason: 'nothing spins once the wait is over');
      expect(find.byType(RawImage), findsOneWidget);
    });

    testWidgets('over the cap: a clear message, share it in pieces, copy the path; nothing was read', (tester) async {
      final bytes = Uint8List(5 * 1024 * 1024);
      final fs = FakeFs()..addFile('/p/big.jpg', bytes);
      final files = RemoteFiles(FakeTransport()..fs = fs);
      final export = FakeExport();
      final decoder = FakeDecoder();
      final rig = await _open(
        tester,
        [
          PhotoItem(
            id: '/p/big.jpg',
            name: 'big.jpg',
            path: '/p/big.jpg',
            source: RemotePhotoSource(files, '/p/big.jpg', size: 52 * 1024 * 1024),
          ),
        ],
        decoder,
        export: export,
      );
      expect(find.text('Too large to open here'), findsOneWidget);
      expect(find.text('This photo is 52 MB. The viewer opens photos up to 40 MB.'), findsOneWidget);
      expect(find.text('Share…'), findsOneWidget);
      expect(find.text('Copy path'), findsOneWidget);
      expect(find.text('Retry'), findsNothing, reason: 'trying again cannot help');
      expect(fs.calls.where((c) => c.startsWith('read')), isEmpty);
      expect(rig.model.currentEntry.failure!.kind, PhotoFailureKind.tooLarge);
    });

    testWidgets('a dropped connection offers Retry, which reads again', (tester) async {
      final (decoder, log) = await prepared(tester);
      final item = fakePhoto('a.jpg', log, width: 4000, height: 3000, error: RemoteFileException(RemoteFileErrorKind.network, 'The connection was lost'));
      final rig = await _open(tester, [item], decoder);
      expect(find.text('Connection lost'), findsOneWidget);
      (item.source as FakeSource).error = null;
      await tester.tap(find.text('Retry'));
      await pumpUntil(tester, () => rig.model.currentEntry.ready);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Connection lost'), findsNothing);
      expect(find.byType(RawImage), findsOneWidget);
    });

    testWidgets('bytes that are not a picture offer to view the file as text', (tester) async {
      final decoder = FakeDecoder()..failing = true;
      final log = <String>[];
      final rig = await _open(
        tester,
        [fakePhoto('page.png', log)],
        decoder,
        viewAsText: () => const Scaffold(body: Text('as text')),
      );
      expect(find.text("Can't show this as a picture"), findsOneWidget);
      await tester.tap(find.text('View as text'));
      // One frame and a little more: the buttons of a failure answer at once,
      // not after the 300 ms a double-tap recogniser would hold a tap for.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('as text'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byType(PhotoViewer), findsNothing, reason: 'replaced, not stacked');
      expect(rig.log, isEmpty);
    });
  });

  group('lifecycle', () {
    testWidgets('leaving the viewer frees every bitmap it made, the zoomed one included', (tester) async {
      final (decoder, log) = await prepared(tester);
      final rig = await _open(tester, _three(log), decoder);
      await rig.doubleTap(rig.center);
      await rig.settle(300);
      await pumpUntil(tester, () => rig.model.currentEntry.sharp != null);
      expect(decoder.decoded.length, greaterThanOrEqualTo(3), reason: 'base of 1, base of 2, sharp of 1');

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(PhotoViewer), findsNothing);
      expect([for (final d in decoder.decoded) d.image.debugDisposed], everyElement(isTrue));
    });

    testWidgets('a rotation starts again at fit, with no error, and the photo is still there', (tester) async {
      final (decoder, log) = await prepared(tester);
      final rig = await _open(tester, _three(log), decoder);
      await rig.doubleTap(rig.center);
      await rig.settle();
      expect(rig.pose.scale, closeTo(2.5, 0.001));

      tester.view.physicalSize = const Size(892, 412) * 2.625;
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(rig.pose, PhotoPose.rest);
      expect(find.byType(RawImage), findsOneWidget);
    });
  });

  group('save and share', () {
    testWidgets('the share button offers Save to phone and Share, and a toast says it was saved', (tester) async {
      final (decoder, log) = await prepared(tester);
      final export = FakeExport();
      await _open(tester, _three(log), decoder, export: export);

      await tester.tap(find.byTooltip('Save or share'));
      await tester.pumpAndSettle();
      expect(find.text('Save to phone'), findsOneWidget);
      expect(find.text('Share…'), findsOneWidget);
      expect(find.text('Copy path'), findsOneWidget);

      await tester.tap(find.text('Save to phone'));
      await tester.pumpAndSettle();
      expect(export.saved, ['IMG_0001.jpg:${photoBytes(4000, 3000).length}']);
      expect(find.text('Saved to Pictures/herdr'), findsOneWidget);
    });

    testWidgets('a failure to save is a toast with the reason', (tester) async {
      final (decoder, log) = await prepared(tester);
      final export = FakeExport()..failWith = const PhotoExportException('The phone is out of space.');
      await _open(tester, _three(log), decoder, export: export);
      await tester.tap(find.byTooltip('Save or share'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share…'));
      await tester.pumpAndSettle();
      expect(find.text('The phone is out of space.'), findsOneWidget);
    });
  });

  group('crisp and see-through', () {
    testWidgets('a 32 px picture shown at fit is drawn with the nearest neighbour; a photo is smoothed', (tester) async {
      final tiny = jpegWithExif(32, 32);
      final big = jpegWithExif(1200, 800);
      usePhoneSurface(tester);
      late BuildContext host;
      await pumpApp(tester, Builder(builder: (c) {
        host = c;
        return const SizedBox();
      }));
      unawaited(Navigator.of(host).push(photoViewerRoute(
        items: [
          PhotoItem(id: 'tiny', name: 'tiny.jpg', source: MemoryPhotoSource(() async => tiny, size: tiny.length)),
          PhotoItem(id: 'big', name: 'big.jpg', source: MemoryPhotoSource(() async => big, size: big.length)),
        ],
        export: FakeExport(),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final model = tester.state<PhotoViewerState>(find.byType(PhotoViewer)).model;
      await pumpUntil(tester, () => model.entryAt(1)?.ready ?? false);
      await tester.pump(const Duration(milliseconds: 50));

      FilterQuality quality() => tester.widget<RawImage>(find.byType(RawImage).first).filterQuality;
      expect(quality(), FilterQuality.none, reason: '32 px stretched to 1081 px stays crisp');
      model.goTo(1);
      await tester.pump(const Duration(milliseconds: 100));
      expect(quality(), FilterQuality.medium);
    });

    testWidgets('a PNG with see-through pixels sits on a checkerboard; an opaque JPEG does not', (tester) async {
      final png = pngWithAlpha(64, 64);
      final jpg = jpegWithExif(64, 64);
      usePhoneSurface(tester);
      late BuildContext host;
      await pumpApp(tester, Builder(builder: (c) {
        host = c;
        return const SizedBox();
      }));
      unawaited(Navigator.of(host).push(photoViewerRoute(
        items: [
          PhotoItem(id: 'png', name: 'a.png', source: MemoryPhotoSource(() async => png, size: png.length)),
          PhotoItem(id: 'jpg', name: 'b.jpg', source: MemoryPhotoSource(() async => jpg, size: jpg.length)),
        ],
        export: FakeExport(),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final model = tester.state<PhotoViewerState>(find.byType(PhotoViewer)).model;
      await pumpUntil(tester, () => model.entryAt(1)?.ready ?? false);
      await tester.pump(const Duration(milliseconds: 50));

      Finder checker() => find.descendant(of: find.byType(PhotoPage), matching: find.byWidgetPredicate((w) => w is CustomPaint && w.painter.runtimeType.toString() == '_Checkerboard'));
      expect(checker(), findsOneWidget, reason: 'only the PNG is see-through');
      model.goTo(1);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.descendant(of: find.byType(PhotoPage), matching: find.byWidgetPredicate((w) => w is CustomPaint && w.painter.runtimeType.toString() == '_Checkerboard')), findsNothing,
          reason: 'the png is a neighbour now, off screen and not built');
    });
  });
}
