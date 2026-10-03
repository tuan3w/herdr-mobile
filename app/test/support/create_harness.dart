import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/repositories/new_session_settings.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import 'fake_network.dart';
import 'fake_transport.dart';
import 'herdr_stub.dart';
import 'memory_stores.dart';

class MemoryNewSessionStore implements NewSessionStore {
  NewSessionMemory memory = const NewSessionMemory();
  int writes = 0;

  @override
  Future<NewSessionMemory> read() async => memory;

  @override
  Future<void> write(NewSessionMemory m) async {
    memory = m;
    writes++;
  }
}

typedef MachineSpec = ({MachineProfile profile, Map<String, dynamic> snapshot});

MachineProfile profileOf(String id, String label, {bool enabled = true, String host = 'h.example'}) =>
    MachineProfile(id: id, label: label, host: host, username: 'fatman', enabled: enabled);

/// Fake machines wired like the app wires real ones, on [HerdrStub]s whose
/// answers a test can script. Machines with `enabled: false` stay offline.
class CreateHarness {
  CreateHarness._(this.machines, this.fleet, this.stubs, this.store, this.settings);

  final MachineRepository machines;
  final FleetRepository fleet;
  final Map<String, HerdrStub> stubs;
  final MemoryNewSessionStore store;
  final NewSessionSettings settings;

  MachineConnection connection(String id) => fleet.connection(id)!;

  /// With [waitOnline] false (widget tests) the caller pumps until the
  /// machines are up, as `UiHarness` does.
  static Future<CreateHarness> create(List<MachineSpec> spec, {bool waitOnline = true}) async {
    final machines = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
    await machines.load();
    final stubs = {for (final s in spec) s.profile.id: HerdrStub(s.snapshot)};
    for (final t in stubs.values) {
      // Enough for a pane screen to open on a new pane.
      t.on['pane.read'] = (_) => {
            'type': 'pane_read',
            'read': {'text': '', 'truncated': false},
          };
    }
    final fleet = FleetRepository(
      machines: machines,
      network: FakeNetwork(),
      connect: (profile, secrets) => MachineConnection(
        profile: profile,
        api: HerdrApi(stubs[profile.id]!),
        backoff: (_) => const Duration(hours: 1),
        pollInterval: const Duration(hours: 1),
        structuralDelay: const Duration(milliseconds: 20),
      ),
    );
    for (final s in spec) {
      await machines.save(s.profile, secrets: const MachineSecrets(password: 'x'));
    }
    await fleet.settled();
    final store = MemoryNewSessionStore();
    final h = CreateHarness._(machines, fleet, stubs, store, NewSessionSettings(store));
    if (waitOnline) {
      // Enabled machines are online once their first snapshot has landed.
      await eventually(() => [
            for (final s in spec)
              if (s.profile.enabled) h.connection(s.profile.id).isLive,
          ].every((live) => live));
    }
    return h;
  }

  void dispose() => fleet.dispose();
}
