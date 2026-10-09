import 'package:flutter/foundation.dart';

import '../../../data/acp/acp_models.dart';
import '../../../data/acp/auth_needed.dart';
import '../../../data/acp/past_session.dart' show ResumeTarget;
import '../../../data/acp/prompt_queue.dart';
import '../../../data/acp/background/background_work.dart';
import '../../../data/acp/session_state.dart';
import '../../../data/acp/subagents/subagent_run.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/machine_connection.dart';

/// One subagent's transcript as a read-only [AgentSessionView], so the
/// transcript widgets that draw a session draw it without being forked.
///
/// It reads the run from [parent] on every access (the run object changes
/// when the subagent does) and notifies when the parent does, which the
/// parent already batches to one notification per frame, text included. The
/// child's [state] is the run's own transcript, marked as a turn in progress
/// while the run is active, so its work log is open and the status line
/// names its current step; a finished run folds like a finished turn.
///
/// Nothing can be sent: [sendBlocked] says so, and every write is a no-op.
/// A request the subagent asks lives in the parent's state (the person
/// answers it in the dock of the parent), so this view has none.
class SubagentRunSession extends ChangeNotifier implements AgentSessionView {
  SubagentRunSession(this.parent, this.runId) {
    parent.addListener(notifyListeners);
  }

  final AgentSessionView parent;
  final String runId;

  SubagentRun? get run => parent.subagentRun(runId);

  @override
  void dispose() {
    parent.removeListener(notifyListeners);
    super.dispose();
  }

  static const _empty = AgentSessionState('subagent');
  AgentSessionState? _from;
  bool _active = false;
  AgentSessionState _state = _empty;

  @override
  AgentSessionState get state {
    final r = run;
    final base = r?.transcript ?? _empty;
    final active = r?.isActive ?? false;
    if (!identical(base, _from) || active != _active) {
      _from = base;
      _active = active;
      _state = active ? base.withTurnStarted() : base;
    }
    return _state;
  }

  @override
  String get key => '${parent.key}/$runId';
  @override
  MachineConnection get machine => parent.machine;
  @override
  String get agent => parent.agent;
  @override
  String get agentLabel => parent.agentLabel;
  @override
  String get cwd => parent.cwd;
  @override
  String get title => run?.title ?? 'Subagent';
  @override
  AgentLink get link => parent.link;
  @override
  DateTime? get cachedAsOf => parent.cachedAsOf;

  @override
  EarlierHistory get earlier => EarlierHistory.none;

  @override
  void loadEarlier() {}
  @override
  String? get error => null;
  @override
  AgentPhase get phase => state.phase;
  @override
  DateTime? get phaseSince => run?.startedAt;
  @override
  DateTime? get lastActivity => run?.startedAt;
  @override
  DateTime? get turnStartedAt => (run?.isActive ?? false) ? run?.startedAt : null;
  @override
  Listenable? liveTextOf(String messageKey) => run?.liveTextOf(messageKey);

  @override
  bool get unseenDone => false;
  @override
  void markSeen() {}
  @override
  bool unmarkSeen() => false;

  @override
  Future<bool> send(String text) async => false;
  @override
  Future<bool> sendBlocks(List<ContentBlock> blocks, {bool queue = false}) async => false;
  @override
  SendDelivery get delivery => SendDelivery.queued;
  @override
  bool get canSteer => false;
  @override
  bool get acceptsImages => false;
  @override
  bool get acceptsEmbeddedContext => false;
  @override
  List<QueuedMessage> get queued => const [];
  @override
  void editQueued(String id, String text) {}
  @override
  void removeQueued(String id) {}
  @override
  void resumeQueue() {}
  @override
  AuthNeeded? get authNeeded => null;
  @override
  void cancel() {}
  @override
  Future<void> setMode(String modeId) async {}
  @override
  Future<void> setConfigOption(String configId, Object value) async {}
  @override
  void answerPermission(Object requestId, PermissionOutcome outcome) => parent.answerPermission(requestId, outcome);
  @override
  void answerQuestion(Object requestId, ElicitationResponse response) => parent.answerQuestion(requestId, response);
  @override
  Future<void> end() async {}
  @override
  bool get evicted => false;
  @override
  AnsweredElsewhere? get answeredElsewhere => null;
  @override
  ResumeTarget? get resumeTarget => null;
  @override
  Future<void> reattach() async {}
  @override
  void acquire() {}
  @override
  void release() {}
  @override
  bool get isObserved => false;
  @override
  String? get terminalPaneId => null;
  @override
  bool get needsTerminal => false;
  @override
  List<SubagentEntry> get subagents => const [];
  @override
  void watchSubagents(bool on) {}
  @override
  String? get relayNote => null;
  @override
  List<String>? get liveOutput => null;
  @override
  String? get sendBlocked => 'A subagent’s conversation is read-only.';

  // The runs are the session's: a subagent that starts subagents shows their
  // cards in its own transcript.
  @override
  List<SubagentRun> get subagentRuns => parent.subagentRuns;
  @override
  SubagentSummary get subagentSummary => parent.subagentSummary;
  @override
  SubagentRun? subagentRun(String id) => parent.subagentRun(id);
  @override
  List<SubagentRun> subagentsOfToolCall(String toolCallId) => parent.subagentsOfToolCall(toolCallId);
  @override
  void watchSubagentLog(String runId, bool on) => parent.watchSubagentLog(runId, on);
  @override
  SubagentLogStatus subagentLogStatus(String runId) => parent.subagentLogStatus(runId);
  @override
  void retrySubagentLog(String runId) => parent.retrySubagentLog(runId);

  // A subagent's own screen lists no background work.
  @override
  BackgroundWork get backgroundWork => BackgroundWork.empty;
  @override
  bool get waitingOnBackground => false;
  @override
  Future<BackgroundStopResult> stopBackground(String id) async => const BackgroundNotStoppable();
  @override
  Future<BackgroundStopResult> stopAllBackground() async => const BackgroundNotStoppable();
}
