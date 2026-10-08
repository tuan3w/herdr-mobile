import '../../../data/repositories/agent_session.dart' show AgentSessionView;
import '../../../data/acp/session_state.dart';
import '../../../data/acp/subagents/subagent_run.dart';
import '../../../data/acp/turns/plain_text.dart' show safeEnd;
import 'status_line.dart' show elapsedLabel;
import 'visible_text.dart';

/// How a subagent shows itself: one tone per state the person can tell apart.
/// The glyph, the colour of the live line and the order in the roster all
/// follow from it.
enum RunTone {
  /// A request of this subagent waits for the person.
  waitingForYou,

  /// Asked for, not started.
  starting,
  running,

  /// It was running when the link to the agent went away: the app does not
  /// know any more, and does not say `running`.
  stale,
  done,
  failed,
  cancelled;

  /// It may still say something.
  bool get isActive => this == waitingForYou || this == starting || this == running;
}

/// The tone of [run]. [blocked] is the set of run ids that have a request
/// waiting ([blockedRunIds]); [live] is whether the session is connected to
/// its agent (a run that was active when it went away is [RunTone.stale]).
RunTone toneOf(SubagentRun run, {required Set<String> blocked, required bool live}) {
  if (run.isActive && !live) return RunTone.stale;
  if (run.isActive && blocked.contains(run.id)) return RunTone.waitingForYou;
  return switch (run.status) {
    SubagentStatus.waiting => RunTone.starting,
    SubagentStatus.running => RunTone.running,
    SubagentStatus.finished => RunTone.done,
    SubagentStatus.failed => RunTone.failed,
    SubagentStatus.cancelled => RunTone.cancelled,
  };
}

/// The runs that have a permission or a question waiting: their ids.
Set<String> blockedRunIds(AgentSessionState state) {
  if (state.pending.isEmpty) return const {};
  return {
    for (final p in state.pending)
      if (p.origin != null) p.origin!.id,
  };
}

/// Whether the session is connected to its agent, so that a run that says
/// `running` is believed.
bool runsAreLive(AgentSessionState state, {required bool linkLive}) => linkLive && !state.disconnected;

/// `7 tools`, `1 tool`; null for none.
String? toolsWord(int count) => count <= 0 ? null : '$count ${count == 1 ? 'tool' : 'tools'}';

/// How long [run] has run, as best known. A run that is active and live
/// counts from when this client first saw it ([now] - `startedAt`), else it
/// shows the figure the agent last reported; null when nothing is known.
Duration? runElapsed(SubagentRun run, DateTime now, {required bool live}) {
  if (run.isActive) {
    final at = run.startedAt;
    if (live && at != null) {
      final d = now.difference(at);
      return d.isNegative ? Duration.zero : d;
    }
    return run.reportedElapsed;
  }
  return run.elapsed;
}

/// The live line of a card, a roster row and the state strip, made of
/// figures the app has:
///
///  * running: `running 42s · Grep · 7 tools` (omp adds `60%`, a retry says
///    `retrying 2 of 5`);
///  * waiting for a request: `Waiting for you · 7 tools`;
///  * done: `Explore · done · 31s · 12 tools`; failed and cancelled likewise.
String runLine(SubagentRun run, RunTone tone, {required DateTime now}) {
  final live = tone != RunTone.stale;
  final elapsed = runElapsed(run, now, live: live);
  final time = elapsed == null ? null : elapsedLabel(elapsed);
  final tools = toolsWord(run.toolCount);
  final last = _lastTool(run);
  final type = _clean(run.agentType);
  final retry = run.retry;
  final parts = switch (tone) {
    RunTone.waitingForYou => ['Waiting for you', ?tools],
    RunTone.starting => ['starting', ?time],
    RunTone.running => [
      time == null ? 'running' : 'running $time',
      if (retry != null)
        retry.maxAttempts == null ? 'retrying' : 'retrying ${retry.attempt} of ${retry.maxAttempts}',
      if (run.percent != null) '${run.percent}%',
      ?last,
      ?tools,
    ],
    RunTone.stale => ['was running', ?time, ?last, ?tools],
    RunTone.done => [?type, 'done', ?time, ?tools],
    RunTone.failed => [?type, 'failed', ?time, ?tools],
    RunTone.cancelled => [?type, 'cancelled', ?time, ?tools],
  };
  return parts.join(' · ');
}

String? _lastTool(SubagentRun run) {
  final t = _clean(run.lastTool);
  if (t == null) return null;
  return t.length <= 24 ? t : '${t.substring(0, 23)}…';
}

String? _clean(String? s) {
  if (s == null) return null;
  final t = visibleText(s).replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.isEmpty ? null : t;
}

/// What the reducer writes when the agent gave no reason; it says what the
/// state already says, so it is not shown again.
const genericFailure = 'The subagent failed';

/// Why a run did not succeed, whole; null when the agent gave no reason.
String? failureText(SubagentRun run) {
  final f = run.failure?.trim();
  if (f == null || f.isEmpty || f == genericFailure) return null;
  return visibleText(f);
}

/// The first line of why a run did not succeed, cut to [max] characters.
String? failureLine(SubagentRun run, {int max = 160}) {
  final f = failureText(run);
  if (f == null) return null;
  final line = f.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '').trim();
  if (line.isEmpty) return null;
  return line.length <= max ? line : '${line.substring(0, safeEnd(line, max - 1))}…';
}

/// The title of a run as shown: its description, with a fallback when the
/// agent gave none.
String runTitle(SubagentRun run) {
  final t = _clean(run.title) ?? _clean(run.name) ?? _clean(run.agentType);
  return t ?? 'Subagent';
}

// ---------------------------------------------------------------------------
// groups: parallel runs

/// Subagents started together: the runs of one call (omp's `task` starts
/// several), and of calls that follow each other in the transcript with
/// nothing between them (Claude's parallel `Task` calls).
class SubagentGroup {
  const SubagentGroup(this.toolCallIds, this.runs);

  /// The calls, in transcript order; the group header sits on the first.
  final List<String> toolCallIds;
  final List<SubagentRun> runs;

  String get firstToolCallId => toolCallIds.first;

  /// More than one run: the header `3 subagents · 2 running` is shown.
  bool get isGroup => runs.length > 1;
}

class _Index {
  _Index(this.runs, this.groups);

  final List<SubagentRun> runs;
  final Map<String, SubagentGroup> groups;
}

final _indexes = Expando<_Index>('subagent groups');

/// The group the call [toolCallId] belongs to, or null when it started no
/// subagent. Worked out once per (transcript, runs) pair: a streaming message
/// changes neither.
SubagentGroup? groupOf(String toolCallId, List<TranscriptItem> items, List<SubagentRun> runs) {
  if (runs.isEmpty) return null;
  var index = _indexes[items];
  if (index == null || !identical(index.runs, runs)) {
    index = _Index(runs, _group(items, runs));
    _indexes[items] = index;
  }
  return index.groups[toolCallId];
}

Map<String, SubagentGroup> _group(List<TranscriptItem> items, List<SubagentRun> runs) {
  final byCall = <String, List<SubagentRun>>{};
  for (final r in runs) {
    (byCall[r.parentToolCallId] ??= []).add(r);
  }
  final out = <String, SubagentGroup>{};
  var ids = <String>[];
  var members = <SubagentRun>[];
  void close() {
    if (ids.isEmpty) return;
    final g = SubagentGroup(ids, members);
    for (final id in ids) {
      out[id] = g;
    }
    ids = [];
    members = [];
  }

  for (final item in items) {
    final owned = item is TranscriptTool ? byCall[item.call.toolCallId] : null;
    if (owned == null) {
      close();
      continue;
    }
    ids.add((item as TranscriptTool).call.toolCallId);
    members.addAll(owned);
  }
  close();
  return out;
}

/// The calls of [session]'s transcript that stay out of the fold of a
/// finished turn because of something the person must see: the ones that
/// wait for a permission, and the calls that started a subagent which failed
/// or was cancelled (the call itself may say `completed`: omp's `task` call
/// completes with a failed subagent in it).
Set<String> attentionToolIds(AgentSessionView session) {
  final state = session.state;
  final base = state.pending.isEmpty ? const <String>{} : state.waitingToolIds;
  final runs = session.subagentRuns;
  if (runs.isEmpty) return base;
  Set<String>? out;
  for (final r in runs) {
    if (r.status == SubagentStatus.failed || r.status == SubagentStatus.cancelled) {
      (out ??= {...base}).add(r.parentToolCallId);
    }
  }
  return out ?? base;
}

/// `3 subagents · 2 running`, `3 subagents · 1 failed`, `3 subagents · all
/// done`: counts of what the group's runs are, by tone ([toneOf]).
String groupTitle(List<SubagentRun> runs, Set<String> blocked, {bool live = true}) {
  var running = 0, starting = 0, stale = 0, failed = 0, cancelled = 0, waitingForYou = 0;
  for (final r in runs) {
    switch (toneOf(r, blocked: blocked, live: live)) {
      case RunTone.running:
        running++;
      case RunTone.starting:
        starting++;
      case RunTone.stale:
        stale++;
      case RunTone.waitingForYou:
        waitingForYou++;
      case RunTone.failed:
        failed++;
      case RunTone.cancelled:
        cancelled++;
      case RunTone.done:
        break;
    }
  }
  final parts = [
    '${runs.length} subagents',
    if (running > 0) '$running running',
    if (waitingForYou > 0) '$waitingForYou waiting for you',
    if (starting > 0) '$starting starting',
    if (stale > 0) '$stale not updating',
    if (failed > 0) '$failed failed',
    if (cancelled > 0) '$cancelled cancelled',
  ];
  return parts.length == 1 ? '${parts.first} · all done' : parts.join(' · ');
}

// ---------------------------------------------------------------------------
// the roster

enum RosterSection {
  /// Needs the person, or not started.
  waiting('Waiting'),
  running('Running'),
  finished('Finished');

  const RosterSection(this.title);
  final String title;
}

/// One line of the roster list: a section header or a run.
sealed class RosterItem {
  const RosterItem();
}

class RosterHeader extends RosterItem {
  const RosterHeader(this.section, this.count);

  final RosterSection section;
  final int count;
}

class RosterEntry extends RosterItem {
  const RosterEntry(this.run, this.tone);

  final SubagentRun run;
  final RunTone tone;
}

/// The roster's lines: Waiting (the ones that wait for the person first, then
/// the ones not started), Running, then Finished (failed, then cancelled,
/// then done; newest first). Empty sections are left out.
List<RosterItem> rosterOf(List<SubagentRun> runs, {required Set<String> blocked, required bool live}) {
  final waitingForYou = <RosterEntry>[], waiting = <RosterEntry>[], running = <RosterEntry>[];
  final failed = <RosterEntry>[], cancelled = <RosterEntry>[], done = <RosterEntry>[];
  for (final r in runs) {
    final tone = toneOf(r, blocked: blocked, live: live);
    final e = RosterEntry(r, tone);
    switch (tone) {
      case RunTone.waitingForYou:
        waitingForYou.add(e);
      case RunTone.starting:
        waiting.add(e);
      case RunTone.running || RunTone.stale:
        running.add(e);
      case RunTone.failed:
        failed.add(e);
      case RunTone.cancelled:
        cancelled.add(e);
      case RunTone.done:
        done.add(e);
    }
  }
  final head = [...waitingForYou, ...waiting];
  final tail = [...failed.reversed, ...cancelled.reversed, ...done.reversed];
  return [
    if (head.isNotEmpty) ...[RosterHeader(RosterSection.waiting, head.length), ...head],
    if (running.isNotEmpty) ...[RosterHeader(RosterSection.running, running.length), ...running],
    if (tail.isNotEmpty) ...[RosterHeader(RosterSection.finished, tail.length), ...tail],
  ];
}

// ---------------------------------------------------------------------------
// figures

/// `950`, `12.3k`, `1.2M`: a token count for a line of text.
String formatTokens(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) {
    final k = n / 1000;
    return '${k < 10 ? k.toStringAsFixed(1) : k.round()}k'.replaceFirst('.0k', 'k');
  }
  final m = n / 1000000;
  return '${m < 10 ? m.toStringAsFixed(1) : m.round()}M'.replaceFirst('.0M', 'M');
}

/// A cost with its currency: `$0.42` for USD, `0.42 EUR` otherwise (a symbol
/// is only guessed for the dollar); no currency is told as the number alone.
String formatCost(double amount, [String? currency]) {
  final digits = amount.abs() >= 100 ? 0 : (amount.abs() >= 1 ? 2 : (amount == 0 ? 2 : 3));
  final number = amount.toStringAsFixed(digits);
  final c = currency?.trim();
  if (c == null || c.isEmpty) return number;
  return c.toUpperCase() == 'USD' ? '\$$number' : '$number ${c.toUpperCase()}';
}
