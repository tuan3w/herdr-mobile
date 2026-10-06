import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../data/models/remote_file.dart';
import '../../../data/services/remote_files.dart';
import '../files/file_format.dart';

/// The most the viewer reads of one picture. A 12 MP phone photo is 3-8 MB and
/// a raw-ish export 20-30 MB; past this a person is better served by sharing
/// the file to an app made for it ([PhotoViewerViewModel.shareLarge]).
const photoReadCap = 40 * 1024 * 1024;

/// One read of a remote picture asks for this much: small enough that the
/// progress moves and a dropped link wastes little, large enough that the
/// open/close of each SFTP read does not dominate.
const photoReadChunk = 2 * 1024 * 1024;

/// Pictures larger than this are not fetched ahead of the person arriving at
/// them (the neighbours of the one on screen).
const photoPreloadLimit = 12 * 1024 * 1024;

/// Where one picture's bytes come from.
abstract interface class PhotoSource {
  /// The size in bytes when it is known before reading.
  int? get size;

  /// All the bytes. [onProgress] hears the bytes received so far; a [cancel]
  /// that fires ends the read with [ReadCancelled]. Throws
  /// [RemoteFileException] for what a person can be told (not found, too
  /// large, connection lost).
  Future<Uint8List> read({void Function(int received)? onProgress, ReadCancel? cancel});
}

/// A picture that cannot be read for a reason the person is told as it is
/// (not valid base64, too large to show here).
class PhotoSourceException implements Exception {
  const PhotoSourceException(this.message, {this.tooLarge = false});

  final String message;
  final bool tooLarge;

  @override
  String toString() => message;
}

/// A source that can also hand out any range of the file, which is what lets
/// a picture over [photoReadCap] be shared without being held in memory.
abstract interface class RangedPhotoSource implements PhotoSource {
  Future<Uint8List> readRange(int offset, int length);
}

/// A picture in a file on the machine, read over SFTP in [photoReadChunk]
/// pieces. Over [photoReadCap] it is refused before a byte is read.
class RemotePhotoSource implements RangedPhotoSource {
  RemotePhotoSource(this._files, this.path, {required this.size, this.cap = photoReadCap});

  final RemoteFiles _files;
  final String path;
  final int cap;

  @override
  final int? size;

  @override
  Future<Uint8List> read({void Function(int received)? onProgress, ReadCancel? cancel}) async {
    // A listing or a link can leave the size unknown: ask once.
    final known = size ?? (await _files.stat(path)).size;
    if (known == null || known <= 0) {
      throw RemoteFileException(RemoteFileErrorKind.failed, 'The file is empty.', path: path, fatal: true);
    }
    if (known > cap) {
      throw RemoteFileException(
        RemoteFileErrorKind.tooLarge,
        'This photo is ${formatBytes(known)}. The viewer opens photos up to ${formatBytes(cap)}.',
        path: path,
        fatal: true,
      );
    }
    return _files.readAll(path, size: known, chunk: photoReadChunk, onProgress: onProgress, cancel: cancel);
  }

  @override
  Future<Uint8List> readRange(int offset, int length) => _files.read(path, offset: offset, length: length);
}

/// A picture whose bytes are already here (an agent's inline picture, a
/// picture attached to a message): [load] produces them, off the main isolate
/// when that is worth it.
class MemoryPhotoSource implements PhotoSource {
  MemoryPhotoSource(this._load, {this.size});

  final Future<Uint8List> Function() _load;

  @override
  final int? size;

  @override
  Future<Uint8List> read({void Function(int received)? onProgress, ReadCancel? cancel}) async {
    final bytes = await _load();
    if (cancel?.cancelled ?? false) throw const ReadCancelled();
    onProgress?.call(bytes.length);
    return bytes;
  }
}

/// A picture the viewer can show, and what is known about it before it is
/// read.
class PhotoItem {
  const PhotoItem({
    required this.id,
    required this.name,
    required this.source,
    this.path,
    this.modified,
    this.mime,
    this.origin,
    this.placeholder,
  });

  /// Unique within one viewer (a path, a block's identity): entries are kept
  /// by it when the list of pictures changes underneath.
  final String id;

  /// What it is called: a file name, or what the agent named it.
  final String name;

  final PhotoSource source;

  /// The full path on the machine, for a file.
  final String? path;

  final DateTime? modified;
  final String? mime;

  /// Where a picture from a conversation came from ("Sent by omp · Read
  /// screenshot.png"); null for a file.
  final String? origin;

  /// A small copy to show while the picture loads: returns a clone the caller
  /// owns and disposes, or null when there is none (yet).
  final ui.Image? Function()? placeholder;

  int? get size => source.size;
}
