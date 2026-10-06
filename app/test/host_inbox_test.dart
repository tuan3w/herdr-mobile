import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/repositories/host_inbox.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';

final _now = DateTime(2026, 10, 5, 9, 8, 7);
const _stamp = '20261005-090807';
const _base = '/home/dev/.herdr-mobile/inbox';

void main() {
  group('inboxSafeName', () {
    final safe = RegExp(r'^[\p{L}\p{M}\p{N}._-]+$', unicode: true);

    test('hostile and odd names become sane names', () {
      const cases = {
        '../x': 'x',
        '../../.ssh/authorized_keys': 'authorized_keys',
        'a/b': 'b',
        r'C:\Users\me\Report 1.docx': 'Report_1.docx',
        '.bashrc': 'bashrc',
        '...hidden.txt': 'hidden.txt',
        '': 'file',
        '   ': 'file',
        '..': 'file',
        '/': 'file',
        'x/..': 'file',
        '😀': 'file',
        'x😀y.png': 'x_y.png',
        'tài liệu.pdf': 'tài_liệu.pdf',
        'Bản vẽ kỹ thuật (v2).dwg': 'Bản_vẽ_kỹ_thuật__v2_.dwg',
        'a\u202eb.txt': 'a_b.txt', // right-to-left override
        'name\n.txt': 'name_.txt',
        'photo.JPG': 'photo.JPG',
        'archive.tar.gz': 'archive.tar.gz',
        'noext': 'noext',
        'trailing.': 'trailing.',
      };
      cases.forEach((input, want) => expect(inboxSafeName(input), want, reason: 'for ${jsonEncode(input)}'));
      // A decomposed Vietnamese name keeps its combining marks.
      expect(inboxSafeName('ta\u0300i.pdf'), 'ta\u0300i.pdf');
    });

    test('a long name is cut to 100 characters and 200 bytes, the extension stays', () {
      final long = '${'a' * 300}.txt';
      final cut = inboxSafeName(long);
      expect(cut.length, 100);
      expect(cut, endsWith('.txt'));

      // Three bytes a letter: the byte cap bites before the character cap.
      final viet = inboxSafeName('${'ệ' * 150}.pdf');
      expect(utf8.encode(viet).length, lessThanOrEqualTo(200));
      expect(viet, endsWith('.pdf'));
      expect(viet.runes.length, lessThan(100));
      expect(viet, matches(safe));

      // Four bytes a letter (outside the BMP).
      final astral = inboxSafeName('${String.fromCharCode(0x20000) * 120}.pdf');
      expect(utf8.encode(astral).length, lessThanOrEqualTo(200));
      expect(astral, matches(safe));
    });

    test('whatever goes in, the result is a safe, non-hidden, non-empty file name', () {
      final inputs = [
        '../../etc/passwd', 'a\u0000b', '.', '....', '~/x', r'..\..\win', 'x\t\ty', '\u{1F600}\u{1F600}.png',
        'with space and ünïcödé.txt', '.ssh', 'CON', 'a:b*c?.txt', '"quoted".md', 'x' * 500,
      ];
      for (final input in inputs) {
        final out = inboxSafeName(input);
        expect(out, isNotEmpty, reason: input);
        expect(out, matches(safe), reason: input);
        expect(out.startsWith('.'), isFalse, reason: input);
        expect(out.length, lessThanOrEqualTo(100), reason: input);
      }
    });
  });

  group('reserving a path', () {
    late FakeFs fs;
    late FakeTransport transport;
    late RemoteFiles files;
    late HostInbox inbox;

    setUp(() {
      fs = FakeFs()..addDir('/home/dev/.herdr-mobile/keepers');
      transport = FakeTransport()..fs = fs;
      files = RemoteFiles(transport);
      inbox = HostInbox(files, now: () => _now);
    });

    test('lands under the inbox in a folder named by the session key hash', () async {
      expect(HostInbox.sessionFolder('abc'), 'a9993e364706'); // sha1("abc") = a9993e36 4706816a...
      final path = await inbox.reserve(sessionKey: 'abc', fileName: 'tài liệu.pdf');
      expect(path, '$_base/a9993e364706/$_stamp-tài_liệu.pdf');
      expect(fs.nodes['$_base/a9993e364706']!.isDir, isTrue);
      final other = await inbox.reserve(sessionKey: 'abd', fileName: 'x.txt');
      expect(other, isNot(startsWith('$_base/a9993e364706/')));
    });

    test('creates the folders 0700 and leaves the existing ones as they were', () async {
      await inbox.reserve(sessionKey: 's', fileName: 'x');
      final folder = '$_base/${HostInbox.sessionFolder('s')}';
      expect(fs.nodes[_base]!.mode, 0x41C0);
      expect(fs.nodes[folder]!.mode, 0x41C0);
      expect(fs.nodes['/home/dev/.herdr-mobile']!.mode, 0x41ED, reason: 'the keepers folder is not ours');
      expect(fs.nodes['/home/dev/.herdr-mobile/keepers']!.mode, 0x41ED);
    });

    test('a hostile file name stays inside the session folder', () async {
      final folder = '$_base/${HostInbox.sessionFolder('s')}';
      for (final name in [
        '../x',
        '../../.ssh/authorized_keys',
        'a/b',
        '.bashrc',
        '',
        'a' * 300,
        '😀',
        'tài liệu.pdf',
        r'..\..\x',
        '/etc/passwd',
      ]) {
        final path = await inbox.reserve(sessionKey: 's', fileName: name);
        expect(path, startsWith('$folder/$_stamp-'), reason: name);
        final leaf = path.substring(folder.length + 1);
        expect(leaf, isNot(contains('/')), reason: name);
        expect(leaf.length, lessThanOrEqualTo(255), reason: name);
        expect(leaf, isNot(contains('..')), reason: name);
      }
    });

    test('a name taken on the host gets -2, -3 before the extension', () async {
      final folder = '$_base/${HostInbox.sessionFolder('s')}';
      fs.addFile('$folder/$_stamp-report.pdf', 'x');
      expect(await inbox.reserve(sessionKey: 's', fileName: 'report.pdf'), '$folder/$_stamp-report-2.pdf');
      fs.addFile('$folder/$_stamp-report-2.pdf', 'x');
      fs.addFile('$folder/$_stamp-report-3.pdf', 'x');
      // A fresh inbox object (a new run) sees only what is on the host.
      final next = HostInbox(files, now: () => _now);
      expect(await next.reserve(sessionKey: 's', fileName: 'report.pdf'), '$folder/$_stamp-report-4.pdf');

      fs.addFile('$folder/$_stamp-notes', 'x');
      expect(await next.reserve(sessionKey: 's', fileName: 'notes'), '$folder/$_stamp-notes-2');
    });

    test('two files reserved at once never get the same path', () async {
      final paths = await Future.wait([
        for (var i = 0; i < 5; i++) inbox.reserve(sessionKey: 's', fileName: 'IMG.jpg'),
      ]);
      expect(paths.toSet(), hasLength(5));
      final folder = '$_base/${HostInbox.sessionFolder('s')}';
      expect(paths.first, '$folder/$_stamp-IMG.jpg');
      expect(paths, contains('$folder/$_stamp-IMG-5.jpg'));
    });

    test('the folder is made once per run, not once per file', () async {
      for (var i = 0; i < 4; i++) {
        await inbox.reserve(sessionKey: 's', fileName: 'f$i');
      }
      expect(fs.calls.where((c) => c.startsWith('mkdirs')), hasLength(1));
      await inbox.reserve(sessionKey: 'another', fileName: 'f');
      expect(fs.calls.where((c) => c.startsWith('mkdirs')), hasLength(2));
    });

    test('a folder that cannot be made fails the reservation with a typed error', () async {
      fs.deny.add('/home/dev/.herdr-mobile');
      await expectLater(
        inbox.reserve(sessionKey: 's', fileName: 'x'),
        throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.permission)),
      );
      // And the failure is not remembered as a made folder.
      fs.deny.clear();
      expect(await inbox.reserve(sessionKey: 's', fileName: 'x'), contains(_base));
    });

    test('the top-level helper takes the machine and uses its home', () async {
      final machine = MachineConnection(
        profile: const MachineProfile(id: 'm', label: 'box', host: 'h', username: 'u'),
        api: HerdrApi(transport),
      );
      final path = await reserveInboxPath(machine, sessionKey: 'k', fileName: '../../a.txt');
      expect(path, matches(RegExp(r'^/home/dev/\.herdr-mobile/inbox/[0-9a-f]{12}/\d{8}-\d{6}-a\.txt$')));
    });
  });

  group('cleanup', () {
    late FakeFs fs;
    late RemoteFiles files;
    late HostInbox inbox;
    const hash = 'aaaaaaaaaaaa';
    DateTime ago(int days) => _now.toUtc().subtract(Duration(days: days));

    setUp(() {
      fs = FakeFs();
      files = RemoteFiles(FakeTransport()..fs = fs);
      inbox = HostInbox(files, now: () => _now);
    });

    test('deletes only old regular files directly inside session folders of the inbox', () async {
      fs.addFile('$_base/$hash/old-20d', 'x', modified: ago(20));
      fs.addFile('$_base/$hash/old-15d', 'x', modified: ago(15));
      fs.addFile('$_base/$hash/new-13d', 'x', modified: ago(13));
      fs.addFile('$_base/$hash/exactly-14d', 'x', modified: ago(14));
      fs.addFile('$_base/bbbbbbbbbbbb/old-other-session', 'x', modified: ago(40));
      // Not to be touched:
      fs.addLink('$_base/$hash/old-link', '/home/dev/precious');
      fs.addFile('/home/dev/precious', 'x', modified: ago(90));
      fs.addFile('$_base/$hash/sub/deep-old', 'x', modified: ago(90)); // a folder in a session folder
      fs.addFile('$_base/not-a-hash/old', 'x', modified: ago(90));
      fs.addFile('$_base/top-level-old', 'x', modified: ago(90));
      fs.addFile('/home/dev/.herdr-mobile/keepers/state', 'x', modified: ago(90));
      fs.addFile('/home/dev/notes.txt', 'x', modified: ago(90));
      fs.addFile('$_base/CCCCCCCCCCCC/old-upper-case-name', 'x', modified: ago(90));

      expect(await inbox.cleanup(), 3);

      expect(fs.nodes.keys.where((p) => p.startsWith('$_base/$hash/')).toSet(), {
        '$_base/$hash/new-13d',
        '$_base/$hash/exactly-14d',
        '$_base/$hash/old-link',
        '$_base/$hash/sub',
        '$_base/$hash/sub/deep-old',
      });
      for (final kept in [
        '/home/dev/precious',
        '$_base/not-a-hash/old',
        '$_base/top-level-old',
        '/home/dev/.herdr-mobile/keepers/state',
        '/home/dev/notes.txt',
        '$_base/CCCCCCCCCCCC/old-upper-case-name',
      ]) {
        expect(fs.nodes, contains(kept));
      }
      expect(fs.nodes, isNot(contains('$_base/bbbbbbbbbbbb/old-other-session')));
      // Only the inbox was ever listed.
      expect(fs.calls.where((c) => c.startsWith('list')).map((c) => c.substring(5)),
          everyElement(startsWith(_base)));
    });

    test('never deletes more than the cap', () async {
      for (final h in ['111111111111', '222222222222', '333333333333']) {
        for (var i = 0; i < 100; i++) {
          fs.addFile('$_base/$h/f$i', 'x', modified: ago(30));
        }
      }
      expect(await inbox.cleanup(), inboxCleanupCap);
      expect(fs.nodes.keys.where((p) => RegExp(r'/f\d+$').hasMatch(p)), hasLength(300 - inboxCleanupCap));
      expect(await inbox.cleanup(cap: 7), 7);
      expect(await inbox.cleanup(), 93);
    });

    test('no inbox, no files on the host, or a failing link: quietly nothing', () async {
      expect(await inbox.cleanup(), 0);
      expect(await HostInbox(RemoteFiles(FakeTransport()), now: () => _now).cleanup(), 0);
      fs.addFile('$_base/$hash/old', 'x', modified: ago(30));
      fs.fail = StateError('link down');
      expect(await inbox.cleanup(), 0);
      fs.fail = null;
      expect(fs.nodes, contains('$_base/$hash/old'));
    });

    test('a file it may not remove does not stop the rest', () async {
      fs.addFile('$_base/$hash/locked', 'x', modified: ago(30));
      fs.addFile('$_base/$hash/free', 'x', modified: ago(30));
      fs.deny.add('$_base/$hash/locked');
      expect(await inbox.cleanup(), 1);
      expect(fs.nodes, contains('$_base/$hash/locked'));
      expect(fs.nodes, isNot(contains('$_base/$hash/free')));
    });
  });

  group('InboxJanitor', () {
    test('watch sweeps when the machine first goes online, once per run', () async {
      final fs = FakeFs()..addFile('$_base/aaaaaaaaaaaa/old', 'x', modified: DateTime.utc(2026, 1, 1));
      final machine = MachineConnection(
        profile: const MachineProfile(id: 'm3', label: 'box', host: 'h', username: 'u'),
        api: HerdrApi(FakeTransport()..fs = fs),
        pollInterval: const Duration(hours: 1),
      );
      addTearDown(machine.dispose);
      final log = _MemoryLog();
      InboxJanitor(log, startDelay: Duration.zero).watch(machine);
      expect(fs.nodes, contains('$_base/aaaaaaaaaaaa/old'), reason: 'not before the machine is online');
      machine.start();
      await eventually(() => !fs.nodes.containsKey('$_base/aaaaaaaaaaaa/old') && log.runs.isNotEmpty,
          reason: 'the sweep after going online');
    });

    test('sweeps a machine at most once per 24 hours and skips machines without files', () async {
      final fs = FakeFs()..addFile('$_base/aaaaaaaaaaaa/old', 'x', modified: DateTime.utc(2026, 1, 1));
      final machine = MachineConnection(
        profile: const MachineProfile(id: 'm1', label: 'box', host: 'h', username: 'u'),
        api: HerdrApi(FakeTransport()..fs = fs),
      );
      var clock = _now;
      final log = _MemoryLog();
      final janitor = InboxJanitor(log, now: () => clock);

      expect(await janitor.run(machine), 1);
      fs.addFile('$_base/aaaaaaaaaaaa/old2', 'x', modified: DateTime.utc(2026, 1, 1));
      clock = clock.add(const Duration(hours: 23));
      expect(await janitor.run(machine), isNull, reason: 'swept 23 h ago');
      clock = clock.add(const Duration(hours: 2));
      expect(await janitor.run(machine), 1);

      final bare = MachineConnection(
        profile: const MachineProfile(id: 'm2', label: 'bare', host: 'h', username: 'u'),
        api: HerdrApi(FakeTransport()),
      );
      expect(await janitor.run(bare), isNull);
      expect(log.runs.containsKey('m2'), isFalse);
    });
  });
}

class _MemoryLog implements InboxCleanupLog {
  final runs = <String, DateTime>{};

  @override
  Future<DateTime?> lastRun(String machineId) async => runs[machineId];

  @override
  Future<void> record(String machineId, DateTime at) async => runs[machineId] = at;
}
