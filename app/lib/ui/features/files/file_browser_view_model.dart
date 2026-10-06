import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/services/remote_files.dart';
import 'file_listing.dart';
import 'photo_files.dart';

/// A folder with at least this many pictures can show them as a grid.
const photoGridMinimum = 6;

/// What a person has chosen about how folders look, shared by every folder of
/// one browsing session (the browser they opened and every folder pushed on
/// top of it): hidden files, the sort, folders first, the "changed in the last
/// hour" filter. Folders you walk into inherit it; leaving the browser forgets
/// it.
class FileBrowserOptions extends ChangeNotifier {
  FileBrowserOptions({
    this.sort = FileSort.name,
    this.foldersFirst = true,
    this.showHidden = false,
    this.recentOnly = false,
  });

  FileSort sort;
  bool foldersFirst;
  bool showHidden;

  /// Only entries changed in the last [recentWindow].
  bool recentOnly;

  /// Folders a listing was refused for, so the row that leads there is dimmed.
  final denied = <String>{};

  (FileSort, bool)? _beforeRecent;

  void setShowHidden(bool value) {
    if (showHidden == value) return;
    showHidden = value;
    notifyListeners();
  }

  void setSort(FileSort value) {
    if (sort == value) return;
    sort = value;
    // A sort picked by hand ends the "come back to what it was" of the chip.
    _beforeRecent = null;
    notifyListeners();
  }

  void setFoldersFirst(bool value) {
    if (foldersFirst == value) return;
    foldersFirst = value;
    _beforeRecent = null;
    notifyListeners();
  }

  /// One tap for "what did it just touch": the filter on, newest first with
  /// the folders among the files. Off again, the ordering goes back to what
  /// it was (unless it was changed by hand meanwhile).
  void setRecentOnly(bool value) {
    if (recentOnly == value) return;
    recentOnly = value;
    if (value) {
      _beforeRecent = (sort, foldersFirst);
      sort = FileSort.modified;
      foldersFirst = false;
    } else {
      final before = _beforeRecent;
      if (before != null) {
        sort = before.$1;
        foldersFirst = before.$2;
      }
      _beforeRecent = null;
    }
    notifyListeners();
  }

  void markDenied(String path) {
    if (denied.add(path)) notifyListeners();
  }
}

/// One directory, as [FileListing] orders and filters it. The folder is read
/// once per load; changing the sort, the hidden switch or the search never
/// reads it again, and a 5,000-entry directory stays cheap on the UI isolate.
///
/// A browser can open before its folder is known: pass [startDir] (or nothing,
/// for the login directory) instead of [path] and [load] works it out first,
/// so the screen can be on show while the SFTP round trips happen.
class FileBrowserViewModel extends ChangeNotifier {
  FileBrowserViewModel({
    required this._files,
    this._path,
    this.startDir,
    this.directoriesOnly = false,
    FileBrowserOptions? options,
    DateTime Function()? clock,
  }) : options = options ?? FileBrowserOptions(),
       _clock = clock ?? DateTime.now {
    this.options.addListener(_optionsChanged);
  }

  final RemoteFiles _files;
  final String? startDir;
  final FileBrowserOptions options;
  final DateTime Function() _clock;

  /// Folder picking: files are not listed at all.
  final bool directoriesOnly;

  String? _path;
  bool _loading = true;
  RemoteFileException? _error;
  FileListing? _listing;
  List<RemoteEntry>? _visible;
  int? _base;
  var _query = '';
  String? _home;
  var _epoch = 0;
  var _disposed = false;
  var _photoGrid = false;
  List<RemoteEntry>? _photos;

  RemoteFiles get files => _files;

  /// The moment "now" is for this browser (rows say "3 min ago" from it).
  DateTime now() => _clock();

  bool get loading => _loading;
  RemoteFileException? get error => _error;

  /// The folder is known (always, unless the browser opened without one and
  /// has not worked it out yet).
  bool get resolved => _path != null;

  /// The folder's absolute path; empty until [resolved].
  String get path => _path ?? '';

  bool get showHidden => options.showHidden;

  /// What the search field holds.
  String get query => _query;
  bool get searching => _query.trim().isNotEmpty;

  /// Any filter narrows the list: the search, or "changed in the last hour".
  bool get filtered => searching || options.recentOnly;

  /// Visible entries in display order.
  List<RemoteEntry> get entries => _visible ??= _build();

  /// Entries after the hidden switch only (what the filters narrow down).
  int get baseCount => _base ??= _listing == null
      ? 0
      : _listing!.view(sort: FileSort.name, foldersFirst: true, showHidden: options.showHidden).length;

  /// Dotfiles currently not shown (0 while they are shown).
  int get hiddenCount => options.showHidden ? 0 : (_listing?.hiddenCount ?? 0);

  /// Entries of the directory, whatever is hidden.
  int get totalCount => _listing?.length ?? 0;

  /// The login directory once known, so breadcrumbs can say `~`.
  String? get home => _home;

  String get name => resolved ? RemotePath.basename(path) : 'Files';
  String? get parentPath => !resolved || path == '/' ? null : RemotePath.parent(path);

  /// Whether the row for [e] should look unavailable: nobody can read it, or
  /// the host refused this login when it was tried.
  bool isDenied(RemoteEntry e) => options.denied.contains(e.path) || isUnreadable(e);

  void setQuery(String value) {
    if (_query == value) return;
    _query = value;
    _visible = null;
    _photos = null;
    notifyListeners();
  }

  void setShowHidden(bool value) => options.setShowHidden(value);

  List<RemoteEntry> _build() {
    final listing = _listing;
    if (listing == null) return const [];
    return List.unmodifiable(
      listing.view(
        sort: options.sort,
        foldersFirst: options.foldersFirst,
        showHidden: options.showHidden,
        query: _query,
        changedSince: options.recentOnly ? _clock().subtract(recentWindow) : null,
      ),
    );
  }

  void _optionsChanged() {
    if (_disposed) return;
    _visible = null;
    _photos = null;
    _base = null;
    notifyListeners();
  }

  /// Loads (or reloads) the directory. A reload keeps the old entries on
  /// screen until the new ones arrive, and keeps them if it fails.
  Future<void> load() async {
    final epoch = ++_epoch;
    final reload = _listing != null;
    if (!reload) {
      _loading = true;
      _error = null;
      notifyListeners();
    }
    if (_path == null) {
      final start = await _startDirectory();
      if (_disposed || epoch != _epoch) return;
      _path = start;
      notifyListeners();
    }
    final path = _path!;
    unawaited(_loadHome());
    try {
      final entries = await _files.list(path);
      if (_disposed || epoch != _epoch) return;
      _listing = FileListing(directoriesOnly ? entries.where((e) => e.isDirectory) : entries);
      _visible = null;
      _photos = null;
      _base = null;
      _error = null;
    } on RemoteFileException catch (e) {
      if (_disposed || epoch != _epoch) return;
      // A failed refresh of a listing already on screen leaves it there.
      if (!reload) {
        _error = e;
        if (e.kind == RemoteFileErrorKind.permission) options.markDenied(path);
      }
    }
    _loading = false;
    notifyListeners();
  }

  /// [startDir] resolved to an absolute path, else home, else `/`. A start
  /// that cannot be resolved does not stop the browser from opening: it shows
  /// its own error for that folder.
  Future<String> _startDirectory() async {
    final start = startDir;
    try {
      if (start != null && start.trim().isNotEmpty) return await _files.resolve(start);
      return await _files.home();
    } on RemoteFileException {
      return start != null && RemotePath.isAbsolute(start) ? start : '/';
    }
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

  /// The photo grid replaces the entry list. Kept for the browser's life only.
  bool get photoGrid => _photoGrid;

  void setPhotoGrid(bool value) {
    if (_photoGrid == value) return;
    _photoGrid = value;
    notifyListeners();
  }

  /// The pictures among [entries] (so the hidden switch and the filters apply),
  /// in viewing order. Remembered like [entries].
  List<RemoteEntry> get photos => _photos ??= photoEntries(entries);

  /// Enough pictures to offer the grid.
  bool get hasManyPhotos => !directoriesOnly && photos.length >= photoGridMinimum;

  /// The crumbs for [path]: `/`, then `~` for a path under [home] (instead of
  /// its segments), then the rest. None before the folder is known.
  List<({String path, String label})> get breadcrumbs {
    if (!resolved) return const [];
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
    options.removeListener(_optionsChanged);
    super.dispose();
  }
}
