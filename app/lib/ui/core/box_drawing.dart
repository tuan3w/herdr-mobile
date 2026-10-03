import 'dart:math' as math;
import 'dart:ui' show Offset, Path, Rect;

import 'box_drawing_table.dart';

/// Procedural geometry for the box drawing (U+2500-257F) and block element
/// (U+2580-259F) characters.
///
/// Fonts draw these with metrics of their own, so next to a different font's
/// cell they come out dashed, stubby or misaligned. A terminal draws them
/// itself so they fill the cell exactly and neighbouring cells meet without a
/// seam. Everything here works in whole **device pixels**: a cell is the box
/// `[x0, x1) x [y0, y1)` of integers, and every returned rectangle has integer
/// edges, so painting it without anti-aliasing gives identical pixels however
/// the row is positioned.
///
/// Pure geometry: the only Flutter dependency is the `dart:ui` value types.

/// Whether [rune] is drawn by [boxGlyph].
bool isBoxGlyph(int rune) => rune >= 0x2500 && rune <= 0x259f;

/// Thickness in device pixels of a light line in a cell [cellWidthPx] wide
/// (anything fractional is fine): an eighth of the cell, at least one pixel.
/// Heavy lines are twice that, and each stroke of a double line is one light
/// stroke with one light stroke between them.
int lightStroke(double cellWidthPx) => math.max(1, (cellWidthPx / 8).round());

/// A stroked curve or line (anti-aliased, flat caps).
final class GlyphStroke {
  const GlyphStroke(this.path, this.width, {this.clip});

  /// In device pixels, absolute (cell position included).
  final Path path;
  final double width;

  /// The stroke is cut off outside this box, when it overshoots on purpose.
  final Rect? clip;
}

/// What to paint for one glyph, in device pixels.
final class GlyphShape {
  const GlyphShape({
    this.rects = const [],
    this.alpha = 1,
    this.strokes = const [],
  });

  /// Axis-aligned fills with integer edges; paint without anti-aliasing.
  final List<Rect> rects;

  /// Opacity of [rects] (shades blend the foreground over what is behind).
  final double alpha;

  /// Curves and diagonals, which are anti-aliased.
  final List<GlyphStroke> strokes;
}

/// The shape of [rune] in the cell `[x0, x1) x [y0, y1)` (device pixels) with
/// light strokes [light] pixels thick, or null when [rune] is not a box or
/// block character.
GlyphShape? boxGlyph(
  int rune, {
  required int x0,
  required int x1,
  required int y0,
  required int y1,
  required int light,
}) {
  if (!isBoxGlyph(rune)) return null;
  final cell = _Cell(x0, x1, y0, y1, light);
  final code = boxGlyphCodes[rune - 0x2500];
  final param = code >> 11;
  switch ((code >> 8) & 7) {
    case 1:
      return GlyphShape(rects: _merge(_arms(cell, code)));
    case 2:
      return GlyphShape(rects: _dashes(cell, code, 2 + (param & 3)));
    case 3:
      return GlyphShape(strokes: [_arc(cell, code)]);
    case 4:
      return GlyphShape(strokes: _diagonals(cell, param));
    case 5:
      return GlyphShape(rects: [
        _eighths(cell, param & 15, (param >> 4) & 15, (param >> 8) & 15,
            (param >> 12) & 15),
      ]);
    case 6:
      return GlyphShape(
        rects: [Rect.fromLTRB(x0.toDouble(), y0.toDouble(), x1.toDouble(), y1.toDouble())],
        alpha: param * 0.25,
      );
    case 7:
      return GlyphShape(rects: _merge(_quadrants(cell, param)));
  }
  return null;
}

final class _Cell {
  const _Cell(this.x0, this.x1, this.y0, this.y1, this.t);

  final int x0, x1, y0, y1;

  /// Light stroke thickness.
  final int t;

  int get w => x1 - x0;
  int get h => y1 - y0;
}

Rect _rect(int l, int t, int r, int b) =>
    Rect.fromLTRB(l.toDouble(), t.toDouble(), r.toDouble(), b.toDouble());

/// Pixels a stroke of [weight] (1 light, 2 heavy, 3 double) takes across.
int _thickness(int weight, int t) => weight * t;

/// The lines of a stroke of [weight] starting at [start] across: one band for
/// light and heavy, two light ones with a light gap for double. Each is
/// (from, to, side) where side is -1 for the low (left/top) line of a double,
/// 1 for the high one, 0 for a single band.
List<(int, int, int)> _bands(int weight, int start, int t) => weight == 3
    ? [(start, start + t, -1), (start + 2 * t, start + 3 * t, 1)]
    : [(start, start + _thickness(weight, t), 0)];

List<Rect> _arms(_Cell c, int code) {
  final l = code & 3, r = (code >> 2) & 3, u = (code >> 4) & 3, d = (code >> 6) & 3;
  final t = c.t;
  final midX = c.x0 + c.w ~/ 2;
  final midY = c.y0 + c.h ~/ 2;

  int startX(int weight) => c.x0 + (c.w - _thickness(weight, t)) ~/ 2;
  int startY(int weight) => c.y0 + (c.h - _thickness(weight, t)) ~/ 2;

  // The junction: the widest vertical band and the tallest horizontal one,
  // which the arms of the other direction butt against.
  final vWeight = math.max(u, d);
  final hWeight = math.max(l, r);
  final vx0 = startX(vWeight);
  final vx1 = vx0 + _thickness(vWeight, t);
  final hy0 = startY(hWeight);
  final hy1 = hy0 + _thickness(hWeight, t);
  final hasH = hWeight > 0;
  final hasV = vWeight > 0;

  final out = <Rect>[];

  // Vertical arms. A stroke of a double line on the same side as a double
  // horizontal arm stops at that arm's inner line; everything else reaches
  // across the junction (or just to the middle when nothing crosses).
  for (final (weight, up) in [(u, true), (d, false)]) {
    if (weight == 0) continue;
    for (final (a, b, side) in _bands(weight, startX(weight), t)) {
      final inner = (side < 0 && l == 3) || (side > 0 && r == 3);
      final int from, to;
      if (up) {
        from = c.y0;
        to = !hasH ? midY : (inner ? hy0 + t : hy1);
      } else {
        from = !hasH ? midY : (inner ? hy1 - t : hy0);
        to = c.y1;
      }
      out.add(_rect(a, from, b, to));
    }
  }

  // Horizontal arms, mirrored.
  for (final (weight, left) in [(l, true), (r, false)]) {
    if (weight == 0) continue;
    for (final (a, b, side) in _bands(weight, startY(weight), t)) {
      final inner = (side < 0 && u == 3) || (side > 0 && d == 3);
      final int from, to;
      if (left) {
        from = c.x0;
        to = !hasV ? midX : (inner ? vx0 + t : vx1);
      } else {
        from = !hasV ? midX : (inner ? vx1 - t : vx0);
        to = c.x1;
      }
      out.add(_rect(from, a, to, b));
    }
  }
  return out;
}

/// Dashed lines: [count] dashes per cell, every gap split across the cell
/// edges so neighbouring cells continue the pattern.
List<Rect> _dashes(_Cell c, int code, int count) {
  final horizontal = (code & 15) != 0;
  final weight = horizontal ? code & 3 : (code >> 4) & 3;
  final thick = _thickness(weight, c.t);
  final length = horizontal ? c.w : c.h;
  final gap = math.max(1, (length / count / 3).round());
  final before = gap ~/ 2;
  final after = gap - before;
  final start = (horizontal ? c.y0 + (c.h - thick) ~/ 2 : c.x0 + (c.w - thick) ~/ 2);
  final origin = horizontal ? c.x0 : c.y0;
  final out = <Rect>[];
  for (var i = 0; i < count; i++) {
    final a = origin + (length * i + count ~/ 2) ~/ count + before;
    final b = origin + (length * (i + 1) + count ~/ 2) ~/ count - after;
    if (b <= a) continue;
    out.add(horizontal
        ? _rect(a, start, b, start + thick)
        : _rect(start, a, start + thick, b));
  }
  return out;
}

/// A light arc joining a horizontal and a vertical arm, which end on the
/// middle of the cell edges exactly like the straight lines next to them.
GlyphStroke _arc(_Cell c, int code) {
  final t = c.t;
  final cx = c.x0 + (c.w - t) ~/ 2 + t / 2;
  final cy = c.y0 + (c.h - t) ~/ 2 + t / 2;
  final toRight = ((code >> 2) & 3) != 0;
  final toDown = ((code >> 6) & 3) != 0;
  final r = math.min(c.w, c.h) / 2;
  final edgeX = toRight ? c.x1.toDouble() : c.x0.toDouble();
  final edgeY = toDown ? c.y1.toDouble() : c.y0.toDouble();
  final dx = toRight ? 1.0 : -1.0;
  final dy = toDown ? 1.0 : -1.0;
  final path = Path()
    ..moveTo(edgeX, cy)
    ..lineTo(cx + dx * r, cy)
    ..quadraticBezierTo(cx, cy, cx, cy + dy * r)
    ..lineTo(cx, edgeY);
  return GlyphStroke(path, t.toDouble());
}

/// Diagonals reach past the corners (by a stroke width) so those of
/// neighbouring cells join, and are cut off at the cell.
List<GlyphStroke> _diagonals(_Cell c, int mask) {
  final box = _rect(c.x0, c.y0, c.x1, c.y1);
  final w = c.w.toDouble(), h = c.h.toDouble();
  final len = math.sqrt(w * w + h * h);
  final ex = c.t * w / len, ey = c.t * h / len;
  GlyphStroke line(Offset a, Offset b) => GlyphStroke(
        Path()
          ..moveTo(a.dx, a.dy)
          ..lineTo(b.dx, b.dy),
        c.t.toDouble(),
        clip: box,
      );
  return [
    if ((mask & 1) != 0)
      line(Offset(c.x1 + ex, c.y0 - ey), Offset(c.x0 - ex, c.y1 + ey)),
    if ((mask & 2) != 0)
      line(Offset(c.x0 - ex, c.y0 - ey), Offset(c.x1 + ex, c.y1 + ey)),
  ];
}

/// The block of the cell between eighths [a]..[c] across and [b]..[d] down.
Rect _eighths(_Cell cell, int a, int b, int c, int d) {
  int x(int n) => cell.x0 + (cell.w * n + 4) ~/ 8;
  int y(int n) => cell.y0 + (cell.h * n + 4) ~/ 8;
  return _rect(x(a), y(b), x(c), y(d));
}

List<Rect> _quadrants(_Cell c, int mask) {
  final mx = c.x0 + (c.w + 1) ~/ 2;
  final my = c.y0 + (c.h + 1) ~/ 2;
  return [
    if ((mask & 1) != 0) _rect(c.x0, c.y0, mx, my),
    if ((mask & 2) != 0) _rect(mx, c.y0, c.x1, my),
    if ((mask & 4) != 0) _rect(c.x0, my, mx, c.y1),
    if ((mask & 8) != 0) _rect(mx, my, c.x1, c.y1),
  ];
}

/// Joins rectangles that touch with the same extent across, so a line
/// through a cell is one fill.
List<Rect> _merge(List<Rect> rects) {
  final out = List<Rect>.of(rects);
  var merged = true;
  while (merged) {
    merged = false;
    outer:
    for (var i = 0; i < out.length; i++) {
      for (var j = i + 1; j < out.length; j++) {
        final a = out[i], b = out[j];
        final sameX = a.left == b.left && a.right == b.right;
        final sameY = a.top == b.top && a.bottom == b.bottom;
        if (sameX && a.top <= b.bottom && b.top <= a.bottom ||
            sameY && a.left <= b.right && b.left <= a.right) {
          out[i] = a.expandToInclude(b);
          out.removeAt(j);
          merged = true;
          break outer;
        }
      }
    }
  }
  return out;
}
