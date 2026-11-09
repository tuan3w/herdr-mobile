import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/machine_layout.dart';
import '../../../data/repositories/machine_connection.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../create/management_sheets.dart';
import '../create/new_agent_session_screen.dart';
import '../create/session_prefill.dart';
import 'closed_worktrees.dart';
import 'machine_pane_rows.dart';

/// A repo with several open checkouts: one header with the roll-up and a ＋
/// that starts an agent in the main checkout, then each checkout with the
/// agents running in it. Same collapse and cap behaviour as a plain workspace.
class MachineRepoSection extends StatelessWidget {
  const MachineRepoSection({
    super.key,
    required this.machine,
    required this.item,
    required this.open,
    required this.onToggle,
    required this.showAll,
    required this.onShowAll,
  });

  final MachineConnection machine;
  final RepoItem item;
  final bool open;
  final VoidCallback onToggle;

  /// Whether the checkout of this workspace lists every pane.
  final bool Function(String workspaceId) showAll;
  final void Function(String workspaceId) onShowAll;

  @override
  Widget build(BuildContext context) {
    final live = machine.isLive;
    final group = item.group;
    final primary = item.blocks.firstWhere((b) => !b.place.isLinked, orElse: () => item.blocks.first);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(
          label: group.repoName,
          count: item.paneCount,
          expanded: open,
          onTap: onToggle,
          leading: StatusGlyph(status: item.status, size: IconSize.inline, dim: !live),
          trailing: Transform.translate(
            offset: const Offset(machineDotsNudge, 0),
            child: CircleButton(
              icon: LucideIcons.plus,
              tooltip: 'New agent session in ${group.repoName}',
              filled: false,
              size: CircleButton.compact,
              onPressed: live
                  ? () => unawaited(
                      openNewAgentSession(
                        context,
                        machine: machine,
                        prefill: SessionPrefill(machineId: machine.profile.id, folder: primary.place.checkoutPath),
                      ),
                    )
                  : null,
            ),
          ),
        ),
        Collapse(
          open: open,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final block in item.blocks)
                _CheckoutBlockView(
                  key: ValueKey(block.workspace.id),
                  machine: machine,
                  block: block,
                  showAll: showAll(block.workspace.id),
                  onShowAll: () => onShowAll(block.workspace.id),
                ),
              ClosedWorktreesRow(machine: machine, repoKey: group.repoKey, repoName: group.repoName),
            ],
          ),
        ),
      ],
    );
  }
}

class _CheckoutBlockView extends StatelessWidget {
  const _CheckoutBlockView({
    super.key,
    required this.machine,
    required this.block,
    required this.showAll,
    required this.onShowAll,
  });

  final MachineConnection machine;
  final CheckoutBlock block;
  final bool showAll;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final live = machine.isLive;
    final place = block.place;
    // herdr names a checkout's workspace after its folder (the repo for the
    // main one). A name the person gave it, from ⋯ Rename, is shown as typed.
    final label = block.workspace.label.trim();
    final given = label.isNotEmpty && label != place.checkoutName && label != place.repoName;
    final title = given ? label : (place.isLinked ? place.checkoutName : 'Main checkout');
    final branch = machine.branchOf(place.checkoutPath);
    final rows = machinePaneRows(
      machine: machine,
      entries: block.panes,
      showAll: showAll,
      onShowAll: onShowAll,
      // The header already says which checkout; a sub-folder is still news.
      folderOf: (pane) {
        final cwd = pane.cwd;
        if (cwd == null) return '';
        final dir = cwd.length > 1 && cwd.endsWith('/') ? cwd.substring(0, cwd.length - 1) : cwd;
        return dir == place.checkoutPath ? '' : cwdTail(cwd);
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.md, Gap.gutter, Gap.xs),
          child: Row(
            children: [
              Icon(
                place.isLinked ? LucideIcons.gitBranch : LucideIcons.folder,
                size: IconSize.row,
                color: ds.textSecondary,
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: title,
                        style: Type.labelStrong.copyWith(color: ds.textSecondary),
                      ),
                      if (branch != null)
                        TextSpan(
                          text: ' · $branch',
                          style: Type.secondary.copyWith(color: ds.textMuted),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Transform.translate(
                offset: const Offset(machineDotsNudge, 0),
                child: CircleButton(
                  icon: LucideIcons.ellipsis,
                  tooltip: 'Checkout actions',
                  filled: false,
                  size: CircleButton.compact,
                  onPressed: live ? () => showWorkspaceActions(context, machine, block.workspace) : null,
                ),
              ),
            ],
          ),
        ),
        RowColumn(rows: rows),
      ],
    );
  }
}
