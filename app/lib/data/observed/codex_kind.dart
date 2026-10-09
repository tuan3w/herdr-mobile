import '../acp/background/background_work.dart' show stopMessageForCodex;
import '../models/remote_file.dart';
import '../repositories/agent_session.dart' show SubagentState;
import '../repositories/machine_connection.dart';
import 'codex_locator.dart';
import 'codex_log_mapper.dart';
import 'observed_contracts.dart';
import 'observed_kind.dart';
import 'session_log_locator.dart';

/// Codex: herdr reports the thread id (not the path) once its integration is
/// installed, so the log is found by it ([CodexLocator]). Its questions are
/// answered in the terminal (the numbered-menu card covers them), its approvals
/// by the generic prompt detector, and a script that outlives its wait (a
/// "cell") is stopped by asking the model to `wait` on it with `terminate`.
final codexKind = _codexKind();

ObservedKind _codexKind() {
  final locator = CodexLocator();
  return ObservedKind(
    id: 'codex',
    label: 'Codex',
    newMapper: CodexLogMapper.new,
    locator: locator,
    stopMessage: stopMessageForCodex,
    subagents: CodexSubagentLogs(locator),
    wakesOnBackground: false,
    integration: 'codex',
  );
}

/// A Codex subagent is a thread of its own: its rollout is found by its thread
/// id like any session's, and it is running while that file is being written.
class CodexSubagentLogs implements SubagentLogs {
  CodexSubagentLogs(this._locator);

  final CodexLocator _locator;

  @override
  Future<String?> pathOf(MachineConnection machine, String parentLogPath, SubagentInfo info) async {
    final id = info.logId;
    if (id == null) return null;
    final found = await _locator.locateById(machine.files, id, machineId: machine.profile.id);
    return found is Located ? found.path : null;
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
        final stat = await machine.files.stat(path);
        final at = stat.modified;
        out[info.name] = at != null && now.difference(at.toUtc()) <= running ? SubagentState.running : SubagentState.finished;
      } on RemoteFileException {
        continue;
      }
    }
    return out;
  }
}
