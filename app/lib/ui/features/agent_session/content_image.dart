import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/acp_models.dart';
import '../../../data/observed/log_picture.dart';
import '../../../data/services/disk_cache.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../../data/services/image_decode.dart' show DecodedImage;
import '../files/file_format.dart';
import 'content_chip.dart';
import 'content_image_cache.dart';
import 'photo_thread.dart';
import 'visible_text.dart';
import 'content_target.dart';

/// Tallest an inline picture is drawn, in dp.
const imagePreviewMaxHeight = 220.0;

/// A picture an agent (or the person) sent, in the transcript:
///
///  * with base64 `data`: an inline preview, at most [imagePreviewMaxHeight]
///    high, aspect kept, rounded; a tap opens it in the zoom viewer. The bytes
///    are decoded off the main isolate when large and the bitmap is shrunk
///    while it is decoded ([ImagePreviewCache]);
///  * with only a `uri`: a line, never a download. An `http`/`https` address
///    shows `Image · host`, and a tap shows the whole address in the link
///    sheet; `file://` and absolute paths open the file viewer on the
///    session's machine, the way a path in the Markdown does;
///  * when the data cannot be drawn (malformed, too large, 0 x 0, not a
///    picture): the same line with a plain note saying why.
class ImageBlockView extends StatelessWidget {
  const ImageBlockView({super.key, required this.block, this.cache});

  final ImageBlock block;

  /// The cache previews live in; the shared one unless a test brings its own.
  final ImagePreviewCache? cache;

  /// The name an image goes by: the last segment of its uri, else empty.
  static String nameOf(ImageBlock block) => (block.uri ?? '').trim().isEmpty ? '' : contentBaseName(block.uri!);

  @override
  Widget build(BuildContext context) {
    final b = block;
    if (b is LogImageBlock) return LogImageView(block: b, cache: cache);
    if (block.data.isNotEmpty) return _InlineImage(block: block, cache: cache ?? ImagePreviewCache.shared);
    return ImageReferenceLine(block: block);
  }
}

/// A picture of a terminal-log chat (Claude Code, Codex, omp), which the host
/// does not send with the log: a quiet line with its type and size, and
/// `Tap to load`. Nothing is downloaded until the person taps, except that a
/// picture the phone already holds (the [DiskCache]) simply shows. A failed
/// fetch says why and offers `Tap to retry.`.
///
/// The bytes come through the session of the conversation ([ThreadPhotos]);
/// without one (a subagent's view) the line says `Not available here` and does
/// nothing.
class LogImageView extends StatefulWidget {
  const LogImageView({super.key, required this.block, this.cache});

  final LogImageBlock block;
  final ImagePreviewCache? cache;

  @override
  State<LogImageView> createState() => _LogImageViewState();
}

class _LogImageViewState extends State<LogImageView> {
  // The picture is wanted: asked for by a tap, or already held on the phone.
  late var _requested = DiskCache.shared.knows(widget.block.key);

  // The person tapped: the wait that follows is theirs, and shows the spinner.
  var _tapped = false;

  @override
  void initState() {
    super.initState();
    // Known at once when the index is loaded (a held picture is then never a
    // chip for a frame, and the row never changes height under the reader);
    // otherwise as soon as it is: no tap, no radio.
    final store = DiskCache.shared;
    if (!_requested) {
      unawaited(store.ready.then((_) {
        if (mounted && !_requested && store.knows(widget.block.key)) setState(() => _requested = true);
      }));
    }
  }

  void _load() {
    Haptics.tick();
    setState(() {
      _requested = true;
      _tapped = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final block = widget.block;
    final scope = ThreadPhotos.maybeOf(context);
    if (_requested && scope != null) {
      return _InlineImage(
        block: block,
        cache: widget.cache ?? ImagePreviewCache.shared,
        fetch: () => scope.session.loadLogPicture(block.ref),
        waited: _tapped,
      );
    }
    final size = block.ref.bytes;
    return ContentChip(
      icon: LucideIcons.image,
      title: 'Image',
      // The size first: at a large text size the type may wrap or be cut, and the
      // size is what tells the person whether a tap is worth it.
      detail: [if (size != null) formatBytes(size), if (block.mimeType.isNotEmpty) block.mimeType].join(' · '),
      note: scope == null ? 'Not available here' : 'Tap to load',
      muted: scope == null,
      onTap: scope == null ? null : _load,
    );
  }
}

/// The line for a picture that is only a uri, or whose data cannot be drawn
/// ([problem] says why).
class ImageReferenceLine extends StatelessWidget {
  const ImageReferenceLine({super.key, required this.block, this.problem});

  final ImageBlock block;
  final String? problem;

  @override
  Widget build(BuildContext context) {
    final uri = block.uri?.trim() ?? '';
    final target = resolveContentUri(uri);
    final mime = block.mimeType;
    final String detail;
    switch (target) {
      case WebTarget(:final host):
        detail = host;
      case PathTarget():
        detail = ImageBlockView.nameOf(block);
      case null:
        detail = uri.length > 80 ? '${uri.substring(0, 80)}…' : uri;
    }
    final note = problem ?? (uri.isEmpty ? 'The agent sent no picture data.' : null);
    return ContentChip(
      icon: LucideIcons.image,
      title: 'Image',
      detail: [if (detail.isNotEmpty) detail else if (mime.isNotEmpty) mime].join(' · '),
      note: note,
      muted: target == null,
      onTap: contentTapFor(context, target),
    );
  }
}

class _InlineImage extends StatefulWidget {
  const _InlineImage({required this.block, required this.cache, this.fetch, this.waited = false});

  final ImageBlock block;
  final ImagePreviewCache cache;

  /// The person asked for this picture (a tap): the wait shows the spinner. A
  /// held picture that simply appears has the quiet icon, like any preview.
  final bool waited;

  /// Brings the bytes of a [LogImageBlock] (see [ImagePreviewCache.acquire]).
  final Future<Uint8List> Function()? fetch;

  @override
  State<_InlineImage> createState() => _InlineImageState();
}

class _InlineImageState extends State<_InlineImage> {
  late ImageEntry _entry;

  // A retry is a tap too.
  var _retried = false;

  @override
  void initState() {
    super.initState();
    _hold();
  }

  void _hold() {
    _entry = widget.cache.acquire(widget.block, fetch: widget.fetch)..addListener(_changed);
  }

  void _letGo() {
    _entry.removeListener(_changed);
    widget.cache.release(_entry);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(_InlineImage old) {
    super.didUpdateWidget(old);
    if (ImagePreviewCache.keyOf(old.block) != ImagePreviewCache.keyOf(widget.block) || old.cache != widget.cache) {
      // The cache of the old widget lets its entry go.
      _entry.removeListener(_changed);
      old.cache.release(_entry);
      _hold();
    }
  }

  @override
  void dispose() {
    _letGo();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final problem = _entry.problem;
    final logPicture = widget.block is LogImageBlock;
    if (problem != null) {
      if (!logPicture) return ImageReferenceLine(block: widget.block, problem: problem);
      // A fetch that failed can be tried again; a picture over the limit, a log
      // that is not what it was and a view that cannot fetch it cannot.
      final retryable = _entry.retryable;
      return ContentChip(
        icon: LucideIcons.image,
        title: 'Image',
        detail: widget.block.mimeType,
        note: retryable ? '$problem Tap to retry.' : problem,
        muted: !retryable,
        onTap: retryable
            ? () {
                Haptics.tick();
                _retried = true;
                widget.cache.retry(_entry);
              }
            : null,
      );
    }
    final image = _entry.image;
    final ds = context.ds;
    final name = ImageBlockView.nameOf(widget.block);
    if (image == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: _Frame(
          width: 120,
          height: 96,
          child: ColoredBox(
            color: ds.fill,
            // A fetch the person started is a wait they can see: the one spinner.
            child: Center(
              child: logPicture && (widget.waited || _retried)
                  ? const BusySpinner(size: 20)
                  : Icon(LucideIcons.image, size: 20, color: ds.textTertiary),
            ),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        final size = _drawSize(image, box.maxWidth, MediaQuery.devicePixelRatioOf(context));
        return Align(
          alignment: Alignment.centerLeft,
          child: PressBuilder(
            scale: 0.985,
            onTap: () {
              Haptics.tick();
              unawaited(showContentImage(context, widget.block));
            },
            semanticLabel: imageSemanticLabel(widget.block, name),
            minTapSize: kMinTap,
            builder: (context, pressed) => _Frame(
              width: size.width,
              height: size.height,
              child: RawImage(
                image: image.image,
                width: size.width,
                height: size.height,
                fit: BoxFit.fill,
                filterQuality: size.width * MediaQuery.devicePixelRatioOf(context) > image.image.width * 1.5
                    ? FilterQuality.none
                    : FilterQuality.medium,
              ),
            ),
          ),
        );
      },
    );
  }

  /// The picture's size on screen: its aspect, within [maxWidth] and
  /// [imagePreviewMaxHeight], never more than twice its natural size (a
  /// 48 px icon is not blown up to the width of the screen).
  static Size _drawSize(DecodedImage image, double maxWidth, double dpr) {
    final w = image.width / dpr;
    final h = image.height / dpr;
    final scale = math.min(2.0, math.min(maxWidth / w, imagePreviewMaxHeight / h));
    return Size(math.max(1, w * scale), math.max(1, h * scale));
  }
}

class _Frame extends StatelessWidget {
  const _Frame({required this.width, required this.height, required this.child});

  final double width;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final radius = BorderRadius.circular(Radii.panel);
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(borderRadius: radius, border: Border.all(color: ds.hairline)),
        child: ClipRRect(borderRadius: radius, child: child),
      ),
    );
  }
}

/// `Image, image/png, chart.png`: what a screen reader says for a picture.
String imageSemanticLabel(ImageBlock block, String name) => [
  'Image',
  if (block.mimeType.isNotEmpty) block.mimeType,
  if (name.isNotEmpty) visibleText(name),
].join(', ');
