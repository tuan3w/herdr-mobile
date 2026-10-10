import 'dart:convert';

import '../acp/acp_models.dart';
import '../acp/background/background_work.dart';
import 'agent_coverage.dart';
import 'log_mapping.dart';
import 'observed_contracts.dart';

/// Maps the lines of a Codex session log
/// (`~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`) to the updates
/// `AgentSessionState.apply` understands.
///
/// Codex writes two dialects (captured in `test/fixtures/codex_logs/`):
///
/// **Paginated** (`session_meta.payload.history_mode == "paginated"`, every
/// log of a current Codex TUI): the chat is the `event_msg` lines of type
/// `item_completed` whose `item.type` is `UserMessage`, `AgentMessage`
/// (`phase` commentary or final answer), `CommandExecution`, `FileChange`,
/// `McpToolCall`, `Plan`, ... Those items carry NO call id. The model calls one
/// tool, `exec`, a script of JavaScript (`response_item` `custom_tool_call`,
/// `input` is the script) whose output comes back as `custom_tool_call_output`;
/// the items of the commands it ran land between the two, or, for a command
/// that outlived the script's wait (a unified-exec process), much later, named
/// by `process_id` (the `session_id` of the script's result). A script that
/// outlives its own wait stays a "cell": its output says `Script running with
/// cell ID N` until a `wait` call ends it.
///
/// **Legacy** (`history_mode` absent: older Codex and the desktop app):
/// `event_msg` `user_message`, `agent_message`, `exec_command_end` and
/// `patch_apply_end`, joined to `response_item` `function_call` /
/// `custom_tool_call` by `call_id`.
///
/// In both dialects `response_item.message` repeats the event stream and is
/// never mapped. Nothing is written while Codex waits for an approval, but the
/// `custom_tool_call` of the command that waits is on disk, so the approval
/// card can show it. A `compacted` line is about 1.2 MB: it is skipped from its
/// first characters, before it is decoded. The log of a subagent starts with a
/// replay of its parent: only lines from `subagent_history_start_ordinal` on
/// are its own.
///
/// Idempotent: a line is mapped once (by its `ordinal`, else a hash of the
/// line), messages are whole-message upserts and tool calls are keyed by their
/// call id, so the same file fed twice changes nothing.
class CodexLogMapper implements SessionLogMapper {
  static const _titleChars = 120;
  static const _finishedKept = 30;

  final _seen = <String>{};
  final _calls = <String, _Call>{};

  /// Calls that started and have no output yet, oldest first.
  final _open = <String>[];

  /// Shell processes still running after their script returned: the process id
  /// (a script's `session_id`) -> the call that started it.
  final _procs = <String, String>{};

  /// Scripts still running ("cells"): cell id -> the call that started it.
  final _cells = <String, String>{};

  /// A `wait` call -> the cell it waits for.
  final _waits = <String, String>{};

  PendingAsk? _ask;
  int? _startOrdinal;
  var _sawMeta = false;
  var _titled = false;
  var _turnEnded = false;
  var _extra = 0;

  /// Subagents by key (their thread id, or `pending:<name>` until it is known).
  final _subagents = <String, SubagentInfo>{};

  final _tasks = <String, BackgroundTask>{};
  List<BackgroundTask>? _taskView;

  @override
  PendingAsk? get pendingAsk => _ask;

  @override
  Set<String> get openToolCalls => {
    // A script that outlives its wait (a cell) is a background task, not the call a
    // permission dialog asks about.
    for (final id in _open)
      if (!_cells.containsValue(id)) id,
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
    _calls.clear();
    _open.clear();
    _procs.clear();
    _cells.clear();
    _waits.clear();
    _ask = null;
    _startOrdinal = null;
    _sawMeta = false;
    _titled = false;
    _turnEnded = false;
    _extra = 0;
    _subagents.clear();
    _tasks.clear();
    _taskView = null;
  }

  @override
  List<SessionUpdate> map(String line) {
    if (line.isEmpty) return const [];
    // The compacted history is a megabyte: its type is in the first bytes.
    final head = line.length > 160 ? line.substring(0, 160) : line;
    if (head.contains('"type":"compacted"')) return const [];
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
    final type = e['type'];
    final p = e['payload'];
    if (type is! String || p is! Map<String, dynamic>) return const [];
    final ordinal = e['ordinal'];
    if (type == 'session_meta') {
      if (_sawMeta) return const [];
      _sawMeta = true;
      final start = p['subagent_history_start_ordinal'];
      if (start is int) _startOrdinal = start;
      return const [];
    }
    if (ordinal is int && _startOrdinal != null && ordinal < _startOrdinal!) return const [];
    if (type != 'event_msg' && type != 'response_item') return const [];
    final key = ordinal is int ? 'o$ordinal' : 'h${fnv(line)}';
    if (!_seen.add(key)) return const [];
    return type == 'event_msg' ? _event(p, key) : _response(p, key);
  }

  // -- events ------------------------------------------------------------------

  List<SessionUpdate> _event(Json p, String key) {
    switch (p['type']) {
      case 'item_completed':
        final item = p['item'];
        return item is Map<String, dynamic> ? _item(item, key) : const [];
      case 'task_started':
        _turnEnded = false;
        return const [];
      case 'task_complete':
        _turnEnded = true;
        return const [];
      case 'turn_aborted':
        _turnEnded = true;
        return [..._cancelOpen(), messageUpsert(MessageRole.agent, 'aborted:$key', 'Interrupted')];
      case 'user_message':
        return _userMessage(p['message'], key);
      case 'agent_message':
        return _agentMessage(p['message'], key);
      case 'exec_command_end':
        return _legacyExecEnd(p);
      case 'patch_apply_end':
        return _legacyPatchEnd(p);
      default:
        return const [];
    }
  }

  List<SessionUpdate> _item(Json item, String key) {
    final id = item['id'] is String && (item['id'] as String).isNotEmpty ? item['id'] as String : key;
    switch (item['type']) {
      case 'UserMessage':
        return _userMessage(withImageMarkers(_textParts(item['content'], 'text'), _imagesOf(item['content'])), id);
      case 'AgentMessage':
        final text = _textParts(item['content'], 'Text');
        if (text.isEmpty) return _questions(item['questions'], id);
        return _agentMessage(text, id);
      case 'Plan':
        final text = item['text'];
        return text is String && text.trim().isNotEmpty ? [messageUpsert(MessageRole.agent, id, text)] : const [];
      case 'ContextCompaction':
        return [messageUpsert(MessageRole.agent, id, 'Earlier messages were summarised')];
      case 'CommandExecution':
        return _commandItem(item, id);
      case 'FileChange':
        return _fileChangeItem(item, id);
      case 'McpToolCall':
        return _attach(_mcpRow(item), id, null);
      case 'Extension':
        if (item['kind'] != 'web.search') return const [];
        return _attach(_searchRow(item), id, null);
      case 'ImageView':
        final path = item['path'];
        final name = path is String ? path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path : 'an image';
        return _attach(_Row('Viewed $name', ToolKind.read, status: ToolStatus.completed), id, null);
      case 'WebSearch':
        return _attach(_searchRow(item), id, null);
      case 'DynamicToolCall':
        final tool = item['tool'] is String ? item['tool'] as String : 'tool';
        final ns = item['namespace'] is String && (item['namespace'] as String).isNotEmpty ? '${item['namespace']}: ' : '';
        return _attach(
          _Row(cutText('$ns$tool', _titleChars), ToolKind.other, status: item['success'] == false ? ToolStatus.failed : ToolStatus.completed, raw: item['arguments'] == null ? null : {'arguments': capJson(item['arguments'])}),
          id,
          null,
        );
      case 'ImageGeneration':
        return _attach(_Row('Generated an image', ToolKind.other, status: item['status'] == 'failed' ? ToolStatus.failed : ToolStatus.completed), id, null);
      case 'EnteredReviewMode' || 'ExitedReviewMode':
        return [messageUpsert(MessageRole.agent, id, item['type'] == 'EnteredReviewMode' ? 'Review started' : 'Review finished')];
      case 'SubAgentActivity':
        _subagentActivity(item);
        return const [];
      default:
        // Items that only repeat what the log says elsewhere or are for the
        // model: nothing to show (see `codexItemCoverage`).
        if (codexItemCoverage[item['type']]?.startsWith('ignored') ?? false) return const [];
        // Anything else is shown as a row of its own, so a new kind of item
        // is never lost silently: it says what it is.
        final type = item['type'];
        if (type is! String || type.isEmpty) return const [];
        return _attach(_Row(type, ToolKind.other, status: ToolStatus.completed, raw: {'item': capJson(item)}), id, null);
    }
  }

  List<SessionUpdate> _userMessage(Object? text, String id) {
    if (text is! String || text.trim().isEmpty || text.trimLeft().startsWith('<turn_aborted>')) return const [];
    _turnEnded = false;
    final out = <SessionUpdate>[messageUpsert(MessageRole.user, id, text)];
    if (!_titled) {
      _titled = true;
      out.add(SessionInfoUpdate(hasTitle: true, title: cutText(firstLine(text.trim()), 80), hasUpdatedAt: false));
    }
    return out;
  }

  List<SessionUpdate> _agentMessage(Object? text, String id) {
    if (text is! String || text.trim().isEmpty) return const [];
    return [messageUpsert(MessageRole.agent, id, text)];
  }

  /// An agent message that asks questions and says nothing else.
  List<SessionUpdate> _questions(Object? questions, String id) {
    if (questions is! List) return const [];
    final titles = [
      for (final q in questions)
        if (q is Map && (q['question'] ?? q['title']) is String) (q['question'] ?? q['title']) as String,
    ];
    return titles.isEmpty ? const [] : [messageUpsert(MessageRole.agent, id, 'Asked: ${titles.join('; ')}')];
  }

  /// How many pictures a content list carries (`image` by URL, `local_image` by path).
  static int _imagesOf(Object? content) => content is List
      ? content.where((p) => p is Map && (p['type'] == 'image' || p['type'] == 'local_image')).length
      : 0;

  /// The text parts (`{type: <type>, text}`) of a content list, joined.
  static String _textParts(Object? content, String type) {
    if (content is! List) return '';
    return [
      for (final p in content)
        if (p is Map && p['type'] == type && p['text'] is String) p['text'] as String,
    ].join('\n');
  }

  // -- response items ----------------------------------------------------------

  List<SessionUpdate> _response(Json p, String key) {
    switch (p['type']) {
      case 'custom_tool_call':
        return _customCall(p);
      case 'custom_tool_call_output' || 'function_call_output':
        return _output(p);
      case 'function_call':
        return _functionCall(p);
      default:
        return const [];
    }
  }

  List<SessionUpdate> _customCall(Json p) {
    final id = p['call_id'];
    if (id is! String || id.isEmpty) return const [];
    final input = p['input'] is String ? p['input'] as String : '';
    final name = p['name'] is String ? p['name'] as String : 'exec';
    final row = name == 'apply_patch'
        ? _Row('Applying a patch', ToolKind.edit, raw: {'patch': capText(input)})
        : _parseScript(input);
    return _start(id, name, row);
  }

  List<SessionUpdate> _functionCall(Json p) {
    final id = p['call_id'];
    final name = p['name'];
    if (id is! String || id.isEmpty || name is! String) return const [];
    final args = _decode(p['arguments']);
    switch (name) {
      case 'wait':
        final cell = args?['cell_id'];
        if (cell != null) _waits[id] = '$cell';
        return const [];
      case 'wait_agent' || 'request_user_input_async':
        return const [];
      case 'update_plan':
        _calls[id] = _Call(name, hidden: true);
        return _plan(args);
      case 'exec_command' || 'shell':
        final cmd = args?['cmd'] ?? args?['command'];
        final text = cmd is List ? cmd.join(' ') : (cmd is String ? cmd : null);
        if (text == null) return _start(id, name, _Row(name, ToolKind.execute));
        return _start(
          id,
          name,
          _Row(cutText(firstLine(text), _titleChars), ToolKind.execute, raw: {'command': capText(text), 'workdir': ?args?['workdir']}),
          command: text,
        );
      case 'spawn_agent':
        final task = args?['task_name'];
        if (task is String && task.isNotEmpty && !_subagents.values.any((s) => s.name == task)) {
          _subagents['pending:$task'] = SubagentInfo(name: task, callId: id);
        }
        return _start(id, name, _Row(task is String && task.isNotEmpty ? '$name: $task' : name, ToolKind.other));
      case 'request_user_input':
        final qs = args?['questions'];
        final first = qs is List && qs.isNotEmpty && qs.first is Map ? (qs.first as Map)['question'] : null;
        return _start(id, name, _Row(first is String ? cutText(firstLine(first), _titleChars) : 'Question', ToolKind.other, raw: args == null ? null : {'arguments': capJson(args)}));
      default:
        final target = args?['task_name'] ?? args?['target'];
        return _start(id, name, _Row(target is String ? '$name: $target' : name, ToolKind.other));
    }
  }

  Json? _decode(Object? raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is! String || !raw.trimLeft().startsWith('{')) return null;
    try {
      final d = jsonDecode(raw);
      return d is Map<String, dynamic> ? d : null;
    } on Object {
      return null;
    }
  }

  // -- tool rows ---------------------------------------------------------------

  List<SessionUpdate> _start(String id, String name, _Row row, {String? command}) {
    if (_calls.containsKey(id)) return const [];
    _calls[id] = _Call(name, command: command ?? row.command);
    _open.add(id);
    _turnEnded = false;
    return [ToolCallStart(row.toCall(id, name, ToolStatus.inProgress))];
  }

  /// The title, kind and input of a script of the `exec` tool, from the first
  /// tool it calls. A script that does not parse is just "Running a script".
  _Row _parseScript(String js) {
    final exec = js.indexOf('tools.exec_command(');
    if (exec >= 0) {
      final args = _balanced(js, js.indexOf('(', exec) + 1);
      // The model writes a JavaScript object, which is JSON only when it quotes
      // its keys: `{cmd:"ls"}` is as common as `{"cmd":"ls"}`.
      final map = args == null ? null : _decode(args);
      final cmd = map?['cmd'] ?? (args == null ? null : _jsString(args, 'cmd'));
      if (cmd is String && cmd.isNotEmpty) {
        final workdir = map?['workdir'] ?? (args == null ? null : _jsString(args, 'workdir'));
        return _Row(
          cutText(firstLine(cmd.trim()), _titleChars),
          ToolKind.execute,
          raw: {'command': capText(cmd), 'workdir': ?workdir},
          command: cmd,
        );
      }
    }
    if (js.contains('tools.apply_patch(')) {
      final m = RegExp(r'const\s+\w+\s*=\s*("(?:[^"\\]|\\.)*")\s*;').firstMatch(js);
      Object? patch;
      if (m != null) {
        try {
          patch = jsonDecode(m.group(1)!);
        } on Object {
          patch = null;
        }
      }
      return _Row('Applying a patch', ToolKind.edit, raw: patch is String ? {'patch': capText(patch)} : null);
    }
    if (js.contains('tools.write_stdin(')) return _Row('Writing to a running command', ToolKind.execute);
    if (js.contains('tools.web__run(') || js.contains('tools.web.')) return _Row('Searching the web', ToolKind.fetch);
    if (js.contains('tools.view_image(')) return _Row('Viewing an image', ToolKind.read);
    if (js.contains('tools.mcp__')) return _Row('MCP call', ToolKind.other);
    return _Row('Running a script', ToolKind.other);
  }

  /// The string value of [key] in a JavaScript object literal [js], whether
  /// the key is quoted or not and the string is `"..."` or `'...'`; null when
  /// there is none.
  static String? _jsString(String js, String key) {
    final m = RegExp('(?:^|[{,\\s])["\']?$key["\']?\\s*:\\s*("(?:[^"\\\\]|\\\\.)*"|\'(?:[^\'\\\\]|\\\\.)*\')').firstMatch(js);
    if (m == null) return null;
    final lit = m.group(1)!;
    try {
      return jsonDecode(lit.startsWith('"') ? lit : '"${lit.substring(1, lit.length - 1).replaceAll('"', '\\"').replaceAll("\\'", "'")}"') as String;
    } on Object {
      return null;
    }
  }

  /// The `{...}` object whose `{` is at or after [from] (with strings and
  /// escapes respected), or null.
  static String? _balanced(String s, int from) {
    final start = s.indexOf('{', from);
    if (start < 0) return null;
    var depth = 0;
    var inString = false;
    for (var i = start; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (inString) {
        if (c == 0x5c) {
          i++;
        } else if (c == 0x22) {
          inString = false;
        }
      } else if (c == 0x22) {
        inString = true;
      } else if (c == 0x7b) {
        depth++;
      } else if (c == 0x7d && --depth == 0) {
        return s.substring(start, i + 1);
      }
    }
    return null;
  }

  // -- items that belong to a call ----------------------------------------------

  List<SessionUpdate> _commandItem(Json item, String id) {
    final command = item['command'];
    final cmd = command is List && command.length >= 3 && command[1] == '-lc' && command[2] is String
        ? command[2] as String
        : (command is List ? command.join(' ') : (command is String ? command : ''));
    final cwd = item['cwd'] is String ? (item['cwd'] as String).replaceFirst('file://', '') : null;
    final output = item['aggregated_output'] is String ? item['aggregated_output'] as String : (item['formatted_output'] is String ? item['formatted_output'] as String : '');
    final exit = item['exit_code'];
    final status = switch (item['status']) {
      'declined' => ToolStatus.cancelled,
      'failed' => ToolStatus.failed,
      'inProgress' || 'in_progress' => ToolStatus.inProgress,
      _ => exit is int && exit != 0 ? ToolStatus.failed : ToolStatus.completed,
    };
    final row = _Row(
      cutText(firstLine(cmd.trim()), _titleChars),
      ToolKind.execute,
      raw: {'command': capText(cmd), 'cwd': ?cwd},
      status: status,
      output: output,
      command: cmd,
    );
    final process = item['process_id'];
    final out = _attach(row, id, cmd, process: process == null ? null : '$process');
    if (process != null && status != ToolStatus.inProgress) {
      _finishTask('proc$process', status == ToolStatus.completed ? BackgroundStatus.finished : BackgroundStatus.failed);
    }
    return out;
  }

  List<SessionUpdate> _fileChangeItem(Json item, String id) {
    final changes = item['changes'];
    if (changes is! Map) return const [];
    final diffs = <ToolDiff>[];
    for (final e in changes.entries) {
      final path = '${e.key}';
      final c = e.value;
      if (c is! Map) continue;
      switch (c['type']) {
        case 'add':
          diffs.add(ToolDiff(path: path, newText: capText(c['content'] is String ? c['content'] as String : '')));
        case 'delete':
          diffs.add(ToolDiff(path: path, oldText: c['content'] is String ? capText(c['content'] as String) : null, newText: ''));
        default:
          final u = c['unified_diff'];
          if (u is String) diffs.add(diffFromUnified(path, capText(u)));
      }
    }
    if (diffs.isEmpty) return const [];
    final first = diffs.first.path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? diffs.first.path;
    final more = diffs.length - 1;
    final stdout = item['stdout'] is String ? item['stdout'] as String : '';
    // A patch the person declined is written after the turn was aborted, when
    // its call is already cancelled: nothing more to show.
    if (_open.isEmpty && '${item['stderr']}'.contains('TurnAborted')) return const [];
    final status = switch (item['status']) {
      'declined' => ToolStatus.cancelled,
      'failed' => ToolStatus.failed,
      _ => ToolStatus.completed,
    };
    return _attach(
      _Row('Edited $first${more > 0 ? ' and $more more' : ''}', ToolKind.edit, status: status, diffs: diffs, output: stdout),
      id,
      null,
    );
  }

  _Row _mcpRow(Json item) {
    final server = item['server'] is String ? item['server'] as String : 'mcp';
    final tool = item['tool'] is String ? item['tool'] as String : 'tool';
    final result = item['result'];
    var text = '';
    if (result is Map) {
      text = _textParts(result['content'], 'text');
    } else if (result is String) {
      text = result;
    }
    final error = item['error'];
    if (text.isEmpty && error is Map && error['message'] is String) text = error['message'] as String;
    if (text.isEmpty && error is String) text = error;
    final failed = item['status'] == 'failed' || error != null;
    return _Row(
      cutText('$server: $tool', _titleChars),
      ToolKind.other,
      status: failed ? ToolStatus.failed : ToolStatus.completed,
      raw: item['arguments'] == null ? null : {'arguments': capJson(item['arguments'])},
      output: text,
    );
  }

  _Row _searchRow(Json item) {
    Object? query = item['query'];
    final action = item['action'];
    if (query == null && action is Map) query = action['query'];
    return _Row(
      query is String && query.isNotEmpty ? cutText('Searched: ${firstLine(query)}', _titleChars) : 'Searched the web',
      ToolKind.fetch,
      status: ToolStatus.completed,
    );
  }

  /// A finished item of a command, a patch, ...: it belongs to the call it ran
  /// for (the process it names, the call whose command it is, else the call the
  /// script is still running), or is a row of its own when none is known.
  List<SessionUpdate> _attach(_Row row, String itemId, String? command, {String? process}) {
    String? target;
    var late = false;
    if (process != null) target = _procs[process];
    if (target == null && command != null) {
      for (final id in _calls.keys.toList().reversed) {
        final c = _calls[id]!;
        if (!c.claimed && !c.hidden && c.command != null && c.command!.trim() == command.trim()) {
          target = id;
          break;
        }
      }
    }
    if (target == null && command != null && _open.isEmpty) {
      // The script is over and its row filled: this is the same command's late
      // item (a process that ended after the turn did). Nothing new to show.
      for (final id in _calls.keys.toList().reversed) {
        final c = _calls[id]!;
        if (!c.hidden && c.command != null && c.command!.trim() == command.trim()) {
          target = id;
          late = true;
          break;
        }
      }
    }
    if (target == null && _open.isNotEmpty) {
      // The newest call still running that has no item yet (not a cell: it waits
      // for its own command, which may arrive much later).
      final unclaimed = _open.where((id) => !(_calls[id]?.claimed ?? true) && !_cells.containsValue(id)).lastOrNull;
      if (unclaimed != null) {
        target = unclaimed;
      } else {
        // The call's script ran more than one command: one row each.
        final last = _open.last;
        return [ToolCallStart(row.toCall('$last:${++_extra}', 'exec', row.status))];
      }
    }
    if (target == null || _calls[target] == null) {
      return [ToolCallStart(row.toCall(itemId, 'exec', row.status))];
    }
    final call = _calls[target]!;
    call.claimed = true;
    call.output = row.output;
    call.itemStatus = row.status;
    final fields = <String, Object?>{
      'toolCallId': target,
      'title': row.title,
      'kind': kindWire(row.kind),
      if (row.raw != null) 'rawInput': row.raw,
      // The call's own status is the script's: an item that says "completed"
      // only says its command ended, and a call still open stays open until
      // its output. A failure or a decline of the command counts at once.
      if (!late && (!_open.contains(target) || row.status != ToolStatus.completed)) 'status': _wire(row.status),
      'content': [...row.content().map((c) => c.toJson())],
      if (row.output.isNotEmpty) 'rawOutput': capText(row.output),
    };
    return [ToolCallPatchUpdate(ToolCallPatch(target, fields))];
  }

  static String _wire(ToolStatus s) => switch (s) {
    ToolStatus.pending => 'pending',
    ToolStatus.inProgress => 'in_progress',
    ToolStatus.completed => 'completed',
    ToolStatus.failed => 'failed',
    ToolStatus.cancelled => 'cancelled',
  };

  // -- outputs -----------------------------------------------------------------

  static final _header = RegExp(r'^Script (completed|failed|terminated|running with cell ID (\d+))');

  List<SessionUpdate> _output(Json p) {
    final id = p['call_id'];
    if (id is! String || id.isEmpty) return const [];
    final raw = p['output'];
    final parts = <String>[
      if (raw is String) raw,
      if (raw is List)
        for (final part in raw)
          if (part is Map && part['text'] is String) part['text'] as String,
    ];
    final waited = _waits.remove(id);
    final call = _calls[id];
    if (call == null && waited == null) return const [];
    if (call?.hidden ?? false) return const [];
    final first = parts.isEmpty ? '' : parts.first;
    final header = _header.firstMatch(first);
    if (waited != null) return _waitResult(waited, header, parts);
    if (call == null) return const [];

    // The cell is still running: the call stays open.
    final cell = header?.group(2);
    if (cell != null) {
      _cells[cell] = id;
      _startTask(
        id: 'cell$cell',
        kind: BackgroundKind.shell,
        title: call.command == null ? 'Running a script' : cutText(firstLine(call.command!.trim()), _titleChars),
        detail: call.command,
        toolCallId: id,
        stop: StopRoute.message,
      );
      return const [];
    }
    _open.remove(id);
    _turnEnded = false;

    var body = parts.length > 1 ? parts.sublist(1).join('\n') : (header == null ? first : '');
    final result = _decode(body);
    final session = result?['session_id'];
    if (result != null && result['output'] is String) body = result['output'] as String;
    if (session != null && '$session'.isNotEmpty) {
      // The process belongs to the call that started it; a `write_stdin` that
      // polls it names the same id.
      _procs.putIfAbsent('$session', () => id);
      _startTask(
        id: 'proc$session',
        kind: BackgroundKind.terminal,
        title: call.command == null ? 'Running command' : cutText(firstLine(call.command!.trim()), _titleChars),
        detail: call.command,
        toolCallId: id,
        stop: StopRoute.none,
      );
    }
    final aborted = raw is String && raw.startsWith('aborted by user');
    final exit = result?['exit_code'];
    final failed = header?.group(1) == 'failed' || (exit is int && exit != 0);
    final status = aborted ? 'cancelled' : (failed ? 'failed' : 'completed');
    final text = aborted ? raw : body;
    if (call.claimed) {
      // The item of the command has the output and the exit status; the
      // script's own failure still counts.
      final item = call.itemStatus;
      final own = item == ToolStatus.failed || item == ToolStatus.cancelled ? _wire(item!) : 'completed';
      return [
        ToolCallPatchUpdate(ToolCallPatch(id, {'toolCallId': id, 'status': aborted || failed ? status : own})),
      ];
    }
    return [
      ToolCallPatchUpdate(
        ToolCallPatch(id, {
          'toolCallId': id,
          'status': status,
          'content': [if (text.isNotEmpty) ToolContentBlock(TextBlock(capText(text))).toJson()],
          if (text.isNotEmpty) 'rawOutput': capText(text),
        }),
      ),
    ];
  }

  /// What a `wait` call reported about cell [cell]: it ended, or still runs.
  List<SessionUpdate> _waitResult(String cell, RegExpMatch? header, List<String> parts) {
    if (header == null || header.group(2) != null) return const [];
    final id = _cells.remove(cell);
    final failed = header.group(1) == 'failed';
    final stopped = header.group(1) == 'terminated';
    _finishTask('cell$cell', stopped ? BackgroundStatus.stopped : (failed ? BackgroundStatus.failed : BackgroundStatus.finished));
    if (id == null || !_open.remove(id)) return const [];
    final call = _calls[id];
    final text = parts.length > 1 ? parts.sublist(1).join('\n') : '';
    return [
      ToolCallPatchUpdate(
        ToolCallPatch(id, {
          'toolCallId': id,
          'status': stopped ? 'cancelled' : (failed ? 'failed' : 'completed'),
          if (!(call?.claimed ?? false) && text.isNotEmpty) ...{
            'content': [ToolContentBlock(TextBlock(capText(text))).toJson()],
            'rawOutput': capText(text),
          },
        }),
      ),
    ];
  }

  /// Every call still running ends: the turn was interrupted. A cell dies with
  /// its turn; a shell process may go on (Codex says so) until its item
  /// arrives.
  List<SessionUpdate> _cancelOpen() {
    if (_open.isEmpty) return const [];
    final out = [for (final id in _open) cancelledPatch(id)];
    for (final cell in _cells.keys.toList()) {
      _finishTask('cell$cell', BackgroundStatus.stopped);
    }
    _cells.clear();
    _open.clear();
    return out;
  }

  // -- the plan ------------------------------------------------------------------

  List<SessionUpdate> _plan(Json? args) {
    final plan = args?['plan'];
    if (plan is! List) return const [];
    final entries = <PlanEntry>[];
    for (final s in plan) {
      if (s is! Map || s['step'] is! String || (s['step'] as String).isEmpty) continue;
      entries.add(
        PlanEntry(
          content: cutText(s['step'] as String, 300),
          status: switch (s['status']) {
            'in_progress' => PlanStatus.inProgress,
            'completed' => PlanStatus.completed,
            _ => PlanStatus.pending,
          },
        ),
      );
    }
    return [PlanUpdate(entries)];
  }

  // -- legacy dialect ------------------------------------------------------------

  List<SessionUpdate> _legacyExecEnd(Json p) {
    final id = p['call_id'];
    if (id is! String || !_calls.containsKey(id)) return const [];
    final call = _calls[id]!;
    _open.remove(id);
    call.claimed = true;
    final exit = p['exit_code'];
    final failed = p['status'] == 'failed' || (exit is int && exit != 0);
    final output = p['aggregated_output'] is String ? p['aggregated_output'] as String : '';
    return [
      ToolCallPatchUpdate(
        ToolCallPatch(id, {
          'toolCallId': id,
          'status': failed ? 'failed' : 'completed',
          'content': [if (output.isNotEmpty) ToolContentBlock(TextBlock(capText(output))).toJson()],
          if (output.isNotEmpty) 'rawOutput': capText(output),
        }),
      ),
    ];
  }

  List<SessionUpdate> _legacyPatchEnd(Json p) {
    final id = p['call_id'];
    if (id is! String || !_calls.containsKey(id)) return const [];
    _open.remove(id);
    _calls[id]!.claimed = true;
    final changes = p['changes'];
    final diffs = <ToolDiff>[];
    if (changes is Map) {
      for (final e in changes.entries) {
        final c = e.value;
        if (c is! Map) continue;
        if (c['type'] == 'add' && c['content'] is String) {
          diffs.add(ToolDiff(path: '${e.key}', newText: capText(c['content'] as String)));
        } else if (c['unified_diff'] is String) {
          diffs.add(diffFromUnified('${e.key}', capText(c['unified_diff'] as String)));
        }
      }
    }
    final stdout = p['stdout'] is String ? p['stdout'] as String : '';
    return [
      ToolCallPatchUpdate(
        ToolCallPatch(id, {
          'toolCallId': id,
          'status': p['success'] == false ? 'failed' : 'completed',
          'content': [...diffs.map((d) => d.toJson()), if (stdout.isNotEmpty) ToolContentBlock(TextBlock(capText(stdout))).toJson()],
          if (stdout.isNotEmpty) 'rawOutput': capText(stdout),
        }),
      ),
    ];
  }

  // -- subagents -----------------------------------------------------------------

  void _subagentActivity(Json item) {
    final thread = item['agent_thread_id'];
    final path = item['agent_path'];
    if (thread is! String || thread.isEmpty) return;
    final name = path is String && path.isNotEmpty ? path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? thread : thread;
    final old = _subagents[thread] ?? _subagents.remove('pending:$name');
    final status = switch (item['kind']) {
      'started' || 'interacted' => 'running',
      'completed' => 'completed',
      'interrupted' => 'aborted',
      _ => old?.status ?? 'running',
    };
    _subagents[thread] = SubagentInfo(
      name: old?.name ?? name,
      agent: old?.agent ?? '',
      status: status,
      assignment: old?.assignment ?? '',
      toolCount: old?.toolCount ?? 0,
      recentTools: old?.recentTools ?? const [],
      logId: thread,
      callId: old?.callId ?? (item['id'] is String ? item['id'] as String : null),
    );
  }

  // -- background tasks ------------------------------------------------------------

  void _startTask({
    required String id,
    required BackgroundKind kind,
    required String title,
    String? detail,
    String? toolCallId,
    required StopRoute stop,
  }) {
    final key = '0/$id';
    if (_tasks[key] != null) return;
    _tasks[key] = BackgroundTask(
      id: id,
      kind: kind,
      status: BackgroundStatus.running,
      title: title,
      detail: detail == null ? null : capText(detail),
      toolCallId: toolCallId,
      stop: stop,
    );
    _tasksChanged();
  }

  void _finishTask(String id, BackgroundStatus status) {
    final t = _tasks['0/$id'];
    if (t == null || !t.isActive) return;
    _tasks['0/$id'] = t.copyWith(status: status, stop: StopRoute.none);
    _tasksChanged();
  }

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

class _Call {
  _Call(this.name, {this.command, this.hidden = false});

  final String name;
  final String? command;

  /// Not shown as a tool row (the plan call shows as the plan).
  final bool hidden;

  /// An item of the call's own command already filled its row.
  bool claimed = false;
  String output = '';

  /// The status the command's own item gave (a failed command stays failed
  /// when the script's output says nothing about it).
  ToolStatus? itemStatus;
}

class _Row {
  const _Row(
    this.title,
    this.kind, {
    this.raw,
    this.status = ToolStatus.inProgress,
    this.output = '',
    this.diffs = const [],
    this.command,
  });

  final String title;
  final ToolKind kind;
  final Map<String, Object?>? raw;
  final ToolStatus status;
  final String output;
  final List<ToolDiff> diffs;
  final String? command;

  List<ToolContent> content() => [...diffs, if (output.isNotEmpty) ToolContentBlock(TextBlock(capText(output)))];

  ToolCall toCall(String id, String name, ToolStatus at) => ToolCall(
    toolCallId: id,
    name: name,
    title: title,
    kind: kind,
    status: at,
    rawInput: raw,
    rawOutput: output.isEmpty ? null : capText(output),
    content: content(),
  );
}
