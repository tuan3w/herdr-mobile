import 'dart:convert';

import '../models/remote_file.dart';
import '../repositories/agent_session.dart' show SubagentState;
import '../repositories/machine_connection.dart';
import 'observed_contracts.dart';
import 'observed_kind.dart';
import 'session_log_locator.dart';

/// Claude Code's subagents: `<session>/subagents/agent-<agentId>.jsonl`, with an
/// `agent-<agentId>.meta.json` beside it that names the call that started it
/// (`toolUseId`). The id is in the parent's log once the call returned; before
/// that the meta files tell. A transcript that was written to recently is
/// running.
class ClaudeSubagentLogs implements SubagentLogs {
  ClaudeSubagentLogs();

  static final _agentId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
  static final _metaName = RegExp(r'^agent-([A-Za-z0-9_-]{1,64})\.meta\.json$');

  /// The biggest `.meta.json` read: they are about 200 bytes.
  static const maxMeta = 8 * 1024;

  /// call id -> agent id, learnt from the meta files (an id never changes).
  final _byCall = <String, String>{};

  static String? _dirOf(String parentLogPath) =>
      parentLogPath.endsWith('.jsonl') ? '${parentLogPath.substring(0, parentLogPath.length - '.jsonl'.length)}/subagents' : null;

  /// The log of agent [id] under [dir]; null when the id is not a plain token
  /// (it comes from a log) or the path is not a readable log path.
  static String? _pathFor(String dir, String id) {
    if (!_agentId.hasMatch(id)) return null;
    final path = '$dir/agent-$id.jsonl';
    return isReadableLogPath(path) ? path : null;
  }

  @override
  Future<String?> pathOf(MachineConnection machine, String parentLogPath, SubagentInfo info) async {
    final dir = _dirOf(parentLogPath);
    if (dir == null) return null;
    final id = info.logId ?? await _idByCall(machine, dir, info.callId);
    if (id == null) return null;
    final path = _pathFor(dir, id);
    if (path == null) return null;
    // The file is made when the agent starts; until then there is nothing to follow.
    try {
      final stat = await machine.files.stat(path);
      return stat.kind == RemoteEntryKind.file ? path : null;
    } on RemoteFileException catch (e) {
      if (e.kind == RemoteFileErrorKind.notFound) return null;
      rethrow;
    }
  }

  Future<String?> _idByCall(MachineConnection machine, String dir, String? callId) async {
    if (callId == null) return null;
    final known = _byCall['$dir|$callId'];
    if (known != null) return known;
    final List<RemoteEntry> entries;
    try {
      entries = await machine.files.list(dir);
    } on RemoteFileException catch (e) {
      if (e.kind == RemoteFileErrorKind.notFound || e.kind == RemoteFileErrorKind.notADirectory) return null;
      rethrow;
    }
    for (final e in entries) {
      final m = _metaName.firstMatch(e.name);
      if (m == null) continue;
      final id = m.group(1)!;
      if (_byCall.entries.any((e) => e.key.startsWith('$dir|') && e.value == id)) continue;
      try {
        final bytes = await machine.files.read('$dir/${e.name}', length: maxMeta + 1);
        if (bytes.length > maxMeta) continue;
        final json = jsonDecode(utf8.decode(bytes, allowMalformed: true));
        final call = json is Map ? json['toolUseId'] : null;
        if (call is String && call.isNotEmpty && _byCall.length < 500) _byCall['$dir|$call'] = id;
      } on FormatException {
        continue;
      } on RemoteFileException {
        continue;
      }
    }
    return _byCall['$dir|$callId'];
  }

  @override
  Future<Map<String, SubagentState>?> refine(
    MachineConnection machine,
    String parentLogPath,
    List<SubagentInfo> infos, {
    required Duration running,
  }) async {
    final out = <String, SubagentState>{};
    final now = DateTime.now().toUtc();
    for (final info in infos) {
      final path = await pathOf(machine, parentLogPath, info);
      if (path == null) continue;
      try {
        final at = (await machine.files.stat(path)).modified;
        out[info.name] = at != null && now.difference(at.toUtc()) <= running ? SubagentState.running : SubagentState.finished;
      } on RemoteFileException {
        continue;
      }
    }
    return out;
  }
}
