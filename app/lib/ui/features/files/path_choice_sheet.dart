import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/repositories/path_finder.dart';
import '../../core/chrome.dart';
import '../../core/rows.dart';
import '../../core/theme.dart';
import 'file_format.dart';
import 'file_widgets.dart';

/// Which of several places the tapped path meant: the path below its root, the
/// root's name and when it changed, newest first. Returns the one tapped, or
/// null when the sheet is dismissed.
Future<PathCandidate?> showPathChoices(BuildContext context, String name, List<PathCandidate> candidates) {
  final now = DateTime.now();
  return showAppSheet<PathCandidate>(
    context,
    builder: (ctx) {
      final ds = ctx.ds;
      return Padding(
        padding: const EdgeInsets.only(bottom: Gap.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.lg, Gap.gutter, Gap.xs),
              child: Semantics(
                header: true,
                child: Text(
                  '$name is in ${candidates.length} places',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Type.title.copyWith(color: ds.text),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.gutter, 0, Gap.gutter, Gap.sm),
              child: Text('Newest first', style: Type.secondary.copyWith(color: ds.textSecondary)),
            ),
            for (var i = 0; i < candidates.length; i++)
              ListRow(
                title: candidates[i].relative,
                titleMaxLines: 2,
                subtitle: [
                  candidates[i].rootName,
                  if (candidates[i].modified != null) formatModified(candidates[i].modified, now: now),
                ].join(' · '),
                leading: Icon(
                  candidates[i].stat.isDirectory ? LucideIcons.folder : fileIconForName(candidates[i].stat.name),
                  size: 20,
                  color: ds.textSecondary,
                ),
                divider: i < candidates.length - 1,
                onTap: () => Navigator.of(ctx).pop(candidates[i]),
              ),
          ],
        ),
      );
    },
  );
}
