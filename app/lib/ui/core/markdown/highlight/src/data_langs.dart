import 'lex.dart';
import 'model.dart';

/// JSON and JSONC (`//` and `/* */` comments). Keys are `property`; `{}[],:`
/// stay plain. State: open block comment.
final class JsonHighlighter extends LineScanner {
  @override
  void scan(String t, int n, List<Token> out) {
    var i = 0;
    if (mode == 1) i = _comment(t, 0, 0, n, out);
    while (i < n) {
      final c = t.codeUnitAt(i);
      if (c <= 0x20) {
        i++;
      } else if (c == 0x22) {
        var j = i + 1;
        while (j < n) {
          final d = t.codeUnitAt(j);
          if (d == 0x5C) {
            j += 2;
          } else if (d == 0x22) {
            break;
          } else {
            j++;
          }
        }
        j = j < n ? j + 1 : n;
        final k = skipBlanks(t, j, n);
        emit(out, i, j,
            k < n && t.codeUnitAt(k) == 0x3A
                ? TokenKind.property
                : TokenKind.string);
        i = j;
      } else if (isDigit(c) ||
          ((c == 0x2D || c == 0x2B) &&
              i + 1 < n &&
              (isDigit(t.codeUnitAt(i + 1)) || t.codeUnitAt(i + 1) == 0x2E))) {
        var j = i + 1;
        while (j < n) {
          final d = t.codeUnitAt(j);
          if (isDigit(d) ||
              d == 0x2E ||
              d == 0x2B ||
              d == 0x2D ||
              (d | 0x20) == 0x65) {
            j++;
          } else {
            break;
          }
        }
        emit(out, i, j, TokenKind.number);
        i = j;
      } else if (isIdentStart(c)) {
        var j = i + 1;
        while (j < n && isIdentPart(t.codeUnitAt(j))) {
          j++;
        }
        if (_word(t, i, j, 'true') ||
            _word(t, i, j, 'false') ||
            _word(t, i, j, 'null')) {
          emit(out, i, j, TokenKind.constant);
        }
        i = j;
      } else if (c == 0x2F && i + 1 < n && t.codeUnitAt(i + 1) == 0x2F) {
        emit(out, i, n, TokenKind.comment);
        return;
      } else if (c == 0x2F && i + 1 < n && t.codeUnitAt(i + 1) == 0x2A) {
        i = _comment(t, i + 2, i, n, out);
      } else {
        i++;
      }
    }
  }

  bool _word(String t, int s, int e, String w) =>
      e - s == w.length && t.startsWith(w, s);

  int _comment(String t, int from, int start, int n, List<Token> out) {
    for (var i = from; i + 1 < n; i++) {
      if (t.codeUnitAt(i) == 0x2A && t.codeUnitAt(i + 1) == 0x2F) {
        mode = 0;
        emit(out, start, i + 2, TokenKind.comment);
        return i + 2;
      }
    }
    mode = 1;
    emit(out, start, n, TokenKind.comment);
    return n;
  }
}

const int _yBlock = 1;

/// YAML, line by line: comments, `key:` as property, list dashes, anchors and
/// tags as attributes, quoted strings, numbers and booleans, flow `[a, b]`.
/// State: inside a `|` / `>` block scalar (`a` = the indent of its key; the
/// scalar's lines are indented deeper).
final class YamlHighlighter extends LineScanner {
  @override
  void scan(String t, int n, List<Token> out) {
    final indent = skipBlanks(t, 0, n);
    if (mode == _yBlock) {
      if (indent >= n) return;
      if (indent > a) {
        emit(out, indent, n, TokenKind.string);
        return;
      }
      mode = 0;
      a = 0;
    }
    if (indent >= n) return;
    var i = indent;
    var c = t.codeUnitAt(i);
    if (c == 0x23) {
      emit(out, i, n, TokenKind.comment);
      return;
    }
    if (i == 0 &&
        (t.startsWith('---') || t.startsWith('...')) &&
        (n == 3 || isSpace(t.codeUnitAt(3)))) {
      emit(out, 0, 3, TokenKind.punctuation);
      i = 3;
    }
    // list dashes: `- `, `- - `
    var col = i;
    while (i < n && t.codeUnitAt(i) == 0x2D && (i + 1 == n || isSpace(t.codeUnitAt(i + 1)))) {
      emit(out, i, i + 1, TokenKind.punctuation);
      i = skipBlanks(t, i + 1, n);
      col = i;
    }
    if (i >= n) return;
    c = t.codeUnitAt(i);
    if (c == 0x23) {
      emit(out, i, n, TokenKind.comment);
      return;
    }
    final keyEnd = _keyEnd(t, i, n);
    if (keyEnd > 0) {
      emit(out, i, keyEnd, TokenKind.property);
      emit(out, keyEnd, keyEnd + 1, TokenKind.punctuation);
      i = skipBlanks(t, keyEnd + 1, n);
    }
    if (i < n) _value(t, i, n, out, keyEnd > 0 ? col : indent);
  }

  /// End (exclusive) of a mapping key starting at [i] (the index of its `:`),
  /// or -1 when the text there is not a key.
  int _keyEnd(String t, int i, int n) {
    final c = t.codeUnitAt(i);
    var j = i;
    if (c == 0x22 || c == 0x27) {
      j = i + 1;
      while (j < n) {
        final d = t.codeUnitAt(j);
        if (d == 0x5C && c == 0x22) {
          j += 2;
        } else if (d == c) {
          break;
        } else {
          j++;
        }
      }
      if (j >= n) return -1;
      j++;
      final k = skipBlanks(t, j, n);
      return k < n && t.codeUnitAt(k) == 0x3A && (k + 1 == n || isSpace(t.codeUnitAt(k + 1))) ? k : -1;
    }
    if (c == 0x5B || c == 0x7B || c == 0x7C || c == 0x3E || c == 0x26 || c == 0x2A || c == 0x21) {
      return -1;
    }
    while (j < n) {
      final d = t.codeUnitAt(j);
      if (d == 0x3A && (j + 1 == n || isSpace(t.codeUnitAt(j + 1)))) {
        return j > i ? j : -1;
      }
      if (d == 0x23 && j > i && isSpace(t.codeUnitAt(j - 1))) return -1;
      j++;
    }
    return -1;
  }

  void _value(String t, int from, int n, List<Token> out, int parent) {
    var i = from;
    var flow = 0;
    while (i < n) {
      final c = t.codeUnitAt(i);
      if (isSpace(c)) {
        i++;
      } else if (c == 0x23 && (i == 0 || isSpace(t.codeUnitAt(i - 1)))) {
        emit(out, i, n, TokenKind.comment);
        return;
      } else if (c == 0x22 || c == 0x27) {
        var j = i + 1;
        while (j < n) {
          final d = t.codeUnitAt(j);
          if (d == 0x5C && c == 0x22) {
            j += 2;
          } else if (d == c) {
            break;
          } else {
            j++;
          }
        }
        j = j < n ? j + 1 : n;
        final k = skipBlanks(t, j, n);
        final isKey = flow > 0 && k < n && t.codeUnitAt(k) == 0x3A;
        emit(out, i, j, isKey ? TokenKind.property : TokenKind.string);
        i = j;
      } else if (c == 0x5B || c == 0x7B) {
        flow++;
        i++;
      } else if (c == 0x5D || c == 0x7D) {
        if (flow > 0) flow--;
        i++;
      } else if (c == 0x2C) {
        i++;
      } else if ((c == 0x7C || c == 0x3E) && flow == 0 && _blockHeader(t, i, n)) {
        emit(out, i, i + 1, TokenKind.punctuation);
        var j = i + 1;
        while (j < n && !isSpace(t.codeUnitAt(j))) {
          j++;
        }
        emit(out, i + 1, j, TokenKind.punctuation);
        mode = _yBlock;
        a = parent;
        i = j;
      } else if (c == 0x26 || c == 0x2A || c == 0x21) {
        var j = i + 1;
        while (j < n && !isSpace(t.codeUnitAt(j)) && t.codeUnitAt(j) != 0x2C) {
          j++;
        }
        emit(out, i, j, TokenKind.attribute);
        i = j;
      } else {
        var j = i;
        while (j < n) {
          final d = t.codeUnitAt(j);
          if (flow > 0 && (d == 0x2C || d == 0x5D || d == 0x7D)) break;
          if (d == 0x23 && j > i && isSpace(t.codeUnitAt(j - 1))) break;
          if (flow > 0 && d == 0x3A && (j + 1 == n || isSpace(t.codeUnitAt(j + 1)))) break;
          j++;
        }
        var e = j;
        while (e > i && isSpace(t.codeUnitAt(e - 1))) {
          e--;
        }
        if (e == i) {
          i = j > i ? j : i + 1;
          if (flow > 0 && i < n && t.codeUnitAt(i) == 0x3A) i++;
          continue;
        }
        final isKey = flow > 0 && j < n && t.codeUnitAt(j) == 0x3A;
        emit(out, i, e, isKey ? TokenKind.property : _scalarKind(t, i, e));
        i = j;
        if (isKey) i++;
      }
    }
  }

  /// `|`, `>`, `|-`, `>+2` followed by blank/EOL/comment.
  bool _blockHeader(String t, int i, int n) {
    var j = i + 1;
    while (j < n) {
      final d = t.codeUnitAt(j);
      if (d == 0x2B || d == 0x2D || isDigit(d)) {
        j++;
      } else {
        break;
      }
    }
    return j >= n || isSpace(t.codeUnitAt(j));
  }

  TokenKind _scalarKind(String t, int s, int e) {
    final c = t.codeUnitAt(s);
    if (isDigit(c) || ((c == 0x2D || c == 0x2B || c == 0x2E) && e - s > 1 && isDigit(t.codeUnitAt(s + 1)))) {
      var j = s + 1;
      while (j < e) {
        final d = t.codeUnitAt(j);
        if (isDigit(d) || d == 0x2E || d == 0x5F || (d | 0x20) == 0x65 || d == 0x2B || d == 0x2D || d == 0x3A || d == 0x78 || isHex(d)) {
          j++;
        } else {
          return TokenKind.string;
        }
      }
      return TokenKind.number;
    }
    final len = e - s;
    bool is_(String w) => len == w.length && t.startsWith(w, s);
    if (len <= 5) {
      final lower = t.substring(s, e).toLowerCase();
      switch (lower) {
        case 'true':
        case 'false':
        case 'null':
        case '~':
        case 'yes':
        case 'no':
        case 'on':
        case 'off':
          return TokenKind.constant;
      }
    }
    if (is_('.inf') || is_('.nan')) return TokenKind.constant;
    return TokenKind.string;
  }
}

const int _tArray = 1, _tMlBasic = 2, _tMlLiteral = 3;

/// TOML: `[table]` headers as `type`, keys as `property`, strings (incl.
/// `"""` and `'''` multi-line), numbers and dates, booleans, comments.
/// State: open multi-line string, or the depth of a multi-line array.
final class TomlHighlighter extends LineScanner {
  @override
  void scan(String t, int n, List<Token> out) {
    var i = 0;
    if (mode == _tMlBasic || mode == _tMlLiteral) {
      i = _multiline(t, 0, 0, mode == _tMlBasic ? 0x22 : 0x27, n, out);
    }
    if (mode == 0) {
      i = skipBlanks(t, i, n);
      if (i < n && t.codeUnitAt(i) == 0x5B) {
        var j = i;
        while (j < n && t.codeUnitAt(j) == 0x5B) {
          j++;
        }
        var e = j;
        while (e < n && t.codeUnitAt(e) != 0x5D && t.codeUnitAt(e) != 0x23) {
          e++;
        }
        final close = e < n && t.codeUnitAt(e) == 0x5D;
        if (close) {
          while (e < n && t.codeUnitAt(e) == 0x5D) {
            e++;
          }
          emit(out, i, e, TokenKind.type);
          i = e;
        }
      }
    }
    _values(t, i, n, out);
  }

  void _values(String t, int from, int n, List<Token> out) {
    var i = from;
    while (i < n) {
      final c = t.codeUnitAt(i);
      if (c <= 0x20) {
        i++;
      } else if (c == 0x23) {
        emit(out, i, n, TokenKind.comment);
        return;
      } else if (c == 0x22 || c == 0x27) {
        if (i + 2 < n && t.codeUnitAt(i + 1) == c && t.codeUnitAt(i + 2) == c) {
          i = _multiline(t, i + 3, i, c, n, out);
        } else {
          var j = i + 1;
          while (j < n) {
            final d = t.codeUnitAt(j);
            if (d == 0x5C && c == 0x22) {
              j += 2;
            } else if (d == c) {
              break;
            } else {
              j++;
            }
          }
          j = j < n ? j + 1 : n;
          final k = skipBlanks(t, j, n);
          emit(out, i, j,
              k < n && t.codeUnitAt(k) == 0x3D
                  ? TokenKind.property
                  : TokenKind.string);
          i = j;
        }
      } else if (c == 0x5B) {
        a++;
        mode = _tArray;
        i++;
      } else if (c == 0x5D) {
        if (a > 0) a--;
        if (a == 0 && mode == _tArray) mode = 0;
        i++;
      } else if (isIdentPart(c) || c == 0x2D || c == 0x2B || c == 0x2E) {
        var j = i + 1;
        while (j < n) {
          final d = t.codeUnitAt(j);
          if (isIdentPart(d) || d == 0x2D || d == 0x2B || d == 0x2E || d == 0x3A) {
            j++;
          } else {
            break;
          }
        }
        final k = skipBlanks(t, j, n);
        if (k < n && t.codeUnitAt(k) == 0x3D) {
          emit(out, i, j, TokenKind.property);
        } else if (_isBool(t, i, j) || _isWord(t, i, j, 'inf') || _isWord(t, i, j, 'nan')) {
          emit(out, i, j, TokenKind.constant);
        } else if (isDigit(c) || ((c == 0x2D || c == 0x2B) && j - i > 1)) {
          emit(out, i, j, TokenKind.number);
        }
        i = j;
      } else if (c == 0x3D) {
        emit(out, i, i + 1, TokenKind.operator);
        i++;
      } else {
        i++;
      }
    }
  }

  bool _isWord(String t, int s, int e, String w) =>
      e - s == w.length && t.startsWith(w, s);

  bool _isBool(String t, int s, int e) =>
      _isWord(t, s, e, 'true') || _isWord(t, s, e, 'false');

  int _multiline(String t, int from, int start, int q, int n, List<Token> out) {
    var i = from;
    while (i < n) {
      final c = t.codeUnitAt(i);
      if (c == 0x5C && q == 0x22) {
        i += 2;
      } else if (c == q &&
          i + 2 < n &&
          t.codeUnitAt(i + 1) == q &&
          t.codeUnitAt(i + 2) == q) {
        i += 3;
        mode = a > 0 ? _tArray : 0;
        emit(out, start, i, TokenKind.string);
        return i;
      } else {
        i++;
      }
    }
    mode = q == 0x22 ? _tMlBasic : _tMlLiteral;
    emit(out, start, n, TokenKind.string);
    return n;
  }
}
