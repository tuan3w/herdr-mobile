import 'dart:async';
import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';

/// What the app may read of the phone's pictures.
enum GalleryAccess {
  /// Never asked (or the answer is not known yet).
  undetermined,

  /// Every picture.
  granted,

  /// Android 14's "selected photos": only what the person chose last time.
  limited,

  /// Refused, or revoked in Settings.
  denied,

  /// The plugin failed (no MediaStore, a platform error): the system picker
  /// is the way to pick a photo.
  unavailable;

  bool get canRead => this == granted || this == limited;
}

/// One picture in the phone's library, as much as the grid and the tray need.
/// The bytes come from [PhoneGallery.thumbnail] and [PhoneGallery.file].
class GalleryAsset {
  const GalleryAsset({required this.id, required this.createdAt, this.name, this.width = 0, this.height = 0});

  /// The MediaStore id: stable across launches.
  final String id;
  final DateTime createdAt;

  /// `IMG_2031.jpg` when the store has it.
  final String? name;
  final int width;
  final int height;

  @override
  bool operator ==(Object other) => other is GalleryAsset && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// An album: `Recent` (everything, newest first), `Screenshots`, `Camera`...
class GalleryAlbum {
  const GalleryAlbum({required this.id, required this.name, required this.count, this.isRecent = false});

  final String id;
  final String name;
  final int count;

  /// The album that holds every picture.
  final bool isRecent;
}

/// A picture's original, as a file on the phone.
class GalleryFile {
  const GalleryFile({required this.path, required this.name, required this.size});

  final String path;
  final String name;
  final int size;
}

/// The phone's picture library. A small interface so a widget test hands the
/// sheet a library without the plugin (which needs a phone).
///
/// Nothing here blocks the UI isolate: every call is a platform-channel
/// round trip served by the plugin's own threads. Failures other than a
/// refused permission surface as [GalleryAccess.unavailable] or a null/empty
/// answer, never as an exception the caller must catch.
abstract interface class PhoneGallery {
  /// The permission as it stands. Never shows a dialog.
  Future<GalleryAccess> access();

  /// Asks the system for the permission (the dialog shows once; later calls
  /// answer from the system's memory).
  Future<GalleryAccess> request();

  /// The albums, `Recent` first. Only `Recent` when [onlyRecent].
  Future<List<GalleryAlbum>> albums({bool onlyRecent = false});

  /// Pictures [start] up to [start] + [count] of [albumId], newest first.
  Future<List<GalleryAsset>> assets(String albumId, {required int start, required int count});

  /// A JPEG of at most [size] px a side, from MediaStore's own thumbnail
  /// cache; null when the picture is gone or cannot be read.
  Future<Uint8List?> thumbnail(GalleryAsset asset, {int size = 240});

  /// The original as a file on the phone (a cache copy on newer Androids);
  /// null when it is gone or cannot be read.
  Future<GalleryFile?> file(GalleryAsset asset);

  /// Re-opens the system's selector for Android 14's partial access.
  Future<void> manageSelection();

  /// The app's page in the system settings (to allow after a refusal).
  Future<void> openSettings();

  /// Gives back the cache copies [file] made.
  Future<void> clearFileCache();
}

/// [PhoneGallery] over `photo_manager` (MediaStore on Android).
///
/// Chosen over `gallery_picker`/`image_gallery_saver`-style packages and
/// `PHPicker` look-alikes because it is the maintained plugin that serves
/// paged queries, albums, MediaStore's own thumbnails, limited access
/// (`READ_MEDIA_VISUAL_USER_SELECTED`) and Android 13+ granular permissions.
class PhotoManagerGallery implements PhoneGallery {
  PhotoManagerGallery();

  static const _permission = PermissionRequestOption(
    androidPermission: AndroidPermission(type: RequestType.image, mediaLocation: false),
  );

  static final _filter = FilterOptionGroup(orders: const [OrderOption()]);

  final _paths = <String, AssetPathEntity>{};
  final _entities = <String, AssetEntity>{};

  static GalleryAccess _map(PermissionState s) => switch (s) {
    PermissionState.authorized => GalleryAccess.granted,
    PermissionState.limited => GalleryAccess.limited,
    PermissionState.notDetermined => GalleryAccess.undetermined,
    PermissionState.denied || PermissionState.restricted => GalleryAccess.denied,
  };

  @override
  Future<GalleryAccess> access() async {
    try {
      return _map(await PhotoManager.getPermissionState(requestOption: _permission));
    } on Object {
      return GalleryAccess.unavailable;
    }
  }

  @override
  Future<GalleryAccess> request() async {
    try {
      return _map(await PhotoManager.requestPermissionExtend(requestOption: _permission));
    } on Object {
      return GalleryAccess.unavailable;
    }
  }

  @override
  Future<List<GalleryAlbum>> albums({bool onlyRecent = false}) async {
    try {
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        onlyAll: onlyRecent,
        filterOption: _filter,
      );
      final out = <GalleryAlbum>[];
      for (final p in paths) {
        final count = await p.assetCountAsync;
        if (count == 0 && !p.isAll) continue;
        _paths[p.id] = p;
        out.add(GalleryAlbum(id: p.id, name: p.isAll ? 'Recent' : p.name, count: count, isRecent: p.isAll));
      }
      out.sort((a, b) => a.isRecent == b.isRecent ? b.count.compareTo(a.count) : (a.isRecent ? -1 : 1));
      return out;
    } on Object {
      return const [];
    }
  }

  @override
  Future<List<GalleryAsset>> assets(String albumId, {required int start, required int count}) async {
    final path = _paths[albumId];
    if (path == null) return const [];
    try {
      final list = await path.getAssetListRange(start: start, end: start + count);
      return [
        for (final e in list)
          () {
            _entities[e.id] = e;
            return GalleryAsset(
              id: e.id,
              createdAt: e.createDateTime,
              name: e.title,
              width: e.width,
              height: e.height,
            );
          }(),
      ];
    } on Object {
      return const [];
    }
  }

  @override
  Future<Uint8List?> thumbnail(GalleryAsset asset, {int size = 240}) async {
    final e = _entities[asset.id];
    if (e == null) return null;
    try {
      return await e.thumbnailDataWithSize(ThumbnailSize.square(size), quality: 80);
    } on Object {
      return null;
    }
  }

  @override
  Future<GalleryFile?> file(GalleryAsset asset) async {
    final e = _entities[asset.id];
    if (e == null) return null;
    try {
      final f = await e.originFile;
      if (f == null) return null;
      final name = e.title ?? await e.titleAsync;
      return GalleryFile(path: f.path, name: name, size: await f.length());
    } on Object {
      return null;
    }
  }

  @override
  Future<void> manageSelection() async {
    try {
      await PhotoManager.presentLimited(type: RequestType.image);
    } on Object {
      // The sheet re-reads the access afterwards, whatever happened.
    }
  }

  @override
  Future<void> openSettings() async {
    try {
      await PhotoManager.openSetting();
    } on Object {
      // Nothing to do: the sheet keeps offering the system picker.
    }
  }

  @override
  Future<void> clearFileCache() async {
    try {
      await PhotoManager.clearFileCache();
    } on Object {
      // A cache that stays is the system's to trim.
    }
  }
}
