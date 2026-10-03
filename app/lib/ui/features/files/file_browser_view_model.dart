import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/services/remote_files.dart';

/// One directory: its entries sorted the way a person looks for things
/// (folders first, then files, each in case-insensitive natural order), with
/// dotfiles hidden until asked for.
///
/// The sort runs once per load and is remembered, so toggling hidden files or
/// rebuilding the list never re-sorts: a 5,000-entry directory stays cheap on
/// the UI isolate.
class FileBrowserViewModel extends ChangeNotifier {
  FileBrowserViewModel({
    required this._files,
    required this.path,
    this.directoriesOnly = false,
    this.showHidden = false,
  });

  final RemoteFiles _files;
  final String path;

  /// Folder picking: files are not listed at all.
  final bool directoriesOnly;

  bool showHidden;

  bool _loading = true;
  RemoteFileException? _error;
  List<RemoteEntry> _sorted = const [];
  List<RemoteEntry>? _visible;
  var _hiddenCount = 0;
  String? _home;
  var _epoch = 0;
  var _disposed = false;

  bool get loading => _loading;
  RemoteFileException? get error => _error;

  /// Visible entries in display order.
  List<RemoteEntry> get entries => _visible ??= _filter();

  /// Dotfiles currently not shown (0 while they are shown).
  int get hiddenCount => showHidden ? 0 : _hiddenCount;

  /// Entries of the directory, whatever is hidden.
  int get totalCount => _sorted.length;

  /// The login directory once known, so breadcrumbs can say `~`.
  String? get home => _home;

  String get name => RemotePath.basename(path);
  String? get parentPath => path == '/' ? null : RemotePath.parent(path);

  /// Loads (or reloads) the directory. A reload keeps the old entries on
  /// screen until the new ones arrive, and keeps them if it fails.
  Future<void> load() async {
    final epoch = ++_epoch;
    final reload = _sorted.isNotEmpty;
    if (!reload) {
      _loading = true;
      _error = null;
      notifyListeners();
    }
    unawaited(_loadHome());
    try {
      final entries = await _files.list(path);
      if (_disposed || epoch != _epoch) return;
      _sorted = sortEntries(directoriesOnly ? entries.where((e) => e.isDirectory) : entries);
      _hiddenCount = _sorted.where((e) => e.isHidden).length;
      _visible = null;
      _error = null;
    } on RemoteFileException catch (e) {
      if (_disposed || epoch != _epoch) return;
      // A failed refresh of a listing already on screen leaves it there.
      if (!reload) _error = e;
    }
    _loading = false;
    notifyListeners();
  }

  Future<void> _loadHome() async {
    if (_home != null) return;
    try {
      final home = await _files.home();
      if (_disposed) return;
      if (_home != home) {
        _home = home;
        notifyListeners();
      }
    } on RemoteFileException {
      // Breadcrumbs just start at `/`.
    }
  }

  void setShowHidden(bool value) {
    if (showHidden == value) return;
    showHidden = value;
    _visible = null;
    notifyListeners();
  }

  List<RemoteEntry> _filter() =>
      showHidden ? _sorted : List.unmodifiable(_sorted.where((e) => !e.isHidden));

  /// The crumbs for [path]: `/`, then `~` for a path under [home] (instead of
  /// its segments), then the rest.
  List<({String path, String label})> get breadcrumbs {
    final all = RemotePath.breadcrumbs(path);
    final home = _home;
    if (home == null || home == '/' || !(path == home || path.startsWith('$home/'))) return all;
    final homeDepth = RemotePath.breadcrumbs(home).length;
    return [
      all.first,
      (path: home, label: '~'),
      ...all.skip(homeDepth),
    ];
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Folders first, then everything else; each group in case-insensitive natural
/// order (`file2` before `file10`). Names are lowercased once, not per compare.
List<RemoteEntry> sortEntries(Iterable<RemoteEntry> entries) {
  final keyed = [for (final e in entries) (e.name.toLowerCase(), e)];
  keyed.sort((a, b) {
    final da = a.$2.isDirectory;
    final db = b.$2.isDirectory;
    if (da != db) return da ? -1 : 1;
    final c = RemotePath.naturalCompareFolded(a.$1, b.$1);
    return c != 0 ? c : a.$2.name.compareTo(b.$2.name);
  });
  return List.unmodifiable([for (final k in keyed) k.$2]);
}
