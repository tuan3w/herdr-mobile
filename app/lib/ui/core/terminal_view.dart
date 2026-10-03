import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'ansi.dart';
import 'theme.dart';

const _baseFontSize = 11.5;
const _lineHeightFactor = 1.3;

/// Within this many pixels of the newest line the view follows new output.
const _followSlop = 24.0;

/// Lines compared to work out how far a sliding read window has moved.
const _anchorLines = 5;

/// How far dim (SGR 2) text is blended from the background to its colour.
const _dimBlend = 0.62;

const _easeOut = Cubic(0.23, 1, 0.32, 1);

/// Read-only, selectable, colour terminal output.
///
/// Lines have a fixed extent, so only the visible ones are built and laid
/// out however long the scrollback is. The list is reversed: scroll offset 0
/// is the newest line, which makes "follow the bottom" free (no jumps, no
/// extra frame, and it survives the keyboard resizing the viewport).
class TerminalView extends StatefulWidget {
  const TerminalView({super.key, required this.text});

  /// Pane output, with SGR escape sequences.
  final String text;

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

typedef _Metrics = ({double fontSize, double advance, double lineHeight});

class _TerminalViewState extends State<TerminalView> {
  final _scroll = _AnchoringController();
  final _following = ValueNotifier(true);

  late AnsiDocument _doc = parseAnsi(widget.text);
  late List<TextSpan?> _spans = List.filled(_doc.lines.length, null);
  _Metrics? _metrics;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_syncFollowing);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scaled = MediaQuery.textScalerOf(context).scale(_baseFontSize);
    final fontSize = math.min(math.max(scaled, _baseFontSize), _baseFontSize * 1.6);
    if (_metrics?.fontSize != fontSize) _metrics = _measure(fontSize);
  }

  @override
  void didUpdateWidget(TerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text == oldWidget.text) return;
    final previousLines = _doc.lines.length;
    _doc = parseAnsi(widget.text);
    _spans = List.filled(_doc.lines.length, null);
    if (!_scroll.hasClients) return;

    // Offsets count from the newest line, so appended lines (and lines the
    // read window dropped from the top) would slide what the user is reading.
    // While following nothing has to move, but the viewport still has to lay
    // out against the new extent either way.
    final moved = _following.value
        ? 0
        : _doc.lines.length -
            previousLines +
            _droppedLines(oldWidget.text, widget.text);
    final position = _scroll.position as _AnchoringPosition;
    position.anchorBy(moved * _metrics!.lineHeight);
    if (position.pixels <= _followSlop) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncFollowing());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _following.dispose();
    super.dispose();
  }

  void _syncFollowing() {
    if (!_scroll.hasClients) return;
    _following.value = _scroll.position.pixels <= _followSlop;
  }

  void _jumpToLatest() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  TextSpan _span(int index) => _spans[index] ??= TextSpan(
        children: [
          for (final run in _doc.lines[index])
            TextSpan(text: run.text, style: _runStyle(run)),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final metrics = _metrics!;
    final lines = _doc.lines.length;
    final style = _baseStyle(metrics.fontSize);
    final strut = StrutStyle(
      fontFamily: monoFamily,
      fontSize: metrics.fontSize,
      height: _lineHeightFactor,
      leading: 0,
      forceStrutHeight: true,
    );

    return RepaintBoundary(
      child: Stack(
        children: [
          SelectionArea(
            child: LayoutBuilder(
              builder: (context, box) {
                // Never narrower than the viewport, or the empty strip on the
                // right would not respond to vertical drags.
                final width = math.max(
                  (_doc.columns * metrics.advance).ceilToDouble() + 1,
                  box.maxWidth - 2 * Gap.md,
                );
                final height = lines * metrics.lineHeight + 2 * Gap.sm;
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                  child: SizedBox(
                    width: width,
                    // Short output hugs the top instead of the (reversed)
                    // list's leading edge at the bottom.
                    height: math.min(height, box.maxHeight),
                    child: ListView.builder(
                      reverse: true,
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                      itemExtent: metrics.lineHeight,
                      itemCount: lines,
                      addAutomaticKeepAlives: false,
                      addSemanticIndexes: false,
                      itemBuilder: (context, i) => Text.rich(
                        _span(lines - 1 - i),
                        style: style,
                        strutStyle: strut,
                        textScaler: TextScaler.noScaling,
                        softWrap: false,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
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
                        child: FloatingActionButton.small(
                          heroTag: null,
                          tooltip: 'Jump to latest',
                          onPressed: _jumpToLatest,
                          child: const Icon(
                            Icons.keyboard_double_arrow_down_rounded,
                          ),
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
    );
  }
}

TextStyle _baseStyle(double fontSize) => TextStyle(
      fontFamily: monoFamily,
      fontSize: fontSize,
      height: _lineHeightFactor,
      color: TerminalColors.foreground,
    );

/// Width of one monospace cell, measured once per font size.
_Metrics _measure(double fontSize) {
  const sample = 'MMMMMMMMMMMMMMMM';
  final painter = TextPainter(
    text: TextSpan(text: sample, style: _baseStyle(fontSize)),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
  )..layout();
  final advance = painter.width / sample.length;
  painter.dispose();
  return (
    fontSize: fontSize,
    advance: advance,
    lineHeight: fontSize * _lineHeightFactor,
  );
}

TextStyle? _runStyle(AnsiRun run) {
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
      run.bg == null &&
      !run.bold &&
      !run.dim &&
      !run.italic &&
      decoration == null) {
    return null;
  }
  final color = run.dim
      ? Color.lerp(
          run.bg ?? TerminalColors.background,
          run.fg ?? TerminalColors.foreground,
          _dimBlend,
        )
      : run.fg;
  return TextStyle(
    color: color,
    backgroundColor: run.bg,
    fontWeight: run.bold ? FontWeight.w700 : null,
    fontStyle: run.italic ? FontStyle.italic : null,
    decoration: decoration,
  );
}

/// How many lines fell off the top between two reads of a sliding window:
/// where the start of [next] sits inside [previous].
int _droppedLines(String previous, String next) {
  final old = previous.split('\n');
  final now = next.split('\n');
  final anchor = math.min(_anchorLines, now.length);
  for (var shift = 0; shift + anchor <= old.length; shift++) {
    var i = 0;
    while (i < anchor && old[shift + i] == now[i]) {
      i++;
    }
    if (i == anchor) return shift;
  }
  return 0;
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
