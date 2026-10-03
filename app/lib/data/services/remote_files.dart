import 'dart:async';
import 'dart:typed_data';

import '../models/remote_file.dart';
import 'herdr_transport.dart';

/// Reads a machine's files through its transport (SFTP over the machine's SSH
/// connection). Every failure surfaces as a [RemoteFileException], including a
/// dropped connection, so screens handle one error type.
class RemoteFiles {
  RemoteFiles(this._transport);

  final HerdrTransport _transport;
  Future<String>? _home;

  /// False when the transport has no file channel at all (nothing to show).
  bool get supported => _transport.supportsFiles;

  /// The login directory, which is where relative and `~` paths start. Asked
  /// once; a failed ask is not remembered.
  Future<String> home() {
    final cached = _home;
    if (cached != null) return cached;
    final ask = _guard('~', () => _transport.realPath('.'));
    _home = ask;
    ask.then((_) {}, onError: (Object _) {
      if (identical(_home, ask)) _home = null;
    });
    return ask;
  }

  /// Follows links. Throws notFound / permission.
  Future<RemoteStat> stat(String path) => _guard(path, () => _transport.statFile(path));

  /// Entries of [path] in server order. Throws notFound / permission /
  /// notADirectory.
  Future<List<RemoteEntry>> list(String path) => _guard(path, () => _transport.listDirectory(path));

  /// Up to [length] bytes from [offset] (the transport caps one call at
  /// [remoteReadCap]); fewer at end of file.
  Future<Uint8List> read(String path, {int offset = 0, int length = remoteReadCap}) =>
      _guard(path, () => _transport.readFile(path, offset: offset, length: length));

  /// All [size] bytes of a file, fetched in capped pieces. For files the caller
  /// has already decided are small enough to hold in memory.
  Future<Uint8List> readAll(String path, {required int size}) async {
    if (size <= remoteReadCap) return read(path, length: size);
    final out = Uint8List(size);
    var at = 0;
    while (at < size) {
      final piece = await read(path, offset: at, length: size - at);
      if (piece.isEmpty) break; // the file shrank since it was measured
      out.setRange(at, at + piece.length, piece);
      at += piece.length;
    }
    return at == size ? out : Uint8List.sublistView(out, 0, at);
  }

  /// Canonical absolute path (links resolved when the target exists).
  Future<String> realpath(String path) => _guard(path, () => _transport.realPath(path));

  /// Absolute, normalised form of [raw]: `~` expands to the login directory and
  /// a relative path is taken against [cwd] (home when there is none). A
  /// trailing `:line:col` is NOT removed here, see [RemotePath.splitLocation].
  Future<String> resolve(String raw, {String? cwd}) async {
    final text = raw.trim();
    if (text.isEmpty) {
      throw RemoteFileException(RemoteFileErrorKind.notFound, 'No path given');
    }
    final needsHome = RemotePath.usesHome(text) ||
        (!RemotePath.isAbsolute(text) && !(cwd != null && RemotePath.isAbsolute(cwd)));
    final resolved = RemotePath.resolve(
      text,
      cwd: cwd,
      home: needsHome ? await home() : null,
    );
    if (resolved == null) {
      throw RemoteFileException(RemoteFileErrorKind.notFound, 'Cannot place $text', path: text);
    }
    return resolved;
  }

  Future<T> _guard<T>(String path, Future<T> Function() op) async {
    if (!_transport.supportsFiles) {
      throw RemoteFileException(
        RemoteFileErrorKind.unsupported,
        'Files are not available on this machine.',
        path: path,
      );
    }
    try {
      return await op();
    } on RemoteFileException {
      rethrow;
    } on HerdrTransportException catch (e) {
      throw RemoteFileException(RemoteFileErrorKind.network, e.message, fatal: e.fatal, path: path);
    } on Object catch (e) {
      throw RemoteFileException(RemoteFileErrorKind.network, '$e', path: path);
    }
  }
}
