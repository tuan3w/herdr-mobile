import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/services/phone_gallery.dart';
import '../../../data/services/remote_files.dart' show ReadCancel, ReadCancelled;
import '../../../data/services/thumb_cache.dart';
import '../../core/controls.dart';
import '../../core/theme.dart';
import '../files/file_format.dart';
import '../photos/photo_item.dart';
import '../photos/photo_viewer.dart';
import 'gallery_model.dart';
import 'selection_circle.dart';
import 'tray.dart';

/// A picture of the gallery for the immersive viewer: the original, read from
/// the phone's storage in the background (the viewer decodes it to the screen
/// size first, as for any photo).
class GalleryPhotoSource implements PhotoSource {
  GalleryPhotoSource(this._gallery, this.asset);

  final PhoneGallery _gallery;
  final GalleryAsset asset;

  @override
  int? get size => null;

  @override
  Future<Uint8List> read({void Function(int received)? onProgress, ReadCancel? cancel}) async {
    final file = await _gallery.file(asset);
    if (file == null) throw const PhotoSourceException('This picture is no longer on the phone.');
    if (file.size > photoReadCap) {
      throw PhotoSourceException('This photo is ${formatBytes(file.size)}. The viewer opens photos up to ${formatBytes(photoReadCap)}.', tooLarge: true);
    }
    final bytes = await File(file.path).readAsBytes();
    if (cancel?.cancelled ?? false) throw const ReadCancelled();
    onProgress?.call(bytes.length);
    return bytes;
  }
}

/// Opens the album at [index] in the app's one photo viewer, with a select
/// toggle over the picture that works on the sheet's tray.
Future<void> openGalleryPreview(
  BuildContext context, {
  required GalleryModel model,
  required AttachTray tray,
  required ThumbCache cache,
  required int index,
  PhoneGallery? gallery,
}) {
  final assets = <GalleryAsset>[];
  for (var i = 0; i < model.count; i++) {
    final a = model.at(i);
    if (a == null) break;
    assets.add(a);
  }
  final byId = {for (final a in assets) a.id: a};
  final source = gallery ?? model.gallery;
  return openPhotoViewer(
    context,
    items: [
      for (final a in assets)
        PhotoItem(
          id: a.id,
          name: a.name ?? 'Photo',
          modified: a.createdAt,
          mime: 'image/jpeg',
          origin: 'On this phone',
          source: GalleryPhotoSource(source, a),
        ),
    ],
    initialIndex: index.clamp(0, assets.length - 1),
    overlay: (context, viewer) => Positioned(
      left: 0,
      right: 0,
      bottom: 56 + MediaQuery.paddingOf(context).bottom,
      child: Center(
        child: _SelectPill(
          tray: tray,
          asset: () => byId[viewer.currentEntry.item.id],
          cache: cache,
        ),
      ),
    ),
  );
}

/// `Select` / `Selected 2`: the picture on show joins or leaves the tray.
class _SelectPill extends StatelessWidget {
  const _SelectPill({required this.tray, required this.asset, required this.cache});

  final AttachTray tray;
  final GalleryAsset? Function() asset;
  final ThumbCache cache;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: tray,
    builder: (context, _) {
      final a = asset();
      if (a == null) return const SizedBox.shrink();
      final number = tray.numberOf('g:${a.id}');
      final picked = number != null;
      final ds = context.ds;
      void toggle() {
        if (picked) {
          tray.remove('g:${a.id}');
        } else {
          tray.add(GalleryPick(a, thumb: cache.peek(a.id)));
        }
      }

      return PressBuilder(
        onTap: toggle,
        haptic: true,
        scale: 0.97,
        minTapSize: kMinTap,
        selected: picked,
        semanticLabel: picked ? 'Selected, number $number. Tap to deselect' : 'Select this photo',
        builder: (context, pressed) => Container(
          height: 40,
          padding: const EdgeInsets.only(left: 8, right: 16),
          decoration: BoxDecoration(
            color: picked ? ds.accent : const Color(0x99000000),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectionMark(number: number, onPhoto: true),
              const SizedBox(width: 8),
              Text(
                picked ? 'Selected' : 'Select',
                style: Type.button.copyWith(fontSize: 14, color: picked ? ds.onAccent : Colors.white),
              ),
              if (picked) ...[
                const SizedBox(width: 6),
                Icon(LucideIcons.check, size: 14, color: ds.onAccent),
              ],
            ],
          ),
        ),
      );
    },
  );
}
