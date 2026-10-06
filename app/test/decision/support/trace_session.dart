import 'dart:convert';
import 'dart:io';

import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/repositories/last_seen.dart';

/// A permission request in a recorded trace, with the session as it stood
/// when the agent asked.
typedef TracePermission = ({PermissionRequest request, AgentSessionState before});

/// A recorded trace (`test/fixtures/traces/<agent>/<scenario>.jsonl`) folded
/// the way the app folds a live session.
class TraceRun {
  TraceRun(this.setup, this.finalState, this.permissions, this.questions);

  /// The session as `session/new` answered, before any prompt.
  final AgentSessionState setup;

  /// The session after the last line.
  final AgentSessionState finalState;
  final List<TracePermission> permissions;
  final List<ElicitationRequest> questions;
}

const traceRoot = 'test/fixtures/traces';

/// Every trace file as `agent/scenario` (relative, without extension).
List<String> allTraces() {
  final root = Directory(traceRoot);
  final out = <String>[];
  for (final f in root.listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.jsonl')) continue;
    final parts = f.uri.pathSegments;
    out.add('${parts[parts.length - 2]}/${parts.last.replaceAll('.jsonl', '')}');
  }
  out.sort();
  return out;
}

TraceRun replayTrace(String name) {
  var state = const AgentSessionState('s');
  var setup = state;
  var sawSetup = false;
  final permissions = <TracePermission>[];
  final questions = <ElicitationRequest>[];
  Object? promptId;
  for (final row in const LineSplitter().convert(File('$traceRoot/$name.jsonl').readAsStringSync())) {
    if (row.trim().isEmpty) continue;
    final j = jsonDecode(row) as Map<String, dynamic>;
    final msg = j['msg'] as Map<String, dynamic>;
    final received = j['dir'] == 'recv';
    final method = msg['method'];
    final result = msg['result'];
    if (!received && method == 'session/prompt') {
      promptId = msg['id'];
      final prompt = (msg['params'] as Map)['prompt'] as List;
      state = state
          .withUserMessage([TextBlock(prompt.map((b) => (b as Map)['text'] ?? '').join())])
          .withTurnStarted();
    } else if (received && method == 'session/update') {
      state = state.apply(SessionUpdate.parse((msg['params'] as Map)['update']));
    } else if (received && method == 'session/request_permission') {
      final request = PermissionRequest.parse(msg['params']);
      permissions.add((request: request, before: state));
      state = state.withPending(PendingPermission(msg['id'] as Object, request));
    } else if (received && method == 'elicitation/create') {
      final request = ElicitationRequest.parse(msg['params']);
      questions.add(request);
      state = state.withPending(PendingQuestion(msg['id'] as Object, request));
    } else if (!received && msg['result'] != null && msg['id'] != null && state.pending.any((p) => p.id == msg['id'])) {
      state = state.withoutPending(msg['id'] as Object);
    } else if (received && result is Map && !sawSetup && (result.containsKey('configOptions') || result.containsKey('modes'))) {
      sawSetup = true;
      state = state.withSetup(AcpSessionSetup.parse(result));
      setup = state;
    } else if (received && promptId != null && msg['id'] == promptId && result is Map) {
      state = state.withTurnEnded(StopReason.parse(result['stopReason'] as String?));
      promptId = null;
    }
  }
  return TraceRun(setup, state, permissions, questions);
}

/// Keeps the markers in memory, as a store that survives a "restart": give
/// the same instance to a second [LastSeen].
class MemoryLastSeenStore implements LastSeenStore {
  Map<String, SeenMarker>? saved;
  int writes = 0;

  /// While set, [write] throws (a phone that cannot write its preferences).
  bool failing = false;

  /// While set, [read] throws.
  bool unreadable = false;

  @override
  Future<Map<String, SeenMarker>?> read() async {
    if (unreadable) throw StateError('cannot read');
    return saved == null ? null : Map.of(saved!);
  }

  @override
  Future<void> write(Map<String, SeenMarker> markers) async {
    if (failing) throw StateError('disk full');
    writes++;
    saved = Map.of(markers);
  }
}
