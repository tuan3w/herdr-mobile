import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/session_state.dart';
import '../../../data/acp/turns/turns.dart';
import '../../core/controls.dart';
import '../../core/markdown/markdown.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import 'code_panel.dart';
import 'log_atoms.dart';
import 'transcript_rows.dart';
import 'visible_text.dart';

/// The folded work log of a finished turn, one line:
/// `▸ Worked 42s · 3 files · 4 commands · 1 failed`. Made of counts, times and
/// exit codes the app has (`workSummaryParts`), never of words a model wrote;
/// the part that counts failures is in the danger text tone. A tap opens the
/// log in place (the toggle lives with the transcript, so it survives the row
/// scrolling away), and the caret turns.
class FoldRow extends StatelessWidget {
  const FoldRow({
    super.key,
    required this.rowKey,
    required this.turn,
    required this.gap,
    required this.open,
    required this.onToggle,
    this.note,
  });

  final String rowKey;
  final Turn turn;
  final double gap;
  final bool open;
  final RowToggle onToggle;

  /// A trailing part of the summary the transcript knows (`Plan 3 of 3 done`).
  final String? note;

  @override
  Widget build(BuildContext context) {
    notifyRowBuilt(rowKey);
    final ds = context.ds;
    final parts = [...workSummaryParts(turn), ?note];
    final base = Type.secondary.copyWith(color: ds.textSecondary, fontWeight: FontWeight.w500, fontFeatures: Type.tabular);
    return Padding(
      padding: EdgeInsets.only(top: gap),
      child: Semantics(
        expanded: open,
        child: PressBuilder(
          onTap: () => onToggle(rowKey),
          semanticLabel: parts.join(', '),
          builder: (context, pressed) => AnimatedContainer(
            duration: Motion.pressing(pressed),
            curve: Motion.easeOut,
            constraints: const BoxConstraints(minHeight: kMinTap),
            padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: 6),
            decoration: BoxDecoration(
              color: pressed ? ds.fill : Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.row),
            ),
            child: Row(
              children: [
                Caret(open: open),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      style: base,
                      children: [
                        for (final (i, part) in parts.indexed) ...[
                          if (i > 0) const TextSpan(text: ' \u00b7 '),
                          TextSpan(
                            text: part,
                            style: part.endsWith(' failed') ? base.copyWith(color: ds.dangerText) : null,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final _thoughtDocuments = Expando<MdDocument>('thought markdown');

/// A thought parsed as Markdown, once per message object. A thought that is
/// still arriving grows in place, so it is parsed again per change (only
/// while it is open: a folded thought builds nothing).
MdDocument thoughtDocument(TranscriptMessage message) {
  final live = message.live != null;
  final cached = live ? null : _thoughtDocuments[message];
  if (cached != null) return cached;
  final text = message.text;
  final document = parseMd(text.length > panelTextLimit ? text.substring(0, panelTextLimit) : text);
  if (!live) _thoughtDocuments[message] = document;
  return document;
}

/// The agent's reasoning of one stretch of the log: a single quiet `Thinking`
/// line that opens to the thoughts as Markdown. Thoughts have no row of their
/// own; the ones with nothing but other thoughts between them are one line.
class ThinkingRow extends StatelessWidget {
  const ThinkingRow({
    super.key,
    required this.rowKey,
    required this.thoughts,
    required this.gap,
    required this.open,
    required this.onToggle,
  });

  final String rowKey;
  final List<TranscriptMessage> thoughts;
  final double gap;
  final bool open;
  final RowToggle onToggle;

  @override
  Widget build(BuildContext context) {
    notifyRowBuilt(rowKey);
    final ds = context.ds;
    final lives = [
      for (final t in thoughts)
        if (t.live != null) t.live!,
    ];
    Widget body() => Padding(
      padding: const EdgeInsets.only(left: Gap.sm + Gap.xs, bottom: Gap.sm),
      child: Container(
        padding: const EdgeInsets.only(left: Gap.md),
        decoration: BoxDecoration(border: Border(left: BorderSide(color: ds.hairline, width: 2))),
        child: MdToneScope(
          tone: MdTone.quiet,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, t) in thoughts.indexed) ...[
                if (i > 0) const SizedBox(height: Gap.sm),
                if (t.text.isNotEmpty) MdDocumentView(document: thoughtDocument(t)),
              ],
            ],
          ),
        ),
      ),
    );
    return Padding(
      padding: EdgeInsets.only(top: gap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            expanded: open,
            child: PressBuilder(
              onTap: () => onToggle(rowKey),
              semanticLabel: 'Thinking',
              builder: (context, pressed) => AnimatedContainer(
                duration: Motion.pressing(pressed),
                curve: Motion.easeOut,
                constraints: const BoxConstraints(minHeight: kMinTap),
                padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
                decoration: BoxDecoration(
                  color: pressed ? ds.fill : Colors.transparent,
                  borderRadius: BorderRadius.circular(Radii.row),
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.brain, size: 16, color: ds.textSecondary),
                    const SizedBox(width: 10),
                    Text(
                      'Thinking',
                      style: Type.secondary.copyWith(color: ds.textSecondary, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (open)
            // A thought that is still arriving is followed while it is open.
            lives.isEmpty ? body() : ListenableBuilder(listenable: Listenable.merge(lives), builder: (_, _) => body()),
        ],
      ),
    );
  }
}

/// Adjacent reads and searches that went well, one line (`Read 3 files ·
/// searched 2×`); tapped, the calls.
class GroupRow extends StatelessWidget {
  const GroupRow({
    super.key,
    required this.rowKey,
    required this.group,
    required this.gap,
    required this.open,
    required this.onToggle,
  });

  final String rowKey;
  final ToolGroup group;
  final double gap;
  final bool open;
  final RowToggle onToggle;

  @override
  Widget build(BuildContext context) {
    notifyRowBuilt(rowKey);
    final ds = context.ds;
    final label = group.label ?? '';
    return Padding(
      padding: EdgeInsets.only(top: gap),
      child: Semantics(
        expanded: open,
        child: PressBuilder(
          onTap: () => onToggle(rowKey),
          semanticLabel: label,
          builder: (context, pressed) => AnimatedContainer(
            duration: Motion.pressing(pressed),
            curve: Motion.easeOut,
            constraints: const BoxConstraints(minHeight: kMinTap),
            padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: 6),
            decoration: BoxDecoration(
              color: pressed ? ds.fill : Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.row),
            ),
            child: Row(
              children: [
                Icon(group.reads > 0 ? LucideIcons.fileText : LucideIcons.search, size: 16, color: ds.textSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    visibleText(label),
                    style: Type.secondary.copyWith(color: ds.textSecondary, fontWeight: FontWeight.w500),
                  ),
                ),
                const SizedBox(width: Gap.sm),
                Caret(open: open),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
