import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../models/remote_file.dart';
import 'remote_files.dart';

/// How much of a file one read asks for: the piece that is in memory at a time.
const copyChunk = 2 * 1024 * 1024;

/// A file of a machine, copied whole to the phone's temporary folder so that a
/// player or another app can open it by path (a video cannot be played from
/// bytes in memory, and a share sheet takes files).
///
/// Not the `DiskCache`: that keeps small things (a picture is at most 12 MB, the
/// whole cache 192 MB) as bytes under a key, to read again. A video is hundreds
/// of MB and has to be a file with a path. So this is a staging place, like the
/// photo viewer's `photo_share` folder: it holds one file at a time. Before a new
/// copy starts, every other copy is removed, because a phone's storage is not
/// ours to fill with a library of videos. The file of the last copy stays until
/// then (the app that was given it may still be reading it) or until Android
/// empties its temporary folder, which a copy survives by being made again.
class RemoteFileStaging {
  /// [root] is the folder the copies live in; the default is `remote_files` in
  /// the app's cache directory.
  RemoteFileStaging({Future<Directory> Function()? root}) : _root = root ?? _defaultRoot;

  final Future<Directory> Function() _root;

  /// The copy that is running or waiting last. Copies run one after another,
  /// process-wide: two viewers on the same file would write the same `.part`, and
  /// one cancelling would delete the folder the other is filling.
  static Future<void> _line = Future.value();

  static Future<Directory> _defaultRoot() async => Directory('${(await getTemporaryDirectory()).path}/remote_files');

  /// The copy of [stat] on this phone, made now unless the same file (same
  /// machine, path, size and time) was copied whole before.
  ///
  /// [onProgress] hears the bytes written after every piece. A [cancel] that
  /// fires stops before the next piece with [ReadCancelled] and removes what was
  /// written. Throws [RemoteFileException]: whatever the reads say, `failed` when
  /// the phone is out of space, when the file shrank while it was copied, or
  /// when its size is not known.
  Future<File> fetch(RemoteFiles files, RemoteStat stat, {void Function(int written)? onProgress, ReadCancel? cancel}) {
    final turn = Completer<void>();
    final before = _line;
    _line = turn.future;
    return before
        .then((_) {
          // Cancelled while waiting for the one before: nothing was started.
          if (cancel?.cancelled ?? false) throw const ReadCancelled();
          return _fetch(files, stat, onProgress, cancel);
        })
        .whenComplete(turn.complete);
  }

  Future<File> _fetch(
    RemoteFiles files,
    RemoteStat stat,
    void Function(int written)? onProgress,
    ReadCancel? cancel,
  ) async {
    final size = stat.size;
    if (size == null) {
      throw RemoteFileException(
        RemoteFileErrorKind.failed,
        'The size of ${stat.name} isn’t known, so it can’t be copied.',
        path: stat.path,
      );
    }
    final root = await _root();
    final identity = '${files.machineId}\n${stat.path}\n$size\n${stat.modified?.millisecondsSinceEpoch}';
    final key = sha1.convert(utf8.encode(identity)).toString();
    final folder = Directory('${root.path}/$key');
    final target = File('${folder.path}/${_safe(stat.name)}');
    try {
      if (await target.exists() && await target.length() == size) {
        onProgress?.call(size);
        return target;
      }
      await _clearExcept(root, key);
      await folder.create(recursive: true);
      final part = File('${target.path}.part');
      final sink = part.openWrite();
      var at = 0;
      try {
        while (at < size) {
          if (cancel?.cancelled ?? false) throw const ReadCancelled();
          final Uint8List piece = await files.read(
            stat.path,
            offset: at,
            length: copyChunk < size - at ? copyChunk : size - at,
          );
          if (piece.isEmpty) {
            throw RemoteFileException(
              RemoteFileErrorKind.failed,
              '${stat.name} changed while it was being copied.',
              path: stat.path,
            );
          }
          sink.add(piece);
          at += piece.length;
          onProgress?.call(at);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (cancel?.cancelled ?? false) throw const ReadCancelled();
      return await part.rename(target.path);
    } on FileSystemException catch (e) {
      await _remove(folder);
      throw RemoteFileException(
        RemoteFileErrorKind.failed,
        e.osError?.errorCode == 28
            ? 'The phone is out of space for a copy.'
            : 'The file couldn’t be copied to the phone.',
        path: stat.path,
      );
    } on Object {
      // Cancelled, or the host said no: a half copy is of no use to anyone.
      await _remove(folder);
      rethrow;
    }
  }

  /// Removes every copy but the one in folder [keep].
  static Future<void> _clearExcept(Directory root, String keep) async {
    if (!await root.exists()) return;
    await for (final entry in root.list()) {
      if (entry.uri.pathSegments.where((s) => s.isNotEmpty).last == keep) continue;
      await _remove(entry);
    }
  }

  static Future<void> _remove(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) await entity.delete(recursive: true);
    } on FileSystemException {
      // A stale copy is not worth failing for.
    }
  }

  /// The remote name, safe as one part of a local path.
  static String _safe(String name) {
    final safe = name.replaceAll(RegExp(r'[\\/\x00-\x1f]'), '_');
    return safe.isEmpty || safe == '.' || safe == '..' ? 'file' : safe;
  }
}
