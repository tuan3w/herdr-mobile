/// What a tool call of omp (over ACP) says about background jobs. omp's ACP
/// mode has no task update: a job exists in the result of the `bash` / `eval`
/// call that started it (`rawOutput.details.async`, `Backgrounded as job
/// bg_6` in the text) and ends in the result of a call that looks at it
/// (`wait`, `jobs`, `write proc://<id>/kill`: `details.jobs[]`,
/// `details.proc.cancelled[]`). When a job ends on its own, ACP says nothing
/// (the result is held for the next prompt).
library;

import '../acp_models.dart';
import 'background_work.dart';

sealed class OmpJobFact {
  const OmpJobFact(this.jobId);

  final String jobId;
}

/// The call started a job (or says it still runs).
class OmpJobStarted extends OmpJobFact {
  const OmpJobStarted(super.jobId, {required this.kind, required this.title, this.detail, this.deadline});

  final BackgroundKind kind;
  final String title;
  final String? detail;

  /// `details.timeoutSeconds`; null when the job has no limit or none is known.
  final Duration? deadline;
}

/// The call says the job is over.
class OmpJobEnded extends OmpJobFact {
  const OmpJobEnded(super.jobId, this.status);

  final BackgroundStatus status;
}

/// The job facts [call] carries now; empty for nearly every call. Reads the
/// call as it stands, so the same call gives the same facts again.
List<OmpJobFact> ompJobFacts(ToolCall call) {
  final out = _map(call.rawOutput);
  if (out == null) return const [];
  final details = _map(out['details']);
  final facts = <OmpJobFact>[];

  final async = _map(details?['async']);
  if (async != null) {
    final id = _string(async['jobId']);
    final type = _string(async['type']);
    if (id != null && (type == 'bash' || type == 'eval')) {
      switch (_string(async['state'])) {
        case 'running':
          facts.add(_started(id, type!, call, details!));
        case 'completed':
          facts.add(OmpJobEnded(id, BackgroundStatus.finished));
        case 'failed':
          facts.add(OmpJobEnded(id, BackgroundStatus.failed));
      }
    }
  } else if (call.kind == ToolKind.execute) {
    // `details` lost on the way: the text still says it, at the end.
    final id = _backgroundedId(out);
    if (id != null) facts.add(_started(id, call.rawInput is Map && (call.rawInput as Map).containsKey('code') ? 'eval' : 'bash', call, const {}));
  }

  for (final job in _list(details?['jobs'])) {
    final m = _map(job);
    final id = _string(m?['id']) ?? _string(m?['jobId']);
    final status = _ended(_string(m?['status']));
    if (id != null && status != null) facts.add(OmpJobEnded(id, status));
  }
  final cancelled = _map(details?['proc'])?['cancelled'];
  for (final job in _list(cancelled)) {
    final m = _map(job);
    final id = _string(m?['id']) ?? _string(m?['jobId']);
    if (id != null) facts.add(OmpJobEnded(id, _ended(_string(m?['status'])) ?? BackgroundStatus.stopped));
  }
  return facts;
}

OmpJobStarted _started(String id, String type, ToolCall call, Map<String, Object?> details) {
  final input = _map(call.rawInput);
  final command = type == 'eval'
      ? (_string(input?['title']) ?? _string(input?['code']))
      : _string(input?['command']);
  final seconds = details['timeoutDisabled'] == true ? null : details['timeoutSeconds'];
  return OmpJobStarted(
    id,
    kind: type == 'eval' ? BackgroundKind.eval : BackgroundKind.shell,
    title: command ?? (call.title.isEmpty ? id : call.title),
    detail: _string(input?['cwd']),
    deadline: seconds is num && seconds > 0 ? Duration(seconds: seconds.round()) : null,
  );
}

BackgroundStatus? _ended(String? status) => switch (status) {
  'completed' => BackgroundStatus.finished,
  'failed' => BackgroundStatus.failed,
  'cancelled' => BackgroundStatus.stopped,
  _ => null,
};

final _backgrounded = RegExp(r'Backgrounded as job ([A-Za-z0-9_.:-]{1,64})');

/// The job id in the closing notice of a backgrounded call's text.
String? _backgroundedId(Map<String, Object?> out) {
  for (final block in _list(out['content'])) {
    final text = _string(_map(block)?['text']);
    if (text == null) continue;
    // The notice is the last paragraph; a long output is not scanned whole.
    final tail = text.length > 600 ? text.substring(text.length - 600) : text;
    final m = _backgrounded.firstMatch(tail);
    if (m != null) return m.group(1);
  }
  return null;
}

Map<String, Object?>? _map(Object? v) => v is Map ? v.cast<String, Object?>() : null;
List<Object?> _list(Object? v) => v is List ? v : const [];
String? _string(Object? v) => v is String && v.isNotEmpty ? v : null;
