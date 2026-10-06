/// The immutable model every Markdown surface of the app reads (chat answers,
/// thoughts, the plan in the permission dock, the file viewer): the seam in
/// front of the parser engine. Nothing outside `ui/core/markdown/` may import
/// the engine; a renderer sees only this file.
///
/// Pure Dart. The shape is chosen for painting and selection:
///
///  * Leaf text blocks (paragraph, heading, table cells) hold an [MdInlines]:
///    runs with a style set, and the visible text as ONE string,
///    `inlines.text`. Every run knows its UTF-16 start in that string
///    (`inlines.startOf(i)`), and `inlines.text` is exactly the concatenation
///    of the runs' `text`: a `TextPainter` built from the runs lays out the
///    same string, so a selection offset in the painter is an offset in the
///    model. A hard break contributes `'\n'`, an image contributes its alt text
///    (the renderer draws a chip whose label is exactly that text).
///  * Containers (quote, alert, list item) hold blocks, to any depth.
///  * `plainText` on every block is what screen readers and "copy as text" use.
library;

/// The style set of a run: a bit mask of [bold], [italic], [strike], [code].
extension type const MdStyle(int bits) {
  static const MdStyle none = MdStyle(0);
  static const MdStyle bold = MdStyle(1);
  static const MdStyle italic = MdStyle(2);
  static const MdStyle strike = MdStyle(4);
  static const MdStyle code = MdStyle(8);

  bool has(MdStyle other) => bits & other.bits != 0;
  MdStyle operator |(MdStyle other) => MdStyle(bits | other.bits);
}

/// One inline element of a paragraph, heading or table cell.
sealed class MdInline {
  const MdInline();

  /// What this element contributes to the visible text.
  String get text;
}

/// A run of text with one style set and an optional link.
///
/// [link] is the destination as the author wrote it (never fetched or opened
/// by the model; the renderer shows the full address first and allows only
/// `http`/`https`). `null` means no link. The empty string means a link with
/// nowhere to go: a link label whose destination is still arriving
/// (`healTail`), or a genuine `[x]()`: the renderer styles it as a link but it
/// is not tappable ([tappable]).
final class MdSpan extends MdInline {
  const MdSpan(this.text, {this.style = MdStyle.none, this.link});

  @override
  final String text;
  final MdStyle style;
  final String? link;

  bool get tappable => link != null && link!.isNotEmpty;
}

/// A hard line break (two trailing spaces, a backslash, `<br>`). Soft line
/// breaks are not elements: they are `'\n'` (chat default) or `' '` inside a
/// [MdSpan]'s text, see `parseMd(softBreaksAsNewlines:)`.
final class MdBreak extends MdInline {
  const MdBreak();

  @override
  String get text => '\n';
}

/// `![alt](src)`. Never fetched: the renderer shows a chip with [alt] and the
/// host of [src]; a tap shows the address first. [text] is [alt].
final class MdImage extends MdInline {
  const MdImage({required this.alt, required this.src});

  final String alt;
  final String src;

  @override
  String get text => alt;
}

/// The inline content of one leaf block, with its visible text and the
/// UTF-16 start of every element in it.
final class MdInlines {
  MdInlines(List<MdInline> items) : this._(List<MdInline>.unmodifiable(items));

  MdInlines._(this.items)
      : text = _join(items),
        _starts = _startsOf(items);

  static const MdInlines empty = MdInlines._empty();

  const MdInlines._empty()
      : items = const <MdInline>[],
        text = '',
        _starts = const <int>[0];

  final List<MdInline> items;

  /// The visible text: the concatenation of every element's `text`.
  final String text;

  /// `_starts[i]` is the offset of `items[i]`; the last entry is `text.length`.
  final List<int> _starts;

  static String _join(List<MdInline> items) {
    if (items.length == 1) return items.first.text;
    final b = StringBuffer();
    for (final i in items) {
      b.write(i.text);
    }
    return b.toString();
  }

  static List<int> _startsOf(List<MdInline> items) {
    final out = List<int>.filled(items.length + 1, 0);
    var at = 0;
    for (var i = 0; i < items.length; i++) {
      out[i] = at;
      at += items[i].text.length;
    }
    out[items.length] = at;
    return out;
  }

  bool get isEmpty => items.isEmpty;

  int get length => text.length;

  /// UTF-16 offset in [text] where `items[index]` starts.
  int startOf(int index) => _starts[index];

  /// UTF-16 offset in [text] just after `items[index]`.
  int endOf(int index) => _starts[index + 1];

  /// Index of the element that contains the character at [offset] (the last
  /// element for `offset == length`). Binary search.
  int indexAt(int offset) {
    if (items.isEmpty) return -1;
    var lo = 0;
    var hi = items.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_starts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }
}

/// A block of the document. Sealed: switch over it exhaustively.
sealed class MdBlock {
  const MdBlock();

  /// The block as plain text (no markers), for semantics and copy-as-text.
  /// Lists and quotes join their children with `'\n'`, tables are TSV.
  String get plainText;
}

final class MdParagraph extends MdBlock {
  const MdParagraph(this.inlines);

  final MdInlines inlines;

  @override
  String get plainText => inlines.text;
}

final class MdHeading extends MdBlock {
  const MdHeading(this.level, this.inlines);

  /// 1 to 6.
  final int level;
  final MdInlines inlines;

  @override
  String get plainText => inlines.text;
}

/// A fenced or indented code block. [text] is the raw code, without the
/// trailing newline and without any indentation of an enclosing list item.
/// [language] is the first word of the info string, `''` when there is none.
final class MdCode extends MdBlock {
  const MdCode({required this.language, required this.text});

  final String language;
  final String text;

  @override
  String get plainText => text;
}

final class MdRule extends MdBlock {
  const MdRule();

  @override
  String get plainText => '';
}

/// A block quote; its [blocks] are any blocks, quotes included.
final class MdQuote extends MdBlock {
  const MdQuote(this.blocks);

  final List<MdBlock> blocks;

  @override
  String get plainText => _joinBlocks(blocks);
}

enum MdAlertKind { note, tip, important, warning, caution }

/// A GitHub alert (`> [!WARNING]`); the marker line is not part of [blocks].
final class MdAlert extends MdBlock {
  const MdAlert(this.kind, this.blocks);

  final MdAlertKind kind;
  final List<MdBlock> blocks;

  @override
  String get plainText => _joinBlocks(blocks);
}

final class MdListItem {
  const MdListItem({required this.blocks, this.checked});

  /// `null` for an ordinary item, otherwise a task item (`- [ ]` / `- [x]`).
  final bool? checked;

  /// The item's content: a paragraph first, then any blocks (nested lists,
  /// continuation paragraphs, code).
  final List<MdBlock> blocks;

  bool get isTask => checked != null;

  String get plainText => _joinBlocks(blocks);
}

/// A bullet or ordered list. Depth is structure: a nested list is a block of
/// an item.
final class MdList extends MdBlock {
  const MdList({
    required this.ordered,
    required this.start,
    required this.tight,
    required this.items,
  });

  final bool ordered;

  /// The number of the first item of an ordered list (`3.` starts at 3); 1 for
  /// a bullet list.
  final int start;

  /// Tight lists draw no space between items or between an item's paragraphs;
  /// loose ones (a blank line between items or blocks) do.
  final bool tight;
  final List<MdListItem> items;

  @override
  String get plainText => items.map((i) => i.plainText).join('\n');
}

enum MdAlign { none, left, center, right }

/// A pipe table. Every row has exactly `aligns.length` cells (short rows are
/// padded with empty cells, long ones cut), as GFM specifies.
final class MdTable extends MdBlock {
  const MdTable({
    required this.aligns,
    required this.header,
    required this.rows,
  });

  final List<MdAlign> aligns;
  final List<MdInlines> header;
  final List<List<MdInlines>> rows;

  int get columns => aligns.length;

  @override
  String get plainText {
    final b = StringBuffer(header.map((c) => c.text).join('\t'));
    for (final r in rows) {
      b
        ..write('\n')
        ..write(r.map((c) => c.text).join('\t'));
    }
    return b.toString();
  }
}

String _joinBlocks(List<MdBlock> blocks) {
  if (blocks.length == 1) return blocks.first.plainText;
  return blocks.map((b) => b.plainText).join('\n');
}

/// A parsed message: its top-level blocks.
final class MdDocument {
  const MdDocument(this.blocks);

  static const MdDocument empty = MdDocument(<MdBlock>[]);

  final List<MdBlock> blocks;

  bool get isEmpty => blocks.isEmpty;

  /// All blocks as plain text, one blank line between blocks.
  String get plainText => blocks.map((b) => b.plainText).join('\n\n');
}
