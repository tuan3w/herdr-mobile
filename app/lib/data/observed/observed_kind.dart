import '../models/pane_preview.dart' show PromptInfo;
import '../repositories/agent_session.dart' show SubagentState;
import '../repositories/machine_connection.dart';
import 'observed_contracts.dart';
import 'omp_ask_driver.dart' show AskStep;
import 'session_log_locator.dart';

/// Reads the pane's screen and says what to send next to answer a dialog.
typedef AskStepper = AskStep Function(String screen);

/// How an agent's question tool is answered from the phone: its dialog is
/// driven by keys, one screen at a time, and the log has the last word.
class ObservedAsk {
  const ObservedAsk({required this.stepper, required this.looksLikeAsk, required this.resultMatches});

  /// The planner for one answer (one per answer: it remembers what scrolled out
  /// of view).
  final AskStepper Function(PendingAsk ask, List<AskAnswer> answers) stepper;

  /// Whether the question dialog (or its custom-answer editor) is on [screen].
  final bool Function(String screen) looksLikeAsk;

  /// Whether the tool result the agent recorded ([output]) says what the person
  /// answered.
  final bool Function(String? output, PendingAsk ask, List<AskAnswer> answers) resultMatches;
}

/// Where the transcripts of an agent's subagents are and whether they still
/// write.
abstract interface class SubagentLogs {
  /// The transcript file of [info], or null when it is not known yet.
  Future<String?> pathOf(MachineConnection machine, String parentLogPath, SubagentInfo info);

  /// Running or finished per subagent name, from the files' state; null when the
  /// host could not be read. A file modified within [running] is running.
  Future<Map<String, SubagentState>?> refine(
    MachineConnection machine,
    String parentLogPath,
    List<SubagentInfo> infos, {
    required Duration running,
  });
}

/// One kind of agent whose panes open as a chat: how to find its log, how to
/// read it and what it can do from the phone. Registered by herdr's agent label.
class ObservedKind {
  const ObservedKind({
    required this.id,
    required this.label,
    required this.newMapper,
    required this.locator,
    this.ask,
    this.stopMessage,
    this.menuPrompt,
    this.subagents,
    this.newSubagentMapper,
    this.wakesOnBackground = true,
    this.integration,
  });

  /// herdr's agent label: `omp`, `claude` or `codex`.
  final String id;

  /// What the person reads: `omp`, `Claude Code`, `Codex`.
  final String label;

  final SessionLogMapper Function() newMapper;
  final SessionLogLocator locator;

  /// Null: the agent's questions are answered in the terminal.
  final ObservedAsk? ask;

  /// The message that asks the agent to stop background jobs [ids]; null for
  /// "nothing to ask" or an id that is not a plain token. A kind without it has
  /// no stop action.
  final String? Function(Iterable<String> ids)? stopMessage;

  /// The agent's own menus (not found by the generic prompt detector) on a
  /// screen, as a prompt. omp only.
  final PromptInfo? Function(String screen)? menuPrompt;

  final SubagentLogs? subagents;

  /// The mapper of a subagent's transcript when it is not the main log's
  /// ([newMapper]): Claude's transcript has `isSidechain` lines only.
  final SessionLogMapper Function()? newSubagentMapper;

  /// A background job that finishes starts a turn of the agent by itself (omp,
  /// Claude Code). Codex does not: it sees a finished command when it next looks.
  final bool wakesOnBackground;

  /// The herdr integration target that makes the agent report its session
  /// (`herdr integration install <target>`).
  final String? integration;
}
