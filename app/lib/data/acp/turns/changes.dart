import '../acp_models.dart';
import 'line_diff.dart';

/// One file a turn changed, from the `ToolDiff`s of its tool calls.
class ChangedFile {
  const ChangedFile({
    required this.path,
    required this.added,
    required this.removed,
    this.isNew = false,
    this.isDelete = false,
    this.diffs = const [],
  });

  /// As the agent gave it (usually absolute).
  final String path;

  /// Lines added and removed, summed over every diff of [path]; a diff that
  /// starts from what the one before it ended with counts as one change (the
  /// file's net change), not two.
  final int added;
  final int removed;

  /// The first diff of the path had no old text: the turn created the file.
  final bool isNew;

  /// The file was deleted (a call of kind `delete` named it, and no later
  /// diff wrote it again).
  final bool isDelete;

  /// The diffs in the order they happened, for a viewer.
  final List<ToolDiff> diffs;

  @override
  String toString() => 'ChangedFile($path +$added -$removed${isNew ? ' new' : ''}${isDelete ? ' delete' : ''})';
}

final _stats = Expando<LineStats>('ToolDiff stats');

/// The line stats of [diff], computed once per diff object.
LineStats statsOf(ToolDiff diff) => _stats[diff] ??= lineStats(diff.oldText, diff.newText);

/// The files [calls] changed, in the order they were first touched, one entry
/// per path: several diffs of one path (an agent that edits a file twice, and
/// codex, which sends one diff per hunk under the title "Editing files") are
/// grouped. A call of kind `delete` marks the path it names deleted.
///
/// Callers pass the calls that count: the turn model gives it the completed
/// ones (an edit waiting for approval has changed nothing yet).
List<ChangedFile> changedFilesOf(Iterable<ToolCall> calls) {
  final order = <String>[];
  final byPath = <String, _Acc>{};
  _Acc accFor(String path) {
    final existing = byPath[path];
    if (existing != null) return existing;
    order.add(path);
    return byPath[path] = _Acc();
  }

  for (final call in calls) {
    var sawDiff = false;
    for (final c in call.content) {
      if (c is! ToolDiff || c.path.isEmpty) continue;
      sawDiff = true;
      accFor(c.path).add(c);
    }
    if (call.kind == ToolKind.delete && !sawDiff) {
      final path = pathOfCall(call);
      if (path != null) accFor(path).deleted = true;
    }
  }
  return [
    for (final path in order)
      if (byPath[path]! case final a) a.build(path),
  ];
}

/// The file a call is about: its first `locations` entry, else the first
/// of `file_path`, `filePath`, `path`, `file` in `rawInput`; null when none.
String? pathOfCall(ToolCall call) {
  for (final l in call.locations) {
    if (l.path.isNotEmpty) return l.path;
  }
  final input = call.rawInput;
  if (input is Map) {
    for (final key in const ['file_path', 'filePath', 'path', 'file']) {
      final v = input[key];
      if (v is String && v.trim().isNotEmpty) return v;
    }
  }
  return null;
}

class _Acc {
  final diffs = <ToolDiff>[];
  var added = 0;
  var removed = 0;
  var deleted = false;
  bool? isNew;

  // The chain being extended: its first old text and last new text.
  String? _chainOld;
  String? _chainNew;
  ToolDiff? _single;
  var _open = false;

  void add(ToolDiff d) {
    diffs.add(d);
    isNew ??= d.oldText == null;
    deleted = false;
    if (_open && d.oldText != null && d.oldText == _chainNew) {
      _single = null;
      _chainNew = d.newText;
      return;
    }
    _flush();
    _open = true;
    _single = d;
    _chainOld = d.oldText;
    _chainNew = d.newText;
  }

  void _flush() {
    if (!_open) return;
    final s = _single != null ? statsOf(_single!) : lineStats(_chainOld, _chainNew!);
    added += s.added;
    removed += s.removed;
    _open = false;
  }

  ChangedFile build(String path) {
    _flush();
    return ChangedFile(
      path: path,
      added: added,
      removed: removed,
      isNew: isNew ?? false,
      isDelete: deleted,
      diffs: List.unmodifiable(diffs),
    );
  }
}
