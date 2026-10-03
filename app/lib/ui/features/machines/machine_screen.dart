import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../core/motion.dart';
import '../../core/status_style.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../pane/pane_screen.dart';

/// Everything running on one machine: workspaces → tabs → panes.
class MachineScreen extends StatelessWidget {
  const MachineScreen({super.key, required this.machine});

  final MachineConnection machine;

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider.value(
        value: machine,
        child: const _MachineView(),
      );
}

class _MachineView extends StatelessWidget {
  const _MachineView();

  @override
  Widget build(BuildContext context) {
    final machine = context.watch<MachineConnection>();
    final snap = machine.snapshot;
    final theme = Theme.of(context);
    final state = machine.state;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async {
          if (machine.isLive) {
            await machine.refresh();
          } else {
            machine.retry();
          }
        },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar.large(
              centerTitle: false,
              title: Text(machine.profile.label),
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(28),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        StatusDot(color: state.color, size: 8),
                        const SizedBox(width: Gap.xs),
                        Flexible(
                          child: Text(state.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge
                                  ?.copyWith(color: state.color)),
                        ),
                        if (snap.version.isNotEmpty)
                          Flexible(
                            child: Text('  ·  herdr ${snap.version}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant)),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (machine.error != null && !machine.isLive)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.md),
                sliver: SliverToBoxAdapter(
                  child: Card(
                    child: ListTile(
                      leading: Icon(Icons.cloud_off_rounded, color: state.color),
                      title: Text(machine.error!,
                          maxLines: 3, overflow: TextOverflow.ellipsis),
                      trailing: TextButton(
                          onPressed: machine.retry, child: const Text('Retry')),
                    ),
                  ),
                ),
              ),
            if (snap.workspaces.isEmpty && machine.isLive)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.space_dashboard_rounded,
                  title: 'No workspaces',
                  message: 'Create a workspace in herdr and it will show up here.',
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                    Gap.lg, 0, Gap.lg, Gap.xxl + MediaQuery.paddingOf(context).bottom),
                sliver: SliverList.separated(
                  itemCount: snap.workspaces.length,
                  separatorBuilder: (_, _) => const SizedBox(height: Gap.md),
                  itemBuilder: (_, i) => _WorkspaceCard(
                    machine: machine,
                    workspace: snap.workspaces[i],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceCard extends StatelessWidget {
  const _WorkspaceCard({required this.machine, required this.workspace});

  final MachineConnection machine;
  final Workspace workspace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final snap = machine.snapshot;
    final tabs = snap.tabsOf(workspace.id);
    final multiTab = tabs.length > 1;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          expansionAnimationStyle: Motion.expansion,
          initiallyExpanded: machine.snapshot.workspaces.length <= 4 ||
              workspace.status == AgentStatus.blocked ||
              workspace.status == AgentStatus.done,
          tilePadding:
              const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
          childrenPadding: const EdgeInsets.fromLTRB(Gap.sm, 0, Gap.sm, Gap.sm),
          shape: const Border(),
          collapsedShape: const Border(),
          leading: StatusDot(color: workspace.status.color, size: 12),
          title: Text(
            workspace.label.isEmpty ? workspace.id : workspace.label,
            style: theme.textTheme.titleMedium,
          ),
          subtitle: Text(
            '${workspace.paneCount} pane${workspace.paneCount == 1 ? '' : 's'}'
            '${multiTab ? ' · ${tabs.length} tabs' : ''}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          children: [
            for (final tab in tabs) ...[
              if (multiTab)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.xs),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: MetaTag(
                      icon: Icons.tab_rounded,
                      text: tab.label.isEmpty ? 'Tab ${tab.number}' : tab.label,
                    ),
                  ),
                ),
              for (final pane in snap.panesOf(tab.id))
                _PaneTile(machine: machine, pane: pane),
            ],
          ],
        ),
      ),
    );
  }
}

class _PaneTile extends StatelessWidget {
  const _PaneTile({required this.machine, required this.pane});

  final MachineConnection machine;
  final Pane pane;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cleaned = pane.title;
    final title = pane.agent ?? (cleaned.isEmpty ? pane.id : cleaned);
    return ListTile(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.field)),
      dense: true,
      leading: Icon(
        pane.isAgent ? Icons.smart_toy_rounded : Icons.terminal_rounded,
        color: pane.isAgent ? pane.status.color : scheme.onSurfaceVariant,
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (pane.isAgent && cleaned.isNotEmpty) cleaned,
          if (cwdTail(pane.cwd).isNotEmpty) cwdTail(pane.cwd),
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      // The pill shrinks with a huge system font instead of squeezing the title.
      trailing: pane.isAgent
          ? ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 112),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: StatusPill(status: pane.status, dim: !machine.isLive),
              ),
            )
          : Icon(Icons.chevron_right_rounded, color: scheme.outline),
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => PaneScreen(machine: machine, paneId: pane.id),
        ));
      },
    );
  }
}
