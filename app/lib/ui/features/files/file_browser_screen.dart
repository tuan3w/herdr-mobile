import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../../core/tokens.dart';
import '../settings/app_switch.dart';
import 'file_browser_view_model.dart';
import 'file_format.dart';
import 'file_listing.dart';
import 'file_row.dart';
import 'file_thumb.dart';
import 'file_widgets.dart';
import 'photo_files.dart';
import 'photo_grid.dart';

/// Whether the browser opens files, picks a folder, or picks a file.
enum FileBrowserMode { browse, pickDirectory, pickFile }

/// One browsing session: the stack of folders a person walked down and what
/// they chose about how to look at them ([options]: hidden files, sort,
/// folders first, "changed in the last hour"). Every folder pushed from a
/// browser shares its session, so a choice made three levels down is still
/// there on the way back and in the next folder.
///
/// It also owns where a breadcrumb leads. The stack holds one route per
/// level, so a tap on an ancestor POPS back to it (the folder is still there,
/// listed and scrolled as it was) and the stack never grows past the depth of
/// the folder. An ancestor above where the session started is not on the stack:
/// the first browser is pointed at it in place.
class FileBrowserSession {
  FileBrowserSession({FileBrowserOptions? options}) : options = options ?? FileBrowserOptions();

  final FileBrowserOptions options;
  final _levels = <_BrowserLevel>[];

  /// The folders on the stack, first opened first.
  List<String> get paths => [for (final level in _levels) level.path];

  /// Takes the stack back to [target] (an ancestor of the folder being shown).
  void goTo(NavigatorState navigator, String target) {
    if (_levels.isEmpty) return;
    for (final level in _levels.reversed) {
      if (level.path == target && level.route != null) {
        navigator.popUntil((r) => r == level.route);
        return;
      }
    }
    final base = _levels.first;
    if (base.route != null) navigator.popUntil((r) => r == base.route);
    base.retarget(target);
  }
}

abstract interface class _BrowserLevel {
  String get path;
  ModalRoute<Object?>? get route;
  void retarget(String path);
}

/// One directory of a machine. Tapping a folder pushes another browser (so the
/// system back gesture walks back up); tapping a file opens the viewer.
///
/// The folder is [path], or, for a browser pushed before its folder is known,
/// [startDir] (the login directory when null): the screen is on show at once
/// and the host is asked inside it. [onResolved] says when the folder is known.
///
/// In [FileBrowserMode.pickDirectory] only folders are listed and a bottom bar
/// returns the folder being looked at: the route (and every browser pushed on
/// top of it) pops with that path.
///
/// In [FileBrowserMode.pickFile] everything is listed, folders open as usual
/// and a tap on a file pops the whole stack of browsers with its absolute
/// path (the chat's "File from the host"). Nothing is opened or read.
class FileBrowserScreen extends StatefulWidget {
  const FileBrowserScreen({
    super.key,
    required this.machine,
    this.path,
    this.startDir,
    this.mode = FileBrowserMode.browse,
    this.session,
    this.onResolved,
    this.clock,
    this.thumbs,
  }) : assert(path == null || startDir == null, 'a folder or a place to start from, not both');

  final MachineConnection machine;
  final String? path;
  final String? startDir;
  final FileBrowserMode mode;

  /// Shared by the folders of one session; a new one when null.
  final FileBrowserSession? session;
  final VoidCallback? onResolved;

  /// What "now" is, for "3 min ago" and "changed in the last hour".
  final DateTime Function()? clock;

  /// Where thumbnails are read; the shared loader when null.
  final ThumbLoader? thumbs;

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> implements _BrowserLevel {
  late final FileBrowserSession _session = widget.session ?? FileBrowserSession();
  late FileBrowserViewModel _vm;
  ModalRoute<Object?>? _route;
  var _navigating = false;
  var _announced = false;

  FileBrowserMode get _mode => widget.mode;

  @override
  String get path => _vm.path;

  @override
  ModalRoute<Object?>? get route => _route;

  @override
  void initState() {
    super.initState();
    _session._levels.add(this);
    _vm = _newViewModel(widget.path, widget.startDir);
    _announce();
    unawaited(_vm.load());
  }

  FileBrowserViewModel _newViewModel(String? path, String? startDir) {
    final vm = FileBrowserViewModel(
      files: widget.machine.files,
      path: path,
      startDir: startDir,
      directoriesOnly: _mode == FileBrowserMode.pickDirectory,
      options: _session.options,
      clock: widget.clock,
    )..addListener(_announce);
    return vm;
  }

  void _announce() {
    if (_announced || !_vm.resolved) return;
    _announced = true;
    widget.onResolved?.call();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  /// Points this browser at [path] in place (the bottom of the stack, when a
  /// breadcrumb names a folder above where the session started).
  @override
  void retarget(String path) {
    final old = _vm;
    final fresh = _newViewModel(path, null);
    setState(() => _vm = fresh);
    unawaited(fresh.load());
    old.removeListener(_announce);
    // The old screen still reads it until the next frame swaps the provider.
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  @override
  void dispose() {
    _session._levels.remove(this);
    _vm.removeListener(_announce);
    _vm.dispose();
    super.dispose();
  }

  void _goTo(String target) {
    Haptics.tick();
    _session.goTo(Navigator.of(context), target);
  }

  Future<void> _push(Route<String> route) async {
    if (_navigating) return;
    _navigating = true;
    final navigator = Navigator.of(context);
    try {
      final chosen = await navigator.push<String>(route);
      // A picker hands its answer down the whole stack.
      if (chosen != null && _mode != FileBrowserMode.browse && navigator.mounted) navigator.pop(chosen);
    } finally {
      _navigating = false;
    }
  }

  void _open(RemoteEntry e) {
    Haptics.tick();
    FocusManager.instance.primaryFocus?.unfocus();
    if (e.isDirectory) {
      unawaited(
        _push(
          MaterialPageRoute<String>(
            builder: (_) => FileBrowserScreen(
              machine: widget.machine,
              path: e.path,
              mode: _mode,
              session: _session,
              clock: widget.clock,
              thumbs: widget.thumbs,
            ),
          ),
        ),
      );
    } else if (e.isFile && _mode == FileBrowserMode.pickFile) {
      Navigator.of(context).pop(e.path);
    } else if (e.isFile) {
      unawaited(
        _push(
          fileViewerRoute<String>(
            widget.machine,
            RemoteStat(
              path: e.path,
              kind: RemoteEntryKind.file,
              size: e.size,
              modified: e.modified,
              mode: e.mode,
            ),
            // A picture pages through the folder's other pictures.
            siblings: _vm.entries,
          ),
        ),
      );
    } else {
      showToast(
        context,
        e.isBrokenLink ? '${e.name} points to something that no longer exists.' : "${e.name} can't be opened.",
        kind: ToastKind.failed,
      );
    }
  }

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider<FileBrowserViewModel>.value(
    value: _vm,
    child: _BrowserView(
      // A new folder in place starts at the top with an empty search.
      key: ObjectKey(_vm),
      mode: _mode,
      thumbs: widget.thumbs,
      onOpen: _open,
      onOpenPhoto: (i) => unawaited(openFolderPhotos(context, widget.machine, _vm.photos, i)),
      onGoTo: _goTo,
    ),
  );
}

class _BrowserView extends StatefulWidget {
  const _BrowserView({
    super.key,
    required this.mode,
    required this.thumbs,
    required this.onOpen,
    required this.onOpenPhoto,
    required this.onGoTo,
  });

  final FileBrowserMode mode;
  final ThumbLoader? thumbs;
  final ValueChanged<RemoteEntry> onOpen;

  /// A tile of the photo grid was tapped: the index among [FileBrowserViewModel.photos].
  final ValueChanged<int> onOpenPhoto;
  final ValueChanged<String> onGoTo;

  @override
  State<_BrowserView> createState() => _BrowserViewState();
}

class _BrowserViewState extends State<_BrowserView> {
  final _search = TextEditingController();

  bool get _pick => widget.mode == FileBrowserMode.pickDirectory;
  bool get _pickFile => widget.mode == FileBrowserMode.pickFile;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final vm = context.watch<FileBrowserViewModel>();
    final entries = vm.entries;
    final inset = MediaQuery.paddingOf(context).bottom;
    final failed = vm.error;
    final now = vm.now();

    final showToggle = widget.mode == FileBrowserMode.browse && !vm.loading && failed == null && vm.hasManyPhotos;
    final showGrid = showToggle && vm.photoGrid;
    final count = vm.loading ? '' : _countLine(vm, grid: showGrid);
    final showTools = !vm.loading && failed == null && (vm.totalCount > 0 || vm.searching);
    final list = AppRefresh(
      onRefresh: vm.load,
      edgeOffset: SliverLargeTitle.extent(context, hasSubtitle: true, bottomHeight: AppChip.height),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverLargeTitle(
            title: vm.name,
            subtitle: Text(
              count,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.secondary.copyWith(color: ds.textSecondary),
            ),
            leading: CircleButton(
              icon: LucideIcons.chevronLeft,
              tooltip: 'Back',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            actions: [
              if (showToggle)
                CircleButton(
                  icon: LucideIcons.images,
                  tooltip: showGrid ? 'List' : 'Photos',
                  active: showGrid,
                  onPressed: () {
                    Haptics.tick();
                    vm.setPhotoGrid(!showGrid);
                  },
                ),
              CircleButton(
                icon: vm.showHidden ? LucideIcons.eye : LucideIcons.eyeOff,
                tooltip: vm.showHidden ? 'Hide hidden files' : 'Show hidden files',
                active: vm.showHidden,
                onPressed: () => vm.setShowHidden(!vm.showHidden),
              ),
            ],
            bottom: FileBreadcrumbs(crumbs: vm.breadcrumbs, onTap: widget.onGoTo),
            bottomHeight: AppChip.height,
          ),
          if (showTools)
            SliverToBoxAdapter(
              child: _Tools(
                controller: _search,
                compact: _pick,
                search: vm.baseCount >= _searchFrom || vm.searching,
              ),
            ),
          if (vm.loading)
            const SliverFillRemaining(child: DelayedSkeleton(rows: true))
          else if (failed != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.sm, Gap.gutter, 0),
                child: _failure(vm, failed),
              ),
            )
          else if (entries.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyFolderState(vm: vm, pick: _pick, onClearSearch: _clearSearch),
            )
          else if (showGrid)
            PhotoGrid(
              files: vm.files,
              entries: vm.photos,
              onOpen: (i) {
                Haptics.tick();
                widget.onOpenPhoto(i);
              },
            )
          else
            SliverList.builder(
              itemCount: entries.length,
              itemBuilder: (context, i) => FileRow(
                entry: entries[i],
                files: vm.files,
                now: now,
                denied: vm.isDenied(entries[i]),
                thumbs: widget.thumbs,
                onTap: () => widget.onOpen(entries[i]),
              ),
            ),
          SliverToBoxAdapter(child: SizedBox(height: Gap.xxl + (_pick ? 0 : inset))),
        ],
      ),
    );

    return Scaffold(
      backgroundColor: ds.bg,
      body: _pick
          ? Column(children: [Expanded(child: list), _PickBar(path: vm.path, enabled: failed == null && !vm.loading)])
          : list,
    );
  }

  void _clearSearch() {
    _search.clear();
    context.read<FileBrowserViewModel>().setQuery('');
  }

  /// What a failed listing offers: for a folder you may not read or that is
  /// gone, the folder above; for a link that dropped, another try.
  Widget _failure(FileBrowserViewModel vm, RemoteFileException failed) {
    final parent = vm.parentPath;
    final up = parent == null
        ? null
        : switch (failed.kind) {
            RemoteFileErrorKind.notFound => 'Go up',
            RemoteFileErrorKind.permission => 'Open parent',
            _ => null,
          };
    return FileErrorPanel(
      error: failed,
      name: vm.name,
      onRetry: vm.load,
      alsoRetry: failed.kind == RemoteFileErrorKind.permission,
      action: up == null
          ? null
          : AppButton(
              label: up,
              kind: AppButtonKind.secondary,
              compact: true,
              onPressed: () => widget.onGoTo(parent!),
            ),
    );
  }

  String _countLine(FileBrowserViewModel vm, {required bool grid}) {
    if (grid) {
      // Folders are not in the grid: say so, and where they went.
      final photos = vm.photos.length;
      final folders = vm.entries.where((e) => e.isDirectory).length;
      final counted = '${groupDigits(photos)} ${photos == 1 ? 'photo' : 'photos'}';
      return folders > 0 ? '$counted · ${groupDigits(folders)} ${folders == 1 ? 'folder' : 'folders'} in list' : counted;
    }
    final shown = vm.entries.length;
    String noun(int n) => _pick ? (n == 1 ? 'folder' : 'folders') : (n == 1 ? 'item' : 'items');
    final hidden = vm.hiddenCount;
    if (vm.error != null) return vm.path;
    final base = vm.baseCount;
    final counted = vm.filtered
        ? '${groupDigits(shown)} of ${groupDigits(base)} ${noun(base)}'
        : (hidden > 0 ? '${groupDigits(shown)} ${noun(shown)} · $hidden hidden' : '${groupDigits(shown)} ${noun(shown)}');
    return _pickFile ? '$counted · choose a file' : counted;
  }
}

/// Find-in-folder, and the two things to do to the list: how it is sorted and
/// whether only what changed in the last hour is shown.
///
/// The find field appears from [_searchFrom] entries up (or while a search is
/// on): in a folder of a few files it is only height.
class _Tools extends StatelessWidget {
  const _Tools({required this.controller, required this.compact, required this.search});

  final TextEditingController controller;

  /// Folder picking: the search only (there are no files to sort by time).
  final bool compact;

  /// The find field is there (a folder of a few entries needs none).
  final bool search;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final vm = context.read<FileBrowserViewModel>();
    final options = vm.options;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.xs),
      child: Column(
        children: [
          if (search)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.xs, Gap.gutter, Gap.xs),
              child: Semantics(
                label: 'Find in this folder',
                textField: true,
                child: ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) => TextField(
                    controller: controller,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.search,
                    onChanged: vm.setQuery,
                    onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
                    style: Type.body.copyWith(fontSize: 15, color: ds.text),
                    cursorColor: ds.accent,
                    textAlignVertical: TextAlignVertical.center,
                    decoration: InputDecoration(
                      hintText: 'Find in ${vm.name}',
                      constraints: const BoxConstraints(minHeight: kMinTap, maxHeight: kMinTap),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                      prefixIcon: Icon(LucideIcons.search, size: 16, color: ds.textTertiary),
                      suffixIcon: controller.text.isEmpty
                          ? null
                          : PressBuilder(
                              onTap: () {
                                controller.clear();
                                vm.setQuery('');
                              },
                              semanticLabel: 'Clear search',
                              minTapSize: kMinTap,
                              builder: (context, pressed) =>
                                  Icon(LucideIcons.x, size: 16, color: pressed ? ds.text : ds.textSecondary),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          if (!compact)
            SizedBox(
              height: AppChip.height,
              child: ListenableBuilder(
                listenable: options,
                builder: (context, _) => ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
                  children: [
                    AppChip(
                      label: options.sort.label,
                      semanticLabel: 'Sort by ${options.sort.label}',
                      leading: Icon(LucideIcons.arrowUpDown, size: 14, color: ds.textSecondary),
                      selected: options.sort != FileSort.name,
                      onTap: () => unawaited(_showSortSheet(context, options)),
                    ),
                    const SizedBox(width: Gap.sm),
                    AppChip(
                      label: 'Changed in the last hour',
                      leading: Icon(LucideIcons.clock, size: 14, color: options.recentOnly ? ds.text : ds.textSecondary),
                      selected: options.recentOnly,
                      onTap: () => options.setRecentOnly(!options.recentOnly),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Entries a folder needs before the find field is worth its height.
const _searchFrom = 8;

const _sortIcons = {
  FileSort.name: LucideIcons.arrowDownAZ,
  FileSort.modified: LucideIcons.clock,
  FileSort.size: LucideIcons.hardDrive,
  FileSort.type: LucideIcons.fileType,
};

Future<void> _showSortSheet(BuildContext context, FileBrowserOptions options) => showAppSheet<void>(
  context,
  builder: (sheet) => ListenableBuilder(
    listenable: options,
    builder: (context, _) {
      final ds = context.ds;
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Semantics(
                header: true,
                child: Text('Sort by', style: Type.label.copyWith(color: ds.textSecondary)),
              ),
            ),
            for (final sort in FileSort.values)
              _SortRow(
                sort: sort,
                selected: options.sort == sort,
                onTap: () {
                  options.setSort(sort);
                  Navigator.of(sheet).pop();
                },
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SwitchRow(
                title: 'Folders first',
                value: options.foldersFirst,
                onChanged: options.setFoldersFirst,
              ),
            ),
          ],
        ),
      );
    },
  ),
);

class _SortRow extends StatelessWidget {
  const _SortRow({required this.sort, required this.selected, required this.onTap});

  final FileSort sort;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return PressBuilder(
      onTap: onTap,
      haptic: true,
      selected: selected,
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: pressed ? ds.fill : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.row),
        ),
        child: Row(
          children: [
            Icon(_sortIcons[sort], size: 20, color: ds.textSecondary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(sort.label, style: Type.row.copyWith(color: ds.text)),
                  Text(sort.hint, style: Type.caption.copyWith(color: ds.textSecondary)),
                ],
              ),
            ),
            if (selected) Icon(LucideIcons.check, size: 18, color: ds.accentText),
          ],
        ),
      ),
    );
  }
}

/// What a folder's list says when it has no rows: the filters took everything
/// (search, "changed in the last hour"), only hidden files are there, or the
/// folder is empty.
class EmptyFolderState extends StatelessWidget {
  const EmptyFolderState({
    super.key,
    required this.vm,
    required this.pick,
    required this.onClearSearch,
    this.pullToRefresh = true,
  });

  final FileBrowserViewModel vm;
  final bool pick;
  final VoidCallback onClearSearch;

  /// The list can be pulled down to read the folder again (the empty-folder
  /// message says so).
  final bool pullToRefresh;

  @override
  Widget build(BuildContext context) {
    // Something is in the folder but the filters took all of it.
    if (vm.baseCount > 0) {
      if (vm.searching) {
        return EmptyState(
          icon: LucideIcons.searchX,
          title: 'No matches',
          message: 'Nothing in ${vm.name} matches “${vm.query.trim()}”.',
          action: AppButton(
            label: 'Clear search',
            kind: AppButtonKind.secondary,
            icon: LucideIcons.x,
            onPressed: onClearSearch,
          ),
        );
      }
      return EmptyState(
        icon: LucideIcons.clock,
        title: 'Nothing changed in the last hour',
        message: 'Only this folder is checked, not the folders inside it.',
        action: AppButton(
          label: 'Show all files',
          kind: AppButtonKind.secondary,
          onPressed: () => vm.options.setRecentOnly(false),
        ),
      );
    }
    final onlyHidden = vm.totalCount > 0 && vm.hiddenCount > 0;
    final onlyFiles = pick && vm.totalCount == 0;
    return EmptyState(
      icon: LucideIcons.folderOpen,
      title: onlyHidden ? 'Only hidden files' : (onlyFiles ? 'No folders here' : 'Folder is empty'),
      message: onlyHidden
          ? '${vm.name} has ${vm.hiddenCount} hidden ${vm.hiddenCount == 1 ? 'item' : 'items'}.'
          : (onlyFiles
                ? 'Choose this folder, or go back.'
                : 'Nothing in ${vm.name} yet.${pullToRefresh ? ' Pull down to check again.' : ''}'),
      action: onlyHidden
          ? AppButton(
              label: 'Show hidden files',
              kind: AppButtonKind.secondary,
              icon: LucideIcons.eye,
              onPressed: () => vm.setShowHidden(true),
            )
          : null,
    );
  }
}

/// Tappable path segments, scrolled so the current folder is in view.
class FileBreadcrumbs extends StatefulWidget {
  const FileBreadcrumbs({super.key, required this.crumbs, required this.onTap});

  final List<({String path, String label})> crumbs;
  final ValueChanged<String> onTap;

  @override
  State<FileBreadcrumbs> createState() => _FileBreadcrumbsState();
}

class _FileBreadcrumbsState extends State<FileBreadcrumbs> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _toEnd();
  }

  @override
  void didUpdateWidget(FileBreadcrumbs old) {
    super.didUpdateWidget(old);
    if (old.crumbs.length != widget.crumbs.length) _toEnd();
  }

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && _scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  });

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final crumbs = widget.crumbs;
    // The tap boxes are 44 wide around 32-wide pills: pull the row left so the
    // first pill's edge, not its tap box, sits on the page gutter.
    const pull = (kMinTap - 32) / 2;
    return LayoutBuilder(
      builder: (context, box) => Transform.translate(
        offset: const Offset(-pull, 0),
        child: SizedBox(
          width: box.maxWidth + pull,
          child: SingleChildScrollView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (i, c) in crumbs.indexed) ...[
                  if (i > 0) Icon(LucideIcons.chevronRight, size: 14, color: ds.textTertiary),
                  PressBuilder(
                    onTap: i == crumbs.length - 1 ? null : () => widget.onTap(c.path),
                    minTapSize: kMinTap,
                    builder: (context, pressed) => Container(
                      height: 32,
                      constraints: const BoxConstraints(minWidth: 32),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: pressed ? ds.fill : Colors.transparent,
                        borderRadius: BorderRadius.circular(Radii.control),
                      ),
                      child: Text(
                        c.label,
                        maxLines: 1,
                        style: Type.label.copyWith(
                          color: i == crumbs.length - 1 ? ds.text : ds.textSecondary,
                          fontWeight: i == crumbs.length - 1 ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The folder picker's confirmation bar: where you are, and one button.
class _PickBar extends StatelessWidget {
  const _PickBar({required this.path, required this.enabled});

  final String path;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ds.bg,
        border: Border(top: BorderSide(color: ds.hairline, width: 1 / MediaQuery.devicePixelRatioOf(context))),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(Gap.gutter, Gap.md, Gap.gutter, Gap.md + MediaQuery.paddingOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textDirection: TextDirection.ltr,
              style: codeStyle(ds, size: 12, color: ds.textMuted).copyWith(height: 1.3),
            ),
            const SizedBox(height: Gap.md),
            AppButton(
              label: 'Choose this folder',
              icon: LucideIcons.check,
              expand: true,
              onPressed: enabled ? () => Navigator.of(context).pop(path) : null,
            ),
          ],
        ),
      ),
    );
  }
}
