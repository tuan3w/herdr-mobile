import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import 'support/fake_network.dart';
import 'support/fake_transport.dart';
import 'support/memory_stores.dart';

MachineProfile _machine(String id) =>
    MachineProfile(id: id, label: id, host: '$id.local', username: 'u');

void main() {
  late MachineRepository machines;
  late FleetRepository fleet;
  late bool badFactory;

  setUp(() {
    badFactory = true;
    machines = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
    fleet = FleetRepository(
      machines: machines,
      network: FakeNetwork(),
      connect: (profile, secrets) {
        if (profile.id == 'bad' && badFactory) throw StateError('cannot build ${profile.id}');
        return MachineConnection(
          profile: profile,
          api: HerdrApi(FakeTransport()),
          pollInterval: const Duration(hours: 1),
        );
      },
    );
  });
  tearDown(() => fleet.dispose());

  Future<void> save(MachineProfile p) async {
    await machines.save(p, secrets: const MachineSecrets(password: 'x'));
    await fleet.settled();
  }

  test('a machine whose connection cannot be built does not stop the next machine being added', () async {
    await save(_machine('bad'));
    await save(_machine('good'));

    expect(fleet.connections.map((c) => c.profile.id), ['good']);
  });

  test('a machine added together with a failing one still gets its connection', () async {
    await machines.save(_machine('bad'), secrets: const MachineSecrets(password: 'x'));
    await machines.save(_machine('good'), secrets: const MachineSecrets(password: 'x'));
    await fleet.settled();

    expect(fleet.connection('good'), isNotNull);
  });

  test('the failing machine is built again by the next change, once it can be', () async {
    await save(_machine('bad'));
    expect(fleet.connection('bad'), isNull);

    badFactory = false;
    await save(_machine('other'));

    expect(fleet.connections.map((c) => c.profile.id), ['bad', 'other']);
  });

  test('editing and removing machines still works after a failure', () async {
    await save(_machine('bad'));
    await save(_machine('good'));
    final before = fleet.connection('good');

    await save(_machine('good').copyWith(label: 'renamed'));
    expect(fleet.connection('good'), isNot(same(before)), reason: 'an edit rebuilds the connection');
    expect(fleet.connection('good')!.profile.label, 'renamed');

    await machines.remove('good');
    await fleet.settled();
    expect(fleet.connection('good'), isNull);
  });
}
