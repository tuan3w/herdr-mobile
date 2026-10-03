import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/repositories/terminal_settings.dart'
    show defaultTerminalFontSize, maxTerminalFontSize, minTerminalFontSize;
import 'controls.dart';
import 'terminal_cells.dart';
import 'terminal_document.dart';
import 'terminal_links.dart';
import 'theme.dart';

/// Pinching reports sizes in steps of this many logical pixels, so a gesture
/// does not rebuild every row sixty times a second.
const _pinchStep = 0.25;

/// Within this many pixels of the newest line the view follows new output.
const _followSlop = 24.0;

/// The view counts as near the top of what it has when fewer than this many
/// viewports of rows lie above the part on screen.
const _nearTopViewports = 1.5;

const _easeOut = Cubic(0.23, 1, 0.32, 1);

/// What lies above the first row of a [TerminalView].
enum TerminalTop {
  /// Nothing: the first row is the pane's first line.
  none,

  /// More output exists and is being fetched.
  loading,

  /// herdr keeps only the last rows of a pane and has no more to give.
  serverLimit,

  /// The phone keeps only so much scrollback and let the oldest rows go.
  localLimit,
}

/// Where the user is in the loaded output; see [TerminalView.onScrollChanged].
typedef TerminalScroll = ({bool nearTop, bool following});

/// Read-only, selectable, colour terminal output.
///
/// Lines have a fixed extent, so only the visible ones are built and laid
/// out however long the scrollback is. The list is reversed: scroll offset 0
/// is the newest line, which makes "follow the bottom" free (no jumps, no
/// extra frame, and it survives the keyboard resizing the viewport). For the
/// same reason rows that appear above (older output) do not move what is on
/// screen.
///
/// Each row is a grid of cells: one paragraph that first fills backgrounds
/// over the full row height and draws box drawing and block characters
/// procedurally, then draws its text (see [TerminalLineView]), with row height
/// and cell edges snapped to device pixels.
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
    this.history = const [],
    this.top = TerminalTop.none,
    this.fontSize = defaultTerminalFontSize,
    this.wrap = false,
    this.onFontSizeChanged,
    this.onFontSizeEnd,
    this.onLinkTap,
    this.onScrollChanged,
    this.onSidewaysChanged,
  });

  /// Pane output, with SGR escape sequences.
  final String text;

  /// Rows that scrolled off the top of [text], oldest first, shown above it.
  /// Pass the same list again while it has not changed: an update is cheap
  /// when only [text] moved.
  final List<String> history;

  /// What to say above the first row.
  final TerminalTop top;

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

  /// A link in the output was tapped. Underlined links only exist when this
  /// is set.
  final ValueChanged<TerminalLink>? onLinkTap;

  /// The user scrolled, or the output changed under them: whether they are
  /// near the oldest row loaded and whether they follow the newest one. Only
  /// called when one of the two changes.
  final ValueChanged<TerminalScroll>? onScrollChanged;

  /// While wrapping, whether a table or box row is wider than the view so the
  /// view scrolls sideways. Called when that changes (after the frame).
  final ValueChanged<bool>? onSidewaysChanged;

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> {
  final _scroll = _AnchoringController();
  final _following = ValueNotifier(true);
  final _list = GlobalKey();

  /// Lines of the output, parsed once and kept between updates. Its line ids
  /// (`base + line`) are what rows are keyed on.
  final _doc = TerminalDocument();

  /// Prepared rows (text span and recorded background/glyph picture), for the
  /// current metrics.
  TerminalLineCache? _cache;

  /// While wrapping: the first row of each line, plus the row count at the
  /// end. Null when every line is one row.
  Int32List? _lineStart;

  /// Rows listed: one per line, or the rows the lines were cut into.
  var _rowCount = 0;

  /// Columns the lines were wrapped to; 0 when they are not.
  var _wrapColumns = 0;

  /// Columns that fit the viewport, known once it has been laid out.
  var _viewColumns = 0;

  CellMetrics? _metrics;

  /// What [TerminalView.onScrollChanged] last heard.
  TerminalScroll? _reported;

  /// What [TerminalView.onSidewaysChanged] last heard.
  var _sideways = false;

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
    _doc.update(widget.history, widget.text);
    _scroll.addListener(_syncFollowing);
    _scroll.addListener(_reportScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportScroll());
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
    // The theme's palette: a theme switch lands here through
    // didChangeDependencies and prepares every row again in the new colours.
    final palette = context.terminal;
    final old = _metrics;
    if (old != null &&
        old.fontSize == fontSize &&
        old.dpr == dpr &&
        identical(old.palette, palette)) {
      return false;
    }
    final metrics = CellMetrics.measure(fontSize, dpr, palette: palette);
    _cache?.dispose();
    _cache = TerminalLineCache(metrics);
    _metrics = metrics;
    return true;
  }

  /// What the rows share (see [TerminalRowEnv]): the same instance until
  /// something in it changes, so rows keep their cached widgets.
  TerminalRowEnv? _env;

  TerminalRowEnv _rowEnv(BuildContext context, CellMetrics metrics) {
    final fresh = TerminalRowEnv.of(context, metrics);
    final old = _env;
    if (old != null && old.sameAs(fresh)) return old;
    return _env = fresh;
  }

  void _reportSideways(bool sideways) {
    if (sideways == _sideways) return;
    _sideways = sideways;
    final report = widget.onSidewaysChanged;
    if (report == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _sideways == sideways) report(sideways);
    });
  }

  @override
  void didUpdateWidget(TerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final contentChanged = widget.text != oldWidget.text ||
        !identical(widget.history, oldWidget.history);
    final wrapChanged = widget.wrap != oldWidget.wrap;
    final sizeChanged = widget.fontSize != oldWidget.fontSize;
    if (!contentChanged && !wrapChanged && !sizeChanged) return;

    // Where the user is reading, in terms that survive a new row height or
    // a different split into rows.
    final place = (wrapChanged || sizeChanged) ? _readingPlace() : null;
    final previousRows = _rowCount;
    final previousLines = _doc.lines.length;
    var droppedRows = 0;
    var prepended = 0;
    if (contentChanged) {
      final shift = _doc.update(widget.history, widget.text);
      // Counted in the layout the rows were last laid out in.
      droppedRows = _startOfLine(math.min(shift.dropped, previousLines));
      prepended = shift.prepended;
    }
    if (sizeChanged) _updateMetrics();
    _layoutRows();
    if (contentChanged) {
      // A rebuild that only moves ids (rows added above, or rows swapped for
      // equal ones) updates no child, so Flutter would skip laying the list
      // out and keep its old extent: the new rows could not be scrolled to.
      _list.currentContext?.findRenderObject()?.markNeedsLayout();
      WidgetsBinding.instance.addPostFrameCallback((_) => _reportScroll());
    }
    if (!_scroll.hasClients) return;

    // Offsets count from the newest row, so appended rows (and rows the read
    // window dropped from the top) would slide what the user is reading. Rows
    // inserted above change no offset. While following nothing has to move,
    // but the viewport still has to lay out against the new extent either way.
    if (place != null) {
      _restorePlace(place);
    } else {
      final prependedRows =
          _startOfLine(math.min(prepended, _doc.lines.length));
      final moved = _following.value
          ? 0
          : _rowCount - previousRows + droppedRows - prependedRows;
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
      _lineStart = null;
      _rowCount = lines.length;
      return;
    }
    final starts = Int32List(lines.length + 1);
    var rows = 0;
    for (var line = 0; line < lines.length; line++) {
      starts[line] = rows;
      rows += lines[line].rowCount(columns);
    }
    starts[lines.length] = rows;
    _lineStart = starts;
    _rowCount = rows;
  }

  /// Index of the first row of document line [line] (of the row after the
  /// last line for `line == lines`).
  int _startOfLine(int line) => _lineStart?[line] ?? line;

  /// The line that row [row] belongs to.
  int _lineOfRow(int row) {
    final starts = _lineStart;
    if (starts == null) return row;
    var lo = 0;
    var hi = starts.length - 2;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= row) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// The row at the bottom edge of the view, as (line id, part, how far into
  /// the row), or null while following or before the first layout.
  ({int id, int part, double fraction})? _readingPlace() {
    if (!_scroll.hasClients || _metrics == null || _rowCount == 0) return null;
    final pixels = _scroll.position.pixels;
    if (pixels <= _followSlop) return null;
    final fromBottom = pixels / _metrics!.lineHeight;
    final item = fromBottom.floor();
    final row = math.max(0, _rowCount - 1 - item);
    final line = _lineOfRow(row);
    return (
      id: _doc.base + line,
      part: row - _startOfLine(line),
      fraction: fromBottom - item,
    );
  }

  /// Scrolls to [place] again after the rows or their height changed.
  void _restorePlace(({int id, int part, double fraction})? place) {
    if (place == null || !_scroll.hasClients) return;
    final line = place.id - _doc.base;
    if (line < 0 || line >= _doc.lines.length) return;
    final start = _startOfLine(line);
    final parts = _startOfLine(line + 1) - start;
    final row = start + math.min(place.part, parts - 1);
    final item = _rowCount - 1 - row;
    final target = (item + place.fraction) * _metrics!.lineHeight;
    final position = _scroll.position as _AnchoringPosition;
    position.anchorBy(target - position.pixels);
  }

  void _syncFollowing() {
    if (!_scroll.hasClients) return;
    _following.value = _scroll.position.pixels <= _followSlop;
  }

  /// Tells the owner where the user is, when that changed.
  void _reportScroll() {
    final report = widget.onScrollChanged;
    if (report == null || !mounted || !_scroll.hasClients) return;
    final position = _scroll.position;
    if (!position.hasContentDimensions) return;
    final now = (
      nearTop: position.maxScrollExtent - position.pixels <
          _nearTopViewports * position.viewportDimension,
      following: position.pixels <= _followSlop,
    );
    if (now == _reported) return;
    _reported = now;
    report(now);
  }

  void _jumpToLatest() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// Item index (counted from the newest row) of the row with this key.
  int? _indexOfKey(Key key) {
    if (key is! ValueKey<(int, int)>) return null;
    final (id, part) = key.value;
    final line = id - _doc.base;
    if (line < 0 || line >= _doc.lines.length) return null;
    final start = _startOfLine(line);
    if (part < 0 || part >= _startOfLine(line + 1) - start) return null;
    return _rowCount - 1 - (start + part);
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
    final top = widget.top;
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
                  // Never narrower than the viewport, or the empty strip on
                  // the right would not respond to vertical drags.
                  // Wrapping leaves table and box rows whole; when one is
                  // wider than the view, the view scrolls sideways for it.
                  final sideways = wrap && _doc.tableColumns > columns;
                  _reportSideways(sideways);
                  final width = wrap && !sideways
                      ? viewWidth
                      : math.max(
                          (metrics.columnEdge(wrap ? _doc.tableColumns : _doc.columns) + 1) /
                              metrics.dpr,
                          viewWidth,
                        );
                  final height = _rowCount * metrics.lineHeight + 2 * Gap.sm;
                  final onLinkTap = widget.onLinkTap;
                  final env = _rowEnv(context, metrics);
                  return ValueListenableBuilder<bool>(
                    valueListenable: _pinching,
                    builder: (context, pinching, _) => SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: (wrap && !sideways) || pinching
                          ? const NeverScrollableScrollPhysics()
                          : null,
                      padding: EdgeInsets.symmetric(horizontal: pad),
                      child: SizedBox(
                        width: width,
                        // Short output hugs the top instead of the
                        // (reversed) list's leading edge at the bottom.
                        height: top == TerminalTop.none
                            ? math.min(height, box.maxHeight)
                            : box.maxHeight,
                        child: CustomScrollView(
                          reverse: true,
                          controller: _scroll,
                          physics: pinching
                              ? const NeverScrollableScrollPhysics()
                              : null,
                          slivers: [
                            SliverPadding(
                              padding: const EdgeInsets.only(bottom: Gap.sm),
                              sliver: SliverFixedExtentList(
                                key: _list,
                                itemExtent: metrics.lineHeight,
                                delegate: SliverChildBuilderDelegate(
                                  (context, i) {
                                    final row = _rowCount - 1 - i;
                                    final index = _lineOfRow(row);
                                    final part = row - _startOfLine(index);
                                    final line = _doc.lines[index];
                                    final columns = _wrapColumns;
                                    return cache
                                        .lineFor(
                                          line.rows(columns)[part],
                                          links: onLinkTap == null
                                              ? null
                                              : () => line.linksOnRow(part, columns),
                                        )
                                        .view(
                                          ValueKey((_doc.base + index, part)),
                                          env,
                                          onLinkTap,
                                        );
                                  },
                                  childCount: _rowCount,
                                  addAutomaticKeepAlives: false,
                                  addSemanticIndexes: false,
                                  findChildIndexCallback: _indexOfKey,
                                ),
                              ),
                            ),
                            SliverToBoxAdapter(
                              child: top == TerminalTop.none
                                  ? const SizedBox(height: Gap.sm)
                                  : _TopRow(top: top, width: viewWidth),
                            ),
                          ],
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

/// The quiet note above the oldest row: more is coming, or why there is no
/// more. As wide as the view, so it stays put in the middle of the screen
/// whatever the width of the output below.
class _TopRow extends StatelessWidget {
  const _TopRow({required this.top, required this.width});

  final TerminalTop top;
  final double width;

  @override
  Widget build(BuildContext context) {
    final secondary = Type.secondary.copyWith(color: context.terminal.dim);
    final (String title, String? detail) = switch (top) {
      TerminalTop.loading => ('Loading earlier output…', null),
      TerminalTop.serverLimit => (
          'Earlier output is not available.',
          'herdr serves the last 1000 rows of a pane.',
        ),
      TerminalTop.localLimit => (
          'Earlier output is not kept.',
          'The phone holds the most recent rows only.',
        ),
      TerminalTop.none => ('', null),
    };
    // Align, so the box may be narrower than the (possibly wider) content.
    return SelectionContainer.disabled(
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: width,
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: title),
                  if (detail != null) TextSpan(text: '\n$detail'),
                ],
              ),
              textAlign: TextAlign.center,
              style: secondary,
            ),
          ),
        ),
      ),
    );
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
