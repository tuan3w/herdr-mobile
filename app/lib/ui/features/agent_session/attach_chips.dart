import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../attach/gallery_thumb.dart';
import '../files/file_format.dart';
import '../photos/photo_item.dart';
import '../photos/photo_viewer.dart';
import 'attach_model.dart';
import 'visible_text.dart';

const _thumb = 32.0;

/// What will be sent with the draft, above the field: one removable chip per
/// attachment, a thumbnail for a picture and an icon for a file. A picture
/// that is still being prepared says so, with the one spinner the app allows
/// (the person is waiting for it). Takes no room when nothing is attached.
class AttachmentChips extends StatelessWidget {
  const AttachmentChips({super.key, required this.attachments});

  final ComposerAttachments attachments;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: attachments,
    builder: (context, _) {
      final items = attachments.items;
      return AnimatedSize(
        duration: Motion.reduced(context) ? Duration.zero : Motion.expand,
        curve: Motion.easeOut,
        alignment: Alignment.topCenter,
        child: items.isEmpty
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final a in items)
                        Padding(
                          key: ValueKey(a.id),
                          padding: const EdgeInsets.only(right: Gap.sm),
                          child: _Chip(
                            attachment: a,
                            onRemove: () => attachments.remove(a.id),
                            onRetry: () => attachments.retry(a.id),
                            onOpen: _pictureOf(a) ? () => unawaited(_open(context, items, a)) : null,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
      );
    },
  );
}

/// A picture that is ready: the chip opens it full screen.
bool _pictureOf(Attachment a) => a.kind == AttachmentKind.image && !a.preparing && a.thumb != null;

/// Opens the pictures waiting to be sent in the viewer, at [at]: this is what
/// will be sent (the prepared JPEG), not the original.
Future<void> _open(BuildContext context, List<Attachment> all, Attachment at) {
  final pictures = all.where(_pictureOf).toList();
  return openPhotoViewer(
    context,
    items: [
      for (final a in pictures)
        PhotoItem(
          id: 'attachment:${a.id}',
          name: visibleText(a.label),
          mime: 'image/jpeg',
          origin: 'Attached to your message (what is sent)',
          source: MemoryPhotoSource(() async => a.thumb!, size: a.thumb!.length),
        ),
    ],
    initialIndex: pictures.indexOf(at).clamp(0, pictures.length - 1),
  );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.attachment, required this.onRemove, required this.onRetry, this.onOpen});

  final Attachment attachment;
  final VoidCallback onRemove;
  final VoidCallback onRetry;

  /// Shows the picture; null for a file and for a picture still being prepared.
  final VoidCallback? onOpen;

  /// The second line, without the live percentage of an upload.
  String _status(double? progress) {
    final a = attachment;
    switch (a.phase) {
      case AttachPhase.preparing:
        return 'Preparing\u2026';
      case AttachPhase.uploading:
        final pct = ((progress ?? 0) * 100).floor();
        return 'Uploading $pct%${a.size == null ? '' : ' \u00b7 ${formatBytes(a.size)}'}';
      case AttachPhase.failed:
        return a.error ?? 'Upload failed';
      case AttachPhase.ready:
        if (a.note != null) return a.note!;
        if (a.kind == AttachmentKind.image) return formatBytes(a.thumb?.length);
        return a.embedded ? 'Text included' : 'Sent as a path';
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final a = attachment;
    final label = visibleText(a.label);
    final progress = a.progress;
    Widget status(double? value) => Text(
      _status(value),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Type.caption.copyWith(color: a.failed ? ds.dangerText : ds.textMuted),
    );
    return Semantics(
      container: true,
      label: '${a.kind == AttachmentKind.image ? 'Picture' : 'File'} $label, ${_status(progress?.value)}',
      child: DecoratedBox(
        decoration: BoxDecoration(color: ds.fill, borderRadius: BorderRadius.circular(Radii.chip)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kMinTap, maxWidth: 280),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: PressBuilder(
                  onTap: onOpen,
                  haptic: true,
                  scale: 0.98,
                  minTapSize: kMinTap,
                  button: onOpen == null ? null : true,
                  semanticLabel: onOpen == null ? null : 'Open $label',
                  builder: (context, pressed) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(width: Gap.sm),
                      ExcludeSemantics(child: _Thumb(attachment: a)),
                      const SizedBox(width: Gap.sm),
                      Flexible(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Type.compact.copyWith(color: ds.text)),
                            if (progress != null && a.uploading)
                              ValueListenableBuilder<double>(valueListenable: progress, builder: (context, v, _) => status(v))
                            else
                              status(null),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (a.failed)
                PressBuilder(
                  onTap: onRetry,
                  haptic: true,
                  minTapSize: kMinTap,
                  semanticLabel: 'Retry upload of $label',
                  builder: (context, pressed) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                    child: Text('Retry', style: Type.answer.copyWith(fontSize: 13.5, color: pressed ? ds.text : ds.accentText)),
                  ),
                ),
              PressBuilder(
                onTap: onRemove,
                haptic: true,
                minTapSize: kMinTap,
                semanticLabel: a.uploading ? 'Cancel upload of $label' : 'Remove $label',
                builder: (context, pressed) => SizedBox.square(
                  dimension: kMinTap,
                  child: Center(child: Icon(LucideIcons.x, size: 16, color: pressed ? ds.text : ds.textSecondary)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.attachment});

  final Attachment attachment;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final a = attachment;
    Widget? picture;
    if (a.preview != null) {
      // The gallery's own thumbnail, even after the picture is prepared: the
      // same provider the grid used, so it is already decoded and the chip
      // costs no second decode.
      picture = Image(image: galleryThumbProvider(a.preview!), fit: BoxFit.cover, gaplessPlayback: true, excludeFromSemantics: true);
    } else if (a.thumb != null) {
      picture = Image.memory(
        a.thumb!,
        fit: BoxFit.cover,
        // Decoded at the size it shows (3x for density): a 1 MB picture never
        // becomes a full-size bitmap for a 32 dp thumbnail.
        cacheWidth: (_thumb * 3).round(),
        gaplessPlayback: true,
        excludeFromSemantics: true,
        errorBuilder: (_, _, _) => Icon(LucideIcons.image, size: 18, color: ds.textSecondary),
      );
    } else if (a.previewPath != null) {
      picture = Image(
        image: ResizeImage(FileImage(File(a.previewPath!)), width: (_thumb * 3).round()),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        excludeFromSemantics: true,
        errorBuilder: (_, _, _) => Icon(LucideIcons.image, size: 18, color: ds.textSecondary),
      );
    }
    final Widget child;
    if (picture != null) {
      child = a.preparing && a.thumb == null && a.preview == null ? const Center(child: BusySpinner()) : picture;
    } else if (a.preparing) {
      child = const Center(child: BusySpinner());
    } else {
      child = Icon(a.kind == AttachmentKind.image ? LucideIcons.image : LucideIcons.fileText, size: 18, color: ds.textSecondary);
    }
    final tile = ClipRRect(
      borderRadius: BorderRadius.circular(Radii.tile),
      child: SizedBox.square(
        dimension: _thumb,
        child: ColoredBox(color: ds.fillPressed, child: child),
      ),
    );
    final progress = a.progress;
    if (!a.uploading || progress == null) return tile;
    // The upload's ring over the thumbnail: a thin arc, no looping animation.
    return SizedBox.square(
      dimension: _thumb,
      child: Stack(
        fit: StackFit.expand,
        children: [
          tile,
          ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (context, v, _) => CustomPaint(painter: _RingPainter(progress: v, track: ds.hairline, color: ds.accent)),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.progress, required this.track, required this.color});

  final double progress;
  final Color track;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(1.5);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, math.pi * 2, false, paint..color = track.withValues(alpha: 0.7));
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * progress.clamp(0.02, 1.0), false, paint..color = color);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress || old.color != color;
}
