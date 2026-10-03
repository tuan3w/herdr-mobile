import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/machine_profile.dart';

/// Persists non-secret machine profiles.
abstract interface class ProfileStore {
  Future<List<MachineProfile>> read();
  Future<void> write(List<MachineProfile> profiles);
}

/// Persists per-machine secrets (private key, passphrase, password).
abstract interface class SecretStore {
  Future<MachineSecrets> read(String machineId);
  Future<void> write(String machineId, MachineSecrets secrets);
  Future<void> delete(String machineId);
}

class PrefsProfileStore implements ProfileStore {
  static const _key = 'machines.v1';

  @override
  Future<List<MachineProfile>> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const [];
    return (jsonDecode(raw) as List)
        .cast<Map<String, dynamic>>()
        .map(MachineProfile.fromJson)
        .toList();
  }

  @override
  Future<void> write(List<MachineProfile> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(profiles.map((p) => p.toJson()).toList()));
  }
}

class KeychainSecretStore implements SecretStore {
  KeychainSecretStore([FlutterSecureStorage? storage])
      : _s = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _s;

  String _k(String id, String field) => 'machine.$id.$field';

  @override
  Future<MachineSecrets> read(String id) async => MachineSecrets(
        privateKeyPem: await _s.read(key: _k(id, 'key')),
        passphrase: await _s.read(key: _k(id, 'passphrase')),
        password: await _s.read(key: _k(id, 'password')),
      );

  Future<void> _put(String id, String field, String? value) => value == null
      ? _s.delete(key: _k(id, field))
      : _s.write(key: _k(id, field), value: value);

  @override
  Future<void> write(String id, MachineSecrets s) async {
    await _put(id, 'key', s.privateKeyPem);
    await _put(id, 'passphrase', s.passphrase);
    await _put(id, 'password', s.password);
  }

  @override
  Future<void> delete(String id) => write(id, const MachineSecrets());
}

/// Source of truth for the saved machine list.
class MachineRepository extends ChangeNotifier {
  MachineRepository({required this._profiles, required this._secrets});

  final ProfileStore _profiles;
  final SecretStore _secrets;
  List<MachineProfile> _machines = const [];
  final Map<String, int> _credentialRevision = {};

  List<MachineProfile> get machines => _machines;

  /// Bumped whenever a machine's secrets are rewritten, so consumers can
  /// restart connections that were using the old ones.
  int credentialRevision(String id) => _credentialRevision[id] ?? 0;

  Future<void> load() async {
    _machines = await _profiles.read();
    notifyListeners();
  }

  Future<MachineSecrets> secretsFor(String id) => _secrets.read(id);

  String newId() {
    final r = Random.secure();
    return List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// Adds or replaces [profile]. Pass [secrets] to (re)write credentials;
  /// null keeps the stored ones.
  Future<void> save(MachineProfile profile, {MachineSecrets? secrets}) async {
    if (secrets != null) {
      await _secrets.write(profile.id, secrets);
      _credentialRevision[profile.id] = credentialRevision(profile.id) + 1;
    }
    final i = _machines.indexWhere((m) => m.id == profile.id);
    _machines = [
      for (var j = 0; j < _machines.length; j++)
        if (j == i) profile else _machines[j],
      if (i < 0) profile,
    ];
    await _profiles.write(_machines);
    notifyListeners();
  }

  Future<void> remove(String id) async {
    _machines = _machines.where((m) => m.id != id).toList();
    await _profiles.write(_machines);
    await _secrets.delete(id);
    notifyListeners();
  }

  /// Persists a host key trusted on first use without disturbing connections.
  Future<void> pinHostKey(String id, String fingerprint) async {
    final i = _machines.indexWhere((m) => m.id == id);
    if (i < 0) return;
    _machines = [
      for (var j = 0; j < _machines.length; j++)
        if (j == i)
          _machines[j].copyWith(hostKeyFingerprint: fingerprint)
        else
          _machines[j],
    ];
    await _profiles.write(_machines);
    notifyListeners();
  }
}
