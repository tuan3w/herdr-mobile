import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/session_state.dart';
import '../../../data/acp/turns/turns.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../render/markdown/markdown.dart';
import 'code_panel.dart';
import 'transcript_rows.dart';
import '../../render/visible_text.dart';

/// The folded work log of a finished turn, one line:
/// `▸ Worked 42s · 3 files · 4 commands · 1 failed`. Made of counts, times and
/// exit codes the app has (`workSummaryParts`), never of words a model wrote;
/// the count of failures is quiet like the rest: a failure the agent got past
/// is only counted, and one that stays is marked on its own row. A tap opens
/// the log in place (the toggle lives with the transcript, so it survives the
/// row scrolling away), and the caret turns.
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
    final base = Type.secondaryStrong.copyWith(color: ds.textSecondary, fontFeatures: Type.tabular);
    return Padding(
      padding: EdgeInsets.only(top: gap),
      child: Semantics(
        expanded: open,
        child: PressRow(
          onTap: () => onToggle(rowKey),
          semanticLabel: parts.join(', '),
          minHeight: kMinTap,
          padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: Gap.xs),
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
                        TextSpan(text: part),
                      ],
                    ],
                  ),
                ),
              ),
            ],
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
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: ds.hairline, width: 2)),
        ),
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
            child: PressRow(
              onTap: () => onToggle(rowKey),
              semanticLabel: 'Thinking',
              minHeight: kMinTap,
              padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
              child: Row(
                children: [
                  Icon(LucideIcons.brain, size: IconSize.row, color: ds.textSecondary),
                  const SizedBox(width: Gap.sm),
                  Text('Thinking', style: Type.secondaryStrong.copyWith(color: ds.textSecondary)),
                ],
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
        child: PressRow(
          onTap: () => onToggle(rowKey),
          semanticLabel: label,
          minHeight: kMinTap,
          padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: Gap.xs),
          child: Row(
            children: [
              Icon(
                group.reads > 0 ? LucideIcons.fileText : LucideIcons.search,
                size: IconSize.row,
                color: ds.textSecondary,
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(visibleText(label), style: Type.secondaryStrong.copyWith(color: ds.textSecondary)),
              ),
              const SizedBox(width: Gap.sm),
              Caret(open: open),
            ],
          ),
        ),
      ),
    );
  }
}
