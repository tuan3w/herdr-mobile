import 'package:flutter/foundation.dart';

import '../../../data/acp/session_state.dart' show AgentPhase;
import '../../../data/models/herdr_models.dart';
import '../../../data/models/pane_name.dart';
import '../../../data/models/status_time.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/attention_set.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/words/agent_names.dart';
import '../../../data/words/elapsed.dart';

import 'package:herdr_mobile/ui/core/kit.dart' show AgentStatusColor;

/// The board's sections, top to bottom ([boardLayout]): what needs the
/// person, then what is running, then what finished and awaits a look, then
/// what is at rest. Why this order (owner decision, 0.1.48): asked which
/// order finds an agent fastest, the owner chose status sections, "Needs you,
/// then working, then finished (to review), then idle", after trying a board
/// grouped by project in start order on the phone and not being able to tell
/// what to look at. A rank of its own: [AgentStatus]'s order sorts the
/// fleet's flat list, so it stays as it is. Terminal agents and agent
/// sessions share the sections.
const boardOrder = [AgentStatus.blocked, AgentStatus.working, AgentStatus.done, AgentStatus.idle, AgentStatus.unknown];

/// A section's name on the board: the status's, but `To review` for what
/// finished, the words of the status line's `3 to review` that selects them.
String sectionLabel(AgentStatus status) => status == AgentStatus.done ? 'To review' : status.label;

/// The state a row is in, as a word for screen readers: the visible label
/// says it with the glyph and the time's colour. Empty for "unknown".
String stateWord(AgentStatus status) => switch (status) {
  AgentStatus.blocked => 'needs you',
  AgentStatus.working => 'working',
  AgentStatus.done => 'done',
  AgentStatus.idle => 'idle',
  AgentStatus.unknown => '',
};

/// "12m", "<1m"; with a bound (the change was found after a gap and its start
/// is not known) "≤ 25m": at most that long. The time only: the row's glyph
/// already says the state (DESIGN.md Hierarchy 5). Empty for an agent whose
/// state has no useful word ("unknown").
String timeInState(AgentStatus status, Duration d, {bool exact = true}) {
  if (status == AgentStatus.unknown) return '';
  if (exact) return Elapsed.compact(d, seconds: false);
  // A bound is a gap of at least a minute; never "<1m" for one.
  return '≤ ${Elapsed.compact(d < _minute ? _minute : d, seconds: false)}';
}

/// What [timeInState] says, in words: "needs you, 4 minutes", "done, at most
/// 2 hours". Empty for "unknown".
String timeInStateWords(AgentStatus status, Duration d, {bool exact = true}) {
  final word = stateWord(status);
  if (word.isEmpty) return '';
  if (exact) return d < _minute ? '$word, under a minute' : '$word, ${Elapsed.words(d)}';
  return '$word, at most ${Elapsed.words(d < _minute ? _minute : d)}';
}

// design-lint: allow(raw-duration) a unit of the label, not a timer or an animation
const _minute = Duration(minutes: 1);

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

  // Second line: which feature it is, `repo · branch · agent`, then the
  // machine when there are several ([agentWhere]). Last items are the first
  // to be cut off.
  String subtitle,
  bool stale,

  // When the state began, as far as known: sorts a section newest first
  // ([compareNewestFirst]).
  StatusTime? since,

  // Whole minutes a working agent has been quiet, as of the machine's last
  // refresh and 0 below its threshold: the row says `quiet 14m`.
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

/// What the board needs from the fleet, and nothing more.
@immutable
class AgentsOverview {
  const AgentsOverview({
    required this.machineCount,
    required this.agents,
    required this.troubled,
    required this.enabledCount,
    this.branches = const [],
  });

  factory AgentsOverview.of(FleetRepository fleet) => AgentsOverview.from(fleet.connections, fleet.agents);

  factory AgentsOverview.from(List<MachineConnection> connections, List<FleetAgent> agents) {
    final several = connections.length > 1;
    return AgentsOverview(
      machineCount: connections.length,
      enabledCount: connections.where((c) => c.state != LinkState.disabled).length,
      agents: [for (final a in agents) agentRow(a, showMachine: several)],
      branches: [for (final c in connections) c.branchesVersion],
      troubled: [
        for (final c in connections)
          // A machine the person switched off is not a problem to fix.
          if (c.state != LinkState.online && c.state != LinkState.disabled)
            (machine: c, label: c.profile.label, state: c.state, error: c.error, approvalUrl: c.approvalUrl),
      ],
    );
  }

  final int machineCount;

  /// Machines that are switched on: the ones home's header counts.
  final int enabledCount;
  final List<AgentRowData> agents;
  final List<TroubledMachine> troubled;

  /// Each machine's [MachineConnection.branchesVersion]: the board names rows
  /// by branch (agent sessions' too, which [agents] does not hold), so a
  /// branch read changes what it shows.
  final List<int> branches;

  @override
  bool operator ==(Object other) =>
      other is AgentsOverview &&
      other.machineCount == machineCount &&
      other.enabledCount == enabledCount &&
      listEquals(other.agents, agents) &&
      listEquals(other.troubled, troubled) &&
      listEquals(other.branches, branches);

  @override
  int get hashCode => Object.hash(
    machineCount,
    enabledCount,
    Object.hashAll(agents),
    Object.hashAll(troubled),
    Object.hashAll(branches),
  );
}

AgentRowData agentRow(FleetAgent a, {required bool showMachine}) {
  final pane = a.pane;
  final kind = agentName(pane.agent);
  // A pane whose own title says nothing (omp's `π > <folder>`) is named by what
  // its session log says, when that was read (`PaneSessionNames`).
  final named = a.betterTitle;
  final title = named ?? (pane.title.isNotEmpty ? pane.title : kind);
  // herdr gives no status timestamps, so a pane that was already idle when the
  // app first looked has no time of its own, or only a bound. The file its agent
  // writes says when it last did: the end of its last turn, the moment it went
  // idle (`PaneSessionNames`).
  var since = a.machine.statusTime(pane.id);
  final active = a.lastActive;
  if (pane.status == AgentStatus.idle && active != null && (since == null || !since.exact)) {
    since = StatusTime.exact(active);
  }
  return (
    key: '${a.machine.profile.id}/${pane.id}',
    machine: a.machine,
    paneId: pane.id,
    status: pane.status,
    // A pane with no title is named after its agent.
    title: title,
    subtitle: agentWhere(a.machine, pane.cwd, agent: kind, title: title, showMachine: showMachine),
    stale: a.stale,
    since: since,
    quietMinutes: pane.status == AgentStatus.working ? a.machine.quietMinutes(pane.id) : 0,
  );
}

/// Which feature an agent works on, on the line under its title:
/// `herdr-mobile · fix/login · omp`, the repo, the branch checked out where it
/// works, the agent kind, then [machine]'s name when [showMachine] (the board
/// spans several machines). Why (owner decision): rows named only by task and
/// agent could not be told apart when one repo runs several features.
///
/// The repo is herdr's name for it ([PlaceIndex.of]), else the folder's last
/// part. The branch is what [MachineConnection.branchOf] read
/// (`loadBranchesOnce`, once per machine per app run); until then, and for a
/// checkout no branch was read for, the checkout's folder, which is left out
/// when it is the repo's own name. A part the [title] already says is left
/// out, and so is one said already. Never empty while there is anything to
/// say.
String agentWhere(
  MachineConnection machine,
  String? cwd, {
  required String agent,
  String? title,
  bool showMachine = false,
}) {
  final place = machine.places.of(cwd);
  final repo = place?.repoName ?? paneFolder(cwd);
  final branch = place == null ? null : machine.branchOf(place.checkoutPath);
  final checkout = branch ?? place?.checkoutName ?? '';
  final parts = <String>[];
  for (final part in [repo, checkout, agent, if (showMachine) machine.profile.label]) {
    final p = part.trim();
    if (p.isEmpty || p == '/') continue;
    final low = p.toLowerCase();
    if (title != null && low == title.trim().toLowerCase()) continue;
    if (parts.any((q) => q.toLowerCase() == low)) continue;
    parts.add(p);
  }
  return parts.join(' · ');
}

/// [agentWhere] for an agent session.
String sessionWhereOnBoard(AgentSessionView s, {bool showMachine = false}) =>
    agentWhere(s.machine, s.cwd, agent: s.agentLabel, title: s.title, showMachine: showMachine);

/// The line under a board row's title ([agentWhere]): a terminal agent's
/// [AgentRowData.subtitle], or an agent session's.
String whereOfItem(BoardItem item, {bool showMachine = false}) => switch (item) {
  PaneItem(:final row) => row.subtitle,
  SessionItem(:final session) => sessionWhereOnBoard(session, showMachine: showMachine),
};

/// Agents by status in [boardOrder], empty groups left out. Inside a group:
/// Needs you longest waiting first (a bound counts as when it begins; unknown
/// last), Working, To review and Idle newest first ([compareNewestFirst]),
/// then machine, then pane; Unknown, which has no state to date, by machine
/// and pane. [now] is the moment recency is measured from.
Map<AgentStatus, List<AgentRowData>> groupByStatus(Iterable<AgentRowData> agents, {DateTime? now}) {
  final at = now ?? DateTime.now();
  final groups = <AgentStatus, List<AgentRowData>>{};
  for (final a in agents) {
    groups.putIfAbsent(a.status, () => []).add(a);
  }
  return {
    for (final s in boardOrder)
      if (groups[s] case final list?) s: list..sort(_within(s, at)),
  };
}

Comparator<AgentRowData> _within(AgentStatus status, DateTime now) => switch (status) {
  AgentStatus.blocked => _longestWaiting,
  // No state to date.
  AgentStatus.unknown => _byPlace,
  _ => (a, b) {
    final byTime = compareNewestFirst(a.since?.at, b.since?.at, now);
    return byTime != 0 ? byTime : _byPlace(a, b);
  },
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

/// What counts as recent: past it an agent's time is old news, and one with
/// no known time is placed above it ([compareNewestFirst]).
const recentWindow = Duration(hours: 24);

/// Newest first, in three groups: a state that began within [recentWindow]
/// (newest first), then those with no known time, then those that began
/// longer ago (newest first). An agent the app has no date for was in its
/// state before it first looked, and may be 3 minutes old or 3 months; it
/// cannot be placed among the dated ones, so it sits between "known recent"
/// and "known old": above the agent whose file says 3 days, below the one
/// that stopped an hour ago. Put last, as it was first, it buried the
/// person's own recent agents under other machines' dated old ones. 0 for two
/// agents the same time does not tell apart.
int compareNewestFirst(DateTime? a, DateTime? b, DateTime now) {
  int bucket(DateTime? t) => t == null
      ? 1
      : now.difference(t) < recentWindow
      ? 0
      : 2;
  final byBucket = bucket(a).compareTo(bucket(b));
  if (byBucket != 0) return byBucket;
  return a != null && b != null ? b.compareTo(a) : 0;
}

/// A board row's status: a terminal agent's, or an agent session's
/// ([boardStatus]).
AgentStatus statusOfItem(BoardItem item) => switch (item) {
  PaneItem(:final row) => row.status,
  SessionItem(:final session) => boardStatus(session),
};

/// Whether a row can be acted on now: its machine (and a session's link) is
/// up. One that cannot is listed as last known, dimmed.
bool _reachable(BoardItem item) => switch (item) {
  PaneItem(:final row) => !row.stale,
  SessionItem(:final session) => AttentionSet.sessionReachable(session),
};

/// When a row's state began, as far as known: a terminal agent's
/// [AgentRowData.since]; an agent session's turn start while it works (its
/// last activity moves with every event, and the row would move with it),
/// else when it last did anything, by the host's clock.
DateTime? _timeOf(BoardItem item) => switch (item) {
  PaneItem(:final row) => row.since?.at,
  SessionItem(:final session) =>
    boardStatus(session) == AgentStatus.working
        ? session.phaseSince ?? session.lastActivity
        : session.lastActivity ?? session.phaseSince,
};

/// One section of the board: its rows in order, how many of them count, and
/// how many are listed but out of reach.
@immutable
class BoardSection {
  const BoardSection(this.status, this.items, {required this.count, this.offline = 0});

  final AgentStatus status;
  final List<BoardItem> items;

  /// What the section counts. For Needs you and To review it is the
  /// [AttentionSet]'s (what can be reached), the number the status line and
  /// the triage sheet show; for the others, every row.
  final int count;

  /// Needs you and To review: rows listed (last known) whose machine or link
  /// is down. Not in [count].
  final int offline;
}

/// What the board lists, top to bottom: one [BoardSection] per status in
/// [boardOrder], empty ones left out.
@immutable
class BoardLayout {
  const BoardLayout({this.sections = const []});

  final List<BoardSection> sections;

  /// The section of [status], if the board has one.
  BoardSection? section(AgentStatus status) => sections.where((s) => s.status == status).firstOrNull;

  /// Needs you's rows, in [AttentionSet]'s order (the triage walk's).
  List<BoardItem> get needsYou => section(AgentStatus.blocked)?.items ?? const [];

  /// What Needs you counts: the [AttentionSet]'s (what can be answered), the
  /// number the status line and the triage sheet show.
  int get needsYouCount => section(AgentStatus.blocked)?.count ?? 0;

  /// Waiting agents listed (last known) whose machine or link is down. Not in
  /// [needsYouCount]; the header says "N offline".
  int get needsYouOffline => section(AgentStatus.blocked)?.offline ?? 0;

  /// Finished agents not reviewed that can be marked ([AttentionSet.toReview]),
  /// and those out of reach: the status line's `3 to review`.
  int get toReviewCount => section(AgentStatus.done)?.count ?? 0;
  int get toReviewOffline => section(AgentStatus.done)?.offline ?? 0;

  /// Every row, in the board's order.
  Iterable<BoardItem> get items sync* {
    for (final s in sections) {
      yield* s.items;
    }
  }

  /// How many agents are working, as the status line says.
  int get working => section(AgentStatus.working)?.items.length ?? 0;
}

/// The board's layout: terminal agents ([rows]) and agent sessions
/// ([sessions]) together in one section per status ([boardOrder]), so a
/// status means one place whatever started the agent.
///
/// Needs you follows [attention]: what can be answered first, longest waiting
/// first, panes and sessions mixed (the order the triage sheet walks and the
/// decision card in front keeps its place by: a new waiter joins below it),
/// then what is out of reach. Every other section is newest first, by when
/// its state began ([compareNewestFirst]), so the agent that just finished
/// or just started is on top of its section (owner decision: "newest first
/// within each"). To review lists what can be marked before what is out of
/// reach, as the status line counts it. Ties keep machine and pane order.
/// [now] is the moment recency is measured from.
BoardLayout boardLayout(
  List<AgentRowData> rows,
  List<AgentSessionView> sessions,
  AttentionSet attention, {
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final byStatus = <AgentStatus, List<BoardItem>>{};
  // Panes by place first, so equal times keep a stable order.
  for (final group in groupByStatus(rows, now: at).values) {
    for (final r in group) {
      byStatus.putIfAbsent(r.status, () => []).add(PaneItem(r));
    }
  }
  for (final s in sessions) {
    byStatus.putIfAbsent(boardStatus(s), () => []).add(SessionItem(s));
  }

  // [attention]'s order; anything it does not list keeps its own order, last.
  List<BoardItem> inAttentionOrder(List<BoardItem> items, List<AttentionItem> order) {
    final rank = {for (final (i, item) in order.indexed) item.key: i};
    int rankOf(BoardItem b) =>
        rank[switch (b) {
          PaneItem(:final row) => row.key,
          SessionItem(:final session) => 'session/${session.key}',
        }] ??
        order.length;
    final indexed = items.indexed.toList()
      ..sort((a, b) {
        final byRank = rankOf(a.$2).compareTo(rankOf(b.$2));
        return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
      });
    return [for (final (_, item) in indexed) item];
  }

  List<BoardItem> newestFirst(List<BoardItem> items, {bool reachableFirst = false}) {
    final indexed = items.indexed.toList()
      ..sort((a, b) {
        if (reachableFirst) {
          final byReach = (_reachable(a.$2) ? 0 : 1).compareTo(_reachable(b.$2) ? 0 : 1);
          if (byReach != 0) return byReach;
        }
        final byTime = compareNewestFirst(_timeOf(a.$2), _timeOf(b.$2), at);
        return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
      });
    return [for (final (_, item) in indexed) item];
  }

  BoardSection section(AgentStatus status, List<BoardItem> items) => switch (status) {
    AgentStatus.blocked => BoardSection(
      status,
      inAttentionOrder(items, [...attention.needsYou, ...attention.offlineNeedsYou]),
      count: attention.needsYou.length,
      offline: attention.offlineNeedsYou.length,
    ),
    AgentStatus.done => BoardSection(
      status,
      newestFirst(items, reachableFirst: true),
      count: attention.toReview.length,
      offline: attention.offlineToReview.length,
    ),
    // No state to date: panes by place, then sessions.
    AgentStatus.unknown => BoardSection(status, items, count: items.length),
    _ => BoardSection(status, newestFirst(items), count: items.length),
  };

  return BoardLayout(
    sections: [
      for (final status in boardOrder)
        if (byStatus[status] case final items?) section(status, items),
    ],
  );
}

/// One line of the agents list.
sealed class AgentEntry {
  const AgentEntry();

  /// What identifies this line across rebuilds, so a line keeps its element
  /// (and any animation in flight) when others come and go around it.
  Key get key;
}

/// A section's header: its name ([sectionLabel]) and, but for Needs you, a
/// tap that folds it.
class AgentHeader extends AgentEntry {
  const AgentHeader(this.section, {required this.expanded});

  final BoardSection section;
  final bool expanded;

  AgentStatus get status => section.status;

  /// Whether the person can fold this section. Needs you never folds: a fold
  /// is kept across launches, and a folded Needs you would hide the one loud
  /// section the board exists for.
  bool get collapsible => status != AgentStatus.blocked;

  @override
  Key get key => ValueKey('header/${status.name}');
}

/// A row stays in the list while its section is folded so that it can
/// animate away; it costs one empty box, not a built row.
class AgentLine extends AgentEntry {
  const AgentLine(this.agent, {required this.open, required this.last, this.front = false});

  final AgentRowData agent;
  final bool open;
  final bool last;

  /// The first row of Needs you: the one decision in front, drawn as a card
  /// with its answers. Every other agent is a row: the other waiting agents
  /// are named in rows under it, so one question is in front and the rest are
  /// known, not stacked as cards the thumb has to scroll past.
  final bool front;

  @override
  Key get key => ValueKey(agent.key);
}

/// The place a card held until a moment ago, shrinking to nothing: an agent
/// that stopped waiting leaves Needs you, and the rows below glide up into
/// the gap instead of jumping by a whole card. Only the board adds these, for
/// a fraction of a second; they are not agents and nothing selects them.
class AgentFolding extends AgentEntry {
  const AgentFolding(this.agentKey, this.height);

  final String agentKey;

  /// What the card measured when it left.
  final double height;

  @override
  Key get key => ValueKey('folding/$agentKey');
}

/// How many Idle rows show before the older ones fold behind [AgentMore].
/// Idle is inventory, not a decision: a board with 27 of them buried
/// everything else.
const idleShown = 5;

/// The line that stands for the rows of a section that are folded away ("22
/// more idle", with the names of the first two, so what is inside is not a
/// guess) and opens them in place. It sits after the section's last row;
/// open, it reads "Show less".
class AgentMore extends AgentEntry {
  const AgentMore(this.status, this.hidden, this.names, {required this.open});

  final AgentStatus status;

  /// How many rows the fold holds.
  final int hidden;

  /// The titles of the first rows it holds, to say what is inside.
  final List<String> names;
  final bool open;

  @override
  Key get key => ValueKey('more/${status.name}');
}

/// A session's line, in the section of its status. The board only tells
/// about it (answers are given in the session). [where] is its line under
/// the title ([sessionWhereOnBoard]).
class SessionLine extends AgentEntry {
  const SessionLine(this.session, {required this.open, required this.last, required this.where});

  final AgentSessionView session;
  final bool open;
  final bool last;
  final String where;

  @override
  Key get key => ValueKey('session/${session.key}');
}

/// One row of the board: a terminal agent or an agent session.
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

/// The lines to list: each section's header, then its rows. Needs you never
/// folds, whatever [collapsed] holds ([AgentHeader.collapsible]), and its
/// first row that can be answered is the one in front ([AgentLine.front]).
/// [showMachine]: the board spans several machines, so a session's line says
/// its machine (a terminal agent's [AgentRowData.subtitle] already does).
///
/// Idle shows its newest [idleShown] rows and folds the older ones behind one
/// [AgentMore] line after its rows (opened by [idleOpen]), unless folding
/// would hide a single row; with [idleFold], exactly those rows
/// ([idleFoldFor]: never one the person has seen during this look). The rows
/// are in the list either way, closed, so that they animate away.
List<AgentEntry> boardEntries(
  BoardLayout layout, {
  Set<AgentStatus> collapsed = const {},
  bool idleOpen = false,
  bool showMachine = false,
  Set<String>? idleFold,
}) {
  bool expanded(AgentStatus s) => s == AgentStatus.blocked || !collapsed.contains(s);
  return [
    for (final section in layout.sections) ...[
      AgentHeader(section, expanded: expanded(section.status)),
      ..._sectionLines(
        section,
        open: expanded(section.status),
        foldOpen: idleOpen,
        fold: idleFold,
        showMachine: showMachine,
      ),
    ],
  ];
}

/// The folded sections kept across a reclaimed process: one status name per
/// line ([foldedSectionsText]). A name this version does not know (a project
/// key kept by 0.1.47, a status that went) is ignored, and Needs you never
/// folds, so no restored text can fold it or throw.
Set<AgentStatus> foldedSectionsOf(String text) {
  final names = text.split('\n').toSet();
  return {
    for (final s in AgentStatus.values)
      if (s != AgentStatus.blocked && names.contains(s.name)) s,
  };
}

/// [sections] as [foldedSectionsOf] reads them.
String foldedSectionsText(Set<AgentStatus> sections) => [
  for (final s in AgentStatus.values)
    if (sections.contains(s)) s.name,
].join('\n');

/// The rows the person has seen on the board during this look, by item key
/// ([idleFoldFor]). The board drops it when it is looked at afresh (shown
/// again, the app back from the background).
typedef SeenRows = Set<String>;

String _itemKey(BoardItem item) => switch (item) {
  PaneItem(:final row) => 'p:${row.key}',
  SessionItem(:final session) => 's:${session.key}',
};

String _titleOf(BoardItem item) => switch (item) {
  PaneItem(:final row) => row.title,
  SessionItem(:final session) => session.title,
};

/// The rows the fold would hold now, by index: Idle's rows but the newest
/// [idleShown]. None when folding would hide a single row.
Set<int> _foldNow(BoardSection section) {
  if (section.status != AgentStatus.idle) return const {};
  final n = section.items.length;
  return n > idleShown + 1 ? {for (var i = idleShown; i < n; i++) i} : const {};
}

/// What the Idle fold holds now, by item key: Idle's rows past the newest
/// [idleShown], but never one in [seen], and nothing when that would hide a
/// single row. Adds to [seen] every row of [layout] that it leaves in view.
/// The board calls it on every build and drops [seen] when it is looked at
/// afresh (shown again, the app back from the background).
///
/// Why (owner decision, a predictable board): a fold worked out on every
/// build hid a row the moment another agent went idle, under the person's
/// eyes. A row the person has seen (in Idle or anywhere else) stays in view
/// until the next look; a row they never saw, such as a machine's agents
/// arriving after the board opened, folds as usual.
Set<String> idleFoldFor(BoardLayout layout, SeenRows seen) {
  final idle = layout.section(AgentStatus.idle);
  final hidden = idle == null
      ? <String>{}
      : {
          for (final i in _foldNow(idle))
            if (!seen.contains(_itemKey(idle.items[i]))) _itemKey(idle.items[i]),
        };
  final fold = hidden.length > 1 ? hidden : const <String>{};
  for (final item in layout.items) {
    final key = _itemKey(item);
    if (!fold.contains(key)) seen.add(key);
  }
  return fold;
}

/// The rows of [section] its fold holds, by index: with [fold], those whose
/// key it holds; without, the fold as it would be now.
Set<int> _folded(BoardSection section, Set<String>? fold) {
  if (section.status != AgentStatus.idle) return const {};
  if (fold == null) return _foldNow(section);
  return {
    for (final (i, item) in section.items.indexed)
      if (fold.contains(_itemKey(item))) i,
  };
}

List<AgentEntry> _sectionLines(
  BoardSection section, {
  required bool open,
  required bool foldOpen,
  required bool showMachine,
  Set<String>? fold,
}) {
  final items = section.items;
  final hidden = _folded(section, fold);
  final foldable = hidden.isNotEmpty;
  final folded = foldable && !foldOpen;
  final blocked = section.status == AgentStatus.blocked;

  AgentEntry line(int i) {
    final shown = open && (!folded || !hidden.contains(i));
    final last = i == items.length - 1;
    return switch (items[i]) {
      PaneItem(:final row) => AgentLine(row, open: shown, last: last, front: blocked && i == 0 && !row.stale),
      SessionItem(:final session) => SessionLine(
        session,
        open: shown,
        last: last,
        where: sessionWhereOnBoard(session, showMachine: showMachine),
      ),
    };
  }

  AgentMore more() {
    final inFold = [for (final i in hidden) items[i]];
    return AgentMore(section.status, inFold.length, [
      for (final item in inFold.take(2)) _titleOf(item),
    ], open: foldOpen);
  }

  return [
    for (var i = 0; i < items.length; i++) line(i),
    // After the section's rows, open ("Show less") or closed ("12 more idle").
    if (foldable && open) more(),
  ];
}

/// Entry key to its index, for `findChildIndexCallback`.
Map<Key, int> entryIndexes(List<AgentEntry> entries) => {for (final (i, e) in entries.indexed) e.key: i};

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
