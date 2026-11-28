@TestOn('linux || mac-os')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/host/host_link.dart';
import 'package:herdr_mobile/data/host/host_transfer.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';

import 'support/fake_host.dart';
import 'support/host_serve.dart';

// The phone's side of an upload against the REAL `herdr-host serve`: the inbox
// path the host picks, the bytes' journey (hash, resume after a lost
// connection, a file that changes while it is sent), and the sweep. The Rust
// side (naming, path rules, the sha check) is rust/crates/host/src/svc/transfer.rs.
//
// Needs the binary: `cd rust && cargo build --release -p host`, or
// HERDR_HOST_BIN=/path/to/herdr-host.

/// Content that depends on the position, so a lost or shifted byte shows.
Uint8List pattern(int n, [int seed = 31]) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) (i * seed + (i >> 8) + (i >> 17)) & 0xFF]);

String sha(List<int> bytes) => sha256.convert(bytes).toString();

void main() {
  final skip = hostBinarySkip();
  late ServedHost host;
  late Directory phone;

  setUp(() {
    host = ServedHost();
    phone = Directory.systemTemp.createTempSync('phone_files');
  });
  tearDown(() {
    host.dispose();
    phone.deleteSync(recursive: true);
  });

  File local(String name, Uint8List bytes) => File('${phone.path}/$name')..writeAsBytesSync(bytes);

  HostUpload upload(HostLink link, File file, String inbox, {void Function(int, int)? onProgress}) => HostUpload(
    link: Future.value(link),
    localPath: file.path,
    inboxPath: inbox,
    onProgress: onProgress,
    progressInterval: Duration.zero,
  );

  group('the inbox path the host picks', () {
    test('lands under <home>/.herdr-mobile/inbox/<12 hex of sha1(key)>, in an owner-only folder', () async {
      final (_, link) = await host.connect();
      final path = await HostTransfer(link).reserve(key: 'abc', name: 'Report 1.pdf');

      final folder = '${host.home}/.herdr-mobile/inbox/a9993e364706'; // sha1("abc") = a9993e36 4706816a…
      expect(path, startsWith('$folder/'));
      expect(path.substring(folder.length + 1), matches(RegExp(r'^\d{8}-\d{6}-Report_1\.pdf$')));
      expect(Directory(folder).existsSync(), isTrue, reason: 'the folders are made by the reservation');
      expect(Directory(folder).statSync().mode & 0x1FF, 448, reason: 'owner only (0700)');
      expect(File(path).existsSync(), isFalse, reason: 'a name, not a file');
    });

    test('a hostile name cannot leave the inbox, and the same name twice gives two paths', () async {
      final (_, link) = await host.connect();
      final transfer = HostTransfer(link);
      final a = await transfer.reserve(key: 's', name: '../../etc/passwd');
      final b = await transfer.reserve(key: 's', name: '../../etc/passwd');

      expect(a, startsWith('${host.home}/.herdr-mobile/inbox/'));
      expect(a, isNot(contains('..')));
      expect(File(a).parent.path, File(b).parent.path);
      expect(a, isNot(b));
    });
  }, skip: skip);

  group('an upload', () {
    test('stores the file whole: progress in order from 0 to the total, the sha256 of the source, mode 0600', () async {
      final (_, link) = await host.connect();
      final bytes = pattern(5 * 1024 * 1024 + 123);
      final src = local('big.bin', bytes);
      final inbox = await HostTransfer(link).reserve(key: 'k', name: 'big.bin');

      final seen = <(int, int)>[];
      await upload(link, src, inbox, onProgress: (s, t) => seen.add((s, t))).done;

      expect(seen.first, (0, bytes.length));
      expect(seen.last, (bytes.length, bytes.length), reason: 'the end is claimed only when the host stored it');
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i].$1, greaterThanOrEqualTo(seen[i - 1].$1), reason: 'monotonic');
        expect(seen[i].$2, bytes.length);
      }
      expect(seen.where((p) => p.$1 == bytes.length), hasLength(1), reason: 'total/total once, at the very end');
      final stored = File(inbox);
      expect(sha(stored.readAsBytesSync()), sha(bytes));
      expect(stored.statSync().mode & 0x1FF, 384, reason: 'owner read/write only');
      expect(File('$inbox.part').existsSync(), isFalse);
      expect(File('$inbox.part.meta').existsSync(), isFalse);
      expect(Directory(stored.parent.path).listSync().whereType<File>(), hasLength(1), reason: 'nothing left behind');
    });

    test('an empty file is a file', () async {
      final (_, link) = await host.connect();
      final inbox = await HostTransfer(link).reserve(key: 'k', name: 'empty.txt');
      final seen = <(int, int)>[];
      await upload(link, local('empty.txt', Uint8List(0)), inbox, onProgress: (s, t) => seen.add((s, t))).done;
      expect(File(inbox).lengthSync(), 0);
      expect(seen.last, (0, 0));
    });

    test(
      'a lost connection keeps what arrived; the same file to the same path on a new link continues there',
      () async {
        final bytes = pattern(5 * 1024 * 1024);
        final src = local('resume.bin', bytes);
        final (first, link1) = await host.connect();
        final inbox = await HostTransfer(link1).reserve(key: 'k', name: 'resume.bin');

        var sentAtDrop = 0;
        var dropped = false;
        final job = upload(
          link1,
          src,
          inbox,
          onProgress: (s, t) {
            if (s >= 2 * 1024 * 1024 && !dropped) {
              dropped = true;
              sentAtDrop = s;
              first.kill();
            }
          },
        );
        await expectLater(
          job.done,
          throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.network)),
        );
        expect(File(inbox).existsSync(), isFalse, reason: 'not a file yet');
        expect(File('$inbox.part').existsSync(), isTrue, reason: 'what arrived is kept');

        await first.done;
        final (_, link2) = await host.connect();
        final seen = <(int, int)>[];
        await upload(link2, src, inbox, onProgress: (s, t) => seen.add((s, t))).done;

        final have = seen.first.$1;
        expect(have, greaterThan(0), reason: 'the host remembered the first part');
        expect(have, lessThanOrEqualTo(sentAtDrop));
        expect(
          bytes.length - have,
          lessThan(bytes.length),
          reason: 'less than the whole file went over the second time',
        );
        expect(seen.last, (bytes.length, bytes.length));
        expect(sha(File(inbox).readAsBytesSync()), sha(bytes));
        expect(File('$inbox.part').existsSync(), isFalse);
      },
    );

    test('a cancel keeps what arrived too, and fails with UploadCancelled', () async {
      final bytes = pattern(6 * 1024 * 1024);
      final src = local('cancel.bin', bytes);
      final (p1, link1) = await host.connect();
      final inbox = await HostTransfer(link1).reserve(key: 'k', name: 'cancel.bin');

      late final HostUpload job;
      var cancelled = false;
      job = upload(
        link1,
        src,
        inbox,
        onProgress: (s, t) {
          if (s >= 3 * 1024 * 1024 && !cancelled) {
            cancelled = true;
            job.cancel();
          }
        },
      );
      await expectLater(job.done, throwsA(isA<UploadCancelled>()));

      // A new connection, once the first host process is gone: two processes
      // never write one part (a live host ends with its connection).
      p1.close();
      await p1.done;
      final (_, link2) = await host.connect();
      final seen = <int>[];
      await upload(link2, src, inbox, onProgress: (s, t) => seen.add(s)).done;
      expect(seen.first, greaterThan(0), reason: 'the second try started past 0');
      expect(sha(File(inbox).readAsBytesSync()), sha(bytes));
    });

    test('a file that changes while it is sent is refused: `changed`, and no file', () async {
      final bytes = pattern(2 * 1024 * 1024);
      final src = local('moving.bin', bytes);
      final (_, link) = await host.connect();
      final inbox = await HostTransfer(link).reserve(key: 'k', name: 'moving.bin');

      var rewritten = false;
      final job = upload(
        link,
        src,
        inbox,
        onProgress: (s, t) {
          // After the file was hashed and opened, before its bytes are read: the
          // same size, other content.
          if (!rewritten) {
            rewritten = true;
            src.writeAsBytesSync(pattern(bytes.length, 17));
          }
        },
      );
      await expectLater(job.done, throwsA(isA<RemoteFileChanged>()));
      expect(File(inbox).existsSync(), isFalse, reason: 'what arrived is not the file that was announced');
      expect(File('$inbox.part').existsSync(), isFalse, reason: 'and its part is deleted, never resumed');

      // The same path takes the file as it is now.
      await upload(link, src, inbox).done;
      expect(sha(File(inbox).readAsBytesSync()), sha(src.readAsBytesSync()));
    });

    test('a path that is not a reserved inbox path is refused, and nothing is created', () async {
      final (_, link) = await host.connect();
      final src = local('x.txt', Uint8List.fromList([1, 2, 3]));
      for (final bad in [
        '${host.home}/evil.txt',
        '${host.home}/.herdr-mobile/inbox/a9993e364706/../../evil.txt',
        '${host.home}/.herdr-mobile/inbox/short/20260101-000000-x.txt',
      ]) {
        await expectLater(
          upload(link, src, bad).done,
          throwsA(
            isA<RemoteFileException>()
                .having((e) => e.kind, 'kind', RemoteFileErrorKind.failed)
                .having((e) => e.fatal, 'fatal', isTrue),
          ),
          reason: bad,
        );
      }
      expect(File('${host.home}/evil.txt').existsSync(), isFalse);
    });

    test('a file that is gone and a folder fail typed, before the host hears of them', () async {
      final (process, link) = await host.connect();
      final inbox = await HostTransfer(link).reserve(key: 'k', name: 'x');

      await expectLater(
        upload(link, File('${phone.path}/nope'), inbox).done,
        throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.notFound)),
      );
      await expectLater(
        upload(link, File(phone.path), inbox).done,
        throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.notAFile)),
      );
      expect(process.opens().where((o) => o == 'transfer.put'), isEmpty);
    });
  }, skip: skip);

  group('the sweep', () {
    test('removes old files of the inbox and nothing outside it', () async {
      final (_, link) = await host.connect();
      final base = '${host.home}/.herdr-mobile/inbox';
      final session = '$base/0123456789ab';
      Directory(session).createSync(recursive: true);
      final old = DateTime.now().subtract(const Duration(days: 20));
      File('$session/old.txt')
        ..writeAsStringSync('x')
        ..setLastModifiedSync(old);
      File('$session/fresh.txt').writeAsStringSync('x');
      Directory('${host.home}/.herdr-mobile').createSync(recursive: true);
      File('${host.home}/.herdr-mobile/outside.txt')
        ..writeAsStringSync('x')
        ..setLastModifiedSync(old);
      File('${host.home}/notes.txt')
        ..writeAsStringSync('x')
        ..setLastModifiedSync(old);

      expect(await HostTransfer(link).sweep(), 1);

      expect(File('$session/old.txt').existsSync(), isFalse);
      expect(File('$session/fresh.txt').existsSync(), isTrue);
      expect(File('${host.home}/.herdr-mobile/outside.txt').existsSync(), isTrue, reason: 'not in a session folder');
      expect(File('${host.home}/notes.txt').existsSync(), isTrue);
    });

    test('with no inbox yet it removes nothing and says so', () async {
      final (_, link) = await host.connect();
      expect(await HostTransfer(link).sweep(), 0);
    });
  }, skip: skip);

  group('a host without the transfer service', () {
    test('an upload fails as unsupported with the reason the screen shows', () async {
      final fake = FakeHost();
      final hello = HostLink.connect(fake, version: '9.9.9');
      fake.greet();
      final link = await hello;

      await expectLater(
        HostUpload(link: Future.value(link), localPath: local('a', Uint8List(1)).path, inboxPath: '/inbox/x').done,
        throwsA(
          isA<RemoteFileException>()
              .having((e) => e.kind, 'kind', RemoteFileErrorKind.unsupported)
              .having((e) => e.message, 'message', needsHostHelper),
        ),
      );
      expect(fake.opens, isEmpty, reason: 'nothing was asked of a host that cannot do it');
      await link.close();
    });

    test('the host\'s own codes become the right exceptions', () {
      RemoteFileException failure(String code) => HostTransfer.uploadFailure(HostException(code, 'said'), '/p');
      expect(failure('changed'), isA<RemoteFileChanged>());
      expect(failure('too_large').kind, RemoteFileErrorKind.tooLarge);
      expect(failure('unavailable').kind, RemoteFileErrorKind.unsupported);
      expect(failure('permission').kind, RemoteFileErrorKind.permission);
      expect(failure('bad_request').fatal, isTrue);
      expect(HostTransfer.uploadFailure(const HostLinkLost('gone'), '/p').kind, RemoteFileErrorKind.network);
    });
  });
}
