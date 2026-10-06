import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import '../models/remote_file.dart';
import '../services/remote_files.dart';

/// Lets the screen that asked stop a search when it goes away: after
/// [cancel] the finder starts no new SFTP call, and the ones in flight are
/// not waited for.
class SearchCancel {
  final _done = Completer<void>();

  bool get isCancelled => _done.isCompleted;

  /// Completes when [cancel] is called.
  Future<void> get whenCancelled => _done.future;

  void cancel() {
    if (!_done.isCompleted) _done.complete();
  }
}

/// Where a [PathCandidate] came from.
enum CandidateSource {
  /// The same relative path in another checkout of the session's repository.
  worktree,

  /// A file with the tapped name somewhere under the session's folder.
  search,
}

/// A place a tapped path may have meant: a file (or folder) that exists.
class PathCandidate {
  const PathCandidate({required this.stat, required this.root, required this.source});

  /// What `stat` said about [path] (links followed, as the viewer will).
  final RemoteStat stat;

  /// The checkout (or, for a name search, the session folder) it was found in.
  final String root;
  final CandidateSource source;

  String get path => stat.path;
  DateTime? get modified => stat.modified;

  /// [path] below [root], without a leading slash.
  String get relative =>
      path.length > root.length && path.startsWith(root) ? path.substring(root.length).replaceFirst('/', '') : path;

  /// The last part of [root]: the name of the worktree folder.
  String get rootName => RemotePath.basename(root);

  /// Folder of [path] below [root], `.` at the top.
  String get folder {
    final r = relative;
    final cut = r.lastIndexOf('/');
    return cut < 0 ? '.' : r.substring(0, cut);
  }
}

/// What a search found and how far it looked.
class PathFindReport {
  const PathFindReport({this.candidates = const [], this.worktreesLooked = 0, this.searched = false});

  /// Newest first.
  final List<PathCandidate> candidates;

  /// Other checkouts whose copy of the path was asked about.
  final int worktreesLooked;

  /// Whether a search by name ran.
  final bool searched;
}

/// The other checkouts of the repository a session folder belongs to.
class Checkouts {
  const Checkouts({this.top, this.others = const []});

  /// The folder holding the `.git` the session folder belongs to (the folder
  /// itself, or one of the two above it); null outside a repository.
  final String? top;

  /// Absolute folders of the other checkouts: the main one first when [top] is
  /// itself a linked worktree, then the worktrees git lists.
  final List<String> others;
}

/// A not-found that says what it looked for and where. Still a plain
/// not-found to everything that only reads [kind].
class PathNotFound extends RemoteFileException {
  PathNotFound(
    String message, {
    super.path,
    this.canSearch = false,
  }) : super(RemoteFileErrorKind.notFound, message);

  /// A search by name could still be tried (it was not, and the path is below
  /// the session folder).
  final bool canSearch;
}

/// Finds a file an agent named when it is not where the session runs: in the
/// other worktrees of the same repository (agents hand work to subagents that
/// write in sibling checkouts), or by name below the session folder.
///
/// SFTP only, through [RemoteFiles]: `stat`, `list` and short `read`s of the
/// `gitdir` files git keeps. Nothing is asked of a shell and nothing is
/// followed beyond what `stat` reports. Every search is bounded (calls in
/// flight, folders listed, time) and stops asking once its [SearchCancel] is
/// cancelled. One finder per machine ([of]); it remembers the worktrees of a
/// folder for [cacheFor].
class PathFinder {
  PathFinder(
    this.files, {
    this.maxWorktrees = 12,
    this.parallel = 4,
    this.worktreeBudget = const Duration(seconds: 3),
    this.searchBudget = const Duration(seconds: 2),
    this.maxFolders = 400,
    this.maxDepth = 3,
    this.maxMatches = 12,
    this.cacheFor = const Duration(seconds: 60),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static final _byFiles = Expando<PathFinder>('PathFinder');

  /// The finder of [files] (one machine), created on first use.
  static PathFinder of(RemoteFiles files) => _byFiles[files] ??= PathFinder(files);

  final RemoteFiles files;
  final int maxWorktrees;

  /// Calls in flight at once.
  final int parallel;
  final Duration worktreeBudget;
  final Duration searchBudget;
  final int maxFolders;
  final int maxDepth;
  final int maxMatches;
  final Duration cacheFor;
  final DateTime Function() _now;

  final _cache = <String, ({DateTime at, Checkouts value})>{};

  /// Folders a name search does not enter (besides hidden ones).
  static const skipFolders = {'node_modules', 'build', '.dart_tool', 'target', 'dist', '.venv'};

  static const _commonStems = {
    'readme', 'index', 'main', 'license', 'licence', 'changelog', 'makefile', 'dockerfile', 'package', 'pubspec',
    'cargo', 'setup', 'config', 'settings', 'utils', 'helpers', 'types', 'constants', 'test', 'tests', 'app',
    'lib', 'mod', 'init', '__init__', 'notes', 'todo', 'plan', 'design', 'docs', 'schema', 'models', 'agents', 'claude', 'gemini', 'contributing', 'tsconfig', 'gradle', 'manifest', 'strings',
  };

  /// Whether [name] says enough to search for it on its own: not a name every
  /// project has (`README.md`, `main.dart`, `index.ts`) and not a short one.
  static bool isDistinctive(String name) {
    final dot = name.lastIndexOf('.');
    final stem = (dot > 0 ? name.substring(0, dot) : name).toLowerCase();
    return stem.length >= 5 && !_commonStems.contains(stem);
  }

  /// The other checkouts of the repository [cwd] is in (cached for
  /// [cacheFor]). Null when the search ran out of time or was cancelled.
  Future<Checkouts?> checkouts(String cwd, SearchCancel cancel) async {
    final hit = _cache[cwd];
    if (hit != null && _now().difference(hit.at) < cacheFor) return hit.value;
    final budget = _Budget(worktreeBudget, cancel);
    final found = await _discover(cwd, budget);
    return budget.complete ? found : null;
  }

  /// Looks for [relatives] (paths below [cwd], most likely first) in the other
  /// checkouts of [cwd]'s repository. A path taken from the root of a
  /// checkout is tried too when [cwd] is a folder inside it.
  Future<PathFindReport> inWorktrees(List<String> relatives, String cwd, SearchCancel cancel) async {
    final budget = _Budget(worktreeBudget, cancel);
    final known = _cache[cwd];
    final Checkouts found;
    if (known != null && _now().difference(known.at) < cacheFor) {
      found = known.value;
    } else {
      found = await _discover(cwd, budget);
    }
    if (found.others.isEmpty) return const PathFindReport();

    final top = found.top;
    final sub = top != null && cwd != top && cwd.startsWith('$top/') ? cwd.substring(top.length + 1) : '';
    final rels = <String>{
      if (sub.isNotEmpty) for (final r in relatives) RemotePath.normalize('$sub/$r'),
      for (final r in relatives) RemotePath.normalize(r),
    }.where((r) => r != '.' && r != '..' && !r.startsWith('../') && !RemotePath.isAbsolute(r)).toList();
    if (rels.isEmpty) return const PathFindReport();

    final hits = <PathCandidate>[];
    var looked = 0;
    await _pool(found.others, budget, (root) async {
      for (final rel in rels) {
        final stat = await budget.attempt(() => files.stat(RemotePath.join(root, rel)));
        if (stat != null) {
          hits.add(PathCandidate(stat: stat, root: root, source: CandidateSource.worktree));
          break;
        }
        if (budget.spent) return;
      }
      looked++;
    });
    return PathFindReport(candidates: _newestFirst(hits), worktreesLooked: looked);
  }

  /// Looks below [cwd] for [name] (an exact match), breadth first: at most
  /// [maxDepth] levels and [maxFolders] folders listed, never entering hidden
  /// folders, [skipFolders] or links.
  Future<PathFindReport> byName(String name, String cwd, SearchCancel cancel) async {
    final budget = _Budget(searchBudget, cancel);
    final hits = <PathCandidate>[];
    var level = <String>[cwd];
    var listed = 0;
    for (var depth = 0; depth <= maxDepth && level.isNotEmpty; depth++) {
      final next = <String>[];
      final room = maxFolders - listed;
      if (room <= 0) break;
      final batch = level.length > room ? level.sublist(0, room) : level;
      listed += batch.length;
      final children = List<List<String>>.filled(batch.length, const []);
      await _pool(List<int>.generate(batch.length, (i) => i), budget, (i) async {
        final entries = await budget.attempt(() => files.list(batch[i]));
        if (entries == null) return;
        final down = <String>[];
        for (final e in entries) {
          if (e.name == name) {
            final kind = e.resolvedKind;
            if (kind == RemoteEntryKind.file || kind == RemoteEntryKind.dir) {
              hits.add(PathCandidate(
                stat: RemoteStat(path: e.path, kind: kind!, size: e.size, modified: e.modified, mode: e.mode),
                root: cwd,
                source: CandidateSource.search,
              ));
            }
          }
          if (e.kind == RemoteEntryKind.dir && !e.isHidden && !skipFolders.contains(e.name)) down.add(e.path);
        }
        children[i] = down;
      });
      if (budget.spent || hits.length >= maxMatches) break;
      for (final c in children) {
        next.addAll(c);
      }
      level = next;
    }
    final trimmed = hits.length > maxMatches ? hits.sublist(0, maxMatches) : hits;
    return PathFindReport(candidates: _newestFirst(trimmed), searched: true);
  }

  Future<Checkouts> _discover(String cwd, _Budget budget) async {
    String? top;
    RemoteStat? git;
    var dir = cwd;
    for (var i = 0; i < 3 && dir != '/' && RemotePath.isAbsolute(dir); i++) {
      git = await budget.attempt(() => files.stat(RemotePath.join(dir, '.git')));
      if (git != null) {
        top = dir;
        break;
      }
      if (budget.spent) break;
      dir = RemotePath.parent(dir);
    }
    var result = const Checkouts();
    if (top != null && git != null) {
      result = Checkouts(top: top, others: await _listCheckouts(top, git, budget));
    }
    if (budget.complete) _cache[cwd] = (at: _now(), value: result);
    return result;
  }

  Future<List<String>> _listCheckouts(String top, RemoteStat git, _Budget budget) async {
    String worktreesDir;
    String? mainRoot;
    if (git.isDirectory) {
      worktreesDir = RemotePath.join(git.path, 'worktrees');
    } else if (git.isFile) {
      final line = await _firstLine(git.path, budget);
      if (line == null || !line.startsWith('gitdir:')) return const [];
      final target = RemotePath.resolve(line.substring(7).trim(), cwd: top);
      if (target == null) return const [];
      worktreesDir = RemotePath.parent(target);
      if (RemotePath.basename(worktreesDir) != 'worktrees') return const []; // a submodule
      final mainGit = RemotePath.parent(worktreesDir);
      if (RemotePath.basename(mainGit) == '.git') mainRoot = RemotePath.parent(mainGit);
    } else {
      return const [];
    }

    final out = <String>[];
    void add(String? root) {
      if (root == null || root == '/' || root == top || out.contains(root) || out.length >= maxWorktrees) return;
      out.add(root);
    }

    add(mainRoot);
    final listing = await budget.attempt(() => files.list(worktreesDir));
    if (listing == null) return out;
    final entries = listing.where((e) => e.isDirectory).toList()
      ..sort((a, b) => _byTimeDesc(a.modified, b.modified, a.name, b.name));
    final shown = entries.take(maxWorktrees).toList();
    final roots = List<String?>.filled(shown.length, null);
    await _pool(List<int>.generate(shown.length, (i) => i), budget, (i) async {
      final line = await _firstLine(RemotePath.join(shown[i].path, 'gitdir'), budget);
      roots[i] = line == null ? null : _worktreeOf(line);
    });
    roots.forEach(add);
    return out;
  }

  /// The folder a worktree's `gitdir` file points into (`<folder>/.git`), or
  /// null for anything else.
  static String? _worktreeOf(String line) {
    if (!RemotePath.isAbsolute(line) || line.contains('\u0000')) return null;
    final git = RemotePath.normalize(line);
    return RemotePath.basename(git) == '.git' ? RemotePath.parent(git) : null;
  }

  Future<String?> _firstLine(String path, _Budget budget) async {
    final bytes = await budget.attempt(() => files.read(path, length: 4096));
    if (bytes == null) return null;
    final text = utf8.decode(bytes, allowMalformed: true);
    final cut = text.indexOf('\n');
    final line = (cut < 0 ? text : text.substring(0, cut)).trim();
    return line.isEmpty ? null : line;
  }

  /// Runs [task] over [items] with at most [parallel] in flight, starting
  /// nothing once [budget] is spent.
  Future<void> _pool<T>(List<T> items, _Budget budget, Future<void> Function(T item) task) async {
    final queue = Queue<T>.of(items);
    Future<void> worker() async {
      while (!budget.spent && queue.isNotEmpty) {
        await task(queue.removeFirst());
      }
    }

    await Future.wait([for (var i = 0; i < math.min(parallel, items.length); i++) worker()]);
  }

  static int _byTimeDesc(DateTime? a, DateTime? b, String nameA, String nameB) {
    if (a != null && b != null) {
      final c = b.compareTo(a);
      if (c != 0) return c;
    } else if (a != null) {
      return -1;
    } else if (b != null) {
      return 1;
    }
    return nameA.compareTo(nameB);
  }

  static List<PathCandidate> _newestFirst(List<PathCandidate> hits) =>
      hits..sort((a, b) => _byTimeDesc(a.modified, b.modified, a.path, b.path));
}

/// Time left for one search, and whether it was cut short.
class _Budget {
  _Budget(this._total, this._cancel) {
    _clock.start();
  }

  final Duration _total;
  final SearchCancel _cancel;
  final _clock = Stopwatch();
  var _cut = false;
  var _failed = false;

  bool get spent => _cut || _cancel.isCancelled || _clock.elapsed >= _total;

  /// Finished without running out of time, being cancelled, or meeting a
  /// connection failure: what it learnt is worth remembering.
  bool get complete => !spent && !_failed;

  /// Runs [op] and returns its value; null when it failed (not found and
  /// permission errors are simply "nothing here"), when the budget ran out
  /// or when the search was cancelled. Never throws.
  Future<T?> attempt<T>(Future<T> Function() op) async {
    if (spent) return null;
    final done = Completer<T?>();
    void finish(T? value) {
      if (!done.isCompleted) done.complete(value);
    }

    final timer = Timer(_total - _clock.elapsed, () {
      _cut = true;
      finish(null);
    });
    unawaited(_cancel.whenCancelled.then((_) => finish(null)));
    op().then(finish, onError: (Object e) {
      if (e is RemoteFileException &&
          (e.kind == RemoteFileErrorKind.network || e.kind == RemoteFileErrorKind.failed)) {
        _failed = true;
      }
      finish(null);
    });
    try {
      return await done.future;
    } finally {
      timer.cancel();
    }
  }
}
