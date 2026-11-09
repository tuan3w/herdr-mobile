import 'herdr_models.dart';

/// A checkout of a repo that herdr has open as a workspace: where a folder
/// "lives" for a person who thinks in repos and worktrees, not paths.
class Place {
  const Place({
    required this.repoKey,
    required this.repoName,
    required this.checkoutPath,
    required this.workspaceId,
    required this.isLinked,
  });

  final String repoKey;
  final String repoName;
  final String checkoutPath;

  /// The herdr workspace that is this checkout.
  final String workspaceId;

  /// True for a linked worktree, false for the repo's primary checkout.
  final bool isLinked;

  /// The folder's own name: what the person sees on disk.
  String get checkoutName {
    final parts = checkoutPath.split('/').where((s) => s.isNotEmpty);
    return parts.isEmpty ? '/' : parts.last;
  }
}

/// The workspaces of one repo that herdr groups together.
class RepoGroup {
  const RepoGroup({required this.repoKey, required this.repoName, required this.checkouts});

  final String repoKey;
  final String repoName;

  /// Primary first, then linked checkouts in herdr's order.
  final List<Workspace> checkouts;
}

String _trimSlash(String path) => path.length > 1 && path.endsWith('/') ? path.substring(0, path.length - 1) : path;

/// Which repo and checkout a folder belongs to, read from the workspaces' git
/// provenance. Built per snapshot; one instance answers every where-line, so
/// the board, the notification and the toast name a folder the same way.
class PlaceIndex {
  PlaceIndex._(this.repos, this._places, this._groupOf, this.anchors);

  factory PlaceIndex.of(Snapshot s) {
    final byRepo = <String, List<Workspace>>{};
    final places = <Place>[];
    final anchors = <String, Place>{};
    for (final w in s.workspaces) {
      final wt = w.worktree;
      if (wt == null) continue;
      byRepo.putIfAbsent(wt.repoKey, () => []).add(w);
      final place = Place(
        repoKey: wt.repoKey,
        repoName: wt.repoName,
        checkoutPath: _trimSlash(wt.checkoutPath),
        workspaceId: w.id,
        isLinked: wt.isLinked,
      );
      places.add(place);
      anchors.putIfAbsent(wt.repoKey, () => place);
    }
    final repos = <RepoGroup>[];
    final groupOf = <String, RepoGroup>{};
    for (final entry in byRepo.entries) {
      final ws = entry.value;
      if (ws.length < 2) continue;
      final group = RepoGroup(
        repoKey: entry.key,
        repoName: ws.first.worktree!.repoName,
        checkouts: [...ws.where((w) => !w.worktree!.isLinked), ...ws.where((w) => w.worktree!.isLinked)],
      );
      repos.add(group);
      for (final w in ws) {
        groupOf[w.id] = group;
      }
    }
    return PlaceIndex._(repos, places, groupOf, anchors.values.toList(growable: false));
  }

  /// Repos with two or more open checkouts, in the order herdr lists them.
  /// A repo with one is an ordinary workspace.
  final List<RepoGroup> repos;
  final List<Place> _places;
  final Map<String, RepoGroup> _groupOf;

  /// One checkout per repo herdr knows by its git provenance, repos with a
  /// single open checkout included: a workspace to ask `worktree.list` about.
  final List<Place> anchors;

  /// The workspace herdr has open for the checkout at [path]; null when none.
  String? workspaceAt(String path) {
    final dir = _trimSlash(path);
    for (final p in _places) {
      if (p.checkoutPath == dir) return p.workspaceId;
    }
    return null;
  }

  /// Whether herdr has a workspace open for the checkout at [path].
  bool isOpenCheckout(String path) => workspaceAt(path) != null;

  /// The checkout [cwd] is in: the longest checkout path that is [cwd] or a
  /// parent of it at a `/` boundary (`/r/app` does not contain `/r/app-2`).
  /// Null for no cwd, a relative one, or a folder in no known checkout.
  Place? of(String? cwd) {
    if (cwd == null || !cwd.startsWith('/')) return null;
    final dir = _trimSlash(cwd);
    Place? best;
    for (final p in _places) {
      final path = p.checkoutPath;
      final inside = dir == path || (path == '/' ? true : dir.startsWith('$path/'));
      if (inside && (best == null || path.length > best.checkoutPath.length)) best = p;
    }
    return best;
  }

  /// The checkout a workspace is, null for a plain workspace.
  Place? ofWorkspace(String workspaceId) {
    for (final p in _places) {
      if (p.workspaceId == workspaceId) return p;
    }
    return null;
  }

  /// The group a workspace is shown in, null for a plain workspace or a repo
  /// with a single open checkout.
  RepoGroup? groupOf(String workspaceId) => _groupOf[workspaceId];
}
