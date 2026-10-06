import 'dart:async';

import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/models/status_time.dart';
import 'package:herdr_mobile/data/services/snapshot_cache.dart';

class MemorySnapshotCache implements SnapshotCache {
  MemorySnapshotCache([Map<String, Snapshot>? initial, Map<String, ObservedStatuses>? observed])
      : entries = {...?initial},
        observed = {...?observed};

  final Map<String, Snapshot> entries;

  /// The status times stored beside each snapshot.
  final Map<String, ObservedStatuses> observed;

  /// Every write in order, as `(machineId, snapshot)`.
  final List<(String, Snapshot)> writes = [];
  final List<String> deletes = [];

  /// When set, [read] waits for it (simulates slow storage).
  Completer<void>? readGate;

  @override
  Future<CachedSnapshot?> read(String machineId) async {
    await readGate?.future;
    final snapshot = entries[machineId];
    return snapshot == null ? null : CachedSnapshot(snapshot, observed[machineId]);
  }

  @override
  Future<void> write(String machineId, Snapshot snapshot, {ObservedStatuses? observed}) async {
    writes.add((machineId, snapshot));
    entries[machineId] = snapshot;
    if (observed != null) this.observed[machineId] = observed;
  }

  @override
  Future<void> delete(String machineId) async {
    deletes.add(machineId);
    entries.remove(machineId);
    observed.remove(machineId);
  }
}
