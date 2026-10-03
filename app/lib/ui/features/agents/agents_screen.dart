import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../core/approval_button.dart';
import '../../core/motion.dart';
import '../../core/status_style.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../machines/machine_form_screen.dart';
import '../pane/pane_screen.dart';

class AgentsScreen extends StatelessWidget {
  const AgentsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final fleet = context.watch<FleetRepository>();
    final connections = fleet.connections;
    final agents = fleet.agents;
    final theme = Theme.of(context);

    if (connections.isEmpty) {
      return Scaffold(
        body: SafeArea(
          child: EmptyState(
            icon: Icons.hub_rounded,
            title: 'Your agents, in your pocket',
            message:
                'Connect a machine running herdr to see every coding agent, '
                'know the moment one needs you, and reply from anywhere.',
            action: FilledButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const MachineFormScreen()),
              ),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add your first machine'),
            ),
          ),
        ),
      );
    }

    final troubled =
        connections.where((c) => c.state != LinkState.online).toList();
    final groups = <AgentStatus, List<FleetAgent>>{};
    for (final a in agents) {
      groups.putIfAbsent(a.pane.status, () => []).add(a);
    }

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: fleet.retryAll,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar.large(
              title: const Text('Agents'),
              centerTitle: false,
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xxl),
              sliver: SliverList.list(
                children: [
                  _SummaryStrip(groups: groups),
                  for (final c in troubled) ...[
                    const SizedBox(height: Gap.md),
                    _ConnectionNotice(machine: c),
                  ],
                  if (agents.isEmpty && troubled.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.xxl * 2),
                      child: Column(
                        children: [
                          Icon(Icons.nights_stay_rounded,
                              size: 40, color: theme.colorScheme.outline),
                          const SizedBox(height: Gap.md),
                          Text('No agents running',
                              style: theme.textTheme.titleMedium),
                          const SizedBox(height: Gap.xs),
                          Text(
                            'Start one in herdr and it will appear here.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  for (final status in AgentStatus.values)
                    if (groups[status] case final list? when list.isNotEmpty) ...[
                      SectionHeader(
                        label: status.label,
                        count: list.length,
                        color: status.color,
                      ),
                      for (final a in list)
                        Padding(
                          padding: const EdgeInsets.only(bottom: Gap.md),
                          child: AgentCard(agent: a),
                        ),
                    ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.groups});

  final Map<AgentStatus, List<FleetAgent>> groups;

  @override
  Widget build(BuildContext context) {
    final shown = [
      AgentStatus.blocked,
      AgentStatus.working,
      AgentStatus.done,
      AgentStatus.idle,
    ];
    return Row(
      children: [
        for (final s in shown)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: s == shown.last ? 0 : Gap.sm),
              child: _SummaryTile(
                status: s,
                count: groups[s]?.length ?? 0,
              ),
            ),
          ),
      ],
    );
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({required this.status, required this.count});

  final AgentStatus status;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = count > 0;
    final color = active ? status.color : theme.colorScheme.outline;
    return AnimatedContainer(
      duration: Motion.standard,
      curve: Motion.easeOut,
      padding: const EdgeInsets.symmetric(vertical: Gap.md, horizontal: Gap.md),
      decoration: BoxDecoration(
        color: active
            ? status.color.withValues(alpha: 0.10)
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.chip + 2),
        border: Border.all(
          color: active
              ? status.color.withValues(alpha: 0.30)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$count',
            style: theme.textTheme.headlineMedium
                ?.copyWith(color: color, height: 1),
          ),
          const SizedBox(height: Gap.xs),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              status.label,
              maxLines: 1,
              style: theme.textTheme.labelSmall?.copyWith(
                color: active
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionNotice extends StatelessWidget {
  const _ConnectionNotice({required this.machine});

  final MachineConnection machine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final needsAction = machine.state == LinkState.attention ||
        machine.state == LinkState.approval;
    final color = needsAction ? const Color(0xFFF59E0B) : machine.state.color;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.chip + 2),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          Icon(
            needsAction ? Icons.error_outline_rounded : Icons.sync_rounded,
            color: color,
            size: 20,
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${machine.profile.label} · ${machine.state.label}',
                  style: theme.textTheme.labelLarge,
                ),
                if (machine.error != null)
                  Text(
                    machine.error!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          if (machine.approvalUrl case final url?)
            ApprovalButton(url: url)
          else
            TextButton(onPressed: machine.retry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class AgentCard extends StatelessWidget {
  const AgentCard({super.key, required this.agent});

  final FleetAgent agent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pane = agent.pane;
    final status = pane.status;
    final stale = agent.stale;
    final urgent = status == AgentStatus.blocked && !stale;
    final workspace = agent.workspace?.label ?? '';
    final path = cwdTail(pane.cwd);

    final card = Opacity(
      opacity: stale ? 0.55 : 1,
      child: Material(
        color: urgent
            ? status.color.withValues(alpha: 0.07)
            : scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.card),
          side: BorderSide(
            color: urgent
                ? status.color.withValues(alpha: 0.55)
                : scheme.outlineVariant,
            width: urgent ? 1.4 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            tapFeedback();
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    PaneScreen(machine: agent.machine, paneId: pane.id),
              ),
            );
          },
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 4, color: status.color.withValues(alpha: stale ? 0.4 : 1)),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                pane.agent ?? 'terminal',
                                style: theme.textTheme.titleMedium,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (status == AgentStatus.working)
                              StatusDot(
                                  color: status.color
                                      .withValues(alpha: stale ? 0.4 : 1),
                                  size: 8),
                          ],
                        ),
                        if (pane.title.isNotEmpty) ...[
                          const SizedBox(height: Gap.sm),
                          Text(
                            pane.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                              height: 1.35,
                            ),
                          ),
                        ],
                        const SizedBox(height: Gap.md),
                        Wrap(
                          spacing: Gap.md,
                          runSpacing: Gap.xs,
                          children: [
                            MetaTag(
                              icon: Icons.dns_rounded,
                              text: agent.machine.profile.label,
                              color: scheme.primary,
                            ),
                            if (workspace.isNotEmpty)
                              MetaTag(
                                  icon: Icons.space_dashboard_rounded,
                                  text: workspace),
                            if (path.isNotEmpty && path != workspace)
                              MetaTag(icon: Icons.folder_rounded, text: path),
                            if (stale)
                              const MetaTag(
                                  icon: Icons.cloud_off_rounded, text: 'offline'),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: Gap.md),
                  child: Icon(Icons.chevron_right_rounded,
                      color: scheme.outline),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // Status is otherwise conveyed by colour and the section header only.
    return Semantics(value: status.label, child: Pressable(child: card));
  }
}
