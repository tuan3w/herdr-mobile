import 'package:herdr_mobile/l10n/l10n_context.dart';
import 'package:flutter/material.dart';

import '../../../data/acp/turns/turns.dart';
import '../../../data/words/plural.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'log_atoms.dart';
import 'tool_rows.dart' show DiffPanel;
import 'transcript_rows.dart';
import '../../render/visible_text.dart';

/// The Changed card of a finished turn, drawn as rows of the transcript list
/// (the head, one row per file, `N more`) that share one quiet panel, so a
/// card with hundreds of files is as lazy as the rest of the list.
///
/// A file is its path tail and `+a −b`, with a mark when the turn created or
/// deleted it; a tap opens its diff in place (the panel of the tool body).
/// The card is absent when no file changed.

BorderRadius _corners({required bool first, required bool last}) => BorderRadius.vertical(
  top: first ? const Radius.circular(Radii.md) : Radius.zero,
  bottom: last ? const Radius.circular(Radii.md) : Radius.zero,
);

/// `Changed · 3 files` and the totals.
class ChangedHeadRow extends StatelessWidget {
  const ChangedHeadRow({super.key, required this.rowKey, required this.turn, required this.gap});

  final String rowKey;
  final Turn turn;
  final double gap;

  @override
  Widget build(BuildContext context) {
    notifyRowBuilt(rowKey);
    final ds = context.ds;
    final files = turn.changed;
    var added = 0, removed = 0;
    for (final f in files) {
      added += f.added;
      removed += f.removed;
    }
    return Padding(
      padding: EdgeInsets.only(top: gap),
      child: DecoratedBox(
        decoration: BoxDecoration(color: ds.fill, borderRadius: _corners(first: true, last: false)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xs),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text.rich(
                    TextSpan(
                      text: context.l10n.uiChanged,
                      style: Type.labelStrong.copyWith(color: ds.text),
                      children: [
                        TextSpan(
                          text: '  ${countOf(files.length, 'file')}',
                          style: Type.caption.copyWith(color: ds.textMuted),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (added + removed > 0) ...[const SizedBox(width: Gap.sm), DiffStats(added: added, removed: removed)],
            ],
          ),
        ),
      ),
    );
  }
}

/// One file of the card: path tail, marks, `+a −b`; opens its diff.
class ChangedFileRow extends StatelessWidget {
  const ChangedFileRow({
    super.key,
    required this.rowKey,
    required this.file,
    required this.last,
    required this.open,
    required this.all,
    required this.onToggle,
  });

  final String rowKey;
  final ChangedFile file;
  final bool last;
  final bool open;

  /// "Show all" is on for the diff panels of this file.
  final bool all;
  final RowToggle onToggle;

  @override
  Widget build(BuildContext context) {
    notifyRowBuilt(rowKey);
    final ds = context.ds;
    final name = visibleText(basenameOf(file.path));
    final hint = dirHintOf(file.path);
    final stats = file.added + file.removed > 0;
    final mark = file.isDelete ? 'deleted' : (file.isNew ? 'new' : null);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ds.fill,
        borderRadius: _corners(first: false, last: last),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            expanded: open,
            child: PressRow(
              onTap: () => onToggle(rowKey),
              semanticLabel: [
                visibleText(file.path),
                ?mark,
                if (stats) DiffStats.words(file.added, file.removed),
              ].join(', '),
              minHeight: kMinTap,
              padding: const EdgeInsets.symmetric(horizontal: Gap.md - PressRow.inset, vertical: Gap.xs),
              child: Row(
                children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        text: name,
                        style: Type.secondaryStrong.copyWith(color: ds.text),
                        children: [
                          if (hint != null && hint.isNotEmpty)
                            TextSpan(
                              text: '  ${visibleText(hint)}',
                              style: Type.secondary.copyWith(color: ds.textMuted),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (mark != null) ...[
                    const SizedBox(width: Gap.sm),
                    Text(
                      mark,
                      style: Type.captionStrong.copyWith(color: file.isDelete ? removedText(ds) : ds.addedText),
                    ),
                  ],
                  if (stats) ...[const SizedBox(width: Gap.sm), DiffStats(added: file.added, removed: file.removed)],
                ],
              ),
            ),
          ),
          // The highlight keeps clear of the panel's bottom corners.
          if (last && !open) const SizedBox(height: Gap.xs),
          if (open)
            Padding(
              padding: const EdgeInsets.only(left: Gap.md, right: Gap.md, bottom: Gap.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (file.diffs.isEmpty)
                    Text(
                      file.isDelete ? context.l10n.uiTheFileWasDeleted : context.l10n.uiNoChangesToShow,
                      style: Type.secondary.copyWith(color: ds.textMuted),
                    ),
                  for (final (i, diff) in file.diffs.indexed) ...[
                    if (i > 0) const SizedBox(height: Gap.sm),
                    DiffPanel(diff: diff, all: all, onToggleAll: () => onToggle(allKey(rowKey))),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The last line of a card that lists only some of its files: `12 more`, and
/// `Show less` once all are listed.
class ChangedMoreRow extends StatelessWidget {
  const ChangedMoreRow({
    super.key,
    required this.rowKey,
    required this.count,
    required this.all,
    required this.onToggle,
  });

  final String rowKey;
  final int count;
  final bool all;
  final RowToggle onToggle;

  @override
  Widget build(BuildContext context) {
    notifyRowBuilt(rowKey);
    final ds = context.ds;
    final label = all ? 'Show less' : '$count more';
    return DecoratedBox(
      decoration: BoxDecoration(color: ds.fill, borderRadius: _corners(first: false, last: true)),
      child: Padding(
        // The highlight keeps clear of the panel's bottom corners.
        padding: const EdgeInsets.only(bottom: Gap.xs),
        child: PressRow(
          onTap: () => onToggle(rowKey),
          semanticLabel: all ? context.l10n.uiShowLess : countOf(count, context.l10n.uiMoreFile),
          minHeight: kMinTap,
          padding: const EdgeInsets.symmetric(horizontal: Gap.md - PressRow.inset),
          child: Text(label, style: Type.labelStrong.copyWith(color: ds.accentText)),
        ),
      ),
    );
  }
}
