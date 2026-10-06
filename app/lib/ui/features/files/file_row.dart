import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/services/remote_files.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/theme.dart';
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

  static const _inset = 8.0;

  /// `12 KB · 3 min ago`, `Link → target`, `No permission`.
  String subtitle() {
    final e = entry;
    if (denied) return 'No permission';
    final when = formatModified(e.modified, now: now);
    if (e.kind == RemoteEntryKind.link) {
      final to = e.linkTarget == null ? '' : ' → ${e.linkTarget}';
      return e.isBrokenLink ? 'Broken link$to' : 'Link$to';
    }
    if (e.isDirectory) return when;
    final size = formatBytes(e.size);
    return when.isEmpty ? size : '$size · $when';
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final e = entry;
    final sub = subtitle();
    final indent = Gap.gutter + 32 + 12;
    Widget row = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PressBuilder(
          onTap: onTap,
          builder: (context, pressed) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: _inset),
            child: AnimatedContainer(
              duration: Motion.pressing(pressed),
              curve: Motion.easeOut,
              constraints: const BoxConstraints(minHeight: 64),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: pressed ? ds.fill : Colors.transparent,
                borderRadius: BorderRadius.circular(Radii.row),
              ),
              padding: const EdgeInsets.symmetric(horizontal: Gap.gutter - _inset, vertical: 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 32,
                    child: e.isDirectory
                        ? IconTile(icon: iconForEntry(e), color: ds.accentText)
                        : FileThumb(files: files, entry: e, icon: iconForEntry(e), loader: thumbs),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        MiddleEllipsisText(e.name, style: Type.row.copyWith(color: ds.text)),
                        if (sub.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
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
                  if (trailing != null) ...[const SizedBox(width: 4), trailing!] else if (e.isDirectory) ...[
                    const SizedBox(width: 12),
                    Icon(LucideIcons.chevronRight, size: 16, color: ds.textTertiary),
                  ],
                ],
              ),
            ),
          ),
        ),
        Hairline(indent: indent),
      ],
    );
    // An Opacity layer only for the rare unreadable row.
    if (denied) row = Opacity(opacity: 0.55, child: row);
    return Semantics(hint: e.isDirectory ? 'Folder' : null, selected: selected, child: row);
  }
}
