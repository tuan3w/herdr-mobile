import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/services/ssh_transport.dart';
import 'package:herdr_mobile/data/services/transport_factory.dart';

import 'support/memory_stores.dart';

const _unpinned = MachineProfile(id: 'a', label: 'a', host: 'a.local', username: 'u');

void main() {
  group('what to do with the key a machine presents', () {
    test('with nothing pinned the first key is trusted and pinned', () {
      expect(judgeHostKey(pinned: null, seen: 'SHA256:one'), HostKeyVerdict.trustFirstUse);
    });

    test('the pinned key goes on', () {
      expect(judgeHostKey(pinned: 'SHA256:one', seen: 'SHA256:one'), HostKeyVerdict.matches);
    });

    test('another key than the pinned one is a hard stop, never a new pin', () {
      expect(judgeHostKey(pinned: 'SHA256:one', seen: 'SHA256:two'), HostKeyVerdict.changed);
      expect(judgeHostKey(pinned: 'SHA256:one', seen: ''), HostKeyVerdict.changed);
    });
  });

  group('a worker that is replaced', () {
    late MemoryProfileStore store;
    late MachineRepository machines;

    setUp(() async {
      store = MemoryProfileStore()..profiles = [_unpinned];
      machines = MachineRepository(profiles: store, secrets: MemorySecretStore());
      await machines.load();
    });

    Future<MachineSecrets> secrets() async => const MachineSecrets(password: 'pw');

    test('is built from the host key pinned since the connection was made', () async {
      // What the connection factory hands the transport: the profile as the
      // repository has it at the time a worker starts.
      MachineProfile current() => machines.byId('a') ?? _unpinned;

      final first = await sshWorkerConfig(current(), secrets);
      expect((first['profile']! as Map)['hostKeyFingerprint'], isNull);

      await machines.pinHostKey('a', 'SHA256:one');

      final replaced = await sshWorkerConfig(current(), secrets);
      expect((replaced['profile']! as Map)['hostKeyFingerprint'], 'SHA256:one');
    });
  });

  group('pinning a host key', () {
    test('saves the first key a machine shows', () async {
      final store = MemoryProfileStore()..profiles = [_unpinned];
      final machines = MachineRepository(profiles: store, secrets: MemorySecretStore());
      await machines.load();

      await machines.pinHostKey('a', 'SHA256:one');

      expect(machines.byId('a')!.hostKeyFingerprint, 'SHA256:one');
      expect(store.profiles.single.hostKeyFingerprint, 'SHA256:one');
    });

    test('never replaces a different pin that is already saved', () async {
      final store = MemoryProfileStore()
        ..profiles = [_unpinned.copyWith(hostKeyFingerprint: 'SHA256:one')];
      final machines = MachineRepository(profiles: store, secrets: MemorySecretStore());
      await machines.load();

      await machines.pinHostKey('a', 'SHA256:other');

      expect(machines.byId('a')!.hostKeyFingerprint, 'SHA256:one');
      expect(store.profiles.single.hostKeyFingerprint, 'SHA256:one');
    });

    test('a machine that is not saved (any more) is ignored', () async {
      final store = MemoryProfileStore();
      final machines = MachineRepository(profiles: store, secrets: MemorySecretStore());
      await machines.load();

      await machines.pinHostKey('gone', 'SHA256:one');

      expect(store.profiles, isEmpty);
    });
  });
}
