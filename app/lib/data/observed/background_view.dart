import '../acp/background/background_work.dart';
import '../models/herdr_models.dart' show AgentStatus;

/// What a terminal session says about its background work, decided from three
/// witnesses that can disagree: the agent's log (the tasks, whether the turn
/// is over), herdr (whether the pane shows the agent busy) and the clock.
/// Cross-check with herdr once the turn ended: herdr `idle`/`done` means
/// nothing can wake the agent (waking tasks show as ended, not counted);
/// herdr `working` means waiting on background work, even with no tasks listed.
///
/// Pure: the session hands in what it knows and gets back the work and the
/// one bit the composer and status line read.
class BackgroundView {
  const BackgroundView(this.work, this.waiting);

  /// Nothing in the background, not waiting.
  static final BackgroundView none = BackgroundView(BackgroundWork.empty, false);

  final BackgroundWork work;

  /// The turn is over, the agent is still busy in herdr's eyes and will go on
  /// by itself: Send, not Stop.
  final bool waiting;

  /// [herdr] is the pane's status, null when it is not known (the machine is
  /// out of reach, the pane is gone). [watchedRunning] holds the ids of
  /// subagent tasks that the subagent roster independently confirms running
  /// (it reads the subagents' own files): the log alone is not trusted to
  /// tell a subagent that ended unseen.
  ///
  /// - A task past its own deadline is `ended?` (the agent kills it and says
  ///   so; when that did not reach the log it is stale).
  /// - herdr `idle`/`done` and [turnEnded]: nothing is working and nothing is
  ///   owed to the agent, so a task the log still calls running was ended
  ///   where the log cannot see it (a stop from the agent's own UI, a kill).
  ///   It is `ended?` too, unless [watchedRunning] vouches for it.
  ///
  ///   An `ended?` task is NOT counted and not dropped: it becomes
  ///   [BackgroundStatus.stopped] (no end time, no stop route), so the person
  ///   still sees it in the finished list rather than a job that vanished.
  ///   `stopped` is the nearest of the model's states; the log never said so.
  /// - herdr `working` and [turnEnded]: the agent is waiting on something. It
  ///   is [waiting], even when the log lists no running task
  ///   ([BackgroundWork.unknownRunning], "details unavailable").
  /// - herdr `working` and not [turnEnded]: a normal turn. The tasks are
  ///   listed, nothing waits. `blocked`, `idle`, `done` and an unknown pane
  ///   never wait.
  static BackgroundView derive({
    required AgentStatus? herdr,
    required bool turnEnded,
    required List<BackgroundTask> tasks,
    required DateTime now,
    required String wakeLabel,
    Set<String> watchedRunning = const {},
  }) {
    final working = herdr == AgentStatus.working;
    final nothingWorks = turnEnded && (herdr == AgentStatus.idle || herdr == AgentStatus.done);
    final waiting = working && turnEnded;
    if (tasks.isEmpty) {
      return waiting ? BackgroundView(BackgroundWork(wakes: true, wakeLabel: wakeLabel, unknownRunning: true), true) : none;
    }

    var changed = false;
    final shown = <BackgroundTask>[];
    for (final t in tasks) {
      final unseenEnd =
          t.isActive &&
          (t.pastDeadline(now) || (nothingWorks && !(t.kind == BackgroundKind.agent && watchedRunning.contains(t.id))));
      if (unseenEnd) {
        changed = true;
        shown.add(t.copyWith(status: BackgroundStatus.stopped, stop: StopRoute.none));
      } else {
        shown.add(t);
      }
    }
    final list = changed ? shown : tasks;
    final anyRunning = list.any((t) => t.isActive);
    return BackgroundView(
      BackgroundWork(tasks: list, wakes: true, wakeLabel: wakeLabel, unknownRunning: waiting && !anyRunning),
      waiting,
    );
  }

  /// Both views say the same, so the older work instance can stay.
  bool sameAs(BackgroundView other) =>
      waiting == other.waiting &&
      work.wakes == other.work.wakes &&
      work.wakeLabel == other.work.wakeLabel &&
      work.unknownRunning == other.work.unknownRunning &&
      _sameTasks(work.tasks, other.work.tasks);

  static bool _sameTasks(List<BackgroundTask> a, List<BackgroundTask> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
