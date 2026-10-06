import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/services/remote_files.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/theme.dart';
import '../../core/tokens.dart';
import '../agent_session/visible_text.dart';
import '../files/file_browser_screen.dart';
import '../files/file_browser_view_model.dart';
import '../files/file_row.dart';
import '../files/file_thumb.dart';
import '../files/file_widgets.dart';
import 'selection_circle.dart';
import 'sheet_frame.dart';
import 'tray.dart';

/// The attach sheet's Host tab: files on the machine the agent runs on, in
/// the sheet itself (no pushed screen), starting at the session's folder and
/// showing what changed in the last hour first, because "what did it just
/// touch?" is the usual reason to attach a host file.
///
/// A file row toggles a [HostPick] in the [tray] (the circle at its end shows
/// its place); a folder row opens in place. The folders walked down are a stack
/// of [FileBrowserViewModel]s sharing one [FileBrowserOptions], so a breadcrumb
/// pops back to an ancestor without reading it again. `Browse all…` opens the
/// full file browser in pick mode for anything the tab does not show.
///
/// Files are read over SFTP only, one folder at a time; nothing here touches a
/// shell.
class HostTab extends StatefulWidget {
  const HostTab({
    super.key,
    required this.session,
    required this.tray,
    required this.onProblem,
    this.clock,
    this.thumbs,
  });

  final AgentSessionView session;
  final AttachTray tray;

  /// Says why a pick was refused (the composer shows it as a toast).
  final void Function(String message) onProblem;

  /// "Now" for the `Changed recently` filter and the rows' times.
  final DateTime Function()? clock;

  /// Defaults to the shared thumbnail loader.
  final ThumbLoader? thumbs;

  @override
  State<HostTab> createState() => _HostTabState();
}

class _HostTabState extends State<HostTab> {
  late final FileBrowserOptions _options = FileBrowserOptions()..setRecentOnly(true);
  final _stack = <FileBrowserViewModel>[];
  final _search = TextEditingController();
  final _focus = FocusNode();
  var _browsing = false;

  bool get _supported => widget.session.machine.files.supported;
  String get _startPath => widget.session.cwd.isEmpty ? '/' : widget.session.cwd;
  FileBrowserViewModel get _vm => _stack.last;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted && _focus.hasFocus) _expand();
    });
    if (_supported) _push(_startPath);
  }

  @override
  void dispose() {
    for (final vm in _stack) {
      vm.dispose();
    }
    _options.dispose();
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// The keyboard needs the room of the full sheet.
  void _expand() {
    final position = context.getInheritedWidgetOfExactType<SheetScope>()?.position;
    if (position != null && !position.expanded.value) position.expand();
  }

  void _push(String path) {
    final vm = FileBrowserViewModel(
      files: widget.session.machine.files,
      path: path,
      options: _options,
      clock: widget.clock,
    );
    _stack.add(vm);
    unawaited(vm.load());
  }

  /// The old view models are still read by this frame's widgets.
  void _retire(List<FileBrowserViewModel> gone) {
    if (gone.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final vm in gone) {
        vm.dispose();
      }
    });
  }

  void _clearSearch() {
    _search.clear();
    _vm.setQuery('');
  }

  void _open(String path) {
    _focus.unfocus();
    _clearSearch();
    setState(() => _push(path));
  }

  /// A breadcrumb: back to that folder when it is on the stack (still listed),
  /// else a fresh listing of it replaces the walk (an ancestor above where the
  /// tab began).
  void _goTo(String path) {
    Haptics.tick();
    _focus.unfocus();
    _clearSearch();
    final at = _stack.lastIndexWhere((vm) => vm.path == path);
    if (at == _stack.length - 1 && at >= 0) return;
    final List<FileBrowserViewModel> gone;
    if (at >= 0) {
      gone = _stack.sublist(at + 1);
      _stack.removeRange(at + 1, _stack.length);
      setState(() {});
    } else {
      gone = [..._stack];
      _stack.clear();
      setState(() => _push(path));
    }
    _retire(gone);
  }

  void _toggle(RemoteEntry e) => widget.tray.toggle(HostPick(path: e.path, name: e.name, size: e.size));

  void _tap(FileBrowserViewModel vm, RemoteEntry e) {
    final name = visibleText(e.name);
    if (e.isDirectory) {
      Haptics.tick();
      _open(e.path);
    } else if (!e.isFile) {
      Haptics.failed();
      widget.onProblem(e.isBrokenLink ? '$name points to something that no longer exists.' : "$name can't be attached.");
    } else if (vm.isDenied(e)) {
      Haptics.failed();
      widget.onProblem('No permission to read $name');
    } else {
      Haptics.tick();
      _toggle(e);
    }
  }

  Future<void> _browseAll() async {
    if (_browsing) return;
    _browsing = true;
    _focus.unfocus();
    final navigator = Navigator.of(context);
    try {
      final path = await navigator.push<String>(
        MaterialPageRoute<String>(
          builder: (_) => FileBrowserScreen(
            machine: widget.session.machine,
            path: _startPath,
            mode: FileBrowserMode.pickFile,
            clock: widget.clock,
            thumbs: widget.thumbs,
          ),
        ),
      );
      if (path != null && mounted) widget.tray.add(HostPick(path: path, name: RemotePath.basename(path)));
    } finally {
      _browsing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final clearance = SheetScope.of(context).bottomClearance;
    // The find field is a Material text field; the sheet is not a Material.
    return Material(
      type: MaterialType.transparency,
      child: _supported ? _browser(clearance) : _unavailable(clearance),
    );
  }

  Widget _unavailable(double clearance) => SheetScroll(
    builder: (context, controller, physics) => CustomScrollView(
      controller: controller,
      physics: physics,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.only(bottom: clearance),
          // Top-aligned, not centred: at half height the lower part of the
          // tab is below the screen.
          sliver: const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: Gap.xl),
              child: EmptyState(
                icon: LucideIcons.serverOff,
                title: 'Files are unavailable on this machine',
                message: 'This machine has no file access (SFTP), so its folders cannot be listed here.',
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _browser(double clearance) {
    final ds = context.ds;
    return ListenableBuilder(
      listenable: _vm,
      builder: (context, _) {
        final vm = _vm;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.xs, Gap.gutter, Gap.xs),
              child: _FindField(
                controller: _search,
                focus: _focus,
                hint: 'Find in ${visibleText(vm.name)}',
                onChanged: vm.setQuery,
                onExpand: _expand,
              ),
            ),
            SizedBox(
              height: AppChip.height,
              child: ListenableBuilder(
                listenable: _options,
                builder: (context, _) => ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
                  children: [
                    AppChip(
                      label: 'Changed recently',
                      leading: Icon(LucideIcons.clock, size: 14, color: _options.recentOnly ? ds.text : ds.textSecondary),
                      selected: _options.recentOnly,
                      onTap: () => _options.setRecentOnly(!_options.recentOnly),
                    ),
                    const SizedBox(width: Gap.sm),
                    AppChip(
                      label: 'Browse all…',
                      leading: Icon(LucideIcons.folderTree, size: 14, color: ds.textSecondary),
                      onTap: () => unawaited(_browseAll()),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              height: AppChip.height,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
                child: FileBreadcrumbs(key: ObjectKey(vm), crumbs: vm.breadcrumbs, onTap: _goTo),
              ),
            ),
            Expanded(child: _list(vm, clearance)),
          ],
        );
      },
    );
  }

  Widget _list(FileBrowserViewModel vm, double clearance) {
    final failed = vm.error;
    final entries = vm.entries;
    final now = vm.now();
    final Widget state;
    if (vm.loading) {
      state = const SliverFillRemaining(child: DelayedSkeleton(rows: true));
    } else if (failed != null) {
      state = SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.sm, Gap.gutter, 0),
          child: _failure(vm, failed),
        ),
      );
    } else if (entries.isEmpty) {
      state = SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: Gap.xl),
          child: EmptyFolderState(vm: vm, pick: false, pullToRefresh: false, onClearSearch: _clearSearch),
        ),
      );
    } else {
      state = SliverList.builder(
        itemCount: entries.length,
        itemBuilder: (context, i) {
          final e = entries[i];
          return _HostRow(
            key: ValueKey(e.path),
            entry: e,
            files: vm.files,
            now: now,
            tray: widget.tray,
            denied: vm.isDenied(e),
            thumbs: widget.thumbs,
            onTap: () => _tap(vm, e),
            onToggle: () => _toggle(e),
          );
        },
      );
    }
    return SheetScroll(
      builder: (context, controller, physics) => CustomScrollView(
        controller: controller,
        physics: physics,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [SliverPadding(padding: EdgeInsets.only(bottom: clearance), sliver: state)],
      ),
    );
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
      name: visibleText(vm.name),
      onRetry: vm.load,
      alsoRetry: failed.kind == RemoteFileErrorKind.permission,
      action: up == null
          ? null
          : AppButton(label: up, kind: AppButtonKind.secondary, compact: true, onPressed: () => _goTo(parent!)),
    );
  }
}

/// A file or folder of the list. A file carries the circle with its place in
/// the tray; the row listens to the tray itself and rebuilds only when that
/// place changes.
class _HostRow extends StatefulWidget {
  const _HostRow({
    super.key,
    required this.entry,
    required this.files,
    required this.now,
    required this.tray,
    required this.denied,
    required this.thumbs,
    required this.onTap,
    required this.onToggle,
  });

  final RemoteEntry entry;
  final RemoteFiles files;
  final DateTime now;
  final AttachTray tray;
  final bool denied;
  final ThumbLoader? thumbs;
  final VoidCallback onTap;
  final VoidCallback onToggle;

  @override
  State<_HostRow> createState() => _HostRowState();
}

class _HostRowState extends State<_HostRow> {
  late int? _number = _read();

  String get _key => 'h:${widget.entry.path}';

  int? _read() => widget.tray.numberOf(_key);

  @override
  void initState() {
    super.initState();
    widget.tray.addListener(_onTray);
  }

  @override
  void didUpdateWidget(_HostRow old) {
    super.didUpdateWidget(old);
    if (old.tray != widget.tray) {
      old.tray.removeListener(_onTray);
      widget.tray.addListener(_onTray);
    }
    _number = _read();
  }

  @override
  void dispose() {
    widget.tray.removeListener(_onTray);
    super.dispose();
  }

  void _onTray() {
    final now = _read();
    if (now != _number) setState(() => _number = now);
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    // Only a readable file is picked: a folder opens, an unreadable file is
    // refused when tapped.
    final pickable = e.isFile && !widget.denied;
    final name = visibleText(e.name);
    return FileRow(
      entry: e,
      files: widget.files,
      now: widget.now,
      denied: widget.denied,
      thumbs: widget.thumbs,
      selected: pickable ? _number != null : null,
      trailing: pickable
          // The circle's 44 dp hit box reaches 10 dp past the row's content
          // edge, so the ring lines up with the chevrons of the folder rows
          // (the row itself is the rest of the touch target).
          ? SizedBox(
              width: kMinTap - 10,
              height: kMinTap,
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: kMinTap,
                maxWidth: kMinTap,
                child: SelectionCircle(
                  number: _number,
                  onTap: widget.onToggle,
                  label: _number == null ? 'Select $name' : 'Deselect $name',
                ),
              ),
            )
          : null,
      onTap: widget.onTap,
    );
  }
}

/// The find field: 44 dp, the folder's name in the hint, a clear button. It
/// asks the sheet for its full height as soon as a finger lands on it, so the
/// keyboard has room by the time it opens.
class _FindField extends StatelessWidget {
  const _FindField({
    required this.controller,
    required this.focus,
    required this.hint,
    required this.onChanged,
    required this.onExpand,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final String hint;
  final ValueChanged<String> onChanged;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Semantics(
      label: 'Find in this folder',
      textField: true,
      child: Listener(
        onPointerDown: (_) => onExpand(),
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => TextField(
            controller: controller,
            focusNode: focus,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.search,
            onChanged: onChanged,
            onTapOutside: (_) => focus.unfocus(),
            style: Type.body.copyWith(fontSize: 15, color: ds.text),
            cursorColor: ds.accent,
            textAlignVertical: TextAlignVertical.center,
            decoration: InputDecoration(
              hintText: hint,
              constraints: const BoxConstraints(minHeight: kMinTap, maxHeight: kMinTap),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              prefixIcon: Icon(LucideIcons.search, size: 16, color: ds.textTertiary),
              suffixIcon: controller.text.isEmpty
                  ? null
                  : PressBuilder(
                      onTap: () {
                        controller.clear();
                        onChanged('');
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
    );
  }
}
