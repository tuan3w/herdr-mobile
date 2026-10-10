import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/status_panel.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import 'binary_view.dart';
import 'code_view.dart';
import 'file_format.dart';
import 'file_kind.dart';
import 'file_viewer_view_model.dart';
import 'file_widgets.dart';
import 'photo_files.dart';
import 'markdown_view.dart';
import 'text_document.dart';

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
  const FileViewerScreen({super.key, required this.machine, required this.stat, this.line, this.asText = false});

  final MachineConnection machine;
  final RemoteStat stat;
  final int? line;
  final bool asText;

  @override
  Widget build(BuildContext context) => Provider<_ViewerMachine>.value(
        value: _ViewerMachine(machine),
        child: ChangeNotifierProvider(
          create: (_) => FileViewerViewModel(files: machine.files, stat: stat, line: line, forceText: asText)..load(),
          child: const _ViewerPage(),
        ),
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
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } on PlatformException {
      if (mounted) showToast(context, "Couldn't copy: the clipboard refused it.", kind: ToastKind.failed);
      return;
    }
    if (!mounted) return;
    Haptics.tick();
    showToast(context, complete ? 'Contents copied' : 'Copied the first ${formatBytes(text.length)} only');
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
          _Header(
            name: stat.name,
            path: stat.path,
            actions: [
              if (ready && vm.isText && vm.document != null && !vm.document!.isEmpty)
                CircleButton(
                  icon: LucideIcons.clipboardCopy,
                  tooltip: 'Copy contents',
                  onPressed: () => _copyContents(vm),
                ),
              CircleButton(
                icon: LucideIcons.link,
                tooltip: 'Copy path',
                onPressed: () => copyToClipboard(context, stat.path, 'Path copied'),
              ),
            ],
          ),
          _Tools(vm: vm, onTogglePretty: () => _togglePretty(vm)),
          if (ready && vm.refreshError != null) _RefreshStrip(vm: vm),
          Expanded(
            child: Stack(
              children: [
                _Body(vm: vm),
                Align(
                  alignment: Alignment.topCenter,
                  child: _ChangedSlot(vm: vm),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Back, the file name, and its folder (scrollable, showing the end first).
class _Header extends StatelessWidget {
  const _Header({required this.name, required this.path, required this.actions});

  final String name;
  final String path;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final parent = RemotePath.parent(path);
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: kBarTextScale,
      child: Container(
        color: ds.bg,
        padding: EdgeInsets.fromLTRB(Gap.gutter - 6, MediaQuery.paddingOf(context).top, Gap.gutter - 6, 0),
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              CircleButton(
                icon: LucideIcons.chevronLeft,
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Type.barTitle.copyWith(color: ds.text),
                      ),
                    ),
                    _TailText(parent == '/' ? '/' : '$parent/'),
                  ],
                ),
              ),
              for (final a in actions) ...[const SizedBox(width: 4), a],
            ],
          ),
        ),
      ),
    );
  }
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
    final style = codeStyle(ds, size: 11.5, color: ds.textMuted).copyWith(height: 1.3);
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
      )..layout())
      .width;
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
      (vm.kind == FileKind.binary || vm.kind == FileKind.svg || vm.kind == FileKind.pdf);

  String get _meta {
    final s = vm.stat;
    final parts = <String>[];
    parts.add(formatBytes(s.size));
    final when = formatModified(s.modified);
    if (when.isNotEmpty) parts.add(when);
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final chips = <Widget>[];
    if (vm.phase == ViewerPhase.ready) {
      Widget wrap() => AppChip(
            label: 'Wrap',
            leading: Icon(LucideIcons.wrapText, size: 14, color: vm.wrap ? ds.text : ds.textSecondary),
            selected: vm.wrap,
            onTap: () => vm.setWrap(!vm.wrap),
          );
      switch (vm.kind) {
        case FileKind.text:
          if (vm.document != null && !vm.document!.isEmpty) chips.add(wrap());
        case FileKind.json:
          chips.add(AppChip(
            label: 'Pretty',
            leading: Icon(LucideIcons.braces, size: 14, color: vm.pretty ? ds.text : ds.textSecondary),
            selected: vm.pretty,
            onTap: onTogglePretty,
          ));
          chips.add(wrap());
        case FileKind.markdown:
          chips.add(AppChip(label: 'Rendered', selected: !vm.showSource, onTap: () => vm.setShowSource(false)));
          chips.add(AppChip(label: 'Source', selected: vm.showSource, onTap: () => vm.setShowSource(true)));
          if (vm.showSource) chips.add(wrap());
        case FileKind.image || FileKind.svg || FileKind.pdf || FileKind.binary:
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
                  padding: EdgeInsets.only(left: chips.isEmpty ? 0 : Gap.md),
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
  const _Body({required this.vm});

  final FileViewerViewModel vm;

  @override
  Widget build(BuildContext context) {
    switch (vm.phase) {
      case ViewerPhase.loading:
        return const FileSkeleton();
      case ViewerPhase.failed:
        return ListView(
          padding: EdgeInsets.fromLTRB(
            Gap.gutter,
            Gap.md,
            Gap.gutter,
            Gap.xl + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            FileErrorPanel(error: vm.error!, name: vm.name, onRetry: vm.retry),
            const SizedBox(height: Gap.lg),
            Align(
              alignment: Alignment.centerLeft,
              child: AppButton(
                label: 'Copy path',
                icon: LucideIcons.copy,
                kind: AppButtonKind.secondary,
                onPressed: () => copyToClipboard(context, vm.stat.path, 'Path copied'),
              ),
            ),
          ],
        );
      case ViewerPhase.ready:
        return switch (vm.kind) {
          FileKind.text || FileKind.json => _TextBody(vm: vm, doc: vm.document!),
          FileKind.markdown => _TextBody(vm: vm, doc: vm.document!, rendered: !vm.showSource),
          // Handed to the photo viewer in the same frame (see _handOverPicture).
          FileKind.image => const FileSkeleton(),
          FileKind.svg || FileKind.pdf || FileKind.binary => BinaryView(
              model: vm,
              onCopyPath: () => copyToClipboard(context, vm.stat.path, 'Path copied'),
              onViewAsText: vm.canViewAsText ? vm.viewAsText : null,
            ),
        };
    }
  }
}

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
      return EmptyState(
        icon: LucideIcons.fileText,
        title: 'Empty file',
        message: '${vm.name} has no content.',
      );
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
              border: Border(top: BorderSide(color: ds.hairline, width: 1 / MediaQuery.devicePixelRatioOf(context))),
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                Gap.gutter,
                Gap.sm,
                Gap.sm + 4,
                Gap.sm + MediaQuery.paddingOf(context).bottom,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      vm.loadMoreError != null
                          ? "Couldn't load more: ${vm.loadMoreError!.message}"
                          : vm.truncatedAtLimit
                              ? 'Showing the first $loaded$of. That is as much as the viewer opens.'
                              : 'Showing $loaded$of',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Type.caption.copyWith(
                        color: vm.loadMoreError != null ? ds.dangerText : ds.textMuted,
                      ),
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
  static const every = Duration(seconds: 15);

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

/// Where [_ChangedPill] appears and goes: a short slide and fade from under
/// the tools bar.
class _ChangedSlot extends StatelessWidget {
  const _ChangedSlot({required this.vm});

  final FileViewerViewModel vm;

  @override
  Widget build(BuildContext context) {
    final show = vm.phase == ViewerPhase.ready && vm.changedOnDisk;
    final reduced = Motion.reduced(context);
    return AnimatedSwitcher(
      duration: reduced ? Duration.zero : Motion.standard,
      switchInCurve: Motion.easeOut,
      switchOutCurve: Motion.easeOut,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: reduced
            ? child
            : SlideTransition(
                position: Tween(begin: const Offset(0, -0.5), end: Offset.zero).animate(animation),
                child: child,
              ),
      ),
      child: show ? _ChangedPill(key: const ValueKey('changed'), vm: vm) : const SizedBox.shrink(key: ValueKey('none')),
    );
  }
}

/// "Changed on disk · Reload": a quiet capsule over the top of the text. A tap
/// reads the file again where the reader is.
class _ChangedPill extends StatelessWidget {
  const _ChangedPill({super.key, required this.vm});

  final FileViewerViewModel vm;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final busy = vm.refreshing;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      child: Padding(
        padding: const EdgeInsets.only(top: Gap.xs),
        child: PressBuilder(
          onTap: busy ? null : () => unawaited(vm.refresh()),
          haptic: true,
          minTapSize: kMinTap,
          scale: 0.97,
          button: true,
          builder: (context, pressed) => AnimatedContainer(
            duration: Motion.pressing(pressed),
            curve: Motion.easeOut,
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: pressed ? ds.fillPressed : ds.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: ds.border, width: 1),
              // Floats over the text: the one float shadow lifts it off the lines.
              boxShadow: ds.floatShadow,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  const BusySpinner(size: 14)
                else
                  Icon(LucideIcons.refreshCw, size: 14, color: ds.accentText),
                const SizedBox(width: 8),
                Text('Changed on disk', style: Type.label.copyWith(color: ds.textSecondary)),
                const SizedBox(width: 6),
                Text(
                  busy ? 'Reloading' : 'Reload',
                  style: Type.label.copyWith(color: ds.accentText, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
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
      padding: const EdgeInsets.fromLTRB(Gap.gutter, 0, Gap.gutter, Gap.sm),
      child: StatusStrip(
        color: ds.danger,
        title: "Couldn't refresh",
        detail: 'Showing the earlier version',
        leading: Icon(LucideIcons.triangleAlert, size: 16, color: ds.dangerText),
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
