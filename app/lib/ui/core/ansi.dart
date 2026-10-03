import 'dart:math' as math;
import 'dart:ui' show Color;

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

  AnsiRun _withText(String text) => AnsiRun(
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
AnsiDocument parseAnsi(String text) => _Parser(text).parse();

final class _Parser {
  _Parser(this._s);

  final String _s;
  final _lines = <List<AnsiRun>>[];
  var _line = <AnsiRun>[];
  var _columns = 0;

  /// No visible character since the last line break, so reaching the end of
  /// the input here must not emit one more empty line.
  var _lineStart = true;

  /// A lone CR was seen: the next visible text replaces the line so far
  /// (progress meters redraw this way) unless a line feed follows first.
  var _carriageReturn = false;

  Color? _fg;
  Color? _bg;
  var _bold = false;
  var _dim = false;
  var _italic = false;
  var _underline = false;
  var _strike = false;
  var _reverse = false;

  AnsiDocument parse() {
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
        case 0x0a:
          _endLine();
          i++;
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
    if (!_lineStart) _endLine();
    return AnsiDocument(_lines, _columns);
  }

  void _text(int start, int end) {
    if (end > start) _add(_s.substring(start, end));
  }

  void _add(String text) {
    if (_carriageReturn) {
      _line = [];
      _carriageReturn = false;
    }
    _lineStart = false;
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
      _line[_line.length - 1] = _line.last._withText(_line.last.text + text);
    } else {
      _line.add(run);
    }
  }

  void _endLine() {
    _trimPadding();
    var columns = 0;
    for (final run in _line) {
      columns += _columnsOf(run.text);
    }
    if (columns > _columns) _columns = columns;
    _lines.add(_line);
    _line = [];
    _carriageReturn = false;
    _lineStart = true;
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
        _line[_line.length - 1] = run._withText(run.text.substring(0, end));
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

int _columnsOf(String s) {
  var columns = 0;
  for (final r in s.runes) {
    columns += r < 0x300 ? 1 : _cellWidth(r);
  }
  return columns;
}

int _cellWidth(int r) {
  if ((r >= 0x300 && r <= 0x36f) ||
      (r >= 0x200b && r <= 0x200f) ||
      (r >= 0x20d0 && r <= 0x20ff) ||
      (r >= 0xfe00 && r <= 0xfe0f)) {
    return 0;
  }
  if ((r >= 0x1100 && r <= 0x115f) ||
      (r >= 0x2e80 && r <= 0xa4cf) ||
      (r >= 0xac00 && r <= 0xd7a3) ||
      (r >= 0xf900 && r <= 0xfaff) ||
      (r >= 0xfe30 && r <= 0xfe6f) ||
      (r >= 0xff00 && r <= 0xff60) ||
      (r >= 0xffe0 && r <= 0xffe6) ||
      (r >= 0x1f300 && r <= 0x1f64f) ||
      (r >= 0x1f900 && r <= 0x1f9ff) ||
      (r >= 0x20000 && r <= 0x3fffd)) {
    return 2;
  }
  return 1;
}
