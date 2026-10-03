import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../core/approval_button.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/tokens.dart';
import '../machines/machine_form_screen.dart';
import '../pane/pane_screen.dart';

/// Statuses that get a filter chip, in urgency order. Unknown agents still
/// show in their own section but are not worth a chip.
const _filterable = [
  AgentStatus.blocked,
  AgentStatus.working,
  AgentStatus.done,
  AgentStatus.idle,
];

/// Every agent across every machine, grouped by how much it needs you.
class AgentsScreen extends StatefulWidget {
  const AgentsScreen({super.key});

  @override
  State<AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends State<AgentsScreen> {
  AgentStatus? _filter;
  final Set<AgentStatus> _collapsed = {};

  void _addMachine() => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const MachineFormScreen()),
      );

  void _toggleFilter(AgentStatus s) =>
      setState(() => _filter = _filter == s ? null : s);

  void _toggleSection(AgentStatus s) => setState(() {
        if (!_collapsed.remove(s)) _collapsed.add(s);
      });

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final fleet = context.watch<FleetRepository>();
    final connections = fleet.connections;
    final agents = fleet.agents;
    final top = MediaQuery.paddingOf(context).top;
    final clearance = FloatingTabBar.clearance(context);

    if (connections.isEmpty) {
      return CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          const SliverLargeTitle(title: 'Agents'),
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: EdgeInsets.only(bottom: clearance),
              child: EmptyState(
                icon: LucideIcons.layoutList,
                title: 'Your agents, in your pocket',
                message: 'Connect a machine running herdr to see every coding '
                    'agent, know the moment one needs you, and reply from anywhere.',
                action: AppButton(
                  label: 'Add your first machine',
                  icon: LucideIcons.plus,
                  onPressed: _addMachine,
                ),
              ),
            ),
          ),
        ],
      );
    }

    final troubled =
        connections.where((c) => c.state != LinkState.online).toList();
    final groups = <AgentStatus, List<FleetAgent>>{};
    for (final a in agents) {
      groups.putIfAbsent(a.pane.status, () => []).add(a);
    }
    // A filter whose agents are all gone cannot be cleared by its chip any
    // more, so it simply stops applying.
    final filter = groups.containsKey(_filter) ? _filter : null;

    final entries = <_Entry>[
      for (final status in AgentStatus.values)
        if (groups[status] case final list? when filter == null || filter == status) ...[
          _Header(status, list.length, expanded: !_collapsed.contains(status)),
          for (final (i, a) in list.indexed)
            _Row(a, open: !_collapsed.contains(status), last: i == list.length - 1),
        ],
    ];

    final chips = [for (final s in _filterable) if (groups.containsKey(s)) s];
    final hasChips = chips.isNotEmpty;
    const chipsHeight = 36.0;

    return RefreshIndicator(
      onRefresh: fleet.retryAll,
      color: ds.textSecondary,
      backgroundColor: ds.surface,
      elevation: 0,
      strokeWidth: 2,
      // Appear under the pinned header, not on top of the title.
      edgeOffset: top + 56 + 50 + 22 + 8 + (hasChips ? chipsHeight : 0),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverLargeTitle(
            title: 'Agents',
            subtitle: Text(
              _summary(connections.length, agents.length, troubled.length),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.secondary.copyWith(color: ds.textSecondary),
            ),
            actions: [
              CircleButton(
                icon: LucideIcons.plus,
                tooltip: 'Add machine',
                onPressed: _addMachine,
              ),
            ],
            bottom: hasChips
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    // Chips slide out through the page gutter, not under it.
                    clipBehavior: Clip.none,
                    child: Row(
                      children: [
                        for (final (i, s) in chips.indexed) ...[
                          if (i > 0) const SizedBox(width: Gap.sm),
                          Semantics(
                            selected: filter == s,
                            child: AppChip(
                              label: s.label,
                              count: groups[s]!.length,
                              leading: StatusGlyph(status: s, size: 14),
                              selected: filter == s,
                              onTap: () => _toggleFilter(s),
                            ),
                          ),
                        ],
                      ],
                    ),
                  )
                : null,
            bottomHeight: hasChips ? chipsHeight : 0,
          ),
          if (troubled.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.xs, Gap.gutter, 0),
              sliver: SliverList.separated(
                itemCount: troubled.length,
                separatorBuilder: (_, _) => const SizedBox(height: Gap.sm),
                itemBuilder: (_, i) => _ConnectionNotice(
                  key: ValueKey(troubled[i].profile.id),
                  machine: troubled[i],
                ),
              ),
            ),
          if (agents.isEmpty && troubled.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: EdgeInsets.only(bottom: clearance),
                child: const EmptyState(
                  icon: LucideIcons.moon,
                  title: 'No agents running',
                  message: 'Start one in herdr and it will appear here.',
                ),
              ),
            )
          else ...[
            SliverList.builder(
              itemCount: entries.length,
              itemBuilder: (context, i) => switch (entries[i]) {
                _Header(:final status, :final count, :final expanded) => SectionLabel(
                    label: status.label,
                    count: count,
                    expanded: expanded,
                    onTap: () => _toggleSection(status),
                  ),
                _Row(:final agent, :final open, :final last) => Collapse(
                    key: ValueKey('${agent.machine.profile.id}/${agent.pane.id}'),
                    open: open,
                    child: _AgentRow(agent: agent, divider: !last),
                  ),
              },
            ),
            SliverToBoxAdapter(child: SizedBox(height: clearance)),
          ],
        ],
      ),
    );
  }
}

String _summary(int machines, int agents, int troubled) {
  String count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
  return [
    count(machines, 'machine'),
    agents == 0 ? 'no agents' : count(agents, 'agent'),
    if (troubled > 0) '$troubled not connected',
  ].join(' · ');
}

sealed class _Entry {
  const _Entry();
}

class _Header extends _Entry {
  const _Header(this.status, this.count, {required this.expanded});

  final AgentStatus status;
  final int count;
  final bool expanded;
}

/// A row stays in the list while its section is collapsed so that [Collapse]
/// can animate it away; it costs one empty box, not a built row.
class _Row extends _Entry {
  const _Row(this.agent, {required this.open, required this.last});

  final FleetAgent agent;
  final bool open;
  final bool last;
}

class _AgentRow extends StatelessWidget {
  const _AgentRow({required this.agent, required this.divider});

  final FleetAgent agent;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final pane = agent.pane;
    final stale = agent.stale;
    final kind = pane.agent ?? 'terminal';
    final machine = agent.machine.profile.label;
    final hasTitle = pane.title.isNotEmpty;
    final title = hasTitle ? pane.title : kind;
    final workspace = agent.workspace?.label ?? '';
    final path = cwdTail(pane.cwd);

    return ListRow(
      leading: StatusGlyph(status: pane.status, size: 20, dim: stale),
      title: title,
      subtitle: hasTitle ? '$kind · $machine' : machine,
      subtitle2: [
        if (workspace.isNotEmpty) workspace,
        if (path.isNotEmpty && path != workspace) path,
      ].join(' · '),
      trailing: Icon(LucideIcons.chevronRight, size: 16, color: ds.textTertiary),
      dim: stale,
      divider: divider,
      // The glyph adds the status; staleness is otherwise only dimming.
      semanticLabel: stale ? '$title, offline' : null,
      onTap: () {
        tapFeedback();
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PaneScreen(machine: agent.machine, paneId: pane.id),
          ),
        );
      },
    );
  }
}

/// A machine that is not online: why, and the one thing to do about it.
class _ConnectionNotice extends StatelessWidget {
  const _ConnectionNotice({super.key, required this.machine});

  final MachineConnection machine;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final state = machine.state;
    final error = machine.error;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: state.color(ds).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.panel),
        border: Border.all(color: ds.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: LinkDot(state: state),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    machine.profile.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.body.copyWith(
                      color: ds.text,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.1,
                    ),
                  ),
                  Text(
                    state.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.secondary.copyWith(
                      color: ds.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (error != null && error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.xs),
                      child: Text(
                        error,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Type.secondary.copyWith(color: ds.textSecondary),
                      ),
                    ),
                  const SizedBox(height: Gap.md),
                  if (machine.approvalUrl case final url?)
                    ApprovalButton(url: url)
                  else
                    AppButton(
                      label: 'Retry',
                      compact: true,
                      kind: AppButtonKind.secondary,
                      onPressed: machine.retry,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
