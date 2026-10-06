import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/features/photos/photo_math.dart';

/// A 4000 x 3000 photo in a 412 x 892 viewport on a 2.625 dpr screen.
PhotoGeometry geometry({Size image = const Size(4000, 3000), Size viewport = const Size(412, 892), double dpr = 2.625}) =>
    PhotoGeometry.forImage(viewport: viewport, image: image, devicePixelRatio: dpr);

void main() {
  group('rubber band', () {
    test('is zero without overshoot and never reaches the limit', () {
      expect(rubberBand(0, 400), 0);
      expect(rubberBand(-5, 400), 0);
      var last = 0.0;
      for (final over in [10.0, 50.0, 100.0, 400.0, 4000.0, 400000.0]) {
        final v = rubberBand(over, 400);
        expect(v, greaterThan(last), reason: 'the more you pull, the more it gives');
        expect(v, lessThan(400), reason: 'but never past the dimension');
        last = v;
      }
    });

    test('follows the finger at first and resists progressively', () {
      // Slope near zero is the constant (0.55): content moves a bit under the finger.
      expect(rubberBand(1, 400) / 1, closeTo(0.55, 0.01));
      // 100 px of pull gives well under 100 px.
      expect(rubberBand(100, 400), lessThan(60));
      expect(rubberBand(200, 400) - rubberBand(100, 400), lessThan(rubberBand(100, 400) - rubberBand(0, 400)));
    });

    test('rubberBandedValue is the identity inside and symmetric outside', () {
      expect(rubberBandedValue(5, -10, 10, 400), 5);
      expect(rubberBandedValue(10, -10, 10, 400), 10);
      expect(rubberBandedValue(60, -10, 10, 400), 10 + rubberBand(50, 400));
      expect(rubberBandedValue(-60, -10, 10, 400), -10 - rubberBand(50, 400));
    });

    test('a scale pinched out of range resists in ratios and never goes below 0.6 or far past the max', () {
      expect(rubberBandedScale(2, 1, 8), 2);
      expect(rubberBandedScale(1, 1, 8), 1);
      final below = rubberBandedScale(0.5, 1, 8);
      expect(below, lessThan(1));
      expect(below, greaterThan(0.5), reason: 'it gives, but less than the fingers');
      expect(rubberBandedScale(0.01, 1, 8), greaterThan(0.6), reason: 'never shrinks to nothing');
      final above = rubberBandedScale(16, 1, 8);
      expect(above, greaterThan(8));
      expect(above, lessThan(16));
      expect(rubberBandedScale(1e9, 1, 8), lessThan(8 * 1.45));
      expect(rubberBandedScale(0, 1, 8), 1);
    });
  });

  group('geometry', () {
    test('fit is the largest size that fits; scale 1 is "fit"', () {
      final g = geometry();
      expect(g.fit.width, closeTo(412, 0.01));
      expect(g.fit.height, closeTo(309, 0.01));
      // Wider than tall in a tall viewport: width-bound. A tall photo is height-bound.
      final tall = geometry(image: const Size(3000, 4000), viewport: const Size(412, 500));
      expect(tall.fit.height, closeTo(500, 0.01));
      expect(tall.fit.width, closeTo(375, 0.01));
    });

    test('a picture that fits the viewport on an axis stays centred on it', () {
      final g = geometry();
      final limit = g.panLimit(1);
      expect(limit, Offset.zero);
      // At 2.5x the width overflows (412 * 2.5 > 412) but the height does not yet (309 * 2.5 = 772 < 892).
      final at = g.panLimit(2.5);
      expect(at.dx, closeTo((412 * 2.5 - 412) / 2, 0.01));
      expect(at.dy, 0, reason: 'still shorter than the screen: centred vertically');
      expect(g.panLimit(4).dy, closeTo((309 * 4 - 892) / 2, 0.5));
    });

    test('max scale: 3x actual size, at least 4, at most 16', () {
      expect(geometry().maxScale, closeTo(4000 / 2.625 / 412 * 3, 0.01), reason: '12 MP photo');
      expect(geometry(image: const Size(32, 32)).maxScale, 4, reason: 'an icon has no useful actual size');
      expect(geometry(image: const Size(40000, 30000)).maxScale, 16);
    });

    test('scale clamps to 1..max: never smaller than fit', () {
      final g = geometry();
      expect(g.clampScale(0.6), 1, reason: 'the old minScale 0.6 bug: nothing rests smaller than fit');
      expect(g.clampScale(3), 3);
      expect(g.clampScale(1000), g.maxScale);
    });

    test('offset clamps to what the picture allows at that scale', () {
      final g = geometry();
      expect(g.clampOffset(const Offset(500, 500), 1), Offset.zero);
      final c = g.clampOffset(const Offset(900, -900), 2.5);
      expect(c.dx, closeTo((412 * 2.5 - 412) / 2, 0.01));
      expect(c.dy, 0);
    });
  });

  group('zooming around the fingers', () {
    test('the point under the fingers stays under them', () {
      final g = geometry();
      const focal = Offset(80, -120);
      const fromOffset = Offset(30, 10);
      const from = 1.7, to = 3.2;
      final offset = g.anchoredOffset(focal: focal, fromScale: from, fromOffset: fromOffset, toScale: to);
      // The scene point under the focal: (focal - offset) / scale, before and after.
      final before = (focal - fromOffset) / from;
      final after = (focal - offset) / to;
      expect(after.dx, closeTo(before.dx, 1e-9));
      expect(after.dy, closeTo(before.dy, 1e-9));
    });

    test('zooming about the centre only scales (the offset stays)', () {
      final g = geometry();
      expect(g.anchoredOffset(focal: Offset.zero, fromScale: 1, fromOffset: Offset.zero, toScale: 3), Offset.zero);
    });

    test('zooming about a corner moves the picture away from it', () {
      final g = geometry();
      final o = g.anchoredOffset(focal: const Offset(200, 300), fromScale: 1, fromOffset: Offset.zero, toScale: 2);
      expect(o, const Offset(-200, -300));
    });
  });

  group('double tap', () {
    test('at fit it goes to 2.5x around the tapped point', () {
      final g = geometry();
      final t = g.doubleTapTarget(scale: 1, offset: Offset.zero, focal: const Offset(100, 0));
      expect(t.scale, 2.5);
      // Anchored: x = 100 - 100 * 2.5 = -150, and inside the limit (618 / 2 = 309).
      expect(t.offset.dx, closeTo(-150, 1e-9));
      expect(t.offset.dy, 0, reason: 'the zoomed picture is still shorter than the screen');
    });

    test('a tap near the edge is kept inside the picture', () {
      final g = geometry();
      final t = g.doubleTapTarget(scale: 1, offset: Offset.zero, focal: const Offset(-206, 0));
      expect(t.offset.dx, closeTo(309, 1e-9), reason: 'clamped to the pan limit, not 515 past it');
    });

    test('zoomed it goes back to fit, and to exactly fit', () {
      final g = geometry();
      final t = g.doubleTapTarget(scale: 2.5, offset: const Offset(-150, 0), focal: const Offset(100, 0));
      expect(t.scale, 1);
      expect(t.offset, Offset.zero);
    });

    test('a barely zoomed picture still counts as zoomed', () {
      final g = geometry();
      expect(g.doubleTapTarget(scale: 1.2, offset: Offset.zero, focal: Offset.zero).scale, 1);
      expect(g.doubleTapTarget(scale: 1.02, offset: Offset.zero, focal: Offset.zero).scale, 2.5);
    });

    test('never aims past what the picture allows', () {
      final small = PhotoGeometry(viewport: const Size(400, 800), fit: const Size(400, 300), maxScale: 1.5);
      expect(small.doubleTapTarget(scale: 1, offset: Offset.zero, focal: Offset.zero).scale, 1.5);
    });
  });

  group('dismiss', () {
    test('progress is the drag over a third of the height, capped at 1', () {
      expect(dismissProgress(0, 900), 0);
      expect(dismissProgress(150, 900), closeTo(0.5, 1e-9));
      expect(dismissProgress(-150, 900), closeTo(0.5, 1e-9), reason: 'up or down');
      expect(dismissProgress(5000, 900), 1);
      expect(dismissProgress(10, 0), 0);
    });

    test('a short slow drag does not dismiss, a long one does', () {
      expect(shouldDismiss(60, 0, 892), isFalse);
      expect(shouldDismiss(150, 0, 892), isFalse);
      expect(shouldDismiss(220, 0, 892), isTrue);
      expect(shouldDismiss(-220, 0, 892), isTrue);
    });

    test('a short fast flick dismisses (the projected end counts)', () {
      expect(shouldDismiss(60, 1500, 892), isTrue);
      expect(shouldDismiss(-60, -1500, 892), isTrue);
      expect(shouldDismiss(60, 300, 892), isFalse, reason: 'a slow one does not');
    });

    test('moving back against the drag cancels, however far it went', () {
      expect(shouldDismiss(300, -400, 892), isFalse);
      expect(shouldDismiss(400, -1500, 892), isFalse);
      expect(shouldDismiss(-300, 400, 892), isFalse);
    });

    test('no drag and no speed is not a dismissal', () {
      expect(shouldDismiss(0, 0, 892), isFalse);
    });
  });

  group('paging', () {
    test('a pull past 30% of the width, or a flick, turns the page; a neighbour must exist', () {
      expect(pageDecision(150, 0, 400, hasPrevious: true, hasNext: true), -1, reason: 'dragged right: the previous photo');
      expect(pageDecision(-150, 0, 400, hasPrevious: true, hasNext: true), 1);
      expect(pageDecision(60, 0, 400, hasPrevious: true, hasNext: true), 0);
      expect(pageDecision(40, 1200, 400, hasPrevious: true, hasNext: true), -1);
      expect(pageDecision(150, 0, 400, hasPrevious: false, hasNext: true), 0, reason: 'nothing before the first');
      expect(pageDecision(-150, 0, 400, hasPrevious: true, hasNext: false), 0, reason: 'nothing after the last');
    });

    test('a pull that is being taken back stays', () {
      expect(pageDecision(200, -600, 400, hasPrevious: true, hasNext: true), 0);
      expect(pageDecision(-200, 600, 400, hasPrevious: true, hasNext: true), 0);
    });
  });

  group('projection', () {
    test('matches the exponential-decay form', () {
      expect(project(1000, decelerationRate: 0.998), closeTo(499, 0.01));
      expect(project(-1000), closeTo(-99, 0.01));
      expect(project(0), 0);
    });
  });

  group('sharpening and crispness', () {
    test('a sharper bitmap is wanted only when the picture is stretched past the one decoded', () {
      final g = geometry();
      // Fit shows 412 dp * 2.625 = 1081 px; a 1623 px bitmap covers up to 1.5x.
      bool wants(double scale, {int decoded = 1623}) => wantsSharper(
        geometry: g,
        scale: scale,
        devicePixelRatio: 2.625,
        decodedWidth: decoded,
        nativeWidth: 4000,
      );
      expect(wants(1), isFalse);
      expect(wants(1.4), isFalse);
      expect(wants(1.6), isTrue);
      expect(wants(3, decoded: 4000), isFalse, reason: 'already every pixel of the file');
    });

    test('nearest neighbour only past 2 device pixels per bitmap pixel', () {
      expect(useNearestNeighbour(shownWidth: 412, devicePixelRatio: 2.625, bitmapWidth: 32), isTrue);
      expect(useNearestNeighbour(shownWidth: 412, devicePixelRatio: 2.625, bitmapWidth: 500), isTrue);
      expect(useNearestNeighbour(shownWidth: 412, devicePixelRatio: 2.625, bitmapWidth: 541), isFalse);
      expect(useNearestNeighbour(shownWidth: 412, devicePixelRatio: 2.625, bitmapWidth: 1080), isFalse);
      expect(useNearestNeighbour(shownWidth: 412, devicePixelRatio: 2.625, bitmapWidth: 0), isFalse);
      expect(useNearestNeighbour(shownWidth: 100, devicePixelRatio: 1, bitmapWidth: 49), isTrue);
    });
  });
}
