/// A small Markdown reader: headings, paragraphs, fenced code, block quotes,
/// lists, rules and pipe tables (kept as preformatted text), with bold,
/// italic, inline code and links inside text. It is for reading a README on a
/// phone, not for full CommonMark.
sealed class MdBlock {
  const MdBlock();
}

class MdHeading extends MdBlock {
  const MdHeading(this.level, this.text);
  final int level;
  final String text;
}

class MdParagraph extends MdBlock {
  const MdParagraph(this.text);
  final String text;
}

/// Fenced code, or a pipe table (shown as written so its columns line up).
class MdCode extends MdBlock {
  const MdCode(this.code, {this.language = ''});
  final String code;
  final String language;
}

class MdQuote extends MdBlock {
  const MdQuote(this.text);
  final String text;
}

class MdListItem extends MdBlock {
  const MdListItem({required this.depth, required this.marker, required this.text});

  /// 0 for top-level items; two spaces of indent per level.
  final int depth;

  /// `•`, or `1.` for ordered items.
  final String marker;
  final String text;
}

class MdRule extends MdBlock {
  const MdRule();
}

final _heading = RegExp(r'^(#{1,6})\s+(.*?)\s*#*\s*$');
final _fence = RegExp(r'^\s*(```|~~~)\s*([\w+-]*)');
final _bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$');
final _ordered = RegExp(r'^(\s*)(\d{1,9})[.)]\s+(.*)$');
final _rule = RegExp(r'^\s{0,3}([-*_])(\s*\1){2,}\s*$');
final _quote = RegExp(r'^\s{0,3}>\s?(.*)$');

List<MdBlock> parseMarkdown(String source) {
  final lines = source.split('\n');
  final out = <MdBlock>[];
  final paragraph = <String>[];

  void flush() {
    if (paragraph.isEmpty) return;
    out.add(MdParagraph(paragraph.join(' ')));
    paragraph.clear();
  }

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final fence = _fence.firstMatch(line);
    if (fence != null) {
      flush();
      final marker = fence.group(1)!;
      final body = <String>[];
      i++;
      while (i < lines.length && !lines[i].trimLeft().startsWith(marker)) {
        body.add(lines[i]);
        i++;
      }
      i++; // closing fence (or end of file)
      out.add(MdCode(body.join('\n'), language: fence.group(2) ?? ''));
      continue;
    }
    if (line.trim().isEmpty) {
      flush();
      i++;
      continue;
    }
    final h = _heading.firstMatch(line);
    if (h != null) {
      flush();
      out.add(MdHeading(h.group(1)!.length, h.group(2)!));
      i++;
      continue;
    }
    if (_rule.hasMatch(line)) {
      flush();
      out.add(const MdRule());
      i++;
      continue;
    }
    if (line.trimLeft().startsWith('|')) {
      flush();
      final table = <String>[];
      while (i < lines.length && lines[i].trimLeft().startsWith('|')) {
        table.add(lines[i].trimRight());
        i++;
      }
      out.add(MdCode(table.join('\n')));
      continue;
    }
    final q = _quote.firstMatch(line);
    if (q != null) {
      flush();
      final body = <String>[q.group(1)!];
      i++;
      while (i < lines.length && _quote.hasMatch(lines[i])) {
        body.add(_quote.firstMatch(lines[i])!.group(1)!);
        i++;
      }
      out.add(MdQuote(body.join(' ').trim()));
      continue;
    }
    final b = _bullet.firstMatch(line);
    final o = b == null ? _ordered.firstMatch(line) : null;
    if (b != null || o != null) {
      flush();
      final indent = (b?.group(1) ?? o!.group(1)!).replaceAll('\t', '  ').length;
      out.add(MdListItem(
        depth: (indent ~/ 2).clamp(0, 4),
        marker: b != null ? '•' : '${o!.group(2)}.',
        text: b?.group(2) ?? o!.group(3)!,
      ));
      i++;
      continue;
    }
    paragraph.add(line.trim());
    i++;
  }
  flush();
  return out;
}

/// A run of inline text with one style.
class MdSpan {
  const MdSpan(this.text, {this.bold = false, this.italic = false, this.code = false, this.url});
  final String text;
  final bool bold;
  final bool italic;
  final bool code;

  /// Link target, for a link's text.
  final String? url;
}

final _inline = RegExp(
  r'`([^`]+)`' // 1 code
  r'|\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)' // 2 label, 3 url
  r'|\*\*([^*]+)\*\*|__([^_]+)__' // 4, 5 bold
  r'|(?<![\w*])\*([^*\s][^*]*)\*(?!\w)|(?<![\w_])_([^_\s][^_]*)_(?![\w_])' // 6, 7 italic
  r'|(https?://[^\s<>)\]]+)', // 8 bare link
);

List<MdSpan> parseInline(String text) {
  final spans = <MdSpan>[];
  var at = 0;
  for (final m in _inline.allMatches(text)) {
    if (m.start > at) spans.add(MdSpan(text.substring(at, m.start)));
    if (m.group(1) != null) {
      spans.add(MdSpan(m.group(1)!, code: true));
    } else if (m.group(2) != null) {
      // `![alt](src)`: a picture cannot be shown here; keep its description.
      final isImage = m.start > 0 && text[m.start - 1] == '!';
      if (isImage && spans.isNotEmpty && spans.last.text.endsWith('!')) {
        final last = spans.removeLast();
        final rest = last.text.substring(0, last.text.length - 1);
        if (rest.isNotEmpty) spans.add(MdSpan(rest));
        spans.add(MdSpan('[image: ${m.group(2)}]', italic: true));
      } else {
        spans.add(MdSpan(m.group(2)!, url: m.group(3)));
      }
    } else if (m.group(4) != null || m.group(5) != null) {
      spans.add(MdSpan(m.group(4) ?? m.group(5)!, bold: true));
    } else if (m.group(6) != null || m.group(7) != null) {
      spans.add(MdSpan(m.group(6) ?? m.group(7)!, italic: true));
    } else {
      var url = m.group(8)!;
      // Sentence punctuation after a bare link is not part of it.
      final trailing = RegExp(r'[.,;:!?]+$').firstMatch(url);
      var tail = '';
      if (trailing != null) {
        tail = trailing.group(0)!;
        url = url.substring(0, url.length - tail.length);
      }
      spans.add(MdSpan(url, url: url));
      if (tail.isNotEmpty) spans.add(MdSpan(tail));
    }
    at = m.end;
  }
  if (at < text.length) spans.add(MdSpan(text.substring(at)));
  return spans;
}
