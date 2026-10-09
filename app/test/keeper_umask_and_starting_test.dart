@TestOn('linux || mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart';

import 'support/keeper_harness.dart';

// Two things the person notices in the REAL keeper script (python3):
//  - an agent writes files the way their own shell would (the login umask),
//    while the keeper's own files stay private;
//  - a keeper that is still starting its agent is never reported gone, and
//    `kill` ends it however its record reads.

void main() {
  final hasPython = pythonDir() != null;

  Future<KeeperHost> newHost([Map<String, String> env = const {}]) async {
    final h = await KeeperHost.create(env);
    addTearDown(h.dispose);
    await h.install();
    return h;
  }

  int mode(String path) => FileStat.statSync(path).mode & 0x1ff;

  group('keeper', skip: hasPython ? false : 'python3 is not installed', () {
    test('the agent gets the login umask; the keeper\'s own files stay private', () async {
      final h = await newHost();
      final written = '${h.home.path}/agent.pid';
      h.env['FAKE_ACP_PID_FILE'] = written; // the agent creates it when it answers initialize
      final r = await h.run('umask 027; ${keeperStartCommand(agent: 'omp', cwd: h.work)}');
      expect(r.code, 0, reason: r.err);
      final id = asJson(jsonDecode(r.out))['id']! as String;

      expect(mode(written), 0x1a0, reason: '0666 with umask 027 is 0640: the agent is not stuck with the keeper\'s 077'); // 0640
      for (final ext in ['sock', 'json', 'log']) {
        expect(mode('${h.keepers}/$id.$ext'), 0x180, reason: ext); // 0600
      }
    });

    group('a keeper still starting its agent', () {
      // Starts a keeper whose agent answers `initialize` only after a minute
      // and returns its record. Every process it started is killed, by PID, in
      // the tear-down, whatever the test did.
      Future<({KeeperHost h, Json rec, KeeperRunning start})> startSlow() async {
        final h = await newHost({'FAKE_ACP_INIT_DELAY': '60'});
        final start = await h.startInBackground();
        addTearDown(() => start.process.kill());
        late Json rec;
        await eventually(() async {
          final l = await h.rawList();
          if (l.isEmpty || l.single['agent_pid'] == null) return false;
          rec = l.single;
          return true;
        }, what: 'a starting keeper that has its agent');
        for (final key in ['pid', 'agent_pid']) {
          final pid = rec[key]! as int;
          addTearDown(() => Process.killPid(pid, ProcessSignal.sigkill));
        }
        return (h: h, rec: rec, start: start);
      }

      test('is listed as starting however often it is listed', () async {
        final (:h, :rec, start: _) = await startSlow();
        for (var i = 0; i < 20; i++) {
          final now = (await h.rawList()).single;
          expect(now['state'], 'starting', reason: 'list #$i');
        }
        expect(await processAlive(rec['pid']! as int), isTrue);
      });

      test('kill ends it even when its record says exited', () async {
        final (:h, :rec, :start) = await startSlow();
        final keeperPid = rec['pid']! as int;
        final agentPid = rec['agent_pid']! as int;
        final id = rec['id']! as String;
        // What a failed probe used to leave behind: a live keeper recorded as gone.
        final record = File('${h.keepers}/$id.json');
        record.writeAsStringSync(jsonEncode({...rec, 'state': 'exited'}));

        final k = await h.run(keeperKillCommand(id));
        expect(k.code, 0, reason: k.err);
        await eventually(() async => !await processAlive(keeperPid) && !await processAlive(agentPid), what: 'keeper and agent to stop');
        expect((await start.finished).code, 70);
        expect(await h.list(), isEmpty);
      });

      test('attach says it is busy, not gone, when its socket will not take another connection', () async {
        // A unix socket's backlog is full after 16 pending connections; macOS
        // then refuses the next one (Linux makes it wait, so it is not testable there).
        final (:h, :rec, start: _) = await startSlow();
        final id = rec['id']! as String;
        final held = <Socket>[];
        addTearDown(() {
          for (final s in held) {
            s.destroy();
          }
        });
        for (var i = 0; i < 24; i++) {
          try {
            held.add(await Socket.connect(InternetAddress('${h.keepers}/$id.sock', type: InternetAddressType.unix), 0));
          } on SocketException {
            break;
          }
        }

        final r = await h.run(keeperAttachCommand(id));
        expect(r.code, isNot(67), reason: 'the agent has not exited: ${r.err}');
        expect((await h.rawList()).single['state'], 'starting');
      }, skip: Platform.isMacOS ? false : 'a full unix socket backlog is refused on macOS only');
    });
  });
}
