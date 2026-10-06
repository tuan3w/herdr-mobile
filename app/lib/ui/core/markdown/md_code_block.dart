import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../controls.dart';
import '../motion.dart';
import '../theme.dart';
import 'md_document.dart';
import 'md_highlight.dart';
import 'md_more_row.dart';
import 'md_styles.dart';

/// Lines shown before "Show all".
const mdCodeCap = 60;

/// Past this many lines "Show all" opens a box that scrolls and builds its
/// lines lazily, instead of laying out every line in the transcript.
const mdCodeBoundedFrom = 300;
const _boundedHeight = 360.0;

/// A line longer than this makes the wrap button worth showing.
const _wrapWorthFrom = 34;

/// The wrap choice of the last block the person toggled: the next block that
/// is built starts the same way, so a person who prefers wrapped code sets it
/// once.
bool _preferWrap = false;

/// Back to "scroll sideways" (tests).
@visibleForTesting
void resetMdCodePreferences() => _preferWrap = false;

/// A fenced code block: a header (language, wrap, copy), the lines in the
/// terminal palette's syntax colours, and a "Show all" foot past [mdCodeCap]
/// lines.
///
///  * No wrap by default: the block scrolls sideways, so a line is one line.
///  * [tail]: the block is still arriving; its open last line stays plain until
///    it is complete, and it makes no semantics noise.
///  * [expanded] and [onToggleExpanded] belong to the caller, so "Show all"
///    survives the row scrolling out of the list and back.
///  * Every character that can hide or reorder code is shown as `‹U+202E›`;
///    copy still gives the raw text.
class MdCodeBlock extends StatefulWidget {
  const MdCodeBlock({super.key, required this.code, this.tail = false, this.expanded = false, this.onToggleExpanded});

  final MdCode code;
  final bool tail;
  final bool expanded;
  final VoidCallback? onToggleExpanded;

  @override
  State<MdCodeBlock> createState() => _MdCodeBlockState();
}

class _MdCodeBlockState extends State<MdCodeBlock> {
  late MdCodeLines _lines = _fresh();
  bool _wrap = _preferWrap;
  bool _copied = false;
  Timer? _reset;
  int _longest = 0;

  MdCodeLines _fresh() => MdCodeLines(widget.code.language)..setText(widget.code.text);

  @override
  void initState() {
    super.initState();
    _measure();
  }

  @override
  void didUpdateWidget(MdCodeBlock old) {
    super.didUpdateWidget(old);
    if (old.code.language != widget.code.language) {
      _lines = _fresh();
      _measure();
    } else if (old.code.text != widget.code.text && _lines.setText(widget.code.text)) {
      _measure();
    }
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  void _measure() {
    var longest = 0;
    for (final l in _lines.lines) {
      if (l.length > longest) longest = l.length;
    }
    _longest = longest;
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.code.text));
    } on PlatformException {
      Haptics.failed();
      return;
    }
    Haptics.tick();
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  void _toggleWrap() {
    setState(() {
      _wrap = !_wrap;
      _preferWrap = _wrap;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = MdCodeColors.of(context);
    final styles = MdStyles.of(context);
    final lines = _lines.lines;
    final total = lines.length;
    final over = total > mdCodeCap;
    final expanded = widget.expanded;
    final shown = over && !expanded ? mdCodeCap : total;
    // Highlight what is shown and complete: the open last line of a streaming
    // block waits for its newline.
    _lines.highlightUpTo(widget.tail ? math.min(shown, total - 1) : shown);

    final style = styles.codeBlock.copyWith(color: colors.plain);
    final charWidth = MediaQuery.textScalerOf(context).scale(style.fontSize!) * 0.6;
    final lineHeight = MediaQuery.textScalerOf(context).scale(style.fontSize!) * style.height!;
    final language = widget.code.language;
    final label = StringBuffer('Code');
    if (language.isNotEmpty) label.write(', $language');
    label.write(', $total ${total == 1 ? 'line' : 'lines'}');

    final Widget body;
    if (expanded && total > mdCodeBoundedFrom) {
      Widget line(int i) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        child: Text.rich(_lines.span(i, colors), softWrap: _wrap, style: style),
      );
      final list = ListView.builder(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        itemCount: total,
        itemExtent: _wrap ? null : lineHeight,
        itemBuilder: (context, i) => line(i),
      );
      body = SizedBox(
        height: _boundedHeight,
        child: _wrap
            ? list
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(width: _longest * charWidth + 2 * Gap.md, child: list),
              ),
      );
    } else {
      final spans = <InlineSpan>[
        for (var i = 0; i < shown; i++) ...[_lines.span(i, colors), if (i < shown - 1) const TextSpan(text: '\n')],
      ];
      final text = Text.rich(TextSpan(children: spans), softWrap: _wrap, style: style);
      body = Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: _wrap
            ? Padding(padding: const EdgeInsets.symmetric(horizontal: Gap.md), child: text)
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                child: text,
              ),
      );
    }

    final hidden = total - mdCodeCap;
    final more = over
        ? MoreRow(
            label: expanded ? '$total lines' : '$hidden more lines',
            action: expanded ? 'Show less' : 'Show all',
            onTap: widget.onToggleExpanded ?? () {},
          )
        : null;

    final block = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(Radii.row),
        border: Border.all(color: colors.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.row),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              language: language,
              colors: colors,
              wrap: _wrap,
              canWrap: _longest > _wrapWorthFrom,
              copied: _copied,
              onWrap: _toggleWrap,
              onCopy: _copy,
            ),
            body,
            ?more,
          ],
        ),
      ),
    );
    return ExcludeSemantics(
      excluding: widget.tail,
      child: Semantics(container: true, explicitChildNodes: true, label: label.toString(), child: block),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.language,
    required this.colors,
    required this.wrap,
    required this.canWrap,
    required this.copied,
    required this.onWrap,
    required this.onCopy,
  });

  final String language;
  final MdCodeColors colors;
  final bool wrap;
  final bool canWrap;
  final bool copied;
  final VoidCallback onWrap;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final label = Type.caption.copyWith(color: colors.muted);
    return SizedBox(
      height: kMinTap,
      child: Row(
        children: [
          const SizedBox(width: Gap.md),
          Expanded(
            child: ExcludeSemantics(
              child: Text(language, maxLines: 1, overflow: TextOverflow.ellipsis, style: label),
            ),
          ),
          if (canWrap)
            PressBuilder(
              onTap: onWrap,
              selected: wrap,
              semanticLabel: 'Wrap long lines',
              minTapSize: kMinTap,
              builder: (context, pressed) => Icon(
                LucideIcons.textWrap,
                size: 16,
                color: wrap || pressed ? context.ds.accentText : colors.muted,
              ),
            ),
          PressBuilder(
            onTap: onCopy,
            semanticLabel: copied ? 'Copied' : 'Copy code',
            minTapSize: kMinTap,
            builder: (context, pressed) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    copied ? LucideIcons.check : LucideIcons.copy,
                    size: 16,
                    color: copied || pressed ? context.ds.accentText : colors.muted,
                  ),
                  if (copied) ...[
                    const SizedBox(width: Gap.xs),
                    Text('Copied', style: label.copyWith(color: context.ds.accentText)),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: Gap.xs),
        ],
      ),
    );
  }
}
