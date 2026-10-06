/// What keeps running after an agent's turn: shell jobs, background
/// terminals, subagents. Pure Dart, no Flutter.
library;

/// What a background task is. The UI picks an icon and a noun from it.
enum BackgroundKind {
  /// A shell command the agent started in the background (`bg_6`).
  shell,

  /// A background terminal (Codex unified exec).
  terminal,

  /// A code cell (omp `eval`).
  eval,

  /// A workflow the agent runs.
  workflow,

  /// A monitor (Claude Code) that watches something.
  monitor,

  /// A subagent the agent started in the background.
  agent,

  /// Anything else an agent reports.
  other,
}

enum BackgroundStatus {
  running,
  paused,
  finished,
  failed,
  stopped;

  /// Still alive: it may yet say something, wake the agent, or need a stop.
  bool get isActive => this == running || this == paused;
}

/// How a stop reaches the agent.
enum StopRoute {
  /// The agent offers no way to stop this task from the phone.
  none,

  /// A protocol request (`_session/async_task/stop`).
  direct,

  /// The phone sends the agent a message asking it to stop the task (omp has
  /// no key or request for it; the model can).
  message,
}

/// One background task. Immutable and value-equal.
class BackgroundTask {
  const BackgroundTask({
    required this.id,
    required this.kind,
    required this.status,
    required this.title,
    this.epoch = 0,
    this.detail,
    this.startedAt,
    this.endedAt,
    this.deadline,
    this.toolCallId,
    this.stop = StopRoute.none,
  });

  /// The agent's own id (`bg_6`, `command-1`, `RLFrameworks`). omp ids restart
  /// with the process, so the id alone is not unique: see [epoch], [key].
  final String id;

  /// Process or session generation the id belongs to; a new one starts when
  /// the agent's process ends.
  final int epoch;

  final BackgroundKind kind;
  final BackgroundStatus status;

  /// The command or the name, raw. The UI passes it through `visibleText()`.
  final String title;

  /// The full command, the working folder or the agent's last summary.
  final String? detail;

  /// By this client's clock. Null when the task came from a replay.
  final DateTime? startedAt;
  final DateTime? endedAt;

  /// How long the agent lets it run (omp bash `timeoutSeconds`); null when
  /// there is no limit or it is not known.
  final Duration? deadline;

  /// The transcript row that started it.
  final String? toolCallId;

  final StopRoute stop;

  /// Unique within a session.
  String get key => '$epoch/$id';

  bool get isActive => status.isActive;

  /// Running past its own deadline: the agent kills such a job and says so, and
  /// when it did not reach us the task is stale rather than running.
  bool pastDeadline(DateTime now, {Duration grace = const Duration(seconds: 60)}) {
    final start = startedAt;
    final limit = deadline;
    if (start == null || limit == null || !isActive) return false;
    return now.difference(start) > limit + grace;
  }

  BackgroundTask copyWith({
    BackgroundKind? kind,
    BackgroundStatus? status,
    String? title,
    String? detail,
    DateTime? endedAt,
    StopRoute? stop,
  }) => BackgroundTask(
    id: id,
    epoch: epoch,
    kind: kind ?? this.kind,
    status: status ?? this.status,
    title: title ?? this.title,
    detail: detail ?? this.detail,
    startedAt: startedAt,
    endedAt: endedAt ?? this.endedAt,
    deadline: deadline,
    toolCallId: toolCallId,
    stop: stop ?? this.stop,
  );

  @override
  bool operator ==(Object other) =>
      other is BackgroundTask &&
      other.id == id &&
      other.epoch == epoch &&
      other.kind == kind &&
      other.status == status &&
      other.title == title &&
      other.detail == detail &&
      other.startedAt == startedAt &&
      other.endedAt == endedAt &&
      other.deadline == deadline &&
      other.toolCallId == toolCallId &&
      other.stop == stop;

  @override
  int get hashCode =>
      Object.hash(id, epoch, kind, status, title, detail, startedAt, endedAt, deadline, toolCallId, stop);

  @override
  String toString() => 'BackgroundTask($key ${kind.name} ${status.name} $title)';
}

/// What a session says about its background tasks. Immutable; a session hands
/// out the same instance until something changes, so widgets compare by
/// identity.
class BackgroundWork {
  BackgroundWork({
    this.tasks = const [],
    this.wakes = false,
    this.wakeLabel,
    this.unknownRunning = false,
  });

  /// The nothing: the same instance for every session without tasks.
  static final BackgroundWork empty = BackgroundWork();

  /// In order of appearance. Finished ones stay for a while (the owner of the
  /// list trims them); the UI splits them by [BackgroundTask.isActive].
  final List<BackgroundTask> tasks;

  /// Finishing a task starts a turn by itself (omp, Claude Code). False for
  /// Codex, where the agent only learns of it on its next turn.
  final bool wakes;

  /// Who wakes, for the sentence (`omp`, `Claude`); null when [wakes] is false.
  final String? wakeLabel;

  /// The agent is known to wait for something in the background but the list
  /// is empty or incomplete (the log lost it). Shown as `details unavailable`.
  final bool unknownRunning;

  late final List<BackgroundTask> running = List.unmodifiable(tasks.where((t) => t.isActive));

  late final List<BackgroundTask> finished = List.unmodifiable(tasks.where((t) => !t.isActive));

  /// Running tasks the phone has any way to stop.
  late final List<BackgroundTask> stoppable = List.unmodifiable(running.where((t) => t.stop != StopRoute.none));

  int get runningCount => running.length;

  bool get hasRunning => running.isNotEmpty || unknownRunning;

  bool get isEmpty => tasks.isEmpty && !unknownRunning;

  /// The oldest start among running tasks with a known start: what the status
  /// line counts from.
  DateTime? get oldestStart {
    DateTime? oldest;
    for (final t in running) {
      final s = t.startedAt;
      if (s != null && (oldest == null || s.isBefore(oldest))) oldest = s;
    }
    return oldest;
  }

  BackgroundTask? byId(String id) {
    for (final t in tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  BackgroundWork copyWith({List<BackgroundTask>? tasks, bool? wakes, String? wakeLabel, bool? unknownRunning}) =>
      BackgroundWork(
        tasks: tasks ?? this.tasks,
        wakes: wakes ?? this.wakes,
        wakeLabel: wakeLabel ?? this.wakeLabel,
        unknownRunning: unknownRunning ?? this.unknownRunning,
      );
}

/// The answer to a stop request. Never an exception: a stop is one of the few
/// things the person does to something that may already be gone.
sealed class BackgroundStopResult {
  const BackgroundStopResult();
}

/// It stopped (a protocol answer), or the message that asks for it went out.
class BackgroundStopped extends BackgroundStopResult {
  const BackgroundStopped({this.asked = false});

  /// The route was a message: the agent has been asked, nothing is confirmed
  /// until the task leaves the running set.
  final bool asked;
}

/// It had already ended.
class BackgroundAlreadyDone extends BackgroundStopResult {
  const BackgroundAlreadyDone();
}

/// This task has no stop route.
class BackgroundNotStoppable extends BackgroundStopResult {
  const BackgroundNotStoppable();
}

class BackgroundStopFailed extends BackgroundStopResult {
  const BackgroundStopFailed(this.reason);

  /// In words for the person.
  final String reason;
}

/// Ids come from an agent's log or wire; they go into a message to the agent.
/// Only plain tokens pass.
final RegExp _safeId = RegExp(r'^[A-Za-z0-9_.:-]{1,64}$');

bool isSafeBackgroundId(String id) => _safeId.hasMatch(id);

/// The message that asks omp to stop [ids] (`write proc://<id>/kill`). Null when
/// there is nothing to ask or an id is not a plain token.
String? stopMessageForOmp(Iterable<String> ids) {
  final list = ids.toList();
  if (list.isEmpty || list.any((id) => !isSafeBackgroundId(id))) return null;
  final calls = list.map((id) => '$id (write proc://$id/kill)').join(', ');
  final noun = list.length == 1 ? 'job' : 'jobs';
  return 'Stop these background $noun now: $calls. Do nothing else.';
}
