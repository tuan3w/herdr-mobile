import '../session_state.dart';
import 'subagent_run.dart';

/// A subagent transcript read from the agent's own log, and what is known
/// about the read.
class LoggedTranscript {
  const LoggedTranscript(this.transcript, this.info, {this.droppedItems = 0});

  final AgentSessionState transcript;
  final SubagentLogInfo info;

  /// Items cut from the start to stay under [SubagentRun.maxItems].
  final int droppedItems;
}

/// Lays transcripts read from logs over the runs the reducer made.
///
/// The reducer's state belongs to the ACP client and is replaced wholesale
/// whenever the client publishes (a reload replays the session), so a
/// transcript that comes from somewhere else cannot live inside it. The session
/// keeps them here and reads its runs through [run] / [runs].
///
/// Identity is kept: the same base run (or list) and the same attached
/// transcript give the same object back, so the widgets that compare runs by
/// identity rebuild only when something changed.
class SubagentOverlay {
  final _attached = <String, LoggedTranscript>{};
  final _memo = Expando<_Laid>('SubagentOverlay');
  List<SubagentRun>? _fromList;
  List<SubagentRun>? _toList;
  int _version = 0;
  int _listVersion = -1;

  /// Nothing attached.
  bool get isEmpty => _attached.isEmpty;

  LoggedTranscript? of(String runId) => _attached[runId];

  /// Attaches [logged] to run [runId], replacing an earlier one.
  void attach(String runId, LoggedTranscript logged) {
    _attached[runId] = logged;
    _version++;
  }

  /// Forgets the transcript of [runId].
  void detach(String runId) {
    if (_attached.remove(runId) != null) _version++;
  }

  /// [base] with its attached transcript, or [base] itself when none is
  /// attached or the run has a transcript of its own (Claude's).
  SubagentRun? run(SubagentRun? base) {
    if (base == null || base.transcript != null) return base;
    final logged = _attached[base.id];
    if (logged == null) return base;
    final memo = _memo[base];
    if (memo != null && identical(memo.logged, logged)) return memo.run;
    final laid = base.copyWith(
      transcript: logged.transcript,
      log: logged.info,
      droppedItems: logged.droppedItems,
    );
    _memo[base] = _Laid(logged, laid);
    return laid;
  }

  /// [base] with the attached transcripts laid over its runs. The same list
  /// while neither [base] nor the attachments changed.
  List<SubagentRun> runs(List<SubagentRun> base) {
    if (_attached.isEmpty) return base;
    if (identical(base, _fromList) && _listVersion == _version) return _toList!;
    var changed = false;
    final next = <SubagentRun>[];
    for (final r in base) {
      final laid = run(r)!;
      if (!identical(laid, r)) changed = true;
      next.add(laid);
    }
    _fromList = base;
    _listVersion = _version;
    return _toList = changed ? next : base;
  }
}

class _Laid {
  const _Laid(this.logged, this.run);

  final LoggedTranscript logged;
  final SubagentRun run;
}
