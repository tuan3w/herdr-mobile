/// Markdown for the app: the public surface of `ui/core/markdown/`.
///
///  * `MdDocument` and its blocks/inlines (`md_document.dart`): what a
///    renderer reads;
///  * `parseMd`: a whole message to an `MdDocument`;
///  * `StreamingMd`: the same for a message that is arriving: frozen blocks
///    plus an open tail;
///  * `healTail`: display-only completion of the tail's half-written syntax;
///  * `MdBlockView`, `MdDocumentView`, `mdBlockGap`: the widgets that draw it
///    (one block per row for a lazy list, or a whole static document);
///  * `MdActions`: what a tap on a link, a path or an image does (the screen
///    knows the machine and the folder, the renderer does not);
///  * `MdToneScope`: answer or aside.
///
/// The engine (`package:markdown`) is imported only by `md_parser.dart`;
/// `md_chunker.dart` is internal.
library;

export 'md_actions.dart';
export 'md_block_view.dart' show MdBlockView, MdDocumentView, mdBlockGap;
export 'md_document.dart';
export 'md_equal.dart' show mdBlocksEqual, mdInlinesEqual;
export 'md_heal.dart' show healTail;
export 'md_parser.dart' show parseMd;
export 'md_stream.dart' show StreamingMd;
export 'md_styles.dart' show MdTone, MdToneScope;
