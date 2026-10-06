// Where an omp subagent's own log lives, and the one rule that keeps the path
// honest: the agent's text never picks a file.
//
// omp writes a `task` subagent's session to `<artifact dir>/<id>.jsonl`, where
// the artifact dir is the parent session file without its `.jsonl`
// (`.../sessions/<project>/<time>_<session id>/PongReply.jsonl`, verified on
// omp 18.4.12; docs/AGENT_SESSIONS.md). The id is the name omp's progress
// entries carry (`progress[].id`), which the run keeps as [SubagentRun.name]:
// text that came from the agent, so it is checked here before it is used.

/// The longest id accepted. omp's ids are short names, a numeric suffix for a
/// repeat (`Anna-2`) and dots between nested levels (`Anna.Bob`).
const maxSubagentNameLength = 120;

final _subagentName = RegExp(r'^[A-Za-z0-9_](?:[A-Za-z0-9_.-]*[A-Za-z0-9_-])?$');

/// [name] when it is a plain id that can only name one file in the artifact
/// dir: letters, digits, `_`, `-` and single inner dots; no separator, no
/// `..`, no leading or trailing dot, not already ending in `.jsonl`. Null
/// otherwise (also for null and blank).
String? validSubagentName(String? name) {
  if (name == null || name.isEmpty || name.length > maxSubagentNameLength) return null;
  if (!_subagentName.hasMatch(name)) return null;
  if (name.contains('..') || name.endsWith('.jsonl')) return null;
  return name;
}

/// The log file of subagent [name] inside [artifactDir] (an absolute path
/// without a trailing slash), or null when the name is not valid or the
/// directory is not an absolute path. The result is always
/// `<artifactDir>/<name>.jsonl`: one segment below the directory, `.jsonl`.
String? subagentLogPath(String artifactDir, String? name) {
  final valid = validSubagentName(name);
  if (valid == null) return null;
  if (!artifactDir.startsWith('/') || artifactDir.length < 2 || artifactDir.endsWith('/')) return null;
  if (artifactDir.contains('\u0000')) return null;
  return '$artifactDir/$valid.jsonl';
}
