@TestOn('linux || mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart';

import 'support/keeper_harness.dart';

// Starting, listing, killing and attaching to the REAL keeper script (python3).

void main() {
  final hasPython = pythonDir() != null;

  Future<KeeperHost> newHost([Map<String, String> env = const {}, bool install = true]) async {
    final h = await KeeperHost.create(env);
    addTearDown(h.dispose);
    if (install) await h.install();
    return h;
  }

  group('keeper', skip: hasPython ? false : 'python3 is not installed', () {
    test('start prints the KeeperInfo, outlives the starter and ignores SIGHUP', () async {
      final h = await newHost();
      final info = await h.start();
      expect(info.id, matches(RegExp(r'^[a-hjkmnp-z2-9]{6}$')));
      expect(info.agent, 'omp');
      expect(info.cwd, h.work);
      expect(info.state, KeeperState.running);
      expect(info.pid, greaterThan(0));
      expect(info.pending, 0);
      expect(info.sessionId, isNull);
      expect(DateTime.now().difference(info.startedAt!).inSeconds.abs(), lessThan(60));

      // The starter is gone; the keeper lives, also after SIGHUP.
      Process.killPid(info.pid!, ProcessSignal.sighup);
      // A SIGHUP was delivered when killPid returned; a keeper that did not
      // ignore it would not answer the attach below.
      final a = await h.attach(info.id);
      final init = asJson((await a.initialize())['result']);
      expect(asJson(init['agentInfo'])['name'], 'fake-acp');
      expect(await processAlive(info.pid!), isTrue);
      final listed = (await h.list()).single;
      expect(listed.id, info.id);
      expect(listed.state, KeeperState.running);
    });

    test('on a Mac, Claude with no token in the environment is marked as logging in through the Keychain', () async {
      final bare = await newHost();
      expect((await bare.start(agent: 'claude')).loginInKeychain, Platform.isMacOS);
      expect((await bare.start()).loginInKeychain, isFalse, reason: 'omp keeps its login in a file');

      final token = await newHost({'CLAUDE_CODE_OAUTH_TOKEN': 'test-token'});
      expect((await token.start(agent: 'claude')).loginInKeychain, isFalse);
      expect((await token.list()).single.loginInKeychain, isFalse);
    });

    test('on a Mac, Claude\'s keeper is a launchd job of the desktop session, works, and unloads when it ends', () async {
      final uid = (await Process.run('id', ['-u'])).stdout.toString().trim();
      if (!Platform.isMacOS || (await Process.run('launchctl', ['print', 'gui/$uid'])).exitCode != 0) {
        markTestSkipped('needs a macOS desktop session');
        return;
      }
      final h = await newHost({'HERDR_MOBILE_NO_LAUNCHD': ''});
      final info = await h.start(agent: 'claude');
      expect(info.loginInKeychain, isFalse, reason: 'the job can open the Keychain, so there is nothing to warn about');
      final label = (await h.rawList()).single['launchd'] as String;
      expect(label, startsWith('dev.herdrmobile.keeper.'));
      Future<bool> loaded() async => (await Process.run('launchctl', ['print', 'gui/$uid/$label'])).exitCode == 0;
      expect(await loaded(), isTrue);
      expect([for (final f in Directory(h.keepers).listSync()) if (f.path.contains('/start-')) f.path], isEmpty,
          reason: 'the plist (it can hold a token) and the report file are gone');

      // It is a working keeper, with the starter's environment (the fake agent logs to FAKE_ACP_LOG).
      final a = await h.attach(info.id);
      await a.initialize(title: 'Phone');
      await a.newSession(h);
      await a.response(a.prompt('plain'));
      expect(h.agentLog(), isNotEmpty);

      await h.run(keeperKillCommand(info.id));
      await eventually(() async => !await loaded(), what: 'the job to unload');
      expect(await processAlive(info.pid!), isFalse);
    });

    test('directory, socket, record and log are private', () async {
      final h = await newHost();
      final info = await h.start();
      int mode(String path) => FileStat.statSync(path).mode & 0x1ff;
      expect(mode(h.keepers), 0x1c0); // 0700
      for (final ext in ['sock', 'json', 'log']) {
        expect(mode('${h.keepers}/${info.id}.$ext'), 0x180, reason: ext); // 0600
      }
    });

    test('the agent gets no stray file descriptors', skip: Directory('/proc/self/fd').existsSync() ? false : 'needs /proc', () async {
      final h = await newHost();
      await h.start();
      final agentPid = (await h.rawList()).single['agent_pid']! as int;
      final fds = Directory('/proc/$agentPid/fd').listSync().map((e) => e.uri.pathSegments.last).toSet();
      expect(fds, {'0', '1', '2'});
    });

    test('a slow start is listed while it initialises and is not swept as an orphan', () async {
      final h = await newHost({'FAKE_ACP_INIT_DELAY': '8', 'HERDR_KEEPER_ORPHAN_SECONDS': '1'});
      final s = await h.startInBackground();
      await eventually(
        () => Directory(h.keepers).existsSync() && Directory(h.keepers).listSync().any((f) => f.path.endsWith('.json')),
        what: 'the first record',
      );
      await Future<void>.delayed(const Duration(milliseconds: 2500)); // a minimum: past the 1 s orphan bound
      final starting = (await h.rawList()).single;
      expect(starting['state'], 'starting');
      expect(KeeperInfo.fromJson(starting).state, KeeperState.starting);
      final id = starting['id']! as String;
      for (final ext in ['json', 'sock', 'log']) {
        expect(File('${h.keepers}/$id.$ext').existsSync(), isTrue, reason: ext);
      }
      final done = await s.finished;
      expect(done.code, 0, reason: done.err);
      expect(KeeperInfo.fromJson(asJson(jsonDecode(done.out))).id, id);
      final a = await h.attach(id);
      expect(asJson((await a.initialize())['result'])['protocolVersion'], 1);
      expect((await h.list()).single.state, KeeperState.running);
    });

    test('kill reaches a keeper whose agent is still starting', () async {
      final h = await newHost({'FAKE_ACP_INIT_DELAY': '60'});
      final s = await h.startInBackground();
      late Json rec;
      await eventually(() async {
        final l = await h.rawList();
        if (l.isEmpty || l.single['agent_pid'] == null) return false;
        rec = l.single;
        return true;
      }, what: 'a starting keeper that has its agent');
      expect(rec['state'], 'starting');
      final keeperPid = rec['pid']! as int;
      final agentPid = rec['agent_pid']! as int;
      final k = await h.run(keeperKillCommand(rec['id']! as String));
      expect(k.code, 0, reason: k.err);
      expect(asJson(jsonDecode(k.out)), {'ok': true});
      await eventually(() async => !await processAlive(keeperPid) && !await processAlive(agentPid), what: 'keeper and agent to stop');
      final r = await s.finished;
      expect(r.code, 70);
      expect(await h.list(), isEmpty);
      expect(Directory(h.keepers).listSync(), isEmpty);
    });

    test('one huge update is cut down and never empties the replay log', () async {
      final h = await newHost({'HERDR_KEEPER_LOG_BYTES': '20000'});
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      await a.response(a.prompt('long:5'));
      await a.response(a.prompt('big:100000'));
      await a.response(a.prompt('long:3'));
      await a.close();

      final b = await h.attach(info.id);
      await b.initialize();
      await b.load(h);
      final replay = updatesOf(b.seen);
      final texts = replay.where((u) => u['sessionUpdate'] == 'agent_message_chunk').map(updateText).toList();
      // The entries from before the huge one are still there, and after it.
      expect(texts, containsAll(['line 0 ', 'line 4 ', 'tail', 'line 2 ']));
      final tool = replay.singleWhere((u) => u['toolCallId'] == 'big-1');
      expect(tool['status'], 'completed');
      expect(tool['title'], 'Big output');
      expect(jsonEncode(tool['content']), contains('bytes omitted'));
      expect(jsonEncode(tool).length, lessThan(1000));
      final big = replay.singleWhere((u) => u['messageId'] == 'mbig');
      expect(updateText(big), startsWith('zzzz'));
      expect(updateText(big), contains('bytes omitted'));
      expect(updateText(big).length, lessThan(2000));
    });

    test('list tells a turn in flight and a turn that ended unseen', () async {
      final h = await newHost();
      final info = await h.start();
      expect(info.turnActive, isFalse);
      expect(info.unseenDone, isFalse);
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      expect((await h.list()).single.turnActive, isFalse);
      a.prompt('sleep:2');
      await a.next(isUpdate('agent_message_chunk'));
      var now = (await h.list()).single;
      expect(now.turnActive, isTrue);
      expect(now.unseenDone, isFalse);

      await a.close(); // detached, still working
      now = (await h.list()).single;
      expect(now.turnActive, isTrue);
      await eventually(() async => (await h.list()).single.unseenDone, what: 'the unseen end');
      now = (await h.list()).single;
      expect(now.turnActive, isFalse);
      expect(now.unseenDone, isTrue);

      final b = await h.attach(info.id);
      await b.initialize();
      expect((await h.list()).single.unseenDone, isTrue, reason: 'attaching alone has not shown the end');
      await b.load(h);
      await eventually(() async => !(await h.list()).single.unseenDone, what: 'the load to clear it');

      // A turn the attached client waits for is never "unseen".
      await b.response(b.prompt('plain'));
      now = (await h.list()).single;
      expect(now.turnActive, isFalse);
      expect(now.unseenDone, isFalse);
    });

    test('initialize is asked once and answered from the cache', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      final first = asJson((await a.initialize())['result']);
      // The agent said loadSession false; the keeper answers the load itself.
      expect(asJson(first['agentCapabilities'])['loadSession'], isTrue);
      expect(first['protocolVersion'], 1);
      await a.close();
      final b = await h.attach(info.id);
      expect(asJson((await b.initialize())['result']), first);
      final inits = h.agentLog().where((m) => m['method'] == 'initialize').toList();
      expect(inits, hasLength(1));
      expect(inits.single['id'], 'keeper-init');
      final caps = asJson(asJson(inits.single['params'])['clientCapabilities']);
      expect(asJson(caps['session']), {'configOptions': {'boolean': <String, Object?>{}}},
          reason: 'Claude Code and Codex send fast as a select unless the client opts in');
      expect(asJson(caps['elicitation']), {'form': <String, Object?>{}});
    });

    test('a failing agent fails the start and leaves nothing behind', () async {
      final h = await newHost({'FAKE_ACP_FAIL_INIT': '1'});
      final r = await h.run(keeperStartCommand(agent: 'omp', cwd: h.work));
      expect(r.code, 70);
      expect(r.err, contains('cannot start: no login'));
      expect(r.out.trim(), isEmpty);
      expect(await h.list(), isEmpty);
      expect(Directory(h.keepers).listSync(), isEmpty);
    });

    test('racing starts get different ids', () async {
      final h = await newHost();
      final infos = await Future.wait([for (var i = 0; i < 5; i++) h.start()]);
      expect({for (final i in infos) i.id}, hasLength(5));
      expect(await h.list(), hasLength(5));
    });

    test('list is newest first', () async {
      final h = await newHost();
      final a = await h.start();
      await Future<void>.delayed(const Duration(milliseconds: 50)); // started_at has millisecond resolution
      final b = await h.start();
      expect((await h.list()).map((i) => i.id), [b.id, a.id]);
    });

    test('updates are replayed after a detach, with the prompt and merged chunks', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      final done = asJson((await a.response(a.prompt('plain')))['result']);
      expect(done['stopReason'], 'end_turn');
      // Live, the chunks arrive as the agent wrote them.
      expect(updatesOf(a.seen).map(updateText), ['Hel', 'lo']);
      await a.close();

      final b = await h.attach(info.id);
      await b.initialize();
      final loaded = asJson((await b.load(h))['result']);
      expect(asJson(loaded['modes'])['currentModeId'], 'default');
      final replay = updatesOf(b.seen);
      expect(replay.map((u) => u['sessionUpdate']), ['user_message_chunk', 'agent_message_chunk']);
      expect(updateText(replay[0]), 'plain');
      expect(updateText(replay[1]), 'Hello');
      // The agent could not load a live session: the keeper never asks it to.
      expect(h.agentLog().where((m) => m['method'] == 'session/load'), isEmpty);

      // Requests still reach the agent under the phone's own ids.
      final listed = await b.request('session/list');
      expect(asJson(listed['result'])['sessions'], isEmpty);
    });

    group('a prompt the agent refuses as busy (-32003) is not a message in the log', () {
      // omp answers -32003 to a prompt that lands while a turn of its own (a
      // background subagent) runs. It took nothing, so a replay must not show
      // it: every refused attempt used to come back as one more identical
      // bubble.
      for (final noisy in [true, false]) {
        test(noisy ? 'the agent streamed output of its own before refusing' : 'the agent refused without a word', () async {
          final busy = File('${Directory.systemTemp.createTempSync('keeper_busy_').path}/busy');
          addTearDown(() => busy.parent.deleteSync(recursive: true));
          final h = await newHost({'FAKE_ACP_BUSY_FILE': busy.path});
          final info = await h.start();
          final a = await h.attach(info.id);
          await a.initialize();
          await a.newSession(h);

          busy.writeAsStringSync(noisy ? 'busy' : 'quiet');
          for (var i = 0; i < 3; i++) {
            final refused = await a.response(a.prompt('reply:fix it'));
            expect(asJson(refused['error'])['code'], -32003);
          }
          busy.deleteSync();
          final ok = await a.response(a.prompt('reply:fix it'));
          expect(asJson(ok['result'])['stopReason'], 'end_turn');
          await a.close();

          final b = await h.attach(info.id);
          await b.initialize();
          await b.load(h);
          final users = updatesOf(b.seen).where((u) => u['sessionUpdate'] == 'user_message_chunk');
          expect(users.map(updateText), ['reply:fix it'], reason: 'the one the agent took');
          expect(updatesOf(b.seen).where((u) => u['sessionUpdate'] == 'agent_message_chunk').map(updateText), [
            if (noisy) ...List.filled(3, 'subagent progress'),
            're: fix it',
          ]);
        });
      }
    });
  });
}
