import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/snapshot_cache.dart';

import 'support/fake_transport.dart';
import 'support/memory_snapshot_cache.dart';
import 'support/test_transport.dart';

const _profile =
    MachineProfile(id: 'm', label: 'box', host: 'h', username: 'u');

/// Real-time tests: short delays so `eventually` stays quick.
MachineConnection _connection(FakeTransport t) => MachineConnection(
      profile: _profile,
      api: HerdrApi(t),
      backoff: (_) => const Duration(milliseconds: 10),
      pollInterval: const Duration(hours: 1),
      structuralDelay: const Duration(milliseconds: 20),
      churnInterval: const Duration(milliseconds: 100),
    );

/// `fakeAsync` tests: production throttle defaults, and a backoff so long
/// that any reconnect that happens must have skipped it.
MachineConnection _slow(FakeTransport t, {SnapshotCache? cache}) =>
    MachineConnection(
      profile: _profile,
      api: HerdrApi(t),
      cache: cache,
      backoff: (_) => const Duration(seconds: 30),
      pollInterval: const Duration(hours: 1),
    );

const _structural = Duration(milliseconds: 150);

Map<String, dynamic> _paneUpdated(String id) => {
      'event': 'pane_updated',
      'data': {
        'type': 'pane_updated',
        'pane': {'pane_id': id},
      },
    };

/// Starts [c] and lets the first connect finish.
void _online(FakeAsync async, MachineConnection c) {
  c.start();
  async.flushMicrotasks();
  expect(c.isLive, isTrue);
}

({String id, String ws, String? agent, String status}) _pane(
        String id, String status) =>
    (id: id, ws: 'w1', agent: 'claude', status: status);

void main() {
  test('goes online with a fresh snapshot', () async {
    final t = FakeTransport(snapshotJson(panes: [_pane('w1:p1', 'working')]));
    final c = _connection(t)..start();
    addTearDown(c.dispose);

    await eventually(() => c.isLive, reason: 'online');
    expect(c.snapshot.agentPanes.single.status, AgentStatus.working);
    expect(c.snapshot.version, '9.9.9');
  });

  test('a changed event re-fetches the snapshot', () async {
    final t = FakeTransport(snapshotJson(panes: [_pane('w1:p1', 'working')]));
    final c = _connection(t)..start();
    addTearDown(c.dispose);
    await eventually(() => c.isLive && t.subscriptions == 1);

    t.snapshot = snapshotJson(panes: [_pane('w1:p1', 'blocked')]);
    t.emit();

    await eventually(
      () => c.snapshot.agentPanes.single.status == AgentStatus.blocked,
      reason: 'refresh after event',
    );
  });

  // Regression: busy agents emit events continuously. A debounce that resets
  // on every event never fires, so the UI froze on stale state.
  test('refreshes even while events arrive continuously', () async {
    final t = FakeTransport(snapshotJson(panes: [_pane('w1:p1', 'working')]));
    final c = _connection(t)..start();
    addTearDown(c.dispose);
    await eventually(() => c.isLive && t.subscriptions == 1);

    t.snapshot = snapshotJson(panes: [_pane('w1:p1', 'blocked')]);
    final flood = Timer.periodic(const Duration(milliseconds: 5), (_) => t.emit());
    addTearDown(flood.cancel);

    await eventually(
      () => c.snapshot.agentPanes.single.status == AgentStatus.blocked,
      reason: 'refresh during event flood',
    );
  });

  // `pane_updated` carries the whole pane (same shape as a snapshot pane).
  // Busy agents emit it for every spinner frame; refetching the full session
  // each time was the dominant steady-state cost.
  group('pane_updated is classified against the known pane', () {
    Map<String, dynamic> event(
      FakeTransport t,
      void Function(Map<String, dynamic>) edit,
    ) {
      final pane = Map<String, dynamic>.of(
          (t.snapshot['panes'] as List).first as Map<String, dynamic>);
      edit(pane);
      return {
        'event': 'pane_updated',
        'data': {'type': 'pane_updated', 'pane': pane},
      };
    }

    test('spinner churn that changes nothing we show causes no refetch', () {
      fakeAsync((async) {
        final t = FakeTransport(snapshotJson(panes: [_pane('w1:p1', 'working')]));
        final c = _slow(t);
        _online(async, c);
        final activity = <String>[];
        c.paneActivity.listen(activity.add);
        final before = t.snapshotCalls;

        for (var i = 0; i < 50; i++) {
          t.emit(event(t, (p) => p['terminal_title_stripped'] = '⠹ title w1:p1'));
        }
        async.elapse(const Duration(seconds: 10));

        expect(t.snapshotCalls, before);
        expect(activity, hasLength(50),
            reason: 'an open pane view still needs every activity signal');
        c.dispose();
      });
    });

    test('a status flip refreshes at structural speed', () {
      fakeAsync((async) {
        final t = FakeTransport(snapshotJson(panes: [_pane('w1:p1', 'working')]));
        final c = _slow(t);
        _online(async, c);
        final before = t.snapshotCalls;

        t.snapshot = snapshotJson(panes: [_pane('w1:p1', 'blocked')]);
        t.emit(event(t, (p) => p['agent_status'] = 'blocked'));
        async.elapse(_structural + const Duration(milliseconds: 10));

        expect(t.snapshotCalls, before + 1);
        expect(c.snapshot.agentPanes.single.status, AgentStatus.blocked);
        c.dispose();
      });
    });

    test('a real title change is throttled, not immediate', () {
      fakeAsync((async) {
        final t = FakeTransport(snapshotJson(panes: [_pane('w1:p1', 'working')]));
        final c = _slow(t);
        _online(async, c);
        final before = t.snapshotCalls;

        t.emit(event(t, (p) => p['terminal_title_stripped'] = 'a different task'));
        async.elapse(const Duration(milliseconds: 500));
        expect(t.snapshotCalls, before, reason: 'inside the churn window');

        async.elapse(const Duration(seconds: 2));
        expect(t.snapshotCalls, before + 1);
        c.dispose();
      });
    });

    test('a pane we have never seen refreshes at once', () {
      fakeAsync((async) {
        final t = FakeTransport(snapshotJson(panes: [_pane('w1:p1', 'working')]));
        final c = _slow(t);
        _online(async, c);
        final before = t.snapshotCalls;

        t.emit(event(t, (p) => p['pane_id'] = 'w1:p9'));
        async.elapse(_structural + const Duration(milliseconds: 10));

        expect(t.snapshotCalls, before + 1);
        c.dispose();
      });
    });
  });

  test('refreshes are coalesced, not one per event', () async {
    final t = FakeTransport();
    final c = _connection(t)..start();
    addTearDown(c.dispose);
    await eventually(() => c.isLive && t.subscriptions == 1);
    final before = t.snapshotCalls;

    for (var i = 0; i < 50; i++) {
      t.emit();
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(t.snapshotCalls - before, lessThanOrEqualTo(3));
  });

  test('reconnects after the event channel drops, keeping the stale snapshot',
      () async {
    final t = FakeTransport(snapshotJson(panes: [_pane('w1:p1', 'working')]));
    final c = _connection(t)..start();
    addTearDown(c.dispose);
    await eventually(() => c.isLive && t.subscriptions == 1);

    t.failure = const HerdrTransportException('network down');
    t.dropEvents(const HerdrTransportException('network down'));
    await eventually(() => c.state == LinkState.reconnecting, reason: 'reconnecting');
    expect(c.error, 'network down');
    expect(c.snapshot.agentPanes, hasLength(1), reason: 'stale state kept');

    t.failure = null;
    await eventually(() => c.isLive, reason: 'back online');
    expect(c.error, isNull);
  });

  test('a fatal error needs attention and stops retrying until retry()', () async {
    final t = FakeTransport()
      ..failure = const HerdrTransportException('bad key', fatal: true);
    final c = _connection(t)..start();
    addTearDown(c.dispose);

    await eventually(() => c.state == LinkState.attention);
    expect(c.error, 'bad key');
    final calls = t.calls.length;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(t.calls.length, calls, reason: 'no retry storm on fatal errors');

    t.failure = null;
    c.retry();
    await eventually(() => c.isLive, reason: 'online after retry');
  });

  test('disabled machine never connects', () async {
    final t = FakeTransport();
    final c = MachineConnection(
      profile: _profile.copyWith(enabled: false),
      api: HerdrApi(t),
    )..start();
    addTearDown(c.dispose);

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.state, LinkState.disabled);
    expect(t.calls, isEmpty);
  });

  test('dispose closes the transport', () async {
    final t = FakeTransport();
    final c = _connection(t)..start();
    await eventually(() => c.isLive);
    c.dispose();
    await eventually(() => t.closed, reason: 'transport closed');
  });

  group('notifications', () {
    test('an identical refetch is silent; a real change notifies once', () {
      fakeAsync((async) {
        final t = FakeTransport(snapshotJson(panes: [_pane('w1:p1', 'working')]));
        final c = _slow(t);
        _online(async, c);
        var notified = 0;
        c.addListener(() => notified++);
        final calls = t.snapshotCalls;

        t.emit({'event': 'workspace_updated'});
        async.elapse(_structural);
        expect(t.snapshotCalls, calls + 1, reason: 'it did refetch');
        expect(notified, 0, reason: 'but nothing visible changed');

        t.snapshot = snapshotJson(panes: [_pane('w1:p1', 'blocked')]);
        t.emit({'event': 'pane_agent_status_changed'});
        async.elapse(_structural);
        expect(notified, 1);
        expect(c.snapshot.agentPanes.single.status, AgentStatus.blocked);
        c.dispose();
      });
    });

    test('state and error changes notify; repeating them does not', () {
      fakeAsync((async) {
        final t = FakeTransport()
          ..failure = const HerdrTransportException('down');
        final c = _slow(t);
        var notified = 0;
        c.addListener(() => notified++);
        c.start();
        async.flushMicrotasks();
        expect(c.state, LinkState.reconnecting);
        final afterFirstFailure = notified;

        t.failure = const HerdrTransportException('still down');
        async.elapse(const Duration(seconds: 30));
        expect(notified, afterFirstFailure + 1, reason: 'error text changed');
        t.failure = const HerdrTransportException('still down');
        async.elapse(const Duration(seconds: 30));
        expect(notified, afterFirstFailure + 1, reason: 'same state and error');
        c.dispose();
      });
    });
  });

  group('event throttling', () {
    test('a pane_updated flood refreshes at most once per 1500 ms, never starves',
        () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = _slow(t);
        _online(async, c);
        final before = t.snapshotCalls;

        for (var i = 0; i < 600; i++) {
          t.emit(_paneUpdated('w1:p1'));
          async.elapse(const Duration(milliseconds: 10));
        }

        expect(t.snapshotCalls - before, inInclusiveRange(3, 4),
            reason: '6 s of continuous churn');
        c.dispose();
      });
    });

    test('a structural event during a flood refreshes within 150 ms', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = _slow(t);
        _online(async, c);

        for (var i = 0; i < 30; i++) {
          t.emit(_paneUpdated('w1:p1'));
          async.elapse(const Duration(milliseconds: 10));
        }
        expect(c.snapshot.workspaces, hasLength(1));

        t.snapshot = snapshotJson(workspaces: [
          (id: 'w1', label: 'main'),
          (id: 'w2', label: 'new'),
        ]);
        t.emit({'event': 'workspace_created'});
        for (var i = 0; i < 15; i++) {
          t.emit(_paneUpdated('w1:p1')); // the flood keeps going
          async.elapse(const Duration(milliseconds: 10));
        }

        expect(c.snapshot.workspaces, hasLength(2));
        c.dispose();
      });
    });

    test('every structural and status event kind refreshes within 150 ms', () {
      for (final name in const [
        'workspace_created',
        'workspace_closed',
        'tab_created',
        'tab_closed',
        'pane_created',
        'pane_closed',
        'pane_exited',
        'pane_agent_detected',
        'layout_updated',
        'pane_agent_status_changed',
        'worktree_created',
        'worktree_removed',
      ]) {
        fakeAsync((async) {
          final t = FakeTransport();
          final c = _slow(t);
          _online(async, c);
          final before = t.snapshotCalls;

          t.emit({'event': name});
          async.elapse(_structural);

          expect(t.snapshotCalls, before + 1, reason: name);
          c.dispose();
        });
      }
    });

    test('a lone pane_updated waits for the churn interval', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = _slow(t);
        _online(async, c);
        final before = t.snapshotCalls;

        t.emit(_paneUpdated('w1:p1'));
        async.elapse(const Duration(milliseconds: 1400));
        expect(t.snapshotCalls, before);
        async.elapse(const Duration(milliseconds: 100));
        expect(t.snapshotCalls, before + 1);
        c.dispose();
      });
    });

    test('events during an in-flight refresh yield exactly one trailing refresh',
        () {
      fakeAsync((async) {
        final t = TestTransport();
        final c = _slow(t);
        _online(async, c);
        final started = t.snapshotStarted;

        t.gate = Completer<void>();
        t.emit({'event': 'tab_created'});
        async.elapse(_structural);
        expect(t.snapshotStarted, started + 1, reason: 'refresh is in flight');

        for (var i = 0; i < 5; i++) {
          t.emit({'event': 'tab_created'});
        }
        async.flushMicrotasks();
        expect(t.snapshotStarted, started + 1, reason: 'coalesced, not parallel');

        t.gate!.complete();
        t.gate = null;
        async.flushMicrotasks();
        async.elapse(_structural);
        expect(t.snapshotStarted, started + 2);

        async.elapse(const Duration(seconds: 30));
        expect(t.snapshotStarted, started + 2, reason: 'and then it settles');
        c.dispose();
      });
    });
  });

  group('paneActivity', () {
    test('emits the pane id of each pane_updated and ignores everything else', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = _slow(t);
        _online(async, c);
        final ids = <String>[];
        final sub = c.paneActivity.listen(ids.add);

        t.emit(_paneUpdated('w1:p1'));
        t.emit({'event': 'workspace_created'});
        t.emit({
          'event': 'pane_created',
          'data': {
            'pane': {'pane_id': 'w1:p7'},
          },
        });
        t.emit(_paneUpdated('w2:p3'));
        t.emit({'event': 'pane_updated'}); // malformed: no pane id
        async.flushMicrotasks();

        expect(ids, ['w1:p1', 'w2:p3']);
        sub.cancel();
        c.dispose();
      });
    });

    test('is broadcast: late listeners see only later events', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = _slow(t);
        _online(async, c);
        final early = <String>[];
        final later = <String>[];
        c.paneActivity.listen(early.add);

        t.emit(_paneUpdated('w1:p1'));
        async.flushMicrotasks();
        c.paneActivity.listen(later.add);
        t.emit(_paneUpdated('w1:p2'));
        async.flushMicrotasks();

        expect(early, ['w1:p1', 'w1:p2']);
        expect(later, ['w1:p2']);
        c.dispose();
      });
    });
  });

  group('network awareness', () {
    test('goOffline stops everything but keeps the stale snapshot', () {
      fakeAsync((async) {
        final t = FakeTransport(snapshotJson(panes: [_pane('w1:p1', 'working')]));
        final c = _slow(t);
        _online(async, c);

        c.goOffline();
        async.flushMicrotasks();
        expect(c.state, LinkState.offline);
        expect(c.snapshot.agentPanes, hasLength(1));
        final calls = t.calls.length;

        async.elapse(const Duration(minutes: 10));
        expect(t.calls.length, calls, reason: 'no requests while offline');
        c.dispose();
      });
    });

    test('goOffline during a backoff cancels the pending retry', () {
      fakeAsync((async) {
        final t = FakeTransport()
          ..failure = const HerdrTransportException('down');
        final c = _slow(t)..start();
        async.flushMicrotasks();
        expect(c.state, LinkState.reconnecting);
        final calls = t.calls.length;

        async.elapse(const Duration(seconds: 20));
        c.goOffline();
        async.elapse(const Duration(minutes: 10));

        expect(c.state, LinkState.offline);
        expect(t.calls.length, calls, reason: 'the 30 s backoff timer is dead');
        c.dispose();
      });
    });

    test('reconnect after offline is immediate, not after the backoff', () {
      fakeAsync((async) {
        final t = FakeTransport()
          ..failure = const HerdrTransportException('down');
        final c = _slow(t)..start();
        async.flushMicrotasks();
        c.goOffline();

        t.failure = null;
        c.reconnect();
        async.flushMicrotasks(); // no elapse: backoff is 30 s

        expect(c.isLive, isTrue);
        expect(t.resets, 1, reason: 'the dead socket is dropped first');
        expect(c.error, isNull);
        c.dispose();
      });
    });

    test('reconnect while online drops the socket and resubscribes', () {
      fakeAsync((async) {
        final t = TestTransport();
        final c = _slow(t);
        _online(async, c);
        expect(t.liveEventStreams, 1);

        c.reconnect();
        async.flushMicrotasks();

        expect(c.isLive, isTrue);
        expect(t.resets, 1);
        expect(t.subscriptions, 2);
        expect(t.liveEventStreams, 1, reason: 'old watch is gone');
        c.dispose();
      });
    });

    test('goOffline and reconnect leave attention alone', () {
      fakeAsync((async) {
        final t = FakeTransport()
          ..failure = const HerdrTransportException('bad key', fatal: true);
        final c = _slow(t)..start();
        async.flushMicrotasks();
        expect(c.state, LinkState.attention);
        final calls = t.calls.length;

        c.goOffline();
        c.reconnect();
        async.elapse(const Duration(minutes: 1));

        expect(c.state, LinkState.attention);
        expect(c.error, 'bad key');
        expect(t.calls.length, calls);
        expect(t.resets, 0);
        c.dispose();
      });
    });

    test('goOffline leaves a disabled machine disabled', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = MachineConnection(
          profile: _profile.copyWith(enabled: false),
          api: HerdrApi(t),
        )..goOffline();
        expect(c.state, LinkState.disabled);
        c.reconnect();
        async.flushMicrotasks();
        expect(c.state, LinkState.disabled);
        expect(t.calls, isEmpty);
        c.dispose();
      });
    });
  });

  group('resume races', () {
    test('rapid reconnects never leave two live watch loops', () {
      fakeAsync((async) {
        final t = TestTransport();
        final c = _slow(t);
        _online(async, c);

        c.reconnect();
        c.reconnect();
        c.reconnect();
        async.flushMicrotasks();

        expect(c.isLive, isTrue);
        expect(t.liveEventStreams, 1);
        c.dispose();
        async.flushMicrotasks();
        expect(t.liveEventStreams, 0);
      });
    });

    test('reconnect while the first connect is mid-flight leaves one watch', () {
      fakeAsync((async) {
        final t = TestTransport()..gate = Completer<void>();
        final c = _slow(t)..start();
        async.flushMicrotasks();
        expect(t.snapshotStarted, 1);

        c.reconnect();
        async.flushMicrotasks();
        expect(t.snapshotStarted, 2, reason: 'immediate, on a fresh socket');

        t.gate!.complete();
        async.flushMicrotasks();
        expect(c.isLive, isTrue);
        expect(t.liveEventStreams, 1, reason: 'the superseded loop never watches');
        c.dispose();
      });
    });

    test('goOffline while a watch is unwinding cannot resurrect it', () {
      fakeAsync((async) {
        final t = TestTransport();
        final c = _slow(t);
        _online(async, c);

        c.goOffline();
        c.reconnect();
        c.goOffline();
        async.elapse(const Duration(minutes: 1));

        expect(c.state, LinkState.offline);
        expect(t.liveEventStreams, 0);
        c.dispose();
      });
    });

    test('retry while online is a no-op, not a second loop', () {
      fakeAsync((async) {
        final t = TestTransport();
        final c = _slow(t);
        _online(async, c);
        final calls = t.calls.length;

        c.retry();
        async.flushMicrotasks();

        expect(t.liveEventStreams, 1);
        expect(t.calls.length, calls);
        c.dispose();
      });
    });

    test('a refresh failing after the loop was replaced is ignored', () {
      fakeAsync((async) {
        final t = TestTransport()..gate = Completer<void>();
        final c = _slow(t)..start();
        async.flushMicrotasks();
        c.goOffline();

        t.failure = const HerdrTransportException('late failure');
        t.gate!.complete();
        async.flushMicrotasks();

        expect(c.state, LinkState.offline, reason: 'stale loop must not touch state');
        expect(c.error, isNull);
        c.dispose();
      });
    });
  });

  group('suspend', () {
    test('tears the connection down, retries nothing, retry() resumes', () {
      fakeAsync((async) {
        final t = TestTransport();
        final c = _slow(t);
        _online(async, c);

        c.suspend();
        async.flushMicrotasks();
        expect(c.isLive, isFalse);
        expect(c.state, LinkState.reconnecting);
        expect(t.resets, 1);
        expect(t.liveEventStreams, 0);
        final calls = t.calls.length;

        async.elapse(const Duration(minutes: 10));
        expect(t.calls.length, calls);

        c.retry();
        async.flushMicrotasks();
        expect(c.isLive, isTrue);
        c.dispose();
      });
    });

    test('does not override offline or attention', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final c = _slow(t);
        _online(async, c);
        c.goOffline();
        c.suspend();
        expect(c.state, LinkState.offline);
        c.dispose();
      });
    });
  });

  group('snapshot cache', () {
    final cached = Snapshot.fromJson(snapshotJson(
      panes: [_pane('w1:p9', 'blocked')],
      version: 'cached',
    ));

    test('seeds the snapshot before the first fetch completes', () {
      fakeAsync((async) {
        final cache = MemorySnapshotCache({'m': cached});
        final t = TestTransport(snapshotJson(panes: [_pane('w1:p1', 'working')]))
          ..gate = Completer<void>();
        final c = _slow(t, cache: cache);
        var notified = 0;
        c.addListener(() => notified++);

        c.start();
        async.flushMicrotasks();

        expect(t.snapshotStarted, 1, reason: 'network round-trip still pending');
        expect(c.snapshot, cached);
        expect(c.state, LinkState.connecting, reason: 'stale, so not live');
        expect(c.isLive, isFalse);
        expect(notified, 1);

        t.gate!.complete();
        async.flushMicrotasks();
        expect(c.isLive, isTrue);
        expect(c.snapshot.agentPanes.single.id, 'w1:p1');
        c.dispose();
      });
    });

    test('a slow cache read never overrides a fresh snapshot', () {
      fakeAsync((async) {
        final cache = MemorySnapshotCache({'m': cached})
          ..readGate = Completer<void>();
        final t = FakeTransport(snapshotJson(panes: [_pane('w1:p1', 'working')]));
        final c = _slow(t, cache: cache);
        _online(async, c);

        cache.readGate!.complete();
        async.flushMicrotasks();

        expect(c.snapshot.version, '9.9.9');
        expect(c.snapshot.agentPanes.single.id, 'w1:p1');
        c.dispose();
      });
    });

    test('a cache that throws is ignored', () {
      fakeAsync((async) {
        final c = _slow(FakeTransport(), cache: _ThrowingCache());
        _online(async, c);
        expect(c.snapshot.version, '9.9.9');
        c.dispose();
      });
    });

    test('goOffline on a cold start still shows the cached snapshot', () {
      fakeAsync((async) {
        final c = _slow(FakeTransport(), cache: MemorySnapshotCache({'m': cached}))
          ..goOffline();
        async.flushMicrotasks();
        expect(c.state, LinkState.offline);
        expect(c.snapshot, cached);
        c.dispose();
      });
    });

    test('writes are throttled to one per 5 s, trailing with the latest', () {
      fakeAsync((async) {
        final cache = MemorySnapshotCache();
        final t = FakeTransport(snapshotJson(panes: [_pane('w1:p1', 'working')]));
        final c = _slow(t, cache: cache);
        _online(async, c);
        expect(cache.writes, hasLength(1), reason: 'first fresh snapshot goes out');

        for (final status in const ['blocked', 'done', 'idle']) {
          t.snapshot = snapshotJson(panes: [_pane('w1:p1', status)]);
          t.emit({'event': 'pane_agent_status_changed'});
          async.elapse(_structural);
        }
        expect(c.snapshot.agentPanes.single.status, AgentStatus.idle);
        expect(cache.writes, hasLength(1), reason: 'coalesced inside the window');

        async.elapse(const Duration(seconds: 5));
        expect(cache.writes, hasLength(2));
        expect(cache.writes.last, ('m', c.snapshot), reason: 'latest, not first');

        async.elapse(const Duration(minutes: 1));
        expect(cache.writes, hasLength(2), reason: 'unchanged: nothing to write');
        c.dispose();
      });
    });

    test('an identical refetch does not write', () {
      fakeAsync((async) {
        final cache = MemorySnapshotCache();
        final t = FakeTransport();
        final c = _slow(t, cache: cache);
        _online(async, c);

        t.emit({'event': 'tab_created'});
        async.elapse(const Duration(seconds: 30));

        expect(cache.writes, hasLength(1));
        c.dispose();
      });
    });

    test('dispose flushes a pending write', () {
      fakeAsync((async) {
        final cache = MemorySnapshotCache();
        final t = FakeTransport(snapshotJson(panes: [_pane('w1:p1', 'working')]));
        final c = _slow(t, cache: cache);
        _online(async, c);

        t.snapshot = snapshotJson(panes: [_pane('w1:p1', 'blocked')]);
        t.emit({'event': 'pane_agent_status_changed'});
        async.elapse(_structural);
        expect(cache.writes, hasLength(1));

        final latest = c.snapshot;
        c.dispose();
        async.flushMicrotasks();

        expect(cache.writes, hasLength(2));
        expect(cache.entries['m'], latest);
      });
    });

    test('dispose without pending changes writes nothing more', () {
      fakeAsync((async) {
        final cache = MemorySnapshotCache();
        final c = _slow(FakeTransport(), cache: cache);
        _online(async, c);
        c.dispose();
        async.flushMicrotasks();
        expect(cache.writes, hasLength(1));
      });
    });

    test('forget deletes the entry and nothing is written afterwards', () {
      fakeAsync((async) {
        final cache = MemorySnapshotCache();
        final t = FakeTransport(snapshotJson(panes: [_pane('w1:p1', 'working')]));
        final c = _slow(t, cache: cache);
        _online(async, c);
        t.snapshot = snapshotJson(panes: [_pane('w1:p1', 'blocked')]); // dirty
        t.emit({'event': 'pane_agent_status_changed'});
        async.elapse(_structural);

        c.forget();
        c.dispose();
        async.elapse(const Duration(seconds: 30));

        expect(cache.deletes, ['m']);
        expect(cache.entries, isEmpty);
        expect(cache.writes, hasLength(1), reason: 'no flush after forget');
      });
    });
  });
}

class _ThrowingCache implements SnapshotCache {
  @override
  Future<Snapshot?> read(String machineId) => Future.error(StateError('disk'));

  @override
  Future<void> write(String machineId, Snapshot snapshot) =>
      Future.error(StateError('disk'));

  @override
  Future<void> delete(String machineId) => Future.error(StateError('disk'));
}
