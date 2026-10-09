@TestOn('linux || mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart';

import 'support/keeper_harness.dart';

// The commands of the REAL keeper script (python3) against the scripted ACP agent
// (`test/support/fake_acp_agent.py`); see support/keeper_harness.dart.

void main() {
  final hasPython = pythonDir() != null;

  Future<KeeperHost> newHost([Map<String, String> env = const {}, bool install = true]) async {
    final h = await KeeperHost.create(env);
    addTearDown(h.dispose);
    if (install) await h.install();
    return h;
  }

  group('commands', skip: hasPython ? false : 'python3 is not installed', () {
    test('probe lists the routes the host can run', () async {
      final h = await newHost();
      final r = await h.run(keeperProbeCommand());
      expect(r.code, 0, reason: r.err);
      final routes = (asJson(jsonDecode(r.out))['routes'] as List).cast<String>();
      expect(routes, contains('omp'));
      expect(agentRoutes.map((a) => a.id), containsAll(routes));
    });

    test('every command but install is short', () {
      final commands = [
        keeperProbeCommand(),
        keeperListCommand(),
        keeperStartCommand(agent: 'omp', cwd: '/tmp/${'x' * 200}'),
        keeperAttachCommand('abc234'),
        keeperKillCommand('abc234'),
      ];
      for (final c in commands) {
        expect(c.length, lessThan(1024));
      }
      expect(keeperInstallCommand().length, lessThan(2048)); // Dropbear refuses an exec over 9000 bytes
      final payload = keeperInstallPayload();
      expect(payload.length, inInclusiveRange(10000, 60000));
      expect(payload.trimRight().split('\n').every((l) => l.length <= 76), isTrue);
      expect(payload.endsWith('\n'), isTrue);
    });

    test('a broken payload installs nothing and says so', () async {
      final h = await newHost(const {}, false);
      final r = await h.run(keeperInstallCommand(), input: 'not base64 of a deflated script\n');
      expect(r.code, isNot(0));
      expect(r.out, isNot(contains('"ok"')));
      final dir = Directory('${h.home.path}/.herdr-mobile');
      expect(!dir.existsSync() || dir.listSync().isEmpty, isTrue);
    });

    test('a host without the keeper exits 65 until it is installed', () async {
      final h = await newHost(const {}, false);
      for (final c in [
        keeperProbeCommand(),
        keeperListCommand(),
        keeperStartCommand(agent: 'omp', cwd: h.work),
        keeperAttachCommand('abc234'),
        keeperKillCommand('abc234'),
      ]) {
        final r = await h.run(c);
        expect(r.code, 65, reason: r.err);
        expect(r.err, contains('not installed'));
        expect(r.out, isEmpty);
      }
      expect(Directory('${h.home.path}/.herdr-mobile').existsSync(), isFalse);
      await h.install();
      expect((await h.run(keeperProbeCommand())).code, 0);
    });

    test('install writes a private file, is idempotent and leaves no temp files', () async {
      final h = await newHost(const {}, false);
      final file = File('${h.home.path}/.herdr-mobile/keeper-${keeperScriptVersion(keeperScript())}.py');
      await h.install();
      expect(file.readAsStringSync(), keeperScript());
      expect(FileStat.statSync(file.path).mode & 0x1ff, 0x1c0); // 0700
      expect(FileStat.statSync('${h.home.path}/.herdr-mobile').mode & 0x1ff, 0x1c0);
      await h.install();
      expect(file.readAsStringSync(), keeperScript());
      expect(Directory('${h.home.path}/.herdr-mobile').listSync().map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last), [file.uri.pathSegments.last]);
    });

    test('installing is atomic: a reader never sees half a script', () async {
      final h = await newHost(const {}, false);
      final file = File('${h.home.path}/.herdr-mobile/keeper-${keeperScriptVersion(keeperScript())}.py');
      var installing = true;
      var reads = 0;
      final reader = () async {
        while (installing) {
          if (file.existsSync()) {
            reads++;
            expect(file.readAsStringSync(), keeperScript());
          }
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }();
      final results = await Future.wait([
        for (var i = 0; i < 4; i++) h.run(keeperInstallCommand(), input: keeperInstallPayload()),
      ]);
      installing = false;
      await reader;
      for (final r in results) {
        expect(r.code, 0, reason: r.err);
        expect(r.out.trim(), '{"ok":true}');
      }
      expect(reads, greaterThan(0));
      expect(file.readAsStringSync(), keeperScript());
    });

    test('another script version gets its own file; the old one is removed and its keeper lives on', () async {
      final h = await newHost();
      final v1 = keeperScriptVersion(keeperScript());
      final second = '${keeperScript()}\n# a later version\n';
      final v2 = keeperScriptVersion(second);
      expect(v2, isNot(v1));
      expect(v1, matches(RegExp(r'^[0-9a-f]{12}$')));
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);

      await h.install(script: second);
      final dir = '${h.home.path}/.herdr-mobile';
      expect(File('$dir/keeper-$v1.py').existsSync(), isFalse);
      expect(File('$dir/keeper-$v2.py').readAsStringSync(), second);
      // The app of the old version now finds nothing and installs again.
      expect((await h.run(keeperListCommand())).code, 65);

      // The keeper started by the old file still runs and serves.
      expect(await processAlive(info.pid!), isTrue);
      expect((await a.request('session/list'))['result'], isNotNull);
      final listed = await h.run("exec python3 '$dir/keeper-$v2.py' list");
      expect(((jsonDecode(listed.out) as List).single as Map)['id'], info.id);
      final b = await h.run("exec python3 '$dir/keeper-$v2.py' kill ${info.id}");
      expect(b.out.trim(), '{"ok":true}');
    });

    test('rejects an unknown agent, a bad folder and a bad keeper id', () {
      for (final bad in ['', 'gpt', 'OMP', 'omp; id', r'$(id)', 'omp ', "omp'"]) {
        expect(() => keeperStartCommand(agent: bad, cwd: '/tmp'), throwsArgumentError, reason: bad);
      }
      for (final bad in ['', 'a\nb', 'a\u0000b', 'a\rb', 'x' * 5000]) {
        expect(() => keeperStartCommand(agent: 'omp', cwd: bad), throwsArgumentError, reason: bad.length > 20 ? 'long' : bad);
      }
      for (final bad in ['', 'a b', r'$(id)', '../x', 'A1b2c3', "ab'c", 'a;b', 'ab', 'x' * 33]) {
        expect(() => keeperAttachCommand(bad), throwsArgumentError, reason: bad);
        expect(() => keeperKillCommand(bad), throwsArgumentError, reason: bad);
      }
    });

    test('a folder name cannot break out of the command', () async {
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
        final r = await h.run(keeperStartCommand(agent: 'omp', cwd: evil));
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
      expect((await h.run(keeperAttachCommand('zzzzzz'))).code, 66);
      final k = await h.run(keeperKillCommand('zzzzzz'));
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
