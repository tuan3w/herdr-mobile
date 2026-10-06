/// Candidate C: `package:markdown` 7.3.1 with GitHub flavour plus alerts, as it
/// is: the AST mapped to the dump with no repair of any kind.
library;

import 'package:markdown/markdown.dart' as md;

import '../../../app/test/markdown/support/dump_writer.dart';

final _doc = md.Document(
  extensionSet: md.ExtensionSet(
    [...md.ExtensionSet.gitHubFlavored.blockSyntaxes, const md.AlertBlockSyntax()],
    md.ExtensionSet.gitHubFlavored.inlineSyntaxes,
  ),
  encodeHtml: false,
);

List<md.Node> parseC(String text) =>
    _doc.parseLines(text.replaceAll('\r\n', '\n').split('\n'));

void _inline(md.Node n, int flags, String? link, List<DInline> out, bool softSpace) {
  if (n is md.Text) {
    final t = flags & dumpCode == 0 && softSpace ? n.text.replaceAll('\n', ' ') : n.text;
    out.add(DRun(t, flags: flags, link: link));
    return;
  }
  final e = n as md.Element;
  switch (e.tag) {
    case 'br':
      out.add(const DBreak());
    case 'img':
      out.add(DImage(e.attributes['src'] ?? '', e.attributes['alt'] ?? ''));
    default:
      final f = flags |
          switch (e.tag) {
            'strong' => dumpBold,
            'em' => dumpItalic,
            'del' => dumpStrike,
            'code' => dumpCode,
            _ => 0,
          };
      final l = e.tag == 'a' ? (e.attributes['href'] ?? '') : link;
      for (final c in e.children ?? const <md.Node>[]) {
        _inline(c, f, l, out, softSpace);
      }
  }
}

List<DInline> _inlines(Iterable<md.Node> nodes, bool softSpace) {
  final out = <DInline>[];
  for (final n in nodes) {
    _inline(n, 0, null, out, softSpace);
  }
  return out;
}

String _rawText(md.Node n) => n is md.Text
    ? n.text
    : [for (final c in (n as md.Element).children ?? const <md.Node>[]) _rawText(c)].join();

const _blockTags = {
  'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'pre', 'blockquote', 'ul', 'ol',
  'hr', 'table', 'div',
};

void _blocks(DumpOut out, int depth, List<md.Node> nodes, bool softSpace) {
  // Loose runs of inline children (a tight list item) form one paragraph.
  var run = <md.Node>[];
  void flushRun() {
    if (run.isEmpty) return;
    final d = dumpInlines(_inlines(run, softSpace));
    if (d.isNotEmpty) out.add(depth, 'p', d);
    run = [];
  }

  for (final n in nodes) {
    if (n is md.Element && _blockTags.contains(n.tag)) {
      flushRun();
      _block(out, depth, n, softSpace);
    } else if (n is md.Element && n.tag == 'input') {
      continue;
    } else {
      run.add(n);
    }
  }
  flushRun();
}

String _align(md.Element cell) {
  final style = cell.attributes['style'] ?? cell.attributes['align'] ?? '';
  if (style.contains('left')) return 'l';
  if (style.contains('center')) return 'c';
  if (style.contains('right')) return 'r';
  return '-';
}

void _block(DumpOut out, int depth, md.Element e, bool softSpace) {
  final kids = e.children ?? const <md.Node>[];
  switch (e.tag) {
    case 'p':
      out.add(depth, 'p', dumpInlines(_inlines(kids, softSpace)));
    case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
      out.add(depth, e.tag, dumpInlines(_inlines(kids, softSpace)));
    case 'hr':
      out.add(depth, 'rule');
    case 'pre':
      final code = kids.isNotEmpty && kids.first is md.Element
          ? kids.first as md.Element
          : null;
      final cls = code?.attributes['class'] ?? '';
      final lang = cls.startsWith('language-') ? cls.substring(9) : '';
      var text = _rawText(e);
      if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
      out.add(depth, lang.isEmpty ? 'code' : 'code[$lang]', dumpQuote(text));
    case 'blockquote':
      out.add(depth, 'quote');
      _blocks(out, depth + 1, kids, softSpace);
    case 'div':
      final cls = e.attributes['class'] ?? '';
      final m = RegExp(r'markdown-alert-(\w+)$').firstMatch(cls);
      out.add(depth, m == null ? 'div' : 'alert ${m.group(1)!.toUpperCase()}');
      _blocks(out, depth + 1, kids.skip(1).toList(), softSpace);
    case 'ul' || 'ol':
      // Loose when any item holds a paragraph element.
      final loose = kids.any((li) =>
          li is md.Element &&
          (li.children ?? const <md.Node>[]).any((c) => c is md.Element && c.tag == 'p'));
      final start = e.tag == 'ol' ? ' ${e.attributes['start'] ?? '1'}' : '';
      out.add(depth, '${e.tag}$start ${loose ? 'loose' : 'tight'}');
      for (final li in kids.whereType<md.Element>()) {
        final input = (li.children ?? const <md.Node>[])
            .whereType<md.Element>()
            .followedBy((li.children ?? const <md.Node>[])
                .whereType<md.Element>()
                .expand((p) => p.children?.whereType<md.Element>() ?? const <md.Element>[]))
            .where((c) => c.tag == 'input')
            .firstOrNull;
        final task = input == null
            ? ''
            : (input.attributes.containsKey('checked') ? ' [x]' : ' [ ]');
        out.add(depth + 1, 'li$task');
        _blocks(out, depth + 2, li.children ?? const <md.Node>[], softSpace);
      }
    case 'table':
      final rows = [
        for (final s in kids.whereType<md.Element>())
          for (final r in s.children!.whereType<md.Element>()) (s.tag, r),
      ];
      final head = rows.first.$2;
      final cells = head.children!.whereType<md.Element>().toList();
      out.add(depth, 'table ${cells.map(_align).join(',')}');
      for (final (section, r) in rows) {
        out.add(
            depth + 1,
            section == 'thead' ? 'th' : 'tr',
            dumpCells([
              for (final c in r.children!.whereType<md.Element>())
                _inlines(c.children ?? const <md.Node>[], softSpace)
            ]));
      }
  }
}

String dumpC(String src, {bool softSpace = false}) {
  final out = DumpOut();
  for (final n in parseC(src)) {
    if (n is md.Text) {
      // Raw HTML blocks come back as text.
      final t = n.text.trim();
      if (t.isNotEmpty) out.add(0, 'p', dumpQuote(t));
    } else {
      _block(out, 0, n as md.Element, softSpace);
    }
  }
  return out.toString();
}
