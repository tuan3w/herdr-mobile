@TestOn('linux || mac-os')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/host/host_link.dart';
import 'package:herdr_mobile/data/host/host_transfer.dart' show needsHostHelper;
import 'package:herdr_mobile/data/host/wire.dart' show FrameKind;
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/models/remote_search.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart' show hostServeCommand;
import 'package:herdr_mobile/data/services/sftp_files.dart';
import 'package:herdr_mobile/data/services/ssh_transport.dart';
import 'package:image/image.dart' as img;

import 'support/fake_host.dart';
import 'support/host_serve.dart';

// Which backend a machine's files come from: the agent helper's `fs` when the
// machine has it, SFTP (read-only) when it has not, and what writing says on a
// machine without the helper. The machine here is scripted (a helper that is
// missing and cannot be installed, a helper without `fs`) or the real binary.

/// An SFTP session with one folder and one file, counting how often it was opened.
class _Sftp implements SftpApi {
  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async => SftpFileAttrs(
    size: path == '/home/dev' ? 4096 : 5,
    mode: SftpFileMode.value(path == '/home/dev' ? 0x41ED : 0x81A4),
    modifyTime: 1700000000,
  );

  @override
  Future<List<SftpName>> listdir(String path) async => [
    SftpName(
      filename: 'a.txt',
      longname: 'a.txt',
      attr: SftpFileAttrs(size: 5, mode: const SftpFileMode.value(0x81A4), modifyTime: 1700000000),
    ),
  ];

  @override
  Future<String> absolute(String path) async => '/home/dev';

  @override
  Future<String> readlink(String path) async => path;

  @override
  Future<Uint8List> readBytes(String path, int offset, int length) async =>
      Uint8List.fromList('hello'.codeUnits.sublist(offset.clamp(0, 5), (offset + length).clamp(0, 5)));

  @override
  Future<void> close() async {}
}

const _profile = MachineProfile(id: 'm', label: 'm', host: 'h', username: 'u');

void main() {
  late List<String> commands;
  late int sftpOpens;
  late SshTransport transport;

  SshTransport make(Future<HostProcess> Function(String command) host) => transport = SshTransport(
    profile: _profile,
    secrets: const MachineSecrets(),
    onPinHostKey: (_) {},
    openHostProcess: (command) {
      commands.add(command);
      return host(command);
    },
    openSftp: () async {
      sftpOpens++;
      return _Sftp();
    },
  );

  setUp(() {
    commands = [];
    sftpOpens = 0;
  });
  tearDown(() => transport.close());

  group('a machine where the helper is missing and cannot be installed', () {
    // `serve` exits 65 (not installed), the installer exits 1 (no download).
    Future<HostProcess> broken(String command) async => FakeHost()..exit(command == hostServeCommand() ? 65 : 1);

    test('browsing and reading go through SFTP, once the verdict is in, without asking the machine again', () async {
      make(broken);

      expect((await transport.statFile('/home/dev/a.txt')).size, 5);
      expect((await transport.listDirectory('/home/dev')).single.name, 'a.txt');
      expect(String.fromCharCodes(await transport.readFile('/home/dev/a.txt', length: 3)), 'hel');
      expect(await transport.realPath('.'), '/home/dev');
      expect(await transport.watchFile('/home/dev/a.txt').first, isNotNull, reason: 'SFTP watches by polling stat');

      expect(sftpOpens, greaterThan(0));
      expect(commands.where((c) => c == hostServeCommand()), hasLength(1), reason: 'the verdict is remembered');
      expect(commands, hasLength(2), reason: 'one try to serve, one install; no more');
    });

    test('an ifMatch the SFTP backend cannot check does not stop a read', () async {
      make(broken);
      final seen = await transport.statFile('/home/dev/a.txt');
      final other = RemoteStat(path: seen.path, kind: RemoteEntryKind.file, size: 999);

      expect(String.fromCharCodes(await transport.readFile('/home/dev/a.txt', length: 5, ifMatch: other)), 'hello');
    });

    test('reserving, uploading and sweeping say what is missing instead of failing oddly', () async {
      make(broken);
      final src = File('${Directory.systemTemp.createTempSync('ssh_files').path}/a.txt')..writeAsStringSync('x');
      addTearDown(() => src.parent.deleteSync(recursive: true));

      Matcher unsupported() => throwsA(
        isA<RemoteFileException>()
            .having((e) => e.kind, 'kind', RemoteFileErrorKind.unsupported)
            .having((e) => e.message, 'message', needsHostHelper),
      );
      await expectLater(transport.reserveInboxFile(key: 's', name: 'a.txt'), unsupported());
      await expectLater(transport.sweepInbox(), unsupported());
      await expectLater(transport.uploadFile(localPath: src.path, inboxPath: '/inbox/x').done, unsupported());
    });

    test('no thumbnails, and a search is the bounded walk over SFTP', () async {
      make(broken);

      expect(await transport.thumbnailFile('/home/dev/a.txt'), isNull, reason: 'the caller keeps its own way');
      final events = await transport.searchFiles(const FileSearchSpec(root: '/home/dev', query: 'a.t')).toList();

      expect((events.first as FileSearchBatch).entries.single.path, '/home/dev/a.txt');
      expect((events.last as FileSearchDone).truncated, isFalse);
      expect(sftpOpens, greaterThan(0));
    });
  });

  group('a machine whose helper has no fs', () {
    Future<HostProcess> noFs(String command) async => FakeHost()
      ..greet(
        services: {
          'herdr': {'available': true, 'reason': null},
          'fs': {'available': false, 'reason': 'not here'},
        },
      );

    test('files come over SFTP while the link to the helper stays up', () async {
      make(noFs);
      expect((await transport.statFile('/home/dev/a.txt')).size, 5);
      expect(sftpOpens, greaterThan(0));
      expect(commands, hasLength(1));
    });

    test('no thumbnails, and a search is the walk over SFTP', () async {
      make(noFs);

      expect(await transport.thumbnailFile('/home/dev/a.txt'), isNull);
      final events = await transport.searchFiles(const FileSearchSpec(root: '/home/dev', query: 'a.t')).toList();

      expect((events.first as FileSearchBatch).entries.single.path, '/home/dev/a.txt');
      expect((events.last as FileSearchDone).truncated, isFalse);
      expect(sftpOpens, greaterThan(0));
    });
  });

  group('a machine whose helper has fs but is older than fs.thumb and fs.search', () {
    // The helper answers `unknown_method` to what it does not have; its fs.list works.
    Future<HostProcess> older(String command) async {
      final host = FakeHost()
        ..greet(
          services: {
            'fs': {'available': true, 'reason': null},
          },
        );
      host.onFrame = (f) {
        if (f.kind != FrameKind.open) return;
        final o = jsonDecode(utf8.decode(f.payload)) as Map;
        switch (o['method']) {
          case 'list':
            host.sendJson(FrameKind.msg, f.stream, {
              'entries': [
                {'name': 'a.txt', 'kind': 'file', 'size': 5, 'mtime_ms': 1700000000000, 'mode': 420},
              ],
            });
            host.sendJson(FrameKind.end, f.stream, {});
          default:
            host.sendJson(FrameKind.end, f.stream, {
              'error': {'code': 'unknown_method', 'message': 'no such method', 'retryable': false},
            });
        }
      };
      return host;
    }

    test('a thumbnail is null and a search is the walk over the helper\u2019s listing, never an error', () async {
      make(older);

      expect(await transport.thumbnailFile('/home/dev/a.txt'), isNull);
      final events = await transport.searchFiles(const FileSearchSpec(root: '/home/dev', query: 'a.t')).toList();

      expect((events.first as FileSearchBatch).entries.single.path, '/home/dev/a.txt');
      expect(events.last, isA<FileSearchDone>());
      expect(sftpOpens, 0, reason: 'the helper\u2019s own fs.list did the walking');
    });
  });

  group('a machine with the helper', () {
    final skip = hostBinarySkip();
    late ServedHost served;

    setUp(() => served = ServedHost());
    tearDown(() => served.dispose());

    test('files come from the helper, not SFTP; a reset decides again on a new link', () async {
      final file = File('${served.home}/a.txt')..writeAsStringSync('hello');
      make((command) async => served.start());

      expect((await transport.statFile(file.path)).size, 5);
      expect(String.fromCharCodes(await transport.readFile(file.path, offset: 1, length: 3)), 'ell');
      expect(await transport.realPath('~'), served.home);
      expect(sftpOpens, 0, reason: 'SFTP was never needed');
      expect(commands, hasLength(1), reason: 'one helper process serves all of it');

      transport.reset();
      await Future<void>.delayed(Duration.zero);
      expect((await transport.statFile(file.path)).size, 5);
      expect(commands, hasLength(2), reason: 'a reset starts the helper again and decides again');
      expect(sftpOpens, 0);
    }, skip: skip);

    test('an upload goes through the helper to the inbox, and the sweep and reserve too', () async {
      final src = File('${served.home}/phone.bin')..writeAsBytesSync(List.generate(70000, (i) => i & 0xFF));
      make((command) async => served.start());

      final inbox = await transport.reserveInboxFile(key: 'session', name: 'phone.bin');
      expect(inbox, startsWith('${served.home}/.herdr-mobile/inbox/'));
      final seen = <int>[];
      await transport.uploadFile(localPath: src.path, inboxPath: inbox, onProgress: (s, t) => seen.add(s)).done;
      expect(File(inbox).readAsBytesSync(), src.readAsBytesSync());
      expect(seen.last, 70000);
      expect(await transport.sweepInbox(), 0);
    }, skip: skip);

    test('a thumbnail is made by the helper, and a search is its fs.search, not a walk', () async {
      File('${served.home}/pic.png').writeAsBytesSync(img.encodePng(img.Image(width: 640, height: 480)));
      File('${served.home}/notes-pic.txt').writeAsStringSync('x');
      make((command) async => served.start());

      final thumb = await transport.thumbnailFile('${served.home}/pic.png', maxPx: 128);
      final events = await transport.searchFiles(FileSearchSpec(root: served.home, query: 'pic')).toList();

      expect(img.decodeJpg(thumb!)!.width, 128);
      final names = [for (final b in events.whereType<FileSearchBatch>()) ...b.entries.map((e) => e.name)];
      expect(names, unorderedEquals(['pic.png', 'notes-pic.txt']));
      expect(events.last, isA<FileSearchDone>());
      expect(sftpOpens, 0, reason: 'SFTP was never needed');
    }, skip: skip);
  });
}
