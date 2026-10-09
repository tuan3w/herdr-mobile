import '../acp/background/background_work.dart' show stopMessageForOmp;
import '../models/pane_preview.dart';
import '../repositories/agent_session.dart' show SubagentState;
import '../repositories/machine_connection.dart';
import '../repositories/observed_requests.dart' show askResultMatches;
import 'observed_contracts.dart';
import 'observed_kind.dart';
import 'omp_ask_driver.dart';
import 'omp_log_mapper.dart';
import 'session_log_locator.dart';

/// omp: it tells herdr the path of its log, its question tool and its menus are
/// driven by keys, its subagents write `<log minus .jsonl>/<name>.jsonl`.
const ompKind = ObservedKind(
  id: 'omp',
  label: 'omp',
  newMapper: OmpLogMapper.new,
  locator: OmpLocator(),
  ask: ObservedAsk(stepper: _ompStepper, looksLikeAsk: looksLikeAsk, resultMatches: askResultMatches),
  stopMessage: stopMessageForOmp,
  menuPrompt: ompMenuPrompt,
  subagents: OmpSubagentLogs(),
);

AskStepper _ompStepper(PendingAsk ask, List<AskAnswer> answers) => OmpAskDriver(ask, answers).next;

/// omp's tool approval or plan review as a prompt: each option with the keys
/// that choose it from where the cursor is.
PromptInfo? ompMenuPrompt(String screen) {
  final approval = parseOmpApproval(screen);
  final OmpMenuScreen? menu = approval ?? parseOmpPlanReview(screen);
  if (menu == null) return null;
  final replies = <QuickReply>[];
  for (final (i, o) in menu.options.indexed) {
    final keys = menu.keysFor(i);
    if (keys == null) return null;
    replies.add(QuickReply(label: o.label, keys: keys));
  }
  return PromptInfo(
    question: approval == null ? 'Plan mode - next step' : 'Allow tool: ${approval.tool}',
    subject: approval == null ? '' : _approvalSubject(approval.detail),
    replies: replies,
  );
}

/// The rows above an approval's options, without their `Command:`-style
/// labels when it names a command.
String _approvalSubject(List<String> detail) {
  for (final line in detail) {
    final m = RegExp(r'^\s*(?:Command|Path|File|Url|URL):\s*(.+)$').firstMatch(line);
    if (m != null) return m[1]!.trim();
  }
  return detail.map((l) => l.trim()).where((l) => l.isNotEmpty).join('\n');
}

/// omp's subagents: `<parent log minus .jsonl>/<name>.jsonl`, with a `.md` or
/// `.json` next to it once the subagent has finished.
class OmpSubagentLogs implements SubagentLogs {
  const OmpSubagentLogs();

  @override
  Future<String?> pathOf(MachineConnection machine, String parentLogPath, SubagentInfo info) async {
    final dir = artifactDir(parentLogPath);
    return dir == null ? null : '$dir/${info.name}.jsonl';
  }

  /// The folder next to the log that holds the subagents' files.
  static String? artifactDir(String parentLogPath) =>
      parentLogPath.endsWith('.jsonl') ? parentLogPath.substring(0, parentLogPath.length - '.jsonl'.length) : null;

  @override
  Future<Map<String, SubagentState>?> refine(
    MachineConnection machine,
    String parentLogPath,
    List<SubagentInfo> infos, {
    required Duration running,
  }) async {
    final dir = artifactDir(parentLogPath);
    if (dir == null) return null;
    final List<dynamic> entries;
    try {
      entries = await machine.api.files.list(dir);
    } on Object {
      return null;
    }
    final now = DateTime.now().toUtc();
    final names = <String, Map<String, DateTime?>>{};
    for (final e in entries) {
      final name = e.name as String;
      final dot = name.lastIndexOf('.');
      if (dot <= 0) continue;
      names.putIfAbsent(name.substring(0, dot), () => {})[name.substring(dot + 1)] = e.modified as DateTime?;
    }
    final refined = <String, SubagentState>{};
    for (final s in infos) {
      final files = names[s.name];
      if (files == null) continue;
      if (files.containsKey('md') || files.containsKey('json')) {
        refined[s.name] = SubagentState.finished;
      } else if (files.containsKey('jsonl')) {
        final at = files['jsonl'];
        refined[s.name] = at != null && now.difference(at.toUtc()) <= running
            ? SubagentState.running
            : SubagentState.finished;
      }
    }
    return refined;
  }
}
