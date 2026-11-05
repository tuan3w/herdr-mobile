import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/models/machine_layout.dart';
import '../../../data/repositories/machine_connection.dart';
import 'approval_button.dart';
import '../../../data/words/place_name.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../create/management_sheets.dart';
import '../create/new_agent_session_screen.dart';
import '../files/files_navigation.dart';
import 'machine_pane_rows.dart';
import 'machine_repo_section.dart';

/// Everything running on one machine: workspaces (herdr's order) → tabs
/// (newest first) → panes.
class MachineScreen extends StatelessWidget {
  const MachineScreen({super.key, required this.machine});

  final MachineConnection machine;

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider.value(value: machine, child: const _MachineView());
}

class _MachineView extends StatefulWidget {
  const _MachineView();

  @override
  State<_MachineView> createState() => _MachineViewState();
}

class _MachineViewState extends State<_MachineView> {
  /// Workspaces the person opened or closed by hand. Kept here, not in the
  /// list items, because a virtualized list drops off-screen item state.
  final _toggled = <String, bool>{};

  /// Workspaces whose pane list was lifted past the cap.
  final _showAll = <String>{};

  /// Open by default when something here needs a look, or when there is little
  /// to scroll. [key] is a workspace id or a repo key.
  bool _isOpen(String key, AgentStatus status, int sections) =>
      _toggled[key] ?? (sections <= 4 || status == AgentStatus.blocked || status == AgentStatus.done);

  @override
  void initState() {
    super.initState();
    // Branches are decoration read once on arrival and on pull-to-refresh: no
    // timer, no subscription.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(context.read<MachineConnection>().loadBranches());
    });
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final machine = context.watch<MachineConnection>();
    final snap = machine.snapshot;
    final items = machineLayout(snap, machine.places, machine.keeperPanes.keys.toSet());
    final state = machine.state;
    final approval = machine.approvalUrl;

    final loud = state == LinkState.attention || state == LinkState.approval;
    final subtitle = Row(
      children: [
        LinkDot(state: state),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: state.label,
                  style: Type.secondary.copyWith(color: loud ? ds.blockedText : ds.textSecondary),
                ),
                if (snap.version.isNotEmpty)
                  TextSpan(
                    text: ' · herdr ${snap.version}',
                    style: Type.secondary.copyWith(color: ds.textMuted),
                  ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Type.secondary,
          ),
        ),
      ],
    );

    return Scaffold(
      backgroundColor: ds.bg,
      body: AppRefresh(
        onRefresh: () async {
          if (machine.isLive) {
            await machine.refresh();
            unawaited(machine.loadBranches());
          } else {
            machine.retry();
          }
        },
        edgeOffset: SliverLargeTitle.extent(context, hasSubtitle: true),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverLargeTitle.back(
              title: machine.profile.label,
              subtitle: subtitle,
              actions: [
                if (machineSupportsFiles(machine))
                  CircleButton(
                    icon: HerdrIcons.folder,
                    tooltip: 'Browse files',
                    onPressed: () => openFileBrowser(context, machine),
                  ),
                CircleButton(
                  icon: LucideIcons.plus,
                  tooltip: 'New agent session',
                  onPressed: machine.isLive ? () => unawaited(openNewAgentSession(context, machine: machine)) : null,
                ),
              ],
            ),
            if (machine.error != null && !machine.isLive)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.xs, Gap.gutter, Gap.xs),
                  child: StatusPanel(
                    color: state.color(ds),
                    icon: LucideIcons.cloudOff,
                    message: machine.error,
                    messageMaxLines: 3,
                    trailing: AppButton(
                      label: 'Retry',
                      kind: AppButtonKind.secondary,
                      compact: true,
                      onPressed: machine.retry,
                    ),
                  ),
                ),
              ),
            if (approval != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.xs, Gap.gutter, Gap.xs),
                  child: StatusPanel(
                    color: ds.blocked,
                    icon: LucideIcons.shieldCheck,
                    title: 'Approve this sign-in',
                    message: 'Tailscale needs you to approve this sign-in.',
                    footer: Align(
                      alignment: Alignment.centerLeft,
                      child: ApprovalButton(url: approval),
                    ),
                  ),
                ),
              ),
            if (snap.workspaces.isEmpty && machine.isLive)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: LucideIcons.layoutDashboard,
                  title: 'No workspaces',
                  message: 'Create a workspace in herdr and it will show up here.',
                ),
              )
            else
              SliverList.builder(
                itemCount: items.length,
                itemBuilder: (_, i) => switch (items[i]) {
                  WorkspaceItem(:final workspace, :final panes) => _WorkspaceSection(
                    key: ValueKey(workspace.id),
                    machine: machine,
                    workspace: workspace,
                    panes: panes,
                    open: _isOpen(workspace.id, workspace.status, items.length),
                    showAll: _showAll.contains(workspace.id),
                    onToggle: () =>
                        setState(() => _toggled[workspace.id] = !_isOpen(workspace.id, workspace.status, items.length)),
                    onShowAll: () => setState(() => _showAll.add(workspace.id)),
                  ),
                  final RepoItem repo => MachineRepoSection(
                    key: ValueKey(repo.group.repoKey),
                    machine: machine,
                    item: repo,
                    open: _isOpen(repo.group.repoKey, repo.status, items.length),
                    onToggle: () => setState(
                      () => _toggled[repo.group.repoKey] = !_isOpen(repo.group.repoKey, repo.status, items.length),
                    ),
                    showAll: _showAll.contains,
                    onShowAll: (id) => setState(() => _showAll.add(id)),
                  ),
                },
              ),
            SliverToBoxAdapter(child: SizedBox(height: Gap.xxl + MediaQuery.paddingOf(context).bottom)),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceSection extends StatelessWidget {
  const _WorkspaceSection({
    super.key,
    required this.machine,
    required this.workspace,
    required this.panes,
    required this.open,
    required this.showAll,
    required this.onToggle,
    required this.onShowAll,
  });

  final MachineConnection machine;
  final Workspace workspace;
  final List<PaneEntry> panes;
  final bool open;
  final bool showAll;
  final VoidCallback onToggle;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final live = machine.isLive;

    // These are row descriptions only: [Collapse] builds nothing for a
    // workspace that is closed.
    final rows = machinePaneRows(
      machine: machine,
      entries: panes,
      showAll: showAll,
      onShowAll: onShowAll,
      folderOf: (pane) => placeName(machine.places, pane.cwd),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(
          label: workspace.label.isEmpty ? workspace.id : workspace.label,
          // The rows listed, not herdr's count: sessions placed under a
          // checkout elsewhere are not in this list.
          count: panes.length,
          expanded: open,
          onTap: onToggle,
          leading: StatusGlyph(status: workspace.status, size: IconSize.inline, dim: !live),
          // Nudged right so the dots line up with the chevrons of the rows below;
          // the hit box moves with them.
          trailing: Transform.translate(
            offset: const Offset(machineDotsNudge, 0),
            child: CircleButton(
              icon: LucideIcons.ellipsis,
              tooltip: 'Workspace actions',
              filled: false,
              size: CircleButton.compact,
              onPressed: live ? () => showWorkspaceActions(context, machine, workspace) : null,
            ),
          ),
        ),
        Collapse(
          open: open,
          child: RowColumn(rows: rows),
        ),
      ],
    );
  }
}
