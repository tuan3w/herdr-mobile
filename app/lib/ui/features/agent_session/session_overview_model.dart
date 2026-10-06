import '../../../data/acp/acp_models.dart';
import '../../../data/acp/session_state.dart';
import '../../../data/acp/turns/turns.dart';

/// How many files and commands the overview lists before `N more`.
const overviewFiles = 8;
const overviewCommands = 5;

/// The parts of the session overview that come from the transcript: the goal,
/// the files changed across the whole session and the commands it ran. Built
/// from the per-turn summaries ([Turn.changed], [Turn.commands]) that the
/// folds already compute, and memoized per transcript list, so a chunk of
/// streaming text costs nothing and a new tool call costs its own turn.
class SessionOverviewModel {
  const SessionOverviewModel({
    required this.goal,
    required this.files,
    required this.added,
    required this.removed,
    required this.commands,
    required this.commandCount,
    required this.failedCommands,
  });

  /// The first message of the person, whole (the view cuts it); null when
  /// the person has not written yet.
  final String? goal;

  /// Every file the session changed, one entry per path, in the order first
  /// touched. Counts are summed over the turns that touched it.
  final List<ChangedFile> files;
  final int added;
  final int removed;

  /// At most [overviewCommands]: the failed ones first (newest first), then
  /// the newest of the others.
  final List<CommandRun> commands;
  final int commandCount;
  final int failedCommands;
}

final _models = Expando<SessionOverviewModel>('session overview');

/// The overview parts of [items]; memoized by list identity.
SessionOverviewModel overviewOf(List<TranscriptItem> items) => _models[items] ??= _build(items);

SessionOverviewModel _build(List<TranscriptItem> items) {
  final turns = turnsOf(items);
  String? goal;
  final order = <String>[];
  final byPath = <String, _Merge>{};
  final commands = <CommandRun>[];
  for (final turn in turns) {
    goal ??= _text(turn.user);
    for (final f in turn.changed) {
      var merge = byPath[f.path];
      if (merge == null) {
        merge = byPath[f.path] = _Merge();
        order.add(f.path);
      }
      merge.take(f);
    }
    commands.addAll(turn.commands);
  }
  final files = [for (final p in order) byPath[p]!.file(p)];
  var added = 0, removed = 0;
  for (final f in files) {
    added += f.added;
    removed += f.removed;
  }
  final failed = [for (final c in commands.reversed) if (c.failed) c];
  final rest = [for (final c in commands.reversed) if (!c.failed) c];
  return SessionOverviewModel(
    goal: goal,
    files: files,
    added: added,
    removed: removed,
    commands: [...failed, ...rest].take(overviewCommands).toList(growable: false),
    commandCount: commands.length,
    failedCommands: failed.length,
  );
}

String? _text(TranscriptMessage? m) {
  if (m == null) return null;
  final t = m.text.trim();
  return t.isEmpty ? null : t;
}

/// One path across turns.
class _Merge {
  int added = 0, removed = 0;
  bool isNew = false, isDelete = false, first = true;
  final diffs = <ToolDiff>[];

  void take(ChangedFile f) {
    added += f.added;
    removed += f.removed;
    if (first) isNew = f.isNew;
    first = false;
    // A later turn that wrote the file again undoes an earlier delete.
    isDelete = f.isDelete;
    diffs.addAll(f.diffs);
  }

  ChangedFile file(String path) => ChangedFile(
    path: path,
    added: added,
    removed: removed,
    isNew: isNew,
    isDelete: isDelete,
    diffs: List.unmodifiable(diffs),
  );
}

/// How far the plan is: steps done of all, and the step to look at (the one
/// in progress, else the first not done); null for no plan.
({int done, int total, String? current})? planProgress(List<PlanEntry> plan) {
  if (plan.isEmpty) return null;
  final done = plan.where((e) => e.status == PlanStatus.completed).length;
  PlanEntry? current;
  for (final e in plan) {
    if (e.status == PlanStatus.inProgress) {
      current = e;
      break;
    }
  }
  current ??= plan.where((e) => e.status == PlanStatus.pending).firstOrNull;
  final text = current?.content.trim();
  return (done: done, total: plan.length, current: text == null || text.isEmpty ? null : text);
}

/// The share of the context window in use, 0..1; null when the agent reports
/// no window.
double? contextFraction(AcpUsage? usage) => usage?.fraction;

/// The context warning of the bar fires from here.
const contextWarnAt = 0.85;

/// `91` when the context is at least [contextWarnAt] full, else null (no
/// usage, no size, or room left): the bar says nothing then.
int? contextWarning(AcpUsage? usage) {
  final f = contextFraction(usage);
  if (f == null || f < contextWarnAt) return null;
  return (f * 100).round().clamp(0, 100);
}
