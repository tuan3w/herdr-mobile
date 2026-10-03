import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';

class MemoryProfileStore implements ProfileStore {
  List<MachineProfile> profiles = [];

  @override
  Future<List<MachineProfile>> read() async => List.of(profiles);

  @override
  Future<void> write(List<MachineProfile> p) async => profiles = List.of(p);
}

class MemorySecretStore implements SecretStore {
  final Map<String, MachineSecrets> secrets = {};

  @override
  Future<MachineSecrets> read(String id) async =>
      secrets[id] ?? const MachineSecrets();

  @override
  Future<void> write(String id, MachineSecrets s) async => secrets[id] = s;

  @override
  Future<void> delete(String id) async => secrets.remove(id);
}
