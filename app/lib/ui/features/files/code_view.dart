import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/tokens.dart';
import 'file_widgets.dart';
import 'text_document.dart';

/// Longest stretch of one line that is drawn. A minified bundle is one line of
/// megabytes; laying that out would stall the frame, so a line is cut here and
/// says how much it hid.
const codeLineCap = 2000;

/// The same cut when wrapping, where a long line is read rather than scrolled
/// past, so more of it is kept.
const codeWrapLineCap = 20000;

const _fontSize = 13.0;
const _gutterPad = 10.0;

/// A text document as numbered, selectable, virtualized lines.
///
/// Not wrapping, every row has the same height, so the list never measures
/// what is off screen (and "jump to line N" is arithmetic). Wrapping, rows
/// take their natural height. Only the rows on screen exist either way.
class CodeView extends StatefulWidget {
  const CodeView({
    super.key,
    required this.document,
    required this.wrap,
    this.highlightLine,
    this.lineCount,
  });

  final TextDocument document;
  final bool wrap;

  /// 1-based line drawn with an accent band and scrolled into view once.
  final int? highlightLine;

  /// Rows to build; defaults to the document's line count. Changes as more of
  /// the file loads.
  final int? lineCount;

  @override
  State<CodeView> createState() => _CodeViewState();
}

class _CodeViewState extends State<CodeView> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  final _highlightKey = GlobalKey();
  var _jumped = false;

  // Layout of the last build, to translate a scroll offset to a line and back
  // when wrapping is toggled (the two modes have different row heights).
  var _lineHeight = 20.0;
  var _wrapColumns = 40;
  int? _restoreLine;

  @override
  void didUpdateWidget(CodeView old) {
    super.didUpdateWidget(old);
    // The mode changed (rows are another height) or the text was read again
    // (the lines above the reader changed): keep the LINE at the top, not the
    // offset.
    if ((old.wrap != widget.wrap || !identical(old.document, widget.document)) && _vertical.hasClients) {
      final offset = _vertical.offset;
      _restoreLine = old.wrap ? _wrappedLineAt(offset, old.document) : (offset / _lineHeight).floor();
    }
  }

  int _rowsOf(TextDocument doc, int line) {
    final width = TextDocument.widthOf(doc.line(line));
    return math.max(1, (math.min(width, codeWrapLineCap) / _wrapColumns).ceil());
  }

  /// Scroll offset of the top of [line] (0-based) when wrapped.
  double _wrappedOffsetOf(int line) {
    var rows = 0;
    for (var i = 0; i < line && i < widget.document.lineCount; i++) {
      rows += _rowsOf(widget.document, i);
    }
    return rows * _lineHeight;
  }

  /// The line (0-based) of [doc] at scroll [offset] when wrapped.
  int _wrappedLineAt(double offset, TextDocument doc) {
    var y = 0.0;
    final count = doc.lineCount;
    for (var i = 0; i < count; i++) {
      y += _rowsOf(doc, i) * _lineHeight;
      if (y > offset) return i;
    }
    return math.max(0, count - 1);
  }

  void _restorePosition() {
    final line = _restoreLine;
    if (line == null) return;
    _restoreLine = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_vertical.hasClients) return;
      final target = widget.wrap ? _wrappedOffsetOf(line) : line * _lineHeight;
      _vertical.jumpTo(target.clamp(0.0, _vertical.position.maxScrollExtent));
    });
  }

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _jumpTo(double lineHeight, double viewport, double averageRowHeight) {
    final line = widget.highlightLine;
    if (_jumped || line == null) return;
    _jumped = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_vertical.hasClients) return;
      final perLine = widget.wrap ? averageRowHeight : lineHeight;
      final target = (line - 1) * perLine - viewport * 0.3;
      _vertical.jumpTo(target.clamp(0.0, _vertical.position.maxScrollExtent));
      if (widget.wrap) {
        // Wrapped rows differ in height, so the estimate lands near; the row
        // itself is then centred exactly once it exists.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final ctx = _highlightKey.currentContext;
          if (mounted && ctx != null) Scrollable.ensureVisible(ctx, alignment: 0.3);
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final scaler = MediaQuery.textScalerOf(context);
    final fontSize = scaler.scale(_fontSize);
    final lineHeight = (fontSize * 1.5).ceilToDouble();
    _lineHeight = lineHeight;
    final style = codeStyle(ds, size: _fontSize).copyWith(height: lineHeight / fontSize);
    final charWidth = _charWidth(style, scaler);
    final doc = widget.document;
    final count = widget.lineCount ?? doc.lineCount;
    final digits = count.toString().length.clamp(2, 9);
    final gutter = digits * charWidth + _gutterPad * 2;
    final highlight = widget.highlightLine;
    final numberStyle = style.copyWith(color: ds.textMuted);
    final bottom = MediaQuery.paddingOf(context).bottom + Gap.lg;

    Widget row(BuildContext context, int i) {
      final raw = doc.line(i);
      final cap = widget.wrap ? codeWrapLineCap : codeLineCap;
      final cut = raw.length > cap;
      final shown = TextDocument.expandTabs(cut ? raw.substring(0, cap) : raw);
      final text = cut ? '$shown … ${raw.length - cap} more characters' : shown;
      final marked = highlight == i + 1;
      final number = SizedBox(
        width: gutter,
        child: Padding(
          padding: const EdgeInsets.only(right: _gutterPad),
          child: Text(
            '${i + 1}',
            textAlign: TextAlign.right,
            style: marked ? numberStyle.copyWith(color: ds.accentText, fontWeight: FontWeight.w600) : numberStyle,
          ),
        ),
      );
      final body = widget.wrap
          ? ConstrainedBox(
              constraints: BoxConstraints(minHeight: lineHeight),
              child: Text(text.isEmpty ? ' ' : text, style: style),
            )
          : Text(text, style: style, maxLines: 1, softWrap: false, overflow: TextOverflow.clip);
      return Container(
        key: marked ? _highlightKey : null,
        color: marked ? ds.accent.withValues(alpha: ds.isDark ? 0.16 : 0.10) : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectionContainer.disabled(child: number),
            if (widget.wrap) Expanded(child: Padding(padding: const EdgeInsets.only(right: Gap.gutter), child: body)) else body,
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, box) {
        _wrapColumns = math.max(1, ((box.maxWidth - gutter - Gap.gutter) / charWidth).floor());
        _restorePosition();
        final Widget list;
        if (widget.wrap) {
          _jumpTo(lineHeight, box.maxHeight, lineHeight * 1.3);
          list = ListView.builder(
            controller: _vertical,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(top: Gap.sm, bottom: bottom),
            itemCount: count,
            itemBuilder: row,
          );
        } else {
          final columns = math.min(doc.maxColumns, codeLineCap + 40);
          final content = math.max(box.maxWidth, gutter + columns * charWidth + Gap.gutter * 2);
          _jumpTo(lineHeight, box.maxHeight, lineHeight);
          list = SingleChildScrollView(
            controller: _horizontal,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: content,
              child: ListView.builder(
                controller: _vertical,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(top: Gap.sm, bottom: bottom),
                itemExtent: lineHeight,
                itemCount: count,
                itemBuilder: row,
              ),
            ),
          );
        }
        return SelectionArea(
          child: RawScrollbar(
            controller: _vertical,
            notificationPredicate: (n) => n.metrics.axis == Axis.vertical,
            thickness: 3,
            radius: const Radius.circular(2),
            thumbColor: ds.textTertiary.withValues(alpha: 0.6),
            child: list,
          ),
        );
      },
    );
  }

  /// Width of one monospace cell at the current text scale.
  static double _charWidth(TextStyle style, TextScaler scaler) {
    final p = TextPainter(
      text: TextSpan(text: '0' * 20, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final w = p.width / 20;
    p.dispose();
    return w;
  }
}
