import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/services/photo_export.dart';
import '../../../data/services/remote_file_staging.dart';

import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:video_player/video_player.dart' show VideoPlayerController;

import '../web/web_preview_screen.dart';
import 'binary_view.dart';
import 'code_view.dart';
import '../../../data/words/elapsed.dart';
import 'file_copy_model.dart';
import 'file_format.dart';
import 'file_kind.dart';
import 'file_viewer_view_model.dart';
import 'file_widgets.dart';
import 'photo_files.dart';
import 'markdown_view.dart';
import 'text_document.dart';
import 'video_view.dart';

/// The platform clipboard hands text to other apps through a size-limited
/// channel; past this it can fail outright, so a long copy is cut short.
const _clipboardLimit = 900 * 1024;

/// One remote file: text and code (numbered, selectable), Markdown, JSON,
/// and an info card for everything else. A picture is not shown here: the
/// photo viewer (`photoRoute`) opens it, and a file that only turns out to be
/// one once its bytes are read replaces this screen with that viewer.
///
/// [line] is highlighted and scrolled into view (a `file:line` link). [asText]
/// shows the file as text whatever its name and bytes say.
class FileViewerScreen extends StatelessWidget {
  const FileViewerScreen({
    super.key,
    required this.machine,
    required this.stat,
    this.line,
    this.asText = false,
    this.export,
    this.staging,
    this.videoPlayer,
  });

  final MachineConnection machine;
  final RemoteStat stat;
  final int? line;
  final bool asText;

  /// What sharing and saving go through, and where the copy to the phone is
  /// kept; the phone's own unless a test hands in others.
  final PhotoExport? export;
  final RemoteFileStaging? staging;

  /// Makes the player of a video; the phone's own unless a test hands one in.
  final VideoControllerFor? videoPlayer;

  @override
  Widget build(BuildContext context) => MultiProvider(
    providers: [
      Provider<_ViewerMachine>.value(value: _ViewerMachine(machine)),
      Provider<VideoControllerFor>.value(value: videoPlayer ?? VideoPlayerController.file),
      ChangeNotifierProvider(
        create: (_) => FileCopyModel(
          files: machine.files,
          staging: staging ?? RemoteFileStaging(),
          export: export ?? const DevicePhotoExport(),
        ),
      ),
      ChangeNotifierProvider(
        create: (_) => FileViewerViewModel(files: machine.files, stat: stat, line: line, forceText: asText)..load(),
      ),
    ],
    child: const _ViewerPage(),
  );
}

/// The machine the file lives on, for what a path tapped inside rendered
/// Markdown opens. A plain holder: the connection is a `Listenable`, which
/// `Provider` refuses to hand out as a value.
class _ViewerMachine {
  const _ViewerMachine(this.machine);

  final MachineConnection machine;
}

class _ViewerPage extends StatefulWidget {
  const _ViewerPage();

  @override
  State<_ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<_ViewerPage> {
  var _openedPhoto = false;
  final _disk = _DiskWatch();

  /// A file the name did not call a picture but whose bytes are one: the photo
  /// viewer takes its place (once).
  void _handOverPicture(FileViewerViewModel vm) {
    if (_openedPhoto || vm.phase != ViewerPhase.ready || vm.kind != FileKind.image) return;
    _openedPhoto = true;
    final machine = context.read<_ViewerMachine>().machine;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(photoRoute(machine, vm.stat, listSiblings: false));
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disk.attach(context, context.read<FileViewerViewModel>());
  }

  @override
  void dispose() {
    _disk.dispose();
    super.dispose();
  }

  Future<void> _copyContents(FileViewerViewModel vm) async {
    final copied = await vm.textForCopy();
    if (copied == null || !mounted) return;
    var text = copied.text;
    var complete = copied.complete;
    if (text.length > _clipboardLimit) {
      text = text.substring(0, _clipboardLimit);
      complete = false;
    }
    copyText(
      context,
      text,
      what: 'Contents copied',
      caveat: complete ? null : 'Only the first ${formatBytes(text.length)} was copied',
    );
  }

  /// Sharing or saving the file as it is: copied to the phone first, then
  /// handed to the share sheet (which lists the apps and folders that keep it).
  Future<void> _share(FileViewerViewModel vm) async {
    final result = await context.read<FileCopyModel>().share(vm.stat);
    if (result.problem case final problem? when mounted) showToast(context, problem, kind: ToastKind.failed);
  }

  Future<void> _saveVideo(FileViewerViewModel vm) async {
    final result = await context.read<FileCopyModel>().saveVideo(vm.stat);
    if (!mounted) return;
    if (result.problem case final problem?) {
      showToast(context, problem, kind: ToastKind.failed);
    } else if (result.done) {
      showToast(context, 'Saved to Pictures/herdr', kind: ToastKind.success);
    }
  }

  /// Copying the file, out of the bar (it holds two actions at most).
  void _showOptions(FileViewerViewModel vm, bool ready) {
    final stat = vm.stat;
    unawaited(
      showActionSheet(
        context,
        title: stat.name,
        actions: [
          if (ready && vm.isText && vm.document != null && !vm.document!.isEmpty)
            SheetAction(label: 'Copy contents', icon: LucideIcons.clipboardCopy, onTap: () => _copyContents(vm)),
          if (ready && vm.kind == FileKind.video && typeForName(vm.name).kind == FileKind.video)
            SheetAction(label: 'Save to gallery', icon: LucideIcons.download, onTap: () => unawaited(_saveVideo(vm))),
          if (stat.isFile && stat.size != null)
            SheetAction(label: 'Share or save\u2026', icon: LucideIcons.share2, onTap: () => unawaited(_share(vm))),
          SheetAction(
            label: 'Copy path',
            icon: LucideIcons.link,
            onTap: () => copyText(context, stat.path, what: 'Path copied'),
          ),
        ],
      ),
    );
  }

  Future<void> _togglePretty(FileViewerViewModel vm) async {
    final problem = await vm.setPretty(!vm.pretty);
    if (problem != null && mounted) showToast(context, problem, kind: ToastKind.failed);
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final vm = context.watch<FileViewerViewModel>();
    final stat = vm.stat;
    final ready = vm.phase == ViewerPhase.ready;
    _handOverPicture(vm);
    return Scaffold(
      backgroundColor: ds.bg,
      body: Column(
        children: [
          AppTopBar(
            title: stat.name,
            subtitleLine: _TailText(_folderOf(stat.path)),
            actions: [
              if (ready && canShowAsPage(stat.name))
                CircleButton(
                  icon: LucideIcons.globe,
                  tooltip: 'Show as page',
                  onPressed: () => unawaited(_showAsPage(context, stat)),
                ),
              CircleButton(
                icon: LucideIcons.ellipsis,
                tooltip: 'File options',
                onPressed: () => _showOptions(vm, ready),
              ),
            ],
          ),
          _Tools(vm: vm, onTogglePretty: () => _togglePretty(vm)),
          if (ready && vm.refreshError != null) _RefreshStrip(vm: vm),
          Expanded(
            child: Stack(
              children: [
                _Body(vm: vm, onShare: () => unawaited(_share(vm)), onSave: () => unawaited(_saveVideo(vm))),
                Align(
                  alignment: Alignment.topCenter,
                  child: _ChangedSlot(vm: vm),
                ),
                Align(
                  alignment: Alignment.topCenter,
                  child: _CopySlot(vm: vm),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The folder [path] sits in, ending in `/`: the bar's second line.
String _folderOf(String path) {
  final parent = RemotePath.parent(path);
  return parent == '/' ? '/' : '$parent/';
}

/// A path on one line, ellipsized at the START: the folder a file sits in is
/// the informative part of a long path, so `…/payments-api/services/ledger/`
/// beats `/Users/maya/code/payments-api/serv…`.
class _TailText extends StatelessWidget {
  const _TailText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final style = Mono.small.copyWith(color: ds.textMuted);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, box) => Text(
        shortenFront(text, box.maxWidth, style, scaler),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        textDirection: TextDirection.ltr,
        style: style,
      ),
    );
  }
}

/// [text] with its beginning replaced by `…` just enough to fit [maxWidth].
/// Cuts at a path separator when one is close, so no folder name is torn.
/// Shared with the agent session's `path:line` rows.
String shortenFront(String text, double maxWidth, TextStyle style, TextScaler scaler) {
  double width(String s) => (TextPainter(
    text: TextSpan(text: s, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
  )..layout()).width;
  if (!maxWidth.isFinite || width(text) <= maxWidth) return text;
  // Smallest cut that fits: binary search over the number of dropped characters.
  var lo = 1, hi = text.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (width('…${text.substring(mid)}') <= maxWidth) {
      hi = mid;
    } else {
      lo = mid + 1;
    }
  }
  var cut = lo;
  final slash = text.indexOf('/', cut);
  // Prefer a clean break at the next separator if it costs little.
  if (slash != -1 && slash - cut < 12 && slash < text.length - 1) cut = slash;
  return '…${text.substring(cut)}';
}

/// Toggles for the current kind on the left, size and age on the right.
class _Tools extends StatelessWidget {
  const _Tools({required this.vm, required this.onTogglePretty});

  final FileViewerViewModel vm;
  final VoidCallback onTogglePretty;

  /// The info card says all of this itself.
  bool get _redundant =>
      vm.phase == ViewerPhase.ready &&
      (vm.kind == FileKind.binary || vm.kind == FileKind.svg || vm.kind == FileKind.pdf || vm.kind == FileKind.video);

  String get _meta {
    final s = vm.stat;
    final parts = <String>[];
    parts.add(formatBytes(s.size));
    final when = s.modified == null ? '' : formatAgo(s.modified!, DateTime.now());
    if (when.isNotEmpty) parts.add(when);
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final chips = <Widget>[];
    if (vm.phase == ViewerPhase.ready) {
      Widget wrap() =>
          AppChip(label: 'Wrap', icon: LucideIcons.wrapText, selected: vm.wrap, onTap: () => vm.setWrap(!vm.wrap));
      switch (vm.kind) {
        case FileKind.text:
          if (vm.document != null && !vm.document!.isEmpty) chips.add(wrap());
        case FileKind.json:
          chips.add(AppChip(label: 'Pretty', icon: LucideIcons.braces, selected: vm.pretty, onTap: onTogglePretty));
          chips.add(wrap());
        case FileKind.markdown:
          chips.add(
            Segmented<bool>(
              options: const [SegmentOption(false, 'Rendered'), SegmentOption(true, 'Source')],
              value: vm.showSource,
              onChanged: vm.setShowSource,
            ),
          );
          if (vm.showSource) chips.add(wrap());
        case FileKind.image || FileKind.svg || FileKind.pdf || FileKind.binary || FileKind.video:
          break;
      }
    }
    if (_redundant) return const SizedBox(height: Gap.xs);
    // A bar of fixed-height pills: text scale is clamped like the header's.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      child: SizedBox(
        height: AppChip.height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
          child: Row(
            children: [
              for (final (i, c) in chips.indexed) ...[if (i > 0) const SizedBox(width: Gap.sm), c],
              Expanded(
                child: Padding(
                  padding: chips.isEmpty ? EdgeInsets.zero : const EdgeInsets.only(left: Gap.md),
                  child: Text(
                    _meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: chips.isEmpty ? TextAlign.left : TextAlign.right,
                    style: Type.caption.copyWith(color: ds.textMuted),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.vm, required this.onShare, required this.onSave});

  final FileViewerViewModel vm;

  /// Share or save the file (copied to the phone first), and save a video to
  /// the gallery: the screen runs both, it owns the toasts.
  final VoidCallback onShare;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    switch (vm.phase) {
      case ViewerPhase.loading:
        return const Skeleton();
      case ViewerPhase.failed:
        return ListView(
          padding: EdgeInsets.fromLTRB(Gap.gutter, Gap.md, Gap.gutter, Gap.xl + MediaQuery.paddingOf(context).bottom),
          children: [
            FileErrorPanel(error: vm.error!, name: vm.name, onRetry: vm.retry),
            const SizedBox(height: Gap.lg),
            Align(
              alignment: Alignment.centerLeft,
              child: AppButton(
                label: 'Copy path',
                icon: LucideIcons.copy,
                kind: AppButtonKind.secondary,
                onPressed: () => copyText(context, vm.stat.path, what: 'Path copied'),
              ),
            ),
          ],
        );
      case ViewerPhase.ready:
        return switch (vm.kind) {
          FileKind.text || FileKind.json => _TextBody(vm: vm, doc: vm.document!),
          FileKind.markdown => _TextBody(vm: vm, doc: vm.document!, rendered: !vm.showSource),
          // Handed to the photo viewer in the same frame (see _handOverPicture).
          FileKind.image => const Skeleton(),
          FileKind.video => VideoView(
            key: ValueKey('${vm.stat.path}:${vm.stat.size}:${vm.stat.modified}'),
            stat: vm.stat,
            type: vm.type,
            onShare: onShare,
            onSave: onSave,
            controllerFor: context.read<VideoControllerFor>(),
            canSave: typeForName(vm.name).kind == FileKind.video,
          ),
          FileKind.svg || FileKind.pdf || FileKind.binary => BinaryView(
            model: vm,
            onCopyPath: () => copyText(context, vm.stat.path, what: 'Path copied'),
            onShare: onShare,
            onViewAsText: vm.canViewAsText ? vm.viewAsText : null,
            onShowAsPage: canShowAsPage(vm.name) ? () => unawaited(_showAsPage(context, vm.stat)) : null,
          ),
        };
    }
  }
}

/// Shows [stat] (an HTML or SVG file) as a page in herdr, served from its own
/// folder on the machine ([WebPreviewScreen]: it says there if that fails).
Future<void> _showAsPage(BuildContext context, RemoteStat stat) =>
    openWebPreview(context, context.read<_ViewerMachine>().machine, FilePage.stat(stat));

class _TextBody extends StatelessWidget {
  const _TextBody({required this.vm, required this.doc, this.rendered = false});

  final FileViewerViewModel vm;
  final TextDocument doc;

  /// Markdown drawn as formatted text rather than source.
  final bool rendered;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    if (doc.isEmpty) {
      return EmptyState(icon: LucideIcons.fileText, title: 'Empty file', message: '${vm.name} has no content.');
    }
    final footer = vm.hasMore || vm.loadingMore || vm.truncatedAtLimit || vm.loadMoreError != null;
    final size = vm.stat.size;
    final loaded = formatBytes(doc.bytes);
    final of = size == null || size == 0 ? '' : ' of ${formatBytes(size)}';
    final body = rendered
        ? MarkdownView(
            document: doc,
            directory: RemotePath.parent(vm.stat.path),
            machine: context.read<_ViewerMachine>().machine,
          )
        : CodeView(document: doc, wrap: vm.wrap, highlightLine: vm.highlightLine);
    return Column(
      children: [
        Expanded(
          // Pulling the text down reads the file again (a list inside the
          // sideways scroller sits one level deeper, so any vertical scroll
          // counts).
          child: AppRefresh(
            onRefresh: vm.refresh,
            edgeOffset: 0,
            notificationPredicate: (n) => n.metrics.axis == Axis.vertical,
            child: footer ? MediaQuery.removePadding(context: context, removeBottom: true, child: body) : body,
          ),
        ),
        if (footer)
          DecoratedBox(
            decoration: BoxDecoration(
              color: ds.bg,
              border: Border(
                top: BorderSide(color: ds.hairline, width: 1 / MediaQuery.devicePixelRatioOf(context)),
              ),
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(Gap.gutter, Gap.sm, Gap.md, Gap.sm + MediaQuery.paddingOf(context).bottom),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      vm.loadMoreError != null
                          ? 'Couldn’t load more: ${vm.loadMoreError!.message}'
                          : vm.truncatedAtLimit
                          ? 'Showing the first $loaded$of. That is as much as the viewer opens.'
                          : 'Showing $loaded$of',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Type.caption.copyWith(color: vm.loadMoreError != null ? ds.dangerText : ds.textMuted),
                    ),
                  ),
                  if (vm.hasMore || vm.loadMoreError != null)
                    AppButton(
                      label: vm.loadMoreError != null ? 'Retry' : 'Load more',
                      kind: AppButtonKind.secondary,
                      compact: true,
                      loading: vm.loadingMore,
                      onPressed: vm.loadMore,
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Notices the file changing on the host while its viewer is the screen in
/// front: ONE stat (no body is read) when the viewer comes back to the front
/// or the app resumes, and then every [every] while it stays there. Nothing
/// runs while another screen covers the viewer, while the app is in the
/// background, or after the viewer is gone (the timer is cancelled).
class _DiskWatch {
  static const every = Dwell.diskWatch;

  Timer? _timer;
  ValueListenable<TickerModeData>? _front;
  AppLifecycleListener? _life;
  FileViewerViewModel? _vm;
  var _resumed = true;
  var _started = false;

  void attach(BuildContext context, FileViewerViewModel vm) {
    _vm = vm;
    final front = TickerMode.getValuesNotifier(context);
    if (!identical(front, _front)) {
      _front?.removeListener(_sync);
      _front = front..addListener(_sync);
    }
    if (_life == null) {
      final state = WidgetsBinding.instance.lifecycleState;
      _resumed = state == null || state == AppLifecycleState.resumed;
      _life = AppLifecycleListener(
        onStateChange: (s) {
          _resumed = s == AppLifecycleState.resumed;
          _sync();
        },
      );
    }
    _sync();
  }

  void _sync() {
    final vm = _vm;
    final active = vm != null && _resumed && (_front?.value.enabled ?? true);
    if (!active) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    if (_timer != null) return;
    // Back in front or resumed: look once now (the first start comes right
    // after the file was read, so there is nothing to look for yet).
    if (_started) unawaited(vm.checkForChange());
    _started = true;
    _timer = Timer.periodic(every, (_) => unawaited(vm.checkForChange()));
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _front?.removeListener(_sync);
    _life?.dispose();
  }
}

/// "Changed on disk · Reload": a [FloatingPill] over the top of the text,
/// coming in with a fade and a small scale. A tap reads the file again where
/// the reader is.
class _ChangedSlot extends StatelessWidget {
  const _ChangedSlot({required this.vm});

  final FileViewerViewModel vm;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final busy = vm.refreshing;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xs),
      child: FloatingPill(
        visible: vm.phase == ViewerPhase.ready && vm.changedOnDisk,
        size: FloatingPillSize.compact,
        leading: busy ? const BusySpinner() : Icon(LucideIcons.refreshCw, size: IconSize.inline, color: ds.accentText),
        label: 'Changed on disk',
        trailing: Text(busy ? 'Reloading' : 'Reload', style: Type.labelStrong.copyWith(color: ds.accentText)),
        onTap: busy ? null : () => unawaited(vm.refresh()),
      ),
    );
  }
}

/// "Copying 12 MB of 80 MB · Cancel": a file being copied to the phone to be
/// shared, over the top of what is shown. A video shows its own progress in
/// place of the player, so it has none here.
class _CopySlot extends StatelessWidget {
  const _CopySlot({required this.vm});

  final FileViewerViewModel vm;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final copy = context.watch<FileCopyModel>();
    final own = vm.kind == FileKind.video && vm.phase == ViewerPhase.ready;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xs),
      child: FloatingPill(
        visible: copy.running && !own,
        size: FloatingPillSize.compact,
        leading: const BusySpinner(size: IconSize.inline),
        label: copy.total > 0
            ? 'Copying ${formatBytes(copy.written)} of ${formatBytes(copy.total)}'
            : 'Copying ${formatBytes(copy.written)}',
        trailing: Text('Cancel', style: Type.labelStrong.copyWith(color: ds.accentText)),
        onTap: copy.cancel,
      ),
    );
  }
}

/// A refresh failed: the old text stays and this says so, with a Retry.
class _RefreshStrip extends StatelessWidget {
  const _RefreshStrip({required this.vm});

  final FileViewerViewModel vm;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Padding(
      padding: const EdgeInsets.only(left: Gap.gutter, right: Gap.gutter, bottom: Gap.sm),
      child: StatusStrip(
        color: ds.danger,
        title: 'Couldn’t refresh',
        detail: 'Showing the earlier version',
        leading: Icon(LucideIcons.circleAlert, size: IconSize.row, color: ds.dangerText),
        action: AppButton(
          label: 'Retry',
          kind: AppButtonKind.secondary,
          compact: true,
          loading: vm.refreshing,
          onPressed: vm.refresh,
        ),
      ),
    );
  }
}
