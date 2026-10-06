import 'lex.dart';
import 'model.dart';

const int _mFence = 1;

/// Markdown source, lightly: headings (`keyword`, the whole line), fences and
/// their info string, list / quote / rule markers and emphasis markers
/// (`punctuation`), code spans and link / bare URLs (`string`). State: inside a
/// fenced block (`a` = fence character, `b` = fence length); fenced content is
/// left plain.
final class MarkdownHighlighter extends LineScanner {
  @override
  void scan(String t, int n, List<Token> out) {
    final k = skipBlanks(t, 0, n);
    if (mode == _mFence) {
      if (_fenceRun(t, k, n, a) >= b && _blankFrom(t, k + _fenceRun(t, k, n, a), n)) {
        emit(out, k, k + _fenceRun(t, k, n, a), TokenKind.punctuation);
        mode = 0;
        a = 0;
        b = 0;
      }
      return;
    }
    if (k >= n) return;
    final c = t.codeUnitAt(k);
    if (c == 0x60 || c == 0x7E) {
      final run = _fenceRun(t, k, n, c);
      if (run >= 3 && k < 4) {
        emit(out, k, k + run, TokenKind.punctuation);
        final info = skipBlanks(t, k + run, n);
        emit(out, info, n, TokenKind.keyword);
        mode = _mFence;
        a = c;
        b = run;
        return;
      }
    }
    if (c == 0x23) {
      var j = k;
      while (j < n && t.codeUnitAt(j) == 0x23) {
        j++;
      }
      if (j - k <= 6 && (j == n || isSpace(t.codeUnitAt(j)))) {
        emit(out, k, n, TokenKind.keyword);
        return;
      }
    }
    var i = k;
    if (_isRule(t, k, n)) {
      emit(out, k, n, TokenKind.punctuation);
      return;
    }
    // block quotes, then a list marker
    while (i < n && t.codeUnitAt(i) == 0x3E) {
      emit(out, i, i + 1, TokenKind.punctuation);
      i = skipBlanks(t, i + 1, n);
    }
    if (i < n) {
      final m = _listMarker(t, i, n);
      if (m > i) {
        emit(out, i, m, TokenKind.punctuation);
        i = skipBlanks(t, m, n);
        if (i + 2 < n &&
            t.codeUnitAt(i) == 0x5B &&
            t.codeUnitAt(i + 2) == 0x5D &&
            (t.codeUnitAt(i + 1) == 0x20 ||
                (t.codeUnitAt(i + 1) | 0x20) == 0x78)) {
          emit(out, i, i + 3, TokenKind.punctuation);
          i += 3;
        }
      }
    }
    _inline(t, i, n, out);
  }

  int _fenceRun(String t, int k, int n, int c) {
    var j = k;
    while (j < n && t.codeUnitAt(j) == c) {
      j++;
    }
    return j - k;
  }

  bool _blankFrom(String t, int k, int n) => skipBlanks(t, k, n) >= n;

  bool _isRule(String t, int k, int n) {
    final c = t.codeUnitAt(k);
    if (c != 0x2D && c != 0x2A && c != 0x5F) return false;
    var count = 0;
    for (var i = k; i < n; i++) {
      final d = t.codeUnitAt(i);
      if (d == c) {
        count++;
      } else if (!isSpace(d)) {
        return false;
      }
    }
    return count >= 3;
  }

  /// End of a list marker at [i] (`-`, `*`, `+`, `1.`, `1)` followed by a
  /// space), or [i].
  int _listMarker(String t, int i, int n) {
    final c = t.codeUnitAt(i);
    if ((c == 0x2D || c == 0x2A || c == 0x2B) &&
        i + 1 < n &&
        isSpace(t.codeUnitAt(i + 1))) {
      return i + 1;
    }
    if (isDigit(c)) {
      var j = i + 1;
      while (j < n && j - i < 9 && isDigit(t.codeUnitAt(j))) {
        j++;
      }
      if (j + 1 < n &&
          (t.codeUnitAt(j) == 0x2E || t.codeUnitAt(j) == 0x29) &&
          isSpace(t.codeUnitAt(j + 1))) {
        return j + 1;
      }
    }
    return i;
  }

  void _inline(String t, int from, int n, List<Token> out) {
    var i = from;
    while (i < n) {
      final c = t.codeUnitAt(i);
      switch (c) {
        case 0x5C: // backslash escape
          i += 2;
        case 0x60: // `
          final run = _fenceRun(t, i, n, 0x60);
          final close = _closingTicks(t, i + run, n, run);
          if (close > 0) {
            emit(out, i, close + run, TokenKind.string);
            i = close + run;
          } else {
            i += run;
          }
        case 0x2A: // *
        case 0x5F: // _
          final run = _fenceRun(t, i, n, c);
          if (run <= 3 && _isEmphasis(t, i, run, n)) {
            emit(out, i, i + run, TokenKind.punctuation);
          }
          i += run;
        case 0x5D: // ]
          if (i + 1 < n && t.codeUnitAt(i + 1) == 0x28) {
            var j = i + 2;
            var depth = 1;
            while (j < n) {
              final d = t.codeUnitAt(j);
              if (d == 0x28) depth++;
              if (d == 0x29 && --depth == 0) break;
              j++;
            }
            if (j < n) {
              emit(out, i + 1, j + 1, TokenKind.string);
              i = j + 1;
              break;
            }
          }
          i++;
        case 0x3C: // <autolink>
          var j = i + 1;
          while (j < n && t.codeUnitAt(j) > 0x20 && t.codeUnitAt(j) != 0x3E && t.codeUnitAt(j) != 0x3C) {
            j++;
          }
          if (j < n && t.codeUnitAt(j) == 0x3E && (t.startsWith('http', i + 1) || t.startsWith('mailto:', i + 1))) {
            emit(out, i, j + 1, TokenKind.string);
            i = j + 1;
          } else {
            i++;
          }
        case 0x68: // h(ttp)
          if ((i == 0 || !isIdentPart(t.codeUnitAt(i - 1))) &&
              (t.startsWith('http://', i) || t.startsWith('https://', i))) {
            var j = i;
            while (j < n) {
              final d = t.codeUnitAt(j);
              if (d <= 0x20 || d == 0x3C || d == 0x3E || d == 0x29 || d == 0x22) break;
              j++;
            }
            while (j > i && _trailing(t.codeUnitAt(j - 1))) {
              j--;
            }
            emit(out, i, j, TokenKind.string);
            i = j;
          } else {
            i++;
          }
        default:
          i++;
      }
    }
  }

  bool _trailing(int c) =>
      c == 0x2E || c == 0x2C || c == 0x3B || c == 0x3A || c == 0x21 || c == 0x3F;

  /// Start of the closing run of exactly [run] backticks at or after [from].
  int _closingTicks(String t, int from, int n, int run) {
    var i = from;
    while (i < n) {
      if (t.codeUnitAt(i) == 0x60) {
        final r = _fenceRun(t, i, n, 0x60);
        if (r == run) return i;
        i += r;
      } else {
        i++;
      }
    }
    return -1;
  }

  bool _isEmphasis(String t, int i, int run, int n) {
    final prev = i == 0 ? 0x20 : t.codeUnitAt(i - 1);
    final next = i + run >= n ? 0x20 : t.codeUnitAt(i + run);
    final prevSpace = prev <= 0x20, nextSpace = next <= 0x20;
    final prevPunct = _isPunct(prev), nextPunct = _isPunct(next);
    final opening = !nextSpace && (prevSpace || prevPunct);
    final closing = !prevSpace && (nextSpace || nextPunct);
    return opening || closing;
  }

  bool _isPunct(int c) =>
      c < 0x80 && c > 0x20 && !isLetter(c) && !isDigit(c);
}
