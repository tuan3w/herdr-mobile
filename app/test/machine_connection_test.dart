import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';

import 'support/fake_transport.dart';

const _profile =
    MachineProfile(id: 'm', label: 'box', host: 'h', username: 'u');

MachineConnection _connection(FakeTransport t) => MachineConnection(
      profile: _profile,
      api: HerdrApi(t),
      backoff: (_) => const Duration(milliseconds: 10),
      pollInterval: const Duration(hours: 1),
      refreshDebounce: const Duration(milliseconds: 20),
    );

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
}
