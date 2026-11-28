@TestOn('linux || mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/app_info.dart';
import 'package:herdr_mobile/data/host/host_link.dart' show HostMissing;
import 'package:herdr_mobile/data/services/keeper_command.dart';

import 'support/keeper_harness.dart';

// The commands of the REAL keeper (the `herdr-host` binary) against the
// scripted ACP agent (`fake-acp-agent` of `rust/crates/testkit`); see
// support/keeper_harness.dart.

void main() {
  Future<KeeperHost> newHost([Map<String, String> env = const {}, bool install = true]) async {
    final h = await KeeperHost.create(env);
    addTearDown(h.dispose);
    if (install) await h.install();
    return h;
  }

  group('commands', () {
    test('probe lists the routes the host can run', () async {
      final h = await newHost();
      final routes = await h.agentHost.available();
      expect(routes, contains('omp'));
      expect(agentRoutes.map((a) => a.id), containsAll(routes));
    });

    test('the commands are short', () {
      expect(hostServeCommand().length, lessThan(1024));
      // The install command embeds the full install-host.sh script; it is
      // self-contained (nothing travels on stdin) and must fit under the
      // 9000-byte Dropbear exec cap.
      expect(keeperInstallCommand().length, lessThan(9000));
    });

    test('the install command pins this app version and carries tool/install-host.sh verbatim', () {
      // The phone embeds the installer in keeper_command.dart; the repo file is
      // the source of truth. Decode the command's base64 and check it is the
      // file behind the version assignment, so the two cannot drift.
      final file = File('../tool/install-host.sh');
      expect(file.existsSync(), isTrue, reason: 'run from app/');
      final m = RegExp(r'echo (\S+) \|').firstMatch(keeperInstallCommand());
      expect(m, isNotNull);
      final embedded = utf8.decode(base64.decode(m![1]!));
      expect(embedded, startsWith("VERSION='v$appVersion'; export VERSION\n"));
      expect(embedded, endsWith(file.readAsStringSync()));
    });

    test('the serve command execs the version-pinned binary', () {
      final m = RegExp(r'echo (\S+) \|').firstMatch(hostServeCommand());
      expect(m, isNotNull);
      final script = utf8.decode(base64.decode(m![1]!));
      expect(script, contains('herdr-host-$appVersion'));
      expect(script.trimRight().split('\n').last, r'exec "$b" serve');
    });

    test('the install command installs the pinned release as herdr-host-<version> and serve runs it', () async {
      final h = await newHost(const {}, false);
      final bin = hostBinary();
      expect(bin.existsSync(), isTrue, reason: 'build it: cd rust && cargo build --release -p host');
      // A release folder as the installer sees it: this platform's asset and
      // the checksum file. The installer picks the asset by `uname`.
      final uname = (await Process.run('uname', ['-sm'])).stdout.toString().trim();
      final asset = switch (uname) {
        'Linux x86_64' => 'herdr-host-linux-x86_64',
        'Linux aarch64' || 'Linux arm64' => 'herdr-host-linux-aarch64',
        'Darwin arm64' => 'herdr-host-macos-arm64',
        'Darwin x86_64' => 'herdr-host-macos-x86_64',
        _ => fail('no release asset for $uname'),
      };
      final release = Directory('${h.home.path}/release')..createSync();
      File('${release.path}/$asset').writeAsBytesSync(bin.readAsBytesSync());
      final sum = (await Process.run('sha256sum', ['${release.path}/$asset'])).stdout.toString().split(' ').first;
      File('${release.path}/herdr-host-SHA256SUMS').writeAsStringSync('$sum  $asset\n');
      final r = await h.run(keeperInstallCommand(), environment: {'HERDR_HOST_BASE_URL': 'file://${release.path}'});
      expect(r.code, 0, reason: r.err);
      expect(r.out.trim().split('\n').last, '{"ok":true}');
      final bin2 = File('${h.home.path}/.herdr-mobile/bin/$hostBinaryName');
      expect(bin2.existsSync(), isTrue, reason: 'the installer names the file after the binary --version');
      expect(FileStat.statSync(bin2.path).mode & 0x1ff, 0x1c0); // 0700
      expect(await h.agentHost.available(), contains('omp'), reason: 'serve finds what the installer put there');
      // A corrupted download is refused and nothing new is left behind.
      File('${release.path}/herdr-host-SHA256SUMS').writeAsStringSync('${'0' * 64}  $asset\n');
      bin2.deleteSync();
      final bad = await h.run(keeperInstallCommand(), environment: {'HERDR_HOST_BASE_URL': 'file://${release.path}'});
      expect(bad.code, isNot(0));
      expect(bad.err, contains('checksum mismatch'));
      final binDir = Directory('${h.home.path}/.herdr-mobile/bin');
      expect(binDir.existsSync() ? binDir.listSync() : [], isEmpty);
    });

    test('a host without the helper exits 65 until it is installed', () async {
      final h = await newHost(const {}, false);
      final r = await h.run(hostServeCommand());
      expect(r.code, 65, reason: r.err);
      expect(r.err, contains('not installed'));
      expect(r.out, isEmpty);
      await expectLater(h.openLink(), throwsA(isA<HostMissing>()));
      expect(Directory('${h.home.path}/.herdr-mobile').existsSync(), isFalse);
      await h.install();
      expect(await h.agentHost.available(), contains('omp'));
    });

    test('install puts the binary in place, is idempotent and leaves no temp files', () async {
      final h = await newHost(const {}, false);
      final file = File('${h.home.path}/.herdr-mobile/bin/$hostBinaryName');
      await h.install();
      expect(file.existsSync(), isTrue);
      expect(FileStat.statSync(file.path).mode & 0x1ff, 0x1c0); // 0700
      // The binary is the prebuilt one: same size, and it reports a version.
      final v = await h.run('"\$HOME/.herdr-mobile/bin/$hostBinaryName" --version');
      expect(v.code, 0, reason: v.err);
      expect(v.out, contains('herdr-host'));
      // Idempotent: a second install leaves the same binary.
      final before = file.lengthSync();
      await h.install();
      expect(file.lengthSync(), before);
      // Only the binary in the bin dir.
      expect(Directory('${h.home.path}/.herdr-mobile/bin').listSync().length, 1);
    });

    test('the host refuses an unknown agent, a bad folder and a bad keeper id', () async {
      final h = await newHost();
      for (final bad in ['', 'gpt', 'OMP', 'omp; id', r'$(id)', 'omp ', "omp'"]) {
        final r = await h.runStart(agent: bad, cwd: '/tmp');
        expect(r.code, 64, reason: '$bad: ${r.err}');
      }
      for (final bad in ['', 'a\nb', 'a\u0000b', 'a\rb', 'x' * 5000]) {
        final r = await h.runStart(cwd: bad);
        expect(r.code, 64, reason: bad.length > 20 ? 'long' : bad);
      }
      for (final bad in ['', 'a b', r'$(id)', '../x', 'A1b2c3', "ab'c", 'a;b', 'ab', 'x' * 33]) {
        expect((await h.attachAndLeave(bad)).code, 64, reason: bad);
        expect((await h.kill(bad)).code, 64, reason: bad);
      }
      expect(await h.list(), isEmpty);
    });

    test('a folder name cannot break out of anything', () async {
      final h = await newHost();
      final marker = '${h.home.path}/pwned';
      for (final evil in [
        "x'; touch $marker; '",
        '\$(touch $marker)',
        '`touch $marker`',
        'x"; touch $marker; "',
        'a b; touch $marker',
        '-rf',
      ]) {
        final r = await h.runStart(cwd: evil);
        expect(r.code, 66, reason: '$evil: ${r.err}');
        expect(r.err, contains('does not exist'));
        expect(File(marker).existsSync(), isFalse, reason: evil);
      }
      expect(await h.list(), isEmpty);
    });

    test('a folder with spaces and quotes works, and ~ expands on the host', () async {
      final h = await newHost();
      final odd = Directory('${h.home.path}/it\'s a "dir" \$HOME `x`')..createSync();
      final sub = Directory('${h.home.path}/sub dir')..createSync();
      final a = await h.start(cwd: odd.path);
      expect(a.cwd, odd.path);
      final b = await h.start(cwd: '~');
      expect(b.cwd, h.home.path);
      final c = await h.start(cwd: '~/sub dir');
      expect(c.cwd, sub.path);
    });

    test('unknown keeper ids exit 66', () async {
      final h = await newHost();
      expect((await h.attachAndLeave('zzzzzz')).code, 66);
      final k = await h.kill('zzzzzz');
      expect(k.code, 66);
      expect(k.err, contains('no such keeper'));
    });
  });

  group('KeeperInfo', () {
    test('reads what the script prints', () {
      final info = KeeperInfo.fromJson(
        asJson(
          jsonDecode(
            '{"id":"abc234","agent":"omp","cwd":"/w","state":"exited","started_at":1791107532538,'
            '"pid":42,"pending":0,"agent_pid":43,"session_id":"s","title":"t","last_event_at":1791107547185,'
            '"exit_code":3,"exit_reason":"The agent exited with code 3. boom","exited_at":1791107567577}',
          ),
        ),
      );
      expect(info.id, 'abc234');
      expect(info.state, KeeperState.exited);
      expect(info.startedAt, DateTime.fromMillisecondsSinceEpoch(1791107532538));
      expect(info.lastEventAt, DateTime.fromMillisecondsSinceEpoch(1791107547185));
      expect(info.pid, 42);
      expect(info.exitCode, 3);
      expect(info.exitReason, contains('boom'));
      expect(info.sessionId, 's');
      expect(info.title, 't');
      final back = KeeperInfo.fromJson(info.toJson());
      expect(back.exitReason, info.exitReason);
      expect(back.exitCode, 3);
    });

    test('turn_active and unseen_done default to false and round-trip', () {
      final bare = KeeperInfo.fromJson({'id': 'abc234', 'state': 'running'});
      expect(bare.turnActive, isFalse);
      expect(bare.unseenDone, isFalse);
      final set = KeeperInfo.fromJson({'id': 'abc234', 'turn_active': true, 'unseen_done': true, 'state': 'starting'});
      expect(set.turnActive, isTrue);
      expect(set.unseenDone, isTrue);
      expect(set.state, KeeperState.starting);
      final back = KeeperInfo.fromJson(set.toJson());
      expect(back.turnActive, isTrue);
      expect(back.unseenDone, isTrue);
      expect(KeeperInfo.fromJson({'id': 'x', 'turn_active': 'yes'}).turnActive, isFalse);
    });
  });
}
