import 'dart:async';
import 'dart:convert';

import 'package:herdr_mobile/data/acp/transcript_log.dart';
import 'package:herdr_mobile/data/services/transcript_cache.dart';

/// A [TranscriptCache] in memory that keeps what a test needs to look at: what
/// was asked, when, and how (debounced or at once). Shares one instance
/// between "runs" of the app to simulate a restart.
class MemoryTranscriptCache implements TranscriptCache {
  /// What was saved last, per key (the debounce is not simulated: every save
  /// lands).
  final stored = <String, TranscriptSnapshot>{};

  /// Every save asked for: its key and whether it was `now`.
  final saves = <(String, bool)>[];
  final deleted = <String>[];
  final retained = <(String, Set<String>)>[];
  final machinesDeleted = <String>[];
  var reads = 0;

  /// While set, a read waits for it (a slow disk).
  Completer<void>? readGate;

  @override
  Future<CachedTranscript?> read(String key) async {
    reads++;
    if (readGate case final gate?) await gate.future;
    final snapshot = stored[key];
    if (snapshot == null) return null;
    return CachedTranscript(
      sessionId: snapshot.sessionId,
      asOf: snapshot.asOf,
      setup: snapshot.setup,
      partial: snapshot.partial,
      updates: [
        for (final line in snapshot.lines) ((jsonDecode(line) as Map)['params'] as Map).cast<Object?, Object?>(),
      ],
    );
  }

  @override
  void save(String key, TranscriptSnapshot snapshot, {bool now = false}) {
    saves.add((key, now));
    stored[key] = snapshot;
  }

  @override
  Future<void> delete(String key) async {
    deleted.add(key);
    stored.remove(key);
  }

  @override
  Future<void> deleteMachine(String machineId) async {
    machinesDeleted.add(machineId);
    stored.removeWhere((key, _) => key.startsWith('$machineId/'));
  }

  @override
  Future<void> retain(String machineId, Set<String> keeperIds) async {
    retained.add((machineId, keeperIds));
    stored.removeWhere((key, _) => key.startsWith('$machineId/') && !keeperIds.contains(key.substring(machineId.length + 1)));
  }
}
