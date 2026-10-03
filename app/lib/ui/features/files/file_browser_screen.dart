import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/theme.dart';
import '../../core/tokens.dart';
import 'file_browser_view_model.dart';
import 'file_format.dart';
import 'file_viewer_screen.dart';
import 'file_widgets.dart';

/// Whether the browser opens files or picks a folder.
enum FileBrowserMode { browse, pickDirectory }

/// One directory of a machine. Tapping a folder pushes another browser (so the
/// system back gesture walks back up); tapping a file opens the viewer.
///
/// In [FileBrowserMode.pickDirectory] only folders are listed and a bottom bar
/// returns the folder being looked at: the route (and every browser pushed on
/// top of it) pops with that path.
class FileBrowserScreen extends StatelessWidget {
  const FileBrowserScreen({
    super.key,
    required this.machine,
    required this.path,
    this.mode = FileBrowserMode.browse,
  });

  final MachineConnection machine;
  final String path;
  final FileBrowserMode mode;

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider(
        create: (_) => FileBrowserViewModel(
          files: machine.files,
          path: path,
          directoriesOnly: mode == FileBrowserMode.pickDirectory,
        )..load(),
        child: _BrowserView(machine: machine, mode: mode),
      );
}

class _BrowserView extends StatelessWidget {
  const _BrowserView({required this.machine, required this.mode});

  final MachineConnection machine;
  final FileBrowserMode mode;

  bool get _pick => mode == FileBrowserMode.pickDirectory;

  Future<void> _openDirectory(BuildContext context, String path) async {
    final navigator = Navigator.of(context);
    if (_pick) {
      final chosen = await navigator.push<String>(MaterialPageRoute<String>(
        builder: (_) => FileBrowserScreen(machine: machine, path: path, mode: mode),
      ));
      if (chosen != null && navigator.mounted) navigator.pop(chosen);
      return;
    }
    await navigator.push(MaterialPageRoute<void>(
      builder: (_) => FileBrowserScreen(machine: machine, path: path),
    ));
  }

  void _open(BuildContext context, RemoteEntry e) {
    tapFeedback();
    if (e.isDirectory) {
      _openDirectory(context, e.path);
    } else if (e.isFile) {
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => FileViewerScreen(
          machine: machine,
          stat: RemoteStat(
            path: e.path,
            kind: RemoteEntryKind.file,
            size: e.size,
            modified: e.modified,
            mode: e.mode,
          ),
        ),
      ));
    } else {
      showToast(
        context,
        e.isBrokenLink ? '${e.name} points to something that no longer exists.' : "${e.name} can't be opened.",
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final vm = context.watch<FileBrowserViewModel>();
    final entries = vm.entries;
    final inset = MediaQuery.paddingOf(context).bottom;
    final failed = vm.error;
    final now = DateTime.now();

    final count = vm.loading ? '' : _countLine(vm);
    final list = AppRefresh(
      onRefresh: vm.load,
      edgeOffset: SliverLargeTitle.extent(context, hasSubtitle: true, bottomHeight: AppChip.height),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
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
              CircleButton(
                icon: vm.showHidden ? LucideIcons.eye : LucideIcons.eyeOff,
                tooltip: vm.showHidden ? 'Hide hidden files' : 'Show hidden files',
                active: vm.showHidden,
                onPressed: () => vm.setShowHidden(!vm.showHidden),
              ),
            ],
            bottom: _Breadcrumbs(
              crumbs: vm.breadcrumbs,
              onTap: (path) => _openDirectory(context, path),
            ),
            bottomHeight: AppChip.height,
          ),
          if (vm.loading)
            const SliverFillRemaining(child: FileSkeleton(rows: true))
          else if (failed != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.sm, Gap.gutter, 0),
                child: FileErrorPanel(
                  error: failed,
                  name: vm.name,
                  onRetry: vm.load,
                  action: failed.kind == RemoteFileErrorKind.notFound && vm.parentPath != null
                      ? AppButton(
                          label: 'Go up',
                          kind: AppButtonKind.secondary,
                          compact: true,
                          onPressed: () => _openDirectory(context, vm.parentPath!),
                        )
                      : null,
                ),
              ),
            )
          else if (entries.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyFolder(vm: vm, pick: _pick),
            )
          else
            SliverList.builder(
              itemCount: entries.length,
              itemBuilder: (context, i) => _EntryRow(
                entry: entries[i],
                now: now,
                onTap: () => _open(context, entries[i]),
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

  String _countLine(FileBrowserViewModel vm) {
    final shown = vm.entries.length;
    final noun = _pick ? (shown == 1 ? 'folder' : 'folders') : (shown == 1 ? 'item' : 'items');
    final hidden = vm.hiddenCount;
    if (vm.error != null) return vm.path;
    return hidden > 0 ? '${groupDigits(shown)} $noun · $hidden hidden' : '${groupDigits(shown)} $noun';
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry, required this.now, required this.onTap});

  final RemoteEntry entry;
  final DateTime now;
  final VoidCallback onTap;

  String get _subtitle {
    final e = entry;
    final when = formatModified(e.modified, now: now);
    if (e.kind == RemoteEntryKind.link) {
      final to = e.linkTarget == null ? '' : ' → ${e.linkTarget}';
      return e.isBrokenLink ? 'Broken link$to' : 'Link$to';
    }
    if (e.isDirectory) return when;
    final size = formatBytes(e.size);
    return when.isEmpty ? size : '$size · $when';
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final e = entry;
    return ListRow(
      leading: IconTile(icon: iconForEntry(e), color: e.isDirectory ? ds.accentText : null),
      leadingOnTitle: false,
      title: e.name,
      titleMaxLines: 1,
      subtitle: _subtitle,
      trailing: e.isDirectory ? Icon(LucideIcons.chevronRight, size: 18, color: ds.textTertiary) : null,
      onTap: onTap,
    );
  }
}

class _EmptyFolder extends StatelessWidget {
  const _EmptyFolder({required this.vm, required this.pick});

  final FileBrowserViewModel vm;
  final bool pick;

  @override
  Widget build(BuildContext context) {
    final onlyHidden = vm.totalCount > 0 && vm.hiddenCount > 0;
    final onlyFiles = pick && vm.totalCount == 0;
    return EmptyState(
      icon: LucideIcons.folderOpen,
      title: onlyHidden ? 'Only hidden files' : (onlyFiles ? 'No folders here' : 'Empty folder'),
      message: onlyHidden
          ? '${vm.name} has ${vm.hiddenCount} hidden ${vm.hiddenCount == 1 ? 'item' : 'items'}.'
          : (onlyFiles ? 'Choose this folder, or go back.' : 'There is nothing in ${vm.name}.'),
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
class _Breadcrumbs extends StatefulWidget {
  const _Breadcrumbs({required this.crumbs, required this.onTap});

  final List<({String path, String label})> crumbs;
  final ValueChanged<String> onTap;

  @override
  State<_Breadcrumbs> createState() => _BreadcrumbsState();
}

class _BreadcrumbsState extends State<_Breadcrumbs> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _toEnd();
  }

  @override
  void didUpdateWidget(_Breadcrumbs old) {
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
