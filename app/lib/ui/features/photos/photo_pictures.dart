import 'package:herdr_mobile/l10n/l10n_context.dart';

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../files/file_format.dart';
import 'photo_math.dart';
import 'photo_viewer_view_model.dart';

/// One page of the viewer: the picture of [entry] placed by [scale] and
/// [offset] (see [PhotoPose]) inside [viewport]; while it loads, its thumbnail
/// (when there is one) and the progress; when it cannot load, what
/// [failureBuilder] makes.
class PhotoPage extends StatelessWidget {
  const PhotoPage({
    super.key,
    required this.entry,
    required this.viewport,
    required this.scale,
    required this.offset,
    required this.shrink,
    required this.failureBuilder,
  });

  final PhotoEntry entry;
  final Size viewport;
  final double scale;
  final Offset offset;

  /// Extra scale while the picture is being dragged away.
  final double shrink;

  final Widget Function(BuildContext context, PhotoEntry entry) failureBuilder;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: entry,
    builder: (context, _) {
      if (entry.failure != null) return failureBuilder(context, entry);
      final image = entry.shown;
      if (image == null) return _Loading(entry: entry, viewport: viewport);
      return _Picture(
        image: image,
        pixels: entry.sharp?.image.width ?? entry.image!.image.width,
        native: entry.nativeSize!,
        transparent: entry.mayBeTransparent,
        viewport: viewport,
        scale: scale,
        offset: offset,
        shrink: shrink,
      );
    },
  );
}

/// [image] drawn at fit inside [viewport], moved and scaled by the pose. The
/// picture is one layer (the checkerboard of a transparent one moves with it):
/// the transform only changes where the layer is composited.
class _Picture extends StatelessWidget {
  const _Picture({
    required this.image,
    required this.pixels,
    required this.native,
    required this.transparent,
    required this.viewport,
    required this.scale,
    required this.offset,
    required this.shrink,
  });

  final ui.Image image;
  final int pixels;
  final Size native;
  final bool transparent;
  final Size viewport;
  final double scale;
  final Offset offset;
  final double shrink;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final fit = applyBoxFit(BoxFit.contain, native, viewport).destination;
    final crisp = useNearestNeighbour(shownWidth: fit.width * scale, devicePixelRatio: dpr, bitmapWidth: pixels);
    final s = scale * shrink;
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..translateByDouble(offset.dx, offset.dy, 0, 1)
        ..scaleByDouble(s, s, 1, 1),
      child: Center(
        child: SizedBox(
          width: fit.width,
          height: fit.height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // A pixel in from the edge: the picture's anti-aliased edge
              // must not show a dashed line of squares around it.
              if (transparent)
                const Padding(
                  // design-lint: allow(raw-size) one pixel exactly: the inset hides the edge, any gap token would show a frame.
                  padding: EdgeInsets.all(1),
                  child: CustomPaint(painter: _Checkerboard()),
                ),
              RawImage(
                image: image,
                fit: BoxFit.fill,
                filterQuality: crisp ? FilterQuality.none : FilterQuality.medium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The grey squares behind a picture that may have see-through pixels. Fixed
/// in the picture's space, in two greys that read on black.
class _Checkerboard extends CustomPainter {
  const _Checkerboard();

  static const _cell = 12.0;

  @override
  void paint(Canvas canvas, Size size) {
    // design-lint: allow(raw-color) the checkerboard sits on the viewer's fixed black, the same in both themes.
    final dark = Paint()..color = const Color(0xFF262626);
    // design-lint: allow(raw-color) see above: the light square of the same fixed pair.
    final light = Paint()..color = const Color(0xFF3A3A3A);
    canvas.drawRect(Offset.zero & size, dark);
    final path = Path();
    final columns = (size.width / _cell).ceil();
    final rows = (size.height / _cell).ceil();
    // The last column and row are cut at the edge: a whole cell would stick out
    // past the picture, a dashed strip of up to one cell on the right and bottom
    // that shows at any zoom and grows with it (seen on a 2,487 px diagram).
    for (var y = 0; y < rows; y++) {
      for (var x = y.isEven ? 0 : 1; x < columns; x += 2) {
        path.addRect(
          Rect.fromLTRB(
            x * _cell,
            y * _cell,
            math.min((x + 1) * _cell, size.width),
            math.min((y + 1) * _cell, size.height),
          ),
        );
      }
    }
    canvas.drawPath(path, light);
  }

  @override
  bool shouldRepaint(_Checkerboard old) => false;
}

/// The thumbnail (if any) under a quiet progress badge: the one spinner the
/// app allows, which stops when the picture arrives.
class _Loading extends StatelessWidget {
  const _Loading({required this.entry, required this.viewport});

  final PhotoEntry entry;
  final Size viewport;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final holder = entry.placeholder;
    final total = entry.total;
    final received = entry.received;
    final fraction = total == null || total <= 0 ? null : (received / total).clamp(0.0, 1.0);
    final String line;
    if (entry.decoding) {
      line = 'Preparing…';
    } else if (total != null && total > 0 && received > 0) {
      line = '${formatBytes(received)} of ${formatBytes(total)}';
    } else if (total != null && total > 0) {
      line = formatBytes(total);
    } else {
      line = 'Loading…';
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        if (holder != null)
          Center(
            child: Builder(
              builder: (context) {
                final fit = applyBoxFit(
                  BoxFit.contain,
                  Size(holder.width.toDouble(), holder.height.toDouble()),
                  viewport,
                ).destination;
                return SizedBox(
                  width: fit.width,
                  height: fit.height,
                  child: RawImage(image: holder, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                );
              },
            ),
          ),
        Center(
          child: Semantics(
            liveRegion: true,
            label: context.l10n.messageLoadingPhoto(line),
            child: ExcludeSemantics(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: holder == null ? Colors.transparent : ds.surface,
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const BusySpinner(size: IconSize.row),
                          const SizedBox(width: Gap.md),
                          Text(line, style: Type.compact.copyWith(color: ds.textSecondary)),
                        ],
                      ),
                      if (fraction != null) ...[
                        const SizedBox(height: Gap.md),
                        SizedBox(
                          width: math.min(180, viewport.width - 96),
                          child: ProgressLine(fraction: fraction),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
