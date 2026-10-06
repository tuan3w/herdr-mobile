import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../data/repositories/attach_upload.dart';
import '../../../data/repositories/recent_phone_files.dart';
import '../../../data/services/phone_files.dart';
import '../../../data/services/phone_gallery.dart';
import '../../../data/services/thumb_cache.dart';
import '../../../data/repositories/agent_session.dart';
import 'gallery_model.dart';
import 'gallery_thumb.dart' show galleryThumbProvider;

/// The tabs of the sheet, in the order of the tab bar.
enum AttachTab { gallery, files, host }

/// Everything the attach sheet needs that outlives one opening of it: the
/// phone's library, its thumbnail cache, the picker for files of the phone,
/// the list of recent ones, and how a file reaches a session's host.
///
/// One per app run ([AttachKit.device]); tests build their own with fakes.
/// The gallery's state and the thumbnails stay here, so the second opening
/// of the sheet draws pictures on its first frame.
class AttachKit {
  AttachKit({
    required this.gallery,
    required this.files,
    required this.recents,
    required this.uploaderFor,
    ThumbCache? thumbs,
    bool Function()? foreground,
  }) : thumbs =
           thumbs ??
           ThumbCache(
             load: (a) => gallery.thumbnail(a),
             // The decoded bitmap goes with the bytes: the image cache holds
             // as many thumbnails as this one does, not a thousand.
             onEvict: (id, bytes) => unawaited(galleryThumbProvider(bytes).evict()),
           ) {
    galleryModel = GalleryModel(gallery, this.thumbs, foreground: foreground);
  }

  final PhoneGallery gallery;
  final PhoneFilePicker files;
  final RecentPhoneFiles recents;
  final ThumbCache thumbs;
  late final GalleryModel galleryModel;

  /// How a file of the phone reaches [session]'s host.
  final AttachUploader Function(AgentSessionView session) uploaderFor;

  /// The tab shown first the next time: the last one used in this app run.
  AttachTab tab = AttachTab.gallery;

  static AttachKit? _device;

  /// The phone's own services, built on first use.
  static AttachKit device() => _device ??= _build();

  static AttachKit _build() {
    final gallery = PhotoManagerGallery();
    final kit = AttachKit(
      gallery: gallery,
      files: const DevicePhoneFilePicker(),
      recents: RecentPhoneFiles(PrefsRecentPhoneFilesStore()),
      uploaderFor: (s) => HostUploader(machine: s.machine, sessionKey: s.key),
      foreground: () {
        final state = WidgetsBinding.instance.lifecycleState;
        return state == null || state == AppLifecycleState.resumed;
      },
    );
    WidgetsBinding.instance.addObserver(_MemoryPressure(kit.thumbs));
    return kit;
  }
}

/// Gives the thumbnails back when the system asks for memory.
class _MemoryPressure with WidgetsBindingObserver {
  _MemoryPressure(this._thumbs);

  final ThumbCache _thumbs;

  @override
  void didHaveMemoryPressure() => _thumbs.clear();
}
