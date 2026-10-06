import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/herdr_models.dart' show AgentStatus;
import '../glyphs.dart';
import '../rows.dart';
import '../theme.dart';
import 'md_code_block.dart';
import 'md_document.dart';
import 'md_styles.dart';
import 'md_table_view.dart';
import 'md_text.dart';

/// The vertical gap above [next], from the block before it. Headings take
/// room above and keep close to what they introduce; a lead-in line sits
/// nearer its list than two paragraphs do.
double mdBlockGap(MdBlock? previous, MdBlock next) => switch ((previous, next)) {
  (null, _) => 0.0,
  (_, MdHeading(level: <= 2)) => 16.0,
  (_, MdHeading()) => 12.0,
  (MdHeading(), _) => 6.0,
  (MdRule(), _) || (_, MdRule()) => 12.0,
  (MdParagraph(), MdList()) => 6.0,
  _ => 10.0,
};

/// A reading column is about 72 characters wide; a wider screen (landscape, a
/// tablet) leaves the rest empty rather than stretching lines. Code and
/// tables use the whole width.
const _readingWidth = 560.0;

/// One block of a document: a paragraph, heading, list, quote, alert, rule,
/// table or code block, drawn from the [MdDocument] model with `Text.rich`
/// paragraphs (selection and semantics come with them).
///
/// A caller that builds one row per top-level block (the transcript) keeps the
/// "Show all" state of long code blocks and tables itself and passes it as
/// [expanded] / [onToggleExpanded], so it survives the row scrolling away.
/// [tail] marks the open end of a streaming message: its code is not
/// highlighted past complete lines, and it announces nothing to a screen
/// reader until it is final.
///
/// What a link, a path or an image chip does comes from the nearest
/// [MdActions]; the tone (answer or aside) from the nearest [MdToneScope].
class MdBlockView extends StatelessWidget {
  const MdBlockView({super.key, required this.block, this.tail = false, this.expanded = false, this.onToggleExpanded});

  final MdBlock block;
  final bool tail;
  final bool expanded;
  final VoidCallback? onToggleExpanded;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    excluding: tail,
    child: _block(context, block, tail: tail, expanded: expanded, onToggle: onToggleExpanded),
  );
}

/// A static document: its blocks in a non-scrolling column with
/// [mdBlockGap]. The caller scrolls (a file viewer, a plan in a permission
/// request). Keeps the "Show all" state of its long blocks.
class MdDocumentView extends StatefulWidget {
  const MdDocumentView({super.key, required this.document, this.padding});

  final MdDocument document;
  final EdgeInsetsGeometry? padding;

  @override
  State<MdDocumentView> createState() => _MdDocumentViewState();
}

class _MdDocumentViewState extends State<MdDocumentView> {
  final _expanded = <int>{};

  @override
  void didUpdateWidget(MdDocumentView old) {
    super.didUpdateWidget(old);
    if (!identical(old.document, widget.document)) _expanded.clear();
  }

  @override
  Widget build(BuildContext context) {
    final blocks = widget.document.blocks;
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < blocks.length; i++)
          Padding(
            padding: EdgeInsets.only(top: mdBlockGap(i == 0 ? null : blocks[i - 1], blocks[i])),
            child: MdBlockView(
              block: blocks[i],
              expanded: _expanded.contains(i),
              onToggleExpanded: () => setState(() => _expanded.contains(i) ? _expanded.remove(i) : _expanded.add(i)),
            ),
          ),
      ],
    );
    final padding = widget.padding;
    return padding == null ? column : Padding(padding: padding, child: column);
  }
}

/// Caps [child] at the reading width. A block in a list row is given the full
/// width as a tight constraint, which a `ConstrainedBox` cannot narrow, so a
/// wider screen gets an `Align` that loosens it and a box of the cap's width.
/// On a phone in portrait the child is returned as it is.
Widget _capped(BuildContext context, Widget child) {
  final scale = MediaQuery.textScalerOf(context).scale(15) / 15;
  final cap = _readingWidth * scale;
  return LayoutBuilder(
    builder: (context, box) => box.maxWidth <= cap
        ? child
        : Align(
            alignment: AlignmentDirectional.topStart,
            child: SizedBox(width: cap, child: child),
          ),
  );
}

/// A top-level block: text blocks are held to the reading width, code and
/// tables use all of it.
Widget _block(
  BuildContext context,
  MdBlock block, {
  required bool tail,
  required bool expanded,
  required VoidCallback? onToggle,
}) {
  final body = _body(context, block, tail: tail, expanded: expanded, onToggle: onToggle);
  return block is MdCode || block is MdTable ? body : _capped(context, body);
}

/// [block] drawn, without the reading-width cap (the container it sits in has
/// been capped already).
Widget _body(
  BuildContext context,
  MdBlock block, {
  required bool tail,
  required bool expanded,
  required VoidCallback? onToggle,
}) {
  switch (block) {
    case MdParagraph():
      return MdInlineText(inlines: block.inlines, style: MdStyles.of(context).body);
    case MdHeading():
      return Semantics(
        header: true,
        child: MdInlineText(inlines: block.inlines, style: MdStyles.of(context).heading(block.level)),
      );
    case MdCode():
      return MdCodeBlock(code: block, tail: tail, expanded: expanded, onToggleExpanded: onToggle);
    case MdTable():
      return MdTableView(table: block, tail: tail, expanded: expanded, onToggleExpanded: onToggle);
    case MdRule():
      return const ExcludeSemantics(
        child: Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Hairline()),
      );
    case MdQuote():
      return _Quote(blocks: block.blocks, tail: tail, expanded: expanded, onToggle: onToggle);
    case MdAlert():
      return _Alert(alert: block, tail: tail, expanded: expanded, onToggle: onToggle);
    case MdList():
      return _MdList(list: block, depth: 0, tail: tail, expanded: expanded, onToggle: onToggle);
  }
}

/// The blocks inside a container (a quote, an alert, a list item) with their
/// gaps. In a tight list the gaps shrink to a line's leading.
class _Blocks extends StatelessWidget {
  const _Blocks({
    required this.blocks,
    required this.tail,
    required this.expanded,
    required this.onToggle,
    this.tight = false,
    this.depth = -1,
  });

  final List<MdBlock> blocks;
  final bool tail;
  final bool expanded;
  final VoidCallback? onToggle;
  final bool tight;

  /// List nesting depth of the first block's context (0 outside any list).
  final int depth;

  @override
  Widget build(BuildContext context) {
    if (blocks.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < blocks.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : _gap(blocks[i - 1], blocks[i])),
            child: _child(context, blocks[i], tail && i == blocks.length - 1),
          ),
      ],
    );
  }

  double _gap(MdBlock previous, MdBlock next) {
    if (!tight) return mdBlockGap(previous, next);
    return previous is MdList || next is MdList ? 3.0 : 6.0;
  }

  Widget _child(BuildContext context, MdBlock block, bool last) => block is MdList
      ? _MdList(list: block, depth: depth + 1, tail: last, expanded: expanded, onToggle: onToggle)
      : _body(context, block, tail: last, expanded: expanded, onToggle: onToggle);
}

TextDirection? _directionOf(List<MdBlock> blocks) {
  for (final b in blocks) {
    switch (b) {
      case MdParagraph():
        return mdIsRtl(b.inlines.text) ? TextDirection.rtl : null;
      case MdHeading():
        return mdIsRtl(b.inlines.text) ? TextDirection.rtl : null;
      case MdList():
        if (b.items.isNotEmpty) return _directionOf(b.items.first.blocks);
      case MdQuote():
        return _directionOf(b.blocks);
      case MdAlert():
      case MdCode():
      case MdRule():
      case MdTable():
        break;
    }
  }
  return null;
}

class _Quote extends StatelessWidget {
  const _Quote({required this.blocks, required this.tail, required this.expanded, required this.onToggle});

  final List<MdBlock> blocks;
  final bool tail;
  final bool expanded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final rtl = _directionOf(blocks) == TextDirection.rtl;
    Widget child = DecoratedBox(
      decoration: BoxDecoration(
        border: BorderDirectional(start: BorderSide(color: ds.border, width: 3)),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: Gap.md),
        child: MdToneScope(
          tone: MdToneScope.of(context) == MdTone.reading ? MdTone.quote : MdToneScope.of(context),
          child: _Blocks(blocks: blocks, tail: tail, expanded: expanded, onToggle: onToggle),
        ),
      ),
    );
    if (rtl) child = Directionality(textDirection: TextDirection.rtl, child: child);
    return child;
  }
}

class _Alert extends StatelessWidget {
  const _Alert({required this.alert, required this.tail, required this.expanded, required this.onToggle});

  final MdAlert alert;
  final bool tail;
  final bool expanded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final (icon, title, color) = switch (alert.kind) {
      MdAlertKind.note => (LucideIcons.info, 'Note', ds.textSecondary),
      MdAlertKind.tip => (LucideIcons.lightbulb, 'Tip', ds.textSecondary),
      MdAlertKind.important => (LucideIcons.messageSquareWarning, 'Important', ds.textSecondary),
      MdAlertKind.warning => (LucideIcons.triangleAlert, 'Warning', ds.blockedText),
      MdAlertKind.caution => (LucideIcons.octagonAlert, 'Caution', ds.dangerText),
    };
    return DecoratedBox(
      decoration: BoxDecoration(color: ds.fill, borderRadius: BorderRadius.circular(Radii.row)),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Row(
                children: [
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: Gap.sm),
                  Expanded(child: Text(title, style: Type.label.copyWith(color: color, fontWeight: FontWeight.w600))),
                ],
              ),
            ),
            if (alert.blocks.isNotEmpty) ...[
              const SizedBox(height: Gap.sm),
              _Blocks(blocks: alert.blocks, tail: tail, expanded: expanded, onToggle: onToggle),
            ],
          ],
        ),
      ),
    );
  }
}

/// Past this depth a nested list stops indenting further, so a pathological
/// nesting cannot squeeze its text to nothing.
const _maxIndentDepth = 6;

class _MdList extends StatelessWidget {
  const _MdList({
    required this.list,
    required this.depth,
    required this.tail,
    required this.expanded,
    required this.onToggle,
  });

  final MdList list;
  final int depth;
  final bool tail;
  final bool expanded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final styles = MdStyles.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final size = styles.body.fontSize ?? 15;
    final line = scaler.scale(size) * (styles.body.height ?? 1.4);
    // Marker columns and indents grow with the text, but not past 125%: at 160%
    // five nested levels would leave no room for the words.
    final em = size * (scaler.scale(size) / size).clamp(0.0, 1.25);

    // The marker column: as wide as the widest number, so item text lines up.
    String numberOf(int i) => '${list.start + i}.';
    double markerWidth = list.ordered
        ? (numberOf(list.items.length - 1).length * em * 0.58 + em * 0.5).clamp(em * 1.5, em * 4).toDouble()
        : em * 1.25;
    if (list.items.any((i) => i.isTask) && markerWidth < em * 1.5) markerWidth = em * 1.5;
    // Past a few levels the indent stops growing.
    if (depth >= _maxIndentDepth) markerWidth = markerWidth > em * 0.9 ? em * 0.9 : markerWidth;

    final children = <Widget>[];
    for (var i = 0; i < list.items.length; i++) {
      final item = list.items[i];
      final last = i == list.items.length - 1;
      Widget marker;
      if (item.isTask) {
        // A read-only status shape from the glyph language: an empty ring
        // (open) or a check (done). It is not a checkbox; it does nothing.
        final glyph = 14.0 * (scaler.scale(15) / 15).clamp(1.0, 1.4);
        marker = Align(
          alignment: AlignmentDirectional.topEnd,
          child: Padding(
            padding: EdgeInsetsDirectional.only(top: (line - glyph) / 2, end: em * 0.4),
            child: Semantics(
              label: item.checked! ? 'Done' : 'Not done',
              excludeSemantics: true,
              child: StatusGlyph(status: item.checked! ? AgentStatus.done : AgentStatus.idle, size: glyph),
            ),
          ),
        );
      } else if (list.ordered) {
        marker = Align(
          alignment: AlignmentDirectional.topEnd,
          child: Padding(
            padding: EdgeInsetsDirectional.only(end: em * 0.4),
            child: Text(
              numberOf(i),
              style: styles.body.copyWith(color: styles.ds.textSecondary, fontFeatures: Type.tabular),
            ),
          ),
        );
      } else {
        marker = ExcludeSemantics(
          child: Padding(
            padding: EdgeInsetsDirectional.only(top: (line - 6) / 2, start: em * 0.25),
            child: Align(
              alignment: AlignmentDirectional.topStart,
              child: _Bullet(depth: depth, color: styles.ds.textSecondary),
            ),
          ),
        );
      }
      final width = markerWidth;
      final content = _Blocks(
        blocks: item.blocks,
        tail: tail && last,
        expanded: expanded,
        onToggle: onToggle,
        tight: list.tight,
        depth: depth,
      );
      Widget row = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: width, child: marker),
          Expanded(child: content),
        ],
      );
      final dir = _directionOf(item.blocks);
      if (dir == TextDirection.rtl) row = Directionality(textDirection: dir!, child: row);
      children.add(Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : (list.tight ? 4.0 : 10.0)), child: row));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

/// A list bullet drawn as a shape (no font glyph to fall back): a dot, a ring
/// one level down, a square below that.
class _Bullet extends StatelessWidget {
  const _Bullet({required this.depth, required this.color});

  final int depth;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final level = depth % 3;
    return SizedBox.square(
      dimension: 6,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: level == 2 ? BoxShape.rectangle : BoxShape.circle,
          color: level == 1 ? null : color,
          border: level == 1 ? Border.all(color: color, width: 1.2) : null,
        ),
      ),
    );
  }
}
