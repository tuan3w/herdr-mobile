import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../core/controls.dart';
import '../../core/rows.dart';
import '../../core/theme.dart';
import 'binary_view.dart';
import 'code_view.dart';
import 'file_format.dart';
import 'file_kind.dart';
import 'file_viewer_view_model.dart';
import 'file_widgets.dart';
import 'image_view.dart';
import 'markdown_view.dart';
import 'text_document.dart';

/// The platform clipboard hands text to other apps through a size-limited
/// channel; past this it can fail outright, so a long copy is cut short.
const _clipboardLimit = 900 * 1024;

/// One remote file: text and code (numbered, selectable), Markdown, JSON,
/// images (zoomable), and an info card for everything else.
///
/// [line] is highlighted and scrolled into view (a `file:line` link).
class FileViewerScreen extends StatelessWidget {
  const FileViewerScreen({super.key, required this.machine, required this.stat, this.line});

  final MachineConnection machine;
  final RemoteStat stat;
  final int? line;

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider(
        create: (_) => FileViewerViewModel(files: machine.files, stat: stat, line: line)..load(),
        child: const _ViewerPage(),
      );
}

class _ViewerPage extends StatefulWidget {
  const _ViewerPage();

  @override
  State<_ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<_ViewerPage> {
  var _actualSize = false;

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
      if (mounted) showToast(context, "Couldn't copy: the clipboard refused it.");
      return;
    }
    if (!mounted) return;
    HapticFeedback.selectionClick();
    showToast(context, complete ? 'Contents copied' : 'Copied the first ${formatBytes(text.length)} only');
  }

  Future<void> _togglePretty(FileViewerViewModel vm) async {
    final problem = await vm.setPretty(!vm.pretty);
    if (problem != null && mounted) showToast(context, problem);
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final vm = context.watch<FileViewerViewModel>();
    final stat = vm.stat;
    final ready = vm.phase == ViewerPhase.ready;
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
          _Tools(
            vm: vm,
            actualSize: _actualSize,
            onActualSize: (v) => setState(() => _actualSize = v),
            onTogglePretty: () => _togglePretty(vm),
          ),
          Expanded(child: _Body(vm: vm, actualSize: _actualSize)),
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
      maxScaleFactor: 1.15,
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
@visibleForTesting
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
  const _Tools({
    required this.vm,
    required this.actualSize,
    required this.onActualSize,
    required this.onTogglePretty,
  });

  final FileViewerViewModel vm;
  final bool actualSize;
  final ValueChanged<bool> onActualSize;
  final VoidCallback onTogglePretty;

  /// The info card says all of this itself.
  bool get _redundant =>
      vm.phase == ViewerPhase.ready &&
      (vm.kind == FileKind.binary || vm.kind == FileKind.svg || vm.kind == FileKind.pdf);

  String get _meta {
    final s = vm.stat;
    final parts = <String>[];
    final image = vm.image;
    if (image != null) parts.add('${groupDigits(image.width)} × ${groupDigits(image.height)}');
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
        case FileKind.image:
          chips.add(AppChip(label: 'Fit', selected: !actualSize, onTap: () => onActualSize(false)));
          chips.add(AppChip(label: '100%', selected: actualSize, onTap: () => onActualSize(true)));
        case FileKind.svg || FileKind.pdf || FileKind.binary:
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
  const _Body({required this.vm, required this.actualSize});

  final FileViewerViewModel vm;
  final bool actualSize;

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
          FileKind.image => ImageView(image: vm.image!, actualSize: actualSize),
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
    final body = rendered ? MarkdownView(document: doc) : CodeView(document: doc, wrap: vm.wrap, highlightLine: vm.highlightLine);
    return Column(
      children: [
        Expanded(
          child: footer ? MediaQuery.removePadding(context: context, removeBottom: true, child: body) : body,
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
