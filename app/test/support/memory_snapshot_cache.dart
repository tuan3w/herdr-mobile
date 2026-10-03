import 'dart:async';

import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/services/snapshot_cache.dart';

class MemorySnapshotCache implements SnapshotCache {
  MemorySnapshotCache([Map<String, Snapshot>? initial])
      : entries = {...?initial};

  final Map<String, Snapshot> entries;

  /// Every write in order, as `(machineId, snapshot)`.
  final List<(String, Snapshot)> writes = [];
  final List<String> deletes = [];

  /// When set, [read] waits for it (simulates slow storage).
  Completer<void>? readGate;

  @override
  Future<Snapshot?> read(String machineId) async {
    await readGate?.future;
    return entries[machineId];
  }

  @override
  Future<void> write(String machineId, Snapshot snapshot) async {
    writes.add((machineId, snapshot));
    entries[machineId] = snapshot;
  }

  @override
  Future<void> delete(String machineId) async {
    deletes.add(machineId);
    entries.remove(machineId);
  }
}
