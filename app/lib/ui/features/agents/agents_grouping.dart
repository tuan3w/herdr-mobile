import 'package:flutter/foundation.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../core/rows.dart' show cwdTail;

/// Statuses that get a filter chip, in urgency order. Unknown agents still
/// show in their own section but are not worth a chip.
const filterableStatuses = [
  AgentStatus.blocked,
  AgentStatus.working,
  AgentStatus.done,
  AgentStatus.idle,
];

/// How the board draws an agent: a card with a live terminal preview, or the
/// dense two-line row.
enum AgentDensity { cards, compact }

/// "<1m", "12m", "1h 05m", "3d": the time an agent has been in its state,
/// by the minute. Never seconds, so a label changes at most once a minute.
String formatElapsed(Duration d) {
  final minutes = d.inMinutes;
  if (minutes < 1) return '<1m';
  if (minutes < 60) return '${minutes}m';
  if (d.inHours < 24) {
    final m = minutes % 60;
    return m == 0 ? '${d.inHours}h' : '${d.inHours}h ${m.toString().padLeft(2, '0')}m';
  }
  return '${d.inDays}d';
}

/// "working 12m", "needs you 3m"; empty for an agent whose state has no
/// useful word ("unknown").
String timeInState(AgentStatus status, Duration d) {
  final word = switch (status) {
    AgentStatus.blocked => 'needs you',
    AgentStatus.working => 'working',
    AgentStatus.done => 'done',
    AgentStatus.idle => 'idle',
    AgentStatus.unknown => '',
  };
  return word.isEmpty ? '' : '$word ${formatElapsed(d)}';
}

/// The agents the triage pill and sheet walk: blocked and reachable (an
/// offline machine's last-known "needs you" cannot be answered from here).
List<AgentRowData> blockedAgents(Iterable<AgentRowData> agents) => [
      for (final a in agents)
        if (a.status == AgentStatus.blocked && !a.stale) a,
    ];

/// Everything one agent row shows. A record, so two equal rows compare equal
/// and the screen can tell that nothing it draws has changed.
typedef AgentRowData = ({
  // Stable across refreshes: machine id and pane id.
  String key,
  MachineConnection machine,
  String paneId,
  AgentStatus status,
  String title,

  // Second line: agent kind, machine (only when there are several),
  // workspace, folder. Last items are the first to be cut off.
  String subtitle,
  bool stale,
});

/// A machine that is not connected, and why.
typedef TroubledMachine = ({
  MachineConnection machine,
  String label,
  LinkState state,
  String? error,
  String? approvalUrl,
});

/// What the agents tab needs from the fleet, and nothing more.
@immutable
class AgentsOverview {
  const AgentsOverview({
    required this.machineCount,
    required this.agents,
    required this.troubled,
  });

  factory AgentsOverview.of(FleetRepository fleet) =>
      AgentsOverview.from(fleet.connections, fleet.agents);

  factory AgentsOverview.from(
    List<MachineConnection> connections,
    List<FleetAgent> agents,
  ) {
    final several = connections.length > 1;
    return AgentsOverview(
      machineCount: connections.length,
      agents: [for (final a in agents) agentRow(a, showMachine: several)],
      troubled: [
        for (final c in connections)
          // A machine the person switched off is not a problem to fix.
          if (c.state != LinkState.online && c.state != LinkState.disabled)
            (
              machine: c,
              label: c.profile.label,
              state: c.state,
              error: c.error,
              approvalUrl: c.approvalUrl,
            ),
      ],
    );
  }

  final int machineCount;
  final List<AgentRowData> agents;
  final List<TroubledMachine> troubled;

  @override
  bool operator ==(Object other) =>
      other is AgentsOverview &&
      other.machineCount == machineCount &&
      listEquals(other.agents, agents) &&
      listEquals(other.troubled, troubled);

  @override
  int get hashCode => Object.hash(machineCount, Object.hashAll(agents), Object.hashAll(troubled));
}

AgentRowData agentRow(FleetAgent a, {required bool showMachine}) {
  final pane = a.pane;
  final kind = pane.agent ?? 'terminal';
  final hasTitle = pane.title.isNotEmpty;
  final workspace = a.workspace?.label ?? '';
  final path = cwdTail(pane.cwd);
  return (
    key: '${a.machine.profile.id}/${pane.id}',
    machine: a.machine,
    paneId: pane.id,
    status: pane.status,
    // A pane with no title is named after its agent.
    title: hasTitle ? pane.title : kind,
    subtitle: [
      if (hasTitle) kind,
      if (showMachine) a.machine.profile.label,
      if (workspace.isNotEmpty) workspace,
      if (path.isNotEmpty && path != workspace) path,
    ].join(' · '),
    stale: a.stale,
  );
}

/// Agents by status, in urgency order, empty groups left out.
Map<AgentStatus, List<AgentRowData>> groupByStatus(Iterable<AgentRowData> agents) {
  final groups = <AgentStatus, List<AgentRowData>>{};
  for (final a in agents) {
    groups.putIfAbsent(a.status, () => []).add(a);
  }
  return {
    for (final s in AgentStatus.values) s: ?groups[s],
  };
}

/// One line of the agents list.
sealed class AgentEntry {
  const AgentEntry();

  /// What identifies this line across rebuilds, so a line keeps its element
  /// (and any animation in flight) when others come and go around it.
  Key get key;
}

class AgentHeader extends AgentEntry {
  const AgentHeader(this.status, this.count, {required this.expanded});

  final AgentStatus status;
  final int count;
  final bool expanded;

  @override
  Key get key => ValueKey(status);
}

/// A row stays in the list while its section is collapsed so that it can
/// animate away; it costs one empty box, not a built row.
class AgentLine extends AgentEntry {
  const AgentLine(this.agent, {required this.open, required this.last});

  final AgentRowData agent;
  final bool open;
  final bool last;

  @override
  Key get key => ValueKey(agent.key);
}

/// The lines to list: a header per group, then its rows. With [filter] set
/// only that group shows; a filter whose group is gone shows everything.
List<AgentEntry> agentEntries(
  Map<AgentStatus, List<AgentRowData>> groups, {
  AgentStatus? filter,
  Set<AgentStatus> collapsed = const {},
}) {
  final only = groups.containsKey(filter) ? filter : null;
  return [
    for (final MapEntry(key: status, value: list) in groups.entries)
      if (only == null || only == status) ...[
        AgentHeader(status, list.length, expanded: !collapsed.contains(status)),
        for (final (i, a) in list.indexed)
          AgentLine(a, open: !collapsed.contains(status), last: i == list.length - 1),
      ],
  ];
}

/// Entry key to its index, for `findChildIndexCallback`.
Map<Key, int> entryIndexes(List<AgentEntry> entries) => {
      for (final (i, e) in entries.indexed) e.key: i,
    };

/// The state that most needs the person, to colour a summary of several
/// machines: something to fix, then something to approve, then waiting.
LinkState worstLinkState(Iterable<LinkState> states) {
  const order = [
    LinkState.attention,
    LinkState.approval,
    LinkState.reconnecting,
    LinkState.connecting,
    LinkState.offline,
  ];
  return states.reduce((a, b) => order.indexOf(b) < order.indexOf(a) ? b : a);
}
