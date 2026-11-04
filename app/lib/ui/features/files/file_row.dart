import 'package:herdr_mobile/l10n/l10n_context.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/services/remote_files.dart';
import '../../../data/words/elapsed.dart';

import 'package:herdr_mobile/l10n/app_localizations.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'file_format.dart';
import 'file_thumb.dart';
import 'file_widgets.dart';
import 'middle_ellipsis.dart';

/// One entry of a folder: a glyph (a small picture for a small image), the
/// name, and on one muted line its size and when it changed. A long name is
/// cut in the middle so its extension stays on screen. Same grid as
/// [ListRow] (text at 64, divider from the text), which it cannot be because
/// a [ListRow] title is plain end-ellipsized text.
///
/// An entry nobody can read (or that the host refused) is dimmed and says so;
/// it still opens, because the folder it leads to explains itself.
class FileRow extends StatelessWidget {
  const FileRow({
    super.key,
    required this.entry,
    required this.files,
    required this.now,
    required this.onTap,
    this.denied = false,
    this.thumbs,
    this.trailing,
    this.selected,
  });

  final RemoteEntry entry;
  final RemoteFiles files;
  final DateTime now;
  final VoidCallback onTap;
  final bool denied;

  /// Defaults to the shared loader.
  final ThumbLoader? thumbs;

  /// Replaces the folder chevron at the end of the row (the attach sheet puts
  /// a selection circle here).
  final Widget? trailing;

  /// Whether the row is selected, for the screen reader; null when the row
  /// has no selection at all.
  final bool? selected;

  /// `12 KB · 3 min ago`, `Link → target`, `No permission`. The words follow
  /// the phone's language; the size, the time and the target do not.
  String subtitle(AppLocalizations l10n) {
    final e = entry;
    if (denied) return l10n.uiNoPermission;
    final when = e.modified == null ? '' : formatAgo(e.modified!, now, l10n: l10n);
    if (e.kind == RemoteEntryKind.link) {
      final to = e.linkTarget == null ? '' : ' → ${e.linkTarget}';
      return e.isBrokenLink ? '${l10n.uiBrokenLink}$to' : '${l10n.uiLink}$to';
    }
    if (e.isDirectory) return when;
    final size = formatBytes(e.size, l10n: l10n);
    return when.isEmpty ? size : '$size · $when';
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final e = entry;
    final sub = subtitle(context.l10n);
    final indent = Gap.gutter + 32 + Gap.md;
    Widget row = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PressRow(
          onTap: onTap,
          minHeight: _rowHeight,
          padding: const EdgeInsets.symmetric(horizontal: Gap.gutter - PressRow.inset, vertical: Gap.md),
          child: Row(
            children: [
              SizedBox(
                width: RowMetrics.leadingExtent,
                child: e.isDirectory
                    ? IconTile(icon: iconForEntry(e), color: ds.textSecondary)
                    : FileThumb(files: files, entry: e, icon: iconForEntry(e), loader: thumbs),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MiddleEllipsisText(e.name, style: Type.row.copyWith(color: ds.text)),
                    if (sub.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: Gap.hair),
                        child: Text(
                          sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          // The one muted line: size and time.
                          style: Type.secondary.copyWith(color: ds.textSecondary),
                        ),
                      ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: Gap.xs),
                trailing!,
              ] else if (e.isDirectory) ...[
                const SizedBox(width: Gap.md),
                Icon(LucideIcons.chevronRight, size: IconSize.row, color: ds.textTertiary),
              ],
            ],
          ),
        ),
        Hairline(indent: indent),
      ],
    );
    // An Opacity layer only for the rare unreadable row.
    if (denied) row = Opacity(opacity: 0.55, child: row);
    return Semantics(hint: e.isDirectory ? context.l10n.uiFolder : null, selected: selected, child: row);
  }
}

/// A file row: a thumbnail-sized leading column and two lines.
const _rowHeight = 64.0;
