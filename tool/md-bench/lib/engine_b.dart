/// Candidate B: `flutter_md` 0.2.0 parser (lib/fmd, copied by
/// fetch_flutter_md.sh), as it is.
library;

import '../../../app/test/markdown/support/dump_writer.dart';
import 'fmd/markdown.dart';
import 'fmd/nodes.dart';

List<DInline> _inl(List<MD$Span> spans) {
  final out = <DInline>[];
  for (final s in spans) {
    final st = s.style;
    if (st.contains(MD$Style.image)) {
      out.add(DImage('${s.extra?['src'] ?? ''}', s.text));
      continue;
    }
    final flags = (st.contains(MD$Style.bold) ? dumpBold : 0) |
        (st.contains(MD$Style.italic) ? dumpItalic : 0) |
        (st.contains(MD$Style.strikethrough) ? dumpStrike : 0) |
        (st.contains(MD$Style.monospace) ? dumpCode : 0) |
        (st.contains(MD$Style.underline) ? dumpUnderline : 0);
    final link = st.contains(MD$Style.link)
        ? '${s.extra?['href'] ?? s.extra?['url'] ?? ''}'
        : null;
    out.add(DRun(s.text, flags: flags, link: link));
  }
  return out;
}

void _items(DumpOut out, int depth, List<MD$ListItem> items) {
  if (items.isEmpty) return;
  final m = RegExp(r'^(\d+)').firstMatch(items.first.marker);
  out.add(depth, m == null ? 'ul tight' : 'ol ${m.group(1)} tight');
  for (final it in items) {
    out.add(depth + 1, it.checked == null ? 'li' : (it.checked! ? 'li [x]' : 'li [ ]'));
    out.add(depth + 2, 'p', dumpInlines(_inl(it.spans)));
    _items(out, depth + 2, it.children);
  }
}

String _align(MD$TableColumnAlign a) => switch (a) {
      MD$TableColumnAlign.left => 'l',
      MD$TableColumnAlign.center => 'c',
      MD$TableColumnAlign.right => 'r',
      MD$TableColumnAlign.none => '-',
    };

String dumpB(String md, {bool softSpace = false}) {
  final out = DumpOut();
  for (final b in Markdown.fromString(md).blocks) {
    switch (b) {
      case MD$Paragraph():
        out.add(0, 'p', dumpInlines(_inl(b.spans)));
      case MD$Heading():
        out.add(0, 'h${b.level}', dumpInlines(_inl(b.spans)));
      case MD$Quote():
        out.add(0, 'quote');
        out.add(1, 'p', dumpInlines(_inl(b.spans)));
      case MD$Alert():
        out.add(0, 'alert ${b.alert.marker}');
        out.add(1, 'p', dumpInlines(_inl(b.spans)));
      case MD$Code():
        final lang = b.language;
        out.add(0, lang == null || lang.isEmpty ? 'code' : 'code[$lang]',
            dumpQuote(b.text));
      case MD$List():
        _items(out, 0, b.items);
      case MD$Divider():
        out.add(0, 'rule');
      case MD$Spacer():
        break;
      case MD$Table():
        final cols = b.header.cells.length;
        out.add(0, 'table ${[for (var i = 0; i < cols; i++) _align(b.alignmentFor(i))].join(',')}');
        String row(MD$TableRow r) => dumpCells(r.cells.map(_inl));
        out.add(1, 'th', row(b.header));
        for (final r in b.rows) {
          out.add(1, 'tr', row(r));
        }
    }
  }
  return out.toString();
}

/// The raw parse (no dump), for timing.
int parseBlocksB(String md) => Markdown.fromString(md).blocks.length;
