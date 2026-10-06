import 'model.dart';

/// Lines longer than this are not tokenized (bounded cost): they come back as
/// one plain token and the state is left as it was.
const int maxLineLength = 2000;

/// The one state class every scanner uses: a small mode number, two integers
/// and an optional string (a heredoc terminator). Value-equal.
final class LexState implements HighlightState {
  const LexState(this.mode, [this.a = 0, this.b = 0, this.tag]);

  static const LexState initial = LexState(0);

  final int mode, a, b;
  final String? tag;

  @override
  bool operator ==(Object other) =>
      other is LexState &&
      other.mode == mode &&
      other.a == a &&
      other.b == b &&
      other.tag == tag;

  @override
  int get hashCode => Object.hash(mode, a, b, tag);

  @override
  String toString() => 'LexState($mode, $a, $b${tag == null ? '' : ', $tag'})';
}

/// [prev] itself when the new values equal it (no allocation for the common
/// "nothing changed" line).
LexState nextState(LexState prev, int mode, int a, int b, String? tag) =>
    prev.mode == mode && prev.a == a && prev.b == b && prev.tag == tag
        ? prev
        : LexState(mode, a, b, tag);

/// Appends `[s, e)` as [kind], merging into the previous token when they touch
/// and share a kind. Plain and empty spans are dropped (gaps are plain).
void emit(List<Token> out, int s, int e, TokenKind kind) {
  if (s >= e || kind == TokenKind.plain) return;
  if (out.isNotEmpty) {
    final p = out.last;
    if (p.end == s && p.kind == kind) {
      out[out.length - 1] = Token(p.start, e, kind);
      return;
    }
  }
  out.add(Token(s, e, kind));
}

/// Base of the scanners: line-length guard, state in/out through the scratch
/// fields [mode], [a], [b], [tag] (single-threaded, not re-entrant).
abstract class LineScanner implements LineHighlighter {
  int mode = 0, a = 0, b = 0;
  String? tag;

  @override
  HighlightState get initial => LexState.initial;

  @override
  (List<Token>, HighlightState) line(String text, HighlightState state) {
    final st = state is LexState ? state : LexState.initial;
    final n = text.length;
    if (n > maxLineLength) return (<Token>[Token(0, n, TokenKind.plain)], st);
    mode = st.mode;
    a = st.a;
    b = st.b;
    tag = st.tag;
    final out = <Token>[];
    scan(text, n, out);
    return (out, nextState(st, mode, a, b, tag));
  }

  /// Tokenizes [t] (length [n]) into [out], reading and updating the scratch
  /// state.
  void scan(String t, int n, List<Token> out);
}

bool isDigit(int c) => c >= 0x30 && c <= 0x39;

bool isUpper(int c) => c >= 0x41 && c <= 0x5A;

bool isLower(int c) => c >= 0x61 && c <= 0x7A;

bool isLetter(int c) => isUpper(c) || isLower(c);

bool isHex(int c) =>
    isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66);

/// Letters, `_`, `$` and everything non-ASCII (Unicode identifiers).
bool isIdentStart(int c) => isLetter(c) || c == 0x5F || c == 0x24 || c >= 0x80;

bool isIdentPart(int c) => isIdentStart(c) || isDigit(c);

bool isSpace(int c) => c == 0x20 || c == 0x09;

/// True when only blanks precede [i] on the line.
bool onlyBlankBefore(String t, int i) {
  for (var k = i - 1; k >= 0; k--) {
    if (!isSpace(t.codeUnitAt(k))) return false;
  }
  return true;
}

/// First non-blank index at or after [i] (or [n]).
int skipBlanks(String t, int i, int n) {
  while (i < n && isSpace(t.codeUnitAt(i))) {
    i++;
  }
  return i;
}

/// End of the number starting at [i] (a digit, or `.` before a digit):
/// radix prefixes, `_` separators, fraction, exponent, and a type suffix
/// (`u32`, `f`, `L`, `n`).
int scanNumber(String t, int i, int n) {
  var j = i;
  final c = t.codeUnitAt(i);
  if (c == 0x30 && i + 1 < n) {
    final x = t.codeUnitAt(i + 1) | 0x20;
    if (x == 0x78 || x == 0x62 || x == 0x6F) {
      j = i + 2;
      while (j < n && (isHex(t.codeUnitAt(j)) || t.codeUnitAt(j) == 0x5F)) {
        j++;
      }
      return _suffix(t, j, n);
    }
  }
  if (c == 0x2E) {
    j = i + 1;
  } else {
    while (j < n && (isDigit(t.codeUnitAt(j)) || t.codeUnitAt(j) == 0x5F)) {
      j++;
    }
    if (j + 1 < n && t.codeUnitAt(j) == 0x2E && isDigit(t.codeUnitAt(j + 1))) {
      j++;
    } else {
      return _exponentAndSuffix(t, j, n);
    }
  }
  while (j < n && (isDigit(t.codeUnitAt(j)) || t.codeUnitAt(j) == 0x5F)) {
    j++;
  }
  return _exponentAndSuffix(t, j, n);
}

int _exponentAndSuffix(String t, int j, int n) {
  if (j < n && (t.codeUnitAt(j) | 0x20) == 0x65) {
    var k = j + 1;
    if (k < n && (t.codeUnitAt(k) == 0x2B || t.codeUnitAt(k) == 0x2D)) k++;
    if (k < n && isDigit(t.codeUnitAt(k))) {
      j = k;
      while (j < n && (isDigit(t.codeUnitAt(j)) || t.codeUnitAt(j) == 0x5F)) {
        j++;
      }
    }
  }
  return _suffix(t, j, n);
}

int _suffix(String t, int j, int n) {
  while (j < n && isIdentPart(t.codeUnitAt(j))) {
    j++;
  }
  return j;
}
