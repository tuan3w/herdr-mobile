import 'md_document.dart';

/// Structural equality of two blocks: same kind, same text, same styles, links
/// and nesting. A caller that parses a message again after every chunk gets
/// new block objects for old text; this tells it which rows may keep their
/// widgets. Cheap for the usual case (identical objects, or the first
/// difference near the start).
bool mdBlocksEqual(MdBlock a, MdBlock b) {
  if (identical(a, b)) return true;
  switch ((a, b)) {
    case (MdParagraph a, MdParagraph b):
      return mdInlinesEqual(a.inlines, b.inlines);
    case (MdHeading a, MdHeading b):
      return a.level == b.level && mdInlinesEqual(a.inlines, b.inlines);
    case (MdCode a, MdCode b):
      return a.language == b.language && a.text == b.text;
    case (MdRule(), MdRule()):
      return true;
    case (MdQuote a, MdQuote b):
      return _blocksEqual(a.blocks, b.blocks);
    case (MdAlert a, MdAlert b):
      return a.kind == b.kind && _blocksEqual(a.blocks, b.blocks);
    case (MdList a, MdList b):
      if (a.ordered != b.ordered || a.start != b.start || a.tight != b.tight || a.items.length != b.items.length) {
        return false;
      }
      for (var i = 0; i < a.items.length; i++) {
        if (a.items[i].checked != b.items[i].checked || !_blocksEqual(a.items[i].blocks, b.items[i].blocks)) return false;
      }
      return true;
    case (MdTable a, MdTable b):
      if (a.columns != b.columns || a.rows.length != b.rows.length) return false;
      for (var c = 0; c < a.columns; c++) {
        if (a.aligns[c] != b.aligns[c] || !mdInlinesEqual(a.header[c], b.header[c])) return false;
      }
      for (var r = 0; r < a.rows.length; r++) {
        for (var c = 0; c < a.columns; c++) {
          if (!mdInlinesEqual(a.rows[r][c], b.rows[r][c])) return false;
        }
      }
      return true;
    default:
      return false;
  }
}

bool _blocksEqual(List<MdBlock> a, List<MdBlock> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!mdBlocksEqual(a[i], b[i])) return false;
  }
  return true;
}

/// Structural equality of two inline runs.
bool mdInlinesEqual(MdInlines a, MdInlines b) {
  if (identical(a, b)) return true;
  if (a.items.length != b.items.length || a.length != b.length) return false;
  for (var i = 0; i < a.items.length; i++) {
    final x = a.items[i];
    final y = b.items[i];
    final same = switch ((x, y)) {
      (MdSpan x, MdSpan y) => x.text == y.text && x.style == y.style && x.link == y.link,
      (MdBreak(), MdBreak()) => true,
      (MdImage x, MdImage y) => x.alt == y.alt && x.src == y.src,
      _ => false,
    };
    if (!same) return false;
  }
  return true;
}
