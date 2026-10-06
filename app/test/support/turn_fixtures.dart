import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';

/// The start of every fixture turn.
final t0 = DateTime(2026, 10, 5, 12);

DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

TranscriptMessage userAt(String key, String text, int seconds) =>
    TranscriptMessage(key: key, role: MessageRole.user, blocks: [TextBlock(text)], at: at(seconds), endedAt: at(seconds));

TranscriptMessage agentAt(String key, String text, int seconds, [int? end]) => TranscriptMessage(
  key: key,
  role: MessageRole.agent,
  messageId: key,
  blocks: [TextBlock(text)],
  at: at(seconds),
  endedAt: at(end ?? seconds + 1),
);

TranscriptMessage thoughtAt(String key, String text, int seconds) => TranscriptMessage(
  key: key,
  role: MessageRole.thought,
  messageId: key,
  blocks: [TextBlock(text)],
  at: at(seconds),
  endedAt: at(seconds + 2),
);

TranscriptTool toolAt(
  String id, {
  String title = '',
  ToolKind kind = ToolKind.other,
  ToolStatus status = ToolStatus.completed,
  Object? rawInput,
  Object? rawOutput,
  List<ToolContent> content = const [],
  List<ToolLocation> locations = const [],
  ToolOutput? output,
  Json? meta,
  required int start,
  int? end,
}) => TranscriptTool(
  ToolCall(
    toolCallId: id,
    title: title,
    kind: kind,
    status: status,
    rawInput: rawInput,
    rawOutput: rawOutput,
    content: content,
    locations: locations,
    output: output,
    meta: meta,
  ),
  at: at(start),
  finishedAt: status.isFinished ? at(end ?? start + 2) : null,
);

TranscriptTool readAt(String id, String path, int start) => toolAt(
  id,
  title: 'Read $path',
  kind: ToolKind.read,
  rawInput: {'file_path': path},
  locations: [ToolLocation(path: path)],
  start: start,
);

TranscriptTool searchAt(String id, String pattern, int start, {int? hits}) => toolAt(
  id,
  title: 'Grep $pattern',
  kind: ToolKind.search,
  rawInput: {'pattern': pattern},
  rawOutput: hits == null ? null : {'matches': List.filled(hits, 'x')},
  start: start,
);

TranscriptTool editAt(String id, String path, int start, {String? before, String after = 'new line\nsecond\n'}) =>
    toolAt(
      id,
      title: 'Edit $path',
      kind: ToolKind.edit,
      content: [ToolDiff(path: path, oldText: before ?? 'old line\nsecond\n', newText: after)],
      locations: [ToolLocation(path: path)],
      start: start,
    );

TranscriptTool runAt(
  String id,
  String command,
  int start, {
  int? end,
  int? exitCode,
  String output = '',
  ToolStatus? status,
}) => toolAt(
  id,
  title: command,
  kind: ToolKind.execute,
  status: status ?? (exitCode != null && exitCode != 0 ? ToolStatus.failed : ToolStatus.completed),
  rawInput: {'command': command},
  output: ToolOutput(text: output, exited: exitCode != null, exitCode: exitCode),
  start: start,
  end: end,
);

/// A finished turn of the kind the plan describes: a prompt, a thought, the
/// agent saying what it will do, reads and a search, two edits, a passing and
/// a failing command, then the answer. 42 seconds.
List<TranscriptItem> richTurn({String prefix = ''}) => [
  userAt('${prefix}u', 'Fix the Hà Nội locale bug in the parser and add a regression test.', 0),
  thoughtAt('${prefix}th', 'The parser lowercases before it normalizes. That drops the tone marks.', 1),
  agentAt('${prefix}n1', 'I will read the parser and its tests first.', 3),
  readAt('${prefix}r1', '/home/dev/payments-api/lib/locale/parse.dart', 4),
  readAt('${prefix}r2', '/home/dev/payments-api/lib/locale/normalize.dart', 5),
  readAt('${prefix}r3', '/home/dev/payments-api/test/locale_test.dart', 6),
  searchAt('${prefix}s1', 'toLowerCase', 7, hits: 4),
  searchAt('${prefix}s2', 'normalize\\(', 8, hits: 9),
  editAt('${prefix}e1', '/home/dev/payments-api/lib/locale/parse.dart', 12, before: 'a\nb\nc\n', after: 'a\nB\nc\nd\n'),
  editAt('${prefix}e2', '/home/dev/payments-api/test/locale_test.dart', 16, before: 'x\n', after: 'x\ny\nz\nw\n'),
  runAt('${prefix}c1', 'dart format lib test', 20, exitCode: 0),
  runAt(
    '${prefix}c2',
    'flutter test test/locale_test.dart',
    24,
    end: 40,
    exitCode: 1,
    output: '00:02 +11 -1: locale handles Hà Nội\nExpected: Hà Nội\n  Actual: ha noi\n00:03 +11 -1: Some tests failed.\n',
  ),
  agentAt(
    '${prefix}a',
    'The parser lowercased **before** normalizing, so `Hà Nội` lost its tone marks. I moved the call below `normalize()` '
        'and added a regression test.\n\nOne test still fails: the fixture expects the old output.',
    41,
    42,
  ),
];
