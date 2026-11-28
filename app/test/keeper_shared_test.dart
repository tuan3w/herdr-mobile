@TestOn('linux || mac-os')
library;

import 'package:flutter_test/flutter_test.dart';

import 'support/keeper_harness.dart';

// Shared sessions (docs/AGENT_SESSIONS.md, "Shared sessions"): two clients on
// one keeper (the `herdr-host` binary), what each sees of the other. The herdr
// pane, the terminal client and the alert hook are the Rust suite's
// (`rust/crates/host/tests/keeper_parity.rs`).

void main() {
  Future<KeeperHost> newHost([Map<String, String> env = const {}]) async {
    final h = await KeeperHost.create(env);
    addTearDown(h.dispose);
    await h.install();
    return h;
  }

  Json update(Json m) => asJson(asJson(m['params'])['update']);
  bool Function(Json) isState(String state) =>
      (m) => isUpdate('state_update')(m) && update(m)['state'] == state;

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
  List<Json> answersTo(KeeperHost h, Object id) => [
    for (final m in h.agentLog())
      if (!m.containsKey('method') && m['id'] == id) m,
  ];

  group('shared sessions', () {
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
      final message = b.seen.indexWhere(
        (m) => isUpdate('user_message_chunk')(m) && updateText(update(m)) == 'perm:Run: make',
      );
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

    test('a turn that ends with only a terminal attached is unseen to the phone', () async {
      final h = await newHost();
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
  });
}
