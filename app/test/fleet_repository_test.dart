import 'dart:ui' show AppLifecycleState;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/network_monitor.dart';

import 'support/fake_network.dart';
import 'support/fake_transport.dart';
import 'support/memory_snapshot_cache.dart';
import 'support/memory_stores.dart';

MachineProfile _machine(String id, String label) =>
    MachineProfile(id: id, label: label, host: '$id.local', username: 'u');

({String id, String ws, String? agent, String status}) _pane(
        String id, String status,
        {String? agent = 'claude'}) =>
    (id: id, ws: 'w1', agent: agent, status: status);

class _Harness {
  _Harness({
    Duration backoff = const Duration(milliseconds: 10),
    FakeNetwork? network,
    MemorySnapshotCache? cache,
  })  : network = network ?? FakeNetwork(),
        cache = cache ?? MemorySnapshotCache() {
    machines = MachineRepository(
        profiles: MemoryProfileStore(), secrets: MemorySecretStore());
    fleet = FleetRepository(
      machines: machines,
      network: this.network,
      clock: () => now,
      connect: (profile, secrets) {
        final t = transports.putIfAbsent(profile.id, FakeTransport.new);
        return MachineConnection(
          profile: profile,
          api: HerdrApi(t),
          cache: this.cache,
          backoff: (_) => backoff,
          pollInterval: const Duration(hours: 1),
        );
      },
    );
  }

  late final MachineRepository machines;
  late final FleetRepository fleet;
  final FakeNetwork network;
  final MemorySnapshotCache cache;
  final transports = <String, FakeTransport>{};

  /// The fleet's clock; moves only through [advance].
  DateTime now = DateTime(2026);

  Future<void> add(MachineProfile p, {Map<String, dynamic>? snapshot}) async {
    transports[p.id] = FakeTransport(snapshot);
    await machines.save(p, secrets: const MachineSecrets(password: 'x'));
    await fleet.settled();
  }

  /// Moves the fleet clock and the fake timers together.
  void advance(FakeAsync async, Duration d) {
    now = now.add(d);
    async.elapse(d);
  }

  bool get allLive => fleet.connections.every((c) => c.isLive);

  int snapshotCalls(String id) => transports[id]!.snapshotCalls;

  void dispose() => fleet.dispose();
}

void main() {
  late _Harness h;
  setUp(() => h = _Harness());
  tearDown(() => h.dispose());

  test('merges agents from every machine, most urgent first', () async {
    await h.add(_machine('a', 'alpha'),
        snapshot: snapshotJson(panes: [
          _pane('w1:p1', 'idle'),
          _pane('w1:p2', 'working'),
          _pane('w1:p3', 'unknown', agent: null), // plain terminal: excluded
        ]));
    await h.add(_machine('b', 'beta'),
        snapshot: snapshotJson(panes: [_pane('w1:p1', 'blocked')]));
    await eventually(() => h.fleet.connections.every((c) => c.isLive));

    final order = [
      for (final a in h.fleet.agents) '${a.machine.profile.label}:${a.pane.status.name}'
    ];
    expect(order, ['beta:blocked', 'alpha:working', 'alpha:idle']);
  });

  test('same pane id on two machines stays distinct', () async {
    final snap = snapshotJson(panes: [_pane('w1:p1', 'working')]);
    await h.add(_machine('a', 'alpha'), snapshot: snap);
    await h.add(_machine('b', 'beta'), snapshot: snap);
    await eventually(() => h.fleet.connections.every((c) => c.isLive));

    final machines = h.fleet.agents.map((a) => a.machine.profile.id).toSet();
    expect(machines, {'a', 'b'});
  });

  test('attention counts blocked and unseen-done agents only', () async {
    await h.add(_machine('a', 'alpha'),
        snapshot: snapshotJson(panes: [
          _pane('w1:p1', 'blocked'),
          _pane('w1:p2', 'done'),
          _pane('w1:p3', 'working'),
          _pane('w1:p4', 'idle'),
        ]));
    await eventually(() => h.fleet.connections.single.isLive);

    expect(h.fleet.attentionCount, 2);
  });

  test('one machine failing does not affect the others', () async {
    await h.add(_machine('a', 'alpha'),
        snapshot: snapshotJson(panes: [_pane('w1:p1', 'working')]));
    h.transports['b'] = FakeTransport()
      ..failure = const HerdrTransportException('unreachable');
    await h.machines.save(_machine('b', 'beta'),
        secrets: const MachineSecrets(password: 'x'));
    await h.fleet.settled();

    await eventually(() => h.fleet.connection('b')!.state == LinkState.reconnecting);
    expect(h.fleet.connection('a')!.isLive, isTrue);
    expect(h.fleet.agents.single.machine.profile.id, 'a');
  });

  test('removing a machine drops its connection and agents', () async {
    await h.add(_machine('a', 'alpha'),
        snapshot: snapshotJson(panes: [_pane('w1:p1', 'working')]));
    await eventually(() => h.fleet.connection('a')!.isLive);
    final transport = h.transports['a']!;

    await h.machines.remove('a');
    await h.fleet.settled();

    expect(h.fleet.connection('a'), isNull);
    expect(h.fleet.agents, isEmpty);
    await eventually(() => transport.closed, reason: 'transport closed');
  });

  test('editing connection details reconnects; pinning a host key does not',
      () async {
    await h.add(_machine('a', 'alpha'));
    await eventually(() => h.fleet.connection('a')!.isLive);
    final first = h.fleet.connection('a')!;

    await h.machines.pinHostKey('a', 'SHA256:abc');
    await h.fleet.settled();
    expect(h.fleet.connection('a'), same(first), reason: 'pin keeps connection');

    h.transports['a'] = FakeTransport();
    await h.machines.save(
        h.machines.machines.single.copyWith(host: 'new.local'));
    await h.fleet.settled();
    expect(h.fleet.connection('a'), isNot(same(first)));
  });

  test('rewriting credentials reconnects', () async {
    await h.add(_machine('a', 'alpha'));
    await eventually(() => h.fleet.connection('a')!.isLive);
    final first = h.fleet.connection('a')!;

    h.transports['a'] = FakeTransport();
    await h.machines.save(h.machines.machines.single,
        secrets: const MachineSecrets(password: 'rotated'));
    await h.fleet.settled();

    expect(h.fleet.connection('a'), isNot(same(first)));
  });

  test('removing a machine deletes its cached snapshot; editing keeps it', () {
    fakeAsync((async) {
      final h = _Harness();
      h.add(_machine('a', 'alpha'),
          snapshot: snapshotJson(panes: [_pane('w1:p1', 'working')]));
      async.flushMicrotasks();
      expect(h.cache.entries.keys, ['a'], reason: 'fresh snapshot persisted');

      h.transports['a'] = FakeTransport();
      h.machines.save(h.machines.machines.single.copyWith(host: 'new.local'));
      async.flushMicrotasks();
      expect(h.cache.deletes, isEmpty, reason: 'an edit is not a removal');

      final writes = h.cache.writes.length;
      h.machines.remove('a');
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 1));

      expect(h.cache.deletes, ['a']);
      expect(h.cache.entries, isEmpty);
      expect(h.cache.writes.length, writes, reason: 'nothing rewritten after');
      h.dispose();
    });
  });

  group('network', () {
    test('offline pauses every machine without retries; online reconnects at once',
        () {
      fakeAsync((async) {
        // A backoff this long means a quick reconnect cannot be a retry.
        final h = _Harness(backoff: const Duration(hours: 1));
        h.add(_machine('a', 'alpha'));
        h.add(_machine('b', 'beta'));
        async.flushMicrotasks();
        expect(h.allLive, isTrue);
        final calls = {for (final id in ['a', 'b']) id: h.transports[id]!.calls.length};

        h.network.goOffline();
        expect(h.fleet.connections.map((c) => c.state),
            everyElement(LinkState.offline));
        async.elapse(const Duration(minutes: 10));
        for (final id in ['a', 'b']) {
          expect(h.transports[id]!.calls.length, calls[id], reason: id);
        }

        h.network.goOnline();
        async.flushMicrotasks();

        expect(h.allLive, isTrue);
        for (final id in ['a', 'b']) {
          expect(h.transports[id]!.resets, 1, reason: '$id drops the dead socket');
        }
        h.dispose();
      });
    });

    test('a Wi-Fi to cellular switch while online resets and reconnects', () {
      fakeAsync((async) {
        final h = _Harness(backoff: const Duration(hours: 1));
        h.add(_machine('a', 'alpha'));
        async.flushMicrotasks();
        final t = h.transports['a']!;
        expect(t.resets, 0);

        h.network.goOnline('mobile');
        async.flushMicrotasks();

        expect(t.resets, 1);
        expect(t.subscriptions, 2, reason: 'resubscribed on a fresh channel');
        expect(h.allLive, isTrue);
        h.dispose();
      });
    });

    test('offline keeps the stale snapshot visible', () {
      fakeAsync((async) {
        final h = _Harness();
        h.add(_machine('a', 'alpha'),
            snapshot: snapshotJson(panes: [_pane('w1:p1', 'blocked')]));
        async.flushMicrotasks();

        h.network.goOffline();

        final agent = h.fleet.agents.single;
        expect(agent.pane.status, AgentStatus.blocked);
        expect(agent.stale, isTrue);
        h.dispose();
      });
    });

    test('only "none" pauses retries: a failing host keeps retrying while online',
        () {
      fakeAsync((async) {
        final h = _Harness(backoff: const Duration(seconds: 10));
        h.network.goOnline('vpn'); // a VPN-only route, no internet needed
        h.transports['a'] = FakeTransport()
          ..failure = const HerdrTransportException('unreachable');
        h.machines.save(_machine('a', 'alpha'),
            secrets: const MachineSecrets(password: 'x'));
        async.flushMicrotasks();
        final calls = h.transports['a']!.calls.length;

        async.elapse(const Duration(seconds: 35));

        expect(h.transports['a']!.calls.length, greaterThan(calls + 2));
        h.dispose();
      });
    });

    test('a machine added while offline waits, then connects when online', () {
      fakeAsync((async) {
        final h = _Harness(
          network: FakeNetwork(const NetworkState(online: false, signature: '')),
        );
        h.add(_machine('a', 'alpha'));
        async.flushMicrotasks();
        expect(h.fleet.connection('a')!.state, LinkState.offline);
        expect(h.transports['a']!.calls, isEmpty);

        h.network.goOnline();
        async.flushMicrotasks();
        expect(h.fleet.connection('a')!.isLive, isTrue);
        h.dispose();
      });
    });

    test('a cold start offline still shows the cached agents, stale', () {
      fakeAsync((async) {
        final cached = Snapshot.fromJson(
            snapshotJson(panes: [_pane('w1:p1', 'blocked')]));
        final h = _Harness(
          network: FakeNetwork(const NetworkState(online: false, signature: '')),
          cache: MemorySnapshotCache({'a': cached}),
        );
        h.add(_machine('a', 'alpha'));
        async.flushMicrotasks();

        final agent = h.fleet.agents.single;
        expect(agent.pane.id, 'w1:p1');
        expect(agent.stale, isTrue);
        expect(h.transports['a']!.calls, isEmpty);
        h.dispose();
      });
    });

    test('pull-to-refresh does nothing while offline', () {
      fakeAsync((async) {
        final h = _Harness();
        h.add(_machine('a', 'alpha'));
        async.flushMicrotasks();
        h.network.goOffline();
        final calls = h.transports['a']!.calls.length;

        h.fleet.retryAll();
        async.flushMicrotasks();

        expect(h.transports['a']!.calls.length, calls);
        expect(h.fleet.connection('a')!.state, LinkState.offline);
        h.dispose();
      });
    });
  });

  group('app lifecycle', () {
    void addTwo(_Harness h) {
      h.add(_machine('a', 'alpha'));
      h.add(_machine('b', 'beta'));
    }

    test('back after a long absence resets every socket and reconnects now', () {
      fakeAsync((async) {
        final h = _Harness(backoff: const Duration(hours: 1));
        addTwo(h);
        async.flushMicrotasks();

        h.fleet.onLifecycleState(AppLifecycleState.paused);
        h.advance(async, const Duration(seconds: 6));
        h.fleet.onLifecycleState(AppLifecycleState.resumed);
        async.flushMicrotasks();

        for (final id in ['a', 'b']) {
          expect(h.transports[id]!.resets, 1, reason: id);
          expect(h.transports[id]!.subscriptions, 2, reason: id);
        }
        expect(h.allLive, isTrue);
        h.dispose();
      });
    });

    test('back after a short absence only refreshes', () {
      fakeAsync((async) {
        final h = _Harness();
        addTwo(h);
        async.flushMicrotasks();
        final calls = h.snapshotCalls('a');

        h.fleet.onLifecycleState(AppLifecycleState.hidden);
        h.fleet.onLifecycleState(AppLifecycleState.paused);
        h.advance(async, const Duration(seconds: 4));
        h.fleet.onLifecycleState(AppLifecycleState.resumed);
        async.flushMicrotasks();

        for (final id in ['a', 'b']) {
          expect(h.transports[id]!.resets, 0, reason: id);
          expect(h.transports[id]!.subscriptions, 1, reason: id);
        }
        expect(h.snapshotCalls('a'), calls + 1);
        expect(h.allLive, isTrue);
        h.dispose();
      });
    });

    test('exactly at the threshold counts as short', () {
      fakeAsync((async) {
        final h = _Harness();
        addTwo(h);
        async.flushMicrotasks();

        h.fleet.onLifecycleState(AppLifecycleState.paused);
        h.advance(async, const Duration(seconds: 5));
        h.fleet.onLifecycleState(AppLifecycleState.resumed);
        async.flushMicrotasks();

        expect(h.transports['a']!.resets, 0);
        h.dispose();
      });
    });

    test('inactive alone is not backgrounding', () {
      fakeAsync((async) {
        final h = _Harness();
        addTwo(h);
        async.flushMicrotasks();
        final calls = h.snapshotCalls('a');

        h.fleet.onLifecycleState(AppLifecycleState.inactive);
        h.advance(async, const Duration(minutes: 5));
        h.fleet.onLifecycleState(AppLifecycleState.resumed);
        async.flushMicrotasks();

        expect(h.snapshotCalls('a'), calls);
        expect(h.transports['a']!.resets, 0);
        expect(h.allLive, isTrue);
        h.dispose();
      });
    });

    test('90 s in the background suspends every connection; foreground resumes',
        () {
      fakeAsync((async) {
        final h = _Harness();
        addTwo(h);
        async.flushMicrotasks();

        h.fleet.onLifecycleState(AppLifecycleState.paused);
        h.advance(async, const Duration(seconds: 89));
        expect(h.allLive, isTrue, reason: 'not yet');
        h.advance(async, const Duration(seconds: 1));
        expect(h.fleet.connections.map((c) => c.isLive), everyElement(isFalse));
        for (final id in ['a', 'b']) {
          expect(h.transports[id]!.resets, 1, reason: id);
        }
        final calls = h.snapshotCalls('a');

        h.advance(async, const Duration(minutes: 30));
        expect(h.snapshotCalls('a'), calls, reason: 'no retries while suspended');

        h.network.goOnline('mobile'); // route change in the background
        async.flushMicrotasks();
        expect(h.snapshotCalls('a'), calls, reason: 'stays suspended');

        h.fleet.onLifecycleState(AppLifecycleState.resumed);
        async.flushMicrotasks();
        expect(h.allLive, isTrue);
        h.dispose();
      });
    });

    test('hidden then paused does not restart the 90 s clock', () {
      fakeAsync((async) {
        final h = _Harness();
        addTwo(h);
        async.flushMicrotasks();

        h.fleet.onLifecycleState(AppLifecycleState.hidden);
        h.advance(async, const Duration(seconds: 50));
        h.fleet.onLifecycleState(AppLifecycleState.paused);
        h.advance(async, const Duration(seconds: 40));

        expect(h.fleet.connections.map((c) => c.isLive), everyElement(isFalse));
        h.dispose();
      });
    });

    test('coming back cancels the pending suspension', () {
      fakeAsync((async) {
        final h = _Harness();
        addTwo(h);
        async.flushMicrotasks();

        h.fleet.onLifecycleState(AppLifecycleState.paused);
        h.advance(async, const Duration(seconds: 60));
        h.fleet.onLifecycleState(AppLifecycleState.resumed);
        async.flushMicrotasks();
        h.advance(async, const Duration(minutes: 5));

        expect(h.allLive, isTrue);
        h.dispose();
      });
    });

    test('foreground without a network leaves machines offline, no attempts', () {
      fakeAsync((async) {
        final h = _Harness(backoff: const Duration(hours: 1));
        addTwo(h);
        async.flushMicrotasks();

        h.fleet.onLifecycleState(AppLifecycleState.paused);
        h.network.goOffline();
        h.advance(async, const Duration(seconds: 120));
        final calls = h.snapshotCalls('a');
        h.fleet.onLifecycleState(AppLifecycleState.resumed);
        async.flushMicrotasks();

        expect(h.fleet.connections.map((c) => c.state),
            everyElement(LinkState.offline));
        expect(h.snapshotCalls('a'), calls);
        h.dispose();
      });
    });

    test('a suspended fleet resumes even after a short absence', () {
      fakeAsync((async) {
        final h = _Harness(backoff: const Duration(hours: 1));
        addTwo(h);
        async.flushMicrotasks();

        h.fleet.onBackgroundTimeout();
        async.flushMicrotasks();
        expect(h.fleet.connections.map((c) => c.isLive), everyElement(isFalse));

        h.fleet.onForeground(away: const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(h.allLive, isTrue);
        h.dispose();
      });
    });
  });
}
