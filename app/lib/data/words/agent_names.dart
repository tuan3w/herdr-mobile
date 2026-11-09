import '../acp/agent_host.dart' show agentRouteById;
import '../models/herdr_models.dart' show Pane;

/// What the person reads for an agent kind, everywhere: the board, a pane's
/// bar, a session's bar, a composer hint, a notification. One name per agent:
/// `Claude Code`, `Codex`, `omp`, `pi`. A kind herdr does not know is shown as
/// it came; a pane with no agent is a `Shell`.
///
/// `omp` and `pi` are lower case by their own choice, so a sentence never
/// starts with one ("Not installed on studio-mac", not "omp is not installed").
String agentName(String? id) {
  final kind = id?.trim() ?? '';
  if (kind.isEmpty) return 'Shell';
  return agentRouteById(kind)?.label ?? kind;
}

/// What the person reads for the agent in [pane]: the name its hook reported
/// (`display_agent`), else the detected kind's [agentName]. For words only;
/// logic keys on [Pane.agent].
String agentLabelOf(Pane pane) => pane.displayAgent ?? agentName(pane.agent);
