import 'package:flutter/foundation.dart';

import '../../../data/acp/session_state.dart' show AgentPhase;
import '../../../data/models/herdr_models.dart';
import '../../../data/models/status_time.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/attention_set.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../core/rows.dart' show cwdTail;

/// The board's sections, top to bottom: what needs the person first, then
/// what finished and awaits a look, then what is still running. A rank of its
/// own: [AgentStatus]'s order is persisted (collapsed-section bits use the
/// index) and sorts the fleet's flat list, so it stays as it is. Terminal
/// agents and agent sessions share the sections.
const boardOrder = [
  AgentStatus.blocked,
  AgentStatus.done,
  AgentStatus.working,
  AgentStatus.idle,
  AgentStatus.unknown,
];

/// Statuses that get a filter chip, in board order. Unknown agents still show
/// in their own section but are not worth a chip.
const filterableStatuses = [
  AgentStatus.blocked,
  AgentStatus.done,
  AgentStatus.working,
  AgentStatus.idle,
];

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

/// "working 12m", "needs you 3m"; with a bound (the change was found after a
/// gap and its start is not known) "needs you ≤ 25m": at most that long. Empty
/// for an agent whose state has no useful word ("unknown").
String timeInState(AgentStatus status, Duration d, {bool exact = true}) {
  final word = switch (status) {
    AgentStatus.blocked => 'needs you',
    AgentStatus.working => 'working',
    AgentStatus.done => 'done',
    AgentStatus.idle => 'idle',
    AgentStatus.unknown => '',
  };
  if (word.isEmpty) return '';
  // A bound is a gap of at least a minute; never "<1m" for one.
  const minute = Duration(minutes: 1);
  return exact ? '$word ${formatElapsed(d)}' : '$word ≤ ${formatElapsed(d < minute ? minute : d)}';
}

/// "quiet 14m": a working agent heard from nothing for that long.
String quietLabel(Duration d) => 'quiet ${formatElapsed(d)}';

/// The board's status of an agent session: the same five shapes the terminal
/// rows use. A turn that finished and was not looked at is "done".
AgentStatus boardStatus(AgentSessionView s) => AttentionSet.sessionBlocked(s)
    ? AgentStatus.blocked
    : AttentionSet.sessionToReview(s)
        ? AgentStatus.done
        : s.phase == AgentPhase.working
            ? AgentStatus.working
            : AgentStatus.idle;

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

  // When the state began, as far as known: sorts Needs you and Done by how
  // long they have waited, oldest first.
  StatusTime? since,

  // Whole minutes a working agent has been quiet, as of the machine's last
  // refresh and 0 below its threshold: sorts Working, quietest first. Only
  // moves with a refresh, so the order cannot churn with events.
  int quietMinutes,
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
    since: a.machine.statusTime(pane.id),
    quietMinutes: pane.status == AgentStatus.working ? a.machine.quietMinutes(pane.id) : 0,
  );
}

/// Agents by status in [boardOrder], empty groups left out. Inside a group:
/// Needs you and Done by how long they have waited (a bound counts as when it
/// begins; unknown last), Working quietest first, then machine, then pane.
Map<AgentStatus, List<AgentRowData>> groupByStatus(Iterable<AgentRowData> agents) {
  final groups = <AgentStatus, List<AgentRowData>>{};
  for (final a in agents) {
    groups.putIfAbsent(a.status, () => []).add(a);
  }
  return {
    for (final s in boardOrder)
      if (groups[s] case final list?) s: list..sort(_within(s)),
  };
}

Comparator<AgentRowData> _within(AgentStatus status) => switch (status) {
      AgentStatus.blocked || AgentStatus.done => _longestWaiting,
      AgentStatus.working => _quietest,
      AgentStatus.idle || AgentStatus.unknown => _byPlace,
    };

int _byPlace(AgentRowData a, AgentRowData b) {
  final byMachine = a.machine.profile.label.compareTo(b.machine.profile.label);
  if (byMachine != 0) return byMachine;
  final byPane = a.paneId.compareTo(b.paneId);
  return byPane != 0 ? byPane : a.key.compareTo(b.key);
}

int _longestWaiting(AgentRowData a, AgentRowData b) {
  final x = a.since?.at;
  final y = b.since?.at;
  if (x != null && y != null) {
    final byAge = x.compareTo(y);
    if (byAge != 0) return byAge;
  } else if (x != null || y != null) {
    return x != null ? -1 : 1;
  }
  return _byPlace(a, b);
}

int _quietest(AgentRowData a, AgentRowData b) {
  final byQuiet = b.quietMinutes.compareTo(a.quietMinutes);
  return byQuiet != 0 ? byQuiet : _byPlace(a, b);
}

/// One line of the agents list.
sealed class AgentEntry {
  const AgentEntry();

  /// What identifies this line across rebuilds, so a line keeps its element
  /// (and any animation in flight) when others come and go around it.
  Key get key;
}

class AgentHeader extends AgentEntry {
  const AgentHeader(this.status, this.count, {this.offline = 0, required this.expanded});

  final AgentStatus status;

  /// What counts (see [BoardSection.count]).
  final int count;

  /// Listed but out of reach (see [BoardSection.offline]).
  final int offline;
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

/// The place a card held until a moment ago, shrinking to nothing: an agent
/// that stopped waiting leaves its section, and the cards below glide up into
/// the gap instead of jumping by a whole card. Only the board adds these, for a
/// fraction of a second; they are not agents and nothing selects them.
class AgentFolding extends AgentEntry {
  const AgentFolding(this.agentKey, this.height);

  final String agentKey;

  /// What the card measured when it left.
  final double height;

  @override
  Key get key => ValueKey('folding/$agentKey');
}

/// A session's line: the same section as a terminal agent of its status. The
/// board only tells about it (answers are given in the session).
class SessionLine extends AgentEntry {
  const SessionLine(this.session, {required this.open, required this.last});

  final AgentSessionView session;
  final bool open;
  final bool last;

  @override
  Key get key => ValueKey('session/${session.key}');
}

/// One row of a board section: a terminal agent or an agent session.
sealed class BoardItem {
  const BoardItem();
}

final class PaneItem extends BoardItem {
  const PaneItem(this.row);
  final AgentRowData row;
}

final class SessionItem extends BoardItem {
  const SessionItem(this.session);
  final AgentSessionView session;
}

/// One section of the board: its rows, how many of them count, and how many
/// are listed but out of reach.
@immutable
class BoardSection {
  const BoardSection(this.status, this.items, {required this.count, this.offline = 0});

  final AgentStatus status;
  final List<BoardItem> items;

  /// The number on the header and the filter chip. For Needs you and Done it
  /// is the [AttentionSet]'s (what can be reached), the number the badge,
  /// the pill and the triage sheet show; for the others, every row.
  final int count;

  /// Needs you and Done: rows listed (last known) whose machine or link is
  /// down. Not in [count]; the header says "N offline".
  final int offline;
}

/// The board's sections in [boardOrder], empty ones left out, terminal agents
/// ([rows]) and agent sessions ([sessions]) together, so a status means one
/// place whatever started the agent. Needs you and Done follow [attention]:
/// what can be reached first, longest waiting first, panes and sessions
/// mixed (the order the triage sheet walks), then what is out of reach.
/// Working: the terminal agents quietest first, then the sessions as
/// [sessions] lists them; Idle: the terminal agents by place, then the
/// sessions.
List<BoardSection> boardSections(
  List<AgentRowData> rows,
  List<AgentSessionView> sessions,
  AttentionSet attention,
) {
  final panes = groupByStatus(rows);
  final bySession = <AgentStatus, List<AgentSessionView>>{};
  for (final s in sessions) {
    bySession.putIfAbsent(boardStatus(s), () => []).add(s);
  }

  List<BoardItem> itemsOf(AgentStatus status) => [
        for (final r in panes[status] ?? const <AgentRowData>[]) PaneItem(r),
        for (final s in bySession[status] ?? const <AgentSessionView>[]) SessionItem(s),
      ];

  // [attention]'s order; anything it does not list keeps its own order, last.
  List<BoardItem> inOrder(AgentStatus status, List<AttentionItem> order) {
    final rank = {for (final (i, item) in order.indexed) item.key: i};
    int at(BoardItem b) =>
        rank[switch (b) {
          PaneItem(:final row) => row.key,
          SessionItem(:final session) => 'session/${session.key}',
        }] ??
        order.length;
    final indexed = itemsOf(status).indexed.toList()
      ..sort((a, b) {
        final byRank = at(a.$2).compareTo(at(b.$2));
        return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
      });
    return [for (final (_, item) in indexed) item];
  }

  BoardSection everyRow(AgentStatus status, List<BoardItem> items) =>
      BoardSection(status, items, count: items.length);

  BoardSection section(AgentStatus status) => switch (status) {
        AgentStatus.blocked => BoardSection(
            status,
            inOrder(status, [...attention.needsYou, ...attention.offlineNeedsYou]),
            count: attention.needsYou.length,
            offline: attention.offlineNeedsYou.length,
          ),
        AgentStatus.done => BoardSection(
            status,
            inOrder(status, [...attention.toReview, ...attention.offlineToReview]),
            count: attention.toReview.length,
            offline: attention.offlineToReview.length,
          ),
        _ => everyRow(status, itemsOf(status)),
      };

  return [
    for (final status in boardOrder)
      if (panes.containsKey(status) || bySession.containsKey(status)) section(status),
  ];
}

/// The lines to list: a header per section, then its rows. With [filter] set
/// only that section shows; a filter whose section is gone shows everything.
List<AgentEntry> agentEntries(
  List<BoardSection> sections, {
  AgentStatus? filter,
  Set<AgentStatus> collapsed = const {},
}) {
  final only = sections.any((s) => s.status == filter) ? filter : null;
  return [
    for (final section in sections)
      if (only == null || only == section.status) ...[
        AgentHeader(
          section.status,
          section.count,
          offline: section.offline,
          expanded: !collapsed.contains(section.status),
        ),
        for (final (i, item) in section.items.indexed)
          switch (item) {
            PaneItem(:final row) => AgentLine(
                row,
                open: !collapsed.contains(section.status),
                last: i == section.items.length - 1,
              ),
            SessionItem(:final session) => SessionLine(
                session,
                open: !collapsed.contains(section.status),
                last: i == section.items.length - 1,
              ),
          },
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
