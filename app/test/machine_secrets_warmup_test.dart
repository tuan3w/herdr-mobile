import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';

import 'support/memory_stores.dart';

/// A keychain that counts its reads and can be made to fail.
class _CountingSecrets extends MemorySecretStore {
  final reads = <String>[];
  Object? failure;

  @override
  Future<MachineSecrets> read(String id) async {
    reads.add(id);
    if (failure != null) throw failure!;
    return super.read(id);
  }
}

MachineProfile _profile(String id) =>
    MachineProfile(id: id, label: id, host: '$id.example', username: 'u');

Future<(MachineRepository, _CountingSecrets)> _repo(List<String> ids) async {
  final profiles = MemoryProfileStore()..profiles = [for (final id in ids) _profile(id)];
  final secrets = _CountingSecrets();
  for (final id in ids) {
    secrets.secrets[id] = MachineSecrets(password: 'pw-$id');
  }
  final repo = MachineRepository(profiles: profiles, secrets: secrets);
  await repo.load();
  return (repo, secrets);
}

void main() {
  test('warmed secrets are read once, ahead of time, for every machine', () async {
    final (repo, keychain) = await _repo(['a', 'b']);

    repo.warmSecrets();
    repo.warmSecrets(); // a second call starts nothing new
    expect(keychain.reads, ['a', 'b']);

    expect((await repo.secretsFor('b')).password, 'pw-b');
    expect((await repo.secretsFor('a')).password, 'pw-a');
    expect(keychain.reads, ['a', 'b'], reason: 'handed over, not read again');
  });

  test('a warmed read is handed over once: the next ask goes to the keychain', () async {
    final (repo, keychain) = await _repo(['a']);
    repo.warmSecrets();
    await repo.secretsFor('a');

    // Rotated in the keychain behind the repository's back.
    keychain.secrets['a'] = const MachineSecrets(password: 'rotated');
    expect((await repo.secretsFor('a')).password, 'rotated');
    expect(keychain.reads, ['a', 'a']);
  });

  test('saving new credentials drops a warmed read of the old ones', () async {
    final (repo, _) = await _repo(['a']);
    repo.warmSecrets();

    await repo.save(_profile('a'), secrets: const MachineSecrets(password: 'new'));

    expect((await repo.secretsFor('a')).password, 'new');
  });

  test('removing a machine drops its warmed read and still saves the list', () async {
    final profiles = MemoryProfileStore()..profiles = [_profile('a'), _profile('b')];
    final secrets = _CountingSecrets()
      ..secrets['a'] = const MachineSecrets(password: 'pw-a');
    final repo = MachineRepository(profiles: profiles, secrets: secrets);
    await repo.load();
    repo.warmSecrets();

    await repo.remove('a');

    expect(profiles.profiles.map((p) => p.id), ['b'], reason: 'the list is written');
    expect(secrets.secrets.containsKey('a'), isFalse);
    expect((await repo.secretsFor('a')).password, isNull);
  });

  test('a keychain that fails while warming fails only the ask, and can be retried', () async {
    final (repo, keychain) = await _repo(['a']);
    keychain.failure = StateError('keystore locked');

    repo.warmSecrets(); // must not surface an unhandled error by itself
    await Future<void>.delayed(Duration.zero);

    await expectLater(repo.secretsFor('a'), throwsStateError);

    keychain.failure = null;
    expect((await repo.secretsFor('a')).password, 'pw-a');
  });
}
