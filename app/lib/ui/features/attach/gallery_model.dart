import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/services/phone_gallery.dart';
import '../../../data/services/thumb_cache.dart';

/// Assets are fetched in pages this big (one MediaStore query each).
const galleryPage = 120;

/// How many thumbnails are decoded ahead of the first frame.
const galleryWarmThumbs = 24;

/// The gallery tab's state: the permission, the albums, the pictures of the
/// album on show. One per app run (it lives in the `AttachKit`), so a second
/// opening of the sheet starts from what the first one loaded.
///
/// The grid does not rebuild when a page arrives: tiles whose picture was not
/// there yet listen to [revision] themselves. A change of access, album or
/// count notifies the model's own listeners (the tab's frame).
class GalleryModel extends ChangeNotifier {
  GalleryModel(this._gallery, this.thumbs, {bool Function()? foreground}) : _foreground = foreground ?? (() => true);

  final PhoneGallery _gallery;
  final ThumbCache thumbs;
  final bool Function() _foreground;

  GalleryAccess _access = GalleryAccess.undetermined;
  var _checked = false;
  var _albums = const <GalleryAlbum>[];
  GalleryAlbum? _album;
  var _assets = <GalleryAsset?>[];
  final _pagesLoading = <int>{};
  var _epoch = 0;
  var _disposed = false;
  var _loadingFirst = false;

  /// Bumped whenever pictures arrive; placeholder tiles listen to it.
  final revision = ValueNotifier<int>(0);

  PhoneGallery get gallery => _gallery;

  GalleryAccess get access => _access;

  /// The first answer about the permission is in (until then the tab draws its
  /// frame and the camera tile only).
  bool get checked => _checked;

  List<GalleryAlbum> get albums => _albums;
  GalleryAlbum? get album => _album;

  /// Pictures in the album on show.
  int get count => _album?.count ?? 0;

  /// The first page is on its way.
  bool get loading => _loadingFirst;

  /// The picture at [index], or null while its page is on the way.
  GalleryAsset? at(int index) => index >= 0 && index < _assets.length ? _assets[index] : null;

  /// Reads the permission without asking, and loads the first screenful when
  /// it is already given. The paperclip calls this on pointer-down and the
  /// composer on first show, so the sheet opens onto pictures. Never asks the
  /// system for anything and does nothing while the app is in the background.
  Future<void> warm() async {
    if (!_foreground() || _loadingFirst) return;
    if (_checked && !_access.canRead) return;
    if (_checked && _album != null && _assets.isNotEmpty) return;
    await _check(load: true);
  }

  /// The Gallery tab is on show: the same, and the answer reaches the tab.
  Future<void> open() async {
    if (_checked && _access.canRead && _album != null) return;
    await _check(load: true);
  }

  /// Asks the system (after the rationale was read).
  Future<void> request() async {
    final access = await _gallery.request();
    await _apply(access, load: true);
  }

  /// Opens the system settings page of the app; the access is read again when
  /// [recheck] is called on coming back.
  Future<void> openSettings() => _gallery.openSettings();

  /// Android 14's selector for partial access.
  Future<void> manage() async {
    await _gallery.manageSelection();
    _reset();
    await _check(load: true);
  }

  Future<void> recheck() async {
    final before = _access;
    final access = await _gallery.access();
    if (access != before || (access.canRead && _album == null)) await _apply(access, load: true);
  }

  Future<void> loadAlbums() async {
    final list = await _gallery.albums();
    if (_disposed || list.isEmpty) return;
    _albums = list;
    notifyListeners();
  }

  Future<void> selectAlbum(GalleryAlbum album) async {
    if (_album?.id == album.id) return;
    _epoch++;
    _album = album;
    _assets = List<GalleryAsset?>.filled(album.count, null, growable: false);
    _pagesLoading.clear();
    notifyListeners();
    revision.value++;
    await _loadPage(0);
  }

  /// Makes sure the page holding [index] is loaded or on its way.
  void ensure(int index) {
    if (_album == null || index < 0 || index >= _assets.length) return;
    if (_assets[index] != null) return;
    unawaited(_loadPage(index ~/ galleryPage));
  }

  /// Warms the thumbnails of the rows after [lastVisible] in the direction of
  /// travel (`1` forward, `-1` back), when no tile on screen waits.
  void prefetchAround(int lastVisible, {required int span, required int direction}) {
    final from = direction >= 0 ? lastVisible + 1 : lastVisible - span;
    final list = <GalleryAsset>[];
    for (var i = from; i < from + span; i++) {
      final a = at(i);
      if (a != null) list.add(a);
    }
    if (list.isNotEmpty) thumbs.prefetch(list);
  }

  void _reset() {
    _epoch++;
    _album = null;
    _assets = <GalleryAsset?>[];
    _pagesLoading.clear();
    thumbs.clear();
  }

  Future<void> _check({required bool load}) async {
    final access = await _gallery.access();
    await _apply(access, load: load);
  }

  Future<void> _apply(GalleryAccess access, {required bool load}) async {
    if (_disposed) return;
    final changed = access != _access || !_checked;
    _access = access;
    _checked = true;
    if (changed) notifyListeners();
    if (!access.canRead || !load) return;
    if (_album != null && _assets.isNotEmpty) return;
    _loadingFirst = true;
    final epoch = _epoch;
    final list = await _gallery.albums(onlyRecent: true);
    if (_disposed || epoch != _epoch) {
      _loadingFirst = false;
      return;
    }
    if (list.isEmpty) {
      _album = const GalleryAlbum(id: '', name: 'Recent', count: 0, isRecent: true);
      _assets = <GalleryAsset?>[];
      _loadingFirst = false;
      notifyListeners();
      return;
    }
    _albums = list;
    _album = list.first;
    _assets = List<GalleryAsset?>.filled(_album!.count, null, growable: false);
    notifyListeners();
    await _loadPage(0);
    _loadingFirst = false;
    if (!_disposed) notifyListeners();
    final warm = <GalleryAsset>[
      for (var i = 0; i < galleryWarmThumbs; i++) ?at(i),
    ];
    if (warm.isNotEmpty) thumbs.prefetch(warm);
  }

  Future<void> _loadPage(int page) async {
    final album = _album;
    if (album == null || !_pagesLoading.add(page)) return;
    final epoch = _epoch;
    final start = page * galleryPage;
    final list = await _gallery.assets(album.id, start: start, count: galleryPage);
    if (_disposed || epoch != _epoch) return;
    _pagesLoading.remove(page);
    for (var i = 0; i < list.length && start + i < _assets.length; i++) {
      _assets[start + i] = list[i];
    }
    revision.value++;
  }

  @override
  void dispose() {
    _disposed = true;
    revision.dispose();
    super.dispose();
  }
}
