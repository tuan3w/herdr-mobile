/// Splits a message into chunks that parse independently and never change once
/// closed: the freeze boundary of `StreamingMd`.
///
/// Internal to `ui/core/markdown/` (not exported by `markdown.dart`). Pure Dart.
///
/// A chunk is a run of lines that ends at a blank line outside a code fence or
/// raw-HTML block, except where the next line may still belong to it:
///
///  * a chunk that holds a list item (anywhere in it) continues over blank
///    lines when the next line is indented 2+ columns or is another list
///    marker (continuation paragraphs, code in items, loose lists);
///  * a chunk that begins with an indented code block continues while the next
///    line is indented 4+ columns.
///
/// Both rules over-merge rather than under-merge: a merged chunk only costs
/// freezing later, a split inside a block would change its meaning. Such a
/// chunk is closed only when the first line of the next one has arrived; every
/// other chunk closes at its blank line. The chunker is fed complete lines
/// only: an unterminated last line never decides a boundary.
///
/// Link reference definitions are the one construct that crosses chunks in
/// CommonMark; a reference is resolved only inside its own chunk.
library;

/// Line range `[start, end)` of a closed chunk (trailing blank lines excluded).
typedef MdChunkRange = ({int start, int end});

final class MdChunker {
  /// Every complete line fed so far (no line terminators).
  final List<String> lines = <String>[];

  /// Closed chunks, in order. A closed chunk never changes.
  final List<MdChunkRange> closed = <MdChunkRange>[];

  /// First line of the open chunk, `-1` when none is open (the text so far
  /// ends in blank lines or is empty).
  int get openStart => _open;

  int _open = -1;
  int _lastContent = -1;
  int _pendingBlank = 0;
  bool _listCtx = false;
  bool _indentedCode = false;
  int _fenceChar = 0;
  int _fenceLen = 0;
  int _fenceIndent = 0;
  bool _fenceInList = false;
  String? _htmlEnd;

  bool _htmlToBlank = false;
  int _minItemOffset = _noOffset;
  bool get _inFence => _fenceChar != 0;
  int _fenceContainer = 0;

  /// Feeds one complete line.
  void addLine(String line) {
    final at = lines.length;
    lines.add(line);

    if (_open >= 0 && _inFence) {
      // A fence inside a list item ends where the item does: at a line indented
      // less than the item's content. Such a line is then an ordinary line.
      if (_fenceInList && !isBlank(line) && indentAfterQuotes(line) < _fenceContainer) {
        _fenceChar = 0;
      } else {
        _lastContent = at;
        _fenceLine(line);
        return;
      }
    }
    if (_open >= 0 && _htmlEnd != null) {
      _lastContent = at;
      if (line.toLowerCase().contains(_htmlEnd!)) _htmlEnd = null;
      return;
    }

    final blank = isBlank(line);
    if (_open < 0) {
      if (!blank) _begin(at, line);
      return;
    }
    if (blank) {
      _htmlToBlank = false;
      if (_listCtx || _indentedCode) {
        _pendingBlank++;
      } else {
        _close();
      }
      return;
    }
    if (_pendingBlank > 0) {
      if (!_continues(line)) {
        _close();
        _begin(at, line);
        return;
      }
      _pendingBlank = 0;
    }
    _lastContent = at;
    _scan(line, first: false);
  }

  /// The source of the open chunk (blank lines it swallowed included) followed
  /// by [partial], the unterminated last line. This is the part of a message
  /// that is not frozen yet.
  String tailSource(String partial) {
    if (_open < 0) return partial;
    final b = StringBuffer(source(_open, lines.length));
    if (partial.isNotEmpty) {
      b
        ..writeCharCode(0x0a)
        ..write(partial);
    }
    return b.toString();
  }

  /// The source of lines `[start, end)`.
  String source(int start, int end) {
    if (end - start == 1) return lines[start];
    final b = StringBuffer();
    for (var i = start; i < end; i++) {
      if (i > start) b.writeCharCode(0x0a);
      b.write(lines[i]);
    }
    return b.toString();
  }

  void _close() {
    closed.add((start: _open, end: _lastContent + 1));
    _open = -1;
    _pendingBlank = 0;
    _listCtx = false;
    _minItemOffset = _noOffset;
    _indentedCode = false;
    _fenceChar = 0;
    _htmlEnd = null;
    _htmlToBlank = false;
  }

  void _begin(int at, String line) {
    _open = at;
    _lastContent = at;
    _pendingBlank = 0;
    _listCtx = false;
    _minItemOffset = _noOffset;
    _fenceChar = 0;
    _htmlEnd = null;
    _htmlToBlank = false;
    _indentedCode = indentOf(line) >= 4;
    _scan(line, first: true);
  }

  /// Updates fence, raw-HTML and list state from one non-blank line. Raw HTML
  /// blocks of types 1 to 5 can start anywhere (they interrupt a paragraph),
  /// so can type 6; type 7 only opens a chunk.
  void _scan(String line, {required bool first}) {
    if (_htmlToBlank) return;
    final s = stripContainers(line);
    final indent = indentAfterQuotes(line);
    // An indented code block can start after a heading, rule or closed fence;
    // blank lines inside it must not split the chunk.
    if (indent >= 4 && !_listCtx) _indentedCode = true;
    final fence0 = fenceOpener(s);
    if (isListMarker(s)) {
      _listCtx = true;
      final off = _itemOffset(indent, s);
      if (off < _minItemOffset) _minItemOffset = off;
    } else if (_listCtx && indent < 2 && !line.startsWith(' ')) {
      // A fence, heading, quote or rule at column 0 ends the list.
      final t = line.trimLeft();
      if (fence0 != null || t.startsWith('>') || _heading.hasMatch(t) || _thematic.hasMatch(t)) {
        _listCtx = false;
        _minItemOffset = _noOffset;
      }
    }
    // Indented 4+ columns and not inside a list item: code, not a fence.
    final inItem = _listCtx && indent >= _minItemOffset;
    final fence = indent < 4 || inItem ? fence0 : null;
    if (fence != null) {
      _fenceChar = fence.char;
      _fenceLen = fence.len;
      _fenceIndent = indent;
      _fenceInList = _listCtx && (isListMarker(s) || indent >= _minItemOffset);
      _fenceContainer = _minItemOffset;
      return;
    }
    if (indent < 4 || _listCtx) {
      final end = _htmlBlockEnd(s, line);
      if (end != null) {
        if (end.isNotEmpty) _htmlEnd = end;
      } else if (_html6.hasMatch(s) || (first && _html7.hasMatch(s))) {
        _htmlToBlank = true;
      }
    }
  }

  /// Content column of the list item a marker line starts.
  static int _itemOffset(int indent, String s) {
    final m = _markerWidth.firstMatch(s)!;
    var spaces = m.group(2)!.length;
    if (spaces == 0 || spaces > 4) spaces = 1;
    return indent + m.group(1)!.length + spaces;
  }

  void _fenceLine(String line) {
    // A closing fence is indented at most 3 columns inside its container; the
    // container of a list item is not known here, so there the opener's own
    // indent stands in for it.
    if (indentAfterQuotes(line) > (_fenceInList ? _fenceIndent + 3 : 3)) return;
    final s = stripContainers(line);
    var n = 0;
    while (n < s.length && s.codeUnitAt(n) == _fenceChar) {
      n++;
    }
    if (n >= _fenceLen && s.substring(n).trim().isEmpty) {
      _fenceChar = 0;
    }
  }

  /// Columns of indentation after the last `>` quote marker.
  static int indentAfterQuotes(String line) {
    var col = 0;
    for (var i = 0; i < line.length; i++) {
      final c = line.codeUnitAt(i);
      if (c == 0x20) {
        col++;
      } else if (c == 0x09) {
        col += 4 - col % 4;
      } else if (c == 0x3e) {
        col = 0;
        if (i + 1 < line.length && line.codeUnitAt(i + 1) == 0x20) i++;
      } else {
        break;
      }
    }
    return col;
  }

  bool _continues(String line) {
    final ind = indentOf(line);
    if (_listCtx) {
      return ind >= 2 || (ind <= 3 && isListMarker(line.trimLeft()));
    }
    if (_indentedCode) return ind >= 4;
    return false;
  }

  /// Whether [line] is empty or only spaces and tabs.
  static bool isBlank(String line) {
    for (var i = 0; i < line.length; i++) {
      final c = line.codeUnitAt(i);
      if (c != 0x20 && c != 0x09) return false;
    }
    return true;
  }

  /// Leading columns of whitespace (a tab advances to the next multiple of 4).
  static int indentOf(String line) {
    var col = 0;
    for (var i = 0; i < line.length; i++) {
      final c = line.codeUnitAt(i);
      if (c == 0x20) {
        col++;
      } else if (c == 0x09) {
        col += 4 - col % 4;
      } else {
        break;
      }
    }
    return col;
  }

  /// The line without leading spaces and `>` quote markers.
  static String stripContainers(String line) {
    var i = 0;
    while (i < line.length) {
      final c = line.codeUnitAt(i);
      if (c == 0x20 || c == 0x09 || c == 0x3e) {
        i++;
      } else {
        break;
      }
    }
    return i == 0 ? line : line.substring(i);
  }

  /// A bullet or ordered list marker at the start of [s] (indentation already
  /// removed), thematic breaks excluded.
  static bool isListMarker(String s) =>
      _markerPrefix.matchAsPrefix(s) != null && !_thematic.hasMatch(s);

  /// The code fence [s] (indentation and quote markers removed) opens, also
  /// after a list marker (`- ```sh`): its character and run length.
  static ({int char, int len})? fenceOpener(String s) {
    var t = s;
    var m = _fenceOpen.matchAsPrefix(t);
    if (m == null) {
      final lm = _markerPrefix.matchAsPrefix(t);
      if (lm == null) return null;
      t = t.substring(lm.end);
      m = _fenceOpen.matchAsPrefix(t);
      if (m == null) return null;
    }
    final run = m.group(1)!;
    // A backtick fence's info string cannot contain a backtick.
    if (run.codeUnitAt(0) == 0x60 && m.group(2)!.contains('`')) return null;
    return (char: run.codeUnitAt(0), len: run.length);
  }

  /// The token that ends a raw HTML block of type 1 to 5 starting at [line]: ''
  /// when it also ends on that line, null when [line] starts no such block.
  static String? _htmlBlockEnd(String s, String line) {
    final t = line.trimLeft();
    if (!t.startsWith('<')) return null;
    final lower = t.toLowerCase();
    String? end;
    if (lower.startsWith('<!--')) {
      end = '-->';
    } else if (lower.startsWith('<?')) {
      end = '?>';
    } else if (lower.startsWith('<![cdata[')) {
      end = ']]>';
    } else if (lower.startsWith('<!') && lower.length > 2 && _isAsciiLetter(lower.codeUnitAt(2))) {
      end = '>';
    } else {
      for (final tag in const ['script', 'pre', 'style', 'textarea']) {
        if (lower.startsWith('<$tag') &&
            (lower.length == tag.length + 1 ||
                const [0x20, 0x09, 0x3e].contains(lower.codeUnitAt(tag.length + 1)))) {
          end = '</$tag>';
        }
      }
    }
    if (end == null) return null;
    // Closed on its own line: an empty end.
    final from = end == '-->' ? 4 : 1;
    return lower.length > from && lower.indexOf(end, from) >= 0 ? '' : end;
  }

  static bool _isAsciiLetter(int c) => (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);

  static final RegExp _fenceOpen = RegExp(r'(`{3,}|~{3,})(.*)$');
  static final RegExp _markerPrefix = RegExp(r'(?:[-*+]|\d{1,9}[.)])(?:[ \t]|$)');
  static final RegExp _thematic = RegExp(r'^([-*_])(?:[ \t]*\1){2,}[ \t]*$');
  static final RegExp _heading = RegExp(r'^#{1,6}(?:[ \t]|$)');
  static final RegExp _markerWidth = RegExp(r'^([-*+]|\d{1,9}[.)])( *)');
  static const int _noOffset = 1 << 30;
  // CommonMark raw HTML block types 6 and 7: only a blank line ends them.
  static final RegExp _html6 = RegExp(
    r'^</?(?:address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul)(?:[ \t]|/?>|$)',
    caseSensitive: false,
  );
  static final RegExp _html7 = RegExp(
    r'^(?:<[A-Za-z][A-Za-z0-9-]*(?:[ \t]+[^<>]*)?/?>|</[A-Za-z][A-Za-z0-9-]*[ \t]*>)[ \t]*$',
  );
}
