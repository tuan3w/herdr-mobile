import 'lex.dart';
import 'model.dart';
import 'words.dart';

/// How a single quote reads in a language.
enum SingleQuote {
  /// Not a quote at all (Swift).
  none,

  /// A string like the double quote (JS, Dart, Python, SQL).
  string,

  /// A character literal (C, Java, Kotlin, Go, Rust, where it may also start
  /// a lifetime).
  char,
}

/// What a backtick means.
enum Backtick {
  none,

  /// A multi-line template literal with escapes (JS, TS).
  template,

  /// A multi-line raw string (Go).
  raw,

  /// A quoted identifier (SQL, Kotlin, Swift).
  ident,
}

/// The knobs of the shared scanner for the C-family (and Python, SQL, Rust).
final class CLikeSpec {
  const CLikeSpec({
    required this.words,
    this.soft,
    this.lineSlash = false,
    this.lineHash = false,
    this.lineDash = false,
    this.block = false,
    this.nested = false,
    this.singleQuote = SingleQuote.string,
    this.backtick = Backtick.none,
    this.tripleDq = false,
    this.tripleSq = false,
    this.multilineDq = false,
    this.multilineSq = false,
    this.doubledQuote = false,
    this.backslash = true,
    this.dqIsIdentifier = false,
    this.prefixes = '',
    this.maxPrefix = 0,
    this.rustRaw = false,
    this.lifetimes = false,
    this.macroBang = false,
    this.rustAttr = false,
    this.directives = Directives.none,
    this.atAttribute = false,
    this.regex = false,
    this.capsType = true,
    this.upperCall = false,
  });

  /// Hard words: keywords, types, constants.
  final Words words;

  /// Keywords only when a name or a string follows after a space
  /// (`get name`, `data class`, `type Foo`, `from 'x'`).
  final Words? soft;

  final bool lineSlash, lineHash, lineDash, block, nested;
  final SingleQuote singleQuote;
  final Backtick backtick;
  final bool tripleDq, tripleSq;

  /// A `"` / `'` string that is still open at the end of the line goes on
  /// the next line (Rust, SQL).
  final bool multilineDq, multilineSq;

  /// `''` inside a `'` string is a quote (SQL).
  final bool doubledQuote;

  /// `\` escapes in strings.
  final bool backslash;

  /// `"name"` is a quoted identifier, not a string (SQL).
  final bool dqIsIdentifier;

  /// Letters that may prefix a quoted string directly (`f"..."`, `b'x'`).
  final String prefixes;
  final int maxPrefix;

  /// `r"..."`, `r#"..."#`, `br#"..."#`.
  final bool rustRaw;

  /// `'a` is a lifetime (Rust).
  final bool lifetimes;

  /// `name!(` is a macro call (Rust).
  final bool macroBang;

  /// `#[...]` / `#![...]` is an attribute (Rust).
  final bool rustAttr;

  final Directives directives;

  /// `@name` is an annotation / decorator.
  final bool atAttribute;

  /// `/.../flags` can be a regular-expression literal (JS).
  final bool regex;

  /// `Foo` is a type and `FOO` a constant.
  final bool capsType;

  /// `Foo(` is a call, not a constructor (Go).
  final bool upperCall;
}

enum Directives {
  none,

  /// `#include` and friends at the start of a line (C).
  lineStart,

  /// `#if`, `#available` anywhere (Swift).
  anywhere,
}

const int _mBlock = 1, _mTriple = 2, _mBacktick = 3, _mRaw = 4, _mQuoted = 5;

/// One scanner for every C-family language, Python, SQL and Rust, driven by a
/// [CLikeSpec]. State: open block comment (depth in `a`), open triple-quoted
/// string (quote in `a`), open template / raw backtick string, open Rust raw
/// string (hash count in `a`), open multi-line quoted string (quote in `a`).
final class CLikeHighlighter extends LineScanner {
  CLikeHighlighter(this.s);

  final CLikeSpec s;

  @override
  void scan(String t, int n, List<Token> out) {
    var i = 0;
    switch (mode) {
      case _mBlock:
        i = _block(t, 0, 0, n, out);
      case _mTriple:
        i = _triple(t, 0, 0, a, n, out);
      case _mBacktick:
        i = _backtick(t, 0, 0, n, out);
      case _mRaw:
        i = _raw(t, 0, 0, a, n, out);
      case _mQuoted:
        i = _quoted(t, 0, 0, a, n, out);
    }
    while (i < n) {
      final c = t.codeUnitAt(i);
      if (c <= 0x20) {
        i++;
      } else if (isIdentStart(c)) {
        i = _ident(t, i, n, out);
      } else if (isDigit(c)) {
        final e = scanNumber(t, i, n);
        emit(out, i, e, TokenKind.number);
        i = e;
      } else {
        switch (c) {
          case 0x2F: // /
            if (i + 1 < n) {
              final d = t.codeUnitAt(i + 1);
              if (d == 0x2F && s.lineSlash) {
                emit(out, i, n, TokenKind.comment);
                return;
              }
              if (d == 0x2A && s.block) {
                a = 1;
                i = _block(t, i + 2, i, n, out);
                continue;
              }
            }
            if (s.regex) {
              final e = _regex(t, i, n);
              if (e > 0) {
                emit(out, i, e, TokenKind.string);
                i = e;
                continue;
              }
            }
            i = _operator(t, i, n, out);
          case 0x2D: // -
            if (s.lineDash && i + 1 < n && t.codeUnitAt(i + 1) == 0x2D) {
              emit(out, i, n, TokenKind.comment);
              return;
            }
            i = _operator(t, i, n, out);
          case 0x23: // #
            i = _hash(t, i, n, out);
          case 0x22: // "
            i = _string(t, i, i, n, out);
          case 0x27: // '
            i = s.singleQuote == SingleQuote.none
                ? i + 1
                : _string(t, i, i, n, out);
          case 0x60: // `
            i = _backtickStart(t, i, n, out);
          case 0x40: // @
            i = _at(t, i, n, out);
          case 0x2E: // .
            if (i + 1 < n &&
                isDigit(t.codeUnitAt(i + 1)) &&
                (i == 0 || !isIdentPart(t.codeUnitAt(i - 1)))) {
              final e = scanNumber(t, i, n);
              emit(out, i, e, TokenKind.number);
              i = e;
            } else {
              i++;
            }
          default:
            i = _isOperator(c) ? _operator(t, i, n, out) : i + 1;
        }
      }
    }
  }

  // ---- comments and multi-line strings -------------------------------------

  int _block(String t, int from, int start, int n, List<Token> out) {
    var i = from;
    while (i < n) {
      final c = t.codeUnitAt(i);
      if (c == 0x2A && i + 1 < n && t.codeUnitAt(i + 1) == 0x2F) {
        i += 2;
        if (--a <= 0) {
          mode = 0;
          a = 0;
          emit(out, start, i, TokenKind.comment);
          return i;
        }
      } else if (s.nested &&
          c == 0x2F &&
          i + 1 < n &&
          t.codeUnitAt(i + 1) == 0x2A) {
        a++;
        i += 2;
      } else {
        i++;
      }
    }
    mode = _mBlock;
    emit(out, start, n, TokenKind.comment);
    return n;
  }

  int _triple(String t, int from, int start, int q, int n, List<Token> out) {
    var i = from;
    while (i < n) {
      final c = t.codeUnitAt(i);
      if (c == 0x5C && s.backslash) {
        i += 2;
      } else if (c == q &&
          i + 2 < n &&
          t.codeUnitAt(i + 1) == q &&
          t.codeUnitAt(i + 2) == q) {
        i += 3;
        mode = 0;
        a = 0;
        emit(out, start, i, TokenKind.string);
        return i;
      } else {
        i++;
      }
    }
    mode = _mTriple;
    a = q;
    emit(out, start, n, TokenKind.string);
    return n;
  }

  int _backtick(String t, int from, int start, int n, List<Token> out) {
    var i = from;
    final escapes = s.backtick == Backtick.template;
    while (i < n) {
      final c = t.codeUnitAt(i);
      if (c == 0x5C && escapes) {
        i += 2;
      } else if (c == 0x60) {
        i++;
        mode = 0;
        emit(out, start, i, TokenKind.string);
        return i;
      } else {
        i++;
      }
    }
    mode = _mBacktick;
    emit(out, start, n, TokenKind.string);
    return n;
  }

  int _raw(String t, int from, int start, int hashes, int n, List<Token> out) {
    var i = from;
    while (i < n) {
      if (t.codeUnitAt(i) == 0x22) {
        var k = 0;
        while (k < hashes &&
            i + 1 + k < n &&
            t.codeUnitAt(i + 1 + k) == 0x23) {
          k++;
        }
        if (k == hashes) {
          i += 1 + hashes;
          mode = 0;
          a = 0;
          emit(out, start, i, TokenKind.string);
          return i;
        }
      }
      i++;
    }
    mode = _mRaw;
    a = hashes;
    emit(out, start, n, TokenKind.string);
    return n;
  }

  /// A `"` or `'` string whose body starts at [from].
  int _quoted(String t, int from, int start, int q, int n, List<Token> out) {
    var i = from;
    final kind = q == 0x22 && s.dqIsIdentifier
        ? TokenKind.property
        : TokenKind.string;
    while (i < n) {
      final c = t.codeUnitAt(i);
      if (c == 0x5C && s.backslash) {
        i += 2;
      } else if (c == q) {
        if (s.doubledQuote && i + 1 < n && t.codeUnitAt(i + 1) == q) {
          i += 2;
          continue;
        }
        i++;
        mode = 0;
        a = 0;
        emit(out, start, i, kind);
        return i;
      } else {
        i++;
      }
    }
    if (q == 0x22 ? s.multilineDq : s.multilineSq) {
      mode = _mQuoted;
      a = q;
    } else {
      mode = 0;
      a = 0;
    }
    emit(out, start, n, kind);
    return n;
  }

  // ---- strings --------------------------------------------------------------

  /// The quote at [qi] (the string started at [start], earlier if prefixed).
  int _string(String t, int start, int qi, int n, List<Token> out) {
    final q = t.codeUnitAt(qi);
    if (q == 0x22) {
      if (s.tripleDq && _isTriple(t, qi, n)) {
        return _triple(t, qi + 3, start, q, n, out);
      }
      return _quoted(t, qi + 1, start, q, n, out);
    }
    if (s.tripleSq && _isTriple(t, qi, n)) {
      return _triple(t, qi + 3, start, q, n, out);
    }
    if (s.singleQuote == SingleQuote.char) return _char(t, start, qi, n, out);
    return _quoted(t, qi + 1, start, q, n, out);
  }

  bool _isTriple(String t, int i, int n) =>
      i + 2 < n &&
      t.codeUnitAt(i + 1) == t.codeUnitAt(i) &&
      t.codeUnitAt(i + 2) == t.codeUnitAt(i);

  /// A character literal, a Rust lifetime, or a lone quote.
  int _char(String t, int start, int qi, int n, List<Token> out) {
    if (qi + 1 < n) {
      final c1 = t.codeUnitAt(qi + 1);
      if (c1 == 0x5C) {
        final lim = qi + 14 < n ? qi + 14 : n;
        var j = qi + 2;
        while (j < lim && t.codeUnitAt(j) != 0x27) {
          j++;
        }
        if (j < lim) {
          emit(out, start, j + 1, TokenKind.string);
          return j + 1;
        }
      } else if (c1 != 0x27) {
        if (qi + 2 < n && t.codeUnitAt(qi + 2) == 0x27) {
          emit(out, start, qi + 3, TokenKind.string);
          return qi + 3;
        }
        if (c1 >= 0xD800 &&
            c1 <= 0xDBFF &&
            qi + 3 < n &&
            t.codeUnitAt(qi + 3) == 0x27) {
          emit(out, start, qi + 4, TokenKind.string);
          return qi + 4;
        }
        if (s.lifetimes && isIdentStart(c1)) {
          var j = qi + 2;
          while (j < n && isIdentPart(t.codeUnitAt(j))) {
            j++;
          }
          emit(out, qi, j, TokenKind.type);
          return j;
        }
      }
    }
    return qi + 1;
  }

  int _backtickStart(String t, int i, int n, List<Token> out) {
    switch (s.backtick) {
      case Backtick.none:
        return i + 1;
      case Backtick.template:
      case Backtick.raw:
        return _backtick(t, i + 1, i, n, out);
      case Backtick.ident:
        var j = i + 1;
        while (j < n && t.codeUnitAt(j) != 0x60) {
          j++;
        }
        if (j < n) j++;
        emit(out, i, j, TokenKind.property);
        return j;
    }
  }

  // ---- words -----------------------------------------------------------------

  int _ident(String t, int i, int n, List<Token> out) {
    var j = i + 1;
    var hasLower = false;
    while (j < n) {
      final c = t.codeUnitAt(j);
      if (!isIdentPart(c)) break;
      if (isLower(c) || c >= 0x80) hasLower = true;
      j++;
    }
    final first = t.codeUnitAt(i);
    if (first >= 0x80 || isLower(first)) hasLower = true;
    if (j < n) {
      final q = t.codeUnitAt(j);
      if (q == 0x22 || q == 0x27 || q == 0x23) {
        if (s.rustRaw && _rawPrefix(t, i, j)) {
          var k = j;
          while (k < n && t.codeUnitAt(k) == 0x23) {
            k++;
          }
          if (k < n && t.codeUnitAt(k) == 0x22) {
            return _raw(t, k + 1, i, k - j, n, out);
          }
        } else if (q != 0x23 && _prefix(t, i, j)) {
          return _string(t, i, j, n, out);
        }
      }
    }

    final afterDot = i > 0 &&
        t.codeUnitAt(i - 1) == 0x2E &&
        !(i > 1 && t.codeUnitAt(i - 2) == 0x2E);
    final next = j < n ? t.codeUnitAt(j) : 0;
    if (!afterDot) {
      final k = s.words.find(t, i, j);
      if (k != null) {
        emit(out, i, j, k);
        return j;
      }
      final soft = s.soft;
      if (soft != null && soft.find(t, i, j) != null && _softFollows(t, j, n)) {
        emit(out, i, j, TokenKind.keyword);
        return j;
      }
    }
    if (next == 0x21 && s.macroBang && j + 1 < n && !afterDot) {
      final d = t.codeUnitAt(j + 1);
      if (d == 0x28 || d == 0x5B || d == 0x7B) {
        emit(out, i, j + 1, TokenKind.function);
        return j + 1;
      }
    }
    if (s.capsType && isUpper(first)) {
      if (!hasLower && j - i >= 2) {
        emit(out, i, j, next == 0x28 ? TokenKind.function : TokenKind.constant);
      } else if (next == 0x28 && (s.upperCall || afterDot)) {
        emit(out, i, j, TokenKind.function);
      } else if (!afterDot) {
        emit(out, i, j, TokenKind.type);
      }
      return j;
    }
    if (next == 0x28) emit(out, i, j, TokenKind.function);
    return j;
  }

  bool _softFollows(String t, int j, int n) {
    final k = skipBlanks(t, j, n);
    if (k == j || k >= n) return false;
    final c = t.codeUnitAt(k);
    return isIdentStart(c) || c == 0x22 || c == 0x27;
  }

  bool _rawPrefix(String t, int i, int j) {
    final len = j - i;
    if (len == 1) return t.codeUnitAt(i) == 0x72;
    if (len == 2) {
      final p = t.codeUnitAt(i);
      return (p == 0x62 || p == 0x63) && t.codeUnitAt(i + 1) == 0x72;
    }
    return false;
  }

  bool _prefix(String t, int i, int j) {
    if (j - i > s.maxPrefix) return false;
    for (var k = i; k < j; k++) {
      if (!s.prefixes.contains(t[k])) return false;
    }
    return true;
  }

  // ---- punctuation-ish ---------------------------------------------------------

  bool _isOperator(int c) {
    switch (c) {
      case 0x2B: // +
      case 0x2D: // -
      case 0x2A: // *
      case 0x2F: // /
      case 0x25: // %
      case 0x3D: // =
      case 0x3C: // <
      case 0x3E: // >
      case 0x21: // !
      case 0x26: // &
      case 0x7C: // |
      case 0x5E: // ^
      case 0x7E: // ~
      case 0x3F: // ?
        return true;
    }
    return false;
  }

  int _operator(String t, int i, int n, List<Token> out) {
    var j = i + 1;
    while (j < n) {
      final c = t.codeUnitAt(j);
      if (!_isOperator(c)) break;
      if (j + 1 < n) {
        final d = t.codeUnitAt(j + 1);
        if (c == 0x2F && ((d == 0x2F && s.lineSlash) || (d == 0x2A && s.block))) {
          break;
        }
        if (c == 0x2D && d == 0x2D && s.lineDash) break;
      }
      j++;
    }
    emit(out, i, j, TokenKind.operator);
    return j;
  }

  int _hash(String t, int i, int n, List<Token> out) {
    if (s.lineHash) {
      emit(out, i, n, TokenKind.comment);
      return n;
    }
    if (s.rustAttr && i + 1 < n) {
      var j = i + 1;
      if (t.codeUnitAt(j) == 0x21) j++;
      if (j < n && t.codeUnitAt(j) == 0x5B) {
        var depth = 0;
        for (; j < n; j++) {
          final c = t.codeUnitAt(j);
          if (c == 0x5B) depth++;
          if (c == 0x5D && --depth == 0) {
            j++;
            break;
          }
        }
        emit(out, i, j, TokenKind.attribute);
        return j;
      }
    }
    if (s.directives == Directives.anywhere ||
        (s.directives == Directives.lineStart && onlyBlankBefore(t, i))) {
      var j = skipBlanks(t, i + 1, n);
      final nameStart = j;
      while (j < n && isIdentPart(t.codeUnitAt(j))) {
        j++;
      }
      if (j == nameStart) return i + 1;
      emit(out, i, j, TokenKind.keyword);
      if (s.directives == Directives.lineStart &&
          (_is(t, nameStart, j, 'include') || _is(t, nameStart, j, 'import'))) {
        final k = skipBlanks(t, j, n);
        if (k < n && t.codeUnitAt(k) == 0x3C) {
          var e = k + 1;
          while (e < n && t.codeUnitAt(e) != 0x3E) {
            e++;
          }
          if (e < n) e++;
          emit(out, k, e, TokenKind.string);
          return e;
        }
      }
      return j;
    }
    return i + 1;
  }

  bool _is(String t, int s, int e, String word) =>
      e - s == word.length && t.startsWith(word, s);

  int _at(String t, int i, int n, List<Token> out) {
    if (s.atAttribute && i + 1 < n && isIdentStart(t.codeUnitAt(i + 1))) {
      var j = i + 2;
      while (j < n) {
        final c = t.codeUnitAt(j);
        if (isIdentPart(c) ||
            (c == 0x2E && j + 1 < n && isIdentStart(t.codeUnitAt(j + 1)))) {
          j++;
        } else {
          break;
        }
      }
      emit(out, i, j, TokenKind.attribute);
      return j;
    }
    return i + 1;
  }

  /// End of a regular-expression literal starting at [i], or -1.
  int _regex(String t, int i, int n) {
    var p = i - 1;
    while (p >= 0 && isSpace(t.codeUnitAt(p))) {
      p--;
    }
    if (p >= 0) {
      final c = t.codeUnitAt(p);
      var ok = false;
      switch (c) {
        case 0x28: // (
        case 0x2C: // ,
        case 0x3D: // =
        case 0x3A: // :
        case 0x5B: // [
        case 0x21: // !
        case 0x26: // &
        case 0x7C: // |
        case 0x3F: // ?
        case 0x7B: // {
        case 0x7D: // }
        case 0x3B: // ;
        case 0x2B: // +
        case 0x2A: // *
        case 0x25: // %
        case 0x3E: // >
        case 0x7E: // ~
        case 0x5E: // ^
          ok = true;
        default:
          ok = _endsWord(t, p, 'return') || _endsWord(t, p, 'typeof');
      }
      if (!ok) return -1;
    }
    var j = i + 1;
    var inClass = false;
    while (j < n) {
      final c = t.codeUnitAt(j);
      if (c == 0x5C) {
        j += 2;
        continue;
      }
      if (c == 0x5B) {
        inClass = true;
      } else if (c == 0x5D) {
        inClass = false;
      } else if (c == 0x2F && !inClass) {
        break;
      }
      j++;
    }
    if (j >= n || j == i + 1) return -1;
    j++;
    while (j < n && isLetter(t.codeUnitAt(j))) {
      j++;
    }
    return j;
  }

  bool _endsWord(String t, int p, String word) {
    final start = p - word.length + 1;
    return start >= 0 &&
        t.startsWith(word, start) &&
        (start == 0 || !isIdentPart(t.codeUnitAt(start - 1)));
  }
}
