import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../core/approval_button.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/status_panel.dart';
import '../../core/tokens.dart';
import '../machines/machine_form_screen.dart';
import '../pane/pane_screen.dart';
import 'agents_grouping.dart';

/// Every agent across every machine, grouped by how much it needs you.
class AgentsScreen extends StatefulWidget {
  const AgentsScreen({super.key, this.onShowMachines});

  /// Takes the person to the Machines tab, where connection problems are
  /// explained and fixed.
  final VoidCallback? onShowMachines;

  @override
  State<AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends State<AgentsScreen> with RestorationMixin {
  AgentStatus? _filter;

  // Collapsed sections, one bit per status, so the set survives the process
  // being reclaimed. Nothing secret lives here.
  final _collapsedBits = RestorableInt(0);

  // The last page built. A hidden tab hands this back instead of rebuilding,
  // so fleet updates cost the tab that is not on screen one cheap build call.
  Widget? _page;

  @override
  String get restorationId => 'agents';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_collapsedBits, 'collapsed');
  }

  @override
  void dispose() {
    _collapsedBits.dispose();
    super.dispose();
  }

  Set<AgentStatus> get _collapsed => {
        for (final s in AgentStatus.values)
          if (_collapsedBits.value & (1 << s.index) != 0) s,
      };

  void _addMachine() => openMachineForm(context);

  void _toggleFilter(AgentStatus s) => setState(() => _filter = _filter == s ? null : s);

  void _toggleSection(AgentStatus s) =>
      setState(() => _collapsedBits.value ^= 1 << s.index);

  @override
  Widget build(BuildContext context) {
    if (!TickerMode.valuesOf(context).enabled) {
      if (_page case final page?) return page;
    }
    final overview = context.select<FleetRepository, AgentsOverview>(AgentsOverview.of);
    return _page = _buildPage(context, overview);
  }

  Widget _buildPage(BuildContext context, AgentsOverview overview) {
    final ds = context.ds;
    final clearance = FloatingTabBar.clearance(context);

    if (overview.machineCount == 0) {
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

    final groups = groupByStatus(overview.agents);
    // A filter whose agents are all gone cannot be cleared by its chip any
    // more. Drop it for good, so it does not come back by itself when an
    // agent of that status shows up again.
    if (_filter != null && !groups.containsKey(_filter)) _filter = null;
    final filter = _filter;
    final entries = agentEntries(groups, filter: filter, collapsed: _collapsed);
    final indexes = entryIndexes(entries);

    final chips = [for (final s in filterableStatuses) if (groups.containsKey(s)) s];
    final chipsHeight = chips.isEmpty ? 0.0 : AppChip.height;
    final troubled = overview.troubled;

    return AppRefresh(
      onRefresh: context.read<FleetRepository>().retryAll,
      edgeOffset: SliverLargeTitle.extent(context, hasSubtitle: true, bottomHeight: chipsHeight),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverLargeTitle(
            title: 'Agents',
            subtitle: Text(
              _summary(overview),
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
            bottom: chips.isEmpty
                ? null
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    // Chips slide out through the page gutter, not under it.
                    clipBehavior: Clip.none,
                    child: Row(
                      children: [
                        for (final (i, s) in chips.indexed) ...[
                          if (i > 0) const SizedBox(width: Gap.sm),
                          AppChip(
                            label: s.label,
                            count: groups[s]!.length,
                            leading: StatusGlyph(status: s, size: 14),
                            selected: filter == s,
                            onTap: () => _toggleFilter(s),
                          ),
                        ],
                      ],
                    ),
                  ),
            bottomHeight: chipsHeight,
          ),
          if (troubled.isNotEmpty)
            SliverPadding(
              // The chip row's 44dp box and the section label's top padding
              // already leave air around the strip.
              padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
              sliver: SliverToBoxAdapter(
                child: _ConnectionStrip(
                  troubled: troubled,
                  onShowMachines: widget.onShowMachines,
                ),
              ),
            ),
          if (overview.agents.isEmpty && troubled.isEmpty)
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
              findChildIndexCallback: (key) => indexes[key],
              itemBuilder: (context, i) => switch (entries[i]) {
                final AgentHeader h => SectionLabel(
                    key: h.key,
                    label: h.status.label,
                    count: h.count,
                    expanded: h.expanded,
                    onTap: () => _toggleSection(h.status),
                  ),
                final AgentLine l => Collapse(
                    key: l.key,
                    open: l.open,
                    child: _AgentRow(agent: l.agent, divider: !l.last),
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

String _summary(AgentsOverview o) {
  String count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
  return [
    count(o.machineCount, 'machine'),
    o.agents.isEmpty ? 'no agents' : count(o.agents.length, 'agent'),
    if (o.troubled.isNotEmpty) '${o.troubled.length} not connected',
  ].join(' · ');
}

class _AgentRow extends StatelessWidget {
  const _AgentRow({required this.agent, required this.divider});

  final AgentRowData agent;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return ListRow(
      // Staleness dims the whole row once; the glyph is not dimmed again.
      leading: StatusGlyph(status: agent.status, size: 20),
      title: agent.title,
      subtitle: agent.subtitle,
      titleMaxLines: 2,
      trailing: Icon(LucideIcons.chevronRight, size: 16, color: ds.textTertiary),
      dim: agent.stale,
      divider: divider,
      // Merged from the glyph and the texts, plus what dimming only implies.
      semanticLabel: agent.stale
          ? [
              agent.status.label,
              agent.title,
              if (agent.subtitle.isNotEmpty) agent.subtitle,
              'offline',
            ].join(', ')
          : null,
      onTap: () {
        tapFeedback();
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PaneScreen(machine: agent.machine, paneId: agent.paneId),
          ),
        );
      },
    );
  }
}

/// Machines that are not connected, in one line. One machine is named and can
/// be retried here; several are summed up and the detail lives on the
/// Machines tab, so the agents stay on the first screen.
class _ConnectionStrip extends StatelessWidget {
  const _ConnectionStrip({required this.troubled, required this.onShowMachines});

  final List<TroubledMachine> troubled;
  final VoidCallback? onShowMachines;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    if (troubled.length > 1) {
      final state = worstLinkState(troubled.map((t) => t.state));
      return StatusStrip(
        color: state.color(ds),
        leading: LinkDot(state: state),
        title: '${troubled.length} machines not connected',
        action: Icon(LucideIcons.chevronRight, size: 16, color: ds.textSecondary),
        onTap: onShowMachines,
      );
    }
    final t = troubled.single;
    return StatusStrip(
      key: ValueKey(t.machine.profile.id),
      color: t.state.color(ds),
      leading: LinkDot(state: t.state),
      title: t.label,
      detail: t.state.label,
      action: switch (t.approvalUrl) {
        final url? => ApprovalButton(url: url),
        null => AppButton(
            label: 'Retry',
            compact: true,
            kind: AppButtonKind.secondary,
            onPressed: t.machine.retry,
          ),
      },
    );
  }
}
