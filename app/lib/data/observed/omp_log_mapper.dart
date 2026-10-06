import 'dart:convert';

import '../acp/acp_models.dart';
import '../acp/background/background_work.dart';
import 'observed_contracts.dart';

/// Maps the lines of an `omp` session log (`~/.omp/agent/sessions/.../*.jsonl`)
/// to the updates `AgentSessionState.apply` understands, so that an omp turn
/// reads on the phone the way the same turn of an ACP session does.
///
/// Entry kinds read (everything else, and anything malformed, maps to
/// nothing):
/// - `session` (the cwd, used to resolve relative paths; a title), `title`
///   and `title_change` (the session title);
/// - `message` with role `user`, `assistant` (text, thinking, `toolCall`
///   blocks, `stopReason: error`), `toolResult`, `bashExecution` and
///   `pythonExecution`; `developer`, `fileMention` and other roles are
///   housekeeping and stay hidden;
/// - `custom_message` that the user started (a skill prompt, a peer's prompt)
///   and `irc:incoming` (a message from another agent, as a note); an
///   `async-result` only updates [subagents];
/// - `compaction`, `branch_summary` and `reset_boundary` (one quiet note);
/// - `custom`: `user_todo_edit` (the plan) and `session_exit` (the process is
///   gone, so what was running is cancelled).
///
/// The `task` tool shows as one row (`Subagents: A, B`) whose content is a
/// roster; [subagents] holds the latest state per name, from the call, its
/// result's progress and later `wait` results. A `write` to `agent://<name>`
/// is a message to another agent: it shows as a note, not as a tool row. A
/// subagent's own log (`<parent>/<name>.jsonl`) has the same format.
///
/// [backgroundTasks] follows the jobs omp reports as running in the
/// background (`details.async` of a `bash`, `eval` or `task` result) until the
/// log says they ended: an `async-result` notice, a `wait` or proc result, a
/// kill the model issued, or `session_exit` (which also starts a new epoch,
/// since omp's `bg_N` ids restart with the process). [turnEnded] says whether
/// the last turn of the log is over. Neither is confirmed by the agent's UI:
/// a job stopped there is never recorded.
///
/// A log is written by whole entries, so nothing streams: a message arrives
/// complete, a tool call arrives when the assistant message that holds it is
/// written (the tool is then running) and again, as a patch, with its result.
///
/// Idempotent: messages are whole-message upserts keyed by the entry id, tool
/// calls are keyed by their call id and patches replace, and an entry id this
/// mapper has already mapped yields nothing, so a line fed twice (a resume
/// that overlaps, a reconnect) changes nothing. The memory of seen ids lives
/// in the mapper: reset it together with the state it feeds.
class OmpLogMapper implements SessionLogMapper {
  /// The longest text kept per field. The host already cuts a field to about
  /// 16 KB; anything longer than this gets a visible [_cutMark] here.
  static const maxFieldChars = 20000;

  static const _cutMark = '\n... [cut]';
  static const _titleChars = 120;

  /// Entry ids already mapped (those that produce updates).
  final _seen = <String>{};

  /// Every tool call id that started, so that a result for an unseen start
  /// (a log followed from the middle) can name the call itself.
  final _started = <String>{};

  /// Calls that started and have no result yet.
  final _open = <String, _OpenCall>{};

  PendingAsk? _ask;
  String? _cwd;

  /// Subagents by name, in the order they first appeared.
  final _subagents = <String, SubagentInfo>{};

  /// Calls that are not shown as tool rows (messages to other agents show as
  /// notes); their results are dropped.
  final _hidden = <String>{};

  /// Background tasks by [BackgroundTask.key], in the order they started.
  final _tasks = <String, BackgroundTask>{};
  List<BackgroundTask>? _taskView;

  /// Bumped by `session_exit`: omp's job ids restart with its process.
  var _bgEpoch = 0;
  var _turnEnded = false;

  @override
  PendingAsk? get pendingAsk => _ask;

  @override
  Set<String> get openToolCalls => Set.unmodifiable(_open.keys);

  @override
  List<SubagentInfo> get subagents => List.unmodifiable(_subagents.values);

  @override
  List<BackgroundTask> get backgroundTasks => _taskView ??= List.unmodifiable(_tasks.values);

  @override
  bool get turnEnded => _turnEnded;

  @override
  void reset() {
    _seen.clear();
    _started.clear();
    _open.clear();
    _subagents.clear();
    _hidden.clear();
    _ask = null;
    _cwd = null;
    _tasks.clear();
    _taskView = null;
    _bgEpoch = 0;
    _turnEnded = false;
  }

  @override
  List<SessionUpdate> map(String line) {
    if (line.isEmpty) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on Object {
      return const [];
    }
    if (decoded is! Map<String, dynamic>) return const [];
    try {
      return _entry(decoded, line);
    } on Object {
      return const [];
    }
  }

  // -- entries ---------------------------------------------------------------

  List<SessionUpdate> _entry(Json e, String line) {
    switch (e['type']) {
      case 'session':
        final cwd = e['cwd'];
        if (cwd is String && cwd.isNotEmpty) _cwd = cwd;
        return _firstTime(e, line) == null ? const [] : _title(e['title']);
      case 'title':
      case 'title_change':
        return _firstTime(e, line) == null ? const [] : _title(e['title']);
      case 'message':
        final m = e['message'];
        if (m is! Map<String, dynamic>) return const [];
        return _message(e, m, line);
      case 'compaction':
      case 'branch_summary':
        return _note(e, line, 'Earlier messages were summarised');
      case 'reset_boundary':
        return _note(e, line, 'The conversation was cleared on the host');
      case 'custom_message':
        return _customMessage(e, line);
      case 'custom':
        return _custom(e, line);
      default:
        return const [];
    }
  }

  List<SessionUpdate> _title(Object? title) {
    if (title is! String) return const [];
    final t = title.trim();
    if (t.isEmpty) return const [];
    return [SessionInfoUpdate(hasTitle: true, title: _cut(t, 200), hasUpdatedAt: false)];
  }

  /// One quiet agent message for a housekeeping entry.
  List<SessionUpdate> _note(Json e, String line, String text) {
    final key = _firstTime(e, line);
    if (key == null) return const [];
    return [_upsert(MessageRole.agent, key, text)];
  }

  List<SessionUpdate> _customMessage(Json e, String line) {
    final custom = e['customType'];
    if (custom == 'irc:incoming') return _ircIncoming(e, line);
    if (custom == 'async-result') {
      if (_firstTime(e, line) != null) {
        _turnEnded = false;
        _asyncResult(e);
        _jobsFinished(e['details']);
      }
      return const [];
    }
    // Only what the person started shows; reminders, nudges and notices the
    // agent injected are for the model.
    if (e['attribution'] != 'user' || e['display'] != true) return const [];
    var text = _userText(e['content']);
    final details = e['details'];
    if (e['customType'] == 'skill-prompt' && details is Map<String, dynamic>) {
      final name = details['name'];
      if (name is String && name.isNotEmpty) {
        final args = details['args'];
        text = '/skill:$name${args is String && args.trim().isNotEmpty ? ' ${args.trim()}' : ''}';
      }
    }
    if (text.trim().isEmpty) return const [];
    final key = _firstTime(e, line);
    if (key == null) return const [];
    _turnEnded = false;
    return [..._userClears(), _upsert(MessageRole.user, key, text)];
  }

  List<SessionUpdate> _custom(Json e, String line) {
    final data = e['data'];
    switch (e['customType']) {
      case 'user_todo_edit':
        if (data is Map<String, dynamic> && _firstTime(e, line) != null) {
          final plan = _plan(data['phases']);
          if (plan != null) return [plan];
        }
        return const [];
      case 'session_exit':
        if (_firstTime(e, line) == null) return const [];
        _exitSession(_stamp(e));
        return _cancelOpen();
      default:
        return const [];
    }
  }

  // -- messages --------------------------------------------------------------

  List<SessionUpdate> _message(Json e, Json m, String line) {
    switch (m['role']) {
      case 'user':
        final text = _userText(m['content']);
        if (text.trim().isEmpty) return const [];
        final key = _firstTime(e, line);
        if (key == null) return const [];
        _turnEnded = false;
        return [..._userClears(), _upsert(MessageRole.user, key, text)];
      case 'assistant':
        final key = _firstTime(e, line);
        if (key == null) return const [];
        final out = _assistant(key, m);
        _turnEnded = _endsTurn(m['stopReason']) && _open.isEmpty;
        return out;
      case 'toolResult':
        final key = _firstTime(e, line);
        if (key == null) return const [];
        _turnEnded = false;
        return _toolResult(m, _stamp(e));
      case 'bashExecution':
        final key = _firstTime(e, line);
        if (key == null) return const [];
        return [_userRun(key, m, 'command', 'bash')];
      case 'pythonExecution':
        final key = _firstTime(e, line);
        if (key == null) return const [];
        return [_userRun(key, m, 'code', 'python')];
      default:
        return const [];
    }
  }

  /// A later user message ends a question that is still open: the answer, if
  /// any, was typed in the terminal.
  List<SessionUpdate> _userClears() {
    final ask = _ask;
    if (ask == null) return const [];
    _ask = null;
    if (_open.remove(ask.toolCallId) == null) return const [];
    return [_cancelled(ask.toolCallId)];
  }

  List<SessionUpdate> _assistant(String key, Json m) {
    final out = <SessionUpdate>[];
    final content = m['content'];
    if (content is String) {
      _addText(out, MessageRole.agent, '$key:0', content);
    } else if (content is List) {
      for (var i = 0; i < content.length; i++) {
        final b = content[i];
        if (b is! Map<String, dynamic>) continue;
        switch (b['type']) {
          case 'text':
            final t = b['text'];
            if (t is String) _addText(out, MessageRole.agent, '$key:$i', t);
          case 'thinking':
            final t = b['thinking'];
            if (t is String) _addText(out, MessageRole.thought, '$key:$i', t);
          case 'toolCall':
            final note = _agentWrite(b, '$key:$i');
            if (note != null) {
              out.add(note);
            } else {
              final start = _toolStart(b);
              if (start != null) out.add(start);
            }
        }
      }
    }
    final stop = m['stopReason'];
    if (stop == 'error') {
      final err = m['errorMessage'];
      final text = err is String && err.trim().isNotEmpty ? 'The turn failed: ${_capText(err.trim())}' : 'The turn failed.';
      out.add(_upsert(MessageRole.agent, '$key:error', text));
    }
    // An interrupted or failed message leaves its calls without a result.
    if (stop == 'error' || stop == 'aborted') out.addAll(_cancelOpen());
    return out;
  }

  void _addText(List<SessionUpdate> out, MessageRole role, String id, String text) {
    if (text.trim().isEmpty) return;
    out.add(_upsert(role, id, text));
  }

  static MessageUpsert _upsert(MessageRole role, String id, String text) =>
      MessageUpsert(role, id, hasContent: true, content: [TextBlock(_capText(text))]);

  /// What the person typed: a string, or the text blocks joined, with a
  /// placeholder line per image (the log holds a blob reference, not the
  /// picture).
  static String _userText(Object? content) {
    if (content is String) return content;
    if (content is! List) return '';
    final parts = <String>[];
    for (final b in content) {
      if (b is! Map<String, dynamic>) continue;
      switch (b['type']) {
        case 'text':
          final t = b['text'];
          if (t is String && t.isNotEmpty) parts.add(t);
        case 'image':
          parts.add(_imageNote(b));
      }
    }
    return parts.join('\n');
  }

  static String _imageNote(Json b) {
    final mime = b['mimeType'];
    return mime is String && mime.isNotEmpty ? '[image: $mime]' : '[image]';
  }

  /// A `!` command or `$` snippet the person ran in the terminal: one finished
  /// tool call.
  SessionUpdate _userRun(String key, Json m, String inputKey, String name) {
    final source = m[inputKey] is String ? m[inputKey] as String : '';
    final output = m['output'] is String ? m['output'] as String : '';
    final exit = m['exitCode'];
    final status = m['cancelled'] == true
        ? ToolStatus.cancelled
        : exit is num && exit != 0
        ? ToolStatus.failed
        : ToolStatus.completed;
    return ToolCallStart(
      ToolCall(
        toolCallId: 'run:$key',
        name: name,
        title: _cut(_firstLine(source), _titleChars),
        kind: ToolKind.execute,
        status: status,
        rawInput: {inputKey: _capText(source)},
        content: output.isEmpty ? const [] : [ToolContentBlock(TextBlock(_capText(output)))],
      ),
    );
  }

  // -- tool calls ------------------------------------------------------------

  SessionUpdate? _toolStart(Json b) {
    final id = b['id'];
    if (id is! String || id.isEmpty) return null;
    final rawName = b['name'];
    final name = rawName is String && rawName.isNotEmpty ? rawName : 'tool';
    final args = _arguments(b['arguments']);
    final diffs = _startDiffs(name, args);
    final names = name == 'task' ? _taskNames(args) : const <String>[];
    _started.add(id);
    _open[id] = _OpenCall(name, diffs, names, command: _commandOf(args));
    if (name == 'ask') _ask = _parseAsk(id, args);
    final intent = b['intent'] is String ? b['intent'] as String : (args?['i'] is String ? args!['i'] as String : null);
    final roster = _roster(names);
    return ToolCallStart(
      ToolCall(
        toolCallId: id,
        name: name,
        title: names.isEmpty ? _toolTitle(name, args, intent) : _cut('Subagents: ${names.join(', ')}', _titleChars),
        kind: _kindOf(name),
        status: ToolStatus.inProgress,
        rawInput: args == null ? null : _capJson(args),
        content: roster.isEmpty ? diffs : [ToolContentBlock(TextBlock(roster))],
        locations: _locationsOfCall(name, args),
      ),
    );
  }

  static Json? _arguments(Object? raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is String && raw.trimLeft().startsWith('{')) {
      try {
        final d = jsonDecode(raw);
        if (d is Map<String, dynamic>) return d;
      } on Object {
        return null;
      }
    }
    return null;
  }

  List<SessionUpdate> _toolResult(Json m, DateTime? at) {
    final id = m['toolCallId'];
    if (id is! String || id.isEmpty) return const [];
    if (_hidden.contains(id)) return const [];
    final isError = m['isError'] == true;
    final open = _open.remove(id);
    final known = _started.contains(id);
    _started.add(id);
    final rawName = m['toolName'];
    final name = open?.name ?? (rawName is String && rawName.isNotEmpty ? rawName : 'tool');
    final details = m['details'] is Map<String, dynamic> ? m['details'] as Map<String, dynamic> : null;

    // The change as the result reports it (real old text) wins over the one
    // the call's arguments implied; a failed call changed nothing.
    final content = <ToolContent>[];
    if (!isError) {
      final reported = _resultDiffs(details);
      content.addAll(reported.isNotEmpty ? reported : (open?.diffs ?? const <ToolDiff>[]));
    }
    var text = _resultText(m['content']);
    if (details != null) _noteBackground(id, name, details, open, text, at);
    if (name == 'task') {
      _noteTask(details);
      // The roster says more than "Spawned agent ... NEVER poll".
      final roster = _roster(_taskResultNames(details) ?? open?.names ?? const <String>[]);
      if (!isError && roster.isNotEmpty) text = roster;
    } else if (name == 'wait') {
      _noteWait(details);
    }
    if (text.isNotEmpty) content.add(ToolContentBlock(TextBlock(_capText(text))));

    final locations = _locationsOfResult(details);
    final fields = <String, Object?>{
      'toolCallId': id,
      if (!known) ...{'name': name, 'title': name, 'kind': _kindWire(_kindOf(name))},
      'status': isError ? 'failed' : 'completed',
      'content': [for (final c in content) c.toJson()],
      if (text.isNotEmpty) 'rawOutput': _capText(text),
      if (locations.isNotEmpty) 'locations': locations,
    };
    if (_ask?.toolCallId == id) _ask = null;
    final out = <SessionUpdate>[ToolCallPatchUpdate(ToolCallPatch(id, fields))];
    if (name == 'todo' && !isError && details != null) {
      final plan = _plan(details['phases']);
      if (plan != null) out.add(plan);
    }
    return out;
  }

  /// Everything still running is cancelled (the turn was interrupted, failed
  /// or the process exited).
  List<SessionUpdate> _cancelOpen() {
    if (_open.isEmpty) return const [];
    final out = [for (final id in _open.keys) _cancelled(id)];
    _open.clear();
    _ask = null;
    return out;
  }

  // -- background work -------------------------------------------------------

  /// Finished tasks kept for the list; the oldest go first.
  static const _finishedKept = 30;

  /// What omp's own text says of a job that did not succeed. Used only when
  /// the notice has no status.
  static final _failedText = RegExp(r'Command timed out|Command exited with code [1-9]\d*');
  static final _cancelledText = RegExp(r'Cancelled background job (\S+?)\.(?:\s|$)');
  static final _jobHeader = RegExp(r'── Job (\S+)');

  /// The entry's own time, by the host's clock; null when it has none.
  static DateTime? _stamp(Json e) {
    final t = e['timestamp'];
    if (t is String) return DateTime.tryParse(t);
    if (t is int) return DateTime.fromMillisecondsSinceEpoch(t, isUtc: true);
    return null;
  }

  static bool _endsTurn(Object? stopReason) =>
      stopReason == 'stop' || stopReason == 'length' || stopReason == 'aborted' || stopReason == 'error';

  /// The text a `bash` call runs or an `eval` call evaluates.
  static String? _commandOf(Json? args) {
    final c = args?['command'] ?? args?['code'];
    return c is String ? c : null;
  }

  static BackgroundStatus _statusOf(String s) => switch (s) {
    'failed' || 'error' || 'timeout' || 'timed_out' => BackgroundStatus.failed,
    'cancelled' || 'canceled' || 'aborted' || 'killed' || 'stopped' => BackgroundStatus.stopped,
    _ => BackgroundStatus.finished,
  };

  static bool _stillRunning(String s) => s == 'running' || s == 'pending';

  void _noteBackground(String callId, String tool, Json details, _OpenCall? open, String text, DateTime? at) {
    final async = details['async'];
    if (async is Map<String, dynamic>) {
      final state = async['state'];
      final jobId = async['jobId'];
      if (state == 'running') {
        _startJobs(callId, tool, async, details, open, at);
      } else if (state is String && jobId is String) {
        _finish(jobId, _statusOf(state), at);
      }
    }
    final proc = details['proc'];
    for (final root in [details, if (proc is Map<String, dynamic>) proc]) {
      final jobs = root['jobs'];
      if (jobs is List) {
        for (final j in jobs) {
          if (j is Map<String, dynamic>) _settleJob(j, at);
        }
      }
      final job = root['job'];
      if (job is Map<String, dynamic>) _settleJob(job, at);
      final cancelled = root['cancelled'];
      if (cancelled is List) {
        for (final c in cancelled) {
          if (c is! Map<String, dynamic> || c['id'] is! String) continue;
          final id = c['id'] as String;
          if (c['status'] == 'cancelled') _finish(id, BackgroundStatus.stopped, at);
          if (c['status'] == 'already_completed') _finish(id, BackgroundStatus.finished, at);
        }
      }
    }
    if (tool == 'write') {
      for (final m in _cancelledText.allMatches(text)) {
        _finish(m.group(1)!, BackgroundStatus.stopped, at);
      }
    }
  }

  /// A job of a `wait` or proc result: settled unless it still runs.
  void _settleJob(Json j, DateTime? at) {
    final id = j['id'] ?? j['jobId'];
    final status = j['status'];
    if (id is! String || status is! String || _stillRunning(status)) return;
    _finish(id, _statusOf(status), at);
  }

  /// The result of a call that went to the background: one task per job (a
  /// `task` call starts one per subagent, the result lists them all).
  void _startJobs(String callId, String tool, Json async, Json details, _OpenCall? open, DateTime? at) {
    final type = async['type'] is String ? async['type'] as String : tool;
    final kind = switch (type) {
      'bash' => BackgroundKind.shell,
      'eval' => BackgroundKind.eval,
      'task' => BackgroundKind.agent,
      _ => BackgroundKind.other,
    };
    final secs = details['timeoutSeconds'];
    final deadline = secs is num && secs > 0 ? Duration(seconds: secs.round()) : null;
    final starts = <(String, String, String?)>[];
    final progress = details['progress'];
    if (type == 'task' && progress is List) {
      for (final p in progress) {
        final id = p is Map<String, dynamic> ? p['id'] : null;
        if (id is! String || id.isEmpty) continue;
        final what = p['assignment'] is String ? p['assignment'] : p['task'];
        starts.add((id, id, what is String && what.trim().isNotEmpty ? _cut(what.trim(), _assignmentChars) : null));
      }
    }
    final jobId = async['jobId'];
    if (starts.isEmpty && jobId is String && jobId.isNotEmpty) {
      final command = open?.command?.trim() ?? '';
      starts.add((jobId, command.isEmpty ? jobId : _cut(_firstLine(command), _titleChars), command.isEmpty ? null : _capText(command)));
    }
    for (final (id, title, detail) in starts) {
      _put(
        BackgroundTask(
          id: id,
          epoch: _bgEpoch,
          kind: kind,
          status: BackgroundStatus.running,
          title: title,
          detail: detail,
          startedAt: at,
          deadline: deadline,
          toolCallId: callId,
          stop: StopRoute.message,
        ),
      );
    }
  }

  /// An `async-result` notice: the jobs it names ended. It has a status for a
  /// subagent; for a shell job the text decides between done and failed.
  void _asyncResult(Json e) {
    final details = e['details'];
    final jobs = details is Map<String, dynamic> ? details['jobs'] : null;
    if (jobs is! List) return;
    final ids = [
      for (final j in jobs)
        if (j is Map<String, dynamic> && j['jobId'] is String) j['jobId'] as String,
    ];
    final bodies = _jobBodies(_resultText(e['content']), ids);
    for (final j in jobs) {
      if (j is! Map<String, dynamic> || j['jobId'] is! String) continue;
      final id = j['jobId'] as String;
      final status = j['status'];
      if (status is String) {
        if (!_stillRunning(status)) _finish(id, _statusOf(status), _stamp(e));
      } else {
        final failed = _failedText.hasMatch(bodies[id] ?? '');
        _finish(id, failed ? BackgroundStatus.failed : BackgroundStatus.finished, _stamp(e));
      }
    }
  }

  /// The part of a notice's [text] that belongs to each job: all of it for
  /// one job, the section under each `── Job <id>` header for several.
  static Map<String, String> _jobBodies(String text, List<String> ids) {
    if (ids.length == 1) return {ids.single: text};
    final heads = _jobHeader.allMatches(text).toList();
    return {
      for (var i = 0; i < heads.length; i++)
        heads[i].group(1)!: text.substring(heads[i].end, i + 1 < heads.length ? heads[i + 1].start : text.length),
    };
  }

  /// The process ended: what ran is gone and the next process counts ids from
  /// the start again.
  void _exitSession(DateTime? at) {
    for (final t in _tasks.values.toList()) {
      if (t.isActive) _tasks[t.key] = t.copyWith(status: BackgroundStatus.stopped, endedAt: at, stop: StopRoute.none);
    }
    _bgEpoch++;
    _tasksChanged();
  }

  void _put(BackgroundTask t) {
    _tasks.remove(t.key);
    _tasks[t.key] = t;
    _tasksChanged();
  }

  /// A task was added or ended: drops the cached list and keeps the latest
  /// [_finishedKept] finished tasks (the running ones always stay).
  void _tasksChanged() {
    _taskView = null;
    var extra = _tasks.values.where((x) => !x.isActive).length - _finishedKept;
    if (extra <= 0) return;
    final drop = <String>[];
    for (final x in _tasks.values) {
      if (extra == 0) break;
      if (x.isActive) continue;
      drop.add(x.key);
      extra--;
    }
    drop.forEach(_tasks.remove);
  }

  /// [id] of the current epoch ended as [status]; a task that is not running
  /// (unknown, or already ended) is left alone.
  void _finish(String id, BackgroundStatus status, DateTime? at) {
    final key = '$_bgEpoch/$id';
    final t = _tasks[key];
    if (t == null || !t.isActive) return;
    _tasks[key] = t.copyWith(status: status, endedAt: at, stop: StopRoute.none);
    _tasksChanged();
  }

  // -- subagents and messages between agents ---------------------------------

  static const _assignmentChars = 400;

  /// The names a `task` call spawns; each becomes a pending subagent unless it
  /// is known already.
  List<String> _taskNames(Json? args) {
    final tasks = args?['tasks'];
    if (tasks is! List) return const [];
    final names = <String>[];
    for (final t in tasks) {
      if (t is! Map<String, dynamic>) continue;
      final name = t['name'];
      if (name is! String || name.isEmpty) continue;
      names.add(name);
      final agent = t['agent'];
      final assignment = t['task'];
      _subagents.putIfAbsent(
        name,
        () => SubagentInfo(
          name: name,
          agent: agent is String ? agent : 'task',
          assignment: assignment is String ? _cut(assignment, _assignmentChars) : '',
        ),
      );
    }
    return names;
  }

  /// The subagents a `task` result's progress lists, or null when it lists none.
  static List<String>? _taskResultNames(Json? details) {
    final progress = details?['progress'];
    if (progress is! List) return null;
    final names = [
      for (final p in progress)
        if (p is Map<String, dynamic> && p['id'] is String && (p['id'] as String).isNotEmpty) p['id'] as String,
    ];
    return names.isEmpty ? null : names;
  }

  void _noteTask(Json? details) {
    final progress = details?['progress'];
    if (progress is! List) return;
    for (final p in progress) {
      if (p is! Map<String, dynamic>) continue;
      final name = p['id'];
      if (name is! String || name.isEmpty) continue;
      final old = _subagents[name];
      final assignment = p['assignment'] is String ? p['assignment'] : p['task'];
      final count = p['toolCount'];
      _subagents[name] = SubagentInfo(
        name: name,
        agent: p['agent'] is String ? p['agent'] as String : (old?.agent ?? ''),
        status: p['status'] is String ? p['status'] as String : (old?.status ?? 'pending'),
        assignment: assignment is String ? _cut(assignment, _assignmentChars) : (old?.assignment ?? ''),
        toolCount: count is num ? count.toInt() : (old?.toolCount ?? 0),
        recentTools: _toolNames(p['recentTools']) ?? old?.recentTools ?? const [],
      );
    }
  }

  static List<String>? _toolNames(Object? v) {
    if (v is! List) return null;
    final out = <String>[];
    for (final t in v) {
      final name = t is String ? t : (t is Map ? (t['tool'] ?? t['name'] ?? t['toolName']) : null);
      if (name is String && name.isNotEmpty) out.add(_cut(name, 60));
    }
    return out.length <= 5 ? out : out.sublist(out.length - 5);
  }

  /// `wait` reports the state of background jobs, subagents among them.
  void _noteWait(Json? details) {
    final jobs = details?['jobs'];
    if (jobs is! List) return;
    for (final j in jobs) {
      if (j is! Map<String, dynamic>) continue;
      final id = j['id'];
      final status = j['status'];
      if (id is! String || status is! String) continue;
      if (_subagents.containsKey(id) || j['type'] == 'task') _setStatus(id, status);
    }
  }

  /// An `async-result` notice: background jobs that finished.
  void _jobsFinished(Object? details) {
    final jobs = details is Map<String, dynamic> ? details['jobs'] : null;
    if (jobs is! List) return;
    for (final j in jobs) {
      if (j is! Map<String, dynamic> || j['type'] != 'task') continue;
      final id = j['jobId'];
      if (id is String && id.isNotEmpty) _setStatus(id, j['status'] is String ? j['status'] as String : 'completed');
    }
  }

  void _setStatus(String name, String status) {
    final old = _subagents[name];
    _subagents[name] = SubagentInfo(
      name: name,
      agent: old?.agent ?? '',
      status: status,
      assignment: old?.assignment ?? '',
      toolCount: old?.toolCount ?? 0,
      recentTools: old?.recentTools ?? const [],
    );
  }

  /// One line per subagent: `Name (agent): status, what it was asked`.
  String _roster(List<String> names) {
    final lines = <String>[];
    for (final name in names) {
      final s = _subagents[name];
      if (s == null) {
        lines.add(name);
        continue;
      }
      final what = _firstLine(s.assignment.trim());
      lines.add(
        '${s.name}${s.agent.isEmpty ? '' : ' (${s.agent})'}: ${s.status}${what.isEmpty ? '' : ' - ${_cut(what, 100)}'}',
      );
    }
    return lines.join('\n');
  }

  /// A message another agent sent to the observed one.
  List<SessionUpdate> _ircIncoming(Json e, String line) {
    final d = e['details'];
    if (d is! Map<String, dynamic>) return const [];
    final message = d['message'];
    if (message is! String || message.trim().isEmpty) return const [];
    final from = d['from'];
    final key = _firstTime(e, line);
    if (key == null) return const [];
    final who = from is String && from.isNotEmpty ? _cut(from, 80) : 'another agent';
    return [_upsert(MessageRole.agent, key, '$who → this agent: ${_cut(message.trim(), _assignmentChars)}')];
  }

  /// A `write` to `agent://<name>` is a message to another agent: a note, not
  /// a tool row. Null when [b] is something else.
  SessionUpdate? _agentWrite(Json b, String noteId) {
    if (b['name'] != 'write') return null;
    final id = b['id'];
    final args = _arguments(b['arguments']);
    final path = args?['path'];
    final content = args?['content'];
    if (id is! String || id.isEmpty || path is! String || !path.startsWith('agent://') || content is! String) {
      return null;
    }
    _hidden.add(id);
    final to = path.substring('agent://'.length);
    return _upsert(
      MessageRole.agent,
      noteId,
      'this agent → ${to == 'all' ? 'all agents' : _cut(to, 80)}: ${_cut(content.trim(), _assignmentChars)}',
    );
  }

  static SessionUpdate _cancelled(String id) =>
      ToolCallPatchUpdate(ToolCallPatch(id, {'toolCallId': id, 'status': 'cancelled'}));

  static String _resultText(Object? content) {
    if (content is String) return content;
    if (content is! List) return '';
    final parts = <String>[];
    for (final b in content) {
      if (b is! Map<String, dynamic>) continue;
      switch (b['type']) {
        case 'text':
          final t = b['text'];
          if (t is String && t.isNotEmpty) parts.add(t);
        case 'image':
          parts.add(_imageNote(b));
      }
    }
    return parts.join('\n');
  }

  // -- tool names, titles, kinds ---------------------------------------------

  static ToolKind _kindOf(String name) {
    switch (name.toLowerCase()) {
      case 'bash' || 'shell' || 'exec' || 'eval' || 'run_code' || 'python':
        return ToolKind.execute;
      case 'read':
        return ToolKind.read;
      case 'edit' || 'write' || 'patch' || 'apply_patch' || 'ast_edit' || 'multi_edit' || 'str_replace':
        return ToolKind.edit;
      case 'delete':
        return ToolKind.delete;
      case 'move':
        return ToolKind.move;
      case 'grep' || 'glob' || 'find' || 'search' || 'ast_grep':
        return ToolKind.search;
      case 'fetch' || 'web_search' || 'web_fetch' || 'websearch' || 'webfetch':
        return ToolKind.fetch;
      case 'todo' || 'think':
        return ToolKind.think;
      default:
        return ToolKind.other;
    }
  }

  static String _kindWire(ToolKind k) => switch (k) {
    ToolKind.read => 'read',
    ToolKind.edit => 'edit',
    ToolKind.delete => 'delete',
    ToolKind.move => 'move',
    ToolKind.search => 'search',
    ToolKind.execute => 'execute',
    ToolKind.think => 'think',
    ToolKind.fetch => 'fetch',
    ToolKind.switchMode => 'switch_mode',
    ToolKind.other => 'other',
  };

  /// The call's own words (`intent` / `i`), else what it works on.
  static String _toolTitle(String name, Json? args, String? intent) {
    final i = intent == null ? '' : _firstLine(intent.trim());
    if (i.isNotEmpty) return _cut(i, _titleChars);
    String? str(String key) => args?[key] is String && (args![key] as String).trim().isNotEmpty ? args[key] as String : null;
    final kind = _kindOf(name);
    final command = str('command');
    if (kind == ToolKind.execute && command != null) return _cut(_firstLine(command.trim()), _titleChars);
    if (name == 'ask') {
      final qs = args?['questions'];
      if (qs is List && qs.isNotEmpty && qs.first is Map && (qs.first as Map)['question'] is String) {
        return _cut(_firstLine(((qs.first as Map)['question'] as String).trim()), _titleChars);
      }
    }
    final subject = str('path') ?? command ?? str('pattern') ?? str('query');
    if (subject != null) return _cut('$name: ${_firstLine(subject.trim())}', _titleChars);
    return name;
  }

  static final _scheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://');
  static final _readSelector = RegExp(r'^(.+):(\d+)(?:[-+,]\d+)*$');
  static final _hashlineHeader = RegExp(r'^\[([^\]\n#]+)#[0-9A-Za-z]+\]', multiLine: true);

  String _abs(String path) {
    final cwd = _cwd;
    if (cwd == null || path.startsWith('/') || _scheme.hasMatch(path)) return path;
    final rel = path.startsWith('./') ? path.substring(2) : path;
    return cwd.endsWith('/') ? '$cwd$rel' : '$cwd/$rel';
  }

  List<ToolLocation> _locationsOfCall(String name, Json? args) {
    if (args == null) return const [];
    final out = <ToolLocation>[];
    final seen = <String>{};
    void add(Object? raw, {int? line}) {
      if (raw is! String || raw.isEmpty || _scheme.hasMatch(raw)) return;
      final p = _abs(raw);
      if (seen.add(p)) out.add(ToolLocation(path: p, line: line));
    }

    final path = args['path'];
    if (path is String && name == 'read') {
      final m = _readSelector.firstMatch(path);
      if (m != null) {
        add(m.group(1), line: int.tryParse(m.group(2)!));
      } else {
        add(path);
      }
    } else {
      add(path);
    }
    add(args['oldPath']);
    add(args['newPath']);
    final input = args['input'];
    if (input is String && _kindOf(name) == ToolKind.edit) {
      for (final h in _hashlineHeader.allMatches(input)) {
        add(h.group(1));
      }
    }
    return out;
  }

  List<Json> _locationsOfResult(Json? details) {
    if (details == null) return const [];
    final out = <Json>[];
    final seen = <String>{};
    void add(Object? raw) {
      if (raw is! String || raw.isEmpty || _scheme.hasMatch(raw)) return;
      final p = _abs(raw);
      if (seen.add(p)) out.add({'path': p});
    }

    add(details['path']);
    add(details['resolvedPath']);
    final per = details['perFileResults'];
    if (per is List) {
      for (final f in per) {
        if (f is Map<String, dynamic>) add(f['path']);
      }
    }
    return out;
  }

  // -- diffs -----------------------------------------------------------------

  /// The change a call's arguments describe: a `write` (new text only), or an
  /// edit that names the old and the new text. Hashline and patch edits carry
  /// neither; their result does.
  List<ToolDiff> _startDiffs(String name, Json? args) {
    if (args == null) return const [];
    final path = args['path'];
    if (path is! String || path.isEmpty) return const [];
    ToolDiff? one(Object? from, Object? to) =>
        from is String && to is String ? ToolDiff(path: _abs(path), oldText: _capText(from), newText: _capText(to)) : null;

    final out = <ToolDiff>[];
    if (name == 'write' && args['content'] is String) {
      out.add(ToolDiff(path: _abs(path), newText: _capText(args['content'] as String)));
      return out;
    }
    if (_kindOf(name) != ToolKind.edit) return const [];
    for (final (from, to) in const [('old_string', 'new_string'), ('oldText', 'newText'), ('old_text', 'new_text')]) {
      final d = one(args[from], args[to]);
      if (d != null) out.add(d);
    }
    final edits = args['edits'];
    if (edits is List) {
      for (final e in edits) {
        if (e is! Map<String, dynamic>) continue;
        for (final (from, to) in const [('old_string', 'new_string'), ('oldText', 'newText'), ('old_text', 'new_text')]) {
          final d = one(e[from], e[to]);
          if (d != null) out.add(d);
        }
      }
    }
    return out;
  }

  /// The changes an edit result reports, one per file.
  List<ToolDiff> _resultDiffs(Json? details) {
    if (details == null) return const [];
    final per = details['perFileResults'];
    final entries = per is List ? per : [details];
    final out = <ToolDiff>[];
    for (final e in entries) {
      if (e is! Map<String, dynamic> || e['isError'] == true) continue;
      final path = e['path'];
      if (path is! String || path.isEmpty) continue;
      final from = e['oldText'];
      final to = e['newText'];
      if (from is! String && to is! String) continue;
      out.add(
        ToolDiff(
          path: _abs(path),
          oldText: from is String ? _capText(from) : null,
          newText: to is String ? _capText(to) : '',
        ),
      );
    }
    return out;
  }

  // -- plan ------------------------------------------------------------------

  /// The plan from omp's todo phases (`[{name, tasks:[{content, status}]}]`);
  /// null when [phases] is not a list.
  static PlanUpdate? _plan(Object? phases) {
    if (phases is! List) return null;
    final entries = <PlanEntry>[];
    for (final phase in phases) {
      if (phase is! Map<String, dynamic>) continue;
      final tasks = phase['tasks'];
      if (tasks is! List) continue;
      for (final t in tasks) {
        if (t is! Map<String, dynamic>) continue;
        final content = t['content'];
        if (content is! String || content.isEmpty) continue;
        entries.add(PlanEntry(content: _cut(content, 300), status: _planStatus(t['status'])));
      }
    }
    return PlanUpdate(entries);
  }

  static PlanStatus _planStatus(Object? s) => switch (s) {
    'in_progress' => PlanStatus.inProgress,
    'completed' => PlanStatus.completed,
    'abandoned' => PlanStatus.cancelled,
    _ => PlanStatus.pending,
  };

  // -- the question tool -----------------------------------------------------

  static PendingAsk? _parseAsk(String id, Json? args) {
    final qs = args?['questions'];
    if (qs is! List) return null;
    final out = <AskQuestion>[];
    for (var i = 0; i < qs.length; i++) {
      final q = qs[i];
      if (q is! Map<String, dynamic>) continue;
      final options = <AskOption>[];
      final raw = q['options'];
      if (raw is List) {
        for (final o in raw) {
          if (o is String) {
            options.add(AskOption(label: _cut(o, 300)));
          } else if (o is Map<String, dynamic> && o['label'] is String) {
            final d = o['description'];
            options.add(AskOption(label: _cut(o['label'] as String, 300), description: d is String ? _capText(d) : ''));
          }
        }
      }
      final rec = q['recommended'];
      final recommended = rec is num && rec >= 0 && rec < options.length ? rec.toInt() : null;
      final qid = q['id'];
      final question = q['question'];
      out.add(
        AskQuestion(
          id: qid is String && qid.isNotEmpty ? qid : 'q$i',
          question: question is String ? _capText(question) : '',
          options: options,
          multi: q['multi'] == true,
          recommended: recommended,
        ),
      );
    }
    return out.isEmpty ? null : PendingAsk(toolCallId: id, questions: out);
  }

  // -- plumbing --------------------------------------------------------------

  /// The key a message entry is told apart by (its id, else a hash of the
  /// line), or null when this mapper has mapped it before.
  String? _firstTime(Json e, String line) {
    final id = e['id'];
    final key = id is String && id.isNotEmpty ? id : 'h${_fnv(line)}';
    return _seen.add(key) ? key : null;
  }

  static String _fnv(String s) {
    var h = 0x811c9dc5;
    for (var i = 0; i < s.length; i++) {
      h ^= s.codeUnitAt(i);
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16);
  }

  static String _firstLine(String s) {
    final i = s.indexOf('\n');
    return i < 0 ? s : s.substring(0, i);
  }

  /// [s] cut to [max] characters with an ellipsis.
  static String _cut(String s, int max) {
    if (s.length <= max) return s;
    return '${s.substring(0, _safeEnd(s, max - 1))}…';
  }

  /// [s] cut at [maxFieldChars] with a visible marker; whole when shorter.
  static String _capText(String s) {
    if (s.length <= maxFieldChars) return s;
    return '${s.substring(0, _safeEnd(s, maxFieldChars))}$_cutMark';
  }

  /// [end], or one less when it would split a surrogate pair.
  static int _safeEnd(String s, int end) {
    if (end > 0 && end < s.length) {
      final u = s.codeUnitAt(end - 1);
      if (u >= 0xD800 && u <= 0xDBFF) return end - 1;
    }
    return end;
  }

  /// A copy of [v] whose strings are capped.
  static Object? _capJson(Object? v) {
    if (v is String) return _capText(v);
    if (v is List) return [for (final e in v) _capJson(e)];
    if (v is Map) return {for (final e in v.entries) e.key.toString(): _capJson(e.value)};
    return v;
  }
}

class _OpenCall {
  const _OpenCall(this.name, this.diffs, this.names, {this.command});

  final String name;

  /// The change the call's arguments described, kept until the result.
  final List<ToolDiff> diffs;

  /// The subagents a `task` call spawns.
  final List<String> names;

  /// The shell command or code cell, for a background job's title.
  final String? command;
}
