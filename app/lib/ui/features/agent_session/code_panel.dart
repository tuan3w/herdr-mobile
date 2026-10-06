import 'package:flutter/material.dart';

import '../../core/markdown/md_more_row.dart';
import '../../core/theme.dart';

/// Longest text a panel works on. Anything beyond is cut (the end for a
/// panel that shows the end, else the start) and says so, so one runaway
/// command cannot stall a frame.
const panelTextLimit = 400000;

/// Longest line a panel draws; the rest is named, not drawn.
const panelLineLimit = 2000;

/// Past this many lines "Show all" opens a box that scrolls and builds its
/// rows lazily, instead of laying out every line in the transcript.
const panelBoundedFrom = 300;
const _boundedHeight = 360.0;

/// A panel with a copy action shows its foot (with the line count) from this
/// many lines; a shorter one is quick to select by hand.
const copyRowFrom = 6;

/// One line of a [CodePanel].
class CodeLine {
  const CodeLine(this.text, {this.color, this.background});

  final String text;
  final Color? color;

  /// Behind the whole line (diffs); drawn only when the panel wraps.
  final Color? background;
}

/// The lines of [text] for a panel: cut to [panelTextLimit], split, and each
/// line cut to [panelLineLimit]. [fromEnd] says which side survives the cut.
List<CodeLine> textLines(String text, {bool fromEnd = false, Color? color}) {
  var source = text;
  var note = '';
  if (source.length > panelTextLimit) {
    final cut = source.length - panelTextLimit;
    source = fromEnd ? source.substring(cut) : source.substring(0, panelTextLimit);
    note = '… $cut characters not shown';
  }
  final raw = source.split('\n');
  if (raw.length > 1 && raw.last.isEmpty) raw.removeLast();
  return [
    if (fromEnd && note.isNotEmpty) CodeLine(note, color: color),
    for (final line in raw) CodeLine(clipLine(line), color: color),
    if (!fromEnd && note.isNotEmpty) CodeLine(note, color: color),
  ];
}

String clipLine(String line) => line.length <= panelLineLimit
    ? line
    : '${line.substring(0, panelLineLimit)} … +${line.length - panelLineLimit} characters';

/// Lines of mono text on a quiet panel, capped to [cap] lines with a "Show
/// all" row. [fromEnd] keeps the last lines (command output) instead of the
/// first (a file, a diff). Whether it is open lives with the owner ([all]),
/// so it survives the row scrolling out of the transcript.
class CodePanel extends StatelessWidget {
  const CodePanel({
    super.key,
    required this.lines,
    required this.background,
    required this.foreground,
    required this.border,
    required this.all,
    required this.onToggleAll,
    this.fromEnd = false,
    this.wrap = true,
    this.cap = 40,
    this.size = 12,
    this.onCopy,
    this.copyLabel = 'Copy',
  });

  final List<CodeLine> lines;
  final Color background;
  final Color foreground;
  final Color border;
  final bool all;
  final VoidCallback onToggleAll;
  final bool fromEnd;

  /// Wrap long lines to the panel; false scrolls the panel sideways.
  final bool wrap;
  final int cap;
  final double size;

  /// Copies the panel's whole text (what the owner holds, not only what shows).
  /// A panel longer than [copyRowFrom] lines then has a foot with the copy
  /// button, quiet, in the same row "Show all" lives in.
  final VoidCallback? onCopy;
  final String copyLabel;

  @override
  Widget build(BuildContext context) {
    final total = lines.length;
    final over = total > cap;
    final shown = !over || all ? lines : (fromEnd ? lines.sublist(total - cap) : lines.sublist(0, cap));
    final style = TextStyle(
      fontFamily: monoFamily,
      fontSize: size,
      height: 1.45,
      color: foreground,
      fontFeatures: const [FontFeature.disable('liga'), FontFeature.disable('calt')],
    );
    final hidden = total - cap;
    final more = over
        ? MoreRow(
            label: all
                ? '$total lines'
                : fromEnd
                    ? '$hidden earlier lines'
                    : '$hidden more lines',
            action: all ? 'Show less' : 'Show all',
            onTap: onToggleAll,
            onCopy: onCopy,
            copyLabel: copyLabel,
          )
        : (onCopy != null && total > copyRowFrom
            ? MoreRow(label: '$total lines', onCopy: onCopy, copyLabel: copyLabel)
            : null);

    Widget line(CodeLine l) {
      final text = Text(
        l.text.isEmpty ? ' ' : l.text,
        softWrap: wrap,
        style: style.copyWith(color: l.color),
      );
      final padded = Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        child: text,
      );
      return l.background == null || !wrap
          ? padded
          : DecoratedBox(
              decoration: BoxDecoration(color: l.background),
              child: SizedBox(width: double.infinity, child: padded),
            );
    }

    Widget body;
    if (all && total > panelBoundedFrom) {
      final list = ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        itemCount: total,
        itemBuilder: (context, i) => line(lines[i]),
      );
      body = SizedBox(
        height: _boundedHeight,
        child: wrap ? list : _sideways(lines, size, list),
      );
    } else {
      final column = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final l in shown) line(l)],
      );
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        child: wrap
            ? column
            : SingleChildScrollView(scrollDirection: Axis.horizontal, child: column),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(Radii.row),
        border: Border.all(color: border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.row),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (more != null && over && fromEnd && !all) more,
            body,
            if (more != null && (!over || !fromEnd || all)) more,
          ],
        ),
      ),
    );
  }

  /// A list that scrolls sideways as one: as wide as the longest line.
  static Widget _sideways(List<CodeLine> lines, double size, Widget list) {
    var longest = 0;
    for (final l in lines) {
      if (l.text.length > longest) longest = l.text.length;
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(width: longest * size * 0.62 + Gap.xl, child: list),
    );
  }
}
