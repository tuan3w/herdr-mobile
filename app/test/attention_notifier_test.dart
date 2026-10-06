// When the phone tells the person about an agent: the transitions that notify,
// what clears a notification, the limits that keep a burst readable, and the
// "watching" notice that keeps the connections alive in the background.
import 'dart:ui' show AppLifecycleState;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/models/pane_preview.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart' as session_api show AgentLink;
import 'package:herdr_mobile/data/repositories/attention_notifier.dart';
import 'package:herdr_mobile/data/repositories/attention_set.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/repositories/pane_answerer.dart';
import 'package:herdr_mobile/data/repositories/notification_settings.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart' show HerdrTransportException;
import 'package:herdr_mobile/data/services/notifier.dart';
import 'package:herdr_mobile/ui/core/deep_link.dart';
import 'package:herdr_mobile/ui/features/agent_session/visible_text.dart';

import 'support/fake_agent_session.dart';
import 'support/fake_network.dart';
import 'support/fake_notifier.dart';
import 'support/fake_transport.dart';
import 'support/memory_stores.dart';

int _id(String machine, String pane) => notificationIdFor('$machine/$pane');

final _summaryId = notificationIdFor('summary');
final _finishedSummaryId = notificationIdFor('summary/finished');

typedef _Statuses = Map<String, String>;

/// A session list that can say it changed.
class _Sessions extends FakeAgentSessions {
  _Sessions(super.sessions);

  void poke() => notifyListeners();
}

/// herdr with a screen per pane: what `pane.read` answers, and every key sent.
class _Herdr extends FakeTransport {
  _Herdr(super.snapshot);

  final screens = <String, String>{};
  final sent = <String>[];

  /// Runs as a read starts: the screen or the link can change meanwhile.
  void Function()? duringRead;

  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) async {
    if (method == 'pane.read') {
      calls.add((method, params));
      duringRead?.call();
      return {
        'type': 'pane_read',
        'read': {'text': screens[params['pane_id']] ?? '', 'truncated': false},
      };
    }
    if (method == 'pane.send_keys') {
      calls.add((method, params));
      if (failure != null) throw failure!;
      sent.add('${params['pane_id']} ${(params['keys'] as List).join(' ')}');
      return {'type': 'ok'};
    }
    return super.request(method, params);
  }
}

/// The app's pieces over fake transports, on a clock the test moves by hand.
class _Rig {
  _Rig(
    this.async,
    Map<String, _Statuses> machines, {
    bool enabled = true,
    bool alsoDone = false,
    bool granted = true,
    bool startup = false,
    Map<String, String> labels = const {'a': 'Alpha', 'b': 'Bravo'},
    bool answers = false,
  }) : notifier = FakeNotifier(granted: granted) {
    for (final MapEntry(:key, :value) in machines.entries) {
      statuses[key] = Map.of(value);
      transports[key] = _Herdr(_snapshot(value));
    }
    repository = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
    fleet = FleetRepository(
      machines: repository,
      network: network,
      clock: () => now,
      connect: (profile, secrets) => MachineConnection(
        profile: profile,
        api: HerdrApi(transports[profile.id]!),
        backoff: (_) => const Duration(hours: 1),
        pollInterval: const Duration(hours: 1),
        clock: () => now,
      ),
    );
    for (final id in machines.keys) {
      repository.save(
        MachineProfile(id: id, label: labels[id] ?? id, host: '$id.local', username: 'u'),
        secrets: const MachineSecrets(password: 'x'),
      );
    }
    async.flushMicrotasks();
    advance(const Duration(seconds: 1));
    settings = NotificationSettings(MemoryNotificationStore(NotificationChoice(enabled: enabled, alsoDone: alsoDone)));
    settings.load();
    async.flushMicrotasks();
    attentionSet = AttentionSet(fleet: fleet, sessions: sessions);
    attention = AttentionNotifier(
      fleet: fleet,
      sessions: sessions,
      attention: attentionSet,
      settings: settings,
      notifier: notifier,
      answerer: answers ? PaneAnswerer(connection: fleet.connection) : null,
      visibleText: answers ? visibleText : null,
      clock: () => now,
    );
    async.flushMicrotasks();
    if (!startup && enabled) {
      // What the notifier does once at its start (see the test for it) is not
      // what the other tests are about.
      notifier.log
        ..remove('cancelAll')
        ..remove('watching:0');
      notifier.watching.remove(0);
      notifier.glances.remove((count: 0, blocked: 0));
      notifier.cancelAllCount--;
    }
  }

  final FakeAsync async;
  final FakeNotifier notifier;
  final network = FakeNetwork();
  final transports = <String, _Herdr>{};
  final statuses = <String, _Statuses>{};
  late final MachineRepository repository;
  late final FleetRepository fleet;
  late final NotificationSettings settings;
  late final AttentionSet attentionSet;
  late final AttentionNotifier attention;
  final sessions = _Sessions([]);

  DateTime now = DateTime.utc(2026, 1, 1, 12);

  static Map<String, dynamic> _snapshot(_Statuses s) => snapshotJson(
        panes: [for (final e in s.entries) (id: e.key, ws: 'w1', agent: 'claude', status: e.value)],
      );

  void advance(Duration d) {
    now = now.add(d);
    async.elapse(d);
  }

  /// The panes of [machine] as herdr now reports them; waits for the refresh.
  void set(String machine, _Statuses panes) {
    statuses[machine] = Map.of(panes);
    publish(machine, _snapshot(panes));
  }

  /// [snapshot] is what herdr answers from now on; an event makes the app ask.
  void publish(String machine, Map<String, dynamic> snapshot) {
    final t = transports[machine]!;
    t.snapshot = snapshot;
    t.emit({'event': 'pane_agent_status_changed'});
    advance(const Duration(milliseconds: 200));
  }

  /// What herdr answers from now on, with no event to tell the app (it finds
  /// out when it next asks, e.g. on reconnecting).
  void herdr(String machine, _Statuses panes) {
    statuses[machine] = Map.of(panes);
    transports[machine]!.snapshot = _snapshot(panes);
  }

  /// One pane changes, the rest stay.
  void change(String machine, String pane, String status) =>
      set(machine, {...statuses[machine]!, pane: status});

  /// Both halves of the app's lifecycle hook.
  void life(AppLifecycleState state) {
    fleet.onLifecycleState(state);
    attention.onLifecycleState(state);
    async.flushMicrotasks();
  }

  MachineConnection connection(String id) => fleet.connection(id)!;

  /// A session on [machine], listed with the others.
  FakeAgentSession addSession(String machine, String keeper, {String title = 'payments-api'}) {
    final session = FakeAgentSession(
      key: '$machine/$keeper',
      machine: connection(machine),
      title: title,
    );
    sessions.sessions.add(session);
    session.addListener(sessions.poke);
    return session;
  }

  void dispose() {
    attention.dispose();
    async.flushMicrotasks();
    attentionSet.dispose();
    fleet.dispose();
    settings.dispose();
  }
}

/// A rig with an attention notifier built over [sessions] from the start.
_Rig _withSessions(FakeAsync async, Map<String, _Statuses> machines, List<(String, String)> sessions,
    {bool alsoDone = false}) {
  final r = _Rig(async, machines, alsoDone: alsoDone);
  for (final (m, k) in sessions) {
    r.addSession(m, k);
  }
  return r;
}

void _blockSession(FakeAgentSession s) =>
    s.push(stateWith(pending: [PendingPermission('r1', permissionRequest())]));

void _workSession(FakeAgentSession s) => s.push(stateWith(turnActive: true));

void _idleSession(FakeAgentSession s) => s.push(stateWith());

void main() {
  const away = AppLifecycleState.paused;
  const back = AppLifecycleState.resumed;

  group('transitions', () {
    test('an agent that blocks in the background is announced once; opening the app clears it', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working', 'w1:p2': 'idle'}});
        r.life(away);
        r.change('a', 'w1:p1', 'blocked');

        expect(r.notifier.shown, hasLength(1));
        final n = r.notifier.shown.single;
        expect(n.id, _id('a', 'w1:p1'));
        expect(n.kind, NotifyKind.needsYou);
        expect(n.title, 'title w1:p1');
        expect(n.body, 'needs you · claude · Alpha');
        expect(n.link, 'herdr://agent/a/w1%3Ap1');

        // Events about the same agent are not news.
        r.change('a', 'w1:p2', 'working');
        r.change('a', 'w1:p2', 'idle');
        expect(r.notifier.shown, hasLength(1));

        r.life(back);
        expect(r.notifier.visible, isEmpty);
        expect(r.notifier.cancelAllCount, 1);
        r.dispose();
      });
    });

    test('what was blocked when the app went away is seen, and stays unannounced', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'blocked', 'w1:p2': 'working'}});
        r.life(away);
        r.change('a', 'w1:p2', 'blocked');
        r.advance(const Duration(minutes: 30));

        expect(r.notifier.shown.map((n) => n.id), [_id('a', 'w1:p2')], reason: 'only the new one');

        // Once it has left the state, blocking again is news.
        r.change('a', 'w1:p1', 'working');
        r.change('a', 'w1:p1', 'blocked');
        expect(r.notifier.shown.map((n) => n.id), [_id('a', 'w1:p2'), _id('a', 'w1:p1')]);
        r.dispose();
      });
    });

    test('after the app has been away, a still-blocked agent is not announced twice', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working'}});
        r.life(away);
        r.change('a', 'w1:p1', 'blocked');
        r.life(AppLifecycleState.hidden);
        r.life(AppLifecycleState.paused);
        r.advance(const Duration(minutes: 10));
        r.life(AppLifecycleState.inactive);
        expect(r.notifier.shown, hasLength(1));
        r.dispose();
      });
    });

    test('resuming clears every notification and takes a new baseline', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working', 'w1:p2': 'working'}});
        r.life(away);
        r.change('a', 'w1:p1', 'blocked');
        expect(r.notifier.visible, hasLength(1));

        r.life(back);
        expect(r.notifier.visible, isEmpty);
        // Blocking while the person looks is not announced...
        r.change('a', 'w1:p2', 'blocked');
        expect(r.notifier.shown, hasLength(1));

        // ...and both are seen when the app goes away again.
        r.life(away);
        r.advance(const Duration(minutes: 5));
        expect(r.notifier.shown, hasLength(1));
        r.dispose();
      });
    });

    test('inactive (the shade, a system dialog) is not away', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working', 'w1:p2': 'working'}});
        r.life(AppLifecycleState.inactive);
        r.change('a', 'w1:p1', 'blocked');
        expect(r.notifier.shown, isEmpty);

        r.life(AppLifecycleState.hidden);
        r.change('a', 'w1:p2', 'blocked');
        expect(r.notifier.shown.map((n) => n.id), [_id('a', 'w1:p2')]);
        r.dispose();
      });
    });

    test('the notification goes when the agent leaves the state: answered, finished, closed, reviewed', () {
      fakeAsync((async) {
        final r = _Rig(async, {
          'a': {'w1:p1': 'working', 'w1:p2': 'working', 'w1:p3': 'working', 'w1:p4': 'working'},
        }, alsoDone: true);
        r.life(away);
        r.set('a', {'w1:p1': 'blocked', 'w1:p2': 'blocked', 'w1:p3': 'blocked', 'w1:p4': 'working'});
        expect(r.notifier.visible, hasLength(3));

        r.change('a', 'w1:p1', 'working'); // answered on the desktop
        expect(r.notifier.active.keys, isNot(contains(_id('a', 'w1:p1'))));

        r.advance(const Duration(seconds: 6)); // past the burst
        r.set('a', {'w1:p1': 'working', 'w1:p2': 'done', 'w1:p3': 'blocked', 'w1:p4': 'working'});
        // The same id now says "done": replaced, not duplicated.
        expect(r.notifier.active[_id('a', 'w1:p2')]!.kind, NotifyKind.finished);
        expect(r.notifier.active[_id('a', 'w1:p2')]!.body, 'done · claude · Alpha');

        r.set('a', {'w1:p1': 'working', 'w1:p2': 'done', 'w1:p4': 'working'}); // pane closed
        expect(r.notifier.active.keys, [_id('a', 'w1:p2')]);

        r.fleet.markReviewed('a', 'w1:p2'); // looked at on the phone
        expect(r.notifier.visible, isEmpty);
        r.dispose();
      });
    });

    test('a machine that blips out of reach keeps the notification, and the same episode goes on', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working'}});
        r.life(away);
        r.change('a', 'w1:p1', 'blocked');
        expect(r.notifier.visible, hasLength(1));

        r.connection('a').goOffline();
        r.async.flushMicrotasks();
        expect(r.notifier.visible, hasLength(1), reason: 'the person never saw it: it stays');
        expect(r.notifier.log.where((e) => e.startsWith('cancel')), isEmpty);

        r.connection('a').reconnect();
        r.advance(const Duration(seconds: 2));
        expect(r.connection('a').isLive, isTrue);
        expect(r.notifier.shown, hasLength(1), reason: 'told once; the agent still waits: the same episode');
        expect(r.notifier.visible, hasLength(1));

        r.change('a', 'w1:p1', 'working');
        expect(r.notifier.visible, isEmpty, reason: 'seen to leave the state');
        r.dispose();
      });
    });

    test('an agent seen to leave the state while its machine is reconnecting is withdrawn once it is known', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working'}});
        r.life(away);
        r.change('a', 'w1:p1', 'blocked');
        r.connection('a').goOffline();
        r.async.flushMicrotasks();
        expect(r.notifier.visible, hasLength(1));

        r.herdr('a', {'w1:p1': 'working'});
        r.connection('a').reconnect();
        r.advance(const Duration(seconds: 2));
        expect(r.notifier.visible, isEmpty);
        r.dispose();
      });
    });

    test('what was blocked on an unreachable machine when the person left is seen, not news on its return', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'blocked'}});
        r.connection('a').goOffline();
        r.async.flushMicrotasks();
        r.life(away);

        r.connection('a').reconnect();
        r.advance(const Duration(seconds: 2));
        expect(r.connection('a').isLive, isTrue);
        expect(r.notifier.shown, isEmpty);
        r.dispose();
      });
    });

    test('an agent session on an offline machine is not announced until it is reachable', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'idle'}});
        final s = r.addSession('a', 'k1');
        r.connection('a').goOffline();
        r.life(away);
        _blockSession(s);
        expect(r.notifier.shown, isEmpty);

        r.connection('a').reconnect();
        r.advance(const Duration(seconds: 2));
        expect(r.notifier.shown.map((n) => n.id), [notificationIdFor('session/a/k1')]);
        r.dispose();
      });
    });

    test('a machine added or removed does not announce what it already shows', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'idle'}, 'b': {'w1:p1': 'blocked'}});
        r.life(away);
        r.repository.remove('b');
        r.async.flushMicrotasks();
        r.advance(const Duration(seconds: 1));
        expect(r.notifier.shown, isEmpty);
        r.dispose();
      });
    });
  });

  group('content', () {
    test('the title falls back to the folder, then the agent, and is cut', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {for (var i = 1; i <= 3; i++) 'w1:p$i': 'working'}});
        r.life(away);
        final snapshot = _Rig._snapshot({for (var i = 1; i <= 3; i++) 'w1:p$i': 'blocked'});
        final panes = [for (final p in snapshot['panes'] as List) p as Map<String, dynamic>];
        panes[0]['terminal_title_stripped'] = '   ';
        panes[0]['cwd'] = '/home/dev/payments-api';
        panes[1]['terminal_title_stripped'] = '';
        panes[1]['cwd'] = '/';
        panes[2]['terminal_title_stripped'] = 'x' * 100;
        r.publish('a', snapshot);

        String title(String pane) => r.notifier.active[_id('a', pane)]!.title;
        expect(title('w1:p1'), 'payments-api');
        expect(title('w1:p2'), 'claude');
        expect(title('w1:p3'), '${'x' * 59}…');
        r.dispose();
      });
    });

    test('the link and the id are stable and survive odd machine and pane names', () {
      fakeAsync((async) {
        final r = _Rig(async, {'box/1 é': {'w1:p1': 'working'}}, labels: {'box/1 é': 'Máy Việt'});
        r.life(away);
        r.change('box/1 é', 'w1:p1', 'blocked');
        final n = r.notifier.shown.single;
        expect(n.link, 'herdr://agent/box%2F1%20%C3%A9/w1%3Ap1');
        expect(parseAgentLink(n.link), const AgentLink('box/1 é', 'w1:p1'));
        expect(n.body, 'needs you · claude · Máy Việt');
        expect(n.id, notificationIdFor('box/1 é/w1:p1'));
        r.dispose();
      });
    });

    test('the summary link is the board link the deep link reads', () {
      expect(isBoardLink(agentsBoardLink), isTrue);
    });
  });

  group('limits', () {
    test('10 agents blocking at once: 3 notifications and one summary', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {for (var i = 1; i <= 10; i++) 'w1:p$i': 'working'}});
        r.life(away);
        r.set('a', {for (var i = 1; i <= 10; i++) 'w1:p$i': 'blocked'});

        final firstThree = [for (final a in r.fleet.agents.take(3)) _id('a', a.pane.id)];
        expect(r.notifier.shown.where((n) => n.id != _summaryId).map((n) => n.id), firstThree);
        final summary = r.notifier.shown.where((n) => n.id == _summaryId).single;
        expect(summary.title, '10 agents need you');
        expect(summary.kind, NotifyKind.needsYou);
        expect(summary.link, agentsBoardLink);
        expect(r.notifier.visible, hasLength(4));
        r.dispose();
      });
    });

    test('30 agents at once: still 3 and one summary, however often the fleet reports', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {for (var i = 1; i <= 15; i++) 'w1:p$i': 'working'}, 'b': {for (var i = 1; i <= 15; i++) 'w1:p$i': 'working'}});
        r.life(away);
        r.set('a', {for (var i = 1; i <= 15; i++) 'w1:p$i': 'blocked'});
        r.set('b', {for (var i = 1; i <= 15; i++) 'w1:p$i': 'blocked'});
        for (var i = 0; i < 20; i++) {
          r.transports['a']!.emit({'event': 'pane_agent_status_changed'});
          r.advance(const Duration(milliseconds: 300));
        }

        expect(r.notifier.shown.where((n) => n.id != _summaryId), hasLength(3));
        expect(r.notifier.active[_summaryId]!.title, '30 agents need you');
        expect(r.notifier.visible, hasLength(4));
        r.dispose();
      });
    });

    test('the summary follows the count as agents arrive, shrink and go', () {
      fakeAsync((async) {
        final all = [for (var i = 1; i <= 6; i++) 'w1:p$i'];
        final r = _Rig(async, {'a': {for (final p in all) p: 'working'}});
        r.life(away);
        for (final p in all.take(4)) {
          r.change('a', p, 'blocked');
          r.advance(const Duration(seconds: 1));
        }
        expect(r.notifier.active[_summaryId]!.title, '4 agents need you');
        r.change('a', all[4], 'blocked');
        expect(r.notifier.active[_summaryId]!.title, '5 agents need you');

        r.change('a', all[0], 'working'); // one of the three shown is answered
        expect(r.notifier.active[_summaryId]!.title, '4 agents need you');

        // The held-back ones go: nothing left to summarise.
        for (final p in all.skip(3).take(2)) {
          r.change('a', p, 'working');
        }
        expect(r.notifier.active.containsKey(_summaryId), isFalse);
        expect(r.notifier.visible, hasLength(2));
        r.dispose();
      });
    });

    test('a later burst gets its three again; an episode is never posted twice', () {
      fakeAsync((async) {
        final all = [for (var i = 1; i <= 8; i++) 'w1:p$i'];
        final r = _Rig(async, {'a': {for (final p in all) p: 'working'}});
        r.life(away);
        r.set('a', {for (final (i, p) in all.indexed) p: i < 4 ? 'blocked' : 'working'});
        expect(r.notifier.shown.where((n) => n.id != _summaryId), hasLength(3));
        expect(r.notifier.active[_summaryId]!.title, '4 agents need you');

        r.advance(const Duration(seconds: 6));
        r.set('a', {for (final p in all) p: 'blocked'});
        // Four more: the window has passed, so three of them are individual and
        // the one held back in the first burst is not posted by the way.
        final individual = r.notifier.shown.where((n) => n.id != _summaryId).toList();
        expect(individual, hasLength(6));
        expect({for (final n in individual) n.id}, hasLength(6), reason: 'each agent once');
        expect(r.notifier.active[_summaryId]!.title, '8 agents need you');
        r.dispose();
      });
    });

    test('a flapping agent is announced at most once a minute, by the minute', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working'}});
        r.life(away);
        r.change('a', 'w1:p1', 'blocked');
        expect(r.notifier.shown, hasLength(1));

        r.advance(const Duration(seconds: 10));
        r.change('a', 'w1:p1', 'working');
        r.advance(const Duration(seconds: 10));
        r.change('a', 'w1:p1', 'blocked');
        expect(r.notifier.shown, hasLength(1), reason: 'blocked again within a minute');

        r.advance(const Duration(seconds: 38));
        expect(r.notifier.shown, hasLength(1));
        r.advance(const Duration(seconds: 2));
        expect(r.notifier.shown, hasLength(2), reason: 'still blocked when the minute is up');
        r.dispose();
      });
    });

    test('a flapping agent that is no longer blocked at the minute is not announced', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working'}});
        r.life(away);
        r.change('a', 'w1:p1', 'blocked');
        r.change('a', 'w1:p1', 'working');
        r.change('a', 'w1:p1', 'blocked');
        r.advance(const Duration(seconds: 20));
        r.change('a', 'w1:p1', 'working');
        r.advance(const Duration(minutes: 5));
        expect(r.notifier.shown, hasLength(1));
        expect(r.notifier.visible, isEmpty);
        r.dispose();
      });
    });

    test('a flapping agent is announced again once a minute has passed', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working'}});
        r.life(away);
        r.change('a', 'w1:p1', 'blocked');
        r.change('a', 'w1:p1', 'working');
        r.advance(const Duration(seconds: 61));
        r.change('a', 'w1:p1', 'blocked');
        expect(r.notifier.shown, hasLength(2));
        r.dispose();
      });
    });

    test('finished agents over the burst limit get a summary of their own, and none is dropped silently', () {
      fakeAsync((async) {
        final all = [for (var i = 1; i <= 9; i++) 'w1:p$i'];
        final r = _Rig(async, {'a': {for (final p in all) p: 'working'}}, alsoDone: true);
        r.life(away);
        r.set('a', {for (final p in all) p: 'done'});

        final own = r.notifier.shown.where((n) => n.id != _summaryId && n.id != _finishedSummaryId);
        expect(own, hasLength(3));
        final summary = r.notifier.active[_finishedSummaryId]!;
        expect(summary.title, '9 agents finished');
        expect(summary.kind, NotifyKind.finished);
        expect(summary.link, agentsBoardLink);
        expect(r.notifier.active.containsKey(_summaryId), isFalse, reason: 'nothing needs the person');

        // Looked at on the phone: the count follows, and goes with the last held-back one.
        for (final p in all.skip(3)) {
          r.fleet.markReviewed('a', p);
        }
        expect(r.notifier.active.containsKey(_finishedSummaryId), isFalse);
        expect(r.notifier.visible, hasLength(3));
        r.dispose();
      });
    });

    test('blocked and finished summaries are separate notifications', () {
      fakeAsync((async) {
        final all = [for (var i = 1; i <= 10; i++) 'w1:p$i'];
        final r = _Rig(async, {'a': {for (final p in all) p: 'working'}}, alsoDone: true);
        r.life(away);
        r.set('a', {for (final (i, p) in all.indexed) p: i < 5 ? 'blocked' : 'done'});

        expect(r.notifier.active[_summaryId]!.title, '5 agents need you');
        expect(r.notifier.active[_finishedSummaryId]!.title, '5 agents finished');
        expect(r.notifier.shown.where((n) => n.id != _summaryId && n.id != _finishedSummaryId), hasLength(3),
            reason: 'one burst: three in all, blocked first');
        r.dispose();
      });
    });
  });

  group('done', () {
    test('only with "also when finished": done and not yet reviewed', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working', 'w1:p2': 'working'}});
        r.life(away);
        r.change('a', 'w1:p1', 'done');
        expect(r.notifier.shown, isEmpty);

        r.life(back);
        r.settings.setAlsoDone(true);
        r.async.flushMicrotasks();
        r.life(away);
        r.change('a', 'w1:p2', 'done');

        expect(r.notifier.shown, hasLength(1), reason: 'p1 was done before the app went away');
        final n = r.notifier.shown.single;
        expect(n.id, _id('a', 'w1:p2'));
        expect(n.kind, NotifyKind.finished);
        expect(n.body, 'done · claude · Alpha');
        r.dispose();
      });
    });

    test('an agent that finishes after being reviewed is announced again', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working'}}, alsoDone: true);
        r.life(away);
        r.change('a', 'w1:p1', 'done');
        r.fleet.markReviewed('a', 'w1:p1');
        expect(r.notifier.visible, isEmpty);
        r.change('a', 'w1:p1', 'working');
        r.advance(const Duration(seconds: 61));
        r.change('a', 'w1:p1', 'done');
        expect(r.notifier.shown, hasLength(2));
        r.dispose();
      });
    });

    test('blocked comes before done when the burst limit bites', () {
      fakeAsync((async) {
        final all = [for (var i = 1; i <= 6; i++) 'w1:p$i'];
        final r = _Rig(async, {'a': {for (final p in all) p: 'working'}}, alsoDone: true);
        r.life(away);
        r.set('a', {
          'w1:p1': 'done',
          'w1:p2': 'done',
          'w1:p3': 'done',
          'w1:p4': 'blocked',
          'w1:p5': 'blocked',
          'w1:p6': 'blocked',
        });
        final own = r.notifier.shown.where((n) => n.id != _finishedSummaryId).toList();
        expect(own.map((n) => n.kind), everyElement(NotifyKind.needsYou));
        expect(own, hasLength(3));
        expect(r.notifier.active[_finishedSummaryId]!.title, '3 agents finished',
            reason: 'the done ones are not dropped: they are summarised');
        r.dispose();
      });
    });

    test('turning "also when finished" off withdraws the done notifications', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working'}}, alsoDone: true);
        r.life(away);
        r.change('a', 'w1:p1', 'done');
        expect(r.notifier.visible, hasLength(1));
        r.settings.setAlsoDone(false);
        r.async.flushMicrotasks();
        expect(r.notifier.visible, isEmpty);
        r.dispose();
      });
    });

    test('a finished agent session is announced and withdrawn when seen', () {
      fakeAsync((async) {
        final r = _withSessions(async, {'a': {'w1:p1': 'idle'}}, [('a', 'k1')], alsoDone: true);
        final s = r.sessions.sessions.single as FakeAgentSession;
        _workSession(s);
        r.life(away);
        _idleSession(s);
        s.setUnseenDone(true);

        final n = r.notifier.shown.single;
        expect(n.kind, NotifyKind.finished);
        expect(n.id, notificationIdFor('session/a/k1'));
        expect(n.link, 'herdr://session/a/k1');
        s.markSeen();
        expect(r.notifier.visible, isEmpty);
        r.dispose();
      });
    });
  });

  group('settings and permission', () {
    test('nothing is posted or cancelled while it is off', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working'}}, enabled: false, startup: true);
        r.life(away);
        r.change('a', 'w1:p1', 'blocked');
        r.life(back);

        expect(r.notifier.log, isEmpty);
        expect(r.notifier.permissionReads, 0);
        expect(r.fleet.keepAliveInBackground, isFalse);
        r.dispose();
      });
    });

    test('turning it off cancels everything and stops watching', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working', 'w1:p2': 'working'}});
        r.life(away);
        r.change('a', 'w1:p1', 'blocked');
        expect(r.notifier.visible, hasLength(1));
        expect(r.fleet.keepAliveInBackground, isTrue);

        r.settings.setEnabled(false);
        r.async.flushMicrotasks();
        expect(r.notifier.visible, isEmpty);
        expect(r.notifier.watching.last, 0);
        expect(r.fleet.keepAliveInBackground, isFalse);

        final calls = r.notifier.log.length;
        r.change('a', 'w1:p2', 'blocked');
        expect(r.notifier.log, hasLength(calls), reason: 'off means off');
        r.dispose();
      });
    });

    test('turning it on in the background takes the baseline then', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'blocked', 'w1:p2': 'working'}}, enabled: false);
        r.life(away);
        r.settings.setEnabled(true);
        r.async.flushMicrotasks();
        r.change('a', 'w1:p2', 'blocked');
        expect(r.notifier.shown.map((n) => n.id), [_id('a', 'w1:p2')]);
        r.dispose();
      });
    });

    test('without the permission nothing is posted, and nothing is watched', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working'}}, granted: false);
        r.life(away);
        r.change('a', 'w1:p1', 'blocked');
        expect(r.notifier.shown, isEmpty);
        expect(r.notifier.watching, isEmpty);
        expect(r.fleet.keepAliveInBackground, isFalse);
        r.dispose();
      });
    });

    test('the permission is read again when it is turned on and when the app is back', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working'}}, enabled: false, granted: false);
        expect(r.notifier.permissionReads, 0);
        r.settings.setEnabled(true);
        r.async.flushMicrotasks();
        expect(r.notifier.permissionReads, 1);

        // Allowed in the system settings while the app was away.
        r.notifier.granted = true;
        r.life(away);
        r.life(back);
        expect(r.notifier.permissionReads, 2);
        r.life(away);
        r.change('a', 'w1:p1', 'blocked');
        expect(r.notifier.shown, hasLength(1));
        r.dispose();
      });
    });

    test('a notifier that throws does not break the rest', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working', 'w1:p2': 'working'}});
        r.life(away);
        r.notifier.failing = true;
        r.change('a', 'w1:p1', 'blocked');
        r.notifier.failing = false;
        r.change('a', 'w1:p2', 'blocked');
        expect(r.notifier.shown.map((n) => n.id), [_id('a', 'w1:p2')]);
        r.dispose();
      });
    });

    test('at its start, with the app in front, it clears what an earlier life left and any zombie notice', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working'}}, startup: true);
        expect(r.notifier.log.take(2), ['cancelAll', 'watching:0']);
        expect(r.notifier.watching, [0, 1], reason: 'the first real count replaces the notice');
        r.dispose();
      });
    });

    test('with notifications off it does not even do that', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working'}}, enabled: false, startup: true);
        expect(r.notifier.log, isEmpty);
        expect(r.notifier.permissionReads, 0);
        r.dispose();
      });
    });
  });

  group('agent sessions', () {
    test('a blocked session is announced with a link to its chat, and withdrawn when answered', () {
      fakeAsync((async) {
        final r = _withSessions(async, {'a': {'w1:p1': 'idle'}}, [('a', 'k1')]);
        final s = r.sessions.sessions.single as FakeAgentSession;
        _workSession(s);
        r.life(away);
        _blockSession(s);

        final n = r.notifier.shown.single;
        expect(n.id, notificationIdFor('session/a/k1'));
        expect(n.kind, NotifyKind.needsYou);
        expect(n.title, 'payments-api');
        expect(n.body, 'needs you · Claude Code · Alpha');
        expect(n.link, 'herdr://session/a/k1');
        expect(parseSessionLink(n.link), const SessionLink('a', 'k1'));

        _workSession(s);
        expect(r.notifier.visible, isEmpty);
        r.dispose();
      });
    });

    test('a session that was blocked when the app went away is seen', () {
      fakeAsync((async) {
        final r = _withSessions(async, {'a': {'w1:p1': 'idle'}}, [('a', 'k1')]);
        _blockSession(r.sessions.sessions.single as FakeAgentSession);
        r.life(away);
        r.advance(const Duration(minutes: 5));
        expect(r.notifier.shown, isEmpty);
        r.dispose();
      });
    });

    test('terminal agents and sessions share the burst limit', () {
      fakeAsync((async) {
        final r = _withSessions(async, {'a': {'w1:p1': 'working', 'w1:p2': 'working'}}, [('a', 'k1'), ('a', 'k2')]);
        final sessions = [for (final s in r.sessions.sessions) s as FakeAgentSession];
        r.life(away);
        r.set('a', {'w1:p1': 'blocked', 'w1:p2': 'blocked'});
        sessions.forEach(_blockSession);

        expect(r.notifier.shown.where((n) => n.id != _summaryId), hasLength(3));
        expect(r.notifier.active[_summaryId]!.title, '4 agents need you');
        r.dispose();
      });
    });

    test('a session that is attaching again keeps its episode; the same request back is not announced twice', () {
      fakeAsync((async) {
        final r = _withSessions(async, {'a': {'w1:p1': 'idle'}}, [('a', 'k1')]);
        final s = r.sessions.sessions.single as FakeAgentSession;
        _workSession(s);
        r.life(away);
        _blockSession(s);
        expect(r.notifier.shown, hasLength(1));

        // The link blips: the request is cleared from what the session shows,
        // and nobody knows yet whether it is still there.
        s.setLink(session_api.AgentLink.reconnecting);
        _idleSession(s);
        expect(r.notifier.visible, hasLength(1));
        s.setLink(session_api.AgentLink.connecting);
        expect(r.notifier.visible, hasLength(1));

        // It attaches again; the agent asks the very same thing while that
        // goes on, and the link is live at the end.
        _blockSession(s);
        s.setLink(session_api.AgentLink.live);
        expect(r.notifier.shown, hasLength(1), reason: 'the same episode');
        expect(r.notifier.visible, hasLength(1));

        _workSession(s);
        expect(r.notifier.visible, isEmpty, reason: 'a live state says it left blocked');
        r.dispose();
      });
    });

    test('a session that attaches again and finds the request gone is withdrawn', () {
      fakeAsync((async) {
        final r = _withSessions(async, {'a': {'w1:p1': 'idle'}}, [('a', 'k1')]);
        final s = r.sessions.sessions.single as FakeAgentSession;
        _workSession(s);
        r.life(away);
        _blockSession(s);
        s.setLink(session_api.AgentLink.reconnecting);
        _idleSession(s);
        expect(r.notifier.visible, hasLength(1));

        s.setLink(session_api.AgentLink.live);
        expect(r.notifier.visible, isEmpty, reason: 'live and idle: answered elsewhere');
        r.dispose();
      });
    });

    test('a session that ended or failed is over: its notification goes', () {
      fakeAsync((async) {
        final r = _withSessions(async, {'a': {'w1:p1': 'idle'}}, [('a', 'k1'), ('a', 'k2')]);
        final ended = r.sessions.sessions.first as FakeAgentSession;
        final failed = r.sessions.sessions.last as FakeAgentSession;
        _workSession(ended);
        _workSession(failed);
        r.life(away);
        _blockSession(ended);
        _blockSession(failed);
        expect(r.notifier.visible, hasLength(2));

        ended.setLink(session_api.AgentLink.ended);
        _idleSession(ended);
        failed.setLink(session_api.AgentLink.failed);
        _idleSession(failed);
        expect(r.notifier.visible, isEmpty);
        r.dispose();
      });
    });
  });

  group('watching', () {
    test('counts reachable agents that work or are blocked, terminal and session', () {
      fakeAsync((async) {
        final r = _withSessions(
          async,
          {
            'a': {'w1:p1': 'working', 'w1:p2': 'blocked', 'w1:p3': 'idle', 'w1:p4': 'done'},
            'b': {'w1:p1': 'working'},
          },
          [('a', 'k1')],
        );
        _workSession(r.sessions.sessions.single as FakeAgentSession);
        r.advance(const Duration(seconds: 2));
        expect(r.notifier.watching, [3, 4]);

        r.connection('b').goOffline();
        r.async.flushMicrotasks();
        r.advance(const Duration(seconds: 3));
        expect(r.notifier.watching, [3, 4], reason: 'a machine out of reach is still watched: it comes back');
        r.dispose();
      });
    });

    test('the network going away for a moment does not end the watch', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working'}});
        r.life(AppLifecycleState.paused);
        r.advance(const Duration(minutes: 5)); // past the 90 s grace
        expect(r.fleet.keepAliveInBackground, isTrue);

        r.network.goOffline();
        r.advance(const Duration(seconds: 10));
        expect(r.fleet.keepAliveInBackground, isTrue, reason: 'nothing to watch is not what happened');
        expect(r.notifier.watching.last, isNot(0));

        r.network.goOnline('mobile');
        r.advance(const Duration(seconds: 5));
        expect(r.connection('a').isLive, isTrue, reason: 'back by itself, nobody opened the app');
        r.dispose();
      });
    });

    test('a machine that needs the person is not watched', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working'}});
        r.transports['a']!.failure = const HerdrTransportException('bad key', fatal: true);
        r.connection('a').reconnect();
        r.advance(const Duration(seconds: 5));
        expect(r.connection('a').state, LinkState.attention);
        expect(r.notifier.watching.last, 0);
        expect(r.fleet.keepAliveInBackground, isFalse);
        r.dispose();
      });
    });

    test('a change of count reaches the notifier at most once per 2 seconds', () {
      fakeAsync((async) {
        final r = _Rig(async, {
          'a': {'w1:p1': 'working', 'w1:p2': 'idle', 'w1:p3': 'idle', 'w1:p4': 'idle'},
        });
        expect(r.notifier.watching, [1]);

        r.change('a', 'w1:p2', 'working');
        r.change('a', 'w1:p3', 'working');
        r.change('a', 'w1:p4', 'working');
        expect(r.notifier.watching, [1], reason: 'debounced');

        r.advance(const Duration(seconds: 2));
        expect(r.notifier.watching, [1, 4], reason: 'one call, the last count');
        r.dispose();
      });
    });

    test('nothing to watch stops the notice and the keep-alive at once', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working'}});
        expect(r.fleet.keepAliveInBackground, isTrue);

        r.change('a', 'w1:p1', 'idle');
        expect(r.fleet.keepAliveInBackground, isFalse, reason: 'no more waiting for the notice');
        r.advance(const Duration(seconds: 2));
        expect(r.notifier.watching, [1, 0]);
        r.dispose();
      });
    });

    test('a refused start is retried on the next lifecycle change, never in a loop', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working', 'w1:p2': 'idle'}});
        r.notifier.watchingWorks = false;
        r.life(AppLifecycleState.inactive); // the first start already ran; start over
        r.change('a', 'w1:p1', 'idle');
        r.advance(const Duration(seconds: 2));
        r.notifier.watching.clear();

        r.change('a', 'w1:p1', 'working');
        r.advance(const Duration(seconds: 3));
        expect(r.notifier.watching, [1]);
        expect(r.fleet.keepAliveInBackground, isFalse, reason: 'no notice, no keep-alive');

        r.change('a', 'w1:p2', 'working');
        r.advance(const Duration(minutes: 10));
        expect(r.notifier.watching, [1], reason: 'refused: not asked again');

        r.notifier.watchingWorks = true;
        r.life(AppLifecycleState.paused);
        expect(r.notifier.watching, [1, 2]);
        expect(r.fleet.keepAliveInBackground, isTrue);
        r.dispose();
      });
    });

    test('stopping returns false by contract: that is not a refusal', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working'}});
        r.change('a', 'w1:p1', 'idle');
        r.advance(const Duration(seconds: 2));
        expect(r.notifier.watching, [1, 0]);

        r.change('a', 'w1:p1', 'working');
        r.advance(const Duration(seconds: 2));
        expect(r.notifier.watching, [1, 0, 1]);
        expect(r.fleet.keepAliveInBackground, isTrue);
        r.dispose();
      });
    });

    test('disposing stops the notice and the keep-alive', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working'}});
        expect(r.fleet.keepAliveInBackground, isTrue);
        r.attention.dispose();
        r.async.flushMicrotasks();
        expect(r.notifier.watching, [1, 0]);
        expect(r.fleet.keepAliveInBackground, isFalse);
        r.fleet.dispose();
        r.settings.dispose();
      });
    });
  });

  group('keeping the connections', () {
    test('while there is work to watch the fleet is not suspended after 90 s; when it ends, at once', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working'}});
        r.life(away);
        r.advance(const Duration(minutes: 10));
        expect(r.connection('a').isLive, isTrue);

        r.change('a', 'w1:p1', 'idle');
        r.async.flushMicrotasks();
        expect(r.connection('a').isLive, isFalse, reason: 'the grace period was long over');
        r.dispose();
      });
    });

    test('the sessions are kept and let go together with the connections', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working'}});
        expect(r.fleet.keepAliveInBackground, isTrue);
        expect(r.sessions.keepAlive, isTrue);

        r.change('a', 'w1:p1', 'idle');
        expect(r.fleet.keepAliveInBackground, isFalse);
        expect(r.sessions.keepAlive, isFalse);
        r.dispose();
      });
    });

    test('the same with notifications off: the old 90 s applies', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working'}}, enabled: false);
        r.life(away);
        r.advance(const Duration(seconds: 91));
        expect(r.connection('a').isLive, isFalse);
        r.dispose();
      });
    });
  });

  group('the glance', () {
    test('says how many agents are watched and how many of them need you', () {
      fakeAsync((async) {
        final r = _Rig(async, {
          'a': {'w1:p1': 'blocked', 'w1:p2': 'working', 'w1:p3': 'working', 'w1:p4': 'idle'},
          'b': {'w1:p1': 'blocked', 'w1:p2': 'working'},
        });
        expect(r.notifier.glances, [(count: 5, blocked: 2)]);
        r.dispose();
      });
    });

    test('a change of who needs you is a new line even when the total stays; the same numbers are not', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working', 'w1:p2': 'working'}});
        expect(r.notifier.glances, [(count: 2, blocked: 0)]);

        r.advance(const Duration(seconds: 2));
        r.change('a', 'w1:p1', 'blocked');
        r.advance(const Duration(seconds: 2));
        expect(r.notifier.glances, [(count: 2, blocked: 0), (count: 2, blocked: 1)]);

        // Another agent takes its place: same numbers, nothing to say.
        r.set('a', {'w1:p1': 'working', 'w1:p2': 'blocked'});
        r.advance(const Duration(seconds: 5));
        expect(r.notifier.glances, hasLength(2));
        r.dispose();
      });
    });

    test('a session that waits for a permission or a question needs you', () {
      fakeAsync((async) {
        final r = _withSessions(async, {'a': {'w1:p1': 'working'}}, [('a', 'k1'), ('a', 'k2')]);
        _blockSession(r.sessions.sessions.first as FakeAgentSession);
        _workSession(r.sessions.sessions.last as FakeAgentSession);
        r.advance(const Duration(seconds: 2));
        expect(r.notifier.glances.last, (count: 3, blocked: 1));
        r.dispose();
      });
    });
  });

  test('a question\'s fingerprint follows what it shows, not where the cursor is', () {
    const yes = QuickReply(label: '1. Yes', keys: ['enter']);
    const no = QuickReply(label: '2. No', keys: ['down', 'enter']);
    const base = PromptInfo(question: 'Proceed?', subject: 'ls', replies: [yes, no]);
    expect(
      promptDigest(const PromptInfo(question: 'Proceed?', subject: 'ls', replies: [
        QuickReply(label: '1. Yes', keys: ['up', 'enter']),
        QuickReply(label: '2. No', keys: ['enter']),
      ])),
      promptDigest(base),
    );
    expect(promptDigest(const PromptInfo(question: 'Proceed?', subject: 'rm -rf /', replies: [yes, no])),
        isNot(promptDigest(base)));
    expect(promptDigest(const PromptInfo(question: 'Proceed?', subject: 'ls', replies: [no, yes])),
        isNot(promptDigest(base)));
    expect(promptDigest(const PromptInfo(question: 'Proceed?ls', replies: [yes, no])), isNot(promptDigest(base)),
        reason: 'the question and the command are told apart');
    expect(promptDigest(base), matches(RegExp(r'^[0-9a-f]{16}$')));
  });

  group('answers from the notification', () {
    final id = _id('a', 'w1:p1');

    // What Claude draws; the detector's reading of it is what the card shows.
    const lsPrompt = ' Bash command\n   ls -la\n\n Do you want to proceed?\n'
        ' ❯ 1. Yes\n   2. Yes, and don\'t ask again for ls commands\n'
        '   3. No, and tell Claude what to do differently (esc)\n';
    const pushPrompt = ' Bash command\n   git push origin main\n\n Do you want to proceed?\n'
        ' ❯ 1. Yes\n   2. Yes, and don\'t ask again for git push commands\n'
        '   3. No, and tell Claude what to do differently (esc)\n';
    const rmPrompt = ' Bash command\n   rm -rf build\n\n Do you want to proceed?\n'
        ' ❯ 1. Yes\n   2. Yes, and don\'t ask again for rm commands\n'
        '   3. No, and tell Claude what to do differently (esc)\n';

    /// A machine whose pane w1:p1 shows [screen] when it becomes blocked; the
    /// app is away, and the question has been read.
    _Rig blocked(FakeAsync async, String screen) {
      final r = _Rig(async, {'a': {'w1:p1': 'working'}}, answers: true);
      r.transports['a']!.screens['w1:p1'] = screen;
      r.life(away);
      r.change('a', 'w1:p1', 'blocked');
      return r;
    }

    List<String> labels(_Rig r) => [for (final a in r.notifier.active[id]!.answers) a.label];

    test('the announcement is not held up by reading the question; the text and buttons follow', () {
      fakeAsync((async) {
        final r = blocked(async, lsPrompt);
        expect(r.notifier.showsOf(id), 2);
        expect(r.notifier.shown.first.body, 'needs you · claude · Alpha');
        expect(r.notifier.shown.first.answers, isEmpty);

        final n = r.notifier.active[id]!;
        expect(n.body, 'Do you want to proceed?\nls -la\nneeds you · claude · Alpha');
        expect(n.collapsed, 'ls -la', reason: 'a heads-up shows the command, not a bare "proceed?"');
        expect(n.link, 'herdr://agent/a/w1%3Ap1');
        r.dispose();
      });
    });

    test('buttons only for options that need no second tap: never a standing grant', () {
      fakeAsync((async) {
        final r = blocked(async, lsPrompt);
        expect(labels(r), ['1. Yes', '3. No'], reason: '"don\'t ask again" is never one tap');
        r.dispose();
      });
    });

    test('an option the card makes you confirm is not a button', () {
      fakeAsync((async) {
        final r = blocked(async, pushPrompt);
        expect(labels(r), ['3. No']);
        expect(r.notifier.active[id]!.body, contains('git push origin main'));
        r.dispose();
      });
    });

    test('a question the app does not understand stays a plain notification', () {
      fakeAsync((async) {
        final r = blocked(async, 'building...\nstill building\n');
        expect(r.notifier.showsOf(id), 1);
        expect(r.notifier.active[id]!.answers, isEmpty);
        r.dispose();
      });
    });

    test('the command is shown as the person would read it: hidden characters are made visible', () {
      fakeAsync((async) {
        final r = blocked(async, lsPrompt.replaceFirst('ls -la', 'ls \u202e-la'));
        final n = r.notifier.active[id]!;
        expect(n.body, contains('ls \u2039U+202E\u203a-la'));
        expect(n.body, isNot(contains('\u202e')));
        r.dispose();
      });
    });

    test('a command too long to be shown whole gets no buttons', () {
      fakeAsync((async) {
        final long = [for (var i = 0; i < 5; i++) '   echo ${'x' * 150}'].join('\n');
        final r = blocked(async, ' Bash command\n$long\n\n Do you want to proceed?\n'
            ' ❯ 1. Yes\n   2. No\n');
        expect(r.notifier.active[id]!.body, contains('echo ${'x' * 150}'));
        expect(r.notifier.active[id]!.answers, isEmpty);
        r.dispose();
      });
    });

    test('the buttons are made for this notification: each post has its own', () {
      fakeAsync((async) {
        final r = blocked(async, lsPrompt);
        final first = r.notifier.button(id);
        r.life(back);
        r.life(away);
        r.change('a', 'w1:p1', 'working');
        r.advance(const Duration(minutes: 1));
        r.change('a', 'w1:p1', 'blocked');
        expect(r.notifier.button(id).nonce, isNot(first.nonce));
        expect(r.notifier.button(id).digest, first.digest, reason: 'the same question');
        r.dispose();
      });
    });

    test('pressing a button sends that option once, on the existing connection, and withdraws the notification', () {
      fakeAsync((async) {
        final r = blocked(async, lsPrompt);
        final yes = r.notifier.button(id);
        final connections = r.transports['a']!.calls.length;
        r.notifier.press(yes, id);
        async.flushMicrotasks();

        expect(r.transports['a']!.sent, ['w1:p1 1 enter']);
        expect(r.notifier.active, isNot(contains(id)));
        expect(r.notifier.log.last, 'cancel:$id');
        // Read the pane again, send the keys: no more than that went to herdr.
        expect(r.transports['a']!.calls.length - connections, 2);

        // Delivered a second time (or pressed twice): nothing more is sent.
        r.notifier.press(yes, id);
        async.flushMicrotasks();
        expect(r.transports['a']!.sent, hasLength(1));
        expect(r.notifier.shown.where((n) => n.title == answerNotSentTitle), isEmpty);
        r.dispose();
      });
    });

    test('the other button sends its own keys', () {
      fakeAsync((async) {
        final r = blocked(async, lsPrompt);
        r.notifier.press(r.notifier.button(id, 1), id);
        async.flushMicrotasks();
        expect(r.transports['a']!.sent, ['w1:p1 3 enter']);
        r.dispose();
      });
    });

    test('a question that changed since the notification was posted sends nothing, and opens the agent on a tap', () {
      fakeAsync((async) {
        final r = blocked(async, lsPrompt);
        final yes = r.notifier.button(id);
        // Same words around it, another command: "Yes" would now approve rm.
        r.transports['a']!.screens['w1:p1'] = rmPrompt;
        r.notifier.press(yes, id);
        async.flushMicrotasks();

        expect(r.transports['a']!.sent, isEmpty);
        final told = r.notifier.active[id]!;
        expect(told.title, answerNotSentTitle);
        expect(told.body, contains('nothing was sent'));
        expect(told.link, 'herdr://agent/a/w1%3Ap1');
        expect(told.answers, isEmpty);
        r.dispose();
      });
    });

    test('a question that is gone sends nothing', () {
      fakeAsync((async) {
        final r = blocked(async, lsPrompt);
        final yes = r.notifier.button(id);
        r.transports['a']!.screens['w1:p1'] = 'ok, done.\n';
        r.notifier.press(yes, id);
        async.flushMicrotasks();
        expect(r.transports['a']!.sent, isEmpty);
        expect(r.notifier.active[id]!.title, answerNotSentTitle);
        r.dispose();
      });
    });

    test('the same screen on a pane herdr no longer calls blocked sends nothing', () {
      fakeAsync((async) {
        final r = blocked(async, lsPrompt);
        final yes = r.notifier.button(id);
        r.herdr('a', {'w1:p1': 'working'});
        r.connection('a').refresh();
        r.advance(const Duration(milliseconds: 200));
        r.notifier.press(yes, id);
        async.flushMicrotasks();
        expect(r.transports['a']!.sent, isEmpty);
        r.dispose();
      });
    });

    test('an option that needs a second tap is never sent from here, even if a button for it is forged', () {
      fakeAsync((async) {
        final r = blocked(async, lsPrompt);
        final yes = r.notifier.button(id);
        // Index 1 is "don't ask again": the digest is the right one.
        final forged = NotificationAnswer(
            machineId: 'a', paneId: 'w1:p1', digest: yes.digest, index: 1, nonce: 'forged-1');
        r.notifier.press(forged, id);
        async.flushMicrotasks();
        expect(r.transports['a']!.sent, isEmpty);

        final past = NotificationAnswer(
            machineId: 'a', paneId: 'w1:p1', digest: yes.digest, index: 7, nonce: 'forged-2');
        r.notifier.press(past, id);
        async.flushMicrotasks();
        expect(r.transports['a']!.sent, isEmpty);
        r.dispose();
      });
    });

    test('a machine that cannot be reached sends nothing, and the person is told which', () {
      fakeAsync((async) {
        final r = blocked(async, lsPrompt);
        final yes = r.notifier.button(id);
        r.connection('a').goOffline();
        r.async.flushMicrotasks();
        r.notifier.press(yes, id);
        async.flushMicrotasks();
        expect(r.transports['a']!.sent, isEmpty);
        expect(r.notifier.active[id]!.title, answerNotSentTitle);
        expect(r.notifier.active[id]!.body, contains('Alpha'));
        r.dispose();
      });
    });

    test('a send that fails is not tried again by the same button', () {
      fakeAsync((async) {
        final r = blocked(async, lsPrompt);
        final yes = r.notifier.button(id);
        final herdr = r.transports['a']!;
        herdr.duringRead = () => herdr.failure = StateError('link dropped');
        r.notifier.press(yes, id);
        async.flushMicrotasks();
        herdr.failure = null;
        herdr.duringRead = null;
        expect(herdr.sent, isEmpty);
        expect(r.notifier.active[id]!.title, answerNotSentTitle);

        r.notifier.press(yes, id);
        async.flushMicrotasks();
        expect(herdr.sent, isEmpty, reason: 'it may have gone out; a second try could answer twice');
        r.dispose();
      });
    });

    test('an answered agent that asks again is news at once, not after the flap minute', () {
      fakeAsync((async) {
        final r = blocked(async, lsPrompt);
        r.notifier.press(r.notifier.button(id), id);
        async.flushMicrotasks();
        final before = r.notifier.showsOf(id);

        r.change('a', 'w1:p1', 'working');
        r.advance(const Duration(seconds: 5));
        r.transports['a']!.screens['w1:p1'] = rmPrompt;
        r.change('a', 'w1:p1', 'blocked');
        expect(r.notifier.showsOf(id), before + 2, reason: 'announced, then given its buttons');
        expect(r.notifier.active[id]!.body, contains('rm -rf build'));
        r.dispose();
      });
    });

    test('a notification the app already cleared is not given buttons when the read comes back late', () {
      fakeAsync((async) {
        final r = _Rig(async, {'a': {'w1:p1': 'working'}}, answers: true);
        r.transports['a']!.screens['w1:p1'] = lsPrompt;
        r.transports['a']!.duringRead = () => r.attention.onLifecycleState(back);
        r.life(away);
        r.change('a', 'w1:p1', 'blocked');
        expect(r.notifier.showsOf(id), 1);
        expect(r.notifier.visible, isEmpty);
        r.dispose();
      });
    });

    test('sessions and finished agents get no buttons', () {
      fakeAsync((async) {
        final r = _withSessions(async, {'a': {'w1:p1': 'working'}}, [('a', 'k1')]);
        r.life(away);
        _blockSession(r.sessions.sessions.single as FakeAgentSession);
        expect(r.notifier.shown.single.answers, isEmpty);
        r.dispose();
      });
    });
  });
}
