/// Display-only healing of the open tail of a streaming message
/// (the rules of Vercel's `remend`).
///
/// [healTail] takes the SOURCE of the tail (the part of the message that is not
/// frozen) and returns source that renders what the finished text will most
/// likely render, instead of flickering through half-written syntax. It never
/// touches the stored text and never runs on frozen blocks; when the stream
/// ends the tail is shown unhealed. Pure Dart.
///
/// What it does, in this order:
///
///  1. Inside an open code fence: nothing, except dropping a partial closing
///     fence (`` `` `` under a ```` ``` ```` fence).
///  2. Holds back (drops) trailing lines that are only a block marker: `#`,
///     `-`, `*`, `>`, `1.`, `|`, `- [ ]`, a lone backtick run, `-`/`=`
///     underlines of a setext heading that is not decided yet (`Title` then
///     `---`), a table header row, and a table header row with a delimiter row
///     that is not complete yet.
///  3. On the last paragraph, with the CommonMark delimiter rules (flanking,
///     intra-word `_`, list-marker `*`, escapes, code spans) it closes
///     unterminated `**`, `__`, `*`, `_`, `***` and `~~` and a backtick span,
///     holds back a delimiter run that has nothing to open yet (`hello **`),
///     turns a partial link `[label](par` into `[label]()` (an empty
///     destination: styled as a link, not tappable), drops a partial image and
///     a partial `<https://...` autolink.
///
/// Left alone on purpose: `20~25`, `$5`, `a * b`, `x_y_z`, `__init__.py`,
/// `<` comparisons, `\*`, anything in code, `[label` without `](`.
library;

import 'md_chunker.dart';

/// Returns [tail] healed for display; [tail] itself when nothing needs healing.
String healTail(String tail) {
  if (tail.isEmpty) return tail;
  final lines = tail.split('\n');

  final fence = _openFenceAtEnd(lines);
  if (fence != null) return _healFence(tail, lines, fence);

  var edited = false;
  for (var round = 0; round < 3; round++) {
    var changed = false;
    for (var guard = 0; guard < 8; guard++) {
      final i = _lastContent(lines);
      if (i < 0 || lines.length - 1 - i > 1) break;
      final drop = _holdFrom(lines, i);
      if (drop < 0) break;
      lines.removeRange(drop, lines.length);
      changed = true;
    }
    final i = _lastContent(lines);
    if (i >= 0 && lines.length - 1 - i <= 1 && _healParagraph(lines, i)) {
      changed = true;
    }
    if (!changed) break;
    edited = true;
  }
  if (!edited) return tail;
  var out = lines.join('\n');
  var end = out.length;
  while (end > 0 && out.codeUnitAt(end - 1) == 0x0a) {
    end--;
  }
  out = out.substring(0, end);
  return out;
}

// -- line level ---------------------------------------------------------------

int _lastContent(List<String> lines) {
  for (var i = lines.length - 1; i >= 0; i--) {
    if (!MdChunker.isBlank(lines[i])) return i;
  }
  return -1;
}

({int char, int len})? _openFenceAtEnd(List<String> lines) {
  ({int char, int len})? open;
  for (final line in lines) {
    final s = MdChunker.stripContainers(line);
    if (open == null) {
      open = MdChunker.fenceOpener(s);
    } else {
      var n = 0;
      while (n < s.length && s.codeUnitAt(n) == open.char) {
        n++;
      }
      if (n >= open.len && s.substring(n).trim().isEmpty) open = null;
    }
  }
  return open;
}

String _healFence(String tail, List<String> lines, ({int char, int len}) fence) {
  final last = lines.last;
  final s = MdChunker.stripContainers(last);
  if (s.isEmpty || s.length >= fence.len) return tail;
  for (var k = 0; k < s.length; k++) {
    if (s.codeUnitAt(k) != fence.char) return tail;
  }
  // A shorter run of the fence character: the closing fence is arriving.
  return lines.sublist(0, lines.length - 1).join('\n');
}

final RegExp _markerOnly = RegExp(
  r'^[ \t]*(?:>[ \t]*)*(?:(?:#{1,6}|[-+*]|\d{1,9}[.)]|\||`{1,2}|~{1,2}|={1,2}|--?)[ \t]*|[-+*][ \t]+\[[ xX]?\]?[ \t]*)?$',
);
final RegExp _setextUnderline = RegExp(r'^ {0,3}(?:=+|-+)[ \t]*$');
final RegExp _thematicLine = RegExp(r'^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$');
final RegExp _heading = RegExp(r'^ {0,3}#{1,6}(?:[ \t]|$)');
final RegExp _delimiterCell = RegExp(r'^:?-+:?$');

/// Index of the first line to drop so the last block is held back, or -1.
int _holdFrom(List<String> lines, int i) {
  final line = lines[i];
  if (_markerOnly.hasMatch(line)) return i;
  if (_setextUnderline.hasMatch(line) && i > 0 && _isParagraphText(lines[i - 1])) {
    return i;
  }
  if (!_pipeRow(line)) return -1;
  // A table needs a header row AND a complete delimiter row before it shows.
  if (i == 0 || !_pipeRow(lines[i - 1])) return i;
  if (i >= 2 && _pipeRow(lines[i - 2])) return -1;
  if (!_delimiterLike(line)) return -1;
  final closed = lines.length - 1 > i;
  return _delimiterComplete(lines[i - 1], line, closed: closed) ? -1 : i - 1;
}

bool _pipeRow(String line) {
  var k = 0;
  while (k < line.length && k < 4 && line.codeUnitAt(k) == 0x20) {
    k++;
  }
  return k < 4 && k < line.length && line.codeUnitAt(k) == 0x7c;
}

bool _delimiterLike(String line) {
  for (var k = 0; k < line.length; k++) {
    final c = line.codeUnitAt(k);
    if (c != 0x7c && c != 0x3a && c != 0x2d && c != 0x20 && c != 0x09) return false;
  }
  return true;
}

List<String> _cells(String row) {
  var t = row.trim();
  if (t.startsWith('|')) t = t.substring(1);
  if (t.endsWith('|') && !t.endsWith(r'\|')) t = t.substring(0, t.length - 1);
  return t.split('|');
}

bool _delimiterComplete(String header, String delim, {required bool closed}) {
  if (!closed && !delim.trimRight().endsWith('|')) return false;
  final d = _cells(delim);
  if (d.length != _cells(header).length) return false;
  return d.every((c) => _delimiterCell.hasMatch(c.trim()));
}

/// Plain text that a setext underline could still turn into a heading.
bool _isParagraphText(String line) {
  if (MdChunker.isBlank(line) || MdChunker.indentOf(line) >= 4) return false;
  final s = line.trimLeft();
  if (s.startsWith('>') || s.startsWith('|') || _heading.hasMatch(line)) return false;
  if (MdChunker.isListMarker(s) || _thematicLine.hasMatch(line)) return false;
  if (MdChunker.fenceOpener(s) != null) return false;
  return true;
}

// -- inline level -------------------------------------------------------------

/// Line [i] starts a block (so the paragraph's region begins there).
bool _startsBlock(List<String> lines, int i) {
  final line = lines[i];
  final s = line.trimLeft();
  if (MdChunker.indentOf(line) >= 4) return false;
  if (s.startsWith('>')) return i == 0 || !lines[i - 1].trimLeft().startsWith('>');
  return _heading.hasMatch(line) ||
      MdChunker.isListMarker(s) ||
      _thematicLine.hasMatch(line) ||
      _pipeRow(line) ||
      MdChunker.fenceOpener(s) != null;
}

final RegExp _blockPrefix = RegExp(r'^(?:[ \t]*>)*[ \t]*(?:#{1,6}[ \t]+|(?:[-+*]|\d{1,9}[.)])[ \t]+)?');

/// Whether [line] is a block of one line (heading, rule, code fence), so the
/// line after it cannot continue it.
bool _isLeafLine(String line) {
  final s = line.trimLeft();
  return _heading.hasMatch(line) || _thematicLine.hasMatch(line) || MdChunker.fenceOpener(s) != null;
}

/// Heals the paragraph that ends at line [i] in place; whether it changed.
bool _healParagraph(List<String> lines, int i) {
  var s = i;
  while (s > 0 &&
      !MdChunker.isBlank(lines[s - 1]) &&
      !_startsBlock(lines, s) &&
      !_isLeafLine(lines[s - 1])) {
    s--;
  }
  final first = lines[s];
  if (MdChunker.indentOf(first) >= 4 &&
      !MdChunker.isListMarker(first.trimLeft()) &&
      (s == 0 || MdChunker.isBlank(lines[s - 1]))) {
    return false; // indented code
  }
  // A rule (`***`) or a code fence line is not text with markers in it.
  if (_thematicLine.hasMatch(first) || MdChunker.fenceOpener(first.trimLeft()) != null) {
    return false;
  }

  // The region's text with block prefixes removed, and where each line began.
  final b = StringBuffer();
  final starts = <int>[]; // offset in region of line s+k
  final prefixes = <int>[]; // prefix chars removed from line s+k
  for (var k = s; k <= i; k++) {
    final line = lines[k];
    final String rest;
    final int cut;
    if (k == s) {
      cut = _blockPrefix.matchAsPrefix(line)!.end;
      rest = line.substring(cut);
    } else {
      var c = 0;
      if (line.trimLeft().startsWith('>')) {
        while (c < line.length &&
            (line.codeUnitAt(c) == 0x20 || line.codeUnitAt(c) == 0x3e)) {
          c++;
        }
      }
      cut = c;
      rest = line.substring(c);
    }
    if (k > s) b.writeCharCode(0x0a);
    starts.add(b.length);
    prefixes.add(cut);
    b.write(rest);
  }
  final region = b.toString();
  final heal = _scanInline(region);
  if (heal == null) return false;

  // Truncate at heal.cut, then add heal.link, the code span closer and the
  // emphasis closers.
  var k = starts.length - 1;
  while (k > 0 && starts[k] > heal.cut) {
    k--;
  }
  final col = prefixes[k] + (heal.cut - starts[k]);
  var text = lines[s + k].substring(0, col) + heal.link;
  var trailing = '';
  if (heal.codeClose.isNotEmpty) {
    // Inside a code span the trailing space is content: the closer goes after
    // it (the scan already added a space where the content ends in a backtick).
    text = text + heal.codeClose;
  } else if (heal.closers.isNotEmpty) {
    final trimmed = text.trimRight();
    trailing = text.substring(trimmed.length);
    text = trimmed;
  }
  lines
    ..removeRange(s + k + 1, lines.length)
    ..[s + k] = text + heal.closers + trailing;
  return true;
}

final class _Heal {
  const _Heal(this.cut, this.link, this.codeClose, this.closers);
  final int cut;
  final String link;
  final String codeClose;
  final String closers;
}

final class _Run {
  _Run(this.ch, this.pos, this.len, this.canOpen, this.canClose) : rem = len;
  final int ch;
  final int pos;
  final int len;
  final bool canOpen;
  final bool canClose;
  int rem;
}

bool _isWs(int c) =>
    c == 0x20 || (c >= 0x09 && c <= 0x0d) || c == 0xa0 || c == 0x3000 ||
    (c >= 0x2000 && c <= 0x200a) || c == 0x202f || c == 0x205f;

bool _isPunct(int c) =>
    (c >= 0x21 && c <= 0x2f) || (c >= 0x3a && c <= 0x40) || (c >= 0x5b && c <= 0x60) ||
    (c >= 0x7b && c <= 0x7e) || (c >= 0x2010 && c <= 0x2027) || (c >= 0x2030 && c <= 0x205e) ||
    (c >= 0x3001 && c <= 0x3003) || (c >= 0x3008 && c <= 0x3011) || c == 0xa1 || c == 0xa7 ||
    c == 0xab || c == 0xbb || c == 0xbf;

final RegExp _autolink = RegExp(r'<(?:[A-Za-z][A-Za-z0-9+.\-]*:[^\s<>]*|[^\s<>@]+@[^\s<>]+)>');
final RegExp _htmlTag = RegExp(r'</?[A-Za-z][^<>]*>');

/// What to do to [r] (a paragraph's text, block prefixes removed), or null.
_Heal? _scanInline(String r) {
  final n = r.length;
  final runs = <_Run>[];
  final brackets = <({int pos, bool image})>[];
  var cut = n;
  var link = '';
  var codeClose = '';
  var trailingTilde = false;
  var i = 0;

  while (i < n) {
    final c = r.codeUnitAt(i);
    if (c == 0x5c) {
      i += 2;
    } else if (c == 0x60) {
      var j = i;
      while (j < n && r.codeUnitAt(j) == 0x60) {
        j++;
      }
      final k = j - i;
      var close = -1;
      var from = j;
      while (true) {
        final at = r.indexOf('`', from);
        if (at < 0) break;
        var e = at;
        while (e < n && r.codeUnitAt(e) == 0x60) {
          e++;
        }
        if (e - at == k) {
          close = e;
          break;
        }
        from = e;
      }
      if (close >= 0) {
        i = close;
      } else {
        if (r.substring(j).trim().isEmpty) {
          cut = i; // a lone backtick run: hold it back
        } else {
          // A shorter run of backticks at the very end is either the closer
          // arriving (the other backticks inside pair up) or an inner span
          // that is complete (then the closer needs a space before it).
          var trail = 0;
          while (trail < n - j && r.codeUnitAt(n - 1 - trail) == 0x60) {
            trail++;
          }
          var ticks = 0;
          for (var q = j; q < n; q++) {
            if (r.codeUnitAt(q) == 0x60) ticks++;
          }
          final partial = trail > 0 && trail < k && (ticks - trail).isEven;
          codeClose = '${trail > 0 && !partial ? ' ' : ''}${'`' * (partial ? k - trail : k)}';
        }
        break;
      }
    } else if (c == 0x3c) {
      final m = _autolink.matchAsPrefix(r, i) ?? _htmlTag.matchAsPrefix(r, i);
      if (m != null) {
        i = m.end;
      } else if (i + 1 < n && _startsTag(r.codeUnitAt(i + 1)) && !_hasWsOrGt(r, i)) {
        cut = i;
        break;
      } else {
        i++;
      }
    } else if (c == 0x5b) {
      brackets.add((pos: i, image: false));
      i++;
    } else if (c == 0x21 && i + 1 < n && r.codeUnitAt(i + 1) == 0x5b) {
      brackets.add((pos: i, image: true));
      i += 2;
    } else if (c == 0x5d) {
      if (brackets.isEmpty) {
        i++;
        continue;
      }
      final open = brackets.removeLast();
      if (i + 1 < n && r.codeUnitAt(i + 1) == 0x28) {
        final end = _parenEnd(r, i + 2);
        if (end >= 0) {
          i = end + 1;
          continue;
        }
        if (end == -1) {
          if (open.image) {
            cut = open.pos;
          } else {
            cut = i + 1;
            link = '()';
          }
          break;
        }
      } else if (i + 1 == n && open.image) {
        cut = open.pos;
        break;
      }
      i++;
    } else if (c == 0x2a || c == 0x5f || c == 0x7e) {
      var j = i;
      while (j < n && r.codeUnitAt(j) == c) {
        j++;
      }
      final len = j - i;
      if (c != 0x7e || len == 2) {
        final prev = i == 0 ? 0x20 : r.codeUnitAt(i - 1);
        final next = j >= n ? 0x20 : r.codeUnitAt(j);
        final left = !_isWs(next) && (!_isPunct(next) || _isWs(prev) || _isPunct(prev));
        final right = !_isWs(prev) && (!_isPunct(prev) || _isWs(next) || _isPunct(next));
        final open = c == 0x5f ? left && (!right || _isPunct(prev)) : left;
        final close = c == 0x5f ? right && (!left || _isPunct(next)) : right;
        runs.add(_Run(c, i, len, open, close));
      } else if (len == 1 && j == n && i > 0 && !_isWs(r.codeUnitAt(i - 1))) {
        trailingTilde = true;
      }
      i = j;
    } else {
      i++;
    }
  }

  // `![alt` with no `]` yet: an image that cannot be shown.
  if (cut == n) {
    for (final b in brackets) {
      if (b.image) {
        cut = b.pos;
        break;
      }
    }
  }
  if (cut == n && runs.isNotEmpty) {
    final last = runs.last;
    if (last.pos + last.len == n && !last.canOpen && !last.canClose) cut = last.pos;
  }
  while (runs.isNotEmpty && runs.last.pos >= cut) {
    runs.removeLast();
  }

  final closers = StringBuffer();
  final stack = <_Run>[];
  for (final run in runs) {
    var rem = run.len;
    if (run.canClose) {
      while (rem > 0) {
        var k = stack.length - 1;
        for (; k >= 0; k--) {
          final o = stack[k];
          if (o.ch == run.ch && !_oddMatch(o, run)) break;
        }
        if (k < 0) break;
        final o = stack[k];
        final use = run.ch == 0x7e ? 2 : (o.rem >= 2 && rem >= 2 ? 2 : 1);
        o.rem -= use;
        rem -= use;
        stack.removeRange(k + 1, stack.length);
        if (o.rem == 0) stack.removeAt(k);
      }
    }
    if (rem > 0 && run.canOpen) {
      run.rem = rem;
      stack.add(run);
    }
  }
  for (var k = stack.length - 1; k >= 0; k--) {
    final ch = String.fromCharCode(stack[k].ch);
    // `~~gone~`: the closing `~~` is arriving, one `~` is already there.
    final have = trailingTilde && k == stack.length - 1 && stack[k].ch == 0x7e ? 1 : 0;
    closers.write(ch * (stack[k].rem - have));
  }

  if (cut == n && link.isEmpty && closers.isEmpty && codeClose.isEmpty) return null;
  return _Heal(cut, link, codeClose, closers.toString());
}

/// CommonMark's "multiple of 3" rule.
bool _oddMatch(_Run opener, _Run closer) =>
    (opener.canClose || closer.canOpen) &&
    (opener.len + closer.len) % 3 == 0 &&
    !(opener.len % 3 == 0 && closer.len % 3 == 0);

bool _startsTag(int c) =>
    (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x2f || c == 0x21 || c == 0x3f;

bool _hasWsOrGt(String r, int from) {
  for (var k = from; k < r.length; k++) {
    final c = r.codeUnitAt(k);
    if (_isWs(c) || c == 0x3e) return true;
  }
  return false;
}

/// Index of the `)` closing a link destination that starts at [from]; -1 when
/// the text ends first (still arriving), -2 when a newline ends it (not a link).
int _parenEnd(String r, int from) {
  var depth = 1;
  for (var k = from; k < r.length; k++) {
    final c = r.codeUnitAt(k);
    if (c == 0x5c) {
      k++;
    } else if (c == 0x28) {
      depth++;
    } else if (c == 0x29) {
      if (--depth == 0) return k;
    } else if (c == 0x0a) {
      return -2;
    }
  }
  return -1;
}
