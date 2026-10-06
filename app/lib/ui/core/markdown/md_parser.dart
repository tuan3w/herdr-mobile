/// The adapter over the chosen engine, `package:markdown` 7.x (the bench-off in
/// tool/md-bench picked it for correctness; its speed is paid by parsing each
/// chunk once, see `md_chunker.dart` and `md_stream.dart`).
///
/// This is the ONLY file that imports the engine. It maps the engine's AST to
/// the immutable model of `md_document.dart` and owns every repair of the
/// engine's gaps, in the layers where each belongs:
///
///  * syntax set: GFM tables, task lists, autolinks and alerts without
///    footnotes; strikethrough only for `~~` (GFM also takes a single `~`, which
///    turns `20~25 min or 30~35` into struck text); `<br>` is a hard break;
///    entities are decoded by the engine; other HTML stays text;
///  * mapping: raw HTML blocks become paragraphs of their source text, tight
///    list items get a paragraph, the task checkbox becomes `MdListItem.checked`,
///    images become [MdImage], adjacent runs of one style merge;
///  * soft line breaks: `'\n'` in the run text (chat default) or `' '`
///    (CommonMark, the file viewer);
///  * chunks: a message is parsed chunk by chunk (`md_chunker.dart`), so the
///    result of [parseMd] is exactly what `StreamingMd` freezes.
///
/// Not supported, by design: link reference definitions across chunks (a
/// `[1]: url` line alone is shown as text), footnotes, math, raw HTML.
library;

import 'package:markdown/markdown.dart' as md;

import 'md_chunker.dart';
import 'md_document.dart';

/// Parses a whole message.
///
/// [softBreaksAsNewlines]: a single newline inside a paragraph is a line break
/// (what agents mean by `Label: value` lines; the chat default) rather than a
/// space (CommonMark; the file viewer).
MdDocument parseMd(String source, {bool softBreaksAsNewlines = true}) {
  final text = normalizeNewlines(source);
  final chunker = MdChunker();
  var at = 0;
  while (true) {
    final nl = text.indexOf('\n', at);
    if (nl < 0) break;
    chunker.addLine(text.substring(at, nl));
    at = nl + 1;
  }
  final blocks = <MdBlock>[];
  for (final c in chunker.closed) {
    blocks.addAll(parseMdChunk(chunker.source(c.start, c.end), softBreaksAsNewlines: softBreaksAsNewlines));
  }
  final tail = chunker.tailSource(text.substring(at));
  if (tail.isNotEmpty) {
    blocks.addAll(parseMdChunk(tail, softBreaksAsNewlines: softBreaksAsNewlines));
  }
  return MdDocument(blocks);
}

/// One engine call over the whole text, no chunking: the reference the tests
/// compare [parseMd] with. Not exported by `markdown.dart`; the app has no use
/// for it (it cannot be frozen).
MdDocument parseMdUnchunked(String source, {bool softBreaksAsNewlines = true}) =>
    MdDocument(parseMdChunk(normalizeNewlines(source), softBreaksAsNewlines: softBreaksAsNewlines));

/// `\r\n` and lone `\r` to `\n`.
String normalizeNewlines(String s) =>
    s.contains('\r') ? s.replaceAll('\r\n', '\n').replaceAll('\r', '\n') : s;

/// Parses one chunk (see `MdChunker`) into blocks. Internal: used by
/// [parseMd] and `StreamingMd`, not exported by `markdown.dart`.
///
/// Trailing blank lines are cut first: the tail of a stream carries the blank
/// lines a list swallowed, and the engine reads a trailing blank line after an
/// empty item as "loose".
List<MdBlock> parseMdChunk(String chunk, {required bool softBreaksAsNewlines}) {
  var end = chunk.length;
  while (true) {
    final nl = end == 0 ? -1 : chunk.lastIndexOf('\n', end - 1);
    if (!_isBlank(chunk, nl + 1, end)) break;
    if (nl < 0) return const <MdBlock>[];
    end = nl;
  }
  if (end < chunk.length) chunk = chunk.substring(0, end);
  final List<MdBlock> blocks;
  try {
    final doc = md.Document(extensionSet: _extensions, encodeHtml: false);
    blocks = _Mapper(softBreaksAsNewlines).blocks(doc.parseLines(chunk.split('\n')));
    // ignore: avoid_catching_errors
  } on Error {
    // The engine throws an AssertionError when its block parser stops
    // advancing on a pathological input (seen on random input; it is thrown in
    // release builds too). Show the text rather than lose it.
    return [MdParagraph(MdInlines([MdSpan(chunk)]))];
  }
  if (blocks.isEmpty) {
    // Only link reference definitions: keep what was written.
    return [MdParagraph(MdInlines([MdSpan(chunk.trim())]))];
  }
  return blocks;
}

/// Whether `s[from, to)` is only spaces and tabs.
bool _isBlank(String s, int from, int to) {
  for (var i = from; i < to; i++) {
    final c = s.codeUnitAt(i);
    if (c != 0x20 && c != 0x09) return false;
  }
  return true;
}

final md.ExtensionSet _extensions = md.ExtensionSet(
  <md.BlockSyntax>[
    const md.FencedCodeBlockSyntax(),
    const md.TableSyntax(),
    const md.UnorderedListWithCheckboxSyntax(),
    const md.OrderedListWithCheckboxSyntax(),
    const md.AlertBlockSyntax(),
  ],
  <md.InlineSyntax>[
    _HtmlBreakSyntax(),
    _StrikeSyntax(),
    md.AutolinkExtensionSyntax(),
  ],
);

/// `<br>`, `<br/>`, `<br />` (any case) is a hard break.
class _HtmlBreakSyntax extends md.InlineSyntax {
  _HtmlBreakSyntax() : super(r'<br\s*/?>', startCharacter: 0x3c, caseSensitive: false);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.empty('br'));
    return true;
  }
}

/// `~~x~~` only. GFM also accepts `~x~`, which agents never mean (`20~25`).
class _StrikeSyntax extends md.DelimiterSyntax {
  _StrikeSyntax()
      : super(
          '~+',
          requiresDelimiterRun: true,
          allowIntraWord: true,
          startCharacter: 0x7e,
          tags: [md.DelimiterTag('del', 2)],
        );
}

const _blockTags = {
  'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'pre', 'blockquote', 'ul', 'ol', 'hr', 'table', 'div', //
};

class _Mapper {
  _Mapper(this.soft);

  final bool soft;

  /// Engine nodes at block level to blocks. In a tight list item
  /// ([inlineText]) loose runs of inline nodes form one paragraph; anywhere
  /// else text at block level is a raw HTML block and stays text.
  List<MdBlock> blocks(List<md.Node> nodes, {bool inlineText = false}) {
    final out = <MdBlock>[];
    var run = <md.Node>[];
    void flush() {
      if (run.isEmpty) return;
      final inl = _inlines(run);
      if (!inl.isEmpty) out.add(MdParagraph(inl));
      run = [];
    }

    for (final n in nodes) {
      if (n is md.Element && _blockTags.contains(n.tag)) {
        flush();
        final b = _block(n);
        if (b != null) out.add(b);
      } else if (n is md.Text && !inlineText) {
        final t = n.text.trim();
        if (t.isNotEmpty) out.add(MdParagraph(MdInlines([MdSpan(t)])));
      } else {
        run.add(n);
      }
    }
    flush();
    return out;
  }

  MdBlock? _block(md.Element e) {
    final kids = e.children ?? const <md.Node>[];
    switch (e.tag) {
      case 'p':
        return MdParagraph(_inlines(kids));
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        return MdHeading(int.parse(e.tag.substring(1)), _inlines(kids));
      case 'hr':
        return const MdRule();
      case 'pre':
        return _code(e);
      case 'blockquote':
        return MdQuote(blocks(kids));
      case 'div':
        final m = RegExp(r'markdown-alert-(\w+)$').firstMatch(e.attributes['class'] ?? '');
        final kind = m == null ? null : _alertKind(m.group(1)!);
        if (kind == null) return MdQuote(blocks(kids));
        return MdAlert(kind, blocks(kids.skip(1).toList()));
      case 'ul' || 'ol':
        return _list(e);
      case 'table':
        return _table(e);
    }
    return null;
  }

  MdAlertKind? _alertKind(String s) => switch (s) {
        'note' => MdAlertKind.note,
        'tip' => MdAlertKind.tip,
        'important' => MdAlertKind.important,
        'warning' => MdAlertKind.warning,
        'caution' => MdAlertKind.caution,
        _ => null,
      };

  MdCode _code(md.Element pre) {
    final kids = pre.children ?? const <md.Node>[];
    final code = kids.isNotEmpty && kids.first is md.Element ? kids.first as md.Element : null;
    final cls = code?.attributes['class'] ?? '';
    final lang = cls.startsWith('language-') ? cls.substring(9) : '';
    var text = _rawText(pre);
    if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
    return MdCode(language: lang, text: text);
  }

  MdList _list(md.Element e) {
    final items = <MdListItem>[];
    var loose = false;
    for (final li in (e.children ?? const <md.Node>[]).whereType<md.Element>()) {
      var kids = li.children ?? const <md.Node>[];
      if (kids.any((c) => c is md.Element && c.tag == 'p')) loose = true;
      bool? checked;
      if (kids.isNotEmpty) {
        final first = kids.first;
        if (first is md.Element && first.tag == 'input') {
          checked = first.attributes.containsKey('checked');
          kids = kids.skip(1).toList();
        } else if (first is md.Element &&
            first.tag == 'p' &&
            (first.children?.isNotEmpty ?? false) &&
            first.children!.first is md.Element &&
            (first.children!.first as md.Element).tag == 'input') {
          final input = first.children!.first as md.Element;
          checked = input.attributes.containsKey('checked');
          kids = [md.Element('p', first.children!.skip(1).toList()), ...kids.skip(1)];
        }
      }
      items.add(MdListItem(blocks: blocks(kids, inlineText: true), checked: checked));
    }
    final start = e.tag == 'ol' ? int.tryParse(e.attributes['start'] ?? '') ?? 1 : 1;
    return MdList(ordered: e.tag == 'ol', start: start, tight: !loose, items: items);
  }

  MdTable _table(md.Element e) {
    final head = <MdInlines>[];
    final aligns = <MdAlign>[];
    final body = <List<MdInlines>>[];
    for (final section in (e.children ?? const <md.Node>[]).whereType<md.Element>()) {
      for (final tr in (section.children ?? const <md.Node>[]).whereType<md.Element>()) {
        final cells = (tr.children ?? const <md.Node>[]).whereType<md.Element>().toList();
        final row = [for (final c in cells) _inlines(c.children ?? const <md.Node>[])];
        if (section.tag == 'thead') {
          head.addAll(row);
          aligns.addAll(cells.map(_align));
        } else {
          body.add(row);
        }
      }
    }

    return MdTable(
      aligns: aligns,
      header: head,
      rows: [
        for (final r in body)
          [
            for (var i = 0; i < aligns.length; i++) i < r.length ? r[i] : MdInlines.empty,
          ],
      ],
    );
  }

  MdAlign _align(md.Element cell) {
    final style = cell.attributes['style'] ?? cell.attributes['align'] ?? '';
    if (style.contains('left')) return MdAlign.left;
    if (style.contains('center')) return MdAlign.center;
    if (style.contains('right')) return MdAlign.right;
    return MdAlign.none;
  }

  String _rawText(md.Node n) {
    if (n is md.Text) return n.text;
    final kids = (n as md.Element).children;
    if (kids == null) return '';
    if (kids.length == 1) return _rawText(kids.first);
    final b = StringBuffer();
    for (final c in kids) {
      b.write(_rawText(c));
    }
    return b.toString();
  }

  MdInlines _inlines(Iterable<md.Node> nodes) {
    final out = <MdInline>[];
    for (final n in nodes) {
      _inline(n, MdStyle.none, null, out);
    }
    return MdInlines(out);
  }

  void _inline(md.Node n, MdStyle style, String? link, List<MdInline> out) {
    if (n is md.Text) {
      var t = n.text;
      if (!soft && !style.has(MdStyle.code) && t.contains('\n')) {
        t = t.replaceAll('\n', ' ');
      }
      _addText(out, t, style, link);
      return;
    }
    final e = n as md.Element;
    switch (e.tag) {
      case 'br':
        out.add(const MdBreak());
      case 'img':
        out.add(MdImage(alt: e.attributes['alt'] ?? '', src: e.attributes['src'] ?? ''));
      case 'input':
        break;
      default:
        final s = switch (e.tag) {
          'strong' => style | MdStyle.bold,
          'em' => style | MdStyle.italic,
          'del' => style | MdStyle.strike,
          'code' => style | MdStyle.code,
          _ => style,
        };
        final l = e.tag == 'a' ? (e.attributes['href'] ?? '') : link;
        for (final c in e.children ?? const <md.Node>[]) {
          _inline(c, s, l, out);
        }
    }
  }

  void _addText(List<MdInline> out, String text, MdStyle style, String? link) {
    if (text.isEmpty) return;
    if (out.isNotEmpty) {
      final last = out.last;
      if (last is MdSpan && last.style == style && last.link == link) {
        out[out.length - 1] = MdSpan(last.text + text, style: style, link: link);
        return;
      }
    }
    out.add(MdSpan(text, style: style, link: link));
  }
}
