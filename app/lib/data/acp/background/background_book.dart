import '../acp_models.dart';
import 'background_work.dart';
import 'omp_jobs.dart';

/// The background tasks of one ACP session, as the reducer keeps them.
/// Immutable: a change makes a new book with a new [tasks] list, no change
/// returns the same book, so the list can be compared and memoized by
/// identity (the way `SubagentBook.runs` is).
///
/// Four sources, one set of rules:
/// - AIR `async_task_*` updates (Codex; Claude Code when the client declares
///   `asyncTasks`): [withSpawned], [withProgress], [withState].
/// - Claude Code's raw `background_tasks_changed` (a level: the whole live
///   set) and `task_notification` (an edge): [withSdkTasks], [withSdkNotification].
/// - omp's tool results: [withOmpFact].
///
/// Rules: an update for an id nobody announced makes the task (the spawn may
/// have been lost, or came before a replay began); a task that ended stays
/// ended, so a late progress never revives it; a time is this client's clock at
/// first sight or at the end, and null in a replay; only the newest
/// [maxFinished] ended tasks are kept, and at most [maxTasks] in all.
class BackgroundBook {
  const BackgroundBook({this.tasks = const [], this.inferred = const {}});

  static const maxFinished = 20;
  static const maxTasks = 200;

  /// In order of first sight; never reordered.
  final List<BackgroundTask> tasks;

  /// Ids of the tasks whose end was only concluded from the task leaving
  /// Claude's live set. The agent's own word about how it ended
  /// ([withSdkNotification]) may still correct these.
  final Set<String> inferred;

  bool get isEmpty => tasks.isEmpty;

  int _index(String id) {
    for (var i = 0; i < tasks.length; i++) {
      if (tasks[i].id == id) return i;
    }
    return -1;
  }

  BackgroundTask? task(String id) {
    final i = _index(id);
    return i < 0 ? null : tasks[i];
  }

  /// AIR `async_task_spawned`.
  BackgroundBook withSpawned(AsyncTaskSpawned u, {DateTime? now}) {
    final old = task(u.asyncTaskId);
    if (old != null && !old.isActive) return this;
    final name = u.name.isNotEmpty ? u.name : (u.description ?? u.asyncTaskId);
    final description = u.description;
    return _put(
      BackgroundTask(
        id: u.asyncTaskId,
        kind: kindOfTaskType(u.taskType),
        status: old?.status ?? BackgroundStatus.running,
        title: name,
        detail: description != null && description.isNotEmpty && description != name ? description : old?.detail,
        startedAt: old?.startedAt ?? now,
        toolCallId: u.toolCallId ?? old?.toolCallId,
        stop: u.canStop ? StopRoute.direct : StopRoute.none,
      ),
    );
  }

  /// AIR `async_task_progress`.
  BackgroundBook withProgress(AsyncTaskProgress u, {DateTime? now}) {
    final old = task(u.asyncTaskId);
    if (old != null && !old.isActive) return this;
    final said = u.summary ?? u.description;
    if (old == null) {
      return _put(
        BackgroundTask(
          id: u.asyncTaskId,
          kind: BackgroundKind.other,
          status: BackgroundStatus.running,
          title: u.description ?? u.asyncTaskId,
          detail: u.summary,
          startedAt: now,
          toolCallId: u.toolCallId,
        ),
      );
    }
    final detail = said != null && said != old.title ? said : old.detail;
    if (detail == old.detail && (u.toolCallId == null || u.toolCallId == old.toolCallId)) return this;
    return _put(
      BackgroundTask(
        id: old.id,
        epoch: old.epoch,
        kind: old.kind,
        status: old.status,
        title: old.title,
        detail: detail,
        startedAt: old.startedAt,
        endedAt: old.endedAt,
        deadline: old.deadline,
        toolCallId: u.toolCallId ?? old.toolCallId,
        stop: old.stop,
      ),
    );
  }

  /// AIR `async_task_state_update`.
  BackgroundBook withState(AsyncTaskStateUpdate u, {DateTime? now}) {
    final old = task(u.asyncTaskId);
    if (u.state.isTerminal) {
      return _end(u.asyncTaskId, _statusOf(u.state), summary: u.summary, toolCallId: u.toolCallId, now: now);
    }
    final status = u.state == AsyncTaskState.paused ? BackgroundStatus.paused : BackgroundStatus.running;
    if (old == null) {
      return _put(
        BackgroundTask(
          id: u.asyncTaskId,
          kind: BackgroundKind.other,
          status: status,
          title: u.asyncTaskId,
          detail: u.summary,
          startedAt: now,
          toolCallId: u.toolCallId,
        ),
      );
    }
    if (!old.isActive || (old.status == status && u.summary == null)) return this;
    return _put(old.copyWith(status: status, detail: u.summary));
  }

  /// Claude Code's `background_tasks_changed`: [u] is every live background
  /// task. Subagents (`local_agent`: the subagent roster has them) and
  /// ambient entries are left out. A known task that is not in it any more
  /// has ended (how is unknown until a `task_notification` says).
  BackgroundBook withSdkTasks(SdkBackgroundTasks u, {DateTime? now}) {
    var book = this;
    final present = {for (final t in u.tasks) t.taskId};
    for (final t in u.tasks) {
      if (t.ambient || t.taskType == 'local_agent') continue;
      final old = book.task(t.taskId);
      if (old == null) {
        book = book._put(
          BackgroundTask(
            id: t.taskId,
            kind: kindOfSdkTaskType(t.taskType),
            status: BackgroundStatus.running,
            title: t.description.isEmpty ? t.taskId : t.description,
            startedAt: now,
          ),
        );
      } else if (!old.isActive && book.inferred.contains(t.taskId)) {
        // The level proves it alive after all.
        book = book._put(old.copyWith(status: BackgroundStatus.running));
      }
    }
    for (final old in book.tasks.toList()) {
      if (old.isActive && !present.contains(old.id)) {
        book = book._end(old.id, BackgroundStatus.finished, now: now, concluded: true);
      }
    }
    return book;
  }

  /// Claude Code's `task_notification`: how a task ended. Only a task the
  /// level announced counts (a subagent's end is not ours).
  BackgroundBook withSdkNotification(SdkTaskNotification u, {DateTime? now}) {
    if (u.ambient || task(u.taskId) == null) return this;
    return _end(u.taskId, _statusOf(u.status), summary: u.summary, now: now);
  }

  /// A job omp's tool results mention.
  BackgroundBook withOmpFact(OmpJobFact f, {String? toolCallId, DateTime? now}) {
    switch (f) {
      case OmpJobStarted():
        final old = task(f.jobId);
        if (old != null) return this;
        return _put(
          BackgroundTask(
            id: f.jobId,
            kind: f.kind,
            status: BackgroundStatus.running,
            title: f.title,
            detail: f.detail,
            startedAt: now,
            deadline: f.deadline,
            toolCallId: toolCallId,
            stop: StopRoute.message,
          ),
        );
      case OmpJobEnded():
        // A listing names jobs this session never started; only ours end.
        if (task(f.jobId) == null) return this;
        return _end(f.jobId, f.status, now: now);
    }
  }

  /// [id] ended as [status] (never a still-active one). An ended task stays as
  /// it is, except one only concluded ended, which the agent's word replaces.
  BackgroundBook _end(
    String id,
    BackgroundStatus status, {
    String? summary,
    String? toolCallId,
    DateTime? now,
    bool concluded = false,
  }) {
    final old = task(id);
    if (old == null) {
      return _put(
        BackgroundTask(
          id: id,
          kind: BackgroundKind.other,
          status: status,
          title: id,
          detail: summary,
          endedAt: now,
          toolCallId: toolCallId,
        ),
        inferredEnd: concluded,
      );
    }
    if (!old.isActive && !(inferred.contains(id) && !concluded)) return this;
    return _put(
      BackgroundTask(
        id: old.id,
        epoch: old.epoch,
        kind: old.kind,
        status: status,
        title: old.title,
        detail: summary != null && summary.isNotEmpty ? summary : old.detail,
        startedAt: old.startedAt,
        endedAt: old.endedAt ?? now,
        deadline: old.deadline,
        toolCallId: toolCallId ?? old.toolCallId,
        // Nothing left to stop.
        stop: StopRoute.none,
      ),
      inferredEnd: concluded,
    );
  }

  /// [t] in place of the task with its id, or at the end; the book trimmed.
  BackgroundBook _put(BackgroundTask t, {bool inferredEnd = false}) {
    final i = _index(t.id);
    final mark = inferredEnd && !t.isActive;
    if (i >= 0 && tasks[i] == t && inferred.contains(t.id) == mark) return this;
    final next = List<BackgroundTask>.of(tasks);
    if (i < 0) {
      next.add(t);
    } else {
      next[i] = t;
    }
    final marks = {...inferred};
    if (mark) {
      marks.add(t.id);
    } else {
      marks.remove(t.id);
    }
    return BackgroundBook(tasks: _trim(next, marks), inferred: marks);
  }

  /// At most [maxFinished] ended tasks (the oldest go first) and [maxTasks] in
  /// all. [marks] loses the ids that went.
  static List<BackgroundTask> _trim(List<BackgroundTask> list, Set<String> marks) {
    var ended = list.where((t) => !t.isActive).length;
    if (ended <= maxFinished && list.length <= maxTasks) return list;
    final out = <BackgroundTask>[];
    var over = list.length - maxTasks;
    for (final t in list) {
      final dropEnded = !t.isActive && (ended > maxFinished || over > 0);
      if (dropEnded) {
        ended--;
        over--;
        marks.remove(t.id);
        continue;
      }
      out.add(t);
    }
    // Only running tasks past the cap are left: the oldest go.
    if (out.length > maxTasks) {
      for (final t in out.sublist(0, out.length - maxTasks)) {
        marks.remove(t.id);
      }
      return out.sublist(out.length - maxTasks);
    }
    return out;
  }

  /// What [taskType] of an AIR `async_task_spawned` is.
  static BackgroundKind kindOfTaskType(String taskType) => switch (taskType) {
    'shell' => BackgroundKind.shell,
    'terminal' => BackgroundKind.terminal,
    'workflow' => BackgroundKind.workflow,
    'monitor' => BackgroundKind.monitor,
    'agent' || 'subagent' => BackgroundKind.agent,
    _ => BackgroundKind.other,
  };

  /// What [taskType] of an SDK background task is.
  static BackgroundKind kindOfSdkTaskType(String taskType) => switch (taskType) {
    'local_bash' => BackgroundKind.shell,
    'local_workflow' => BackgroundKind.workflow,
    'local_monitor' => BackgroundKind.monitor,
    _ => BackgroundKind.other,
  };

  static BackgroundStatus _statusOf(AsyncTaskState s) => switch (s) {
    AsyncTaskState.running => BackgroundStatus.running,
    AsyncTaskState.paused => BackgroundStatus.paused,
    AsyncTaskState.completed => BackgroundStatus.finished,
    AsyncTaskState.failed => BackgroundStatus.failed,
    AsyncTaskState.stopped => BackgroundStatus.stopped,
  };
}
