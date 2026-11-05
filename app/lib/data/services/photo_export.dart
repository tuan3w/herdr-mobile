import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// A save or share that did not happen, in words for the person.
class PhotoExportException implements Exception {
  const PhotoExportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What the person can do with a picture or a video outside the app: keep a
/// copy in the phone's gallery, or hand it to another app. A small interface so
/// a test checks what the viewer asks for without a platform channel.
abstract interface class PhotoExport {
  /// Puts the picture in the gallery, album `herdr` (Pictures/herdr on
  /// Android). Throws [PhotoExportException].
  Future<void> saveToGallery(Uint8List bytes, {required String name});

  /// Opens the system share sheet with the picture as a file called [name].
  /// Throws [PhotoExportException].
  Future<void> share(Uint8List bytes, {required String name});

  /// Puts a video file in the gallery, album `herdr` (Pictures/herdr on
  /// Android). The file stays where it is. Throws [PhotoExportException].
  Future<void> saveVideoToGallery(File file);

  /// Opens the system share sheet with a file that is already on the phone. The
  /// file is not removed, but on Android `share_plus` first copies it into its
  /// own cache folder, so a big file needs its size free once more until the
  /// next share. Throws [PhotoExportException].
  Future<void> shareFile(File file);

  /// Shares a file too big to hold in memory: [read] is asked for pieces of at
  /// most [chunk] bytes, which are appended to a file in the cache directory
  /// (so memory stays flat), and that file is shared; it is removed by the next
  /// share.
  /// [onProgress] hears the bytes written. A [cancelled] that turns true stops
  /// the copy. Throws [PhotoExportException].
  Future<void> shareLarge({
    required String name,
    required int size,
    required Future<Uint8List> Function(int offset, int length) read,
    required int chunk,
    void Function(int written)? onProgress,
    bool Function()? cancelled,
  });
}

/// The folder in the gallery the viewer saves into.
const photoAlbum = 'herdr';

/// The phone's gallery through `gal` (MediaStore on Android: no storage
/// permission from Android 10 on) and its share sheet through `share_plus`.
class DevicePhotoExport implements PhotoExport {
  const DevicePhotoExport();

  @override
  Future<void> saveToGallery(Uint8List bytes, {required String name}) =>
      _intoGallery('picture', () => Gal.putImageBytes(bytes, album: photoAlbum, name: _stem(name)));

  @override
  Future<void> saveVideoToGallery(File file) => _intoGallery('video', () => Gal.putVideo(file.path, album: photoAlbum));

  /// Asks for the gallery (the album, so on Android 10+ no permission is
  /// needed), runs [put], and says in words what went wrong. [thing] is
  /// "picture" or "video".
  static Future<void> _intoGallery(String thing, Future<void> Function() put) async {
    try {
      if (!await Gal.hasAccess(toAlbum: true) && !await Gal.requestAccess(toAlbum: true)) {
        throw const PhotoExportException('Saving needs access to your photos. Allow it in the phone\u2019s settings.');
      }
      await put();
    } on PhotoExportException {
      rethrow;
    } on GalException catch (e) {
      throw PhotoExportException(switch (e.type) {
        GalExceptionType.accessDenied => 'Saving needs access to your photos. Allow it in the phone\u2019s settings.',
        GalExceptionType.notEnoughSpace => 'The phone is out of space.',
        GalExceptionType.notSupportedFormat => 'The gallery can’t keep this kind of $thing.',
        GalExceptionType.unexpected => 'The $thing couldn’t be saved.',
      });
    } on Object {
      throw PhotoExportException('The $thing couldn’t be saved.');
    }
  }

  @override
  Future<void> shareFile(File file) async {
    try {
      await _send(file);
    } on Object {
      throw const PhotoExportException('The share sheet couldn’t be opened.');
    }
  }

  @override
  Future<void> share(Uint8List bytes, {required String name}) async {
    try {
      final file = await _scratch(name);
      await file.writeAsBytes(bytes, flush: true);
      await _send(file);
    } on PhotoExportException {
      rethrow;
    } on Object {
      throw const PhotoExportException('The share sheet couldn’t be opened.');
    }
  }

  @override
  Future<void> shareLarge({
    required String name,
    required int size,
    required Future<Uint8List> Function(int offset, int length) read,
    required int chunk,
    void Function(int written)? onProgress,
    bool Function()? cancelled,
  }) async {
    try {
      final file = await _scratch(name);
      final sink = file.openWrite();
      var at = 0;
      try {
        while (at < size) {
          if (cancelled?.call() ?? false) return;
          final piece = await read(at, chunk < size - at ? chunk : size - at);
          if (piece.isEmpty) break;
          sink.add(piece);
          at += piece.length;
          onProgress?.call(at);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (cancelled?.call() ?? false) return;
      await _send(file);
    } on PhotoExportException {
      rethrow;
    } on FileSystemException {
      throw const PhotoExportException('The phone is out of space for a copy.');
    } on Object {
      throw const PhotoExportException('The file couldn’t be copied to the phone.');
    }
  }

  /// Opens the share sheet; how it ended (shared, dismissed, unknown) is not
  /// this app's business.
  static Future<void> _send(File file) async {
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
  }

  /// A fresh file in the cache directory's `photo_share` folder. The folder is
  /// emptied first: the file of the last share is kept until now because the
  /// app that received it may still be reading it when the sheet closes.
  static Future<File> _scratch(String name) async {
    final dir = await getTemporaryDirectory();
    final folder = Directory('${dir.path}/photo_share');
    try {
      if (await folder.exists()) await folder.delete(recursive: true);
    } on Object {
      // A stale copy is not worth failing a share for.
    }
    await folder.create(recursive: true);
    // The name is the remote file's: keep only what is safe in one path part.
    final safe = name.replaceAll(RegExp(r'[\\/\x00-\x1f]'), '_');
    return File('${folder.path}/${safe.isEmpty ? 'photo' : safe}');
  }

  /// `IMG_1.jpg` -> `IMG_1` (the gallery adds the extension itself).
  static String _stem(String name) {
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    return stem.isEmpty ? 'image' : stem;
  }
}
