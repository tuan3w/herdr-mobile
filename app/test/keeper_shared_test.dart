@TestOn('linux || mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart';

import 'support/keeper_harness.dart';

// Shared sessions (docs/AGENT_SESSIONS.md, "Shared sessions") with the REAL
// keeper script (python3): every client at once, the first answer wins, the
// herdr pane the keeper opens and `view`, the terminal client that runs in it.

void main() {
  final hasPython = pythonDir() != null;

  Future<KeeperHost> newHost([Map<String, String> env = const {}]) async {
    final h = await KeeperHost.create(env);
    addTearDown(h.dispose);
    await h.install();
    return h;
  }

  Json update(Json m) => asJson(asJson(m['params'])['update']);
  bool Function(Json) isState(String state) => (m) => isUpdate('state_update')(m) && update(m)['state'] == state;

  /// A session opened by a phone [a], and [b] loaded into it.
  Future<(KeeperHost, String, KeeperAttach, KeeperAttach)> twoClients() async {
    final h = await newHost();
    final info = await h.start();
    final a = await h.attach(info.id);
    await a.initialize(title: 'Phone');
    await a.newSession(h);
    final b = await h.attach(info.id);
    await b.initialize(title: 'Laptop');
    await b.load(h);
    return (h, info.id, a, b);
  }

  /// The answers to the agent's request [id] that reached the agent.
  List<Json> answersTo(KeeperHost h, Object id) =>
      [for (final m in h.agentLog()) if (!m.containsKey('method') && m['id'] == id) m];

  group('shared sessions', skip: hasPython ? false : 'python3 is not installed', () {
    test('every client gets the stream, and a prompt from one shows on the other', () async {
      final (_, _, a, b) = await twoClients();

      final r = await a.response(a.prompt('plain'));
      expect(asJson(r['result'])['stopReason'], 'end_turn');
      final idle = await b.next(isState('idle'));
      expect(update(idle)['stopReason'], 'end_turn');

      String text(Json u) => u['sessionUpdate'] == 'agent_message_chunk' ? updateText(u) : '';
      expect(updatesOf(a.seen).map(text).join(), 'Hello');
      expect(updatesOf(b.seen).map(text).join(), 'Hello');

      // B sees the prompt start before the answer streams, as the replay shows it.
      final seen = updatesOf(b.seen);
      final firstAnswer = seen.indexWhere((u) => u['sessionUpdate'] == 'agent_message_chunk');
      final user = seen.indexWhere((u) => u['sessionUpdate'] == 'user_message_chunk');
      final running = seen.indexWhere((u) => u['sessionUpdate'] == 'state_update' && u['state'] == 'running');
      expect(updateText(seen[user]), 'plain');
      expect(user, lessThan(firstAnswer));
      expect(running, isNot(-1));
      expect(running, lessThan(firstAnswer));
      expect(
        updatesOf(a.seen).where((u) => u['sessionUpdate'] == 'user_message_chunk'),
        isEmpty,
        reason: 'the client that sent it shows its own message',
      );
    });

    test('a permission goes to every client; the first answer wins and the others are told who', () async {
      final (h, _, a, b) = await twoClients();
      final p = a.prompt('perm:Run: make');
      final forA = await a.next(isMethod('session/request_permission'));
      final forB = await b.next(isMethod('session/request_permission'));
      expect(forB['id'], forA['id']);
      final asked = b.seen.indexOf(forB);
      final message = b.seen.indexWhere((m) => isUpdate('user_message_chunk')(m) && updateText(update(m)) == 'perm:Run: make');
      expect(message, isNot(-1));
      expect(message, lessThan(asked), reason: 'what was asked comes before what it needs');

      a.reply(forA['id'], {
        'outcome': {'outcome': 'selected', 'optionId': 'allow'},
      });
      final resolved = await b.next(isMethod('_herdr/resolved'));
      expect(asJson(resolved['params']), {'requestId': forA['id'], 'by': 'Phone', 'answer': 'Allow once'});
      final cancel = await b.next(isMethod(r'$/cancel_request'));
      expect(asJson(cancel['params'])['requestId'], forA['id']);

      // B's answer comes too late and is dropped (its own next request fences it).
      b.reply(forB['id'], {
        'outcome': {'outcome': 'selected', 'optionId': 'reject'},
      });
      await b.request('session/list');
      expect(asJson((await a.response(p))['result'])['stopReason'], 'end_turn');
      final answers = answersTo(h, 7002);
      expect(answers, hasLength(1));
      expect(asJson(asJson(answers.single['result'])['outcome'])['optionId'], 'allow');
      expect(a.seen.where(isMethod('_herdr/resolved')), isEmpty, reason: 'the one who answered knows');
      expect((await h.list()).single.pending, 0);
    });

    test('a question answered elsewhere is told by its action', () async {
      final (_, _, a, b) = await twoClients();
      a.prompt('ask');
      final perm = await b.next(isMethod('session/request_permission'));
      b.reply(perm['id'], {
        'outcome': {'outcome': 'cancelled'},
      });
      final cancelled = await a.next(isMethod('_herdr/resolved'));
      expect(asJson(cancelled['params'])['by'], 'Laptop');
      expect(asJson(cancelled['params'])['answer'], 'cancelled');
      final question = await a.next(isMethod('elicitation/create'));
      a.reply(question['id'], {'action': 'decline'});
      final declined = await b.next(isMethod('_herdr/resolved'));
      expect(asJson(declined['params']), {'requestId': question['id'], 'by': 'Phone', 'answer': 'decline'});
    });

    test('a turn that ends with only a terminal attached is unseen and alerts', () async {
      final h = await newHost();
      await h.writeHook(r'echo "$KEEPER_EVENT" >> "$HOME/hook.out"');
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize(title: 'Phone');
      await a.newSession(h);
      final v = await h.attach(info.id);
      await v.initialize(title: 'Terminal on test', viewer: true, pane: 'w1:p1');
      await v.load(h);

      a.prompt('sleep:1');
      await a.next(isUpdate('agent_message_chunk'));
      await a.close();
      final idle = await v.next(isState('idle'));
      expect(update(idle)['stopReason'], 'end_turn', reason: 'the terminal shows the end');
      await eventually(() async => (await h.rawList()).single['unseen_done'] == true, what: 'the end to stay unseen');
      final hook = File(h.hookOut);
      await eventually(() => hook.existsSync() && hook.readAsLinesSync().contains('done'), what: 'the done alert');

      // A terminal loading the session has not seen it either; the phone has.
      final v2 = await h.attach(info.id);
      await v2.initialize(viewer: true);
      await v2.load(h);
      expect((await h.rawList()).single['unseen_done'], isTrue);
      final b = await h.attach(info.id);
      await b.initialize(title: 'Phone');
      await b.load(h);
      await eventually(() async => (await h.rawList()).single['unseen_done'] == false, what: 'the phone to see it');
    });

    test('list counts the clients and keeps the pane a terminal announced', () async {
      final h = await newHost();
      final info = await h.start();
      expect((await h.rawList()).single['clients'], 0);
      final v = await h.attach(info.id);
      await v.initialize(title: 'Terminal on test', viewer: true, pane: 'w9:p2');
      final a = await h.attach(info.id);
      await a.initialize(title: 'Phone');
      await eventually(() async {
        final r = (await h.rawList()).single;
        return r['clients'] == 2 && r['pane_id'] == 'w9:p2';
      }, what: 'two clients and the pane');

      await v.close();
      await eventually(() async => (await h.rawList()).single['clients'] == 1, what: 'one client left');
      expect((await h.rawList()).single['pane_id'], 'w9:p2', reason: 'the pane stays the session\'s');
    });

    test('the keeper shows its session in herdr and closes the tab when ended on request', () async {
      final h = await newHost();
      await h.useFakeHerdr();
      String? after(List<String> call, String flag) {
        final i = call.indexOf(flag);
        return i >= 0 && i + 1 < call.length ? call[i + 1] : null;
      }

      bool isCall(List<String> c, String a, String b) => c.length >= 2 && c[0] == a && c[1] == b;
      List<List<String>> runs() => [for (final c in h.herdrCalls()) if (isCall(c, 'pane', 'run')) c];

      // No `Phone sessions` workspace yet: the first session makes it and takes its pane.
      final first = await h.start();
      await eventually(() => runs().length == 1, what: 'the first view to run');
      final made = h.herdrCalls().firstWhere((c) => isCall(c, 'workspace', 'create'));
      expect(after(made, '--label'), 'Phone sessions');
      expect(after(made, '--cwd'), h.work);
      expect(made, contains('--no-focus'));
      expect(runs().single, ['pane', 'run', 'w1:p1', "python3 '${h.script}' view ${first.id}"]);

      // The next one gets a tab of its own in that workspace.
      final second = await h.start();
      await eventually(() => runs().length == 2, what: 'the second view to run');
      final tab = h.herdrCalls().firstWhere((c) => isCall(c, 'tab', 'create'));
      expect(after(tab, '--workspace'), 'w1');
      expect(after(tab, '--label'), contains('work'));
      expect(tab, contains('--no-focus'));
      expect(runs().last, ['pane', 'run', 'w1:p2', "python3 '${h.script}' view ${second.id}"]);
      expect(h.herdrCalls().where((c) => isCall(c, 'workspace', 'create')), hasLength(1));

      // Ended on request: its tab goes.
      final k = await h.run(keeperKillCommand(first.id));
      expect(k.code, 0, reason: k.err);
      expect(h.herdrCalls(), contains(equals(['tab', 'close', 'w1:t1'])));

      // An agent that exits by itself leaves its tab: the terminal says why.
      final a = await h.attach(second.id);
      await a.initialize();
      await a.newSession(h);
      a.prompt('exit:3');
      await eventually(() async => (await h.list()).single.state.name == 'exited', what: 'the agent to exit');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(h.herdrCalls().where((c) => isCall(c, 'tab', 'close')), [
        ['tab', 'close', 'w1:t1'],
      ]);
    });

    test('~/.herdr-mobile/no-panes keeps herdr out', () async {
      final h = await newHost();
      await h.useFakeHerdr();
      File('${h.home.path}/.herdr-mobile/no-panes').createSync();
      await h.start();
      // Absence cannot be polled for: wait a minimum time (a loaded machine
      // only makes it longer, never flaky).
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(h.herdrCalls(), isEmpty);
    });

    test('a script path that is not one quoted shell word is never typed into a pane', () async {
      final h = await KeeperHost.create(const {}, homeLeaf: "o'brien; touch pwned");
      addTearDown(h.dispose);
      await h.install();
      await h.useFakeHerdr();
      final info = await h.start();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect([for (final c in h.herdrCalls()) if (c.length > 1 && c[0] == 'pane' && c[1] == 'run') c], isEmpty);
      expect(File('${h.work}/pwned').existsSync(), isFalse);
      // The session itself is untouched: a phone still attaches.
      final a = await h.attach(info.id);
      await a.initialize(title: 'Phone');
      await a.newSession(h);
    });

    test('view prints the session, answers a permission by number, prompts, and reports to herdr', () async {
      final h = await newHost();
      final herdr = await h.writeFakeHerdr();
      final info = await h.start();
      final a = await h.attach(info.id);
      await a.initialize(title: 'Phone');
      await a.newSession(h);
      final v = await h.view(info.id, env: {'HERDR_ENV': '1', 'HERDR_PANE_ID': 'w1:p1', 'HERDR_BIN_PATH': herdr});

      List<List<String>> reports() => [
        for (final c in h.herdrCalls())
          if (c.length > 3 && c[0] == 'pane' && c[1] == 'report-agent') c,
      ];
      String state(List<String> c) => c[c.indexOf('--state') + 1];
      await eventually(() => reports().isNotEmpty, what: 'the first report');
      expect(state(reports().first), 'idle');
      await eventually(() async => (await h.rawList()).single['pane_id'] == 'w1:p1', what: 'the keeper to know the pane');

      // What the phone does shows in the terminal.
      await a.response(a.prompt('plain'));
      var at = await v.waitFor('plain');
      at = await v.waitFor('Hello', from: at);

      // A permission: listed with its options, answered by number.
      final p = a.prompt('perm:Run: make test');
      final perm = await a.next(isMethod('session/request_permission'));
      at = await v.waitFor('Run: make test', from: at);
      at = await v.waitFor('Allow once', from: at);
      await eventually(() => state(reports().last) == 'blocked', what: 'herdr to hear blocked');
      v.type('1');
      final resolved = await a.next(isMethod('_herdr/resolved'));
      expect(asJson(resolved['params'])['requestId'], perm['id']);
      expect(asJson(resolved['params'])['by'], startsWith('Terminal on '));
      expect(asJson(resolved['params'])['answer'], 'Allow once');
      await a.response(p);
      final answers = answersTo(h, 7002);
      expect(answers, hasLength(1));
      expect(asJson(asJson(answers.single['result'])['outcome'])['optionId'], 'allow');

      // A long turn is `working` in herdr.
      a.prompt('sleep:1');
      await eventually(() => state(reports().last) == 'working', what: 'herdr to hear working');
      await eventually(() => state(reports().last) == 'idle', what: 'herdr to hear idle');

      // A typed line is a prompt; the phone sees it as the person's message.
      v.type('reply:hi');
      await a.next((m) => isUpdate('user_message_chunk')(m) && updateText(update(m)) == 'reply:hi');
      await v.waitFor('re: hi', from: at);

      final all = reports();
      String agentOf(List<String> c) => c[c.indexOf('--agent') + 1];
      final agent = agentOf(all.first);
      expect(agent, contains('omp'));
      expect(agent, isNot('omp'), reason: 'herdr knows `omp` as its own agent');
      for (final r in all) {
        expect(r.sublist(0, 4), ['pane', 'report-agent', 'w1:p1', '--source']);
        expect(r[4], 'herdr-mobile');
        expect(agentOf(r), agent);
        expect(r[r.indexOf('--agent-session-id') + 1], 'sess-1');
        expect(r.sublist(r.indexOf('--') + 1), ['python3', h.script, 'view', info.id], reason: 'how herdr resumes it');
      }
      final seqs = [for (final r in all) int.parse(r[r.indexOf('--seq') + 1])];
      for (var i = 1; i < seqs.length; i++) {
        expect(seqs[i], greaterThan(seqs[i - 1]));
      }

      v.type('/quit');
      expect(await v.process.exitCode.timeout(const Duration(seconds: 30)), 0);
      final release = h.herdrCalls().last;
      expect(release.take(3), ['pane', 'release-agent', 'w1:p1']);
      expect(agentOf(release), agent);
      await eventually(() async => (await h.rawList()).single['clients'] == 1, what: 'the terminal to leave');
    });
  });
}
