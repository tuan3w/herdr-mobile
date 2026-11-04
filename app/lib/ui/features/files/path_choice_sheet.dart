import 'package:herdr_mobile/l10n/l10n_context.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/repositories/path_finder.dart';
import '../../../data/words/elapsed.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

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
      return SheetScaffold(
        title: context.l10n.messageIsInPlaces(name, '${candidates.length}'),
        kind: SheetKind.list,
        // The rows bring their own gutter.
        bleed: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: Gap.gutter, right: Gap.gutter, bottom: Gap.sm),
              child: Text(context.l10n.uiNewestFirst, style: Type.secondary.copyWith(color: ds.textSecondary)),
            ),
            for (var i = 0; i < candidates.length; i++) ...[
              if (i > 0) Hairline(indent: ListRow.textIndent()),
              ListRow(
                title: candidates[i].relative,
                titleMaxLines: 2,
                subtitle: [
                  candidates[i].rootName,
                  if (candidates[i].modified case final at?) formatAgo(at, now),
                ].join(' · '),
                leading: Icon(
                  candidates[i].stat.isDirectory ? LucideIcons.folder : fileIconForName(candidates[i].stat.name),
                  size: IconSize.lead,
                  color: ds.textSecondary,
                ),
                onTap: () => Navigator.of(ctx).pop(candidates[i]),
              ),
            ],
          ],
        ),
      );
    },
  );
}
