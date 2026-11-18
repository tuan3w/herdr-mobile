import '../models/herdr_models.dart';
import '../models/pane_name.dart';
import 'machine_connection.dart';

final _opaqueAcpTitle = RegExp(r'^acp-[0-9a-f]{20}$');

String? _checkoutDisplayName(String path) {
  final parts = path.split('/').where((part) => part.isNotEmpty).toList(growable: false);
  if (parts.isEmpty) return null;
  final folder = parts.last;
  final separator = folder.indexOf('@');
  final name = separator >= 0 ? folder.substring(separator + 1) : folder;
  return name.isEmpty ? null : name;
}

/// A checkout name read directly from ACP's managed-worktree layout when the
/// host did not report git provenance. The repo folder must agree with the
/// checkout prefix, so an ordinary directory that merely contains `@` is not
/// mistaken for an ACP worktree.
String? _managedWorktreeDisplayName(String? cwd) {
  if (cwd == null || !cwd.startsWith('/')) return null;
  final parts = cwd.split('/').where((part) => part.isNotEmpty).toList(growable: false);
  for (var i = 0; i + 2 < parts.length; i++) {
    if (parts[i] != '.worktrees') continue;
    final repo = parts[i + 1];
    final checkout = parts[i + 2];
    if (!checkout.startsWith('$repo@')) continue;
    final name = checkout.substring(repo.length + 1);
    if (name.isNotEmpty) return name;
  }
  return null;
}

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
  /// [isGenericPaneTitle]. A name the person gave the pane, or a title a hook
  /// reported, is never generic.
  bool isGenericTitle(String title) =>
      pane.label == null &&
      pane.metadataTitle == null &&
      isGenericPaneTitle(title, agent: pane.agent, folder: paneFolder(pane.cwd), workspace: workspace?.label);

  /// The pane's own title says nothing about the work (and the person did not
  /// name it).
  bool get hasGenericTitle => isGenericTitle(pane.title);

  /// What the board shows instead of the pane's own title: the name read from
  /// the session log, only when that title says nothing. Null means show
  /// [Pane.title].
  String? get betterTitle => hasGenericTitle ? sessionName?.shown : null;

  /// The task name shown everywhere a person sees this pane. ACP deliberately
  /// gives its terminal an opaque stable id (`acp-<hash>`); when that exact
  /// shape and a trustworthy checkout path agree, show the worktree's name as
  /// the desktop app does. A person's `pane.rename` always wins.
  String get displayTitle => betterTitle ?? displayTitleOf(machine, pane, workspace: workspace);

  /// [displayTitle] for surfaces that have a pane but not a [FleetAgent]
  /// (Machines and the pane bar). This keeps the same pane named the same way
  /// across the app without changing its raw Core identity.
  static String displayTitleOf(MachineConnection machine, Pane pane, {Workspace? workspace}) {
    return displayTitleOverrideOf(machine, pane, workspace: workspace) ?? pane.title;
  }

  /// A person's pane name or the trustworthy replacement for an opaque ACP
  /// id; null for every pane whose normal title precedence should stay intact.
  /// Observed chats use this before their log title, while ordinary chats keep
  /// the log's more useful task name.
  static String? displayTitleOverrideOf(MachineConnection machine, Pane pane, {Workspace? workspace}) {
    final title = pane.title.trim();
    if (pane.label != null) return pane.title;
    if (!_opaqueAcpTitle.hasMatch(title)) return null;

    final checkoutPath = workspace?.worktree?.checkoutPath ?? machine.places.of(pane.cwd)?.checkoutPath;
    final checkout = checkoutPath == null ? _managedWorktreeDisplayName(pane.cwd) : _checkoutDisplayName(checkoutPath);
    return checkout;
  }
}
