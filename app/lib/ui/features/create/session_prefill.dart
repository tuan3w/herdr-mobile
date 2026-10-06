/// Where a duplicate of a running session starts: its machine and folder, and
/// the agent to start there. Opening the form with one changes nothing that is
/// remembered; only a start does.
class SessionPrefill {
  const SessionPrefill({required this.machineId, required this.folder, this.agent});

  final String machineId;
  final String folder;

  /// A route id of the agent form (`claude`, `codex`, `omp`, ...). Null, or one
  /// the form has no route for, falls back to the agent it would have chosen
  /// without a prefill: the one used last on that machine.
  final String? agent;
}
