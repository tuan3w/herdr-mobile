import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/services/sftp_files.dart';

import 'support/fake_sftp_server.dart';
import 'support/fake_transport.dart';

/// A server whose write at [failAt] is refused, and answers late: every other
/// write is answered by then, so the refused one is the last in flight.
class _RefusesOneWrite extends FakeSftpServer {
  _RefusesOneWrite(this.failAt);

  final int failAt;

  @override
  Future<SftpUploadFile> openForWrite(String path) async => _Refusing(await super.openForWrite(path), failAt);
}

class _Refusing implements SftpUploadFile {
  _Refusing(this._inner, this._failAt);

  final SftpUploadFile _inner;
  final int _failAt;

  @override
  Future<void> write(int offset, Uint8List data) async {
    if (offset != _failAt) return _inner.write(offset, data);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    throw SftpStatusError(4, 'Failure');
  }

  @override
  Future<void> close() => _inner.close();
}

/// A server that refuses to make folders.
class _NoMkdir extends FakeSftpServer {
  @override
  Future<void> mkdir(String path) async {
    calls.add('mkdir $path');
    throw SftpStatusError(3, 'Permission denied');
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('upload_write_failure_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  const remote = '/home/dev/inbox/up.bin';

  File local(int size) => File('${tmp.path}/f.bin')..writeAsBytesSync(Uint8List(size));

  SftpFiles filesOn(FakeSftpServer server) {
    server.dirs['/home/dev/inbox'] = 0x41C0;
    return SftpFiles(open: () async => server, uploadStartWindow: 32);
  }

  group('an upload whose last write fails', () {
    test('is a failed upload, the partial file goes', () async {
      final blocks = 6;
      final server = _RefusesOneWrite((blocks - 1) * 32 * 1024);
      final files = filesOn(server);
      final job = files.upload(local(blocks * 32 * 1024).path, remote);

      await expectLater(
        job.done,
        throwsA(isA<RemoteFileException>().having((e) => e is UploadCancelled, 'cancelled', isFalse)),
      );
      await eventually(() => !server.files.containsKey(remote), reason: 'partial removed');
    });

    test('a file of one block that is refused fails too', () async {
      final server = FakeSftpServer()..dieAfterWrites = 0;
      final files = filesOn(server);
      final job = files.upload(local(10 * 1024).path, remote);

      await expectLater(job.done, throwsA(isA<RemoteFileException>()));
      await eventually(() => !server.files.containsKey(remote), reason: 'partial removed');
    });
  });

  test('a folder the server refuses to make says permission denied, not "no such file"', () async {
    final files = SftpFiles(open: () async => _NoMkdir());

    await expectLater(
      files.makeDirs('/home/dev/inbox/new'),
      throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.permission)),
    );
  });
}
