/// The turn model, data half: turns, what they
/// changed, one-line tool summaries, groups, the fold line and the status
/// line. Pure Dart; the UI lays the parts out.
library;

export 'activity.dart';
export 'changes.dart' show ChangedFile, changedFilesOf, pathOfCall;
export 'line_diff.dart' show LineStats, lineStats;
export 'plain_text.dart' show basenameOf, dirHintOf, firstSentence, stripTerminalEscapes;
export 'tool_summary.dart';
export 'turn.dart';
export 'work_summary.dart';
