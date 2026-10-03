import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/models/machine_profile.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/machine_repository.dart';
import '../../core/motion.dart';
import '../../core/status_style.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'machine_form_screen.dart';
import 'machine_screen.dart';

void openMachineForm(BuildContext context, {MachineProfile? existing}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
          builder: (_) => MachineFormScreen(existing: existing)),
    );

class MachinesScreen extends StatelessWidget {
  const MachinesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final fleet = context.watch<FleetRepository>();
    final connections = fleet.connections;

    return Scaffold(
      floatingActionButton: connections.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => openMachineForm(context),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add machine'),
            ),
      body: connections.isEmpty
          ? SafeArea(
              child: EmptyState(
                icon: Icons.dns_rounded,
                title: 'No machines yet',
                message:
                    'Add a machine that runs herdr. You can connect as many as '
                    'you like and see them all together.',
                action: FilledButton.icon(
                  onPressed: () => openMachineForm(context),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add machine'),
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: fleet.retryAll,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverAppBar.large(
                    title: const Text('Machines'),
                    centerTitle: false,
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                        Gap.lg, Gap.sm, Gap.lg, 96),
                    sliver: SliverList.separated(
                      itemCount: connections.length,
                      separatorBuilder: (_, _) => const SizedBox(height: Gap.md),
                      itemBuilder: (_, i) =>
                          _MachineCard(machine: connections[i]),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _MachineCard extends StatelessWidget {
  const _MachineCard({required this.machine});

  final MachineConnection machine;

  Future<void> _remove(BuildContext context) async {
    final repo = context.read<MachineRepository>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${machine.profile.label}?'),
        content: const Text(
          'The saved connection and its credentials are deleted from this '
          'device. Agents on the machine keep running.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(96, 44),
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) await repo.remove(machine.profile.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final p = machine.profile;
    final snap = machine.snapshot;
    final state = machine.state;
    final agents = snap.agentPanes;
    final needYou = agents.where((a) => a.status == AgentStatus.blocked).length;
    final problem = state == LinkState.attention || state == LinkState.reconnecting;

    final card = Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: p.enabled
            ? () {
                tapFeedback();
                Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => MachineScreen(machine: machine),
                ));
              }
            : null,
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(Radii.field),
                        ),
                        child: Icon(Icons.dns_rounded, color: scheme.onSurfaceVariant),
                      ),
                      Positioned(
                        right: -3,
                        bottom: -3,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerLow,
                            shape: BoxShape.circle,
                          ),
                          child: PulsingDot(
                            color: state.color,
                            size: 9,
                            pulse: state == LinkState.connecting ||
                                state == LinkState.reconnecting,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: Gap.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(p.label,
                            style: theme.textTheme.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Text(
                          '${p.username}@${p.host}${p.port == 22 ? '' : ':${p.port}'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: Icon(Icons.more_vert_rounded, color: scheme.onSurfaceVariant),
                    onSelected: (v) async {
                      final repo = context.read<MachineRepository>();
                      switch (v) {
                        case 'edit':
                          openMachineForm(context, existing: p);
                        case 'toggle':
                          await repo.save(p.copyWith(enabled: !p.enabled));
                        case 'remove':
                          await _remove(context);
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuItem(
                        value: 'toggle',
                        child: Text(p.enabled ? 'Disable' : 'Enable'),
                      ),
                      const PopupMenuItem(value: 'remove', child: Text('Remove')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: Gap.lg),
              if (state == LinkState.online || snap.version.isNotEmpty)
                Wrap(
                  spacing: Gap.lg,
                  runSpacing: Gap.sm,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _Stat(
                      icon: Icons.space_dashboard_rounded,
                      value: '${snap.workspaces.length}',
                      label: 'workspaces',
                    ),
                    _Stat(
                      icon: Icons.smart_toy_rounded,
                      value: '${agents.length}',
                      label: 'agents',
                    ),
                    if (needYou > 0)
                      _Stat(
                        icon: Icons.front_hand_rounded,
                        value: '$needYou',
                        label: 'need you',
                        color: AgentStatus.blocked.color,
                      ),
                    if (snap.version.isNotEmpty)
                      Text('herdr ${snap.version}',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: scheme.outline)),
                  ],
                )
              else
                Text(
                  state.label,
                  style: theme.textTheme.labelLarge?.copyWith(color: state.color),
                ),
              if (problem && machine.error != null) ...[
                const SizedBox(height: Gap.md),
                Container(
                  padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.xs, Gap.xs),
                  decoration: BoxDecoration(
                    color: state.color.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(Radii.chip),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          machine.error!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      TextButton(
                          onPressed: machine.retry, child: const Text('Retry')),
                    ],
                  ),
                ),
              ],
              if (!p.enabled)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.sm),
                  child: Text('Disabled — not connecting',
                      style: theme.textTheme.labelMedium
                          ?.copyWith(color: scheme.outline)),
                ),
            ],
          ),
        ),
      ),
    );

    return Pressable(child: card);
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.value, required this.label, this.color});

  final IconData icon;
  final String value;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: c),
        const SizedBox(width: 6),
        Text(value,
            style: theme.textTheme.titleSmall
                ?.copyWith(color: color, fontWeight: FontWeight.w700)),
        const SizedBox(width: 4),
        Flexible(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
      ],
    );
  }
}
