import 'package:flutter/material.dart';

import '../../../data/acp/turns/turns.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import 'log_atoms.dart';
import 'tool_rows.dart' show DiffPanel;
import 'transcript_rows.dart';
import 'visible_text.dart';

/// The Changed card of a finished turn, drawn as rows of the transcript list
/// (the head, one row per file, `N more`) that share one quiet panel, so a
/// card with hundreds of files is as lazy as the rest of the list.
///
/// A file is its path tail and `+a −b`, with a mark when the turn created or
/// deleted it; a tap opens its diff in place (the panel of the tool body).
/// The card is absent when no file changed.

BorderRadius _corners({required bool first, required bool last}) => BorderRadius.vertical(
  top: first ? const Radius.circular(Radii.panel) : Radius.zero,
  bottom: last ? const Radius.circular(Radii.panel) : Radius.zero,
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
          padding: const EdgeInsets.fromLTRB(Gap.md, 10, Gap.md, 4),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text.rich(
                    TextSpan(
                      text: 'Changed',
                      style: Type.label.copyWith(color: ds.text, fontWeight: FontWeight.w600),
                      children: [
                        TextSpan(
                          text: '  ${files.length} ${files.length == 1 ? 'file' : 'files'}',
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
      decoration: BoxDecoration(color: ds.fill, borderRadius: _corners(first: false, last: last)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            expanded: open,
            child: PressBuilder(
              onTap: () => onToggle(rowKey),
              semanticLabel: [
                visibleText(file.path),
                ?mark,
                if (stats) DiffStats.words(file.added, file.removed),
              ].join(', '),
              builder: (context, pressed) => AnimatedContainer(
                duration: Motion.pressing(pressed),
                curve: Motion.easeOut,
                constraints: const BoxConstraints(minHeight: kMinTap),
                padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 6),
                decoration: BoxDecoration(
                  color: pressed ? ds.fillPressed : Colors.transparent,
                  borderRadius: _corners(first: false, last: last && !open),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          text: name,
                          style: Type.secondary.copyWith(color: ds.text, fontWeight: FontWeight.w500),
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
                        style: Type.caption.copyWith(color: file.isDelete ? removedText(ds) : addedText(ds), fontWeight: FontWeight.w600),
                      ),
                    ],
                    if (stats) ...[
                      const SizedBox(width: Gap.sm),
                      DiffStats(added: file.added, removed: file.removed),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (file.diffs.isEmpty)
                    Text(
                      file.isDelete ? 'The file was deleted.' : 'No changes to show.',
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
/// `Show fewer` once all are listed.
class ChangedMoreRow extends StatelessWidget {
  const ChangedMoreRow({super.key, required this.rowKey, required this.count, required this.all, required this.onToggle});

  final String rowKey;
  final int count;
  final bool all;
  final RowToggle onToggle;

  @override
  Widget build(BuildContext context) {
    notifyRowBuilt(rowKey);
    final ds = context.ds;
    final label = all ? 'Show fewer' : '$count more';
    return DecoratedBox(
      decoration: BoxDecoration(color: ds.fill, borderRadius: _corners(first: false, last: true)),
      child: PressBuilder(
        onTap: () => onToggle(rowKey),
        semanticLabel: all ? 'Show fewer files' : '$count more ${count == 1 ? 'file' : 'files'}',
        builder: (context, pressed) => AnimatedContainer(
          duration: Motion.pressing(pressed),
          curve: Motion.easeOut,
          constraints: const BoxConstraints(minHeight: kMinTap),
          padding: const EdgeInsets.symmetric(horizontal: Gap.md),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: pressed ? ds.fillPressed : Colors.transparent,
            borderRadius: _corners(first: false, last: true),
          ),
          child: Text(label, style: Type.label.copyWith(color: ds.accentText, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}
