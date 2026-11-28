import 'herdr_models.dart';
import 'places.dart';

/// A pane in a list, with the label of its tab when its workspace has several
/// (null otherwise, and for a session placed under a checkout it is not a tab
/// of).
typedef PaneEntry = ({Pane pane, String? tab});

/// One checkout of a repo and what runs in it.
typedef CheckoutBlock = ({Workspace workspace, Place place, List<PaneEntry> panes, AgentStatus status});

/// A top-level entry of the machine screen.
sealed class MachineItem {
  const MachineItem();
}

/// A workspace that is not part of a repo group: a plain section.
final class WorkspaceItem extends MachineItem {
  const WorkspaceItem(this.workspace, this.panes);

  final Workspace workspace;
  final List<PaneEntry> panes;
}

/// A repo with several open checkouts: its checkouts, primary first, each with
/// its agents.
final class RepoItem extends MachineItem {
  const RepoItem(this.group, this.blocks, this.status, this.paneCount);

  final RepoGroup group;
  final List<CheckoutBlock> blocks;

  /// The most urgent status of the blocks.
  final AgentStatus status;
  final int paneCount;
}

/// The best status of [statuses] for a roll-up: the most urgent, `unknown`
/// only when nothing else is known.
AgentStatus bestStatus(Iterable<AgentStatus> statuses) {
  AgentStatus? best;
  for (final s in statuses) {
    if (s == AgentStatus.unknown) continue;
    // The roll-up order of herdr and of the workspace headers: needs you, then
    // finished and unseen, then working, then idle.
    if (best == null || s.rollupRank > best.rollupRank) best = s;
  }
  return best ?? AgentStatus.unknown;
}

/// What the machine screen lists: repo → checkouts → agents, plain workspaces
/// as they are, in herdr's order (a repo sits where its first checkout is).
///
/// A phone session ([keeperPaneIds]: the view panes of keeper-hosted agents)
/// is started in whatever folder was asked for. It is in the workspace of the
/// linked worktree holding that folder, else in a workspace of its own named
/// `<agent> · <folder>` (before, in the shared `Phone sessions`, which older
/// sessions still are). When its folder is inside an open checkout it is
/// listed under that checkout (where it already sits, if that is the
/// workspace it is in); when it is in no checkout it stays where herdr put it.
/// None of this reads a workspace's label: it goes by the session's pane.
List<MachineItem> machineLayout(Snapshot s, PlaceIndex places, Set<String> keeperPaneIds) {
  final tabsByWorkspace = <String, List<Tab>>{};
  for (final t in s.tabs) {
    (tabsByWorkspace[t.workspaceId] ??= []).add(t);
  }
  final panesByTab = <String, List<Pane>>{};
  final tabNumber = <String, int>{};
  for (final t in s.tabs) {
    tabNumber[t.id] = t.number;
  }
  for (final p in s.panes) {
    (panesByTab[p.tabId] ??= []).add(p);
  }

  // Phone sessions that belong under a checkout, by that checkout's workspace.
  // A session that already sits in its checkout's own workspace stays there,
  // with its tab. A checkout that is the only one of its repo is a plain
  // section, and takes its sessions too.
  final moved = <String, List<Pane>>{};
  final movedIds = <String>{};
  final movedFrom = <String>{};
  if (keeperPaneIds.isNotEmpty) {
    for (final p in s.panes) {
      if (!keeperPaneIds.contains(p.id)) continue;
      final place = places.of(p.cwd);
      if (place == null || place.workspaceId == p.workspaceId) continue;
      (moved[place.workspaceId] ??= []).add(p);
      movedIds.add(p.id);
      movedFrom.add(p.workspaceId);
    }
  }

  // A workspace's own panes: newest tab first (herdr opens a tab at the end, so
  // a session just started would sit under every finished one), panes in their
  // order within a tab (splits of one place).
  List<PaneEntry> own(Workspace w) {
    final tabs = [...?tabsByWorkspace[w.id]]..sort((a, b) => b.number.compareTo(a.number));
    final multiTab = tabs.length > 1;
    return [
      for (final t in tabs)
        for (final p in panesByTab[t.id] ?? const <Pane>[])
          if (!movedIds.contains(p.id))
            (pane: p, tab: multiTab ? (t.label.isEmpty ? 'Tab ${t.number}' : t.label) : null),
    ];
  }

  List<PaneEntry> placedIn(String workspaceId) {
    final placed = [...?moved[workspaceId]]
      ..sort((a, b) => (tabNumber[b.tabId] ?? 0).compareTo(tabNumber[a.tabId] ?? 0));
    return [for (final p in placed) (pane: p, tab: null)];
  }

  CheckoutBlock block(Workspace w) {
    final place = places.ofWorkspace(w.id)!;
    final panes = [...own(w), ...placedIn(w.id)];
    return (workspace: w, place: place, panes: panes, status: bestStatus(panes.map((e) => e.pane.status)));
  }

  final items = <MachineItem>[];
  final emitted = <String>{};
  for (final w in s.workspaces) {
    final group = places.groupOf(w.id);
    if (group == null) {
      final panes = [...own(w), ...placedIn(w.id)];
      // Everything it held was moved under a checkout: nothing left to list.
      final emptied = panes.isEmpty && s.panes.any((p) => p.workspaceId == w.id);
      if (emptied) continue;
      // herdr's roll-up counted the sessions that moved away: say what is
      // left, or the header shouts about rows that are not under it.
      final lost = movedFrom.contains(w.id);
      items.add(WorkspaceItem(lost ? w.withStatus(bestStatus(panes.map((e) => e.pane.status))) : w, panes));
      continue;
    }
    if (!emitted.add(group.repoKey)) continue;
    final blocks = [for (final c in group.checkouts) block(c)];
    items.add(
      RepoItem(group, blocks, bestStatus(blocks.map((b) => b.status)), blocks.fold(0, (n, b) => n + b.panes.length)),
    );
  }
  return items;
}
