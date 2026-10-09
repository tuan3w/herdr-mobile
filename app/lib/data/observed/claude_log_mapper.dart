import 'dart:convert';

import '../acp/acp_models.dart';
import '../acp/background/background_work.dart';
import 'log_mapping.dart';
import 'observed_contracts.dart';

/// Maps the lines of a Claude Code session log
/// (`~/.claude/projects/<cwd>/<sessionId>.jsonl`) to the updates
/// `AgentSessionState.apply` understands, so that a Claude Code turn reads on
/// the phone the way the same turn of an ACP session does.
///
/// What the log looks like (Claude Code 2.1, captured in
/// `test/fixtures/claude_logs/`): one JSON object per line, in the order the
/// file was written. An API message is split into one line per content block
/// (same `message.id`, `apiBlockIndex` 0..N-1), a tool call is written before
/// the tool finishes, and each tool result is a line of its own that pairs with
/// its call only by `tool_use_id`. `parentUuid` is not a chain and timestamps
/// are not monotonic: only the file order is used.
///
/// Lines read (everything else maps to nothing, and so does anything
/// malformed):
/// - `assistant`: `text`, `thinking` (only when it holds text: the log keeps
///   only an opaque signature) and `tool_use` blocks; a synthetic API error;
/// - `user`: the person's prompt, a slash command, a `tool_result`, the
///   `[Request interrupted by user]` marker, a background task's
///   `<task-notification>`; housekeeping (`isMeta`, caveats, reminders, a
///   non-human `origin`) stays hidden;
/// - `attachment` of type `queued_command` (a prompt typed while a turn ran);
/// - `system`: `turn_duration` (the turn is over), `compact_boundary`,
///   `local_command`, `informational`;
/// - `ai-title` (the session title).
///
/// A subagent's transcript (`<session>/subagents/agent-<id>.jsonl`) has the
/// same format with `isSidechain: true` on every line: the main file's mapper
/// skips those lines, a mapper made with `sidechain: true` maps only them.
///
/// Idempotent: a line is mapped once (its `uuid`, else a hash of the line), a
/// message is a whole-message upsert, a tool call is keyed by its id and
/// patches replace, so the same file fed twice (a resume that overlaps, a
/// reconnect) changes nothing. Reset the mapper together with the state it
/// feeds.
class ClaudeLogMapper implements SessionLogMapper {
  ClaudeLogMapper({this.sidechain = false});

  /// Maps a subagent's transcript instead of the main file.
  final bool sidechain;

  static const _titleChars = 120;
  static const _assignmentChars = 400;
  static const _finishedKept = 30;

  /// Line ids already mapped.
  final _seen = <String>{};

  /// Every tool call id that started, so that a result for an unseen start (a
  /// log followed from the middle) can name the call itself.
  final _started = <String>{};

  /// Calls that started and have no result yet.
  final _open = <String, _OpenCall>{};

  /// Calls that are not shown (their results are dropped).
  final _hidden = <String>{};

  PendingAsk? _ask;
  String? _cwd;
  String? _lastTyped;

  /// Prompts shown when they were typed, waiting for their second record.
  final _queued = <String>{};
  var _turnEnded = false;

  /// The task list as `TaskCreate` and `TaskUpdate` build it: id -> task.
  final _taskList = <String, _Task>{};

  /// Subagents by call id, in the order they started.
  final _subagents = <String, SubagentInfo>{};

  /// Background tasks by [BackgroundTask.key], in the order they started.
  final _tasks = <String, BackgroundTask>{};
  List<BackgroundTask>? _taskView;

  @override
  PendingAsk? get pendingAsk => _ask;

  @override
  Set<String> get openToolCalls => {
    // A subagent's call stays open for its whole run: it is a task, not what a
    // permission dialog asks about.
    for (final e in _open.entries)
      if (e.value.name != 'Agent' && e.value.name != 'Task') e.key,
  };

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
    _hidden.clear();
    _ask = null;
    _cwd = null;
    _lastTyped = null;
    _queued.clear();
    _turnEnded = false;
    _taskList.clear();
    _subagents.clear();
    _tasks.clear();
    _taskView = null;
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
      return _line(decoded, line);
    } on Object {
      return const [];
    }
  }

  // -- lines -------------------------------------------------------------------

  List<SessionUpdate> _line(Json e, String line) {
    final side = e['isSidechain'] == true;
    if (side != sidechain) return const [];
    final cwd = e['cwd'];
    if (_cwd == null && cwd is String && cwd.isNotEmpty) _cwd = cwd;
    final type = e['type'];
    if (type is! String) return const [];
    switch (type) {
      case 'assistant' || 'user' || 'attachment' || 'system' || 'ai-title' || 'queue-operation':
        final key = _firstTime(e, line);
        if (key == null) return const [];
        return switch (type) {
          'assistant' => _assistant(e, key),
          'user' => _user(e, key),
          'attachment' => _attachment(e, key),
          'system' => _system(e, key),
          'queue-operation' => _enqueued(e),
          _ => _title(e),
        };
      default:
        return const [];
    }
  }

  /// The key of [e] (its `uuid`, else a hash of its [line]), or null when this
  /// mapper has mapped it before.
  String? _firstTime(Json e, String line) {
    final id = e['uuid'];
    final key = id is String && id.isNotEmpty ? id : 'h${fnv(line)}';
    return _seen.add(key) ? key : null;
  }

  /// A prompt typed while a turn runs is written here at once, and again
  /// (as a line or an attachment) seconds later, when the turn takes it. The
  /// person typed it now: it shows now, under a key made from its text so the
  /// later record is the same message.
  List<SessionUpdate> _enqueued(Json e) {
    if (e['operation'] != 'enqueue') return const [];
    final text = e['content'];
    if (text is! String || text.trim().isEmpty || text.trimLeft().startsWith('<')) return const [];
    _queued.add(text.trim());
    return [messageUpsert(MessageRole.user, _queuedKey(text), text)];
  }

  static String _queuedKey(String text) => 'q:${fnv(text.trim())}';

  /// The key of a message of the person: its own, unless it was shown when it
  /// was typed.
  String _messageKey(String key, String text) => _queued.remove(text.trim()) ? _queuedKey(text) : key;

  List<SessionUpdate> _title(Json e) {
    final t = e['aiTitle'];
    if (t is! String || t.trim().isEmpty) return const [];
    return [SessionInfoUpdate(hasTitle: true, title: cutText(t.trim(), 200), hasUpdatedAt: false)];
  }

  List<SessionUpdate> _system(Json e, String key) {
    switch (e['subtype']) {
      case 'turn_duration':
        _turnEnded = true;
        return const [];
      case 'compact_boundary':
        return [messageUpsert(MessageRole.agent, key, 'Earlier messages were summarised')];
      case 'local_command' || 'informational':
        // A command's output line, not a hook's report (`/compact` prints a JSON
        // snapshot of the session after its first line).
        final text = cutText(firstLine(_strip((e['content'] is String ? e['content'] as String : '').replaceAll(_ansi, ''))), 300);
        return text.isEmpty ? const [] : [messageUpsert(MessageRole.agent, key, text)];
      default:
        return const [];
    }
  }

  static final _tag = RegExp(r'<[^<>]{1,200}>');
  static final _ansi = RegExp('\u001b\\[[0-9;]*[A-Za-z]');

  /// [s] without its XML-ish tags, trimmed.
  static String _strip(String s) => s.replaceAll(_tag, '').trim();

  List<SessionUpdate> _attachment(Json e, String key) {
    final a = e['attachment'];
    if (a is! Map<String, dynamic> || a['type'] != 'queued_command') return const [];
    final prompt = a['prompt'];
    if (prompt is! String || prompt.trim().isEmpty) return const [];
    // A background job's notice that waited for the turn to end (a job the
    // person stopped is told this way only): not something they typed.
    if (a['commandMode'] == 'task-notification' || prompt.trimLeft().startsWith('<task-notification>')) {
      return _taskNotification(prompt.trimLeft(), parseStamp(a), wakes: false);
    }
    _turnEnded = false;
    return [..._userClears(), messageUpsert(MessageRole.user, _messageKey(key, prompt), prompt)];
  }

  // -- assistant ---------------------------------------------------------------

  List<SessionUpdate> _assistant(Json e, String key) {
    final m = e['message'];
    if (m is! Map<String, dynamic>) return const [];
    final content = m['content'];
    if (m['model'] == '<synthetic>') {
      if (e['isApiErrorMessage'] != true) return const [];
      final text = _textOf(content);
      _turnEnded = true;
      return text.isEmpty ? const [] : [messageUpsert(MessageRole.agent, '$key:error', 'The turn failed: $text')];
    }
    if (content is! List) return const [];
    final msgId = m['id'] is String && (m['id'] as String).isNotEmpty ? m['id'] as String : key;
    final apiIndex = e['apiBlockIndex'];
    final out = <SessionUpdate>[];
    for (var i = 0; i < content.length; i++) {
      final b = content[i];
      if (b is! Map<String, dynamic>) continue;
      final id = '$msgId:${apiIndex is int ? apiIndex + i : i}';
      switch (b['type']) {
        case 'text':
          final t = b['text'];
          if (t is String && t.trim().isNotEmpty) out.add(messageUpsert(MessageRole.agent, id, t));
        case 'thinking':
          final t = b['thinking'];
          if (t is String && t.trim().isNotEmpty) out.add(messageUpsert(MessageRole.thought, id, t));
        case 'tool_use':
          out.addAll(_toolStart(b));
      }
    }
    _turnEnded = m['stop_reason'] == 'end_turn' && _open.isEmpty;
    return out;
  }

  // -- user --------------------------------------------------------------------

  List<SessionUpdate> _user(Json e, String key) {
    final m = e['message'];
    if (m is! Map<String, dynamic>) return const [];
    final content = m['content'];
    if (content is List && content.any((b) => b is Map && b['type'] == 'tool_result')) {
      final out = <SessionUpdate>[];
      for (final b in content) {
        if (b is Map<String, dynamic> && b['type'] == 'tool_result') out.addAll(_toolResult(e, b));
      }
      _turnEnded = false;
      return out;
    }
    final text = _textOf(content);
    final head = text.trimLeft();
    if (head.startsWith('<task-notification>')) return _taskNotification(head, parseStamp(e), wakes: true);
    if (e['isMeta'] == true || e['isCompactSummary'] == true) return const [];
    final origin = e['origin'];
    if (origin is Map && origin['kind'] != null && origin['kind'] != 'human') return const [];
    if (head.isEmpty ||
        head.startsWith('<local-command-caveat>') ||
        head.startsWith('<system-reminder>')) {
      return const [];
    }
    if (head.startsWith('<local-command-stdout>')) {
      final inner = cutText(firstLine(_strip(head.replaceAll(_ansi, ''))), 300);
      return inner.isEmpty ? const [] : [messageUpsert(MessageRole.agent, key, inner)];
    }
    if (head.startsWith('<command-name>')) {
      final name = _between(head, 'command-name');
      final args = _between(head, 'command-args');
      if (name == null || name.isEmpty) return const [];
      final typed = args == null || args.isEmpty ? name : '$name $args';
      // Claude writes the line the person typed and then the command's own
      // record: one message.
      if (typed == _lastTyped) {
        _lastTyped = null;
        return const [];
      }
      _turnEnded = false;
      return [..._userClears(), messageUpsert(MessageRole.user, key, typed)];
    }
    if (head.startsWith('[Request interrupted by user')) {
      _turnEnded = true;
      return [..._cancelOpen(), messageUpsert(MessageRole.agent, key, 'Interrupted')];
    }
    _turnEnded = false;
    _lastTyped = text.trim();
    return [..._userClears(), messageUpsert(MessageRole.user, _messageKey(key, text), text)];
  }

  static String? _between(String s, String tag) {
    final m = RegExp('<$tag>(.*?)</$tag>', dotAll: true).firstMatch(s);
    return m?.group(1)?.trim();
  }

  /// A string, or the text blocks of a content list joined.
  static String _textOf(Object? content) {
    if (content is String) return content;
    if (content is! List) return '';
    final parts = [
      for (final b in content)
        if (b is Map<String, dynamic> && b['type'] == 'text' && b['text'] is String) b['text'] as String,
    ];
    return parts.join('\n');
  }

  /// A later message from the person ends a question that is still open: the
  /// answer, if any, was typed in the terminal.
  List<SessionUpdate> _userClears() {
    final ask = _ask;
    if (ask == null) return const [];
    _ask = null;
    if (_open.remove(ask.toolCallId) == null) return const [];
    return [cancelledPatch(ask.toolCallId)];
  }

  /// Everything still running is cancelled (the turn was interrupted).
  List<SessionUpdate> _cancelOpen() {
    if (_open.isEmpty) return const [];
    final out = [for (final id in _open.keys) cancelledPatch(id)];
    _open.clear();
    _ask = null;
    return out;
  }

  // -- tool calls --------------------------------------------------------------

  List<SessionUpdate> _toolStart(Json b) {
    final id = b['id'];
    if (id is! String || id.isEmpty) return const [];
    final rawName = b['name'];
    final name = rawName is String && rawName.isNotEmpty ? rawName : 'tool';
    final input = b['input'] is Map<String, dynamic> ? b['input'] as Json : null;
    // Loading a deferred tool's definition is the agent's housekeeping.
    if (name == 'ToolSearch') {
      _hidden.add(id);
      return const [];
    }
    final diffs = _startDiffs(name, input);
    _started.add(id);
    _open[id] = _OpenCall(name, diffs, input);
    if (name == 'AskUserQuestion') _ask = _parseAsk(id, input);
    if (name == 'Agent' || name == 'Task') _startSubagent(id, input);
    final out = <SessionUpdate>[
      ToolCallStart(
        ToolCall(
          toolCallId: id,
          name: name,
          title: _title0(name, input),
          kind: _kindOf(name),
          status: ToolStatus.inProgress,
          rawInput: input == null ? null : capJson(input),
          content: diffs,
          locations: _locations(input),
        ),
      ),
    ];
    if (name == 'TodoWrite') {
      final plan = _todoPlan(input?['todos']);
      if (plan != null) out.add(plan);
    }
    return out;
  }

  List<SessionUpdate> _toolResult(Json line, Json b) {
    final id = b['tool_use_id'];
    if (id is! String || id.isEmpty) return const [];
    if (_hidden.contains(id)) return const [];
    final at = parseStamp(line);
    final open = _open.remove(id);
    final known = _started.contains(id);
    _started.add(id);
    final name = open?.name ?? 'tool';
    final extra = line['toolUseResult'];
    final result = extra is Map<String, dynamic> ? extra : null;
    var text = _resultText(b['content']);
    if (name == 'Bash' && result != null) {
      final stdout = result['stdout'];
      final stderr = result['stderr'];
      final err = stderr is String ? stderr : '';
      if (stdout is String && (stdout.isNotEmpty || err.isNotEmpty)) {
        text = err.isNotEmpty ? '$stdout\nstderr:\n$err' : stdout;
      }
    }
    final isError = b['is_error'] == true;
    final denied = isError && (line['toolDenialKind'] == 'user-rejected' || text.startsWith("The user doesn't want to proceed"));
    final status = denied ? 'cancelled' : (isError ? 'failed' : 'completed');

    final content = <ToolContent>[];
    if (!isError) {
      content.addAll(_finishDiffs(open, result));
    }
    if (text.isNotEmpty) content.add(ToolContentBlock(TextBlock(capText(text))));
    final locations = open == null ? const <ToolLocation>[] : _locations(open.input);
    final fields = <String, Object?>{
      'toolCallId': id,
      if (!known) ...{'name': name, 'title': name, 'kind': kindWire(_kindOf(name))},
      'status': status,
      'content': [for (final c in content) c.toJson()],
      if (text.isNotEmpty) 'rawOutput': capText(text),
      if (locations.isNotEmpty) 'locations': [for (final l in locations) {'path': l.path, 'line': ?l.line}],
    };
    if (_ask?.toolCallId == id) _ask = null;
    final out = <SessionUpdate>[ToolCallPatchUpdate(ToolCallPatch(id, fields))];
    if (open?.name == 'Agent' || open?.name == 'Task') _noteSubagent(id, result, isError, at);
    if (!isError) {
      out.addAll(_foldTask(open, result));
      _noteBackground(id, open, result, at);
    }
    return out;
  }

  /// The change the finished call made: its input's diffs, with the old text of
  /// a `Write` from the result when the file existed.
  List<ToolDiff> _finishDiffs(_OpenCall? open, Json? result) {
    final diffs = open?.diffs ?? const <ToolDiff>[];
    if (open?.name != 'Write' || diffs.length != 1) return diffs;
    final original = result?['originalFile'];
    if (original is! String) return diffs;
    return [ToolDiff(path: diffs.single.path, oldText: capText(original), newText: diffs.single.newText)];
  }

  static String _resultText(Object? content) {
    if (content is String) return content;
    if (content is! List) return '';
    final parts = <String>[];
    for (final p in content) {
      if (p is! Map<String, dynamic>) continue;
      switch (p['type']) {
        case 'text':
          if (p['text'] is String) parts.add(p['text'] as String);
        case 'image':
          parts.add('[image]');
      }
    }
    return parts.join('\n');
  }

  static ToolKind _kindOf(String name) {
    switch (name) {
      case 'Bash' || 'BashOutput':
        return ToolKind.execute;
      case 'Read' || 'NotebookRead':
        return ToolKind.read;
      case 'Write' || 'Edit' || 'MultiEdit' || 'NotebookEdit':
        return ToolKind.edit;
      case 'Grep' || 'Glob' || 'LS':
        return ToolKind.search;
      case 'WebFetch' || 'WebSearch':
        return ToolKind.fetch;
      case 'ExitPlanMode':
        return ToolKind.switchMode;
      case 'TodoWrite' || 'TaskCreate' || 'TaskUpdate' || 'TaskList' || 'TaskGet':
        return ToolKind.think;
      default:
        return ToolKind.other;
    }
  }

  /// The call's own description (a `Bash`'s), else the tool and what it works
  /// on.
  static String _title0(String name, Json? input) {
    String? str(String key) {
      final v = input?[key];
      return v is String && v.trim().isNotEmpty ? v : null;
    }

    if (name.startsWith('mcp__')) {
      final parts = name.split('__');
      if (parts.length >= 3) return cutText('${parts[1]}: ${parts.sublist(2).join('__')}', _titleChars);
    }
    switch (name) {
      case 'Bash':
        final d = str('description');
        if (d != null) return cutText(firstLine(d.trim()), _titleChars);
        final c = str('command');
        return c == null ? name : cutText(firstLine(c.trim()), _titleChars);
      case 'AskUserQuestion':
        final qs = input?['questions'];
        if (qs is List && qs.isNotEmpty && qs.first is Map && (qs.first as Map)['question'] is String) {
          return cutText(firstLine(((qs.first as Map)['question'] as String).trim()), _titleChars);
        }
        return name;
      case 'ExitPlanMode':
        return 'Plan for approval';
      case 'TodoWrite':
        return 'Task list';
      case 'TaskUpdate':
        final id = input?['taskId'];
        final status = str('status');
        return id == null ? name : 'Task #$id${status == null ? '' : ': ${status.replaceAll('_', ' ')}'}';
    }
    final path = str('file_path') ?? str('path') ?? str('notebook_path');
    final subject = path != null
        ? path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path
        : str('pattern') ?? _host(str('url')) ?? str('query') ?? str('skill') ?? str('subject') ?? str('description');
    if (subject == null) return name;
    return cutText('$name: ${firstLine(subject.trim())}', _titleChars);
  }

  static String? _host(String? url) {
    if (url == null) return null;
    final uri = Uri.tryParse(url);
    return uri == null || uri.host.isEmpty ? url : uri.host;
  }

  // -- paths and diffs ---------------------------------------------------------

  static final _scheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://');

  String _abs(String path) {
    final cwd = _cwd;
    if (cwd == null || path.startsWith('/') || _scheme.hasMatch(path)) return path;
    final rel = path.startsWith('./') ? path.substring(2) : path;
    return cwd.endsWith('/') ? '$cwd$rel' : '$cwd/$rel';
  }

  List<ToolLocation> _locations(Json? input) {
    if (input == null) return const [];
    for (final key in const ['file_path', 'path', 'notebook_path']) {
      final v = input[key];
      if (v is String && v.isNotEmpty && !_scheme.hasMatch(v)) return [ToolLocation(path: _abs(v))];
    }
    return const [];
  }

  /// The change a call's input describes: an `Edit` or `MultiEdit` (old and new
  /// text) or a `Write` (new text only; the old comes with the result). The
  /// result's `structuredPatch` and `originalFile` are not used otherwise: they
  /// are huge.
  List<ToolDiff> _startDiffs(String name, Json? input) {
    if (input == null) return const [];
    final path = input['file_path'] is String ? input['file_path'] as String : input['notebook_path'];
    if (path is! String || path.isEmpty) return const [];
    final abs = _abs(path);
    switch (name) {
      case 'Write':
        final c = input['content'];
        return c is String ? [ToolDiff(path: abs, newText: capText(c))] : const [];
      case 'Edit':
        final from = input['old_string'];
        final to = input['new_string'];
        return from is String && to is String ? [ToolDiff(path: abs, oldText: capText(from), newText: capText(to))] : const [];
      case 'MultiEdit':
        final edits = input['edits'];
        if (edits is! List) return const [];
        return [
          for (final ed in edits)
            if (ed is Map && ed['old_string'] is String && ed['new_string'] is String)
              ToolDiff(path: abs, oldText: capText(ed['old_string'] as String), newText: capText(ed['new_string'] as String)),
        ];
      default:
        return const [];
    }
  }

  // -- the question tool -------------------------------------------------------

  /// Claude adds its own "Other" row to every question: not one of ours.
  static PendingAsk? _parseAsk(String id, Json? input) {
    final qs = input?['questions'];
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
            options.add(AskOption(label: cutText(o, 300)));
          } else if (o is Map<String, dynamic> && o['label'] is String) {
            final d = o['description'];
            options.add(AskOption(label: cutText(o['label'] as String, 300), description: d is String ? capText(d) : ''));
          }
        }
      }
      final header = q['header'];
      final question = q['question'];
      out.add(
        AskQuestion(
          id: header is String && header.isNotEmpty ? header : 'q$i',
          question: question is String ? capText(question) : '',
          options: options,
          multi: q['multiSelect'] == true,
        ),
      );
    }
    return out.isEmpty ? null : PendingAsk(toolCallId: id, questions: out);
  }

  // -- the task list -----------------------------------------------------------

  static PlanStatus _planStatus(Object? s) => switch (s) {
    'in_progress' => PlanStatus.inProgress,
    'completed' => PlanStatus.completed,
    _ => PlanStatus.pending,
  };

  /// The plan from `TodoWrite`'s `todos`; null when it is not a list.
  static PlanUpdate? _todoPlan(Object? todos) {
    if (todos is! List) return null;
    final entries = <PlanEntry>[];
    for (final t in todos) {
      if (t is! Map<String, dynamic>) continue;
      final content = t['content'];
      if (content is! String || content.isEmpty) continue;
      entries.add(PlanEntry(content: cutText(content, 300), status: _planStatus(t['status'])));
    }
    return PlanUpdate(entries);
  }

  /// A finished `TaskCreate` or `TaskUpdate` changes the task list: the whole
  /// plan is sent again.
  List<SessionUpdate> _foldTask(_OpenCall? open, Json? result) {
    if (open == null) return const [];
    switch (open.name) {
      case 'TaskCreate':
        final task = result?['task'];
        final id = task is Map ? task['id'] : null;
        final subject = open.input?['subject'];
        if (id == null || subject is! String) return const [];
        _taskList['$id'] = _Task(subject, PlanStatus.pending);
      case 'TaskUpdate':
        final id = open.input?['taskId'];
        final have = id == null ? null : _taskList['$id'];
        if (have == null) return const [];
        final status = open.input?['status'];
        if (status == 'deleted') {
          _taskList.remove('$id');
        } else {
          final subject = open.input?['subject'];
          _taskList['$id'] = _Task(
            subject is String && subject.isNotEmpty ? subject : have.subject,
            status is String ? _planStatus(status) : have.status,
          );
        }
      default:
        return const [];
    }
    return [PlanUpdate([for (final t in _taskList.values) PlanEntry(content: cutText(t.subject, 300), status: t.status)])];
  }

  // -- background work ---------------------------------------------------------

  static final _safeId = RegExp(r'^[A-Za-z0-9_.:-]{1,64}$');

  /// A finished call that left a job running: a `Bash` with
  /// `run_in_background` (or one Claude moved to the background itself) says
  /// its `backgroundTaskId` in the result.
  void _noteBackground(String callId, _OpenCall? open, Json? result, DateTime? at) {
    if (open == null) return;
    final id = result?['backgroundTaskId'];
    if (id is String && _safeId.hasMatch(id)) {
      final command = open.input?['command'];
      final text = command is String ? command.trim() : '';
      _put(
        BackgroundTask(
          id: id,
          kind: BackgroundKind.shell,
          status: BackgroundStatus.running,
          title: text.isEmpty ? id : cutText(firstLine(text), _titleChars),
          detail: text.isEmpty ? null : capText(text),
          startedAt: at,
          toolCallId: callId,
          stop: StopRoute.message,
        ),
      );
    }
    // A workflow or a monitor is a background task of its own: the official
    // tool schema (`WorkflowOutput`, `MonitorOutput`) gives its `taskId`; it
    // ends by a `<task-notification>` like the others.
    if (open.name == 'Workflow' || open.name == 'Monitor') {
      final task = result?['taskId'];
      if (task is String && _safeId.hasMatch(task)) {
        final workflow = open.name == 'Workflow';
        final Object? named = workflow ? (result?['workflowName'] ?? open.input?['name']) : open.input?['description'];
        final title = named is String && named.trim().isNotEmpty ? cutText(firstLine(named.trim()), _titleChars) : open.name;
        _put(
          BackgroundTask(
            id: task,
            kind: workflow ? BackgroundKind.workflow : BackgroundKind.monitor,
            status: BackgroundStatus.running,
            title: title,
            startedAt: at,
            toolCallId: callId,
            stop: StopRoute.message,
          ),
        );
      }
    }
    if (open.name == 'TaskStop' || open.name == 'KillShell') {
      final target = open.input?['task_id'] ?? open.input?['shell_id'] ?? open.input?['taskId'];
      if (target is String) _finish(target, BackgroundStatus.stopped, at);
    }
  }

  /// The notice Claude gives itself when a background job ends: its task id
  /// and `completed`, `failed` or `killed`. It starts a new turn (the agent
  /// reacts to it).
  List<SessionUpdate> _taskNotification(String text, DateTime? at, {required bool wakes}) {
    // Only a notice delivered as a message of its own starts a turn; one that
    // waited for the person's next prompt (a job they stopped) does not.
    if (wakes) _turnEnded = false;
    final id = _between(text, 'task-id');
    final status = _between(text, 'status');
    if (id == null) return const [];
    final ended = switch (status) {
      'failed' => BackgroundStatus.failed,
      'killed' || 'stopped' || 'cancelled' => BackgroundStatus.stopped,
      _ => BackgroundStatus.finished,
    };
    _finish(id, ended, at);
    for (final e in _subagents.entries.toList()) {
      if (e.value.logId != id) continue;
      _subagents[e.key] = _withStatus(
        e.value,
        switch (ended) {
          BackgroundStatus.failed => 'failed',
          BackgroundStatus.stopped => 'aborted',
          _ => 'completed',
        },
      );
    }
    return const [];
  }

  // -- subagents ---------------------------------------------------------------

  /// An `Agent` call: the subagent it starts, running until its result or its
  /// notice says otherwise. Its transcript is another file
  /// (`<session>/subagents/agent-<agentId>.jsonl`), found by [SubagentInfo.logId]
  /// or by [SubagentInfo.callId] (the file's `.meta.json` names the call).
  void _startSubagent(String callId, Json? input) {
    if (sidechain) return;
    final description = input?['description'];
    final type = input?['subagent_type'];
    final prompt = input?['prompt'];
    var name = description is String && description.trim().isNotEmpty
        ? cutText(firstLine(description.trim()), _titleChars)
        : (type is String && type.isNotEmpty ? type : 'Subagent');
    final taken = {for (final s in _subagents.values) s.name};
    for (var n = 2; taken.contains(name); n++) {
      name = '${name.replaceFirst(RegExp(r' \(\d+\)$'), '')} ($n)';
    }
    _subagents[callId] = SubagentInfo(
      name: name,
      agent: type is String ? type : '',
      status: 'running',
      assignment: prompt is String ? cutText(prompt.trim(), _assignmentChars) : '',
      callId: callId,
    );
  }

  static SubagentInfo _withStatus(SubagentInfo s, String status, {int? toolCount}) => SubagentInfo(
    name: s.name,
    agent: s.agent,
    status: status,
    assignment: s.assignment,
    toolCount: toolCount ?? s.toolCount,
    recentTools: s.recentTools,
    logId: s.logId,
    callId: s.callId,
  );

  static final _agentId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  void _noteSubagent(String callId, Json? result, bool isError, DateTime? at) {
    final have = _subagents[callId];
    if (have == null) return;
    final agentId = result?['agentId'];
    final id = agentId is String && _agentId.hasMatch(agentId) ? agentId : null;
    final async = result?['status'] == 'async_launched';
    final count = result?['totalToolUseCount'];
    final status = isError
        ? 'failed'
        : (async ? 'running' : (result?['status'] == 'failed' ? 'failed' : 'completed'));
    _subagents[callId] = SubagentInfo(
      name: have.name,
      agent: have.agent,
      status: status,
      assignment: have.assignment,
      toolCount: count is num ? count.toInt() : have.toolCount,
      recentTools: have.recentTools,
      logId: id ?? have.logId,
      callId: have.callId,
    );
    if (async && id != null) {
      _put(
        BackgroundTask(
          id: id,
          kind: BackgroundKind.agent,
          status: BackgroundStatus.running,
          title: have.name,
          detail: have.assignment.isEmpty ? null : have.assignment,
          startedAt: at,
          toolCallId: callId,
          stop: StopRoute.message,
        ),
      );
    }
  }

  void _put(BackgroundTask t) {
    _tasks.remove(t.key);
    _tasks[t.key] = t;
    _tasksChanged();
  }

  void _finish(String id, BackgroundStatus status, DateTime? at) {
    final t = _tasks['0/$id'];
    if (t == null || !t.isActive) return;
    _tasks['0/$id'] = t.copyWith(status: status, endedAt: at, stop: StopRoute.none);
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
}

class _OpenCall {
  const _OpenCall(this.name, this.diffs, this.input);

  final String name;

  /// The change the call's input described, kept until the result.
  final List<ToolDiff> diffs;
  final Json? input;
}

class _Task {
  const _Task(this.subject, this.status);

  final String subject;
  final PlanStatus status;
}
