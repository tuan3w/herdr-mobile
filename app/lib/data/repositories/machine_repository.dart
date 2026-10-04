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

  // The three reads go out together (not one after the other), so a machine's
  // secrets cost one round trip's wait, and reading several machines queues
  // their reads machine by machine: the first is ready as early as it can be.
  @override
  Future<MachineSecrets> read(String id) async {
    final fields = await Future.wait([
      _s.read(key: _k(id, 'key')),
      _s.read(key: _k(id, 'passphrase')),
      _s.read(key: _k(id, 'password')),
    ]);
    return MachineSecrets(
      privateKeyPem: fields[0],
      passphrase: fields[1],
      password: fields[2],
    );
  }

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

  // Reads started ahead of need (see [warmSecrets]), each handed over once.
  final Map<String, Future<MachineSecrets>> _warm = {};

  /// Starts reading every saved machine's secrets now, all at once, so that
  /// the keychain's start-up work (the first read pays for its cipher) runs
  /// while the first frame is built instead of after it. Each read is handed
  /// to the first [secretsFor] that asks and then forgotten: nothing decrypted
  /// is kept longer than a connection being set up needs it.
  void warmSecrets() {
    for (final m in _machines) {
      _warm[m.id] ??= (_secrets.read(m.id)..ignore());
    }
  }

  Future<MachineSecrets> secretsFor(String id) =>
      _warm.remove(id) ?? _secrets.read(id);

  String newId() {
    final r = Random.secure();
    return List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// Adds or replaces [profile]. Pass [secrets] to (re)write credentials;
  /// null keeps the stored ones.
  Future<void> save(MachineProfile profile, {MachineSecrets? secrets}) async {
    if (secrets != null) {
      _warm.remove(profile.id);
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
    _warm.remove(id);
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
