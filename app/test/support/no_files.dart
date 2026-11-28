import 'dart:typed_data';

import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/models/remote_search.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';

/// The file side of a [HerdrTransport] for a test double that has none: it says
/// so and every operation throws [UnsupportedError]. A class that does have
/// some of them just declares its own.
mixin NoFiles implements HerdrTransport {
  @override
  bool get supportsFiles => false;

  @override
  Future<RemoteStat> statFile(String path) => throw UnsupportedError('files');

  @override
  Future<List<RemoteEntry>> listDirectory(String path) => throw UnsupportedError('files');

  @override
  Future<Uint8List> readFile(String path, {int offset = 0, int length = remoteReadCap, RemoteStat? ifMatch}) =>
      throw UnsupportedError('files');

  @override
  Future<String> realPath(String path) => throw UnsupportedError('files');

  @override
  Stream<RemoteStat?> watchFile(String path) => throw UnsupportedError('files');

  @override
  Future<Uint8List?> thumbnailFile(String path, {int maxPx = 256, RemoteStat? expect, Future<void>? cancelled}) =>
      throw UnsupportedError('files');

  @override
  Stream<FileSearchEvent> searchFiles(FileSearchSpec spec) => throw UnsupportedError('files');

  @override
  Future<String> reserveInboxFile({required String key, required String name}) => throw UnsupportedError('files');

  @override
  Future<int> sweepInbox() => throw UnsupportedError('files');

  @override
  UploadJob uploadFile({
    required String localPath,
    required String inboxPath,
    void Function(int sent, int total)? onProgress,
  }) => throw UnsupportedError('files');
}
