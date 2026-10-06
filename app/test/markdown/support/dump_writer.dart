/// The canonical structure dump the corpus expectations are written in, and the
/// helpers every engine converter (the bench's A, B, C and our own
/// `MdDocument`) uses to print it, so one string comparison scores them all.
///
/// Pure Dart, no imports: the bench AOT-compiles it.
library;

/// Style letters in a dump, in this order: bold, italic, strike, code.
const int dumpBold = 1;
const int dumpItalic = 2;
const int dumpStrike = 4;
const int dumpCode = 8;

/// Not in our model: only engines that render `__x__` as underline use it, so
/// a dump shows the difference.
const int dumpUnderline = 16;

sealed class DInline {
  const DInline();
}

/// A run of text with one style set and an optional link target.
final class DRun extends DInline {
  const DRun(this.text, {this.flags = 0, this.link});
  final String text;
  final int flags;
  final String? link;
}

/// A hard line break.
final class DBreak extends DInline {
  const DBreak();
}

final class DImage extends DInline {
  const DImage(this.src, this.alt);
  final String src;
  final String alt;
}

/// `"text"` with `\\ \" \n \t` escaped, and control, no-break-space and bidi
/// characters as `\uXXXX`, so a dump shows what a renderer would otherwise hide.
String dumpQuote(String s) {
  final b = StringBuffer('"');
  for (final u in s.codeUnits) {
    switch (u) {
      case 0x5c:
        b.write(r'\\');
      case 0x22:
        b.write(r'\"');
      case 0x0a:
        b.write(r'\n');
      case 0x09:
        b.write(r'\t');
      default:
        if (u < 0x20 ||
            u == 0x7f ||
            u == 0xa0 ||
            u == 0x061c ||
            u == 0x200e ||
            u == 0x200f ||
            (u >= 0x2028 && u <= 0x202e) ||
            (u >= 0x2066 && u <= 0x2069) ||
            u == 0xfeff) {
          b.write('\\u${u.toRadixString(16).padLeft(4, '0')}');
        } else {
          b.writeCharCode(u);
        }
    }
  }
  b.write('"');
  return b.toString();
}

/// One line of inline dump: runs with equal style and link merge, empty runs
/// vanish; `a(url)` then the style letters then the quoted text.
String dumpInlines(Iterable<DInline> inlines) {
  final out = <String>[];
  DRun? pending;
  void flush() {
    final r = pending;
    if (r == null) return;
    pending = null;
    if (r.text.isEmpty) return;
    final b = StringBuffer();
    if (r.link != null) b.write('a(${r.link})');
    if (r.flags & dumpBold != 0) b.write('b');
    if (r.flags & dumpItalic != 0) b.write('i');
    if (r.flags & dumpStrike != 0) b.write('s');
    if (r.flags & dumpCode != 0) b.write('c');
    if (r.flags & dumpUnderline != 0) b.write('u');
    b.write(dumpQuote(r.text));
    out.add(b.toString());
  }

  for (final i in inlines) {
    switch (i) {
      case DRun():
        final p = pending;
        if (p != null && p.flags == i.flags && p.link == i.link) {
          pending = DRun(p.text + i.text, flags: p.flags, link: p.link);
        } else {
          flush();
          pending = i;
        }
      case DBreak():
        flush();
        out.add('br');
      case DImage():
        flush();
        out.add('img(${i.src})${dumpQuote(i.alt)}');
    }
  }
  flush();
  return out.join(' ');
}

/// Accumulates dump lines, two spaces of indent per depth.
final class DumpOut {
  final List<String> _lines = <String>[];

  /// `head` plus the inline dump (no trailing space when there is none).
  void add(int depth, String head, [String rest = '']) {
    _lines.add('${'  ' * depth}$head${rest.isEmpty ? '' : ' $rest'}');
  }

  @override
  String toString() => _lines.join('\n');
}

/// A table row: cells joined with ` | `, an empty cell as `""`.
String dumpCells(Iterable<Iterable<DInline>> cells) => cells.map((c) {
      final d = dumpInlines(c);
      return d.isEmpty ? '""' : d;
    }).join(' | ');
