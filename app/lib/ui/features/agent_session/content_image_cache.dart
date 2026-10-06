import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../../data/acp/acp_models.dart';
import '../../../data/services/image_decode.dart';
import '../files/file_format.dart';
import '../photos/photo_item.dart' show PhotoSourceException;

/// Picture bytes larger than this (after base64) are not decoded: a plain note
/// says so instead. The preview is shrunk while it is decoded, but the bytes
/// and the codec's work still cost memory and time.
const imageDecodeLimit = 12 * 1024 * 1024;

/// Longest side of an inline preview's bitmap, in pixels: sharp at the widest
/// inline size on a phone, a few MB at most. The viewer decodes its own, larger
/// one.
const imagePreviewDimension = 1024;

/// How many decoded previews [ImagePreviewCache] keeps once nothing shows them.
const imageCacheCapacity = 8;

/// Base64 text longer than this is decoded off the main isolate.
const _isolateFromChars = 64 * 1024;

/// A picture that cannot be drawn, in words for the person.
class ImageProblem implements Exception {
  const ImageProblem(this.note, {this.tooLarge = false});

  final String note;

  /// The picture is over [imageDecodeLimit] (as opposed to damaged).
  final bool tooLarge;

  @override
  String toString() => note;
}

/// Bytes the base64 [data] stands for, without decoding it.
int base64DecodedLength(String data) {
  var padding = 0;
  for (var i = data.length - 1; i >= 0 && data.codeUnitAt(i) == 0x3D; i--) {
    padding++;
  }
  final n = (data.length * 3) ~/ 4 - padding;
  return n < 0 ? 0 : n;
}

Uint8List _decodeBase64(String data) {
  try {
    return base64Decode(data);
  } on FormatException {
    // MIME-style base64 wraps its lines.
    return base64Decode(data.replaceAll(RegExp(r'\s'), ''));
  }
}

/// The bytes of base64 [data]. Throws [ImageProblem] when there is nothing, it
/// is bigger than [imageDecodeLimit], or it is not base64. Long text is decoded
/// in another isolate.
Future<Uint8List> decodeImageData(String data) async {
  if (data.isEmpty) throw const ImageProblem('The agent sent no picture data.');
  final size = base64DecodedLength(data);
  if (size > imageDecodeLimit) {
    throw ImageProblem('Too large to show here (${formatBytes(size)}).', tooLarge: true);
  }
  try {
    return data.length > _isolateFromChars ? await compute(_decodeBase64, data) : _decodeBase64(data);
  } on Object {
    throw const ImageProblem('The picture data is not valid base64.');
  }
}

/// The bytes of [block] for the full-screen viewer; a picture that cannot be
/// read says why as a [PhotoSourceException].
Future<Uint8List> decodeImageDataFor(ImageBlock block) async {
  try {
    return await decodeImageData(block.data);
  } on ImageProblem catch (e) {
    throw PhotoSourceException(e.note, tooLarge: e.tooLarge);
  }
}

/// Decodes [block] into a bitmap whose longest side is at most [maxDimension].
/// Throws [ImageProblem] with the reason when it cannot.
Future<DecodedImage> decodeImageBlock(
  ImageBlock block, {
  int maxDimension = imagePreviewDimension,
  ImageDecoder decoder = decodeImageBytes,
}) async {
  final bytes = await decodeImageData(block.data);
  final DecodedImage image;
  try {
    image = await decoder(bytes, maxDimension: maxDimension);
  } on Object {
    final mime = block.mimeType.isEmpty ? 'this format' : block.mimeType;
    throw ImageProblem('The picture is not an image this app can read ($mime).');
  }
  if (image.width <= 0 || image.height <= 0) {
    image.dispose();
    throw const ImageProblem('The picture is empty (0 × 0).');
  }
  return image;
}

/// One block's preview: loading, then a bitmap or the reason there is none.
///
/// Held by the widgets that draw it ([ImagePreviewCache.acquire] /
/// [ImagePreviewCache.release]); the bitmap is disposed when the cache lets go
/// of the entry, never while something draws it.
class ImageEntry extends ChangeNotifier {
  ImageEntry._(this.block);

  final ImageBlock block;
  DecodedImage? _image;
  String? _problem;
  var _refs = 0;
  var _gone = false;

  /// The bitmap, once decoded.
  DecodedImage? get image => _image;

  /// Why there is no bitmap, once it is known.
  String? get problem => _problem;

  bool get loading => _image == null && _problem == null;

  void _finish(DecodedImage? image, String? problem) {
    if (_gone) {
      image?.dispose();
      return;
    }
    _image = image;
    _problem = problem;
    notifyListeners();
  }

  void _drop() {
    _gone = true;
    _image?.dispose();
    _image = null;
    dispose();
  }
}

/// Decoded previews by block identity, least recently used first out.
///
/// A transcript of 200 images builds a few rows at a time, and each row holds
/// its entry only while it is built; an entry nobody holds is kept (so scrolling
/// back is instant) until more than [capacity] are kept, then the oldest is
/// disposed. Entries somebody draws are never dropped, so the bound is
/// `capacity` plus what is on screen.
class ImagePreviewCache {
  ImagePreviewCache({this.capacity = imageCacheCapacity, this._decoder = decodeImageBytes});

  /// The cache the transcript uses.
  static ImagePreviewCache shared = ImagePreviewCache();

  final int capacity;
  final ImageDecoder _decoder;
  final _entries = LinkedHashMap<ImageBlock, ImageEntry>.identity();

  /// Entries kept, loading and failed ones included.
  int get length => _entries.length;

  /// Entries that hold a bitmap right now.
  int get bitmaps => _entries.values.where((e) => e.image != null).length;

  /// The entry of [block] (decoding starts at the first call), most recently
  /// used. Pair with [release].
  ImageEntry acquire(ImageBlock block) {
    var entry = _entries.remove(block);
    if (entry == null) {
      entry = ImageEntry._(block);
      unawaited(_load(entry));
    }
    _entries[block] = entry;
    entry._refs++;
    _trim();
    return entry;
  }

  /// A copy of the preview of [block] (the caller disposes it) when one is
  /// decoded, else null: what the full-screen viewer shows while the picture
  /// loads. Does not start a decode and does not keep anything alive.
  ui.Image? cloneOf(ImageBlock block) => _entries[block]?._image?.image.clone();

  void release(ImageEntry entry) {
    entry._refs--;
    _trim();
  }

  Future<void> _load(ImageEntry entry) async {
    try {
      final image = await decodeImageBlock(entry.block, decoder: _decoder);
      entry._finish(image, null);
    } on ImageProblem catch (e) {
      entry._finish(null, e.note);
    } on Object {
      entry._finish(null, 'The picture could not be shown.');
    }
  }

  void _trim() {
    if (_entries.length <= capacity) return;
    for (final block in _entries.keys.toList()) {
      if (_entries.length <= capacity) break;
      final entry = _entries[block]!;
      if (entry._refs > 0) continue;
      _entries.remove(block);
      entry._drop();
    }
  }

  /// Disposes every entry (a test's end).
  @visibleForTesting
  void clear() {
    for (final entry in _entries.values) {
      entry._drop();
    }
    _entries.clear();
  }
}
