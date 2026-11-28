@TestOn('linux || mac-os')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/host/host_files.dart';
import 'package:herdr_mobile/data/host/host_link.dart';
import 'package:herdr_mobile/data/host/wire.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/remote_file_staging.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';

import 'support/host_serve.dart';

// The file viewer's backend against the REAL `herdr-host serve`: what `fs`
// answers for a real folder, and how that becomes the models and errors the
// screens already handle. The Rust side is tested in rust/crates/host (svc/fs).
//
// Needs the binary: `cd rust && cargo build --release -p host`, or
// HERDR_HOST_BIN=/path/to/herdr-host.

/// Content that depends on the position, so a lost or shifted byte shows.
Uint8List pattern(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) (i * 31 + (i >> 8)) & 0xFF]);

bool get _isRoot => Process.runSync('id', ['-u']).stdout.toString().trim() == '0';

void main() {
  final skip = hostBinarySkip();
  late ServedHost host;
  late SpyHostProcess process;
  late HostLink link;
  late HostFiles files;
  late String tree;

  setUp(() async {
    host = ServedHost();
    tree = '${host.home}/tree';
    Directory(tree).createSync();
    if (skip == null) {
      (process, link) = await host.connect();
      files = HostFiles(link, watchInterval: const Duration(milliseconds: 500));
    }
  });
  tearDown(() => host.dispose());

  Future<RemoteFileException> failure(Future<Object?> Function() op) async {
    try {
      await op();
    } on RemoteFileException catch (e) {
      return e;
    }
    fail('expected a RemoteFileException');
  }

  group('what the helper answers for a real folder', () {
    test('stat: kind, size, time in milliseconds and permission bits; links are followed; one request', () async {
      final f = File('$tree/a.txt')..writeAsStringSync('hello');
      Process.runSync('chmod', ['640', f.path]);
      Directory('$tree/d').createSync();
      Link('$tree/l').createSync(f.path);

      final before = process.sent(FrameKind.open).length;
      final s = await files.stat(f.path);
      expect(process.sent(FrameKind.open).length - before, 1, reason: 'one request, one answer');
      expect(s.kind, RemoteEntryKind.file);
      expect(s.size, 5);
      expect(s.mode, 416); // 0o640
      expect(s.modified, DateTime.fromMillisecondsSinceEpoch(f.lastModifiedSync().millisecondsSinceEpoch, isUtc: true));
      expect(s.path, f.path);

      expect((await files.stat('$tree/d')).kind, RemoteEntryKind.dir);
      final viaLink = await files.stat('$tree/l');
      expect(viaLink.kind, RemoteEntryKind.file, reason: 'stat follows links');
      expect(viaLink.size, 5);
    });

    test('a missing path, a file used as a folder and a folder used as a file say what is wrong', () async {
      File('$tree/a.txt').writeAsStringSync('x');
      Directory('$tree/d').createSync();

      final missing = await failure(() => files.stat('$tree/none'));
      expect(missing.kind, RemoteFileErrorKind.notFound);
      expect(missing.path, '$tree/none');
      expect(missing.message, contains('$tree/none'), reason: 'the host words it with the path');
      expect((await failure(() => files.list('$tree/a.txt'))).kind, RemoteFileErrorKind.notADirectory);
      expect((await failure(() => files.list('$tree/none'))).kind, RemoteFileErrorKind.notFound);
      expect((await failure(() => files.read('$tree/d', 0, 10))).kind, RemoteFileErrorKind.notAFile);
      expect((await failure(() => files.read('$tree/none', 0, 10))).kind, RemoteFileErrorKind.notFound);
    });

    test('permission denied is permission, not a connection problem', () async {
      Directory('$tree/locked').createSync();
      File('$tree/locked/inside.txt').writeAsStringSync('x');
      File('$tree/secret.txt').writeAsStringSync('x');
      Process.runSync('chmod', ['000', '$tree/locked', '$tree/secret.txt']);

      expect((await failure(() => files.stat('$tree/locked/inside.txt'))).kind, RemoteFileErrorKind.permission);
      expect((await failure(() => files.list('$tree/locked'))).kind, RemoteFileErrorKind.permission);
      expect((await failure(() => files.read('$tree/secret.txt', 0, 10))).kind, RemoteFileErrorKind.permission);
    }, skip: skip ?? (_isRoot ? 'root can read anything' : null));

    test('real_path expands ~, `.` and relative paths from the home and resolves links', () async {
      File('$tree/a.txt').writeAsStringSync('x');
      Link('$tree/l').createSync('a.txt');

      expect(await files.realPath('~'), host.home);
      expect(await files.realPath('.'), host.home, reason: 'SFTP started in the login folder: so does this');
      expect(await files.realPath('~/tree'), tree);
      expect(await files.realPath('tree/a.txt'), '$tree/a.txt');
      expect(await files.realPath('$tree/l'), '$tree/a.txt', reason: 'links are resolved');
      expect((await files.stat('~/tree/a.txt')).size, 1);
      expect((await failure(() => files.realPath('~/none'))).kind, RemoteFileErrorKind.notFound);
    });

    test('a folder of 1200 entries arrives whole; links say what they point at', () async {
      for (var i = 0; i < 1200; i++) {
        File('$tree/Tệp ${i.toString().padLeft(4, '0')}.txt').writeAsStringSync('$i');
      }
      Directory('$tree/sub').createSync();
      Link('$tree/to-sub').createSync('sub');
      Link('$tree/to-file').createSync('Tệp 0007.txt');
      Link('$tree/broken').createSync('nowhere/at/all');

      final entries = await files.list(tree);
      expect(entries, hasLength(1204));
      final byName = {for (final e in entries) e.name: e};
      expect(byName, hasLength(1204), reason: 'no entry twice, none lost across the 500-entry pieces');
      expect(byName.keys, isNot(anyOf(contains('.'), contains('..'))));
      expect(byName['Tệp 0999.txt']!.size, 3);
      expect(byName['Tệp 0999.txt']!.path, '$tree/Tệp 0999.txt');
      expect(byName['Tệp 0999.txt']!.kind, RemoteEntryKind.file);
      expect(byName['sub']!.kind, RemoteEntryKind.dir);

      final dirLink = byName['to-sub']!;
      expect(dirLink.kind, RemoteEntryKind.link);
      expect(dirLink.isDirectory, isTrue);
      expect(dirLink.linkTarget, '$tree/sub');
      final fileLink = byName['to-file']!;
      expect(fileLink.isFile, isTrue);
      expect(fileLink.size, 1);
      final broken = byName['broken']!;
      expect(broken.isBrokenLink, isTrue);
      expect(broken.linkTarget, isNull);
    });

    test('an empty folder is an empty list', () async {
      expect(await files.list(tree), isEmpty);
    });

    test('read: all of it, from an offset, past the end, nothing, and across many frames', () async {
      final bytes = pattern(300 * 1024 + 7); // ten and a bit 32 KiB frames
      File('$tree/big.bin').writeAsBytesSync(bytes);

      expect(await files.read('$tree/big.bin', 0, bytes.length), orderedEquals(bytes));
      expect(await files.read('$tree/big.bin', 1000, 5000), orderedEquals(bytes.sublist(1000, 6000)));
      expect(await files.read('$tree/big.bin', bytes.length - 3, 100), orderedEquals(bytes.sublist(bytes.length - 3)));
      expect(await files.read('$tree/big.bin', bytes.length, 100), isEmpty, reason: 'at the end');
      expect(await files.read('$tree/big.bin', bytes.length + 5000, 100), isEmpty, reason: 'past the end');
      expect(await files.read('$tree/big.bin', 0, 0), isEmpty);
      expect(await files.read('$tree/big.bin', -5, 10), orderedEquals(bytes.sublist(0, 10)), reason: 'never negative');
    });

    test('the read cap stays on the phone: more than 8 MB asked is 8 MB given', () async {
      final src = File('$tree/ten.bin')..writeAsBytesSync(Uint8List(10 * 1024 * 1024));
      expect((await files.read(src.path, 0, 10 * 1024 * 1024)).length, remoteReadCap);
    });

    test('a read waits for nothing else: it runs beside a listing on the same link', () async {
      File('$tree/a.bin').writeAsBytesSync(pattern(200 * 1024));
      for (var i = 0; i < 50; i++) {
        File('$tree/f$i').writeAsStringSync('x');
      }
      final results = await Future.wait([
        files.read('$tree/a.bin', 0, 200 * 1024),
        files.list(tree),
        files.stat('$tree/a.bin'),
      ]);
      expect(results[0] as Uint8List, hasLength(200 * 1024));
      expect(results[1] as List<RemoteEntry>, hasLength(51));
    });
  }, skip: skip);

  group('the file changing under a read', () {
    test('ifMatch: a read of the file as it was seen works, of a changed one is `changed`', () async {
      final f = File('$tree/log.txt')..writeAsStringSync('first version');
      final seen = await files.stat(f.path);
      expect(files.checksIdentity, isTrue);

      expect(String.fromCharCodes(await files.read(f.path, 0, 5, ifMatch: seen)), 'first');
      expect(String.fromCharCodes(await files.read(f.path, 6, 7, ifMatch: seen)), 'version');

      f.writeAsStringSync('first version, then more');
      final changed = await failure(() => files.read(f.path, 0, 5, ifMatch: seen));
      expect(changed, isA<RemoteFileChanged>());
      expect(changed.fatal, isFalse, reason: 'reading it again is the remedy');
      expect(
        String.fromCharCodes(await files.read(f.path, 0, 5)),
        'first',
        reason: 'without ifMatch the file is read as it is',
      );

      // A new time with the same size is a change too.
      final again = await files.stat(f.path);
      f.setLastModifiedSync(f.lastModifiedSync().add(const Duration(seconds: 7)));
      expect(await failure(() => files.read(f.path, 0, 5, ifMatch: again)), isA<RemoteFileChanged>());
    });
  }, skip: skip);

  group('watching a file', () {
    test('says what it is now, then each change, a file that is gone as null, and stops when cancelled', () async {
      final f = File('$tree/watched.txt');
      final events = StreamQueue<RemoteStat?>(files.watch(f.path));
      addTearDown(events.cancel);

      expect(await events.next, isNull, reason: 'not there yet: null, not an error');
      f.writeAsStringSync('one');
      final created = await events.next;
      expect(created?.size, 3);
      expect(created?.kind, RemoteEntryKind.file, reason: 'a full stat, not only size and time');

      f.writeAsStringSync('longer text');
      expect((await events.next)?.size, 11);
      f.deleteSync();
      expect(await events.next, isNull);

      final watchOpen = process.opens().indexOf('fs.watch');
      expect(watchOpen, isNonNegative);
      final id = process.sent(FrameKind.open)[watchOpen].stream;
      expect(process.sent(FrameKind.reset).where((r) => r.stream == id), isEmpty);
      await events.cancel();
      expect(
        process.sent(FrameKind.reset).where((r) => r.stream == id),
        hasLength(1),
        reason: 'the host is told to stop looking',
      );
      // The link is still good for the next screen.
      expect(await files.realPath('~'), host.home);
    });

    test('a watch on a path the host cannot look at ends with the typed error', () async {
      final events = files.watch('${host.home}/nope\u0000x');
      await expectLater(events, emitsError(isA<RemoteFileException>()));
    });
  }, skip: skip);

  group('a copy to the phone', () {
    test(
      'cancelled at 40 %, the next copy continues where it stopped, asks the host to check the file, and ends equal',
      () async {
        final bytes = pattern(6 * 1024 * 1024 + 11);
        final src = File('$tree/video.mp4')..writeAsBytesSync(bytes);
        final phone = Directory.systemTemp.createTempSync('copies');
        addTearDown(() => phone.deleteSync(recursive: true));
        final remote = RemoteFiles(HostFilesTransport(files), machineId: 'box');
        final staging = RemoteFileStaging(root: () async => Directory('${phone.path}/copies'));
        final stat = await remote.stat(src.path);

        final cancel = ReadCancel();
        await expectLater(
          staging.fetch(
            remote,
            stat,
            cancel: cancel,
            onProgress: (n) => n >= bytes.length * 0.4 ? cancel.cancel() : null,
          ),
          throwsA(isA<ReadCancelled>()),
        );
        final firstPass = process.argsOf('fs.read');
        final kept = firstPass.fold<int>(0, (sum, a) => sum + (a['length']! as int));
        expect(kept, greaterThanOrEqualTo(bytes.length * 0.4), reason: 'the first pass got past 40 %');
        expect(kept, lessThan(bytes.length));

        final heard = <int>[];
        final file = await staging.fetch(remote, stat, onProgress: heard.add);

        expect(sha(file.readAsBytesSync()), sha(bytes), reason: 'the copy equals the source');
        final secondPass = process.argsOf('fs.read').sublist(firstPass.length);
        expect(secondPass.first['offset'], copyChunk * firstPass.length, reason: 'it continued at what the phone had');
        expect(secondPass.first['if_match'], {'size': bytes.length, 'mtime_ms': stat.modified!.millisecondsSinceEpoch});
        final again = secondPass.fold<int>(0, (sum, a) => sum + (a['length']! as int));
        expect(again, lessThan(bytes.length), reason: 'the second pass read less than the whole file');
        expect(again + kept, bytes.length, reason: 'and nothing twice');
        expect(heard.first, kept, reason: 'progress starts at what the phone already had');
      },
    );
  }, skip: skip);

  group('when the connection goes', () {
    test('a dead link is a connection problem for everything, listing and reading included', () async {
      File('$tree/a.txt').writeAsStringSync('x');
      expect((await files.stat('$tree/a.txt')).size, 1);
      process.kill();
      await link.closed;

      for (final op in <Future<Object?> Function()>[
        () => files.stat('$tree/a.txt'),
        () => files.list(tree),
        () => files.read('$tree/a.txt', 0, 1),
        () => files.realPath('~'),
      ]) {
        await expectLater(op(), throwsA(isA<HerdrTransportException>()));
      }
      await expectLater(files.watch('$tree/a.txt'), emitsError(isA<HerdrTransportException>()));
    });
  }, skip: skip);

  group('how host errors become what screens handle', () {
    HostException said(String code, {bool retryable = false}) =>
        HostException(code, 'said by the host', retryable: retryable);

    test('the codes that name a file problem map one to one', () {
      const table = {
        'not_found': RemoteFileErrorKind.notFound,
        'permission': RemoteFileErrorKind.permission,
        'not_a_file': RemoteFileErrorKind.notAFile,
        'not_a_directory': RemoteFileErrorKind.notADirectory,
        'too_large': RemoteFileErrorKind.tooLarge,
        'failed': RemoteFileErrorKind.failed,
        'bad_request': RemoteFileErrorKind.failed,
      };
      table.forEach((code, kind) {
        final e = HostFiles.failure(said(code), '/p');
        expect(e, isA<RemoteFileException>(), reason: code);
        expect((e as RemoteFileException).kind, kind, reason: code);
        expect(e.path, '/p');
        expect(e.message, 'said by the host');
      });
    });

    test('`changed` is its own type, a connection problem is a transport exception', () {
      expect(HostFiles.failure(said('changed'), '/p'), isA<RemoteFileChanged>());
      for (final e in [
        said('unavailable'),
        const HostLinkLost('gone'),
        said('busy', retryable: true),
        said('timeout', retryable: true),
        said('stalled', retryable: true),
      ]) {
        expect(HostFiles.failure(e, '/p'), isA<HerdrTransportException>(), reason: e.code);
      }
    });

    test('paths go to the host absolute or from ~, and relative ones start at home', () {
      expect(HostFiles.wirePath('/a/b'), '/a/b');
      expect(HostFiles.wirePath('~'), '~');
      expect(HostFiles.wirePath('~/a'), '~/a');
      expect(HostFiles.wirePath('.'), '~');
      expect(HostFiles.wirePath(''), '~');
      expect(HostFiles.wirePath('a/b'), '~/a/b');
      expect(HostFiles.wirePath('./a'), '~/a');
    });
  });
}

/// What a stream says, one event at a time, so a test can wait for the next
/// one instead of for a duration.
class StreamQueue<T> {
  StreamQueue(Stream<T> stream) {
    _sub = stream.listen(
      (e) {
        _items.add(e);
        _wake();
      },
      onError: (Object e) {
        _errors.add(e);
        _wake();
      },
    );
  }

  late final StreamSubscription<T> _sub;
  final _items = <T>[];
  final _errors = <Object>[];
  Completer<void>? _waiting;

  void _wake() {
    final w = _waiting;
    _waiting = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<T> get next async {
    while (_items.isEmpty) {
      if (_errors.isNotEmpty) throw _errors.removeAt(0);
      await (_waiting ??= Completer<void>()).future;
    }
    return _items.removeAt(0);
  }

  Future<void> cancel() => _sub.cancel();
}

String sha(List<int> bytes) => sha256.convert(bytes).toString();
