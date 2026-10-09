import '../acp/background/background_work.dart' show stopMessageForClaude;
import 'claude_ask_driver.dart';
import 'claude_locator.dart';
import 'claude_log_mapper.dart';
import 'claude_subagent_logs.dart';
import 'observed_contracts.dart';
import 'observed_kind.dart';
import 'omp_ask_driver.dart' show AskStep;

/// Claude Code: herdr's hook reports the session once its integration is
/// installed; without it the running process names it
/// (`~/.claude/sessions/<pid>.json`). Its approvals are read from the screen by
/// the generic prompt detector, its question tool is answered by keys
/// ([ClaudeAskDriver]) and checked against the tool result in the log.
final claudeKind = ObservedKind(
  id: 'claude',
  label: 'Claude Code',
  newMapper: ClaudeLogMapper.new,
  newSubagentMapper: _newSidechainMapper,
  locator: ClaudeLocator(),
  ask: ObservedAsk(stepper: _stepper, looksLikeAsk: looksLikeClaudeAsk, resultMatches: claudeAskResultMatches),
  stopMessage: stopMessageForClaude,
  subagents: ClaudeSubagentLogs(),
  integration: 'claude',
);

AskStep Function(String) _stepper(PendingAsk ask, List<AskAnswer> answers) => ClaudeAskDriver(ask, answers).next;

ClaudeLogMapper _newSidechainMapper() => ClaudeLogMapper(sidechain: true);
