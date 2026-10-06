import '../../../data/acp/background/background_work.dart';
import 'visible_text.dart';

/// Words for background work. Pure: every sentence the strip, the bar, the
/// status line, the toast and the sheet say comes from here, so the words for
/// each state live in one place.

/// `bash`, `terminal`, `subagent`: the kind of [task] as a word in a meta line.
String kindWord(BackgroundKind kind) => switch (kind) {
  BackgroundKind.shell => 'bash',
  BackgroundKind.terminal => 'terminal',
  BackgroundKind.eval => 'eval',
  BackgroundKind.workflow => 'workflow',
  BackgroundKind.monitor => 'monitor',
  BackgroundKind.agent => 'subagent',
  BackgroundKind.other => 'task',
};

/// `1 job`, `2 jobs`, `1 background terminal`, `3 background tasks` (a mix of
/// kinds, or nothing more specific to say). Counts [tasks] as given.
String nounPhrase(Iterable<BackgroundTask> tasks) {
  final list = tasks.toList();
  final n = list.length;
  final kinds = {for (final t in list) t.kind};
  final plural = n != 1;
  if (kinds.length == 1) {
    final word = switch (kinds.single) {
      BackgroundKind.shell || BackgroundKind.eval => plural ? 'jobs' : 'job',
      BackgroundKind.terminal => plural ? 'background terminals' : 'background terminal',
      BackgroundKind.agent => plural ? 'subagents' : 'subagent',
      BackgroundKind.workflow => plural ? 'workflows' : 'workflow',
      BackgroundKind.monitor => plural ? 'monitors' : 'monitor',
      BackgroundKind.other => plural ? 'background tasks' : 'background task',
    };
    return '$n $word';
  }
  // Shell commands and evals are both "jobs" to the person.
  if (kinds.every((k) => k == BackgroundKind.shell || k == BackgroundKind.eval)) {
    return '$n ${plural ? 'jobs' : 'job'}';
  }
  return '$n ${plural ? 'background tasks' : 'background task'}';
}

/// `42s`, `14m`, `4h 36m`: how long a job has run, by the minute (the labels
/// that show it move on the minute clock, never per second).
String backgroundElapsed(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  if (s < 60) return '${s}s';
  final m = s ~/ 60;
  if (m < 60) return '${m}m';
  return '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
}

/// The one running task's id (`bg_6`), shortened in the middle past
/// [maxLength]; `2 jobs` for several; null when nothing is known to run.
/// What `Waiting for ...` and `Waiting · ...` name.
String? waitingSubject(BackgroundWork work, {int maxLength = 24}) {
  final running = work.running;
  if (running.isEmpty) return null;
  if (running.length > 1) return nounPhrase(running);
  return shorten(visibleText(running.single.id).trim(), maxLength);
}

/// [text] cut in the middle to [max] characters (`bg_loooo…ng_6`), so the end
/// of an id, which tells ids apart, stays.
String shorten(String text, int max) {
  if (text.length <= max || max < 3) return text;
  final head = (max - 1) ~/ 2 + (max - 1) % 2;
  final tail = (max - 1) - head;
  return '${_cut(text, head)}\u2026${text.substring(text.length - tail)}';
}

String _cut(String text, int end) {
  if (end <= 0) return '';
  // Not between the two halves of a surrogate pair.
  final unit = text.codeUnitAt(end - 1);
  return text.substring(0, unit >= 0xD800 && unit <= 0xDBFF ? end - 1 : end);
}

/// `Waiting for bg_6`, `Waiting for 2 jobs`, `Waiting for background work`.
String waitingSentence(BackgroundWork work) {
  final subject = waitingSubject(work);
  return subject == null ? 'Waiting for background work' : 'Waiting for $subject';
}

/// `omp continues by itself when it finishes`: the consequence line of the
/// strip. Null when finishing does not start a turn (Codex).
String? wakeLine(BackgroundWork work) {
  if (!work.wakes) return null;
  final who = work.wakeLabel ?? 'The agent';
  return work.runningCount > 1
      ? '$who continues by itself when one finishes'
      : '$who continues by itself when it finishes';
}

/// The consequence sentence of the sheet, said once: `omp continues by itself
/// when a job finishes.` Null for an agent that does not.
String? wakeSentence(BackgroundWork work) {
  if (!work.wakes) return null;
  return '${work.wakeLabel ?? 'The agent'} continues by itself when a job finishes.';
}

/// What the strip says: one or two lines, or null when it takes no room.
class StripText {
  const StripText(this.primary, [this.secondary]);

  final String primary;

  /// The consequence, in the waiting state only.
  final String? secondary;

  @override
  bool operator ==(Object other) => other is StripText && other.primary == primary && other.secondary == secondary;

  @override
  int get hashCode => Object.hash(primary, secondary);
}

/// The strip's words for [work] ([waiting]: the turn is over and the agent
/// waits on it; [turnRunning]: the model is running now):
///
/// | turn | tasks | words |
/// | --- | --- | --- |
/// | runs | n | `n running in background` |
/// | over, waits, wakes | n | the same, then the consequence |
/// | over, idle | n | `1 background terminal running` |
/// | any | none known | `Background work · details unavailable` |
StripText? stripText(BackgroundWork work, {required bool waiting, required bool turnRunning}) {
  if (!work.hasRunning && !waiting) return null;
  final n = work.runningCount;
  if (n == 0) return const StripText('Background work · details unavailable');
  if (waiting || turnRunning) return StripText('$n running in background', waiting ? wakeLine(work) : null);
  return StripText('${nounPhrase(work.running)} running');
}

/// What a screen reader says for the strip: one node.
String stripSemantics(BackgroundWork work, {required bool waiting, required bool turnRunning}) {
  final text = stripText(work, waiting: waiting, turnRunning: turnRunning);
  if (text == null) return 'Background work';
  final n = work.runningCount;
  final state = n == 0 ? 'details unavailable' : '$n running';
  return ['Background work', state, ?text.secondary, 'double tap to open'].join(', ');
}

/// The small chip of the bar in the compact layout: `2 jobs`; `Background`
/// when the count is unknown.
String chipLabel(BackgroundWork work) =>
    work.runningCount == 0 ? 'Background work' : nounPhrase(work.running);

/// The toast after Stop, when the turn ended and tasks remain:
/// `Turn stopped · 1 job still running`. Null when nothing remains.
String? stoppedToast(BackgroundWork work) {
  if (!work.hasRunning) return null;
  if (work.runningCount == 0) return 'Turn stopped \u00b7 background work still running';
  return 'Turn stopped \u00b7 ${nounPhrase(work.running)} still running';
}

/// `Stop` or `Ask omp to stop`: the label of a task's stop chip, which says
/// what it does (a message is not a kill).
String stopLabel(StopRoute route, String agentLabel) =>
    route == StopRoute.message ? 'Ask $agentLabel to stop' : 'Stop';

/// What a screen reader says for a task's stop chip.
String stopSemantics(BackgroundTask task, String agentLabel, {required bool primed}) {
  final label = task.stop == StopRoute.message ? 'Ask $agentLabel to stop' : 'Stop';
  final id = visibleText(task.id);
  return primed ? 'Confirm: $label $id, activate again to confirm' : '$label $id, hold to confirm';
}

/// `Stopped 2 · 1 has no stop control`: what Stop all reports. [stopped] tasks
/// were asked or told to stop, [skipped] have no stop route.
String stopAllSummary({required int stopped, required int skipped, required bool asked}) {
  final head = asked ? 'Asked to stop $stopped' : 'Stopped $stopped';
  if (skipped == 0) return head;
  return '$head \u00b7 $skipped ${skipped == 1 ? 'has' : 'have'} no stop control';
}

/// How many finished tasks the sheet lists before `Show more`.
const finishedShown = 5;

/// Finished tasks as the sheet lists them: failed first, then newest first
/// (by the end, else the start, else the order they appeared in).
List<BackgroundTask> finishedOrder(List<BackgroundTask> finished) {
  final indexed = [for (var i = 0; i < finished.length; i++) (i, finished[i])];
  int when(BackgroundTask t) => (t.endedAt ?? t.startedAt)?.millisecondsSinceEpoch ?? 0;
  indexed.sort((a, b) {
    final failed = (b.$2.status == BackgroundStatus.failed ? 1 : 0) - (a.$2.status == BackgroundStatus.failed ? 1 : 0);
    if (failed != 0) return failed;
    final time = when(b.$2).compareTo(when(a.$2));
    return time != 0 ? time : b.$1.compareTo(a.$1);
  });
  return [for (final e in indexed) e.$2];
}
