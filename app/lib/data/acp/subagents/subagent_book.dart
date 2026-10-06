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
  const SubagentBook({this.runs = const [], this.owners = const {}, this.held = const []});

  /// In order of first appearance; never reordered.
  final List<SubagentRun> runs;

  /// Tool call id of a subagent's own call to the id of the run (or of the
  /// parent still to come) it belongs to. Late updates of such a call carry
  /// no tag, and are routed by this.
  final Map<String, String> owners;

  /// Waiting for their run, oldest first, at most [maxHeld].
  final List<HeldUpdate> held;

  /// The most updates held; the oldest are dropped past it (a parent that
  /// never comes must not grow memory).
  static const maxHeld = 500;

  bool get isEmpty => runs.isEmpty && owners.isEmpty && held.isEmpty;

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
    return SubagentBook(runs: next, owners: owners, held: held);
  }

  SubagentBook withRuns(List<SubagentRun> next) => SubagentBook(runs: next, owners: owners, held: held);

  SubagentBook withOwner(String toolCallId, String parentId) =>
      owners[toolCallId] == parentId ? this : SubagentBook(runs: runs, owners: {...owners, toolCallId: parentId}, held: held);

  bool hasHeldFor(String parentId) => held.any((h) => h.parentId == parentId);

  SubagentBook withHeld(HeldUpdate update) {
    final next = [...held, update];
    return SubagentBook(
      runs: runs,
      owners: owners,
      held: next.length > maxHeld ? next.sublist(next.length - maxHeld) : next,
    );
  }

  /// The updates held for [parentId], oldest first, and the book without them.
  (SubagentBook, List<HeldUpdate>) takeHeld(String parentId) {
    final mine = <HeldUpdate>[];
    final rest = <HeldUpdate>[];
    for (final h in held) {
      (h.parentId == parentId ? mine : rest).add(h);
    }
    return (SubagentBook(runs: runs, owners: owners, held: rest), mine);
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
      SubagentRun(id: f.id, route: f.route, parentToolCallId: parentToolCallId, parentRunId: parentRunId, startedAt: startedAt);
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
    failure: f.failure ?? (f.status == SubagentStatus.failed || f.status == SubagentStatus.cancelled ? base.failure : null),
    retry: f.retry ?? (f.clearRetry || over ? null : base.retry),
    background: f.background,
  );
}
