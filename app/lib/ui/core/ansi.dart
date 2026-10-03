import 'dart:math' as math;
import 'dart:ui' show Color;

import 'cell_width.dart';
import 'theme.dart';

/// A stretch of text in one style. Reverse video is already resolved: [fg] and
/// [bg] are what to paint, `null` meaning the terminal default.
final class AnsiRun {
  const AnsiRun(
    this.text, {
    this.fg,
    this.bg,
    this.bold = false,
    this.dim = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
  });

  final String text;
  final Color? fg;
  final Color? bg;
  final bool bold;
  final bool dim;
  final bool italic;
  final bool underline;
  final bool strike;

  /// This run's style on other [text].
  AnsiRun withText(String text) => AnsiRun(
        text,
        fg: fg,
        bg: bg,
        bold: bold,
        dim: dim,
        italic: italic,
        underline: underline,
        strike: strike,
      );

  bool _sameStyle(AnsiRun o) =>
      fg == o.fg &&
      bg == o.bg &&
      bold == o.bold &&
      dim == o.dim &&
      italic == o.italic &&
      underline == o.underline &&
      strike == o.strike;
}

/// Parsed pane output: one list of runs per terminal line.
final class AnsiDocument {
  const AnsiDocument(this.lines, this.columns);

  final List<List<AnsiRun>> lines;

  /// Width of the widest line in terminal cells (wide glyphs count as two).
  final int columns;
}

/// Parses text containing SGR escape sequences (as returned by `pane.read`
/// with `format: ansi`). Never throws: malformed or truncated sequences are
/// dropped and every other CSI/OSC/DCS/ESC sequence is ignored.
///
/// One-shot. A document that is re-read every few milliseconds is kept by a
/// `TerminalDocument`, which parses only the lines that changed.
AnsiDocument parseAnsi(String text) {
  final lines = <List<AnsiRun>>[];
  var columns = 0;
  var state = AnsiState.initial;
  final n = text.length;
  var pos = 0;
  while (true) {
    final nl = text.indexOf('\n', pos);
    final last = nl < 0;
    final end = last ? n : nl;
    // A trailing line feed does not start another line.
    if (last && pos == end) break;
    final result = parseAnsiLine(text.substring(pos, end), state);
    state = result.end;
    // The text after the final line feed is a line only if it shows something.
    if (!last || result.hasText) {
      lines.add(result.runs);
      if (result.columns > columns) columns = result.columns;
    }
    if (last) break;
    pos = nl + 1;
  }
  return AnsiDocument(lines, columns);
}

/// Parses one line (no line feed in [line]) that starts in the SGR state
/// [start]. No escape sequence spans a line feed, so the result depends on
/// nothing but these two arguments.
AnsiLine parseAnsiLine(String line, AnsiState start) =>
    _Parser(line, start).parse();

/// One parsed line.
final class AnsiLine {
  const AnsiLine(this.runs, this.columns, this.hasText, this.end);

  final List<AnsiRun> runs;

  /// Cells the runs occupy.
  final int columns;

  /// Something was drawn on the line (even if padding trimming emptied it).
  final bool hasText;

  /// The state the next line starts in.
  final AnsiState end;
}

/// The SGR attributes that carry from one line to the next.
final class AnsiState {
  const AnsiState({
    this.fg,
    this.bg,
    this.bold = false,
    this.dim = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.reverse = false,
  });

  static const initial = AnsiState();

  final Color? fg;
  final Color? bg;
  final bool bold;
  final bool dim;
  final bool italic;
  final bool underline;
  final bool strike;
  final bool reverse;

  @override
  bool operator ==(Object other) =>
      other is AnsiState &&
      fg == other.fg &&
      bg == other.bg &&
      bold == other.bold &&
      dim == other.dim &&
      italic == other.italic &&
      underline == other.underline &&
      strike == other.strike &&
      reverse == other.reverse;

  @override
  int get hashCode =>
      Object.hash(fg, bg, bold, dim, italic, underline, strike, reverse);
}

/// Parses one line (no line feed in [_s]) starting in a given SGR state.
final class _Parser {
  _Parser(this._s, AnsiState start)
      : _fg = start.fg,
        _bg = start.bg,
        _bold = start.bold,
        _dim = start.dim,
        _italic = start.italic,
        _underline = start.underline,
        _strike = start.strike,
        _reverse = start.reverse;

  final String _s;
  final _line = <AnsiRun>[];

  /// Visible text was added since the line began.
  var _hasText = false;

  /// A lone CR was seen: the next visible text replaces the line so far
  /// (progress meters redraw this way).
  var _carriageReturn = false;

  Color? _fg;
  Color? _bg;
  bool _bold;
  bool _dim;
  bool _italic;
  bool _underline;
  bool _strike;
  bool _reverse;

  AnsiLine parse() {
    final n = _s.length;
    var i = 0;
    var start = 0;
    while (i < n) {
      final c = _s.codeUnitAt(i);
      if (c >= 0x20 && c != 0x7f) {
        i++;
        continue;
      }
      _text(start, i);
      switch (c) {
        case 0x1b:
          i = _escape(i + 1);
        case 0x0d:
          _carriageReturn = true;
          i++;
        case 0x09:
          _add(' ');
          i++;
        default:
          i++;
      }
      start = i;
    }
    _text(start, n);
    _trimPadding();
    var columns = 0;
    for (final run in _line) {
      columns += columnsOf(run.text);
    }
    final end = AnsiState(
      fg: _fg,
      bg: _bg,
      bold: _bold,
      dim: _dim,
      italic: _italic,
      underline: _underline,
      strike: _strike,
      reverse: _reverse,
    );
    // The common state (a reset at the end of the line) is the shared
    // constant, so callers can compare states by identity first.
    return AnsiLine(
      _line,
      columns,
      _hasText,
      end == AnsiState.initial ? AnsiState.initial : end,
    );
  }

  void _text(int start, int end) {
    if (end > start) _add(_s.substring(start, end));
  }

  void _add(String text) {
    if (_carriageReturn) {
      _line.clear();
      _carriageReturn = false;
    }
    _hasText = true;
    var fg = _fg;
    var bg = _bg;
    if (_reverse) {
      final swapped = fg ?? TerminalColors.foreground;
      fg = bg ?? TerminalColors.background;
      bg = swapped;
    }
    final run = AnsiRun(
      text,
      fg: fg,
      bg: bg,
      bold: _bold,
      dim: _dim,
      italic: _italic,
      underline: _underline,
      strike: _strike,
    );
    if (_line.isNotEmpty && _line.last._sameStyle(run)) {
      _line[_line.length - 1] = _line.last.withText(_line.last.text + text);
    } else {
      _line.add(run);
    }
  }

  /// herdr pads lines to the pane width. Padding is only invisible on the
  /// default background, so coloured (or underlined/struck) runs keep it.
  void _trimPadding() {
    while (_line.isNotEmpty) {
      final run = _line.last;
      if (run.bg != null || run.underline || run.strike) return;
      var end = run.text.length;
      while (end > 0 && run.text.codeUnitAt(end - 1) == 0x20) {
        end--;
      }
      if (end == run.text.length) return;
      if (end == 0) {
        _line.removeLast();
      } else {
        _line[_line.length - 1] = run.withText(run.text.substring(0, end));
        return;
      }
    }
  }

  /// [i] is the index after an ESC. Returns the index to resume at; always
  /// greater than [i] - 1, so the main loop makes progress.
  int _escape(int i) {
    final n = _s.length;
    if (i >= n) return n;
    final c = _s.codeUnitAt(i);
    switch (c) {
      case 0x5b: // [
        return _csi(i + 1);
      case 0x5d || 0x50 || 0x58 || 0x5e || 0x5f: // ] P X ^ _
        return _string(i + 1);
    }
    if (c >= 0x20 && c <= 0x2f) {
      // Intermediates then one final byte, e.g. charset selection `ESC ( B`.
      var j = i + 1;
      while (j < n && _s.codeUnitAt(j) >= 0x20 && _s.codeUnitAt(j) <= 0x2f) {
        j++;
      }
      return j < n && _s.codeUnitAt(j) >= 0x30 && _s.codeUnitAt(j) <= 0x7e
          ? j + 1
          : j;
    }
    if (c >= 0x30 && c <= 0x7e) return i + 1;
    // ESC before a control character or another ESC: drop only the lone ESC.
    return i;
  }

  int _csi(int i) {
    final n = _s.length;
    var j = i;
    while (j < n && _s.codeUnitAt(j) >= 0x30 && _s.codeUnitAt(j) <= 0x3f) {
      j++;
    }
    final paramsEnd = j;
    while (j < n && _s.codeUnitAt(j) >= 0x20 && _s.codeUnitAt(j) <= 0x2f) {
      j++;
    }
    if (j >= n) return n; // truncated; nothing follows to preserve
    final fin = _s.codeUnitAt(j);
    // Not a final byte: the sequence was cut short. Resume here so a newline
    // or text that follows is kept.
    if (fin < 0x40 || fin > 0x7e) return j;
    if (fin == 0x6d && j == paramsEnd) _sgr(i, paramsEnd);
    return j + 1;
  }

  /// OSC, DCS, SOS, PM, APC: payload up to BEL or ST (`ESC \`). An
  /// unterminated one ends at the line so it cannot swallow the output below.
  int _string(int i) {
    final n = _s.length;
    for (var j = i; j < n; j++) {
      switch (_s.codeUnitAt(j)) {
        case 0x07:
          return j + 1;
        case 0x1b:
          return j + 1 < n && _s.codeUnitAt(j + 1) == 0x5c ? j + 2 : j;
        case 0x0a:
          return j;
      }
    }
    return n;
  }

  void _sgr(int from, int to) {
    final values = <int>[];
    // Whether values[i] was separated from values[i - 1] by ':' (sub-parameter).
    final isSub = <bool>[];
    var value = -1;
    var sub = false;
    for (var i = from; i < to; i++) {
      final c = _s.codeUnitAt(i);
      if (c >= 0x30 && c <= 0x39) {
        if (value < 0) {
          value = c - 0x30;
        } else if (value < 100000) {
          value = value * 10 + c - 0x30;
        }
      } else if (c == 0x3b || c == 0x3a) {
        values.add(math.max(value, 0));
        isSub.add(sub);
        value = -1;
        sub = c == 0x3a;
      } else {
        return; // `<=>?` marks a private sequence, not SGR
      }
    }
    values.add(math.max(value, 0));
    isSub.add(sub);

    var k = 0;
    while (k < values.length) {
      final code = values[k];
      var end = k + 1;
      while (end < values.length && isSub[end]) {
        end++;
      }
      if (code == 38 || code == 48) {
        if (end == k + 1) {
          // `38;5;n` / `38;2;r;g;b`: the arguments are separate parameters.
          final mode = k + 1 < values.length ? values[k + 1] : -1;
          end = math.min(
            k + 2 + (mode == 5 ? 1 : mode == 2 ? 3 : 0),
            values.length,
          );
        }
        final color = _extendedColor(values, k + 1, end);
        if (color != null) {
          if (code == 38) {
            _fg = color;
          } else {
            _bg = color;
          }
        }
      } else {
        switch (code) {
          case 0:
            _reset();
          case 1:
            _bold = true;
          case 2:
            _dim = true;
          case 3:
            _italic = true;
          case 4:
            _underline = !(end > k + 1 && values[k + 1] == 0);
          case 7:
            _reverse = true;
          case 9:
            _strike = true;
          case 22:
            _bold = false;
            _dim = false;
          case 23:
            _italic = false;
          case 24:
            _underline = false;
          case 27:
            _reverse = false;
          case 29:
            _strike = false;
          case 39:
            _fg = null;
          case 49:
            _bg = null;
          case >= 30 && <= 37:
            _fg = TerminalColors.ansi[code - 30];
          case >= 90 && <= 97:
            _fg = TerminalColors.ansi[code - 90 + 8];
          case >= 40 && <= 47:
            _bg = TerminalColors.ansi[code - 40];
          case >= 100 && <= 107:
            _bg = TerminalColors.ansi[code - 100 + 8];
        }
      }
      k = end;
    }
  }

  void _reset() {
    _fg = null;
    _bg = null;
    _bold = false;
    _dim = false;
    _italic = false;
    _underline = false;
    _strike = false;
    _reverse = false;
  }

  /// Colour from `[mode, args…]` in `v[from, to)`; null if incomplete or out
  /// of range, which leaves the current colour untouched.
  Color? _extendedColor(List<int> v, int from, int to) {
    if (from >= to) return null;
    final args = to - from - 1;
    switch (v[from]) {
      case 5:
        return args >= 1 && v[from + 1] <= 255 ? _xterm256(v[from + 1]) : null;
      case 2:
        if (args < 3) return null;
        // The colon form may carry a (usually empty) colour-space id first.
        final o = args >= 4 ? from + 2 : from + 1;
        final r = v[o];
        final g = v[o + 1];
        final b = v[o + 2];
        if (r > 255 || g > 255 || b > 255) return null;
        return Color.fromARGB(255, r, g, b);
    }
    return null;
  }
}

/// xterm 256-colour palette: 16 base, 6x6x6 cube, 24 greys.
Color _xterm256(int n) {
  if (n < 16) return TerminalColors.ansi[n];
  if (n < 232) {
    final c = n - 16;
    return Color.fromARGB(255, _cube(c ~/ 36), _cube(c ~/ 6 % 6), _cube(c % 6));
  }
  final grey = 8 + (n - 232) * 10;
  return Color.fromARGB(255, grey, grey, grey);
}

int _cube(int level) => level == 0 ? 0 : 55 + level * 40;
