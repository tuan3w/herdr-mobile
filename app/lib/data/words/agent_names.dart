import '../acp/agent_host.dart' show agentRouteById;

/// An agent the app knows by name, whether or not it has an ACP route or a
/// session log: what the person reads everywhere, and what the settings copy
/// lists.
class KnownAgent {
  const KnownAgent(this.id, this.label);

  /// herdr's agent label: the id a pane reports.
  final String id;

  /// What the person reads: `omp`, `Codex`, `Claude Code`, `pi`, `dsh`.
  final String label;
}

/// Every agent the app knows, in the order it names them: the four it can
/// follow through a session log, then `dsh`, which runs in a terminal and
/// reports its state to herdr (dsh-herdr) without a log the app can read.
///
/// `omp` and `pi` are lower case by their own choice, and so is `dsh`.
const knownAgents = <KnownAgent>[
  KnownAgent('omp', 'omp'),
  KnownAgent('codex', 'Codex'),
  KnownAgent('claude', 'Claude Code'),
  KnownAgent('pi', 'pi'),
  KnownAgent('dsh', 'dsh'),
];

/// The label of a known agent, or null for one the app does not know.
String? knownAgentLabel(String id) {
  for (final agent in knownAgents) {
    if (agent.id == id) return agent.label;
  }
  return null;
}

/// What the person reads for an agent kind, everywhere: the board, a pane's
/// bar, a session's bar, a composer hint, a notification. One name per agent:
/// `omp`, `Codex`, `Claude Code`, `pi`, `dsh`. A kind the app does not know is
/// shown as it came; a pane with no agent is a `Shell`.
///
/// `omp`, `pi` and `dsh` are lower case by their own choice, so a sentence never
/// starts with one ("Not installed on studio-mac", not "omp is not installed").
String agentName(String? id) {
  final kind = id?.trim() ?? '';
  if (kind.isEmpty) return 'Shell';
  return knownAgentLabel(kind) ?? agentRouteById(kind)?.label ?? kind;
}
