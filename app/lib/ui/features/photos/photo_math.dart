import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/painting.dart' show BoxFit, applyBoxFit;

/// The arithmetic of the photo viewer's gestures, free of widgets so it can be
/// tested on its own.
///
/// A picture is placed by a **scale** relative to "fit" (1 shows the whole
/// picture, the largest size that fits the viewport) and an **offset**: how far
/// the picture's centre is from the viewport's centre, in logical pixels.
/// Everything that talks about a "focal point" does so relative to the
/// viewport's centre.

/// How far a flick travels after the finger lifts, in the units of velocity
/// (pixels per second): Apple's `project` from "Designing Fluid Interfaces",
/// with the snappier deceleration rate. `v / 1000 * d / (1 - d)`.
double project(double velocity, {double decelerationRate = 0.99}) =>
    velocity / 1000 * decelerationRate / (1 - decelerationRate);

/// A boundary that gives way instead of stopping: the further past the edge a
/// drag goes ([overshoot], at least 0), the less the content follows: it starts
/// at [constant] of the finger's speed and never moves more than [dimension].
/// Apple's rubber-banding function; callers pass a fraction of the screen as
/// [dimension] to say how far a boundary may be stretched.
double rubberBand(double overshoot, double dimension, {double constant = 0.55}) {
  if (overshoot <= 0 || dimension <= 0) return 0;
  return (overshoot * dimension * constant) / (dimension + constant * overshoot);
}

/// [raw] with the part beyond [min]..[max] rubber-banded (symmetric on both
/// sides). Inside the range it is returned as it is.
double rubberBandedValue(double raw, double min, double max, double dimension) {
  if (raw > max) return max + rubberBand(raw - max, dimension);
  if (raw < min) return min - rubberBand(min - raw, dimension);
  return raw;
}

/// A pinched scale shown with resistance outside [min]..[max]. Scale is
/// perceived in ratios, so the band works on the logarithm: pinching to a
/// quarter of "fit" shows about 0.7, not a quarter.
double rubberBandedScale(double raw, double min, double max) {
  if (raw <= 0) return min;
  if (raw > max) return max * math.exp(rubberBand(math.log(raw / max), 0.35));
  if (raw < min) return min * math.exp(-rubberBand(math.log(min / raw), 0.4));
  return raw;
}

/// Where the picture sits in the viewport and what it may do there.
class PhotoGeometry {
  const PhotoGeometry({required this.viewport, required this.fit, required this.maxScale});

  /// Fit size for a picture of [image] pixels, one image pixel per device
  /// pixel at the scale [actualScale] reports. [maxScale] is how far a person
  /// may zoom: 3x the scale that shows one image pixel per device pixel, at
  /// least 4x (a 32 px icon has no "actual size" worth reaching), at most 16x.
  factory PhotoGeometry.forImage({required Size viewport, required Size image, required double devicePixelRatio}) {
    final fit = image.isEmpty || viewport.isEmpty
        ? viewport
        : applyBoxFit(BoxFit.contain, image, viewport).destination;
    final actual = fit.width <= 0 ? 1.0 : image.width / devicePixelRatio / fit.width;
    return PhotoGeometry(viewport: viewport, fit: fit, maxScale: (actual * 3).clamp(4.0, 16.0));
  }

  final Size viewport;

  /// The picture at scale 1.
  final Size fit;

  /// The largest scale the person may leave the picture at.
  final double maxScale;

  /// Scale that shows one image pixel per device pixel, for an [image] of that
  /// many pixels.
  double actualScale(Size image, double devicePixelRatio) =>
      fit.width <= 0 ? 1 : image.width / devicePixelRatio / fit.width;

  /// How far the picture's centre may be from the viewport's centre at
  /// [scale], per axis: 0 while the picture is not larger than the viewport on
  /// that axis (it stays centred), otherwise half of what overflows.
  Offset panLimit(double scale) => Offset(
    math.max(0, (fit.width * scale - viewport.width) / 2),
    math.max(0, (fit.height * scale - viewport.height) / 2),
  );

  double clampScale(double scale) => scale.clamp(1.0, maxScale);

  /// [offset] moved inside what [scale] allows.
  Offset clampOffset(Offset offset, double scale) {
    final limit = panLimit(scale);
    return Offset(offset.dx.clamp(-limit.dx, limit.dx), offset.dy.clamp(-limit.dy, limit.dy));
  }

  /// The offset that keeps the point of the picture that is under [focal] at
  /// [fromScale] and [fromOffset] under [focal] at [toScale]: zooming around
  /// the fingers.
  Offset anchoredOffset({
    required Offset focal,
    required double fromScale,
    required Offset fromOffset,
    required double toScale,
  }) => focal - (focal - fromOffset) * (toScale / fromScale);

  /// The pose a double tap at [focal] aims for: back to fit when the picture is
  /// zoomed (past [zoomedThreshold]), else [zoomTo] (2.5x unless the picture
  /// cannot go that far) around the tapped point, kept inside the picture.
  ({double scale, Offset offset}) doubleTapTarget({
    required double scale,
    required Offset offset,
    required Offset focal,
    double zoomTo = 2.5,
    double zoomedThreshold = 1.05,
  }) {
    if (scale > zoomedThreshold) return (scale: 1.0, offset: Offset.zero);
    final target = math.min(zoomTo, maxScale);
    final anchored = anchoredOffset(focal: focal, fromScale: scale, fromOffset: offset, toScale: target);
    return (scale: target, offset: clampOffset(anchored, target));
  }
}

/// How far into dismissing a drag of [dy] at fit is, 0 to 1 over a third of the
/// viewport's height. Drives the background fade and the shrinking picture.
double dismissProgress(double dy, double viewportHeight) =>
    viewportHeight <= 0 ? 0 : (dy.abs() / (viewportHeight / 3)).clamp(0.0, 1.0);

/// Whether letting go at a drag of [dy] with vertical velocity [vy] (px/s)
/// closes the viewer. Decided from where the drag is heading (its projected
/// end), not from where it is: a long drag that is being pulled back does not
/// close, a short flick does. Moving against the drag at speed always cancels.
bool shouldDismiss(double dy, double vy, double viewportHeight) {
  if (dy == 0 && vy == 0) return false;
  final against = dy != 0 && vy != 0 && dy.sign != vy.sign;
  if (against && vy.abs() > 300) return false;
  final end = dy + project(vy);
  return end.abs() > viewportHeight * 0.22;
}

/// What a horizontal release at [dx] (how far the current page has been pulled
/// aside, positive = to the right, which reveals the previous photo) with
/// velocity [vx] does: -1 the previous photo, 1 the next, 0 stay. A neighbour
/// that does not exist cannot be chosen.
int pageDecision(double dx, double vx, double viewportWidth, {required bool hasPrevious, required bool hasNext}) {
  final end = dx + project(vx);
  final against = dx != 0 && vx != 0 && dx.sign != vx.sign && vx.abs() > 300;
  if (against) return 0;
  if (end > viewportWidth * 0.3 && hasPrevious) return -1;
  if (end < -viewportWidth * 0.3 && hasNext) return 1;
  return 0;
}

/// Whether the picture, shown at [scale] on a [geometry], has more device
/// pixels than the [decodedWidth] bitmap holds (so the bitmap is being
/// stretched and a sharper decode would show more).
bool wantsSharper({
  required PhotoGeometry geometry,
  required double scale,
  required double devicePixelRatio,
  required int decodedWidth,
  required int nativeWidth,
}) {
  if (decodedWidth >= nativeWidth) return false;
  return geometry.fit.width * scale * devicePixelRatio > decodedWidth * 1.05;
}

/// Whether a picture shown [shownWidth] logical pixels wide, from a bitmap
/// [bitmapWidth] pixels wide, is enlarged so far that smoothing would only
/// blur it: past 2 device pixels per bitmap pixel it is drawn with the nearest
/// neighbour (pixel art, icons, small screenshots stay crisp).
bool useNearestNeighbour({required double shownWidth, required double devicePixelRatio, required int bitmapWidth}) =>
    bitmapWidth > 0 && shownWidth * devicePixelRatio > bitmapWidth * 2;
