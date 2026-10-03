import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';

import 'support/fake_transport.dart';
import 'support/memory_stores.dart';

MachineProfile _machine(String id, String label) =>
    MachineProfile(id: id, label: label, host: '$id.local', username: 'u');

({String id, String ws, String? agent, String status}) _pane(
        String id, String status,
        {String? agent = 'claude'}) =>
    (id: id, ws: 'w1', agent: agent, status: status);

class _Harness {
  _Harness() {
    machines = MachineRepository(
        profiles: MemoryProfileStore(), secrets: MemorySecretStore());
    fleet = FleetRepository(
      machines: machines,
      connect: (profile, secrets) {
        final t = transports.putIfAbsent(profile.id, FakeTransport.new);
        return MachineConnection(
          profile: profile,
          api: HerdrApi(t),
          backoff: (_) => const Duration(milliseconds: 10),
          pollInterval: const Duration(hours: 1),
        );
      },
    );
  }

  late final MachineRepository machines;
  late final FleetRepository fleet;
  final transports = <String, FakeTransport>{};

  Future<void> add(MachineProfile p, {Map<String, dynamic>? snapshot}) async {
    transports[p.id] = FakeTransport(snapshot);
    await machines.save(p, secrets: const MachineSecrets(password: 'x'));
    await fleet.settled();
  }

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
}
