import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/services/exif.dart';
import '../../../data/services/image_decode.dart';
import '../../../data/services/photo_export.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../files/file_format.dart';
import '../files/file_widgets.dart' show copyToClipboard;
import 'photo_info.dart';
import 'photo_item.dart';
import 'photo_stage.dart';
import 'photo_viewer_view_model.dart';

/// Opens the full-screen viewer on [items] (one picture or a set to swipe
/// through), at [initialIndex]. The route is transparent so a drag that
/// dismisses it shows the screen underneath through the fading backdrop.
///
/// [moreItems] finishes the list after the viewer is already open: a folder's
/// other pictures arrive from the machine while the first one loads.
Future<void> openPhotoViewer(
  BuildContext context, {
  required List<PhotoItem> items,
  int initialIndex = 0,
  Future<List<PhotoItem>> Function()? moreItems,
  Widget Function()? viewAsText,
  PhotoOverlayBuilder? overlay,
}) => Navigator.of(context).push(photoViewerRoute(
  items: items,
  initialIndex: initialIndex,
  moreItems: moreItems,
  viewAsText: viewAsText,
  overlay: overlay,
));

/// The route [openPhotoViewer] pushes, for callers that push their own
/// (replacing a screen, say).
Route<T> photoViewerRoute<T>({
  required List<PhotoItem> items,
  int initialIndex = 0,
  Future<List<PhotoItem>> Function()? moreItems,
  Widget Function()? viewAsText,
  PhotoExport? export,
  FitDecoder? decoder,
  ExifInfo? Function(Uint8List bytes)? exifReader,
  PhotoOverlayBuilder? overlay,
}) {
  final pageKey = GlobalKey();
  return PageRouteBuilder<T>(
    opaque: false,
    transitionDuration: Motion.page,
    reverseTransitionDuration: Motion.sheetOut,
    pageBuilder: (context, _, _) => KeyedSubtree(
      key: pageKey,
      child: PhotoViewer(
        items: items,
        initialIndex: initialIndex,
        moreItems: moreItems,
        viewAsText: viewAsText,
        export: export,
        decoder: decoder,
        exifReader: exifReader,
        overlay: overlay,
      ),
    ),
    transitionsBuilder: (context, animation, _, child) {
      final reduced = Motion.reduced(context);
      // Faded in and out, a hair of scale: nothing wraps the picture at rest.
      return AnimatedBuilder(
        animation: animation,
        child: child,
        builder: (context, child) {
          if (animation.value >= 1) return child!;
          final eased = Motion.easeOut.transform(animation.value);
          final faded = FadeTransition(opacity: animation, child: child);
          return reduced
              ? faded
              : Transform.scale(scale: 0.97 + 0.03 * eased, child: faded);
        },
      );
    },
  );
}

/// Builds extra controls over the picture, placed in the chrome's stack (so a
/// [Positioned] works); rebuilt when the page changes.
typedef PhotoOverlayBuilder = Widget Function(BuildContext context, PhotoViewerViewModel model);

/// The immersive viewer: pictures on black, a quiet overlay (back, position,
/// info, share) that a tap shows and hides, a one-line caption under the
/// picture, and the touch physics of [PhotoStage].
class PhotoViewer extends StatefulWidget {
  const PhotoViewer({
    super.key,
    required this.items,
    this.initialIndex = 0,
    this.moreItems,
    this.viewAsText,
    this.export,
    this.decoder,
    this.exifReader,
    this.overlay,
  });

  final List<PhotoItem> items;
  final int initialIndex;
  final Future<List<PhotoItem>> Function()? moreItems;

  /// A file that is not a picture after all (HTML saved as `.png`): builds the
  /// screen that shows it as text, which replaces this one. Null when there is
  /// none.
  final Widget Function()? viewAsText;

  final PhotoExport? export;
  final FitDecoder? decoder;
  final ExifInfo? Function(Uint8List bytes)? exifReader;

  /// Extra controls drawn with the chrome (they fade with it): the attach
  /// sheet's preview puts its select toggle here. Null for every other caller.
  final PhotoOverlayBuilder? overlay;

  @override
  State<PhotoViewer> createState() => PhotoViewerState();
}

class PhotoViewerState extends State<PhotoViewer> with SingleTickerProviderStateMixin {
  late final PhotoViewerViewModel model = PhotoViewerViewModel(
    items: widget.items,
    initialIndex: widget.initialIndex,
    decoder: widget.decoder ?? decodeImageFit,
    exifReader: widget.exifReader ?? readExif,
    export: widget.export,
  );
  final _dismiss = ValueNotifier<double>(0);
  late final AnimationController _chrome = AnimationController(
    vsync: this,
    duration: Motion.standard,
    value: 1,
  );
  final _chromeKey = GlobalKey();
  late final ThemeData _theme = AppTheme.dark();

  @override
  void initState() {
    super.initState();
    unawaited(_loadMore());
  }

  Future<void> _loadMore() async {
    final more = widget.moreItems;
    if (more == null) return;
    try {
      final items = await more();
      if (mounted) model.setItems(items);
    } on Object {
      // The rest of the folder is a bonus: the picture opened stays alone.
    }
  }

  @override
  void dispose() {
    _chrome.dispose();
    _dismiss.dispose();
    model.dispose();
    super.dispose();
  }

  bool get chromeShown => _chrome.value > 0.5 && _chrome.status != AnimationStatus.reverse;

  void _toggleChrome() {
    if (_chrome.status == AnimationStatus.reverse || _chrome.value == 0) {
      _chrome.forward();
    } else {
      _chrome.reverse();
    }
  }

  void _close() => Navigator.of(context).maybePop();

  Future<void> _share(BuildContext context) async {
    final entry = model.currentEntry;
    Haptics.tick();
    await showActionSheet(
      context,
      actions: [
        SheetAction(
          label: 'Save to phone',
          icon: LucideIcons.download,
          unavailable: entry.bytes == null ? 'Available once the picture has loaded' : null,
          onTap: () => unawaited(_run(context, model.save)),
        ),
        SheetAction(
          label: 'Share…',
          icon: LucideIcons.share2,
          unavailable: entry.bytes == null ? 'Available once the picture has loaded' : null,
          onTap: () => unawaited(_run(context, model.share)),
        ),
        if (entry.item.path != null)
          SheetAction(
            label: 'Copy path',
            icon: LucideIcons.link,
            onTap: () => copyToClipboard(context, entry.item.path!, 'Path copied'),
          ),
      ],
    );
  }

  Future<void> _run(BuildContext context, Future<PhotoActionResult> Function() action) async {
    final toaster = Toaster.maybeOf(context);
    final result = await action();
    if (result.message.isEmpty && result.ok) return;
    toaster?.show(result.message, kind: result.ok ? ToastKind.success : ToastKind.failed);
  }

  Widget _failure(BuildContext context, PhotoEntry entry) {
    final text = widget.viewAsText;
    return _FailureView(
      model: model,
      entry: entry,
      onViewAsText: text == null
          ? null
          : () => Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => text())),
      run: _run,
    );
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: _theme,
    // Below the theme: the sheets opened from here are dark too.
    child: Builder(
      builder: (context) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppTheme.systemBars(Brightness.dark),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            fit: StackFit.expand,
            children: [
              ValueListenableBuilder<double>(
                valueListenable: _dismiss,
                builder: (context, progress, _) =>
                    ColoredBox(color: photoBackdrop.withValues(alpha: 1 - progress)),
              ),
              PhotoStage(
                model: model,
                dismissProgress: _dismiss,
                onTap: _toggleChrome,
                onDismiss: _close,
                failureBuilder: _failure,
              ),
              _Chrome(
                key: _chromeKey,
                model: model,
                visible: _chrome,
                dismiss: _dismiss,
                onBack: _close,
                onInfo: () {
                  Haptics.tick();
                  unawaited(showPhotoInfo(context, model.currentEntry));
                },
                onShare: () => unawaited(_share(context)),
                overlay: widget.overlay,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Both bars of the overlay. Faded by [visible] and by a dismissing drag;
/// nothing wraps them while they are fully shown.
class _Chrome extends StatelessWidget {
  const _Chrome({
    super.key,
    required this.model,
    required this.visible,
    required this.dismiss,
    required this.onBack,
    required this.onInfo,
    required this.onShare,
    this.overlay,
  });

  final PhotoOverlayBuilder? overlay;
  final PhotoViewerViewModel model;
  final Animation<double> visible;
  final ValueNotifier<double> dismiss;
  final VoidCallback onBack;
  final VoidCallback onInfo;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final bars = MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: ListenableBuilder(
        listenable: model,
        builder: (context, _) => Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: _TopBar(model: model, onBack: onBack, onInfo: onInfo, onShare: onShare),
            ),
            Positioned(left: 0, right: 0, bottom: 0, child: _Caption(model: model)),
            if (overlay != null) overlay!(context, model),
          ],
        ),
      ),
    );
    return AnimatedBuilder(
      animation: Listenable.merge([visible, dismiss]),
      child: bars,
      builder: (context, child) {
        // The bars go as soon as a drag starts (the picture needs the room):
        // gone by a third of the way to dismissal.
        final opacity = Motion.easeOut.transform(visible.value) * (1 - (dismiss.value * 3).clamp(0.0, 1.0));
        if (opacity <= 0) return ExcludeSemantics(child: IgnorePointer(child: Opacity(opacity: 0, child: child)));
        if (opacity >= 1) return child!;
        return IgnorePointer(ignoring: opacity < 0.5, child: Opacity(opacity: opacity, child: child));
      },
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.model, required this.onBack, required this.onInfo, required this.onShare});

  final PhotoViewerViewModel model;
  final VoidCallback onBack;
  final VoidCallback onInfo;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final top = MediaQuery.paddingOf(context).top;
    final entry = model.count == 0 ? null : model.currentEntry;
    final title = model.count > 1 ? model.positionLabel : (model.count == 0 ? 'Photo' : model.current.name);
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xB3000000), Color(0x00000000)],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(Gap.gutter - 6, top, Gap.gutter - 6, Gap.md),
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              CircleButton(icon: LucideIcons.chevronLeft, tooltip: 'Back', onPressed: onBack),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Semantics(
                  header: true,
                  liveRegion: true,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.barTitle.copyWith(color: ds.text),
                  ),
                ),
              ),
              CircleButton(icon: LucideIcons.info, tooltip: 'Photo info', onPressed: entry == null ? null : onInfo),
              const SizedBox(width: 4),
              CircleButton(icon: LucideIcons.share2, tooltip: 'Save or share', onPressed: entry == null ? null : onShare),
            ],
          ),
        ),
      ),
    );
  }
}

/// `IMG_2041.jpg · 4032 × 3024` under the picture, on one line, whatever the
/// name: a long one is cut in the middle so the extension (and the end of
/// the name, which is usually what differs) stays.
class _Caption extends StatelessWidget {
  const _Caption({required this.model});

  final PhotoViewerViewModel model;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    if (model.count == 0) return const SizedBox.shrink();
    final item = model.current;
    final entry = model.currentEntry;
    final image = entry.image;
    final detail = image != null
        ? '${groupDigits(image.width)} × ${groupDigits(image.height)}'
        : (item.size != null ? formatBytes(item.size) : '');
    final nameStyle = Type.compact.copyWith(color: ds.text, fontWeight: FontWeight.w600);
    final detailStyle = Type.compact.copyWith(color: ds.textSecondary);
    final bottom = MediaQuery.paddingOf(context).bottom;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xB3000000), Color(0x00000000)],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(Gap.gutter, Gap.xl, Gap.gutter, Gap.lg + bottom),
        child: Semantics(
          container: true,
          label: detail.isEmpty ? item.name : '${item.name}, $detail',
          child: ExcludeSemantics(
            child: LayoutBuilder(
              builder: (context, box) {
                final scaler = MediaQuery.textScalerOf(context);
                final gap = detail.isEmpty ? '' : '  ·  ';
                final room = box.maxWidth - _measure(gap + detail, detailStyle, scaler);
                final name = fitMiddle(item.name, room < 60 ? box.maxWidth : room, nameStyle, scaler);
                return Text.rich(
                  TextSpan(children: [
                    TextSpan(text: name, style: nameStyle),
                    if (detail.isNotEmpty) TextSpan(text: '$gap$detail', style: detailStyle),
                  ]),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

double _measure(String text, TextStyle style, TextScaler scaler) =>
    (TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout()).width;

/// [name] cut in the middle with `…` just enough to fit [maxWidth], keeping
/// the extension and as much of both ends as there is room for.
String fitMiddle(String name, double maxWidth, TextStyle style, TextScaler scaler) {
  if (_measure(name, style, scaler) <= maxWidth) return name;
  final dot = name.lastIndexOf('.');
  final ext = dot > 0 && name.length - dot <= 6 ? name.substring(dot) : '';
  final stem = ext.isEmpty ? name : name.substring(0, dot);
  // Keep `tail` characters before the extension, then as much head as fits.
  final tail = stem.length > 8 ? 4 : 0;
  final end = stem.substring(stem.length - tail) + ext;
  var lo = 0, hi = stem.length - tail;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (_measure('${stem.substring(0, mid)}…$end', style, scaler) <= maxWidth) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return '${stem.substring(0, lo)}…$end';
}

/// What shows where a picture would be when it cannot be: what went wrong and
/// what can be done about it. A picture over the read cap can still be shared:
/// the file is copied to the phone in pieces and handed to the share sheet.
class _FailureView extends StatelessWidget {
  const _FailureView({required this.model, required this.entry, required this.onViewAsText, required this.run});

  final PhotoViewerViewModel model;
  final PhotoEntry entry;
  final VoidCallback? onViewAsText;
  final Future<void> Function(BuildContext context, Future<PhotoActionResult> Function() action) run;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final failure = entry.failure!;
    final (icon, title) = switch (failure.kind) {
      PhotoFailureKind.tooLarge => (LucideIcons.fileWarning, 'Too large to open here'),
      PhotoFailureKind.notAnImage => (LucideIcons.imageOff, "Can't show this as a picture"),
      PhotoFailureKind.network => (LucideIcons.cloudOff, 'Connection lost'),
      PhotoFailureKind.unreadable => (LucideIcons.triangleAlert, "Couldn't open this photo"),
    };
    final exporting = entry.exporting;
    final large = failure.kind == PhotoFailureKind.tooLarge && model.canShareLarge;
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: Gap.gutter, vertical: 72),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 32, color: ds.textSecondary),
                const SizedBox(height: Gap.md),
                Semantics(
                  header: true,
                  child: Text(title, textAlign: TextAlign.center, style: Type.title.copyWith(color: ds.text)),
                ),
                const SizedBox(height: Gap.sm),
                Text(
                  failure.message,
                  textAlign: TextAlign.center,
                  style: Type.compact.copyWith(color: ds.textSecondary),
                ),
                if (large) ...[
                  const SizedBox(height: Gap.sm),
                  Text(
                    'Share it to open it in an app made for big files.',
                    textAlign: TextAlign.center,
                    style: Type.compact.copyWith(color: ds.textSecondary),
                  ),
                ],
                const SizedBox(height: Gap.xl),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: Gap.sm,
                  runSpacing: Gap.sm,
                  children: [
                    if (failure.retryable)
                      AppButton(label: 'Retry', icon: LucideIcons.refreshCw, onPressed: model.retry),
                    if (large)
                      AppButton(
                        label: exporting == null
                            ? 'Share…'
                            : 'Copying ${formatBytes(exporting.done)} of ${formatBytes(exporting.total)}',
                        icon: LucideIcons.share2,
                        loading: exporting != null,
                        onPressed: exporting == null ? () => run(context, model.shareLarge) : null,
                      ),
                    if (failure.kind == PhotoFailureKind.notAnImage && onViewAsText != null)
                      AppButton(label: 'View as text', icon: LucideIcons.fileText, onPressed: onViewAsText),
                    if (entry.item.path != null)
                      AppButton(
                        label: 'Copy path',
                        icon: LucideIcons.copy,
                        kind: AppButtonKind.secondary,
                        onPressed: () => copyToClipboard(context, entry.item.path!, 'Path copied'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
