import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';
import 'package:herdr_mobile/data/services/sftp_files.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';

const _file = 0x81A4; // -rw-r--r--
const _dir = 0x41ED; // drwxr-xr-x
const _link = 0xA1FF; // lrwxrwxrwx

SftpName _name(String name, int mode, {int size = 0, int mtime = 1700000000}) => SftpName(
      filename: name,
      longname: name,
      attr: SftpFileAttrs(size: size, mode: SftpFileMode.value(mode), modifyTime: mtime),
    );

SftpStatusError _status(int code, [String message = '']) => SftpStatusError(code, message);

/// An SFTP server in memory: answers from tables, fails on demand, counts calls.
class _FakeSftp implements SftpApi {
  final stats = <String, SftpFileAttrs>{};
  final dirs = <String, List<SftpName>>{};
  final links = <String, String>{};
  final files = <String, Uint8List>{};
  final failures = <String, Object>{};
  final calls = <String>[];
  var closed = false;
  Completer<void>? gate;

  Future<void> _enter(String call, String path) async {
    calls.add('$call $path');
    await gate?.future;
    final failure = failures['$call $path'] ?? failures[path];
    if (failure != null) throw failure;
  }

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    await _enter('stat', path);
    return stats[path] ?? (throw _status(2, 'No such file'));
  }

  @override
  Future<List<SftpName>> listdir(String path) async {
    await _enter('list', path);
    return dirs[path] ?? (throw _status(2, 'No such file'));
  }

  @override
  Future<SftpUploadFile> openForWrite(String path) => throw UnimplementedError();

  @override
  Future<void> mkdir(String path) => throw UnimplementedError();

  @override
  Future<void> remove(String path) => throw UnimplementedError();

  @override
  Future<String> absolute(String path) async {
    await _enter('real', path);
    return path == '.' ? '/home/dev' : path;
  }

  @override
  Future<String> readlink(String path) async {
    await _enter('readlink', path);
    return links[path] ?? (throw _status(4, 'Failure'));
  }

  @override
  Future<Uint8List> readBytes(String path, int offset, int length) async {
    await _enter('read', path);
    final bytes = files[path] ?? (throw _status(2, 'No such file'));
    if (offset >= bytes.length) return Uint8List(0);
    return Uint8List.sublistView(bytes, offset, (offset + length).clamp(0, bytes.length));
  }

  @override
  Future<void> close() async => closed = true;
}

void main() {
  group('SftpFiles', () {
    late _FakeSftp sftp;
    late SftpFiles files;
    var opened = 0;

    setUp(() {
      sftp = _FakeSftp();
      opened = 0;
      files = SftpFiles(
        open: () async {
          opened++;
          return sftp;
        },
        metaTimeout: const Duration(milliseconds: 200),
        readTimeout: const Duration(milliseconds: 200),
      );
    });

    Future<RemoteFileException> failure(Future<Object?> Function() op) async {
      try {
        await op();
      } on RemoteFileException catch (e) {
        return e;
      }
      fail('expected a RemoteFileException');
    }

    test('maps SFTP status codes to typed errors that say whether to retry', () async {
      sftp.failures['/a'] = _status(2, 'No such file');
      sftp.failures['/b'] = _status(3, 'Permission denied');
      sftp.failures['/c'] = _status(8, 'Op unsupported');
      sftp.failures['/d'] = _status(7, 'Connection lost');
      sftp.failures['/e'] = _status(4, 'Failure');

      final notFound = await failure(() => files.stat('/a'));
      final denied = await failure(() => files.stat('/b'));
      final unsupported = await failure(() => files.stat('/c'));
      final lost = await failure(() => files.stat('/d'));
      final other = await failure(() => files.stat('/e'));

      expect(notFound.kind, RemoteFileErrorKind.notFound);
      expect(notFound.fatal, isTrue);
      expect(denied.kind, RemoteFileErrorKind.permission);
      expect(denied.fatal, isTrue);
      expect(unsupported.kind, RemoteFileErrorKind.unsupported);
      expect(unsupported.fatal, isTrue);
      expect(lost.kind, RemoteFileErrorKind.network);
      expect(lost.fatal, isFalse);
      expect(other.kind, RemoteFileErrorKind.failed);
      expect(other.fatal, isFalse);
      expect(notFound.path, '/a');
    });

    test('every kind declares retryability: only network and failed are retryable', () {
      for (final kind in RemoteFileErrorKind.values) {
        final retryable = kind == RemoteFileErrorKind.network || kind == RemoteFileErrorKind.failed;
        expect(RemoteFileException(kind, 'x').fatal, !retryable, reason: '$kind');
      }
      expect(RemoteFileException(RemoteFileErrorKind.network, 'x', fatal: true).fatal, isTrue);
    });

    test('stat reports kind, size and time; links are followed by the server', () async {
      sftp.stats['/d'] = SftpFileAttrs(size: 4096, mode: const SftpFileMode.value(_dir), modifyTime: 1700000000);
      sftp.stats['/f'] = SftpFileAttrs(size: 12, mode: const SftpFileMode.value(_file), modifyTime: 1700000000);
      sftp.stats['/sock'] = SftpFileAttrs(size: 0, mode: const SftpFileMode.value(0xC1FF));

      final d = await files.stat('/d');
      final f = await files.stat('/f');
      final s = await files.stat('/sock');

      expect(d.kind, RemoteEntryKind.dir);
      expect(f.kind, RemoteEntryKind.file);
      expect(f.size, 12);
      expect(f.modified, DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000, isUtc: true));
      expect(s.kind, RemoteEntryKind.other);
    });

    test('list drops . and .., resolves links, keeps broken ones unresolved', () async {
      sftp.dirs['/p'] = [
        _name('.', _dir),
        _name('..', _dir),
        _name('src', _dir),
        _name('notes.txt', _file, size: 120),
        _name('latest', _link),
        _name('current', _link),
        _name('dangling', _link),
      ];
      sftp.links['/p/latest'] = 'src';
      sftp.links['/p/current'] = 'notes.txt';
      sftp.links['/p/dangling'] = 'nowhere';
      sftp.stats['/p/latest'] = SftpFileAttrs(size: 4096, mode: const SftpFileMode.value(_dir), modifyTime: 1700000500);
      sftp.stats['/p/current'] = SftpFileAttrs(size: 120, mode: const SftpFileMode.value(_file), modifyTime: 1700000600);

      final entries = {for (final e in await files.list('/p')) e.name: e};

      expect(entries.keys, {'src', 'notes.txt', 'latest', 'current', 'dangling'});
      expect(entries['src']!.path, '/p/src');
      expect(entries['latest']!.kind, RemoteEntryKind.link);
      expect(entries['latest']!.isDirectory, isTrue);
      expect(entries['latest']!.linkTarget, 'src');
      expect(entries['current']!.isFile, isTrue);
      expect(entries['current']!.size, 120);
      expect(entries['dangling']!.isBrokenLink, isTrue);
      expect(entries['dangling']!.linkTarget, 'nowhere');
    });

    test('a file asked to list is "not a folder", not "not found"', () async {
      sftp.stats['/f'] = SftpFileAttrs(size: 1, mode: const SftpFileMode.value(_file));
      // sftp-server answers opendir on a file with "no such file".

      final e = await failure(() => files.list('/f'));
      expect(e.kind, RemoteFileErrorKind.notADirectory);

      final missing = await failure(() => files.list('/missing'));
      expect(missing.kind, RemoteFileErrorKind.notFound);
    });

    test('reading a folder says "not a file"', () async {
      sftp.stats['/d'] = SftpFileAttrs(size: 4096, mode: const SftpFileMode.value(_dir));
      sftp.failures['read /d'] = _status(4, 'Failure');

      final e = await failure(() => files.read('/d', 0, 10));
      expect(e.kind, RemoteFileErrorKind.notAFile);
    });

    test('read clamps the length, treats a negative offset as 0, and returns short at the end', () async {
      sftp.files['/f'] = Uint8List.fromList(List.generate(100, (i) => i));

      expect((await files.read('/f', 90, 50)).length, 10);
      expect((await files.read('/f', 100, 50)), isEmpty);
      expect((await files.read('/f', -5, 3)), [0, 1, 2]);
      expect((await files.read('/f', 0, 0)), isEmpty);
      // The request never carries more than the cap.
      final seen = <int>[];
      final capped = SftpFiles(open: () async => _Spy(sftp, seen));
      await capped.read('/f', 0, 1 << 40);
      expect(seen.single, remoteReadCap);
    });

    test('one session serves many calls; concurrent first calls open one', () async {
      sftp.stats['/f'] = SftpFileAttrs(size: 1, mode: const SftpFileMode.value(_file));
      await Future.wait([files.stat('/f'), files.stat('/f'), files.stat('/f')]);
      await files.stat('/f');
      expect(opened, 1);
    });

    test('a channel that died is replaced once and the call succeeds', () async {
      sftp.stats['/f'] = SftpFileAttrs(size: 1, mode: const SftpFileMode.value(_file));
      await files.stat('/f');
      sftp.failures['stat /f'] = SftpAbortError('SFTP channel closed');
      final first = sftp;
      var replaced = false;
      opened = 0;
      files = SftpFiles(
        open: () async {
          opened++;
          if (opened == 1) return first;
          replaced = true;
          return _FakeSftp()..stats['/f'] = SftpFileAttrs(size: 7, mode: const SftpFileMode.value(_file));
        },
      );
      expect((await files.stat('/f')).size, 7);
      expect(replaced, isTrue);
      expect(first.closed, isTrue, reason: 'the dead session is closed');
    });

    test('a channel that keeps dying becomes a retryable network error', () async {
      sftp.stats['/f'] = SftpFileAttrs(size: 1, mode: const SftpFileMode.value(_file));
      sftp.failures['/f'] = SftpAbortError('SFTP channel closed');

      final e = await failure(() => files.stat('/f'));
      expect(e.kind, RemoteFileErrorKind.network);
      expect(e.fatal, isFalse);
    });

    test('an operation that never answers times out as a network error and drops the session', () async {
      sftp.gate = Completer<void>();
      final e = await failure(() => files.stat('/f'));
      expect(e.kind, RemoteFileErrorKind.network);
      expect(sftp.closed, isTrue);
    });

    test('a session that cannot be opened is not cached', () async {
      var attempts = 0;
      files = SftpFiles(open: () async {
        attempts++;
        if (attempts == 1) {
          throw RemoteFileException(RemoteFileErrorKind.unsupported, 'no sftp');
        }
        return sftp..stats['/f'] = SftpFileAttrs(size: 1, mode: const SftpFileMode.value(_file));
      });

      final e = await failure(() => files.stat('/f'));
      expect(e.kind, RemoteFileErrorKind.unsupported);
      expect((await files.stat('/f')).size, 1);
    });

    test('discard closes the session so the next call opens a new one', () async {
      sftp.stats['/f'] = SftpFileAttrs(size: 1, mode: const SftpFileMode.value(_file));
      await files.stat('/f');
      files.discard();
      await Future<void>.delayed(Duration.zero);
      expect(sftp.closed, isTrue);
      await files.stat('/f');
      expect(opened, 2);
    });
  });

  group('RemoteFiles', () {
    test('a transport without files says so instead of failing oddly', () async {
      final files = RemoteFiles(FakeTransport());
      expect(files.supported, isFalse);
      await expectLater(
        files.stat('/x'),
        throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.unsupported)),
      );
    });

    test('a dropped connection is a RemoteFileException that keeps the transport\'s fatal flag', () async {
      final t = FakeTransport()..fs = _NoFs(error: const HerdrTransportException('link dropped'));
      final files = RemoteFiles(t);
      await expectLater(
        files.stat('/x'),
        throwsA(isA<RemoteFileException>()
            .having((e) => e.kind, 'kind', RemoteFileErrorKind.network)
            .having((e) => e.fatal, 'fatal', isFalse)),
      );
      t.fs = _NoFs(error: const HerdrTransportException('bad key', fatal: true));
      await expectLater(
        files.list('/x'),
        throwsA(isA<RemoteFileException>().having((e) => e.fatal, 'fatal', isTrue)),
      );
    });

    test('home is asked once and a failed ask is retried', () async {
      var asks = 0;
      Object? failNext = const HerdrTransportException('down');
      final t = FakeTransport()
        ..fs = _NoFs(onReal: () {
          asks++;
          final f = failNext;
          failNext = null;
          return f;
        });
      final files = RemoteFiles(t);

      await expectLater(files.home(), throwsA(isA<RemoteFileException>()));
      expect(await files.home(), '/home/dev');
      expect(await files.home(), '/home/dev');
      expect(asks, 2);
    });

    test('resolve expands ~, uses the cwd for relative paths, and normalises', () async {
      final files = RemoteFiles(FakeTransport()..fs = _NoFs());
      expect(await files.resolve('~/src/../notes.md'), '/home/dev/notes.md');
      expect(await files.resolve('~'), '/home/dev');
      expect(await files.resolve('lib/main.dart', cwd: '/srv/app'), '/srv/app/lib/main.dart');
      expect(await files.resolve('../x', cwd: '/srv/app'), '/srv/x');
      expect(await files.resolve('/etc//hosts'), '/etc/hosts');
      // No cwd (or a relative one): the login directory is the base.
      expect(await files.resolve('a/b'), '/home/dev/a/b');
      expect(await files.resolve('a', cwd: 'relative'), '/home/dev/a');
      await expectLater(files.resolve('  '), throwsA(isA<RemoteFileException>()));
    });

    test('readAll stitches pieces and survives a file that shrank', () async {
      final bytes = Uint8List.fromList(List.generate(remoteReadCap + 1000, (i) => i % 251));
      final t = FakeTransport()..fs = _NoFs(content: bytes);
      final files = RemoteFiles(t);

      final all = await files.readAll('/big', size: bytes.length);
      expect(all.length, bytes.length);
      expect(all[remoteReadCap + 5], bytes[remoteReadCap + 5]);

      final shrunk = await files.readAll('/big', size: bytes.length + 5000);
      expect(shrunk.length, bytes.length);
    });
  });
}

/// A [FakeFs] stand-in that fails or answers on demand, for RemoteFiles tests.
class _NoFs extends FakeFs {
  _NoFs({this.error, this.onReal, this.content});

  final Object? error;
  final Object? Function()? onReal;
  final Uint8List? content;

  @override
  Future<RemoteStat> stat(String path) async => error != null ? throw error! : throw StateError('unused');

  @override
  Future<List<RemoteEntry>> list(String path) async => error != null ? throw error! : const [];

  @override
  Future<Uint8List> read(String path, int offset, int length) async {
    final c = content ?? Uint8List(0);
    if (offset >= c.length) return Uint8List(0);
    return Uint8List.sublistView(c, offset, (offset + length.clamp(0, remoteReadCap)).clamp(0, c.length));
  }

  @override
  Future<String> realPath(String path) async {
    final f = onReal?.call();
    if (f != null) throw f;
    return path == '.' ? '/home/dev' : path;
  }
}

/// Records the length each read asked for.
class _Spy implements SftpApi {
  _Spy(this._inner, this.lengths);

  final _FakeSftp _inner;
  final List<int> lengths;

  @override
  Future<Uint8List> readBytes(String path, int offset, int length) {
    lengths.add(length);
    return _inner.readBytes(path, offset, length);
  }

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) => _inner.stat(path);

  @override
  Future<List<SftpName>> listdir(String path) => _inner.listdir(path);

  @override
  Future<String> absolute(String path) => _inner.absolute(path);

  @override
  Future<String> readlink(String path) => _inner.readlink(path);

  @override
  Future<SftpUploadFile> openForWrite(String path) => _inner.openForWrite(path);

  @override
  Future<void> mkdir(String path) => _inner.mkdir(path);

  @override
  Future<void> remove(String path) => _inner.remove(path);

  @override
  Future<void> close() => _inner.close();
}
