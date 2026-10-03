import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/repositories/terminal_settings.dart'
    show defaultTerminalFontSize, maxTerminalFontSize, minTerminalFontSize;
import 'ansi.dart';
import 'controls.dart';
import 'line_wrap.dart';
import 'terminal_cells.dart';
import 'theme.dart';

/// Pinching reports sizes in steps of this many logical pixels, so a gesture
/// does not rebuild every row sixty times a second.
const _pinchStep = 0.25;

/// Within this many pixels of the newest line the view follows new output.
const _followSlop = 24.0;

/// Lines compared to work out how far a sliding read window has moved.
const _anchorLines = 5;

const _easeOut = Cubic(0.23, 1, 0.32, 1);

/// Read-only, selectable, colour terminal output.
///
/// Lines have a fixed extent, so only the visible ones are built and laid
/// out however long the scrollback is. The list is reversed: scroll offset 0
/// is the newest line, which makes "follow the bottom" free (no jumps, no
/// extra frame, and it survives the keyboard resizing the viewport).
///
/// Each row is a grid of cells: a [CustomPaint] under the row's text fills
/// backgrounds over the full row height and draws box drawing and block
/// characters procedurally (see [TerminalLineView]), with row height and cell
/// edges snapped to device pixels.
///
/// Pinching with two fingers reports a new font size through
/// [onFontSizeChanged] (and [onFontSizeEnd] when the fingers lift); the view
/// does not keep the size itself, so the owner passes it back as [fontSize].
/// The pinch is watched with raw pointer events, so one-finger scrolling and
/// text selection are untouched; scrolling is only suspended while two
/// fingers are down.
class TerminalView extends StatefulWidget {
  const TerminalView({
    super.key,
    required this.text,
    this.fontSize = defaultTerminalFontSize,
    this.wrap = false,
    this.onFontSizeChanged,
    this.onFontSizeEnd,
  });

  /// Pane output, with SGR escape sequences.
  final String text;

  /// Font size in logical pixels, before the system text scale is applied.
  final double fontSize;

  /// Whether to re-flow every line to the width of the view instead of
  /// keeping the terminal's own layout and scrolling sideways.
  ///
  /// [text] should then be unwrapped output (one logical line per line):
  /// lines are only ever split here, never joined.
  final bool wrap;

  /// A pinch is in progress and wants this size (clamped to
  /// [minTerminalFontSize]..[maxTerminalFontSize]).
  final ValueChanged<double>? onFontSizeChanged;

  /// The fingers of a pinch lifted; this is the size it ended on.
  final ValueChanged<double>? onFontSizeEnd;

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> {
  final _scroll = _AnchoringController();
  final _following = ValueNotifier(true);

  /// Unchanged lines keep their runs instance between updates (see
  /// [AnsiParser]), which is what [_cache] and [_wraps] are keyed on.
  final _parser = AnsiParser();
  late AnsiDocument _doc = _parser.parse(widget.text);

  /// Prepared rows (text span and recorded background/glyph picture), for the
  /// current metrics.
  TerminalLineCache? _cache;

  /// Memoised wrapping of the lines of [_doc].
  final _wraps = WrapMemo();

  /// What is listed: one entry per terminal row. The lines of [_doc] when
  /// not wrapping, otherwise the rows each line was cut into.
  List<List<AnsiRun>> _rows = const [];

  /// While wrapping: the first row of each line, plus the row count at the
  /// end, and the line each row belongs to.
  List<int> _lineStart = const [0];
  List<int> _rowLine = const [];

  /// Columns the rows were wrapped to; 0 when they are the document's lines.
  var _wrapColumns = 0;

  /// Columns that fit the viewport, known once it has been laid out.
  var _viewColumns = 0;

  /// Line ids: line `i` of the document is `_base + i`. The id of a line
  /// survives appends and lines dropped off the top, so its list item (and
  /// the laid-out paragraph in it) is kept although its index moves. A row is
  /// (line id, part): the part counts the rows a wrapped line was cut into.
  var _base = 0;
  CellMetrics? _metrics;

  // Pinch tracking.
  final _touches = <int, Offset>{};
  int? _pinchA;
  int? _pinchB;
  var _pinchStartDistance = 1.0;
  var _pinchStartSize = defaultTerminalFontSize;
  var _pinchSize = defaultTerminalFontSize;
  final _pinching = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_syncFollowing);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final before = _readingPlace();
    if (_updateMetrics()) {
      _layoutRows();
      _restorePlace(before);
    }
  }

  /// Measures again when the font size, text scale or pixel density changed.
  /// Returns whether the metrics (and so the row height) changed.
  bool _updateMetrics() {
    final scaled = MediaQuery.textScalerOf(context).scale(widget.fontSize);
    final fontSize =
        math.min(math.max(scaled, widget.fontSize), widget.fontSize * 1.6);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final old = _metrics;
    if (old != null && old.fontSize == fontSize && old.dpr == dpr) return false;
    final metrics = CellMetrics.measure(fontSize, dpr);
    _cache?.dispose();
    _cache = TerminalLineCache(metrics);
    _metrics = metrics;
    return true;
  }

  @override
  void didUpdateWidget(TerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final textChanged = widget.text != oldWidget.text;
    final wrapChanged = widget.wrap != oldWidget.wrap;
    final sizeChanged = widget.fontSize != oldWidget.fontSize;
    if (!textChanged && !wrapChanged && !sizeChanged) return;

    // Where the user is reading, in terms that survive a new row height or
    // a different split into rows.
    final place = (wrapChanged || sizeChanged) ? _readingPlace() : null;
    final previousRows = _rows.length;
    final previousLines = _doc.lines.length;
    int? dropped;
    var droppedRows = 0;
    if (textChanged) {
      _doc = _parser.parse(widget.text);
      dropped = _droppedLines(oldWidget.text, widget.text);
      droppedRows = _startOfLine(math.min(dropped ?? 0, previousLines));
      // No overlap with the old text: a new document, none of whose lines
      // may be mistaken for an old one.
      _base += dropped ?? previousLines;
    }
    if (sizeChanged) _updateMetrics();
    _layoutRows();
    if (!_scroll.hasClients) return;

    // Offsets count from the newest row, so appended rows (and rows the read
    // window dropped from the top) would slide what the user is reading.
    // While following nothing has to move, but the viewport still has to lay
    // out against the new extent either way.
    if (place != null) {
      _restorePlace(place);
    } else {
      final moved = _following.value
          ? 0
          : _rows.length - previousRows + (dropped == null ? 0 : droppedRows);
      final position = _scroll.position as _AnchoringPosition;
      position.anchorBy(moved * _metrics!.lineHeight);
    }
    if (_scroll.position.pixels <= _followSlop) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncFollowing());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _following.dispose();
    _pinching.dispose();
    _cache?.dispose();
    super.dispose();
  }

  /// Rows of the document at the current width and wrap setting.
  void _layoutRows() {
    final lines = _doc.lines;
    final columns = widget.wrap ? _viewColumns : 0;
    _wrapColumns = columns;
    if (columns == 0) {
      _rows = lines;
      _lineStart = const [0];
      _rowLine = const [];
    } else {
      final rows = <List<AnsiRun>>[];
      final starts = <int>[];
      final rowLine = <int>[];
      for (var line = 0; line < lines.length; line++) {
        starts.add(rows.length);
        for (final row in _wraps.wrap(lines[line], columns)) {
          rows.add(row);
          rowLine.add(line);
        }
      }
      starts.add(rows.length);
      _rows = rows;
      _lineStart = starts;
      _rowLine = rowLine;
      _wraps.retain(Set<List<AnsiRun>>.identity()..addAll(lines));
    }
    _cache?.retain(Set<List<AnsiRun>>.identity()..addAll(_rows));
  }

  /// Index of the first row of document line [line] (of the row after the
  /// last line for `line == lines`).
  int _startOfLine(int line) => _wrapColumns == 0 ? line : _lineStart[line];

  int _lineOfRow(int row) => _wrapColumns == 0 ? row : _rowLine[row];

  /// The row at the bottom edge of the view, as (line id, part, how far into
  /// the row), or null while following or before the first layout.
  ({int id, int part, double fraction})? _readingPlace() {
    if (!_scroll.hasClients || _metrics == null || _rows.isEmpty) return null;
    final pixels = _scroll.position.pixels;
    if (pixels <= _followSlop) return null;
    final fromBottom = pixels / _metrics!.lineHeight;
    final item = fromBottom.floor();
    final row = math.max(0, _rows.length - 1 - item);
    final line = _lineOfRow(row);
    return (
      id: _base + line,
      part: row - _startOfLine(line),
      fraction: fromBottom - item,
    );
  }

  /// Scrolls to [place] again after the rows or their height changed.
  void _restorePlace(({int id, int part, double fraction})? place) {
    if (place == null || !_scroll.hasClients) return;
    final line = place.id - _base;
    if (line < 0 || line >= _doc.lines.length) return;
    final start = _startOfLine(line);
    final parts = _startOfLine(line + 1) - start;
    final row = start + math.min(place.part, parts - 1);
    final item = _rows.length - 1 - row;
    final target = (item + place.fraction) * _metrics!.lineHeight;
    final position = _scroll.position as _AnchoringPosition;
    position.anchorBy(target - position.pixels);
  }

  void _syncFollowing() {
    if (!_scroll.hasClients) return;
    _following.value = _scroll.position.pixels <= _followSlop;
  }

  void _jumpToLatest() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// Item index (counted from the newest row) of the row with this key.
  int? _indexOfKey(Key key) {
    if (key is! ValueKey<(int, int)>) return null;
    final (id, part) = key.value;
    final line = id - _base;
    if (line < 0 || line >= _doc.lines.length) return null;
    final start = _startOfLine(line);
    if (part < 0 || part >= _startOfLine(line + 1) - start) return null;
    return _rows.length - 1 - (start + part);
  }

  // Pinch to zoom, from raw pointer events: no gesture recognizer, so none
  // competes with the list's drag.

  void _pointerDown(PointerDownEvent e) {
    _touches[e.pointer] = e.position;
    if (_pinchA == null && _touches.length >= 2) {
      final ids = _touches.keys.take(2).toList();
      _pinchA = ids[0];
      _pinchB = ids[1];
      _pinchStartDistance = math.max(_pinchDistance(), 1);
      _pinchStartSize = widget.fontSize;
      _pinchSize = widget.fontSize;
      _pinching.value = true;
    }
  }

  void _pointerMove(PointerMoveEvent e) {
    if (!_touches.containsKey(e.pointer)) return;
    _touches[e.pointer] = e.position;
    if (_pinchA == null || (e.pointer != _pinchA && e.pointer != _pinchB)) {
      return;
    }
    final scaled = _pinchStartSize * _pinchDistance() / _pinchStartDistance;
    final stepped = (scaled / _pinchStep).round() * _pinchStep;
    final size = stepped
        .clamp(minTerminalFontSize, maxTerminalFontSize)
        .toDouble();
    if (size == _pinchSize) return;
    _pinchSize = size;
    widget.onFontSizeChanged?.call(size);
  }

  void _pointerEnd(PointerEvent e) {
    _touches.remove(e.pointer);
    if (_pinchA != null && (e.pointer == _pinchA || e.pointer == _pinchB)) {
      _pinchA = null;
      _pinchB = null;
      _pinching.value = false;
      widget.onFontSizeEnd?.call(_pinchSize);
    }
  }

  double _pinchDistance() =>
      (_touches[_pinchA]! - _touches[_pinchB]!).distance;

  @override
  Widget build(BuildContext context) {
    final metrics = _metrics!;
    final cache = _cache!;
    final wrap = widget.wrap;
    // The side padding is a whole number of device pixels, so the cell grid
    // starts on a pixel edge.
    final pad = (Gap.md * metrics.dpr).roundToDouble() / metrics.dpr;

    return Listener(
      // Short output leaves most of the view empty; pinching there counts.
      behavior: HitTestBehavior.translucent,
      onPointerDown: _pointerDown,
      onPointerMove: _pointerMove,
      onPointerUp: _pointerEnd,
      onPointerCancel: _pointerEnd,
      child: RepaintBoundary(
        child: Stack(
          children: [
            SelectionArea(
              child: LayoutBuilder(
                builder: (context, box) {
                  final viewWidth = math.max(0.0, box.maxWidth - 2 * pad);
                  final columns =
                      math.max(1, (viewWidth / metrics.advance).floor());
                  if (columns != _viewColumns) {
                    _viewColumns = columns;
                    if (wrap) _layoutRows();
                  }
                  final rows = _rows;
                  // Never narrower than the viewport, or the empty strip on
                  // the right would not respond to vertical drags.
                  final width = wrap
                      ? viewWidth
                      : math.max(
                          (metrics.columnEdge(_doc.columns) + 1) / metrics.dpr,
                          viewWidth,
                        );
                  final height = rows.length * metrics.lineHeight + 2 * Gap.sm;
                  return ValueListenableBuilder<bool>(
                    valueListenable: _pinching,
                    builder: (context, pinching, _) => SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: wrap || pinching
                          ? const NeverScrollableScrollPhysics()
                          : null,
                      padding: EdgeInsets.symmetric(horizontal: pad),
                      child: SizedBox(
                        width: width,
                        // Short output hugs the top instead of the
                        // (reversed) list's leading edge at the bottom.
                        height: math.min(height, box.maxHeight),
                        child: ListView.builder(
                          reverse: true,
                          controller: _scroll,
                          physics: pinching
                              ? const NeverScrollableScrollPhysics()
                              : null,
                          padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                          itemExtent: metrics.lineHeight,
                          itemCount: rows.length,
                          addAutomaticKeepAlives: false,
                          addSemanticIndexes: false,
                          findChildIndexCallback: _indexOfKey,
                          itemBuilder: (context, i) {
                            final row = rows.length - 1 - i;
                            final line = _lineOfRow(row);
                            return TerminalLineView(
                              key: ValueKey((
                                _base + line,
                                row - _startOfLine(line),
                              )),
                              line: cache.lineFor(rows[row]),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Positioned(
              right: Gap.md,
              bottom: Gap.md,
              child: ValueListenableBuilder<bool>(
                valueListenable: _following,
                builder: (context, following, _) {
                  final duration = MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 160);
                  return ExcludeSemantics(
                    excluding: following,
                    child: IgnorePointer(
                      ignoring: following,
                      child: AnimatedOpacity(
                        opacity: following ? 0 : 1,
                        duration: duration,
                        curve: _easeOut,
                        child: AnimatedScale(
                          scale: following ? 0.8 : 1,
                          duration: duration,
                          curve: _easeOut,
                          child: CircleButton(
                            icon: LucideIcons.chevronsDown,
                            tooltip: 'Jump to latest',
                            size: 36,
                            onPressed: _jumpToLatest,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// How many lines fell off the top between two reads of a sliding window:
/// where the start of [next] sits inside [previous]. Null when the first
/// lines of [next] appear nowhere in [previous].
int? _droppedLines(String previous, String next) {
  final head = <String>[];
  var from = 0;
  while (head.length < _anchorLines) {
    final end = next.indexOf('\n', from);
    if (end < 0) {
      head.add(next.substring(from));
      break;
    }
    head.add(next.substring(from, end));
    from = end + 1;
  }

  // Walks the lines of `previous` without splitting it.
  var start = 0;
  for (var shift = 0;; shift++) {
    var at = start;
    var matched = 0;
    while (matched < head.length && at <= previous.length) {
      final line = head[matched];
      if (!previous.startsWith(line, at)) break;
      final end = at + line.length;
      if (end < previous.length && previous.codeUnitAt(end) != 0x0a) break;
      at = end + 1;
      matched++;
    }
    if (matched == head.length) return shift;
    final nl = previous.indexOf('\n', start);
    if (nl < 0) return null;
    start = nl + 1;
  }
}

/// A scroll position that can move itself and make its viewport lay out again.
///
/// When a sliver's item count changes but its existing children merely get new
/// content, Flutter does not necessarily lay the sliver out again: the extent
/// stays stale and an offset set with `correctPixels` is never painted.
/// Notifying the viewport's offset listener forces that layout pass.
class _AnchoringPosition extends ScrollPositionWithSingleContext {
  _AnchoringPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  /// Shifts the offset by [delta] (never past the newest line) and lays out.
  void anchorBy(double delta) {
    correctBy(math.max(delta, -pixels));
    notifyListeners();
  }
}

class _AnchoringController extends ScrollController {
  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) =>
      _AnchoringPosition(
        physics: physics,
        context: context,
        initialPixels: initialScrollOffset,
        keepScrollOffset: keepScrollOffset,
        oldPosition: oldPosition,
        debugLabel: debugLabel,
      );
}
