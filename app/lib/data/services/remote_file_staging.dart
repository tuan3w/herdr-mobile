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
  /// A copy that was cancelled or cut keeps what it had (the `.part` file of
  /// that file's folder) and the next copy of the same file continues there:
  /// it asks the machine for the file again first and goes on only when size
  /// and time are unchanged (with the agent helper the host also refuses a read
  /// of a file that changed since), else it starts over.
  ///
  /// [onProgress] hears the bytes written after every piece (a continued copy
  /// starts at what it already has). A [cancel] that fires stops before the
  /// next piece with [ReadCancelled]. Throws [RemoteFileException]: whatever
  /// the reads say, `failed` when the phone is out of space, when the file
  /// shrank while it was copied, or when its size is not known.
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
      var from = await _resumePoint(files, stat, size, part);
      while (true) {
        try {
          await _copy(files, stat, size, part, from, onProgress, cancel);
          break;
        } on RemoteFileChanged {
          // The host says the file is not the one the first part came from:
          // that part is of no use. Once from the start, and a file that
          // changes under that is not copyable now.
          if (from == 0) rethrow;
          await _remove(part);
          from = 0;
        }
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
    } on Object catch (e) {
      // A copy that was cancelled or cut by the connection keeps its part: the
      // next copy of the same file continues there. Anything else (the file is
      // gone, refused, shrank) leaves nothing worth keeping.
      final cut =
          e is ReadCancelled ||
          (e is RemoteFileException &&
              e is! RemoteFileChanged &&
              e is! _Shrank &&
              (e.kind == RemoteFileErrorKind.network || e.kind == RemoteFileErrorKind.failed));
      if (!cut) await _remove(folder);
      rethrow;
    }
  }

  /// How many bytes of [part] to keep and continue from: all of them when the
  /// file on the host still has the size and time [stat] had when the copy
  /// began, else none (the part is removed). A host that cannot be asked
  /// leaves the part alone and fails the copy, which keeps it.
  Future<int> _resumePoint(RemoteFiles files, RemoteStat stat, int size, File part) async {
    if (!await part.exists()) return 0;
    final have = await part.length();
    if (have == 0 || have >= size) {
      await _remove(part);
      return 0;
    }
    final now = await files.stat(stat.path);
    if (now.size == stat.size && now.modified == stat.modified) return have;
    await _remove(part);
    return 0;
  }

  /// Reads [stat]'s file from byte [from] to its end into [part] (appending
  /// when [from] is not 0). A continued copy asks the host to refuse a file that
  /// is not the one [stat] describes.
  Future<void> _copy(
    RemoteFiles files,
    RemoteStat stat,
    int size,
    File part,
    int from,
    void Function(int written)? onProgress,
    ReadCancel? cancel,
  ) async {
    final sink = part.openWrite(mode: from > 0 ? FileMode.append : FileMode.write);
    var at = from;
    try {
      if (from > 0) onProgress?.call(from);
      while (at < size) {
        if (cancel?.cancelled ?? false) throw const ReadCancelled();
        final Uint8List piece = await files.read(
          stat.path,
          offset: at,
          length: copyChunk < size - at ? copyChunk : size - at,
          ifMatch: from > 0 ? stat : null,
        );
        if (piece.isEmpty) {
          throw _Shrank('${stat.name} changed while it was being copied.', path: stat.path);
        }
        sink.add(piece);
        at += piece.length;
        onProgress?.call(at);
      }
      await sink.flush();
    } finally {
      await sink.close();
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

/// The file got shorter while it was being copied: its part is no use.
class _Shrank extends RemoteFileException {
  _Shrank(String message, {super.path}) : super(RemoteFileErrorKind.failed, message);
}
