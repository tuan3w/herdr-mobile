/// `MdDocument` to the canonical structure dump (see `dump_writer.dart`).
///
/// Imports only the model and `dump_writer.dart`, so the bench
/// (`tool/md-bench`, which has `herdr_mobile` as a path dependency) compiles it.
library;

import 'package:herdr_mobile/ui/core/markdown/md_document.dart';

import 'dump_writer.dart';

String dumpDocument(MdDocument d) => dumpBlocks(d.blocks);

String dumpBlocks(List<MdBlock> blocks) {
  final out = DumpOut();
  for (final b in blocks) {
    _block(out, 0, b);
  }
  return out.toString();
}

List<DInline> dInlines(MdInlines inl) => [
      for (final i in inl.items)
        switch (i) {
          MdSpan() => DRun(
              i.text,
              flags: (i.style.has(MdStyle.bold) ? dumpBold : 0) |
                  (i.style.has(MdStyle.italic) ? dumpItalic : 0) |
                  (i.style.has(MdStyle.strike) ? dumpStrike : 0) |
                  (i.style.has(MdStyle.code) ? dumpCode : 0),
              link: i.link,
            ),
          MdBreak() => const DBreak(),
          MdImage() => DImage(i.src, i.alt),
        },
    ];

String _inl(MdInlines i) => dumpInlines(dInlines(i));

void _block(DumpOut out, int depth, MdBlock b) {
  switch (b) {
    case MdParagraph():
      out.add(depth, 'p', _inl(b.inlines));
    case MdHeading():
      out.add(depth, 'h${b.level}', _inl(b.inlines));
    case MdCode():
      out.add(depth, b.language.isEmpty ? 'code' : 'code[${b.language}]',
          dumpQuote(b.text));
    case MdRule():
      out.add(depth, 'rule');
    case MdQuote():
      out.add(depth, 'quote');
      for (final c in b.blocks) {
        _block(out, depth + 1, c);
      }
    case MdAlert():
      out.add(depth, 'alert ${b.kind.name.toUpperCase()}');
      for (final c in b.blocks) {
        _block(out, depth + 1, c);
      }
    case MdList():
      final head = b.ordered ? 'ol ${b.start}' : 'ul';
      out.add(depth, '$head ${b.tight ? 'tight' : 'loose'}');
      for (final item in b.items) {
        final task = item.checked == null ? '' : (item.checked! ? ' [x]' : ' [ ]');
        out.add(depth + 1, 'li$task');
        for (final c in item.blocks) {
          _block(out, depth + 2, c);
        }
      }
    case MdTable():
      const letters = {
        MdAlign.none: '-',
        MdAlign.left: 'l',
        MdAlign.center: 'c',
        MdAlign.right: 'r',
      };
      out.add(depth, 'table ${b.aligns.map((a) => letters[a]).join(',')}');
      out.add(depth + 1, 'th', dumpCells(b.header.map(dInlines)));
      for (final r in b.rows) {
        out.add(depth + 1, 'tr', dumpCells(r.map(dInlines)));
      }
  }
}
