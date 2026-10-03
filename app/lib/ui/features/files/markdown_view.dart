import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/open_link.dart';
import '../../core/rows.dart';
import '../../core/theme.dart';
import 'file_widgets.dart';
import 'markdown.dart';
import 'text_document.dart';

/// Rendered Markdown in the app's type: a readable column on the page
/// background, code on a quiet panel, links in the accent colour.
class MarkdownView extends StatefulWidget {
  const MarkdownView({super.key, required this.document});

  final TextDocument document;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  late List<MdBlock> _blocks = parseMarkdown(widget.document.text);
  late int _parsedBytes = widget.document.bytes;

  @override
  void didUpdateWidget(MarkdownView old) {
    super.didUpdateWidget(old);
    // More of the file arrived: parse again (the text is only ever appended).
    if (widget.document.bytes != _parsedBytes || old.document != widget.document) {
      _blocks = parseMarkdown(widget.document.text);
      _parsedBytes = widget.document.bytes;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom + Gap.xl;
    return SelectionArea(
      child: ListView.builder(
        padding: EdgeInsets.fromLTRB(Gap.gutter, Gap.md, Gap.gutter, bottom),
        itemCount: _blocks.length,
        itemBuilder: (context, i) => _Block(block: _blocks[i], previous: i == 0 ? null : _blocks[i - 1]),
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.block, required this.previous});

  final MdBlock block;
  final MdBlock? previous;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final b = block;
    final gap = switch ((previous, b)) {
      (null, _) => 0.0,
      (MdListItem(), MdListItem()) => 4.0,
      (_, MdHeading(level: <= 2)) => 24.0,
      (_, MdHeading()) => 18.0,
      (MdHeading(), _) => 8.0,
      _ => 14.0,
    };
    final child = switch (b) {
      MdHeading() => MdText(
          b.text,
          style: switch (b.level) {
            1 => Type.title.copyWith(fontSize: 26, height: 1.25, letterSpacing: -0.6, fontWeight: FontWeight.w700),
            2 => Type.title.copyWith(fontSize: 21),
            3 => Type.title.copyWith(fontSize: 18),
            _ => Type.row,
          }.copyWith(color: ds.text),
        ),
      MdParagraph() => MdText(b.text, style: Type.body.copyWith(color: ds.text)),
      MdQuote() => Container(
          padding: const EdgeInsets.only(left: Gap.md),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: ds.border, width: 3))),
          child: MdText(b.text, style: Type.body.copyWith(color: ds.textSecondary)),
        ),
      MdListItem() => Padding(
          padding: EdgeInsets.only(left: b.depth * 18.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 22,
                child: Text(b.marker, style: Type.body.copyWith(color: ds.textSecondary)),
              ),
              Expanded(child: MdText(b.text, style: Type.body.copyWith(color: ds.text))),
            ],
          ),
        ),
      MdRule() => const Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Hairline()),
      MdCode() => _CodeBlock(code: b.code),
    };
    return Padding(padding: EdgeInsets.only(top: gap), child: child);
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: ds.fill,
        borderRadius: BorderRadius.circular(Radii.panel),
        border: Border.all(color: ds.hairline),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(Gap.md),
        child: Text(code, softWrap: false, style: codeStyle(ds, size: 12.5).copyWith(height: 1.45)),
      ),
    );
  }
}

/// Inline Markdown text. Owns the tap recognizers of its links, so it is
/// stateful to dispose them.
class MdText extends StatefulWidget {
  const MdText(this.text, {super.key, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<MdText> createState() => _MdTextState();
}

class _MdTextState extends State<MdText> {
  final _recognizers = <TapGestureRecognizer>[];

  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    _clear();
    final spans = <InlineSpan>[];
    for (final s in parseInline(widget.text)) {
      TapGestureRecognizer? tap;
      if (s.url != null && Uri.tryParse(s.url!)?.scheme == 'https') {
        tap = TapGestureRecognizer()..onTap = () => openInBrowser(s.url!);
        _recognizers.add(tap);
      }
      spans.add(TextSpan(
        text: s.text,
        recognizer: tap,
        style: TextStyle(
          fontWeight: s.bold ? FontWeight.w700 : null,
          fontStyle: s.italic ? FontStyle.italic : null,
          fontFamily: s.code ? monoFamily : null,
          fontSize: s.code ? (widget.style.fontSize ?? 15) - 1.5 : null,
          color: s.url != null ? ds.accentText : null,
          backgroundColor: s.code ? ds.fill : null,
          decoration: s.url != null ? TextDecoration.underline : null,
          decorationColor: s.url != null ? ds.accentText.withValues(alpha: 0.4) : null,
        ),
      ));
    }
    return Text.rich(TextSpan(children: spans), style: widget.style);
  }
}
