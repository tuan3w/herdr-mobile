import 'dart:math' as math;

import 'ansi.dart';
import 'cell_width.dart';
import 'line_wrap.dart';
import 'table_lines.dart';
import 'terminal_links.dart';

/// Lines compared to work out how far a sliding window has moved.
const _anchorLines = 5;

/// A link as it sits on one terminal row: [start] and [end] are cells of the
/// row, not of the logical line the [link] was found in.
final class RowLink {
  const RowLink(this.link, this.start, this.end);

  final TerminalLink link;
  final int start;
  final int end;
}

/// One source line of a [TerminalDocument], parsed. Everything derived from it
/// (wrapped rows, links) is computed on first use and kept, so a line that
/// survives an update costs nothing again.
final class DocLine {
  DocLine._(this.src, this.start, AnsiLine parsed)
      : runs = parsed.runs,
        columns = parsed.columns,
        hasText = parsed.hasText,
        end = parsed.end;

  /// The raw text, escape sequences included.
  final String src;

  /// The style the line began in.
  final AnsiState start;
  final List<AnsiRun> runs;

  /// Cells the line occupies.
  final int columns;
  final bool hasText;

  /// The style the next line begins in.
  final AnsiState end;

  late final List<List<AnsiRun>> _fits = [runs];

  /// Links in the line's visible text, in cells of the whole line.
  late final List<TerminalLink> links = _findLinks();

  int _wrapColumns = 0;
  List<List<AnsiRun>> _wrapped = const [];

  /// The line's visible text.
  late final String plain = () {
    final text = StringBuffer();
    for (final run in runs) {
      text.write(run.text);
    }
    return text.toString();
  }();

  /// A row of a table or a box: laid out for a fixed width, so it is never
  /// re-flowed (see [isTableRow]).
  late final bool tabular = isTableRow(plain);

  List<TerminalLink> _findLinks() => detectLinks(plain);

  /// How many rows the line takes at [columns] (0: not wrapping), without
  /// cutting it: a line of one-cell characters is cut every [columns] cells,
  /// which is arithmetic. Only a line with wide or zero-width characters has to
  /// be wrapped to know. So laying out thousands of lines at a new width costs
  /// no allocation, and the rows are cut when one is first built.
  int rowCount(int columns) {
    if (columns <= 0 || this.columns <= columns || tabular) return 1;
    if (_oneCellChars) return (this.columns + columns - 1) ~/ columns;
    return rows(columns).length;
  }

  late final bool _oneCellChars = () {
    for (final run in runs) {
      for (final rune in run.text.runes) {
        if (rune >= 0x300 && cellWidth(rune) != 1) return false;
      }
    }
    return true;
  }();

  /// The rows of this line at [columns] (0: not wrapping): the very same lists
  /// every time, so work cached per row survives. A line that fits is one row
  /// that is [runs] itself.
  List<List<AnsiRun>> rows(int columns) {
    if (columns <= 0 || this.columns <= columns || tabular) return _fits;
    if (_wrapColumns != columns) {
      _wrapped = wrapLine(runs, columns);
      _wrapColumns = columns;
    }
    return _wrapped;
  }

  /// Links on row [part] of the line wrapped to [columns], in cells of that
  /// row.
  List<RowLink> linksOnRow(int part, int columns) {
    final all = links;
    if (all.isEmpty) return const [];
    final rows = this.rows(columns);
    var from = 0;
    for (var i = 0; i < part; i++) {
      from += _width(rows[i]);
    }
    final to = from + _width(rows[part]);
    return [
      for (final link in all)
        if (link.start < to && link.end > from)
          RowLink(
            link,
            math.max(link.start, from) - from,
            math.min(link.end, to) - from,
          ),
    ];
  }
}

int _width(List<AnsiRun> row) {
  var width = 0;
  for (final run in row) {
    width += columnsOf(run.text);
  }
  return width;
}

/// How the top of a [TerminalDocument] moved in one update: lines that left
/// it, and lines inserted above the previous first line.
typedef DocShift = ({int dropped, int prepended});

/// Pane output as parsed lines, kept between updates.
///
/// The text is [update]d every few milliseconds and only its tail normally
/// changes, so an update is proportional to what changed: lines whose source
/// text and starting style are unchanged keep their [DocLine] (and with it
/// their wrapped rows, links and anything callers cache per line by identity).
/// Scrollback that has scrolled out of the live window is handed over as
/// [update]'s `history` and is never parsed twice.
///
/// Line `i` has the id `base + i`. An id follows its line: lines dropped off
/// the top advance [base], lines inserted above it move [base] down, so a
/// list keyed by id keeps the row (and the paragraph laid out in it) while its
/// index moves.
final class TerminalDocument {
  var _lines = const <DocLine>[];
  var _columns = 0;
  var _tableColumns = 0;
  var _base = 0;

  List<DocLine> get lines => _lines;

  /// Width of the widest line in cells.
  int get columns => _columns;

  /// Width of the widest table or box row in cells: what wrapping leaves whole.
  int get tableColumns => _tableColumns;

  /// Id of the first line.
  int get base => _base;

  /// Replaces the content with the rows of [history] (oldest first, never
  /// changed by the caller) followed by the lines of [text], the live window.
  ///
  /// Style carries from line to line within the history and within the window,
  /// but not from the history into the window: the window is read on its own
  /// and starts in the default style, so a colour left open by the last
  /// scrolled-off row must not bleed into it.
  ///
  /// Returns how many lines left the top and how many were inserted above the
  /// previous first line; neither when the content shares no line with the
  /// previous one (then no id survives).
  DocShift update(List<String> history, String text) {
    final window = _split(text);
    // The text after the last line feed is a line only if it shows something.
    final unterminated = window.isNotEmpty && !text.endsWith('\n');
    final windowStart = history.length;
    final source = <String>[...history, ...window];
    final old = _lines;
    final shift = _shiftOf(old, source);
    final offset = shift ?? 0;

    final lines = <DocLine>[];
    var state = AnsiState.initial;
    for (var i = 0; i < source.length; i++) {
      final raw = source[i];
      final start = (i == 0 || i == windowStart) ? AnsiState.initial : state;
      final o = i + offset;
      DocLine? line;
      if (o >= 0 && o < old.length) {
        final candidate = old[o];
        if ((identical(candidate.src, raw) || candidate.src == raw) &&
            (identical(candidate.start, start) || candidate.start == start)) {
          line = candidate;
        }
      }
      line ??= DocLine._(raw, start, parseAnsiLine(raw, start));
      state = line.end;
      if (unterminated && i == source.length - 1 && !line.hasText) break;
      lines.add(line);
    }

    var columns = 0;
    var tableColumns = 0;
    for (final line in lines) {
      if (line.columns > columns) columns = line.columns;
      if (line.columns > tableColumns && line.tabular) tableColumns = line.columns;
    }
    _lines = lines;
    _columns = columns;
    _tableColumns = tableColumns;
    if (shift == null) {
      _base += old.length;
      return (dropped: 0, prepended: 0);
    }
    _base += shift;
    return (dropped: math.max(shift, 0), prepended: math.max(-shift, 0));
  }

  /// Where the start of [source] sits in [old]: how many lines left the top
  /// (a positive number), or minus how many were inserted above (negative).
  /// Null when the first lines of one do not appear in the other.
  static int? _shiftOf(List<DocLine> old, List<String> source) {
    if (old.isEmpty || source.isEmpty) return null;
    final m = math.min(_anchorLines, math.min(old.length, source.length));
    for (var k = 0; k + m <= old.length; k++) {
      var j = 0;
      while (j < m && old[k + j].src == source[j]) {
        j++;
      }
      if (j == m) return k;
    }
    for (var p = 1; p + m <= source.length; p++) {
      var j = 0;
      while (j < m && source[p + j] == old[j].src) {
        j++;
      }
      if (j == m) return -p;
    }
    return null;
  }

  /// The lines of [text]; a line feed at the end does not start another.
  static List<String> _split(String text) {
    if (text.isEmpty) return const [];
    final lines = text.split('\n');
    if (lines.last.isEmpty) lines.removeLast();
    return lines;
  }
}
