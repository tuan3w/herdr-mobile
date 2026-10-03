import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/herdr_models.dart';

/// Last known [Snapshot] per machine, so a cold start can show something
/// before the first network round-trip completes.
abstract interface class SnapshotCache {
  /// Null when nothing usable is stored.
  Future<Snapshot?> read(String machineId);

  Future<void> write(String machineId, Snapshot snapshot);

  Future<void> delete(String machineId);
}

/// [SnapshotCache] on `shared_preferences`, one JSON string per machine.
class PrefsSnapshotCache implements SnapshotCache {
  PrefsSnapshotCache({this.maxBytes = 512 * 1024});

  /// Bump the version when the JSON shape stops round-tripping.
  static const _prefix = 'herdr.snapshot.v1.';

  /// Snapshots larger than this (UTF-16 code units of the JSON) are not
  /// stored: prefs are loaded eagerly at startup and must stay small.
  final int maxBytes;

  /// Prefs operations on one machine must land in call order (a delete on
  /// machine removal must not be overtaken by an earlier write).
  Future<void> _tail = Future.value();

  Future<T> _enqueue<T>(Future<T> Function() op) {
    final result = _tail.then((_) => op());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  @override
  Future<Snapshot?> read(String machineId) => _enqueue(() async {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString('$_prefix$machineId');
        if (raw == null) return null;
        try {
          return Snapshot.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        } on Object {
          return null;
        }
      });

  @override
  Future<void> write(String machineId, Snapshot snapshot) => _enqueue(() async {
        final raw = jsonEncode(snapshot.toJson());
        if (raw.length > maxBytes) return;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('$_prefix$machineId', raw);
      });

  @override
  Future<void> delete(String machineId) => _enqueue(() async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('$_prefix$machineId');
      });
}
