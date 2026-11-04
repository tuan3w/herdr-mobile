import 'package:herdr_mobile/l10n/l10n_context.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'md_document.dart';
import 'md_edge_fade.dart';
import 'md_more_row.dart';
import 'md_styles.dart';
import 'md_text.dart';

/// Body rows shown before "Show all".
const mdTableRowCap = 40;

/// Column width limits (dp): a column is as wide as its longest cell, between
/// these, and longer text wraps inside the cell.
const mdTableMinColumn = 48.0;
const mdTableMaxColumn = 240.0;

/// The table as GitHub-flavoured Markdown source (what "Copy as Markdown"
/// puts on the clipboard).
String mdTableMarkdown(MdTable table) {
  String cell(MdInlines c) => c.text.replaceAll('\n', ' ').replaceAll('|', r'\|').trim();
  String row(List<MdInlines> cells) => '| ${cells.map(cell).join(' | ')} |';
  final divider = table.aligns
      .map(
        (a) => switch (a) {
          MdAlign.none => '---',
          MdAlign.left => ':--',
          MdAlign.center => ':-:',
          MdAlign.right => '--:',
        },
      )
      .join(' | ');
  return [row(table.header), '| $divider |', for (final r in table.rows) row(r)].join('\n');
}

/// A pipe table as a real table: a bold header over a stronger hairline, one
/// hairline per row (no zebra), columns as wide as their content between
/// [mdTableMinColumn] and [mdTableMaxColumn], cells that wrap, alignment from
/// the delimiter row, tabular figures. Wider than the screen it scrolls
/// sideways with a fade on the edge that has more; it never overflows.
///
/// While rows stream the column widths only grow, so nothing already drawn
/// re-flows. A long press offers the whole table as Markdown or TSV.
class MdTableView extends StatefulWidget {
  const MdTableView({super.key, required this.table, this.tail = false, this.expanded = false, this.onToggleExpanded});

  final MdTable table;
  final bool tail;
  final bool expanded;
  final VoidCallback? onToggleExpanded;

  @override
  State<MdTableView> createState() => _MdTableViewState();
}

class _MdTableViewState extends State<MdTableView> {
  final _scroll = ScrollController();
  List<double> _widths = const [];
  final _memo = <String, double>{};
  Object? _memoKey;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  double _measure(String text, TextStyle style, TextScaler scaler, TextDirection direction) {
    final key = '${style.fontWeight?.value ?? 0}|$text';
    return _memo[key] ??= () {
      final p = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final w = p.width;
      p.dispose();
      return w;
    }();
  }

  /// Column widths for [t]: the longest line of the longest cell (and of the
  /// header, which is bold), plus padding, clamped. Never narrower than what
  /// an earlier build of this table needed.
  List<double> _columnWidths(MdTable t, TextStyle body, TextStyle head, TextScaler scaler) {
    final key = (body, scaler);
    if (_memoKey != key) {
      _memoKey = key;
      _memo.clear();
      _widths = const [];
    }
    String longestLine(MdInlines c) {
      final s = c.text;
      if (!s.contains('\n')) return s;
      var best = '';
      for (final l in s.split('\n')) {
        if (l.length > best.length) best = l;
      }
      return best;
    }

    final out = <double>[];
    for (var c = 0; c < t.columns; c++) {
      var natural = _measure(longestLine(t.header[c]), head, scaler, TextDirection.ltr);
      String? candidate;
      for (final r in t.rows) {
        final s = longestLine(r[c]);
        if (candidate == null || s.length > candidate.length) candidate = s;
      }
      if (candidate != null && candidate.isNotEmpty) {
        natural = math.max(natural, _measure(candidate, body, scaler, TextDirection.ltr));
      }
      var w = (natural + 2 * Gap.sm + 2).clamp(mdTableMinColumn, mdTableMaxColumn).toDouble();
      if (c < _widths.length) w = math.max(w, _widths[c]);
      out.add(w);
    }
    return _widths = out;
  }

  void _actions(BuildContext context) {
    final t = widget.table;
    unawaited(
      showActionSheet(
        context,
        title: context.l10n.uiTable,
        actions: [
          SheetAction(
            label: context.l10n.uiCopyAsMarkdown,
            icon: LucideIcons.copy,
            onTap: () => copyText(context, mdTableMarkdown(t), what: 'Table copied'),
          ),
          SheetAction(
            label: context.l10n.uiCopyAsTSV,
            icon: LucideIcons.table,
            onTap: () => copyText(context, t.plainText, what: 'Table copied as TSV'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final styles = MdStyles.of(context);
    final ds = styles.ds;
    final t = widget.table;
    final scaler = MediaQuery.textScalerOf(context);
    // A notch under the text around it: 13.5 in reading text, 12 in quiet.
    final cellStyle = (styles.quiet ? Type.caption : Type.secondary).copyWith(
      fontFeatures: Type.tabular,
      color: styles.quiet ? ds.textSecondary : ds.text,
    );
    final headStyle = (styles.quiet ? Type.captionStrong : Type.buttonCompact).copyWith(
      height: cellStyle.height,
      fontFeatures: Type.tabular,
      color: ds.text,
    );
    final widths = _columnWidths(t, cellStyle, headStyle, scaler);
    final total = widths.fold<double>(0, (a, b) => a + b);

    final capped = t.rows.length > mdTableRowCap && !widget.expanded;
    final rows = capped ? t.rows.sublist(0, mdTableRowCap) : t.rows;

    TextAlign alignOf(int c) => switch (t.aligns[c]) {
      MdAlign.center => TextAlign.center,
      MdAlign.right => TextAlign.right,
      _ => TextAlign.start,
    };

    TableRow tableRow(List<MdInlines> cells, TextStyle style, Color line) => TableRow(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: line)),
      ),
      children: [
        for (var c = 0; c < t.columns; c++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 7),
            child: MdInlineText(inlines: cells[c], style: style, textAlign: alignOf(c)),
          ),
      ],
    );

    Widget table(double width) => SizedBox(
      width: width,
      child: Table(
        defaultVerticalAlignment: TableCellVerticalAlignment.top,
        columnWidths: {for (var c = 0; c < widths.length; c++) c: FixedColumnWidth(widths[c] * (width / total))},
        children: [tableRow(t.header, headStyle, ds.border), for (final r in rows) tableRow(r, cellStyle, ds.hairline)],
      ),
    );

    final hidden = t.rows.length - mdTableRowCap;
    final more = t.rows.length > mdTableRowCap
        ? MoreRow(
            label: widget.expanded
                ? context.l10n.messageRows('${t.rows.length}')
                : context.l10n.messageMoreRows('$hidden'),
            action: widget.expanded ? 'Show less' : 'Show all',
            onTap: widget.onToggleExpanded ?? () {},
          )
        : null;

    final label = 'Table, ${t.columns} ${t.columns == 1 ? 'column' : 'columns'}, ${t.rows.length + 1} rows';
    final body = LayoutBuilder(
      builder: (context, box) {
        final avail = box.maxWidth;
        if (total <= avail) {
          // Narrower than the screen: the columns share the width, in
          // proportion to what they need.
          return table(avail);
        }
        return MdEdgeFade(
          controller: _scroll,
          child: SingleChildScrollView(controller: _scroll, scrollDirection: Axis.horizontal, child: table(total)),
        );
      },
    );

    final content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [body, ?more]);
    return ExcludeSemantics(
      excluding: widget.tail,
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: label,
        customSemanticsActions: {CustomSemanticsAction(label: context.l10n.uiCopyTable): () => _actions(context)},
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          excludeFromSemantics: true,
          onLongPress: () {
            Haptics.hold();
            _actions(context);
          },
          child: content,
        ),
      ),
    );
  }
}
