import 'dart:async';
import 'dart:ui' as ui;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/services/exif.dart';
import '../../../data/services/image_decode.dart';
import '../../../data/services/image_sniff.dart';
import '../../../data/services/photo_export.dart';
import '../../../data/services/remote_files.dart';
import '../files/file_kind.dart';
import 'photo_item.dart';

/// The longest side the sharpening decode may make, in pixels. 4096 x 3072 is
/// 48 MB of bitmap: a full 12 MP photo, and the most the viewer holds beyond
/// the screen-sized bitmap.
const photoSharpSide = 4096;

/// The first bitmap is made to fit this many times the screen's pixels (per
/// side): sharp at fit and a little beyond, a few MB.
const photoBaseFactor = 1.5;

/// Why a picture is not shown.
enum PhotoFailureKind { tooLarge, notAnImage, network, unreadable }

class PhotoFailure {
  const PhotoFailure(this.kind, this.message, {this.retryable = false});

  final PhotoFailureKind kind;
  final String message;

  /// Trying again can help (the link dropped); for a damaged file it cannot.
  final bool retryable;
}

/// One picture's load and what came of it: bytes arriving, the bitmap, the
/// EXIF, or why there is none. Held by the viewer's model while the picture is
/// the current one or its neighbour.
class PhotoEntry extends ChangeNotifier {
  PhotoEntry._(this.item);

  final PhotoItem item;

  var _received = 0;
  var _decoding = false;
  var _sharpening = false;
  DecodedImage? _image;
  DecodedImage? _sharp;
  ui.Image? _placeholder;
  ExifInfo? _exif;
  var _transparent = false;
  Uint8List? _bytes;
  PhotoFailure? _failure;
  ReadCancel? _cancel;
  Future<void>? _loading;
  var _disposed = false;
  ({int done, int total})? _exporting;

  /// Bytes read so far.
  int get received => _received;

  /// The size to expect, when known.
  int? get total => item.size;

  /// The bytes are in and the bitmap is being made.
  bool get decoding => _decoding;

  /// The bitmap at the size of the screen (and the file's own size, which the
  /// bitmap may be smaller than), once decoded.
  DecodedImage? get image => _image;

  /// A bitmap sharper than [image], made while the person is zoomed in.
  DecodedImage? get sharp => _sharp;

  /// What to draw: the sharpest bitmap there is.
  ui.Image? get shown => _sharp?.image ?? _image?.image;

  /// A thumbnail to show until [image] exists.
  ui.Image? get placeholder => _placeholder;

  ExifInfo? get exif => _exif;
  bool get mayBeTransparent => _transparent;
  PhotoFailure? get failure => _failure;
  bool get ready => _image != null;
  bool get loading => _image == null && _failure == null;

  /// The compressed file, kept while the picture is near the one on screen
  /// (saving, sharing and the sharpening decode need it).
  Uint8List? get bytes => _bytes;

  /// A share of a file too large for memory is being prepared: bytes written
  /// of the total.
  ({int done, int total})? get exporting => _exporting;

  /// The picture's size as it is meant to be seen, once decoded.
  Size? get nativeSize => _image == null ? null : Size(_image!.width.toDouble(), _image!.height.toDouble());

  /// The file's format ("JPEG"), from its first bytes.
  String? get format {
    final b = _bytes;
    if (b == null) return null;
    final type = sniffSignature(b);
    if (type != null && type.kind == FileKind.image) return type.label.replaceAll(' image', '');
    return null;
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _releaseBitmaps() {
    _image?.dispose();
    _sharp?.dispose();
    _placeholder?.dispose();
    _image = null;
    _sharp = null;
    _placeholder = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel?.cancel();
    _releaseBitmaps();
    _bytes = null;
    super.dispose();
  }
}

/// What a save or a share came to, for the toast.
class PhotoActionResult {
  const PhotoActionResult.ok(this.message) : ok = true;
  const PhotoActionResult.failed(this.message) : ok = false;

  final bool ok;
  final String message;
}

/// The pictures of one viewer and which one is open.
///
/// Only the open picture and its two neighbours hold anything: the open one is
/// read first, then the next (or the previous, when the person is going
/// backwards) and then the other, one read at a time so a slow link is not
/// shared three ways; a neighbour over [photoPreloadLimit] waits until the
/// person gets to it. Moving on cancels the reads of pictures that are no
/// longer neighbours and frees their bitmaps.
class PhotoViewerViewModel extends ChangeNotifier {
  PhotoViewerViewModel({
    required List<PhotoItem> items,
    int initialIndex = 0,
    this._decoder = decodeImageFit,
    this._exifReader = readExif,
    PhotoExport? export,
    this.sharpSide = photoSharpSide,
    this.preloadLimit = photoPreloadLimit,
  }) : _items = List.of(items),
       export = export ?? const DevicePhotoExport(),
       _index = items.isEmpty ? 0 : initialIndex.clamp(0, items.length - 1) {
    if (_items.isNotEmpty) _ensure(_index);
  }

  final FitDecoder _decoder;
  final ExifInfo? Function(Uint8List) _exifReader;
  final PhotoExport export;

  /// See [photoSharpSide].
  final int sharpSide;
  final int preloadLimit;

  List<PhotoItem> _items;
  int _index;
  var _direction = 1;
  final _entries = <String, PhotoEntry>{};
  final _viewport = Completer<void>();
  var _boxW = 1920;
  var _boxH = 1920;
  var _disposed = false;

  List<PhotoItem> get items => _items;
  int get count => _items.length;
  int get index => _index;
  PhotoItem get current => _items[_index];
  bool get hasPrevious => _index > 0;
  bool get hasNext => _index < _items.length - 1;

  /// The entry of picture [i]; null when it is not a neighbour of the open one
  /// (nothing is held for it).
  PhotoEntry? entryAt(int i) => i < 0 || i >= _items.length ? null : _entries[_items[i].id];

  PhotoEntry get currentEntry => _entries[current.id]!;

  /// The screen the pictures are drawn on: the first decode waits for this, so
  /// it makes a bitmap for this screen and not for a guess.
  void setViewport(Size logical, double devicePixelRatio) {
    if (logical.isEmpty) return;
    _boxW = (logical.width * devicePixelRatio * photoBaseFactor).round();
    _boxH = (logical.height * devicePixelRatio * photoBaseFactor).round();
    if (!_viewport.isCompleted) _viewport.complete();
  }

  /// Makes picture [i] the open one: loads it, then its neighbours, and lets
  /// go of every other.
  void goTo(int i) {
    if (_items.isEmpty) return;
    final to = i.clamp(0, _items.length - 1);
    if (to == _index) return;
    _direction = to > _index ? 1 : -1;
    _index = to;
    _ensure(_index);
    _trim();
    // The open photo may be held already (it was a neighbour): its neighbours
    // still need reading ahead.
    _startNeighbours();
    notifyListeners();
  }

  /// Replaces the list (the rest of the folder arrived) keeping the open
  /// picture where it is, found by id. A list that lacks the open picture is
  /// ignored.
  void setItems(List<PhotoItem> items) {
    final id = current.id;
    final at = items.indexWhere((e) => e.id == id);
    if (at < 0) return;
    _items = List.of(items);
    _index = at;
    _trim();
    _startNeighbours();
    notifyListeners();
  }

  /// Reads the open picture again after a failure.
  void retry() {
    final entry = currentEntry;
    if (entry._failure == null) return;
    entry._failure = null;
    entry._received = 0;
    entry._loading = null;
    entry._changed();
    _ensure(_index);
  }

  PhotoEntry _ensure(int i) {
    final item = _items[i];
    final entry = _entries.putIfAbsent(item.id, () {
      final e = PhotoEntry._(item);
      e._placeholder = item.placeholder?.call();
      return e;
    });
    entry._loading ??= _load(entry);
    return entry;
  }

  /// Entries outside the open picture's neighbourhood are cancelled and freed.
  void _trim() {
    final keep = {for (var i = _index - 1; i <= _index + 1; i++) if (i >= 0 && i < _items.length) _items[i].id};
    for (final id in _entries.keys.toList()) {
      if (keep.contains(id)) continue;
      _entries.remove(id)!.dispose();
    }
    // A sharpened bitmap is only for the picture being looked at.
    for (final e in _entries.values) {
      if (!identical(e, currentEntry) && e._sharp != null) {
        e._sharp!.dispose();
        e._sharp = null;
        e._changed();
      }
    }
  }

  /// The neighbours load one after the other, after the open picture, the one
  /// the person is heading towards first.
  void _startNeighbours() {
    final open = _entries[current.id];
    if (open == null || open.loading) return;
    // One preload at a time: a slow link is not shared three ways.
    if (_entries.values.any((e) => !identical(e, open) && e._loading != null && e.loading)) return;
    for (final i in [_index + _direction, _index - _direction]) {
      if (i < 0 || i >= _items.length) continue;
      final held = _entries[_items[i].id];
      if (held?._loading != null) continue;
      final size = _items[i].size;
      if (size != null && size > preloadLimit) continue;
      _ensure(i);
      return;
    }
  }

  Future<void> _load(PhotoEntry entry) async {
    final cancel = ReadCancel();
    entry._cancel = cancel;
    try {
      final bytes = await entry.item.source.read(
        cancel: cancel,
        onProgress: (n) {
          entry._received = n;
          entry._changed();
        },
      );
      if (entry._disposed || cancel.cancelled) return;
      entry._bytes = bytes;
      entry._decoding = true;
      entry._changed();
      await _viewport.future;
      final image = await _decoder(bytes, maxWidth: _boxW, maxHeight: _boxH);
      if (entry._disposed || cancel.cancelled) {
        image.dispose();
        return;
      }
      entry._image = image;
      entry._decoding = false;
      entry._transparent = mayHaveTransparency(bytes);
      try {
        entry._exif = _exifReader(bytes);
      } on Object {
        // Info is a bonus: a picture with unreadable EXIF is still a picture.
      }
      entry._placeholder?.dispose();
      entry._placeholder = null;
    } on ReadCancelled {
      return;
    } on RemoteFileException catch (e) {
      if (entry._disposed) return;
      entry._failure = _describe(e);
    } on PhotoSourceException catch (e) {
      if (entry._disposed) return;
      entry._failure = PhotoFailure(e.tooLarge ? PhotoFailureKind.tooLarge : PhotoFailureKind.unreadable, e.message);
    } on Object {
      if (entry._disposed || cancel.cancelled) return;
      entry._decoding = false;
      entry._bytes = null;
      entry._failure = const PhotoFailure(
        PhotoFailureKind.notAnImage,
        "This file can't be shown as a picture. It may be damaged, or in a format Android does not read.",
      );
    }
    entry._changed();
    if (!_disposed && !entry._disposed) _startNeighbours();
    if (!_disposed) notifyListeners();
  }

  PhotoFailure _describe(RemoteFileException e) => switch (e.kind) {
    RemoteFileErrorKind.tooLarge => PhotoFailure(PhotoFailureKind.tooLarge, e.message),
    RemoteFileErrorKind.network => PhotoFailure(PhotoFailureKind.network, e.message, retryable: true),
    RemoteFileErrorKind.failed => PhotoFailure(PhotoFailureKind.unreadable, e.message, retryable: !e.fatal),
    RemoteFileErrorKind.notFound => PhotoFailure(
      PhotoFailureKind.unreadable,
      'This photo is no longer there. It may have been moved or deleted.',
    ),
    RemoteFileErrorKind.permission => PhotoFailure(
      PhotoFailureKind.unreadable,
      "Your login on this machine isn't allowed to read this photo.",
    ),
    _ => PhotoFailure(PhotoFailureKind.unreadable, e.message),
  };

  /// Makes a sharper bitmap of the open picture, for a person zoomed in past
  /// what the screen-sized one holds. Does nothing when the first bitmap
  /// already has all the file's pixels, the bytes are gone, or one is being
  /// made.
  Future<void> sharpen() async {
    final entry = currentEntry;
    final base = entry._image;
    final bytes = entry._bytes;
    if (base == null || bytes == null || !base.downscaled || entry._sharp != null || entry._sharpening) return;
    entry._sharpening = true;
    try {
      final sharp = await _decoder(bytes, maxWidth: sharpSide, maxHeight: sharpSide);
      // Moved on, or no more pixels than the base: not worth keeping.
      if (entry._disposed || !identical(entry, _entries[current.id]) || sharp.image.width <= base.image.width) {
        sharp.dispose();
        return;
      }
      entry._sharp = sharp;
      entry._changed();
    } on Object {
      // The base bitmap stays: blurry beats broken.
    } finally {
      entry._sharpening = false;
    }
  }

  /// Gives back the sharpened bitmap of the open picture (the person zoomed
  /// out again).
  void releaseSharp() {
    final entry = currentEntry;
    final sharp = entry._sharp;
    if (sharp == null) return;
    entry._sharp = null;
    entry._changed();
    sharp.dispose();
  }

  /// Saves the open picture to the gallery.
  Future<PhotoActionResult> save() async {
    final entry = currentEntry;
    final bytes = entry._bytes;
    if (bytes == null) return const PhotoActionResult.failed('The picture is not loaded yet.');
    try {
      await export.saveToGallery(bytes, name: entry.item.name);
      return const PhotoActionResult.ok('Saved to Pictures/herdr');
    } on PhotoExportException catch (e) {
      return PhotoActionResult.failed(e.message);
    }
  }

  /// Opens the share sheet with the open picture.
  Future<PhotoActionResult> share() async {
    final entry = currentEntry;
    final bytes = entry._bytes;
    if (bytes == null) return const PhotoActionResult.failed('The picture is not loaded yet.');
    try {
      await export.share(bytes, name: entry.item.name);
      return const PhotoActionResult.ok('');
    } on PhotoExportException catch (e) {
      return PhotoActionResult.failed(e.message);
    }
  }

  /// Whether the open picture can be shared without being opened (a file that
  /// can be read by range, such as one over [photoReadCap]).
  bool get canShareLarge => current.source is RangedPhotoSource && current.size != null;

  /// Copies the open file to the phone in pieces and shares that copy. For a
  /// picture the viewer refuses to open.
  Future<PhotoActionResult> shareLarge() async {
    final entry = currentEntry;
    final source = entry.item.source;
    final size = entry.item.size;
    if (source is! RangedPhotoSource || size == null) {
      return const PhotoActionResult.failed('This picture cannot be shared from here.');
    }
    if (entry._exporting != null) return const PhotoActionResult.ok('');
    entry._exporting = (done: 0, total: size);
    entry._changed();
    try {
      await export.shareLarge(
        name: entry.item.name,
        size: size,
        read: source.readRange,
        chunk: photoReadChunk,
        cancelled: () => entry._disposed,
        onProgress: (n) {
          entry._exporting = (done: n, total: size);
          entry._changed();
        },
      );
      return const PhotoActionResult.ok('');
    } on PhotoExportException catch (e) {
      return PhotoActionResult.failed(e.message);
    } on RemoteFileException catch (e) {
      return PhotoActionResult.failed(e.message);
    } finally {
      entry._exporting = null;
      entry._changed();
    }
  }

  /// "Photo 3 of 12".
  String get positionLabel => count > 1 ? 'Photo ${_index + 1} of $count' : 'Photo';

  /// How many entries hold a bitmap or a read right now (a test's window on
  /// the memory bound).
  @visibleForTesting
  int get heldEntries => _entries.length;

  @override
  void dispose() {
    _disposed = true;
    for (final e in _entries.values) {
      e.dispose();
    }
    _entries.clear();
    super.dispose();
  }
}
