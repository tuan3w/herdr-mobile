import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'ansi.dart';
import 'box_drawing.dart';
import 'cell_width.dart';
import 'terminal_document.dart';
import 'terminal_links.dart';
import 'theme.dart';

/// Row height as a multiple of the font size, before snapping to pixels.
const terminalLineHeightFactor = 1.3;

/// How far dim (SGR 2) text is blended from the background to its colour.
const _dimBlend = 0.62;

/// Rows kept prepared (text span, recorded picture) after they have been
/// built. Many times what fits a screen, so scrolling back a little reuses
/// them; the oldest are released first.
const _cachedLines = 512;

/// Geometry of the terminal's cell grid at one font size and pixel density.
///
/// A cell is [advance] logical pixels wide (the measured monospace advance) and
/// [lineHeight] high, where the height is a whole number of device pixels
/// ([rowPx]) so that rows tile without sub-pixel seams. Column edges are
/// snapped to device pixels too (see [TerminalLine]).
final class CellMetrics {
  CellMetrics({
    required this.fontSize,
    required this.advance,
    required this.dpr,
    TerminalPalette? palette,
  }) : palette = palette ?? TerminalPalette.dark,
       rowPx = (fontSize * terminalLineHeightFactor * dpr).round();

  /// Measures the monospace advance at [fontSize]. Does text layout, so keep
  /// the result around instead of measuring per frame.
  factory CellMetrics.measure(double fontSize, double dpr, {TerminalPalette? palette}) {
    const sample = 'MMMMMMMMMMMMMMMM';
    final painter = TextPainter(
      text: TextSpan(
        text: sample,
        style: TextStyle(
          fontFamily: monoFamily,
          fontSize: fontSize,
          height: terminalLineHeightFactor,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();
    final advance = painter.width / sample.length;
    painter.dispose();
    return CellMetrics(fontSize: fontSize, advance: advance, dpr: dpr, palette: palette);
  }

  final double fontSize;

  /// The colours rows are drawn in (the theme's; see [TerminalPalette.recolor]).
  final TerminalPalette palette;

  /// Logical pixels per column.
  final double advance;

  /// Device pixels per logical pixel.
  final double dpr;

  /// Row height in device pixels.
  final int rowPx;

  /// Row height in logical pixels: exactly [rowPx] device pixels.
  double get lineHeight => rowPx / dpr;

  /// Column width in (fractional) device pixels.
  double get advancePx => advance * dpr;

  /// Light stroke thickness in device pixels.
  int get lightPx => lightStroke(advancePx);

  /// Device-pixel x of the left edge of column [column]. Neighbouring cells
  /// share an edge by construction.
  int columnEdge(int column) => (column * advancePx).round();

  /// Text style of the row text; its line height fills the snapped row.
  late final TextStyle textStyle = TextStyle(
    fontFamily: monoFamily,
    fontSize: fontSize,
    height: lineHeight / fontSize,
    color: palette.foreground,
  );

  late final StrutStyle strut = StrutStyle(
    fontFamily: monoFamily,
    fontSize: fontSize,
    height: lineHeight / fontSize,
    leading: 0,
    forceStrutHeight: true,
  );

  /// Distance from the top of a row to its text baseline, in logical pixels.
  /// Measured on the row's own style, so an underline lands where the font
  /// puts it.
  late final double baseline = () {
    final painter = TextPainter(
      text: TextSpan(text: 'M', style: textStyle),
      strutStyle: strut,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();
    final distance = painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    painter.dispose();
    return distance;
  }();

  /// The cell at logical pixel [dx] of a row.
  int columnAt(double dx) => math.max(0, (dx / advance).floor());

  @override
  bool operator ==(Object other) =>
      other is CellMetrics &&
      other.fontSize == fontSize &&
      other.advance == advance &&
      other.dpr == dpr &&
      identical(other.palette, palette);

  @override
  int get hashCode => Object.hash(fontSize, advance, dpr, palette);
}

/// The colour glyphs of [run] are drawn in: dim text is blended towards the
/// background, otherwise the foreground (default when unset). [run] is already
/// in [palette]'s colours.
Color runForeground(AnsiRun run, TerminalPalette palette) => run.dim
    ? Color.lerp(
        run.bg ?? palette.background,
        run.fg ?? palette.foreground,
        _dimBlend,
      )!
    : (run.fg ?? palette.foreground);

/// Text style of [run]. Backgrounds are not part of it (they are painted by
/// [TerminalLinePainter] across the whole row height); null for plain text.
TextStyle? runTextStyle(AnsiRun run, TerminalPalette palette) {
  final decoration = switch ((run.underline, run.strike)) {
    (true, true) => TextDecoration.combine(const [
        TextDecoration.underline,
        TextDecoration.lineThrough,
      ]),
    (true, false) => TextDecoration.underline,
    (false, true) => TextDecoration.lineThrough,
    _ => null,
  };
  if (run.fg == null &&
      !run.bold &&
      !run.dim &&
      !run.italic &&
      decoration == null) {
    return null;
  }
  return TextStyle(
    color: run.dim ? runForeground(run, palette) : run.fg,
    fontWeight: run.bold ? FontWeight.w700 : null,
    fontStyle: run.italic ? FontStyle.italic : null,
    decoration: decoration,
  );
}

/// [text] with every character the painter draws itself (box drawing and block
/// elements) replaced by a space, so the columns of the text layer stay
/// aligned and the font's own glyphs never show. Selecting and copying a
/// border therefore yields spaces.
String blankSprites(String text) {
  var from = -1;
  for (var i = 0; i < text.length; i++) {
    if (isBoxGlyph(text.codeUnitAt(i))) {
      from = i;
      break;
    }
  }
  if (from < 0) return text;
  final out = StringBuffer(text.substring(0, from));
  for (var i = from; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    out.writeCharCode(isBoxGlyph(unit) ? 0x20 : unit);
  }
  return out.toString();
}

/// One terminal row prepared for drawing: its text span and, built the first
/// time it is painted, a recorded picture of everything the painter draws for
/// it (backgrounds and procedural glyphs). Neither is rebuilt per frame.
///
/// Owns a native [ui.Picture]; [dispose] releases it.
final class TerminalLine {
  TerminalLine(List<AnsiRun> runs, this.metrics, {this.links = const []})
    : runs = metrics.palette.isDark
          ? runs
          : [for (final run in runs) metrics.palette.recolor(run)];

  /// The row's runs in the colours of [CellMetrics.palette].
  final List<AnsiRun> runs;
  final CellMetrics metrics;

  /// Links on this row (cells of the row), underlined and tappable.
  final List<RowLink> links;

  late final TextSpan span = TextSpan(
    children: links.isEmpty
        ? [
            for (final run in runs)
              TextSpan(text: blankSprites(run.text), style: runTextStyle(run, metrics.palette)),
          ]
        : _linkSpans(),
  );

  /// The link under cell [column], if any.
  TerminalLink? linkAt(int column) {
    for (final link in links) {
      if (column >= link.start && column < link.end) return link.link;
    }
    return null;
  }

  bool _linked(int column) {
    for (final link in links) {
      if (column >= link.start && column < link.end) return true;
    }
    return false;
  }

  /// The runs cut at the edges of the links, the linked pieces in
  /// the palette's link colour unless the run already has a colour of its own.
  List<TextSpan> _linkSpans() {
    final spans = <TextSpan>[];
    var column = 0;
    for (final run in runs) {
      final text = run.text;
      final style = runTextStyle(run, metrics.palette);
      var from = 0;
      var unit = 0;
      var linked = _linked(column);
      void flush(int to) {
        if (to <= from) return;
        final piece = blankSprites(text.substring(from, to));
        spans.add(
          TextSpan(
            text: piece,
            style: linked && run.fg == null
                ? (style ?? const TextStyle()).copyWith(color: _linkForeground(run))
                : style,
          ),
        );
        from = to;
      }

      for (final rune in text.runes) {
        final width = cellWidth(rune);
        if (width > 0 && _linked(column) != linked) {
          flush(unit);
          linked = !linked;
        }
        column += width;
        unit += rune > 0xffff ? 2 : 1;
      }
      flush(text.length);
    }
    return spans;
  }

  /// The colour a link piece of [run] is drawn in: the run's own, else
  /// the palette's link colour (dimmed like any dim text).
  Color _linkForeground(AnsiRun run) {
    final palette = metrics.palette;
    if (run.fg != null) return runForeground(run, palette);
    return run.dim
        ? Color.lerp(run.bg ?? palette.background, palette.link, _dimBlend)!
        : palette.link;
  }

  /// Underlines under the linked cells, in the colour of the text above.
  void _underlines(_Fills glyphs) {
    final thickness = math.max(1, (metrics.fontSize * 0.06 * metrics.dpr).round());
    final top = math.min(
      metrics.rowPx - thickness,
      ((metrics.baseline + metrics.fontSize * 0.12) * metrics.dpr).round(),
    );
    var column = 0;
    for (final run in runs) {
      final end = column + columnsOf(run.text);
      for (final link in links) {
        final from = math.max(column, link.start);
        final to = math.min(end, link.end);
        if (to <= from) continue;
        glyphs.add(
          Rect.fromLTRB(
            metrics.columnEdge(from).toDouble(),
            top.toDouble(),
            metrics.columnEdge(to).toDouble(),
            (top + thickness).toDouble(),
          ),
          _linkForeground(run),
        );
      }
      column = end;
    }
  }

  ui.Picture? _picture;
  var _recorded = false;

  Widget? _view;
  Key? _viewKey;
  ValueChanged<TerminalLink>? _viewTap;

  /// The widget that shows this row under [key]. The same instance comes back
  /// while [key] and [onLinkTap] are unchanged, so an update that moved a row
  /// without changing it makes Flutter skip rebuilding it.
  Widget view(Key key, ValueChanged<TerminalLink>? onLinkTap) {
    final cached = _view;
    if (cached != null &&
        _viewKey == key &&
        identical(_viewTap, onLinkTap)) {
      return cached;
    }
    _viewKey = key;
    _viewTap = onLinkTap;
    return _view = TerminalLineView(key: key, line: this, onLinkTap: onLinkTap);
  }

  /// Whether a recorded picture (native memory) is currently held.
  bool get hasPicture => _picture != null;

  /// What goes under the text, or null when the row has nothing to draw.
  ui.Picture? get picture {
    if (!_recorded) {
      _picture = _record();
      _recorded = true;
    }
    return _picture;
  }

  /// Releases the picture. The row is recorded again if it is painted after
  /// all.
  void dispose() {
    _picture?.dispose();
    _picture = null;
    _recorded = false;
  }

  ui.Picture? _record() {
    final backgrounds = _Fills();
    final glyphs = _Fills();
    final strokes = <(GlyphStroke, Color)>[];

    var column = 0;
    for (final run in runs) {
      final text = run.text;
      var sprites = false;
      for (var i = 0; i < text.length; i++) {
        if (isBoxGlyph(text.codeUnitAt(i))) {
          sprites = true;
          break;
        }
      }
      final start = column;
      if (!sprites) {
        column += columnsOf(text);
      } else {
        final color = runForeground(run, metrics.palette);
        for (final rune in text.runes) {
          final width = cellWidth(rune);
          if (isBoxGlyph(rune)) {
            final shape = boxGlyph(
              rune,
              x0: metrics.columnEdge(column),
              x1: metrics.columnEdge(column + 1),
              y0: 0,
              y1: metrics.rowPx,
              light: metrics.lightPx,
            )!;
            final fill = shape.alpha == 1
                ? color
                : color.withValues(alpha: color.a * shape.alpha);
            for (final rect in shape.rects) {
              glyphs.add(rect, fill);
            }
            for (final stroke in shape.strokes) {
              strokes.add((stroke, color));
            }
          }
          column += width;
        }
      }
      final bg = run.bg;
      if (bg != null && column > start) {
        backgrounds.add(
          Rect.fromLTRB(
            metrics.columnEdge(start).toDouble(),
            0,
            metrics.columnEdge(column).toDouble(),
            metrics.rowPx.toDouble(),
          ),
          bg,
        );
      }
    }
    if (links.isNotEmpty) _underlines(glyphs);
    if (backgrounds.isEmpty && glyphs.isEmpty && strokes.isEmpty) return null;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(1 / metrics.dpr);
    // Fills are pixel aligned and drawn without anti-aliasing, so rows and
    // runs that share an edge share its pixels exactly.
    final paint = Paint()..isAntiAlias = false;
    for (final (rect, color) in [...backgrounds.items, ...glyphs.items]) {
      canvas.drawRect(rect, paint..color = color);
    }
    for (final (stroke, color) in strokes) {
      final clip = stroke.clip;
      if (clip != null) {
        canvas
          ..save()
          ..clipRect(clip, doAntiAlias: false);
      }
      canvas.drawPath(
        stroke.path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke.width
          ..color = color,
      );
      if (clip != null) canvas.restore();
    }
    return recorder.endRecording();
  }
}

/// Rectangles with a colour each, joining a new one onto a recent neighbour
/// of the same colour and height (a long horizontal rule is one fill).
final class _Fills {
  final items = <(Rect, Color)>[];

  bool get isEmpty => items.isEmpty;

  void add(Rect rect, Color color) {
    final lowest = items.length > 8 ? items.length - 8 : 0;
    for (var i = items.length - 1; i >= lowest; i--) {
      final (other, otherColor) = items[i];
      if (otherColor == color &&
          other.top == rect.top &&
          other.bottom == rect.bottom &&
          other.right == rect.left) {
        items[i] = (Rect.fromLTRB(other.left, other.top, rect.right, rect.bottom), color);
        return;
      }
    }
    items.add((rect, color));
  }
}

/// [TerminalLine]s by the identity of their runs (a row of a [DocLine] is the
/// same list while the line is unchanged), at one set of [CellMetrics].
///
/// Holds the [_cachedLines] most recently asked for: the rows on screen and a
/// good way around them, however long the scrollback is. A line released
/// while still on screen simply prepares itself again when painted.
final class TerminalLineCache {
  TerminalLineCache(this.metrics);

  final CellMetrics metrics;

  /// In order of use, least recent first (a [Map] keeps insertion order).
  final _lines = Map<List<AnsiRun>, TerminalLine>.identity();

  int get length => _lines.length;

  /// The prepared row for [runs]. [links] gives the links on it and is only
  /// asked for when the row is not cached yet.
  TerminalLine lineFor(List<AnsiRun> runs, {List<RowLink> Function()? links}) {
    var line = _lines.remove(runs);
    line ??= TerminalLine(runs, metrics, links: links?.call() ?? const []);
    _lines[runs] = line;
    if (_lines.length > _cachedLines) {
      final oldest = _lines.keys.first;
      _lines.remove(oldest)!.dispose();
    }
    return line;
  }

  void dispose() {
    for (final line in _lines.values) {
      line.dispose();
    }
    _lines.clear();
  }
}

/// Paints the backgrounds and procedural glyphs of a [TerminalLine].
final class TerminalLinePainter extends CustomPainter {
  const TerminalLinePainter(this.line);

  final TerminalLine line;

  @override
  void paint(Canvas canvas, Size size) {
    final picture = line.picture;
    if (picture != null) canvas.drawPicture(picture);
  }

  @override
  bool shouldRepaint(TerminalLinePainter oldDelegate) =>
      !identical(oldDelegate.line, line);
}

/// One terminal row: backgrounds and box drawing painted under the text.
///
/// Give it a width and a height of [CellMetrics.lineHeight]. The text layer
/// renders sprite characters as spaces; see [blankSprites].
///
/// With [onLinkTap], a tap on a link of the row is reported. The tap
/// recogniser only takes part when the finger lands on a link, and it is an
/// ordinary one, so a drag, a long press or a fling that starts there still
/// belongs to the list, the selection or the scroll view.
class TerminalLineView extends StatelessWidget {
  const TerminalLineView({
    super.key,
    required this.line,
    this.onLinkTap,
  });

  final TerminalLine line;
  final ValueChanged<TerminalLink>? onLinkTap;

  @override
  Widget build(BuildContext context) {
    final metrics = line.metrics;
    final row = CustomPaint(
      painter: TerminalLinePainter(line),
      child: Text.rich(
        line.span,
        style: metrics.textStyle,
        strutStyle: metrics.strut,
        textScaler: TextScaler.noScaling,
        softWrap: false,
        maxLines: 1,
        overflow: TextOverflow.clip,
      ),
    );
    final onTap = onLinkTap;
    if (onTap == null || line.links.isEmpty) return row;
    return RawGestureDetector(
      gestures: {
        _LinkTapRecognizer:
            GestureRecognizerFactoryWithHandlers<_LinkTapRecognizer>(
          _LinkTapRecognizer.new,
          (recognizer) {
            recognizer.allows = (position) =>
                line.linkAt(metrics.columnAt(position.dx)) != null;
            recognizer.onTapUp = (details) {
              final link = line.linkAt(metrics.columnAt(details.localPosition.dx));
              if (link != null) onTap(link);
            };
          },
        ),
      },
      child: row,
    );
  }
}

/// A tap that only exists where [allows] says the finger landed on a link.
class _LinkTapRecognizer extends TapGestureRecognizer {
  bool Function(Offset localPosition) allows = (_) => false;

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      allows(event.localPosition) && super.isPointerAllowed(event);
}
