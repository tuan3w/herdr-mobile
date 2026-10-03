/// Finds tappable URLs and file paths in one line of terminal text.
///
/// The detector is a hand-written scanner rather than one big regular
/// expression: it runs on the UI isolate for every visible line, a regex with
/// this many alternations and look-behinds would be slow to build, hard to
/// read and prone to catastrophic backtracking on hostile output. The scanner
/// makes a single forward pass, tries a candidate only where one may start and
/// never re-reads characters it has already classified.
library;

import 'box_drawing.dart' show isBoxGlyph;
import 'cell_width.dart';

/// What a [TerminalLink] opens.
enum TerminalLinkKind { url, path }

/// A tappable stretch of one terminal line.
final class TerminalLink {
  const TerminalLink({
    required this.kind,
    required this.text,
    required this.target,
    required this.start,
    required this.end,
    this.line,
    this.column,
  });

  final TerminalLinkKind kind;

  /// Exactly as displayed, e.g. `src/main.dart:42:7` or `https://x.dev/a`.
  final String text;

  /// The URL, or the path without its `:line:col` / `(line,col)` suffix.
  final String target;

  /// Cell columns `[start, end)` of [text] in the line, so wide characters
  /// before the link shift it by two columns each and combining marks by none.
  final int start, end;

  /// One-based position the link points at, when the text gave one.
  final int? line, column;

  @override
  bool operator ==(Object other) =>
      other is TerminalLink &&
      other.kind == kind &&
      other.text == text &&
      other.target == target &&
      other.start == start &&
      other.end == end &&
      other.line == line &&
      other.column == column;

  @override
  int get hashCode => Object.hash(kind, text, target, start, end, line, column);

  @override
  String toString() =>
      'TerminalLink(${kind.name} "$text" -> "$target" [$start,$end)'
      '${line == null ? '' : ' line $line'}'
      '${column == null ? '' : ' col $column'})';
}

/// How many UTF-16 units of a line are scanned.
///
/// Terminal output can contain multi-megabyte single lines (minified bundles,
/// base64 blobs). A link is only useful on a screen-sized line, so anything
/// past this is ignored instead of paying for it on every repaint; a link
/// straddling the limit is cut or lost.
const int _maxScanUnits = 2000;

/// Links in one line of visible text (ANSI already stripped), sorted by start
/// and never overlapping.
///
/// Box-drawing and block characters are the terminal view's own artwork, so
/// they separate words like whitespace: `│ src/a.dart │` links `src/a.dart`.
/// Only the first [_maxScanUnits] UTF-16 units of [text] are examined.
List<TerminalLink> detectLinks(String text) {
  if (text.isEmpty) return const [];
  final line = text.length > _maxScanUnits
      ? text.substring(0, _maxScanUnits)
      : text;
  return _Scanner(line).scan();
}

const int _space = 0x20;
const int _quote = 0x22;
const int _percent = 0x25;
const int _apostrophe = 0x27;
const int _openParen = 0x28;
const int _closeParen = 0x29;
const int _star = 0x2a;
const int _plus = 0x2b;
const int _comma = 0x2c;
const int _minus = 0x2d;
const int _dot = 0x2e;
const int _slash = 0x2f;
const int _colon = 0x3a;
const int _semicolon = 0x3b;
const int _less = 0x3c;
const int _equals = 0x3d;
const int _greater = 0x3e;
const int _question = 0x3f;
const int _at = 0x40;
const int _openBracket = 0x5b;
const int _closeBracket = 0x5d;
const int _underscore = 0x5f;
const int _backtick = 0x60;
const int _openBrace = 0x7b;
const int _closeBrace = 0x7d;
const int _tilde = 0x7e;

/// Line and column numbers longer than this are not positions (timestamps,
/// sizes), so the suffix is left unlinked.
const int _maxPositionDigits = 7;

/// Longest extension a relative path may end in.
const int _maxExtensionLength = 8;

/// Letters, digits and combining marks of any script. Combining marks belong
/// to the word because decomposed Vietnamese text carries its diacritics as
/// separate code points. Compiled once; used with `matchAsPrefix` so no
/// substring is allocated per character.
final RegExp _wordChar = RegExp(r'[\p{L}\p{N}\p{M}]', unicode: true);

/// Extensions that make a bare `name.ext` (no directory) worth linking. Kept
/// closed because any word ending in `.something` would otherwise match
/// (`e.g`, `www.x.com`, `10.0.0.1`).
const Set<String> _knownExtensions = {
  'dart', 'py', 'js', 'ts', 'tsx', 'jsx', 'mjs', 'cjs', 'rs', 'go', 'c', 'h',
  'cc', 'cpp', 'hpp', 'cs', 'java', 'kt', 'kts', 'swift', 'rb', 'php', 'sh',
  'bash', 'zsh', 'fish', 'lua', 'sql', 'r', 'scala', 'ex', 'exs', 'erl', 'hs',
  'ml', 'clj', 'gradle', 'proto', 'cmake', 'make', 'mk', 'md', 'mdx', 'txt',
  'rst', 'adoc', 'tex', 'log', 'json', 'jsonl', 'yaml', 'yml', 'toml', 'ini',
  'cfg', 'conf', 'env', 'lock', 'xml', 'html', 'htm', 'css', 'scss', 'sass',
  'less', 'csv', 'tsv', 'pdf', 'png', 'jpg', 'jpeg', 'gif', 'webp', 'svg',
  'bmp', 'ico', 'heic', 'avif', 'mp3', 'mp4', 'mov', 'wav', 'zip', 'tar', 'gz',
  'tgz', 'xz', 'bz2', '7z', 'apk', 'aab', 'so', 'dll', 'exe', 'db', 'sqlite',
  'sqlite3', 'wasm', 'ipynb', 'dockerfile', //
};

/// Extension-less file names that are still unmistakably files.
const Set<String> _knownNames = {'Makefile', 'Dockerfile', 'README', 'LICENSE'};

/// Longest entry of [_knownExtensions] and [_knownNames]; lets other words
/// skip the set lookup (and its lower-casing allocation) by length alone.
const int _maxKnownLength = 10;

bool _isAsciiDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isAsciiLetter(int c) {
  final lower = c | 0x20;
  return lower >= 0x61 && lower <= 0x7a;
}

bool _isAsciiAlnum(int c) => _isAsciiDigit(c) || _isAsciiLetter(c);

/// Whitespace, control characters and the box/block glyphs the terminal view
/// draws itself: they end words.
bool _isSeparator(int c) {
  if (c < 0x80) return c <= _space || c == 0x7f;
  return c == 0xa0 ||
      c == 0x1680 ||
      (c >= 0x2000 && c <= 0x200a) ||
      c == 0x2028 ||
      c == 0x2029 ||
      c == 0x202f ||
      c == 0x205f ||
      c == 0x3000 ||
      isBoxGlyph(c);
}

/// Characters that may directly precede a path: anything else means the path
/// would be glued to a longer word (`x-foo/bar.txt`, `a.b.c.dart`).
bool _isPathBoundary(int c) {
  if (_isSeparator(c)) return true;
  switch (c) {
    case _openParen:
    case _openBracket:
    case _openBrace:
    case _less:
    case _quote:
    case _apostrophe:
    case _backtick:
    case _equals:
    case _comma:
    case _semicolon:
    case _colon:
      return true;
  }
  return false;
}

/// Characters a URL never contains: whitespace, box glyphs and the delimiters
/// that wrap URLs in prose, markdown autolinks and quoted strings.
bool _isUrlTerminator(int c) =>
    _isSeparator(c) || c == _less || c == _greater || c == _quote;

/// One pass over one line; owns the cell-column cursor and the results.
final class _Scanner {
  _Scanner(this._s) : _n = _s.length;

  final String _s;
  final int _n;
  final List<TerminalLink> _links = [];

  /// Start of the whitespace-delimited token being scanned; bounds the
  /// look-behind for `user@host:` prefixes.
  int _tokenStart = 0;

  /// Column cursor: cell column [_cursorColumn] sits at UTF-16 index
  /// [_cursorUnit]. Links are found left to right, so converting their
  /// indexes to columns never rewinds and the whole line is walked once.
  int _cursorUnit = 0;
  int _cursorColumn = 0;

  List<TerminalLink> scan() {
    var i = 0;
    while (i < _n) {
      final c = _s.codeUnitAt(i);
      if (_isSeparator(c)) {
        _tokenStart = ++i;
        continue;
      }
      var next = -1;
      if (c | 0x20 == 0x68) next = _tryUrl(i);
      if (next < 0) {
        if (i == 0) {
          next = _tryPath(i);
        } else {
          final previous = _s.codeUnitAt(i - 1);
          // `</div>`: a slash right after `<` closes a tag, it does not start
          // an absolute path. `<~/a>` and `<src/a>` are still paths.
          next =
              _isPathBoundary(previous) && !(c == _slash && previous == _less)
              ? _tryPath(i)
              : i + 1;
        }
      }
      i = next;
    }
    return _links;
  }

  // -- columns ---------------------------------------------------------------

  int _columnAt(int unit) {
    var u = _cursorUnit;
    var column = _cursorColumn;
    while (u < unit) {
      var rune = _s.codeUnitAt(u++);
      if (rune >= 0xd800 && rune <= 0xdbff && u < _n) {
        final trail = _s.codeUnitAt(u);
        if (trail >= 0xdc00 && trail <= 0xdfff) {
          rune = 0x10000 + ((rune - 0xd800) << 10) + (trail - 0xdc00);
          u++;
        }
      }
      column += cellWidth(rune);
    }
    _cursorUnit = u;
    _cursorColumn = column;
    return column;
  }

  void _emit(
    TerminalLinkKind kind,
    int start,
    int targetEnd,
    int textEnd, {
    int? line,
    int? column,
  }) {
    _links.add(
      TerminalLink(
        kind: kind,
        text: _s.substring(start, textEnd),
        target: _s.substring(start, targetEnd),
        start: _columnAt(start),
        end: _columnAt(textEnd),
        line: line,
        column: column,
      ),
    );
  }

  // -- URLs ------------------------------------------------------------------

  /// Parses a URL starting at [i]; returns the index to resume scanning at, or
  /// -1 if there is no URL here.
  int _tryUrl(int i) {
    // `http` must not be the tail of a longer word.
    if (i > 0 && _isAsciiAlnum(_s.codeUnitAt(i - 1))) return -1;
    var p = i + 4;
    if (p + 3 > _n || !_matchesHttp(i)) return -1;
    if (_s.codeUnitAt(p) | 0x20 == 0x73) p++;
    if (p + 3 > _n ||
        _s.codeUnitAt(p) != _colon ||
        _s.codeUnitAt(p + 1) != _slash ||
        _s.codeUnitAt(p + 2) != _slash) {
      return -1;
    }
    final hostStart = p + 3;
    if (hostStart >= _n) return -1;
    final first = _s.codeUnitAt(hostStart);
    if (!(_isAsciiAlnum(first) || first == _openBracket || first >= 0x80) ||
        _isUrlTerminator(first)) {
      return -1;
    }

    var runEnd = hostStart;
    var parens = 0, brackets = 0, braces = 0; // opens minus closes so far
    while (runEnd < _n) {
      final c = _s.codeUnitAt(runEnd);
      if (_isUrlTerminator(c)) break;
      switch (c) {
        case _openParen:
          parens++;
        case _closeParen:
          parens--;
        case _openBracket:
          brackets++;
        case _closeBracket:
          brackets--;
        case _openBrace:
          braces++;
        case _closeBrace:
          braces--;
      }
      runEnd++;
    }

    // Trailing punctuation belongs to the sentence around the URL. A closing
    // bracket stays only while it pairs with an earlier opening one; the
    // counters above make that O(1) per trimmed character. `<`, `>` and `"`
    // never get here: they already ended the run.
    var end = runEnd;
    trim:
    while (end > hostStart) {
      switch (_s.codeUnitAt(end - 1)) {
        case _closeParen:
          if (parens >= 0) break trim;
          parens++;
        case _closeBracket:
          if (brackets >= 0) break trim;
          brackets++;
        case _closeBrace:
          if (braces >= 0) break trim;
          braces++;
        case _dot:
        case _comma:
        case _semicolon:
        case _colon:
        case 0x21: // !
        case _question:
        case _apostrophe:
        case _star:
        case _underscore:
          break;
        default:
          break trim;
      }
      end--;
    }
    _emit(TerminalLinkKind.url, i, end, end);
    return runEnd;
  }

  /// Whether the four units at [i] spell `http`, in any case.
  bool _matchesHttp(int i) =>
      _s.codeUnitAt(i) | 0x20 == 0x68 &&
      _s.codeUnitAt(i + 1) | 0x20 == 0x74 &&
      _s.codeUnitAt(i + 2) | 0x20 == 0x74 &&
      _s.codeUnitAt(i + 3) | 0x20 == 0x70;

  // -- paths -----------------------------------------------------------------

  /// Length in UTF-16 units of the path character at [k], or 0 if there is
  /// none. `*`, `?`, `[`, `=`, `#` and `:` are deliberately absent so a path
  /// stops before globs, query strings, fragments and `:line` suffixes.
  int _pathCharLength(int k) {
    final c = _s.codeUnitAt(k);
    if (c < 0x80) {
      if (_isAsciiAlnum(c)) return 1;
      switch (c) {
        case _underscore:
        case _minus:
        case _dot:
        case _plus:
        case _at:
        case _tilde:
        case _percent:
        case _slash:
          return 1;
      }
      return 0;
    }
    final match = _wordChar.matchAsPrefix(_s, k);
    return match == null ? 0 : match.end - k;
  }

  /// Tries a path at [i] (already at a legal boundary); returns the index to
  /// resume scanning at, always greater than [i].
  int _tryPath(int i) {
    var runEnd = i;
    while (runEnd < _n) {
      final length = _pathCharLength(runEnd);
      if (length == 0) break;
      runEnd += length;
    }
    if (runEnd == i) return i + 1;
    // Whatever happens, no other path can start before the run ends: its first
    // character would have to follow a boundary, and boundaries are not path
    // characters.
    if (runEnd < _n && _continuesAsGlobOrQuery(runEnd)) return runEnd;

    var end = runEnd;
    while (end > i && _s.codeUnitAt(end - 1) == _dot) {
      end--;
    }
    if (end == i || !_isPath(i, end) || _isScpRemotePath(i)) return runEnd;

    int? line, column;
    var textEnd = end;
    if (end == runEnd) {
      final position = _positionSuffix(end);
      if (position != null) {
        line = position.line;
        column = position.column;
        textEnd = position.end;
      } else {
        line = _pythonLine(end);
      }
    }
    _emit(TerminalLinkKind.path, i, end, textEnd, line: line, column: column);
    return textEnd;
  }

  /// Whether the character right after a path run ([k] < length) shows the
  /// token is a glob (`*`, `[`) or carries a query string (`?x`): such text
  /// is a pattern, not a file.
  bool _continuesAsGlobOrQuery(int k) {
    final c = _s.codeUnitAt(k);
    if (c == _star || c == _openBracket) return true;
    return c == _question && k + 1 < _n && _pathCharLength(k + 1) > 0;
  }

  /// Whether a path at [i] is the remote half of `user@host:/path`, which
  /// belongs to scp/rsync rather than the local file system.
  bool _isScpRemotePath(int i) {
    if (i == 0 || _s.codeUnitAt(i - 1) != _colon) return false;
    for (var k = i - 2; k >= _tokenStart; k--) {
      if (_s.codeUnitAt(k) == _at) return true;
    }
    return false;
  }

  /// Whether `_s[i, e)` (trailing dots already removed) is worth linking.
  bool _isPath(int i, int e) {
    final first = _s.codeUnitAt(i);
    var body = i; // first character after any `/`, `~/`, `./`, `../` prefix
    var absolute = false;
    var prefixed = true;
    if (first == _slash) {
      body = i + 1;
      absolute = true;
    } else if ((first == _tilde || first == _dot) &&
        i + 1 < e &&
        _s.codeUnitAt(i + 1) == _slash) {
      body = i + 2;
    } else if (first == _dot &&
        i + 2 < e &&
        _s.codeUnitAt(i + 1) == _dot &&
        _s.codeUnitAt(i + 2) == _slash) {
      body = i + 3;
    } else {
      prefixed = false;
    }

    // Walk the segments once: reject empty ones (`a//b`) and `...`-style dot
    // runs, remember where the last slash is and whether any letter or digit
    // exists.
    var alnum = false;
    var segmentStart = body;
    var segmentIsDots = true;
    var lastSlash = -1;
    var trailingSlash = false;
    for (var k = body; k <= e; k++) {
      final atEnd = k == e;
      final c = atEnd ? _slash : _s.codeUnitAt(k);
      if (c == _slash) {
        final length = k - segmentStart;
        if (length == 0) {
          if (!atEnd || k == body) return false;
          trailingSlash = true;
        } else if (segmentIsDots && length > 2) {
          return false;
        }
        if (!atEnd) lastSlash = k;
        segmentStart = k + 1;
        segmentIsDots = true;
      } else {
        if (c != _dot) segmentIsDots = false;
        if (_isAsciiAlnum(c) || c >= 0x80) alnum = true;
      }
    }
    if (!alnum) return false;
    if (absolute) return e - body >= 2;
    if (prefixed) return true;

    if (lastSlash < 0) return _isBareFile(i, e);
    // A directory must contain a letter or it is a date or a fraction.
    if (trailingSlash) {
      // `<br/>`: a lone name closed by `/>` is a self-closing tag.
      if (!prefixed &&
          lastSlash == e - 1 &&
          _s.indexOf('/', i) == lastSlash &&
          i > 0 &&
          _s.codeUnitAt(i - 1) == _less &&
          e < _n &&
          _s.codeUnitAt(e) == _greater) {
        return false;
      }
      return _hasLetter(i, e);
    }

    final segment = lastSlash + 1;
    var dot = e - 1;
    while (dot >= segment && _s.codeUnitAt(dot) != _dot) {
      dot--;
    }
    if (dot <= segment) return false; // no extension, or an empty stem
    final extensionLength = e - dot - 1;
    if (extensionLength > _maxExtensionLength) return false;
    for (var k = dot + 1; k < e; k++) {
      if (!_isAsciiAlnum(_s.codeUnitAt(k))) return false;
    }
    // `1/2.5` and `2024/01/05.1` are numbers; the extension itself does not
    // count towards being a name (`1/2.md` is not distinguishable from a date).
    return _hasLetter(i, dot);
  }

  /// Whether `_s[i, e)` has no slash and still reads as a file name.
  bool _isBareFile(int i, int e) {
    var dot = e - 1;
    while (dot >= i && _s.codeUnitAt(dot) != _dot) {
      dot--;
    }
    if (dot < i) {
      return e - i <= _maxKnownLength &&
          _knownNames.contains(_s.substring(i, e));
    }
    if (dot == i) return false; // empty stem
    for (var k = i; k < dot; k++) {
      if (_s.codeUnitAt(k) == _at) return false; // an email address
    }
    if (e - dot - 1 > _maxKnownLength ||
        !_knownExtensions.contains(_s.substring(dot + 1, e).toLowerCase())) {
      return false;
    }
    final first = _s.codeUnitAt(i);
    if (_isAsciiLetter(first) || first >= 0x80) return true;
    return _isAsciiDigit(first) && _hasLetter(i, dot);
  }

  /// Whether `_s[from, to)` contains a letter. Every non-ASCII character in a
  /// path run is a letter, digit or mark; counting them all as letters is
  /// close enough to tell `2024-01-05` from `báo-cáo`.
  bool _hasLetter(int from, int to) {
    for (var k = from; k < to; k++) {
      final c = _s.codeUnitAt(k);
      if (_isAsciiLetter(c) || c >= 0x80) return true;
    }
    return false;
  }

  // -- suffixes --------------------------------------------------------------

  /// End of the digit run starting at [from], or -1 unless it is 1 to
  /// [_maxPositionDigits] digits long.
  int _positionDigitsEnd(int from) {
    var k = from;
    while (k < _n && _isAsciiDigit(_s.codeUnitAt(k))) {
      k++;
    }
    final length = k - from;
    return length >= 1 && length <= _maxPositionDigits ? k : -1;
  }

  /// Parses `:LINE`, `:LINE:COL`, `(LINE)`, `(LINE,COL)` or `(LINE, COL)`
  /// directly at [at]; null if there is none.
  ({int line, int? column, int end})? _positionSuffix(int at) {
    if (at >= _n) return null;
    final c = _s.codeUnitAt(at);
    if (c == _colon) {
      final lineEnd = _positionDigitsEnd(at + 1);
      if (lineEnd < 0) return null;
      final line = int.parse(_s.substring(at + 1, lineEnd));
      if (lineEnd < _n && _s.codeUnitAt(lineEnd) == _colon) {
        final columnEnd = _positionDigitsEnd(lineEnd + 1);
        if (columnEnd >= 0) {
          return (
            line: line,
            column: int.parse(_s.substring(lineEnd + 1, columnEnd)),
            end: columnEnd,
          );
        }
      }
      // `file.dart:12:` ends with the separator, which is not part of the link.
      return (line: line, column: null, end: lineEnd);
    }
    if (c == _openParen) {
      final lineEnd = _positionDigitsEnd(at + 1);
      if (lineEnd < 0 || lineEnd >= _n) return null;
      final line = int.parse(_s.substring(at + 1, lineEnd));
      final next = _s.codeUnitAt(lineEnd);
      if (next == _closeParen) {
        return (line: line, column: null, end: lineEnd + 1);
      }
      if (next != _comma) return null;
      var columnStart = lineEnd + 1;
      if (columnStart < _n && _s.codeUnitAt(columnStart) == _space) {
        columnStart++;
      }
      final columnEnd = _positionDigitsEnd(columnStart);
      if (columnEnd < 0 ||
          columnEnd >= _n ||
          _s.codeUnitAt(columnEnd) != _closeParen) {
        return null;
      }
      return (
        line: line,
        column: int.parse(_s.substring(columnStart, columnEnd)),
        end: columnEnd + 1,
      );
    }
    return null;
  }

  /// Python tracebacks name the line after the path: `"/x/y.py", line 12`.
  /// Returns the line number when [at] (just past the path) continues like
  /// that; the displayed link stays the bare path.
  int? _pythonLine(int at) {
    var k = at;
    if (k < _n && _s.codeUnitAt(k) == _quote) k++;
    if (k >= _n || _s.codeUnitAt(k) != _comma) return null;
    k = _skipSpaces(k + 1);
    if (k < 0 || !_s.startsWith('line', k)) return null;
    k = _skipSpaces(k + 4);
    if (k < 0) return null;
    final lineEnd = _positionDigitsEnd(k);
    return lineEnd < 0 ? null : int.parse(_s.substring(k, lineEnd));
  }

  /// Index after the spaces at [from]; -1 if there is not at least one.
  int _skipSpaces(int from) {
    var k = from;
    while (k < _n && _s.codeUnitAt(k) == _space) {
      k++;
    }
    return k == from ? -1 : k;
  }
}
