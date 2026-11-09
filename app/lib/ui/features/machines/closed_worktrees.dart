import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/repositories/machine_connection.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../create/management_sheets.dart';

/// The quiet row that ends a repo's checkouts: how many of its worktrees herdr
/// has closed (`Closed worktrees · 2`). A closed worktree keeps its folder, and
/// nothing else on this screen shows it, so this is where its space is given
/// back. Nothing when there are none. Offline it is dimmed and does nothing, as
/// the `⋯` buttons are.
class ClosedWorktreesRow extends StatelessWidget {
  const ClosedWorktreesRow({super.key, required this.machine, required this.repoKey, required this.repoName});

  final MachineConnection machine;
  final String repoKey;
  final String repoName;

  /// A quiet closing row, lower than a pane row (as `Show all` is).
  static const _minHeight = 48.0;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: machine,
    builder: (context, _) {
      final closed = machine.closedCheckouts(repoKey);
      if (closed.isEmpty) return const SizedBox.shrink();
      final ds = context.ds;
      final live = machine.isLive;
      return PressRow(
        onTap: live ? () => showClosedWorktrees(context, machine, repoKey, repoName) : null,
        minHeight: _minHeight,
        padding: const EdgeInsetsDirectional.only(start: Gap.gutter - PressRow.inset, end: Gap.gutter - PressRow.inset),
        child: Text(
          'Closed worktrees · ${closed.length}',
          style: Type.labelStrong.copyWith(color: live ? ds.accentText : ds.textMuted),
        ),
      );
    },
  );
}

/// The closed worktrees of one repo, each removable (held, never forced). The
/// sheet stays while one is removed: it leaves the list when the machine says
/// it is gone.
Future<void> showClosedWorktrees(BuildContext context, MachineConnection machine, String repoKey, String repoName) =>
    showAppSheet<void>(
      context,
      builder: (ctx) => SheetScaffold(
        title: 'Closed worktrees',
        kind: SheetKind.list,
        // The rows bring their own gutter.
        bleed: true,
        child: ListenableBuilder(
          listenable: machine,
          builder: (context, _) {
            final ds = context.ds;
            final closed = machine.closedCheckouts(repoKey);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: Gap.gutter, right: Gap.gutter, bottom: Gap.sm),
                  child: Text(
                    '$repoName · folders are still on disk',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Type.secondary.copyWith(color: ds.textSecondary),
                  ),
                ),
                if (closed.isEmpty) const EmptyState.inline('No closed worktrees.'),
                for (var i = 0; i < closed.length; i++) ...[
                  if (i > 0) Hairline(indent: ListRow.textIndent()),
                  ListRow(
                    title: closed[i].name,
                    subtitle: machine.branchOf(closed[i].path) ?? closed[i].branch,
                    leading: Icon(LucideIcons.gitBranch, size: IconSize.lead, color: ds.textSecondary),
                    onTap: machine.isLive
                        ? () => confirmRemoveWorktree(
                            ctx,
                            machine,
                            path: closed[i].path,
                            repoPath: machine.repoRootOf(repoKey),
                            name: closed[i].name,
                          )
                        : null,
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
