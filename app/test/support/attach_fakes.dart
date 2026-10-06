import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:herdr_mobile/data/repositories/attach_upload.dart';
import 'package:herdr_mobile/data/repositories/recent_phone_files.dart';
import 'package:herdr_mobile/data/services/phone_files.dart';
import 'package:herdr_mobile/data/services/phone_gallery.dart';
import 'package:herdr_mobile/data/services/thumb_cache.dart';
import 'package:herdr_mobile/ui/features/attach/attach_kit.dart';
import 'package:image/image.dart' as img;

/// A small PNG: a thumbnail the engine can decode.
final Uint8List tinyPng = Uint8List.fromList(img.encodePng(img.Image(width: 16, height: 16)));

/// A small gradient picture, a different one per [seed]: what a shot test
/// shows as a photo.
Uint8List fakePicture(int seed, {int w = 96, int h = 96}) {
  final image = img.Image(width: w, height: h);
  for (final p in image) {
    final tx = p.x / w;
    final ty = p.y / h;
    p.setRgb(
      (40 + 190 * ((tx + seed * 0.13) % 1)).round(),
      (70 + 150 * ((ty + seed * 0.29) % 1)).round(),
      (200 - 120 * ((tx + ty) / 2) + seed * 7).round() % 256,
    );
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 70));
}

/// The phone's library, in memory: [count] pictures, newest first, named
/// `IMG_0001.jpg`... (one a minute back from [newest]).
class FakeGallery implements PhoneGallery {
  FakeGallery({
    this.count = 40,
    this.state = GalleryAccess.granted,
    this.afterRequest = GalleryAccess.granted,
    DateTime? newest,
    this.extraAlbums = const [],
  }) : newest = newest ?? DateTime(2026, 5, 20, 14, 2);

  int count;
  GalleryAccess state;

  /// What the system answers when asked.
  GalleryAccess afterRequest;
  final DateTime newest;
  final List<GalleryAlbum> extraAlbums;

  /// The picture drawn for an asset; a flat PNG when null.
  Uint8List Function(GalleryAsset asset)? picture;

  var requests = 0;
  var accessReads = 0;
  var albumQueries = 0;
  var pageQueries = 0;
  var thumbCalls = 0;
  var manageCalls = 0;
  var settingsCalls = 0;
  var cleared = 0;
  final thumbIds = <String>[];

  /// Files a test hands back for [file]; defaults to a fresh 1 KB temp file.
  final files = <String, GalleryFile>{};

  /// When set, `thumbnail` waits for it.
  Completer<void>? gate;

  @override
  Future<GalleryAccess> access() async {
    accessReads++;
    return state;
  }

  @override
  Future<GalleryAccess> request() async {
    requests++;
    state = afterRequest;
    return state;
  }

  GalleryAlbum get recent => GalleryAlbum(id: 'recent', name: 'Recent', count: count, isRecent: true);

  @override
  Future<List<GalleryAlbum>> albums({bool onlyRecent = false}) async {
    albumQueries++;
    return [recent, if (!onlyRecent) ...extraAlbums];
  }

  GalleryAsset assetAt(int i) => GalleryAsset(
    id: '${count - i}',
    createdAt: newest.subtract(Duration(minutes: i)),
    name: 'IMG_${(count - i).toString().padLeft(4, '0')}.jpg',
    width: 4000,
    height: 3000,
  );

  @override
  Future<List<GalleryAsset>> assets(String albumId, {required int start, required int count}) async {
    pageQueries++;
    final total = albumId == 'recent' ? this.count : extraAlbums.firstWhere((a) => a.id == albumId).count;
    return [for (var i = start; i < start + count && i < total; i++) assetAt(i)];
  }

  @override
  Future<Uint8List?> thumbnail(GalleryAsset asset, {int size = 240}) async {
    thumbCalls++;
    thumbIds.add(asset.id);
    if (gate != null) await gate!.future;
    return picture?.call(asset) ?? tinyPng;
  }

  @override
  Future<GalleryFile?> file(GalleryAsset asset) async {
    final known = files[asset.id];
    if (known != null) return known;
    final f = File('${Directory.systemTemp.path}/herdr_fake_${asset.id}.jpg')..writeAsBytesSync(List.filled(1024, 7));
    return GalleryFile(path: f.path, name: asset.name ?? 'photo.jpg', size: 1024);
  }

  @override
  Future<void> manageSelection() async => manageCalls++;

  @override
  Future<void> openSettings() async => settingsCalls++;

  @override
  Future<void> clearFileCache() async => cleared++;
}

/// Hands out the files a test queues, as the system picker would.
class FakePhoneFilePicker implements PhoneFilePicker {
  final queued = <List<PhoneFile>>[];
  Object? failure;
  var opened = 0;
  final released = <String>[];

  @override
  Future<List<PhoneFile>> pick() async {
    opened++;
    if (failure != null) throw failure!;
    return queued.isEmpty ? const [] : queued.removeAt(0);
  }

  @override
  Future<void> release(String path) async => released.add(path);
}

/// An upload a test drives by hand.
class FakeUpload implements AttachUpload {
  FakeUpload(this.localPath, this.fileName, this.onProgress);

  final String localPath;
  final String fileName;
  final void Function(int sent, int total)? onProgress;
  final _done = Completer<String>();
  var cancelled = false;

  @override
  Future<String> get done => _done.future;

  void progress(int sent, int total) => onProgress?.call(sent, total);

  void finish([String? remote]) => _done.complete(remote ?? '/home/dev/.herdr-mobile/inbox/abc/2026-05-20-$fileName');

  void fail(Object error) => _done.completeError(error);

  @override
  void cancel() {
    cancelled = true;
    if (!_done.isCompleted) _done.completeError(StateError('cancelled'));
  }
}

class FakeUploader implements AttachUploader {
  final started = <FakeUpload>[];

  FakeUpload get last => started.last;

  @override
  AttachUpload start({required String localPath, required String fileName, void Function(int sent, int total)? onProgress}) {
    final u = FakeUpload(localPath, fileName, onProgress);
    started.add(u);
    return u;
  }
}

class MemoryRecentStore implements RecentPhoneFilesStore {
  MemoryRecentStore([List<RecentPhoneFile> initial = const []]) : files = [...initial];

  List<RecentPhoneFile> files;

  @override
  Future<List<RecentPhoneFile>> read() async => files;

  @override
  Future<void> write(List<RecentPhoneFile> files) async => this.files = [...files];
}

/// An [AttachKit] over fakes.
class FakeKit {
  FakeKit({FakeGallery? gallery, FakePhoneFilePicker? picker, FakeUploader? uploader, MemoryRecentStore? store, ThumbCache? thumbs})
    : gallery = gallery ?? FakeGallery(),
      picker = picker ?? FakePhoneFilePicker(),
      uploader = uploader ?? FakeUploader(),
      store = store ?? MemoryRecentStore() {
    kit = AttachKit(
      gallery: this.gallery,
      files: this.picker,
      recents: RecentPhoneFiles(this.store),
      uploaderFor: (_) => this.uploader,
      thumbs: thumbs,
    );
  }

  final FakeGallery gallery;
  final FakePhoneFilePicker picker;
  final FakeUploader uploader;
  final MemoryRecentStore store;
  late final AttachKit kit;
}
