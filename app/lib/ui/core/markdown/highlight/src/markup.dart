import 'lex.dart';
import 'model.dart';
import 'words.dart';

const int _hComment = 1, _hTag = 2;

/// HTML and XML: tags (`<div`, `</div`, `>`), attributes, quoted values,
/// entities, comments, doctype and processing instructions. Embedded
/// `<script>` / `<style>` bodies stay plain. State: open comment; inside a
/// tag (attributes may span lines, `a` = open quote or 0).
final class MarkupHighlighter extends LineScanner {
  @override
  void scan(String t, int n, List<Token> out) {
    var i = 0;
    if (mode == _hComment) {
      i = _comment(t, 0, 0, n, out);
    } else if (mode == _hTag) {
      i = _inTag(t, 0, n, out);
    }
    while (i < n) {
      final c = t.codeUnitAt(i);
      if (c == 0x3C) {
        i = _open(t, i, n, out);
      } else if (c == 0x26) {
        var j = i + 1;
        while (j < n && j - i < 12 && (isIdentPart(t.codeUnitAt(j)) || (j == i + 1 && t.codeUnitAt(j) == 0x23))) {
          j++;
        }
        if (j < n && j > i + 1 && t.codeUnitAt(j) == 0x3B) {
          emit(out, i, j + 1, TokenKind.constant);
          i = j + 1;
        } else {
          i++;
        }
      } else {
        i++;
      }
    }
  }

  int _comment(String t, int from, int start, int n, List<Token> out) {
    for (var i = from; i + 2 < n; i++) {
      if (t.codeUnitAt(i) == 0x2D &&
          t.codeUnitAt(i + 1) == 0x2D &&
          t.codeUnitAt(i + 2) == 0x3E) {
        mode = 0;
        emit(out, start, i + 3, TokenKind.comment);
        return i + 3;
      }
    }
    mode = _hComment;
    emit(out, start, n, TokenKind.comment);
    return n;
  }

  int _open(String t, int i, int n, List<Token> out) {
    if (i + 1 >= n) return i + 1;
    final c = t.codeUnitAt(i + 1);
    if (c == 0x21 && t.startsWith('--', i + 2)) {
      return _comment(t, i + 4, i, n, out);
    }
    var j = i + 1;
    if (c == 0x2F) {
      j++;
    } else if (c == 0x21 || c == 0x3F) {
      j++;
    } else if (!isLetter(c) && c != 0x5F) {
      return i + 1;
    }
    while (j < n && _nameChar(t.codeUnitAt(j))) {
      j++;
    }
    emit(out, i, j, TokenKind.tag);
    mode = _hTag;
    a = 0;
    return _inTag(t, j, n, out);
  }

  bool _nameChar(int c) =>
      c > 0x20 && c != 0x2F && c != 0x3E && c != 0x3D && c != 0x22 && c != 0x27 && c != 0x3C && c != 0x3F;

  int _inTag(String t, int from, int n, List<Token> out) {
    var i = from;
    if (a != 0) {
      // inside an attribute value that spans lines
      final q = a;
      var j = i;
      while (j < n && t.codeUnitAt(j) != q) {
        j++;
      }
      if (j < n) {
        j++;
        a = 0;
      }
      emit(out, i, j, TokenKind.string);
      i = j;
      if (a != 0) return n;
    }
    while (i < n) {
      final c = t.codeUnitAt(i);
      if (c <= 0x20 || c == 0x3D) {
        i++;
      } else if (c == 0x3E) {
        emit(out, i, i + 1, TokenKind.tag);
        mode = 0;
        return i + 1;
      } else if ((c == 0x2F || c == 0x3F) && i + 1 < n && t.codeUnitAt(i + 1) == 0x3E) {
        emit(out, i, i + 2, TokenKind.tag);
        mode = 0;
        return i + 2;
      } else if (c == 0x22 || c == 0x27) {
        var j = i + 1;
        while (j < n && t.codeUnitAt(j) != c) {
          j++;
        }
        if (j < n) {
          j++;
        } else {
          a = c;
        }
        emit(out, i, j, TokenKind.string);
        i = j;
      } else if (_nameChar(c) || c == 0x3F) {
        var j = i + 1;
        while (j < n && _nameChar(t.codeUnitAt(j))) {
          j++;
        }
        // name=value: name is an attribute; a bare value is a string
        emit(out, i, j, TokenKind.attribute);
        i = j;
        if (i < n && t.codeUnitAt(i) == 0x3D) {
          var v = i + 1;
          if (v < n) {
            final q = t.codeUnitAt(v);
            if (q != 0x22 && q != 0x27 && q > 0x20 && q != 0x3E) {
              var e = v;
              while (e < n && t.codeUnitAt(e) > 0x20 && t.codeUnitAt(e) != 0x3E) {
                e++;
              }
              emit(out, v, e, TokenKind.string);
              i = e;
            }
          }
        }
      } else {
        i++;
      }
    }
    return n;
  }
}

const int _cComment = 1;

/// CSS and SCSS: selectors (tags, `.class`/`#id` as type/constant, pseudo as
/// keyword, `[attr]`), at-rules, properties, values (numbers with units,
/// `#hex` colours, strings, functions), comments (`//` too in SCSS). State:
/// open comment; brace depth in `a` (selector context at depth 0,
/// declarations inside).
final class CssHighlighter extends LineScanner {
  CssHighlighter({required this.scss});

  final bool scss;

  // statement kinds
  static const int _sel = 0, _decl = 1, _value = 2, _at = 3;

  /// Set by [_word] when it just emitted a property name.
  bool _property = false;

  @override
  void scan(String t, int n, List<Token> out) {
    var i = 0;
    if (mode == _cComment) i = _comment(t, 0, 0, n, out);
    var kind = a == 0 ? _sel : (_isSelector(t, i, n) ? _sel : _decl);
    var paren = 0;
    while (i < n) {
      final c = t.codeUnitAt(i);
      if (c <= 0x20) {
        i++;
        continue;
      }
      if (c == 0x2F && i + 1 < n) {
        final d = t.codeUnitAt(i + 1);
        if (d == 0x2A) {
          i = _comment(t, i + 2, i, n, out);
          continue;
        }
        if (d == 0x2F && scss) {
          emit(out, i, n, TokenKind.comment);
          return;
        }
      }
      switch (c) {
        case 0x7B: // {
          a++;
          paren = 0;
          kind = _isSelector(t, i + 1, n) ? _sel : _decl;
          i++;
        case 0x7D: // }
          if (a > 0) a--;
          paren = 0;
          kind = a == 0 ? _sel : (_isSelector(t, i + 1, n) ? _sel : _decl);
          i++;
        case 0x3B: // ;
          paren = 0;
          kind = a == 0 ? _sel : (_isSelector(t, i + 1, n) ? _sel : _decl);
          i++;
        case 0x28: // (
          paren++;
          i++;
        case 0x29: // )
          if (paren > 0) paren--;
          i++;
        case 0x22:
        case 0x27:
          i = _string(t, i, n, out);
        case 0x40: // @
          final e = _identEnd(t, i + 1, n);
          if (kind == _value) {
            emit(out, i, e, TokenKind.constant);
          } else {
            emit(out, i, e, TokenKind.keyword);
            if (kind != _value) kind = _at;
          }
          i = e > i ? e : i + 1;
        case 0x24: // $
          final e = _identEnd(t, i + 1, n);
          emit(out, i, e, TokenKind.constant);
          i = e;
        case 0x23: // #
          if (scss && i + 1 < n && t.codeUnitAt(i + 1) == 0x7B) {
            // `#{...}` interpolation: skip it, its braces are not blocks
            var e = i + 2;
            while (e < n && t.codeUnitAt(e) != 0x7D) {
              e++;
            }
            i = e < n ? e + 1 : n;
          } else {
            final e = _identEnd(t, i + 1, n);
            emit(out, i, e, TokenKind.constant);
            i = e > i ? e : i + 1;
          }
        case 0x2E: // .
          if (kind == _sel) {
            final e = _identEnd(t, i + 1, n);
            emit(out, i, e, TokenKind.type);
            i = e > i ? e : i + 1;
          } else if (i + 1 < n && isDigit(t.codeUnitAt(i + 1))) {
            i = _number(t, i, n, out);
          } else {
            i++;
          }
        case 0x3A: // :
          if (kind == _sel || kind == _at) {
            var e = i + 1;
            if (e < n && t.codeUnitAt(e) == 0x3A) e++;
            final nameEnd = _identEnd(t, e, n);
            if (nameEnd > e) {
              emit(out, i, nameEnd, TokenKind.keyword);
              e = nameEnd;
            }
            i = e;
          } else {
            i++;
          }
        case 0x5B: // [
          if (kind == _sel) {
            var e = i + 1;
            while (e < n && t.codeUnitAt(e) != 0x5D) {
              final d = t.codeUnitAt(e);
              if (d == 0x22 || d == 0x27) {
                e = _skipString(t, e, n);
              } else {
                e++;
              }
            }
            if (e < n) e++;
            emit(out, i, e, TokenKind.attribute);
            i = e;
          } else {
            i++;
          }
        case 0x3E: // >
        case 0x2B: // +
        case 0x7E: // ~
        case 0x26: // &
        case 0x2A: // *
          if (kind == _sel && !(c == 0x2B && i + 1 < n && isDigit(t.codeUnitAt(i + 1)))) {
            emit(out, i, i + 1, TokenKind.operator);
          }
          i++;
        case 0x21: // !
          final e = _identEnd(t, i + 1, n);
          if (e > i + 1) emit(out, i, e, TokenKind.keyword);
          i = e > i ? e : i + 1;
        default:
          final signed = (c == 0x2D || c == 0x2B) &&
              i + 1 < n &&
              (isDigit(t.codeUnitAt(i + 1)) || t.codeUnitAt(i + 1) == 0x2E);
          if (isDigit(c) || (signed && kind != _sel)) {
            i = _number(t, i, n, out);
          } else if (_identStart(c)) {
            _property = false;
            i = _word(t, i, n, out, kind, paren);
            if (kind == _decl && _property) kind = _value;
          } else {
            i++;
          }
      }
    }
  }

  bool _identStart(int c) =>
      isLetter(c) || c == 0x5F || c >= 0x80 || c == 0x2D || c == 0x5C;

  bool _identChar(int c) => _identStart(c) || isDigit(c);

  int _identEnd(String t, int from, int n) {
    var j = from;
    while (j < n && _identChar(t.codeUnitAt(j))) {
      j++;
    }
    return j;
  }

  int _comment(String t, int from, int start, int n, List<Token> out) {
    for (var i = from; i + 1 < n; i++) {
      if (t.codeUnitAt(i) == 0x2A && t.codeUnitAt(i + 1) == 0x2F) {
        mode = 0;
        emit(out, start, i + 2, TokenKind.comment);
        return i + 2;
      }
    }
    mode = _cComment;
    emit(out, start, n, TokenKind.comment);
    return n;
  }

  int _skipString(String t, int i, int n) {
    final q = t.codeUnitAt(i);
    var j = i + 1;
    while (j < n) {
      final c = t.codeUnitAt(j);
      if (c == 0x5C) {
        j += 2;
      } else if (c == q) {
        return j + 1;
      } else {
        j++;
      }
    }
    return n;
  }

  int _string(String t, int i, int n, List<Token> out) {
    final e = _skipString(t, i, n);
    emit(out, i, e, TokenKind.string);
    return e;
  }

  int _number(String t, int i, int n, List<Token> out) {
    var j = i;
    final c = t.codeUnitAt(j);
    if (c == 0x2D || c == 0x2B) j++;
    while (j < n && isDigit(t.codeUnitAt(j))) {
      j++;
    }
    if (j + 1 < n && t.codeUnitAt(j) == 0x2E && isDigit(t.codeUnitAt(j + 1))) {
      j++;
      while (j < n && isDigit(t.codeUnitAt(j))) {
        j++;
      }
    }
    if (j < n && (t.codeUnitAt(j) | 0x20) == 0x65 && j + 1 < n && isDigit(t.codeUnitAt(j + 1))) {
      j++;
      while (j < n && isDigit(t.codeUnitAt(j))) {
        j++;
      }
    }
    if (j < n && t.codeUnitAt(j) == 0x25) {
      j++;
    } else {
      while (j < n && isLetter(t.codeUnitAt(j))) {
        j++;
      }
    }
    emit(out, i, j, TokenKind.number);
    return j > i ? j : i + 1;
  }

  int _word(String t, int i, int n, List<Token> out, int kind, int paren) {
    final e = _identEnd(t, i, n);
    final c = t.codeUnitAt(i);
    final next = e < n ? t.codeUnitAt(e) : 0;
    if (c == 0x2D && e == i + 1) return e;
    if (kind == _sel) {
      emit(out, i, e, next == 0x28 ? TokenKind.function : TokenKind.tag);
      return e;
    }
    final k = skipBlanks(t, e, n);
    final colon = k < n && t.codeUnitAt(k) == 0x3A && (k + 1 >= n || t.codeUnitAt(k + 1) != 0x3A);
    if ((kind == _decl && colon) || (paren > 0 && colon)) {
      emit(out, i, e, TokenKind.property);
      _property = true;
      return e;
    }
    if (next == 0x28) {
      emit(out, i, e, TokenKind.function);
      if (e - i == 3 && t.startsWith('url', i)) {
        // unquoted url(...) body is a string
        var s = skipBlanks(t, e + 1, n);
        if (s < n && t.codeUnitAt(s) != 0x22 && t.codeUnitAt(s) != 0x27) {
          var x = s;
          while (x < n && t.codeUnitAt(x) != 0x29) {
            x++;
          }
          emit(out, s, x, TokenKind.string);
          return x;
        }
      }
    }
    return e;
  }

  /// Whether the statement starting at [from] is a selector (a `{` comes
  /// before any `;` or `}`, or the line ends with a comma).
  bool _isSelector(String t, int from, int n) {
    var paren = 0;
    var last = 0;
    for (var i = from; i < n; i++) {
      final c = t.codeUnitAt(i);
      if (c == 0x22 || c == 0x27) {
        i = _skipString(t, i, n) - 1;
        last = c;
        continue;
      }
      if (c == 0x2F && i + 1 < n && t.codeUnitAt(i + 1) == 0x2A) {
        return false;
      }
      if (c == 0x28) paren++;
      if (c == 0x29 && paren > 0) paren--;
      if (paren == 0) {
        if (c == 0x7B) return true;
        if (c == 0x3B || c == 0x7D) return false;
      }
      if (c > 0x20) last = c;
    }
    return last == 0x2C;
  }
}

/// Diff and patch, by line prefix: `+`/`-` lines, `@@` hunks, `diff `,
/// `index `, `--- ` / `+++ ` headers and git metadata. Stateless.
final class DiffHighlighter extends LineScanner {
  static final Words _meta = Words({
    TokenKind.diffMeta: 'diff index new deleted similarity dissimilarity '
        'rename copy old Binary',
  });

  @override
  void scan(String t, int n, List<Token> out) {
    if (n == 0) return;
    final c = t.codeUnitAt(0);
    switch (c) {
      case 0x2B: // +
        emit(out, 0, n, n >= 4 && t.startsWith('+++ ') ? TokenKind.diffMeta : TokenKind.diffAdd);
      case 0x2D: // -
        emit(out, 0, n, n >= 4 && t.startsWith('--- ') ? TokenKind.diffMeta : TokenKind.diffRemove);
      case 0x40: // @
        if (t.startsWith('@@')) emit(out, 0, n, TokenKind.diffMeta);
      case 0x5C: // \ No newline at end of file
        emit(out, 0, n, TokenKind.diffMeta);
      default:
        if (isLetter(c)) {
          var e = 1;
          while (e < n && isLetter(t.codeUnitAt(e))) {
            e++;
          }
          if (e < n && t.codeUnitAt(e) == 0x20 || e == n) {
            if (_meta.find(t, 0, e) != null) emit(out, 0, n, TokenKind.diffMeta);
          }
        }
    }
  }
}
