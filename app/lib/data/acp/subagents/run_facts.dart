import '../acp_models.dart';
import '../turns/plain_text.dart' show safeEnd;
import 'subagent_run.dart';

/// What one tool call update says about the subagents it started: the fields
/// it names (null: it says nothing, the run keeps what it has), for each
/// route. Pure functions of the call, so a replay gives the same facts.
class RunFacts {
  const RunFacts({
    required this.id,
    required this.route,
    required this.status,
    this.name,
    this.title,
    this.agentType,
    this.assignment,
    this.reportedElapsed,
    this.totalElapsed,
    this.toolCount,
    this.tokens,
    this.cost,
    this.model,
    this.percent,
    this.lastTool,
    this.lastToolLine,
    this.recentTools,
    this.recentOutput,
    this.note,
    this.result,
    this.failure,
    this.retry,
    this.clearRetry = false,
    this.background,
  });

  final String id;
  final SubagentRoute route;
  final SubagentStatus status;
  final String? name;
  final String? title;
  final String? agentType;
  final String? assignment;
  final Duration? reportedElapsed;
  final Duration? totalElapsed;
  final int? toolCount;
  final int? tokens;
  final double? cost;
  final String? model;
  final int? percent;
  final String? lastTool;
  final String? lastToolLine;
  final List<String>? recentTools;
  final List<String>? recentOutput;
  final String? note;
  final String? result;
  final String? failure;
  final SubagentRetry? retry;

  /// The agent reported no retry: drop the one the run had.
  final bool clearRetry;
  final bool? background;
}

/// The runs the tool call [call] starts or reports on, as of the update that
/// just changed it; empty when the call is not a subagent launcher.
/// [updateMeta] is the `_meta` of that update alone (the call's own `meta`
/// keeps only the last value of each key, which loses a `toolResponse` the
/// next update does not repeat). [known] are the runs already made for this
/// call.
List<RunFacts> launchFacts(ToolCall call, {Json? updateMeta, List<SubagentRun> known = const []}) {
  final claude = _claude(call, updateMeta, known);
  if (claude != null) return [claude];
  final omp = _omp(call, known);
  if (omp.isNotEmpty) return omp;
  final codex = _codex(call, known);
  if (codex.isNotEmpty) return codex;
  final single =
      _openCode(call, known) ??
      _copilot(call, known) ??
      _cursor(call, updateMeta, known) ??
      _kimi(call, known) ??
      _deepseek(call, known) ??
      _hermes(call, known);
  return single == null ? const [] : [single];
}

// ---------------------------------------------------------------------------
// json

String? _s(Object? v) => v is String && v.isNotEmpty ? v : null;
Map<String, Object?>? _m(Object? v) => v is Map ? v.cast<String, Object?>() : null;
List<Object?> _l(Object? v) => v is List ? v : const [];
int? _i(Object? v) => v is num && v.isFinite ? v.toInt() : null;
double? _d(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

/// The run for a call that is not named like a launcher but that subagent
/// updates name as their parent (`parentToolUseId`): whatever the call is, it
/// started a subagent, and Claude's `description` / `prompt` are read if it
/// has them.
RunFacts genericRunFacts(ToolCall call) {
  final input = _m(call.rawInput);
  final description = _firstLine(_s(input?['description'])) ?? _firstLine(call.title);
  final status = switch (call.status) {
    ToolStatus.failed => SubagentStatus.failed,
    ToolStatus.cancelled => SubagentStatus.cancelled,
    ToolStatus.completed => SubagentStatus.finished,
    ToolStatus.inProgress || ToolStatus.pending => SubagentStatus.running,
  };
  return RunFacts(
    id: call.toolCallId,
    route: SubagentRoute.claude,
    status: status,
    title: description,
    agentType: _s(input?['subagent_type']),
    assignment: _assignment(_s(input?['prompt'])),
    result: status == SubagentStatus.finished ? _contentText(call) : null,
  );
}

String _cut(String s, int max) => s.length <= max ? s : '${s.substring(0, safeEnd(s, max - 1))}\u2026';

String? _firstLine(String? s) {
  if (s == null) return null;
  for (final line in s.split('\n')) {
    final t = line.trim();
    if (t.isNotEmpty) return t;
  }
  return null;
}

/// The text of [parts] (`[{type: text, text}]`), skipping the trailer Claude
/// appends to a subagent's result (`agentId: ... <usage>...`).
String? _textOf(Object? parts) {
  final out = <String>[];
  for (final p in _l(parts)) {
    final t = p is String ? p : _s(_m(p)?['text']);
    if (t == null || t.startsWith('agentId:')) continue;
    out.add(t);
  }
  return out.isEmpty ? null : _cut(out.join('\n\n'), SubagentRun.maxResult);
}

String? _assignment(String? s) => s == null ? null : _cut(s, SubagentRun.maxAssignment);

// ---------------------------------------------------------------------------
// Claude

const _claudeLaunchers = {'Task', 'Agent'};

/// `Task` / `Agent` call: `kind: think`, `rawInput {description, prompt,
/// subagent_type}`; `_meta.claudeCode.toolResponse` carries
/// `elapsedTimeSeconds` while it runs and, at the end, `agentType`,
/// `totalDurationMs`, `totalTokens`, `totalToolUseCount`, `content`,
/// `resolvedModel`; the background form says `status: async_launched`.
RunFacts? _claude(ToolCall call, Json? updateMeta, List<SubagentRun> known) {
  final fromUpdate = _m(updateMeta?['claudeCode']);
  final fromCall = _m(call.meta?['claudeCode']);
  final toolName = _s(fromUpdate?['toolName']) ?? _s(fromCall?['toolName']) ?? call.name;
  final launcher =
      _claudeLaunchers.contains(toolName) ||
      fromUpdate?['subagent'] == true ||
      fromCall?['subagent'] == true ||
      known.any((r) => r.route == SubagentRoute.claude && r.id == call.toolCallId);
  if (!launcher) return null;

  final input = _m(call.rawInput);
  final resp = _m(fromUpdate?['toolResponse']);
  final description = _firstLine(_s(input?['description']));
  final generic = call.title == 'Task' || call.title == 'Agent' || call.title.isEmpty;
  final title = description ?? (generic ? null : _firstLine(call.title));
  final agentType = _s(input?['subagent_type']) ?? _s(resp?['agentType']) ?? _s(resp?['subagentType']);
  final prompt = _s(input?['prompt']) ?? _s(resp?['prompt']);
  final respStatus = _s(resp?['status']);
  final old = known.where((r) => r.id == call.toolCallId).firstOrNull;

  // Started in the background: the call finishes at once and the subagent
  // keeps working, until a response says it ended.
  final bool background;
  if (respStatus == 'async_launched' || resp?['isAsync'] == true) {
    background = true;
  } else if (respStatus != null) {
    background = false;
  } else {
    background = old?.background ?? input?['run_in_background'] == true;
  }

  final inputReady = prompt != null;
  final status = switch (call.status) {
    ToolStatus.failed => SubagentStatus.failed,
    ToolStatus.cancelled => SubagentStatus.cancelled,
    ToolStatus.completed => background ? SubagentStatus.running : SubagentStatus.finished,
    ToolStatus.inProgress => SubagentStatus.running,
    ToolStatus.pending =>
      inputReady || old?.status == SubagentStatus.running || _num(resp?['elapsedTimeSeconds']) != null
          ? SubagentStatus.running
          : SubagentStatus.waiting,
  };

  String? result;
  if (status == SubagentStatus.finished || status == SubagentStatus.failed) {
    result = _textOf(resp?['content']) ?? _contentText(call);
  } else if (resp != null) {
    result = _textOf(resp['content']);
  }

  final elapsed = _num(resp?['elapsedTimeSeconds']);
  final totalMs = _num(resp?['totalDurationMs']);
  return RunFacts(
    id: call.toolCallId,
    route: SubagentRoute.claude,
    status: status,
    title: title,
    agentType: agentType,
    assignment: _assignment(prompt),
    reportedElapsed: elapsed == null ? null : Duration(milliseconds: (elapsed * 1000).round()),
    totalElapsed: totalMs == null ? null : Duration(milliseconds: totalMs.round()),
    toolCount: _i(resp?['totalToolUseCount']),
    tokens: _i(resp?['totalTokens']),
    model: _s(resp?['resolvedModel']),
    result: result,
    failure: status == SubagentStatus.failed ? (result ?? 'The subagent failed') : null,
    background: background,
  );
}

num? _num(Object? v) => v is num && v.isFinite ? v : null;

/// The text blocks of the call's content, without Claude's `agentId:`
/// trailer.
String? _contentText(ToolCall call) {
  final out = <String>[];
  for (final c in call.content) {
    if (c is ToolContentBlock && c.block is TextBlock) {
      final t = (c.block as TextBlock).text;
      if (t.isNotEmpty && !t.startsWith('agentId:')) out.add(t);
    }
  }
  return out.isEmpty ? null : _cut(out.join('\n\n'), SubagentRun.maxResult);
}

// ---------------------------------------------------------------------------
// omp

/// A `task` call. omp sends no tool name over ACP, so a call is one when its
/// `rawOutput.details` has `progress` or `results` lists, or (before any
/// progress) when it is titled `task`, its input has `tasks[]` of items with
/// a `task` string (or the flat `{name, agent, task}`) and no `op`.
///
/// Shapes written from oh-my-pi's source (`AgentProgress`,
/// `SingleResult`, `TaskToolDetails`) and checked against a real omp 18.4.12
/// session (`test/fixtures/omp_logs/acp_task_updates.json`); `results` was
/// never filled in that run, so its shape is still from the source only. A
/// run's [RunFacts.name] is `progress[].id`, which is also the name of the
/// subagent's log file on the host (see `subagent_log_path.dart`).
List<RunFacts> _omp(ToolCall call, List<SubagentRun> known) {
  final out = _m(call.rawOutput);
  final details = _m(out?['details']);
  final progress = [for (final p in _l(details?['progress'])) ?_m(p)];
  final results = [for (final r in _l(details?['results'])) ?_m(r)];
  final input = _m(call.rawInput);
  final items = <Map<String, Object?>>[];
  final tasks = _l(input?['tasks']);
  if (tasks.isNotEmpty) {
    for (final t in tasks) {
      if (t is Map && t['task'] is String) items.add(_m(t)!);
    }
  } else if (input != null && input['task'] is String && !input.containsKey('op')) {
    items.add(input);
  }
  final shown = progress.isNotEmpty || results.isNotEmpty;
  if (!shown && !(items.isNotEmpty && (call.title == 'task' || call.name == 'task'))) return const [];

  final count = [progress.length, results.length, items.length].reduce((a, b) => a > b ? a : b);
  final async = _m(details?['async']);
  final facts = <RunFacts>[];
  for (var i = 0; i < count; i++) {
    final p = _byIndex(progress, i);
    final r = _byIndex(results, i);
    final item = i < items.length ? items[i] : null;
    final id = '${call.toolCallId}#$i';
    final name = _s(p?['id']) ?? _s(r?['id']) ?? _s(item?['name']);
    final assignment =
        _s(p?['assignment']) ?? _s(p?['task']) ?? _s(r?['assignment']) ?? _s(r?['task']) ?? _s(item?['task']);
    final description = _firstLine(_s(p?['description']) ?? _s(r?['description']));
    final title = description ?? name ?? _firstLine(assignment);

    var status = _ompStatus(call, _s(p?['status']));
    String? failure;
    String? result;
    if (r != null) {
      final aborted = r['aborted'] == true;
      final error = _s(r['error']) ?? _s(_m(r['retryFailure'])?['errorMessage']);
      final exit = _i(r['exitCode']);
      if (aborted) {
        status = SubagentStatus.cancelled;
        failure = _s(r['abortReason']);
      } else if (error != null || (exit != null && exit != 0)) {
        status = SubagentStatus.failed;
        failure = error ?? _s(r['stderr']) ?? 'exit code $exit';
      } else {
        status = SubagentStatus.finished;
      }
      result = _s(r['output']);
      if (result != null) result = _cut(result, SubagentRun.maxResult);
      if (failure != null) failure = _cut(failure, 400);
    }
    if (status.isActive && (call.status == ToolStatus.failed || call.status == ToolStatus.cancelled)) {
      status = call.status == ToolStatus.failed ? SubagentStatus.failed : SubagentStatus.cancelled;
    }
    final duration = _i(r?['durationMs']) ?? _i(p?['durationMs']);
    final retry = _m(p?['retryState']);
    final current = _s(p?['currentTool']);
    final args = _s(p?['currentToolArgs']);
    facts.add(
      RunFacts(
        id: id,
        route: SubagentRoute.omp,
        status: status,
        name: name,
        title: title == null ? null : _cut(title, 120),
        agentType: _s(p?['agent']) ?? _s(r?['agent']) ?? _s(item?['agent']),
        assignment: _assignment(assignment),
        reportedElapsed: status.isActive && duration != null ? Duration(milliseconds: duration) : null,
        totalElapsed: !status.isActive && duration != null ? Duration(milliseconds: duration) : null,
        toolCount: _i(p?['toolCount']),
        tokens: _i(p?['tokens']) ?? _i(r?['tokens']),
        cost: _d(p?['cost']),
        model: _s(p?['resolvedModel']) ?? _s(r?['resolvedModel']),
        percent: _i(p?['completionPercent']),
        lastTool: current,
        lastToolLine: current == null ? null : (args == null ? current : _cut('$current $args', 160)),
        recentTools: p == null ? null : _recentTools(p['recentTools']),
        recentOutput: p == null ? null : _recentOutput(p['recentOutput']),
        result: result,
        failure: failure,
        retry: retry == null
            ? null
            : SubagentRetry(
                attempt: _i(retry['attempt']) ?? 1,
                maxAttempts: _i(retry['maxAttempts']),
                delay: _i(retry['delayMs']) == null ? null : Duration(milliseconds: _i(retry['delayMs'])!),
                message: _cut(_s(retry['errorMessage']) ?? '', 200),
              ),
        clearRetry: p != null && retry == null,
        background: async != null && _s(async['state']) == 'running',
      ),
    );
  }
  return facts;
}

/// The entry with `index == i`, else the one at position [i].
Map<String, Object?>? _byIndex(List<Map<String, Object?>> list, int i) {
  for (final e in list) {
    if (_i(e['index']) == i) return e;
  }
  return i < list.length && _i(list[i]['index']) == null ? list[i] : null;
}

SubagentStatus _ompStatus(ToolCall call, String? progress) => switch (progress) {
  'running' => SubagentStatus.running,
  'completed' => SubagentStatus.finished,
  'failed' => SubagentStatus.failed,
  'aborted' => SubagentStatus.cancelled,
  'pending' => SubagentStatus.waiting,
  _ => switch (call.status) {
    ToolStatus.pending => SubagentStatus.waiting,
    ToolStatus.inProgress => SubagentStatus.running,
    ToolStatus.completed => SubagentStatus.finished,
    ToolStatus.failed => SubagentStatus.failed,
    ToolStatus.cancelled => SubagentStatus.cancelled,
  },
};

List<String> _recentTools(Object? v) {
  final out = <String>[];
  for (final t in _l(v)) {
    final name = t is String ? t : _s(_m(t)?['tool']) ?? _s(_m(t)?['name']);
    if (name != null) out.add(_cut(name, 60));
  }
  return out.length <= SubagentRun.maxRecent ? out : out.sublist(out.length - SubagentRun.maxRecent);
}

List<String> _recentOutput(Object? v) {
  final out = <String>[
    for (final line in _l(v))
      if (line is String && line.trim().isNotEmpty) _cut(line.trimRight(), 300),
  ];
  return out.length <= SubagentRun.maxRecent ? out : out.sublist(out.length - SubagentRun.maxRecent);
}

// ---------------------------------------------------------------------------
// Codex

/// `collabAgentToolCall` (title `spawnAgent`; the other tools only control a
/// subagent that exists) and `subAgentActivity`. The child thread ids are in
/// `rawInput` only; a run is keyed by its thread id, so the spawn and the
/// activity rows of one child are one run. Shapes from codex-acp's source
/// (`CollabAgentReporter`, `SubagentActivityReporter`):
/// UNVERIFIED against a recorded session (no trace has a subagent).
List<RunFacts> _codex(ToolCall call, List<SubagentRun> known) {
  final input = _m(call.rawInput);
  if (input == null) return const [];
  final tool = call.name ?? call.title;

  final receivers = [for (final t in _l(input['receiverThreadIds'])) ?_s(t)];
  final states = _m(input['agentsStates']);
  if (tool == 'spawnAgent' && receivers.isNotEmpty && states != null && input.containsKey('senderThreadId')) {
    final prompt = _s(input['prompt']);
    final facts = <RunFacts>[];
    for (final thread in receivers) {
      final state = _m(states[thread]);
      final message = _s(state?['message']);
      facts.add(
        RunFacts(
          id: thread,
          route: SubagentRoute.codex,
          status: _codexStatus(call, _s(state?['status'])),
          title: prompt == null ? null : _cut(_firstLine(prompt) ?? prompt, 120),
          assignment: _assignment(prompt),
          model: _s(input['model']),
          note: message == null ? null : _cut(message, 300),
          failure: _s(state?['status']) == 'errored' ? (message ?? 'The subagent reported an error') : null,
        ),
      );
    }
    return facts;
  }

  final thread = _s(input['agentThreadId']);
  final kind = _s(input['activityKind']);
  if (thread != null && kind != null && input.containsKey('agentPath')) {
    final path = _s(input['agentPath']);
    final name = path?.split('/').where((p) => p.isNotEmpty).lastOrNull;
    final status = switch (kind) {
      'started' || 'interacted' => SubagentStatus.running,
      'interrupted' => SubagentStatus.cancelled,
      'completed' => SubagentStatus.finished,
      _ => SubagentStatus.running,
    };
    return [RunFacts(id: thread, route: SubagentRoute.codex, status: status, name: name)];
  }
  return const [];
}

SubagentStatus _codexStatus(ToolCall call, String? state) => switch (state) {
  'pendingInit' => SubagentStatus.waiting,
  'running' => SubagentStatus.running,
  'interrupted' => SubagentStatus.cancelled,
  'completed' || 'shutdown' => SubagentStatus.finished,
  'errored' || 'notFound' => SubagentStatus.failed,
  _ => switch (call.status) {
    ToolStatus.pending || ToolStatus.inProgress => SubagentStatus.running,
    ToolStatus.completed => SubagentStatus.finished,
    ToolStatus.failed => SubagentStatus.failed,
    ToolStatus.cancelled => SubagentStatus.cancelled,
  },
};

// ---------------------------------------------------------------------------
// OpenCode, Copilot, Cursor, Kimi, Hermes, DeepSeek
//
// Shapes read from each agent's source or docs, and for OpenCode recorded from
// a real run (`test/fixtures/traces/opencode/subagent.jsonl`, OpenCode 2.2.7;
// 1.19.5 sends the same launcher as `task` with no tagged children). Copilot,
// Cursor, Kimi, Hermes and DeepSeek are UNVERIFIED against a recorded run: see
// `docs/AGENT_SESSIONS.md`, "Subagents of the other routes".

/// Said under a run whose launching call finished at once and whose end the
/// agent never reports: the phone cannot know when it is over, and says so
/// rather than keep showing it as running.
const startedInBackgroundNote = 'Started in the background. The agent does not report when it ends.';

SubagentStatus _callStatus(ToolCall call, {bool waiting = false}) => switch (call.status) {
  ToolStatus.failed => SubagentStatus.failed,
  ToolStatus.cancelled => SubagentStatus.cancelled,
  ToolStatus.completed => SubagentStatus.finished,
  ToolStatus.inProgress => SubagentStatus.running,
  ToolStatus.pending => waiting ? SubagentStatus.waiting : SubagentStatus.running,
};

/// The text of the call's content blocks, joined.
String? _allText(ToolCall call) {
  final out = <String>[];
  for (final c in call.content) {
    if (c is ToolContentBlock && c.block is TextBlock) {
      final t = (c.block as TextBlock).text;
      if (t.trim().isNotEmpty) out.add(t.trim());
    }
  }
  return out.isEmpty ? null : out.join('\n\n');
}

final _wrapOpen = RegExp(r'^<(?:subagent|task)\b[^>]*>\s*(?:<task_result>\s*)?');
final _wrapClose = RegExp(r'\s*(?:</task_result>\s*)?</(?:subagent|task)>\s*$');

/// OpenCode's result text without its `<subagent sessionID=.. state=..>` /
/// `<task id=..><task_result>` wrapper.
String? _unwrapped(String? text) {
  if (text == null) return null;
  final t = text.replaceFirst(_wrapOpen, '').replaceFirst(_wrapClose, '').trim();
  return t.isEmpty ? null : _cut(t, SubagentRun.maxResult);
}

/// `subagentType` as a string: Cursor sends a name or `{custom: name}`.
String? _typeName(Object? v) => _s(v) ?? _s(_m(v)?['custom']);

/// OpenCode: `subagent` (2.x; the call is named, kind `think`) or `task` (1.x;
/// titled `task` first, then by its description). The input is `{agent |
/// subagent_type, description, prompt}`; the result is wrapped in
/// `<subagent sessionID=..>` / `<task id=..>`, and `rawOutput.metadata` names
/// the child session (`sessionID`, or `sessionId` in 1.x). A call without a
/// name is told by its input.
RunFacts? _openCode(ToolCall call, List<SubagentRun> known) {
  final input = _m(call.rawInput);
  final named = call.name == 'subagent' || call.name == 'task';
  final shaped =
      call.kind == ToolKind.think &&
      input != null &&
      _s(input['prompt']) != null &&
      _s(input['description']) != null &&
      (_s(input['agent']) != null || _s(input['subagent_type']) != null);
  final mine = known.any((r) => r.route == SubagentRoute.opencode && r.id == call.toolCallId);
  if (!(named || shaped || mine)) return null;

  final description = _firstLine(_s(input?['description']));
  final generic = call.title == 'subagent' || call.title == 'task' || call.title.isEmpty;
  final prompt = _s(input?['prompt']);
  final background = input?['background'] == true || input?['run_in_background'] == true;
  final old = known.where((r) => r.id == call.toolCallId).firstOrNull;
  final status = _callStatus(call, waiting: prompt == null && old?.status != SubagentStatus.running);
  final over = status == SubagentStatus.finished;
  final result = over && !background ? _unwrapped(_allText(call)) : null;
  return RunFacts(
    id: call.toolCallId,
    route: SubagentRoute.opencode,
    status: status,
    title: description ?? (generic ? null : _firstLine(call.title)),
    agentType: _s(input?['agent']) ?? _s(input?['subagent_type']),
    assignment: _assignment(prompt),
    result: result,
    failure: status == SubagentStatus.failed ? (_unwrapped(_allText(call)) ?? 'The subagent failed') : null,
    note: over && background ? startedInBackgroundNote : null,
    background: background,
  );
}

/// The child session OpenCode names in a launcher's result, or null.
String? openCodeChildSession(ToolCall call) {
  final meta = _m(_m(call.rawOutput)?['metadata']);
  return _s(meta?['sessionID']) ?? _s(meta?['sessionId']);
}

/// Copilot: a `task` call whose input is `{agent_type, prompt, description,
/// name, mode, model}`; `mode: background` returns at once. The answer is in
/// `rawOutput.content`. The child's own updates carry `_meta["github.com/
/// copilot"].agentId`, which is this call's id.
RunFacts? _copilot(ToolCall call, List<SubagentRun> known) {
  final input = _m(call.rawInput);
  final mine = known.any((r) => r.route == SubagentRoute.copilot && r.id == call.toolCallId);
  if (!mine && !(input != null && _s(input['agent_type']) != null && _s(input['prompt']) != null)) return null;
  final prompt = _s(input?['prompt']);
  final background = _s(input?['mode']) == 'background';
  final status = _callStatus(call, waiting: prompt == null);
  final over = status == SubagentStatus.finished;
  final out = _m(call.rawOutput);
  final answer = _s(call.rawOutput) ?? _s(out?['content']) ?? _allText(call);
  final description = _firstLine(_s(input?['description']));
  return RunFacts(
    id: call.toolCallId,
    route: SubagentRoute.copilot,
    status: status,
    name: _s(input?['name']),
    title: description ?? _firstLine(_s(input?['name'])),
    agentType: _s(input?['agent_type']),
    assignment: _assignment(prompt),
    model: _s(input?['model']),
    result: over && !background && answer != null ? _cut(answer, SubagentRun.maxResult) : null,
    failure: status == SubagentStatus.failed ? (answer ?? 'The subagent failed') : null,
    note: over && background ? startedInBackgroundNote : null,
    background: background,
  );
}

/// Cursor: `Task: <description>` (kind `other`), input `{_toolName: task,
/// prompt, description, subagentType}`. The keeper adds `cursor/task` (what the
/// agent sends when the task ends) to a later update as `_meta.cursor.task
/// {description, subagentType, model, agentId, durationMs}`.
RunFacts? _cursor(ToolCall call, Json? updateMeta, List<SubagentRun> known) {
  final input = _m(call.rawInput);
  final mine = known.any((r) => r.route == SubagentRoute.cursor && r.id == call.toolCallId);
  final isTask = _s(input?['_toolName']) == 'task' || (call.title.startsWith('Task: ') && _s(input?['prompt']) != null);
  if (!isTask) return null;
  if (!mine && input == null) return null;
  final done = _m(_m(updateMeta?['cursor'])?['task']) ?? _m(_m(call.meta?['cursor'])?['task']);
  final description = _firstLine(_s(input?['description'])) ?? _firstLine(done?['description']?.toString());
  final status = _callStatus(call);
  final ms = _num(done?['durationMs']);
  return RunFacts(
    id: call.toolCallId,
    route: SubagentRoute.cursor,
    status: status,
    title: description,
    agentType: _typeName(input?['subagentType']) ?? _typeName(done?['subagentType']),
    assignment: _assignment(_s(input?['prompt'])),
    model: _s(done?['model']),
    totalElapsed: ms == null ? null : Duration(milliseconds: ms.round()),
    result: status == SubagentStatus.finished ? _contentText(call) : null,
    failure: status == SubagentStatus.failed ? (_contentText(call) ?? 'The subagent failed') : null,
  );
}

/// Kimi: the `Agent` call, titled `Launching (background) PROFILE agent:
/// DESCRIPTION` once its input is complete, kind `other`, input `{prompt,
/// description, subagent_type, run_in_background}`. The result is text lines
/// (`agent_id:`, `actual_subagent_type:`, `status:` ..) then `[summary]`; a
/// background launch answers `task_id: .. status: running` at once.
RunFacts? _kimi(ToolCall call, List<SubagentRun> known) {
  final input = _m(call.rawInput);
  final mine = known.any((r) => r.route == SubagentRoute.kimi && r.id == call.toolCallId);
  final shaped = call.title.startsWith('Launching ') && _s(input?['prompt']) != null;
  if (!shaped && !mine) return null;
  final background = input?['run_in_background'] == true;
  final status = _callStatus(call);
  final over = status == SubagentStatus.finished;
  final text = _allText(call);
  String? actualType;
  String? summary;
  if (text != null) {
    actualType = RegExp(r'^actual_subagent_type:\s*(\S+)', multiLine: true).firstMatch(text)?.group(1);
    final at = text.indexOf('[summary]');
    if (at >= 0) {
      var s = text.substring(at + '[summary]'.length);
      final hint = s.indexOf('\nresume_hint:');
      if (hint >= 0) s = s.substring(0, hint);
      summary = s.trim().isEmpty ? null : _cut(s.trim(), SubagentRun.maxResult);
    }
  }
  final description = _firstLine(_s(input?['description']));
  return RunFacts(
    id: call.toolCallId,
    route: SubagentRoute.kimi,
    status: status,
    title: description ?? (call.title.startsWith('Launching ') ? _firstLine(call.title) : null),
    agentType: _s(input?['subagent_type']) ?? actualType,
    assignment: _assignment(_s(input?['prompt'])),
    result: over && !background ? (summary ?? (text == null ? null : _cut(text, SubagentRun.maxResult))) : null,
    failure: status == SubagentStatus.failed ? (summary ?? text ?? 'The subagent failed') : null,
    note: over && background ? startedInBackgroundNote : null,
    background: background,
  );
}

/// DeepSeek: `subagent` / `subagent_fork` (kind `other`), input `{description,
/// prompt, name?}`. The call answers `started subagent NAME` at once and the
/// subagent keeps working: the end comes back to the root as a later message,
/// not as an update the phone can attach to the call.
RunFacts? _deepseek(ToolCall call, List<SubagentRun> known) {
  final input = _m(call.rawInput);
  final mine = known.any((r) => r.route == SubagentRoute.deepseek && r.id == call.toolCallId);
  final launcher = (call.title == 'subagent' || call.title == 'subagent_fork') && call.kind == ToolKind.other;
  if (!(launcher && input != null && _s(input['prompt']) != null) && !mine) return null;
  final status = _callStatus(call);
  return RunFacts(
    id: call.toolCallId,
    route: SubagentRoute.deepseek,
    status: status,
    name: _s(input?['name']),
    title: _firstLine(_s(input?['description'])) ?? _s(input?['name']),
    assignment: _assignment(_s(input?['prompt'])),
    failure: status == SubagentStatus.failed ? (_allText(call) ?? 'The subagent failed') : null,
    note: status == SubagentStatus.finished ? startedInBackgroundNote : null,
    background: true,
  );
}

/// Hermes: `delegate_task: <preview>` (kind `execute`, no input). The start text
/// is `Delegating N tasks` and the goals; a call that ends with `Delegation
/// results:` carries the results, any other end is the dispatch of background
/// work (the results come back as a later message).
RunFacts? _hermes(ToolCall call, List<SubagentRun> known) {
  final mine = known.any((r) => r.route == SubagentRoute.hermes && r.id == call.toolCallId);
  if (!call.title.startsWith('delegate_task') && !mine) return null;
  final status = _callStatus(call);
  final text = _allText(call);
  final results = text != null && text.startsWith('Delegation results:');
  final first = text == null ? null : _firstLine(text);
  return RunFacts(
    id: call.toolCallId,
    route: SubagentRoute.hermes,
    status: status,
    title: results ? null : (first != null && first.startsWith('Delegat') ? first : null),
    assignment: results || text == null ? null : _assignment(text),
    result: status == SubagentStatus.finished && results ? _cut(text, SubagentRun.maxResult) : null,
    failure: status == SubagentStatus.failed ? (text ?? 'The subagent failed') : null,
    note: status == SubagentStatus.finished && !results ? startedInBackgroundNote : null,
    background: status == SubagentStatus.finished && !results,
  );
}
