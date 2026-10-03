import 'ansi.dart';
import 'cell_width.dart';

/// Splits one terminal line into rows of at most [columns] cells.
///
/// Runs are cut at the boundary and each piece keeps the style of its run, so
/// a coloured span that crosses a row break is coloured on both rows. A wide
/// character (two cells) that does not fit at the end of a row starts the next
/// one, so such a row is one cell short; one that cannot fit anywhere
/// ([columns] is 1) sits alone on a row. Characters are never split, and a
/// zero-width one (a combining mark) stays with the character before it, even
/// across a break.
///
/// A line that fits comes back as one row that is the very same list as
/// [runs], and an empty line is one empty row, so a blank line still takes a
/// row.
List<List<AnsiRun>> wrapLine(List<AnsiRun> runs, int columns) {
  assert(columns >= 1, 'wrapLine needs at least one column');
  var total = 0;
  for (final run in runs) {
    total += columnsOf(run.text);
    if (total > columns) break;
  }
  if (total <= columns) return [runs];

  final rows = <List<AnsiRun>>[];
  var row = <AnsiRun>[];
  var used = 0;
  for (final run in runs) {
    final text = run.text;
    var pieceStart = 0;
    var i = 0;
    while (i < text.length) {
      final rune = text.runeAt(i);
      final width = cellWidth(rune);
      if (width > 0 && used > 0 && used + width > columns) {
        if (i > pieceStart) row.add(_piece(run, pieceStart, i));
        rows.add(row);
        row = <AnsiRun>[];
        used = 0;
        pieceStart = i;
      }
      used += width;
      i += rune > 0xffff ? 2 : 1;
    }
    if (text.length > pieceStart) row.add(_piece(run, pieceStart, text.length));
  }
  if (row.isNotEmpty) rows.add(row);
  return rows;
}

AnsiRun _piece(AnsiRun run, int start, int end) => start == 0 && end == run.text.length
    ? run
    : run.withText(run.text.substring(start, end));

/// [wrapLine] remembered per line, for a document re-read every few
/// milliseconds where only a line or two changes.
///
/// Keyed on the identity of a line's runs (which [AnsiParser] keeps for
/// unchanged lines) and the column count, so an update re-wraps only the lines
/// that changed. Rows of an unchanged line are the same lists as before, which
/// lets callers cache per-row work by identity too.
final class WrapMemo {
  var _columns = 0;
  final _rows = Map<List<AnsiRun>, List<List<AnsiRun>>>.identity();

  /// Lines wrapped (not served from the memo) so far.
  int computed = 0;

  /// The rows of the line [runs] at [columns].
  List<List<AnsiRun>> wrap(List<AnsiRun> runs, int columns) {
    if (columns != _columns) {
      _rows.clear();
      _columns = columns;
    }
    return _rows[runs] ??= () {
      computed++;
      return wrapLine(runs, columns);
    }();
  }

  /// Forgets every line that is not in [live].
  void retain(Set<List<AnsiRun>> live) =>
      _rows.removeWhere((runs, _) => !live.contains(runs));
}

extension on String {
  /// The code point starting at code unit [index].
  int runeAt(int index) {
    final unit = codeUnitAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff && index + 1 < length) {
      final next = codeUnitAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        return 0x10000 + ((unit - 0xd800) << 10) + (next - 0xdc00);
      }
    }
    return unit;
  }
}
