import '../models/herdr_models.dart';
import '../models/pane_name.dart';
import 'machine_connection.dart';

/// An agent pane together with where it lives.
class FleetAgent {
  const FleetAgent({
    required this.machine,
    required this.pane,
    required this.workspace,
    this.sessionName,
    this.lastActive,
  });

  final MachineConnection machine;
  final Pane pane;
  final Workspace? workspace;

  /// What the agent's session log calls the work, read for a pane whose own
  /// title says nothing (`PaneSessionNames`). Null when none was read.
  final PaneName? sessionName;

  /// When the agent's session file was last written, read for an idle pane
  /// (`PaneSessionNames`): the moment its last turn ended. Null when not known.
  final DateTime? lastActive;

  /// Stale when its machine is not currently online.
  bool get stale => !machine.isLive;

  /// Blocked on the person, and reachable (an offline machine's last-known
  /// "needs you" cannot be answered): `AttentionSet`'s rule for a pane.
  bool get needsYou => pane.status == AgentStatus.blocked && !stale;

  /// Finished and not yet reviewed on this phone. [pane] is what the app
  /// shows, where a reviewed agent is already idle.
  bool get toReview => pane.status == AgentStatus.done;

  /// Which agent program runs in the pane (`omp`, `claude`, ...): what the
  /// agent says about its session, else what herdr detected.
  String? get agentKind => kindOf(pane);

  /// [agentKind] of a bare [pane].
  static String? kindOf(Pane pane) => pane.session?.agent.isNotEmpty == true ? pane.session!.agent : pane.agent;

  /// The session log the agent appends its transcript to, on the machine, when
  /// it names one: a `kind: path` session that is a `.jsonl` file. Null
  /// otherwise (the pane then has no observed chat).
  String? get sessionLogPath => logPathOf(pane);

  /// [sessionLogPath] of a bare [pane].
  static String? logPathOf(Pane pane) {
    final session = pane.session;
    if (session == null || session.kind != 'path' || !session.value.endsWith('.jsonl')) return null;
    return session.value;
  }

  /// True when [title] says nothing about the work here: see
  /// [isGenericPaneTitle]. A name the person gave the pane is never generic.
  bool isGenericTitle(String title) =>
      pane.label == null &&
      isGenericPaneTitle(
        title,
        agent: pane.agent,
        folder: paneFolder(pane.cwd),
        workspace: workspace?.label,
      );

  /// The pane's own title says nothing about the work (and the person did not
  /// name it).
  bool get hasGenericTitle => isGenericTitle(pane.title);

  /// What the board shows instead of the pane's own title: the name read from
  /// the session log, only when that title says nothing. Null means show
  /// [Pane.title].
  String? get betterTitle => hasGenericTitle ? sessionName?.shown : null;
}
