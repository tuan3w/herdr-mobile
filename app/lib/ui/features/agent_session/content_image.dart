import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/acp_models.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../../data/services/image_decode.dart' show DecodedImage;
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
    if (block.data.isNotEmpty) return _InlineImage(block: block, cache: cache ?? ImagePreviewCache.shared);
    return ImageReferenceLine(block: block);
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
  const _InlineImage({required this.block, required this.cache});

  final ImageBlock block;
  final ImagePreviewCache cache;

  @override
  State<_InlineImage> createState() => _InlineImageState();
}

class _InlineImageState extends State<_InlineImage> {
  late ImageEntry _entry;

  @override
  void initState() {
    super.initState();
    _hold();
  }

  void _hold() {
    _entry = widget.cache.acquire(widget.block)..addListener(_changed);
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
    if (!identical(old.block, widget.block) || old.cache != widget.cache) {
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
    if (problem != null) return ImageReferenceLine(block: widget.block, problem: problem);
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
            child: Center(child: Icon(LucideIcons.image, size: 20, color: ds.textTertiary)),
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
