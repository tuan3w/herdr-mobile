import '../acp_models.dart';
import 'run_facts.dart';
import 'subagent_run.dart';

/// An update from a subagent whose run is not known yet (the update came
/// before the call that starts it), kept until that call arrives.
class HeldUpdate {
  const HeldUpdate(this.parentId, this.update, this.at);

  final String parentId;
  final SessionUpdate update;

  /// When it arrived by the caller's clock; null in a replay.
  final DateTime? at;
}

/// The subagents of one session, as the reducer keeps them: the runs in the
/// order they first appeared, which tool call belongs to which subagent, and
/// the updates that wait for their run. Immutable: every change makes a new
/// book, sharing what did not change (the runs list is the same instance
/// while no run changed, which is what `SubagentSummary.of` memoizes on).
class SubagentBook {
  const SubagentBook({
    this.runs = const [],
    this.owners = const {},
    this.held = const [],
    this.aliases = const {},
    this.scanned = const {},
  });

  /// In order of first appearance; never reordered.
  final List<SubagentRun> runs;

  /// Tool call id of a subagent's own call to the id of the run (or of the
  /// parent still to come) it belongs to. Late updates of such a call carry
  /// no tag, and are routed by this.
  final Map<String, String> owners;

  /// Waiting for their run, oldest first, at most [maxHeld].
  final List<HeldUpdate> held;

  /// OpenCode names a child by its own session id, not by the call that
  /// launched it: child session id to the id of the run (the launching call)
  /// it was bound to, when its first update arrived or the call completed.
  final Map<String, String> aliases;

  /// Child session ids that found no launcher to bind to, each with the
  /// transcript items it looked through: while those are the same list there
  /// is nothing new to find, so its next update does not look again.
  final Map<String, Object> scanned;

  /// The most updates held; the oldest are dropped past it (a parent that
  /// never comes must not grow memory).
  static const maxHeld = 500;

  bool get isEmpty => runs.isEmpty && owners.isEmpty && held.isEmpty && aliases.isEmpty;

  SubagentBook _with({
    List<SubagentRun>? runs,
    Map<String, String>? owners,
    List<HeldUpdate>? held,
    Map<String, String>? aliases,
    Map<String, Object>? scanned,
  }) => SubagentBook(
    runs: runs ?? this.runs,
    owners: owners ?? this.owners,
    held: held ?? this.held,
    aliases: aliases ?? this.aliases,
    scanned: scanned ?? this.scanned,
  );

  int indexOf(String id) {
    for (var i = 0; i < runs.length; i++) {
      if (runs[i].id == id) return i;
    }
    return -1;
  }

  SubagentRun? run(String id) {
    final i = indexOf(id);
    return i < 0 ? null : runs[i];
  }

  /// The run [id] in place, or at the end when it is new.
  SubagentBook withRun(SubagentRun run) {
    final i = indexOf(run.id);
    final next = List<SubagentRun>.of(runs);
    if (i < 0) {
      next.add(run);
    } else {
      next[i] = run;
    }
    return _with(runs: next);
  }

  SubagentBook withRuns(List<SubagentRun> next) => _with(runs: next);

  SubagentBook withOwner(String toolCallId, String parentId) =>
      owners[toolCallId] == parentId ? this : _with(owners: {...owners, toolCallId: parentId});

  /// The child session [childId] belongs to the run [runId].
  SubagentBook withAlias(String childId, String runId) =>
      aliases[childId] == runId ? this : _with(aliases: {...aliases, childId: runId});

  /// Every alias [changes] names, at once.
  SubagentBook withAliases(Map<String, String> changes) => _with(aliases: {...aliases, ...changes});

  /// The calls owned by the run [a] go to [b] and the other way round (the two
  /// runs traded their conversations).
  SubagentBook withOwnersSwapped(String a, String b) =>
      _with(owners: {for (final e in owners.entries) e.key: e.value == a ? b : (e.value == b ? a : e.value)});

  /// The child [childId] looked through [items] and found no launcher.
  SubagentBook withScanned(String childId, Object items) => _with(scanned: {...scanned, childId: items});

  bool hasHeldFor(String parentId) => held.any((h) => h.parentId == parentId);

  SubagentBook withHeld(HeldUpdate update) {
    final next = [...held, update];
    return _with(held: next.length > maxHeld ? next.sublist(next.length - maxHeld) : next);
  }

  /// The updates held for [parentId], oldest first, and the book without them.
  (SubagentBook, List<HeldUpdate>) takeHeld(String parentId) {
    final mine = <HeldUpdate>[];
    final rest = <HeldUpdate>[];
    for (final h in held) {
      (h.parentId == parentId ? mine : rest).add(h);
    }
    return (_with(held: rest), mine);
  }
}

/// The run [facts] describe: [old] with what the facts name laid over it, or a
/// new run. [startedAt] is when the call that starts it was first seen; [now]
/// the clock of the update (null in a replay), which becomes [SubagentRun.finishedAt]
/// the first time the run is seen over.
SubagentRun runFromFacts(
  RunFacts f, {
  SubagentRun? old,
  required String parentToolCallId,
  String? parentRunId,
  DateTime? startedAt,
  DateTime? now,
}) {
  final base =
      old ??
      SubagentRun(
        id: f.id,
        route: f.route,
        parentToolCallId: parentToolCallId,
        parentRunId: parentRunId,
        startedAt: startedAt,
      );
  final over = !f.status.isActive;
  final DateTime? finishedAt = over ? (old == null || old.status.isActive ? now : old.finishedAt) : null;
  final count = f.toolCount;
  return base.copyWith(
    name: f.name,
    title: f.title ?? (old == null ? f.name : null),
    agentType: f.agentType,
    assignment: f.assignment,
    status: f.status,
    startedAt: base.startedAt == null ? startedAt : null,
    finishedAt: finishedAt,
    reportedElapsed: f.reportedElapsed,
    totalElapsed: f.totalElapsed,
    toolCount: count != null && count > base.toolCount ? count : null,
    tokens: f.tokens,
    cost: f.cost,
    model: f.model,
    percent: f.percent,
    lastTool: f.lastTool,
    lastToolLine: f.lastToolLine,
    recentTools: f.recentTools,
    recentOutput: f.recentOutput,
    note: f.note,
    result: f.result,
    failure:
        f.failure ?? (f.status == SubagentStatus.failed || f.status == SubagentStatus.cancelled ? base.failure : null),
    retry: f.retry ?? (f.clearRetry || over ? null : base.retry),
    background: f.background,
  );
}
