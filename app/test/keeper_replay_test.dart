@TestOn('linux || mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart';

import 'support/keeper_harness.dart';

// What the REAL keeper script (python3) replays to a client that attaches later.

void main() {
  final hasPython = pythonDir() != null;

  Future<KeeperHost> newHost([Map<String, String> env = const {}, bool install = true]) async {
    final h = await KeeperHost.create(env);
    addTearDown(h.dispose);
    if (install) await h.install();
    return h;
  }

  group('keeper', skip: hasPython ? false : 'python3 is not installed', () {
    test('a prompt nothing has answered yet is in the replay of a client that attached meanwhile', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      a.prompt('quiet:2');
      await eventually(
        () => h.agentLog().any((m) => m['method'] == 'session/prompt'),
        what: 'the prompt to reach the agent',
      );

      final b = await h.attach(info.id);
      await b.initialize();
      await b.load(h);
      expect(
        updatesOf(b.seen).where((u) => u['sessionUpdate'] == 'user_message_chunk').map(updateText),
        ['quiet:2'],
        reason: 'the agent has said nothing yet, the message is already part of the conversation',
      );
      await b.next((m) => m['method'] == 'session/update' && asJson(asJson(m['params'])['update'])['state'] == 'idle');
    });

    test('a permission asked while detached is re-issued and answered once', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      a.prompt('ask');
      final first = await a.next(isMethod('session/request_permission'));
      expect(asJson(asJson(first['params'])['toolCall'])['title'], 'Run: ls -la');
      expect(first['id'], isA<String>()); // a keeper id, not the agent's 7001
      await a.close();

      await eventually(() async => (await h.list()).single.pending == 1, what: 'one pending request');

      final b = await h.attach(info.id);
      await b.initialize();
      await b.load(h);
      final again = await b.next(isMethod('session/request_permission'));
      expect(again['id'], first['id']);
      expect(asJson(again['params']), asJson(first['params']));
      b.reply(again['id'], {
        'outcome': {'outcome': 'selected', 'optionId': 'allow'},
      });
      // A late duplicate (another device, a double tap) is ignored.
      b.reply(again['id'], {
        'outcome': {'outcome': 'selected', 'optionId': 'reject'},
      });

      final question = await b.next(isMethod('elicitation/create'));
      expect(asJson(question['params'])['message'], 'Pick one?\nsecond line');
      b.reply(question['id'], {'action': 'accept', 'content': {'value': 'a'}});

      // The turn ended while no prompt request of this client was waiting.
      final idle = await b.next(isUpdate('state_update'));
      expect(asJson(asJson(idle['params'])['update']), {'sessionUpdate': 'state_update', 'state': 'idle', 'stopReason': 'end_turn'});
      expect(updatesOf(b.seen).map((u) => u['sessionUpdate'] == 'agent_message_chunk' ? updateText(u) : ''), contains('answered:allow/accept'));

      final log = h.agentLog();
      final permission = log.where((m) => !m.containsKey('method') && m['id'] == 7001).toList();
      expect(permission, hasLength(1));
      expect(asJson(asJson(permission.single['result'])['outcome'])['optionId'], 'allow');
      final answers = log.where((m) => !m.containsKey('method') && m['id'] == 'elic-1').toList();
      expect(answers, hasLength(1));
      expect(asJson(answers.single['result'])['action'], 'accept');
      expect((await h.list()).single.pending, 0);
    });

    test('a turn that ended unseen is reported on the next load', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      a.prompt('sleep:1');
      await a.next(isUpdate('agent_message_chunk'));
      await a.close();
      await eventually(() async => (await h.list()).single.unseenDone, what: 'the turn to end unseen');

      final b = await h.attach(info.id);
      await b.initialize();
      await b.load(h);
      final idle = await b.next(isUpdate('state_update'));
      expect(asJson(asJson(idle['params'])['update'])['stopReason'], 'end_turn');
      // Seen now: a third client is told nothing.
      await b.close();
      final c = await h.attach(info.id);
      await c.initialize();
      await c.load(h);
      expect(c.seen.where(isUpdate('state_update')), isEmpty);
    });

    test('garbage, partial lines and probes are no clients and do not hurt', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();

      final g = await h.attach(info.id);
      g.process.stdin.write('garbage\n{"x":1}\n[1,2]\n\n{"jsonrpc":"2.0","id":1,"meth');
      await g.process.stdin.flush();
      await g.close();
      await h.list(); // connects to the socket and hangs up
      await h.list();

      final listed = await a.request('session/list');
      expect(listed['result'], isNotNull);
      await eventually(() async => (await h.rawList()).single['clients'] == 1, what: 'one client counted');
      final log = File('${h.keepers}/${info.id}.log').readAsStringSync();
      expect(log, contains('not JSON'));
    });

    test('an agent that writes non-JSON is logged and skipped', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      final r = await a.response(a.prompt('noise'));
      expect(asJson(r['result'])['stopReason'], 'end_turn');
      expect(updatesOf(a.seen).map(updateText), ['after noise']);
      expect(File('${h.keepers}/${info.id}.log').readAsStringSync(), contains('not JSON'));
    });

    test('session/cancel is forwarded only when a client sends it', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      a.prompt('slow');
      await a.next(isUpdate('agent_message_chunk'));
      await a.close(); // a detach
      // The keeper never cancels by itself. Fence: once the agent has read a
      // request that b sent after the detach, a cancel sent by the keeper on
      // the detach would be in the agent's log already.
      final b = await h.attach(info.id);
      await b.initialize();
      b.post('session/list');
      await eventually(() => h.agentLog().any((m) => m['method'] == 'session/list'), what: 'the agent to read b\'s session/list');
      expect(h.agentLog().where((m) => m['method'] == 'session/cancel'), isEmpty);

      await b.load(h);
      final running = await b.next(isUpdate('state_update'));
      expect(asJson(asJson(running['params'])['update'])['state'], 'running');
      b.write({
        'method': 'session/cancel',
        'params': {'sessionId': 'sess-1'},
      });
      final idle = await b.next(isUpdate('state_update'));
      expect(asJson(asJson(idle['params'])['update']), {'sessionUpdate': 'state_update', 'state': 'idle', 'stopReason': 'cancelled'});
      expect(h.agentLog().where((m) => m['method'] == 'session/cancel'), hasLength(1));
    });

    test('the title, session and activity reach list', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      a.prompt('ask');
      await a.next(isMethod('session/request_permission'));
      await eventually(() async {
        final i = (await h.list()).single;
        return i.title == 'Fake title' && i.sessionId == 'sess-1' && i.lastEventAt != null && i.pending == 1;
      }, what: 'title, session and pending in list');
    });

    test('an agent that exits with nobody attached shows in list with its exit code', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      a.prompt('exit:7');
      await a.close();
      await eventually(() async => (await h.list()).single.state == KeeperState.exited, what: 'exited keeper');
      final gone = (await h.list()).single;
      expect(gone.exitCode, 7);
      expect(gone.exitReason, contains('code 7'));
      expect(gone.pending, 0);
      expect(gone.sessionId, 'sess-1');
    });

    test('an agent that dies with a request pending: noted, announced, attach says why', () async {
      final h = await newHost();
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      a.prompt('die');
      await a.next(isMethod('session/request_permission'));
      final bye = await a.next(isMethod('_herdr/agent_exited'));
      expect(asJson(bye['params'])['exitCode'], 3);
      expect(await a.exit.timeout(const Duration(seconds: 30)), 0);

      final gone = (await h.list()).single;
      expect(gone.state, KeeperState.exited);
      expect(gone.exitCode, 3);
      expect(gone.exitReason, allOf(contains('code 3'), contains('boom')));
      expect(gone.pending, 0);
      final log = File('${h.keepers}/${info.id}.log').readAsStringSync();
      expect(log, contains('cancelled'));
      expect(log, contains('boom'));

      final again = await h.run(keeperAttachCommand(info.id));
      expect(again.code, 67);
      expect(again.err, contains('code 3'));

      // Kill dismisses the record.
      final k = await h.run(keeperKillCommand(info.id));
      expect(k.out.trim(), '{"ok":true}');
      expect(await h.list(), isEmpty);
    });

    test('a keeper whose process vanished is listed as exited', () async {
      final h = await newHost();
      final info = await h.start();
      Process.killPid(info.pid!, ProcessSignal.sigkill);
      await eventually(() async => (await h.list()).single.state == KeeperState.exited, what: 'keeper to be marked exited');
      final gone = (await h.list()).single;
      expect(gone.state, KeeperState.exited);
      expect(gone.exitReason, contains('gone'));
    });

    test('kill stops the agent and forgets the keeper', () async {
      final h = await newHost();
      final info = await h.start();
      final agentPid = (await h.rawList()).single['agent_pid']! as int;
      final a = await h.attach(info.id);
      await a.initialize();
      final k = await h.run(keeperKillCommand(info.id));
      expect(k.code, 0, reason: k.err);
      expect(asJson(jsonDecode(k.out)), {'ok': true});
      expect(await h.list(), isEmpty);
      expect(await processAlive(info.pid!), isFalse);
      expect(await processAlive(agentPid), isFalse);
      final bye = await a.next(isMethod('_herdr/agent_exited'));
      expect(asJson(bye['params'])['reason'], 'Ended on request.');
    });

    test('kill escalates to SIGKILL for an agent that ignores SIGTERM', () async {
      final h = await newHost({'FAKE_ACP_IGNORE_TERM': '1'});
      final info = await h.start();
      final agentPid = (await h.rawList()).single['agent_pid']! as int;
      final watch = Stopwatch()..start();
      final k = await h.run(keeperKillCommand(info.id));
      expect(k.code, 0, reason: k.err);
      expect(watch.elapsed, greaterThan(const Duration(seconds: 2))); // SIGTERM ignored, so it waits out the 3 s ladder
      expect(watch.elapsed, lessThan(const Duration(seconds: 40)), reason: 'the kill command must still finish');
      expect(await processAlive(agentPid), isFalse);
      expect(await h.list(), isEmpty);
    });

    test('the log is bounded by message count', () async {
      final h = await newHost({'HERDR_KEEPER_LOG_MESSAGES': '10'});
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      await a.response(a.prompt('long:50'));
      await a.close();
      final b = await h.attach(info.id);
      await b.initialize();
      await b.load(h);
      final texts = updatesOf(b.seen).map(updateText).toList();
      expect(texts, hasLength(10));
      expect(texts.last, 'line 49 ');
      expect(texts, isNot(contains('line 0 ')));
    });

    test('the log is bounded by bytes', () async {
      final h = await newHost({'HERDR_KEEPER_LOG_BYTES': '2000'});
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize();
      await a.newSession(h);
      await a.response(a.prompt('long:50'));
      await a.close();
      final b = await h.attach(info.id);
      await b.initialize();
      await b.load(h);
      final replay = b.seen.where(isMethod('session/update')).toList();
      expect(replay, isNotEmpty);
      expect(replay.fold<int>(0, (n, m) => n + jsonEncode(m).length), lessThanOrEqualTo(2000));
      expect(updateText(updatesOf(replay).last), 'line 49 ');
    });
  });
}
