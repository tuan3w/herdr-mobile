import '../acp/acp_models.dart';

/// Helpers every agent's log mapper shares: cutting text, the wire names of a
/// tool kind, whole-message upserts. They are the same for every agent so a
/// field looks the same on the phone whichever agent wrote it.

/// The longest text kept per field. The host already cuts a field to about
/// 16 KB; anything longer than this gets a visible marker here.
const maxLogFieldChars = 20000;

const _cutMark = '\n... [cut]';

/// A whole message (`MessageUpsert` replaces by id, so a line mapped twice
/// changes nothing).
MessageUpsert messageUpsert(MessageRole role, String id, String text) =>
    MessageUpsert(role, id, hasContent: true, content: [TextBlock(capText(text))]);

/// A tool call that ended without a result because the turn was interrupted.
SessionUpdate cancelledPatch(String id) =>
    ToolCallPatchUpdate(ToolCallPatch(id, {'toolCallId': id, 'status': 'cancelled'}));

/// The log entry's own time, by the host's clock; null when it has none.
DateTime? parseStamp(Json e) {
  final t = e['timestamp'];
  if (t is String) return DateTime.tryParse(t);
  // A corrupt number must not throw out of a mapper.
  if (t is int && t >= 0 && t < 253402300800000) return DateTime.fromMillisecondsSinceEpoch(t, isUtc: true);
  return null;
}

String fnv(String s) {
  var h = 0x811c9dc5;
  for (var i = 0; i < s.length; i++) {
    h ^= s.codeUnitAt(i);
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h.toRadixString(16);
}

String firstLine(String s) {
  final i = s.indexOf('\n');
  return i < 0 ? s : s.substring(0, i);
}

/// [s] cut to [max] characters with an ellipsis.
String cutText(String s, int max) {
  if (s.length <= max) return s;
  return '${s.substring(0, safeEnd(s, max - 1))}…';
}

/// [text] of a message that carried [images] pictures: one `[image]` line for
/// each, unless the agent's own text already marks them (`[Image #1]`). A
/// message with a picture never shows empty and never loses the picture
/// silently.
String withImageMarkers(String text, int images) {
  if (images <= 0 || text.contains('[Image #')) return text;
  final markers = List.filled(images, '[image]').join('\n');
  return text.isEmpty ? markers : '$text\n$markers';
}

/// [s] cut at [maxLogFieldChars] with a visible marker; whole when shorter.
String capText(String s) {
  if (s.length <= maxLogFieldChars) return s;
  return '${s.substring(0, safeEnd(s, maxLogFieldChars))}$_cutMark';
}

/// [end], or one less when it would split a surrogate pair.
int safeEnd(String s, int end) {
  if (end > 0 && end < s.length) {
    final u = s.codeUnitAt(end - 1);
    if (u >= 0xD800 && u <= 0xDBFF) return end - 1;
  }
  return end;
}

/// A copy of [v] whose strings are capped.
Object? capJson(Object? v) {
  if (v is String) return capText(v);
  if (v is List) return [for (final e in v) capJson(e)];
  if (v is Map) return {for (final e in v.entries) e.key.toString(): capJson(e.value)};
  return v;
}

/// The wire name of a tool kind (`ToolCallUpdate.kind`).
String kindWire(ToolKind k) => switch (k) {
  ToolKind.read => 'read',
  ToolKind.edit => 'edit',
  ToolKind.delete => 'delete',
  ToolKind.move => 'move',
  ToolKind.search => 'search',
  ToolKind.execute => 'execute',
  ToolKind.think => 'think',
  ToolKind.fetch => 'fetch',
  ToolKind.switchMode => 'switch_mode',
  ToolKind.other => 'other',
};

/// A `ToolDiff` from a unified diff of one file (Codex records its file
/// changes that way): the old text is the context and `-` lines, the new text
/// the context and `+` lines; hunk and file headers are dropped (the headers of
/// a file come before its first hunk, never inside one).
ToolDiff diffFromUnified(String path, String unified) {
  final oldLines = <String>[];
  final newLines = <String>[];
  var inHunk = false;
  for (final line in unified.split('\n')) {
    if (line.startsWith('@@')) {
      inHunk = true;
      continue;
    }
    // File headers come before the first hunk only: inside one, `---` is a
    // removed line that starts with `--` and `+++` an added `++i`.
    if (!inHunk && (line.startsWith('+++') || line.startsWith('---'))) continue;
    if (line.startsWith(r'\')) continue;
    if (line.startsWith('+')) {
      newLines.add(line.substring(1));
    } else if (line.startsWith('-')) {
      oldLines.add(line.substring(1));
    } else if (line.startsWith(' ')) {
      oldLines.add(line.substring(1));
      newLines.add(line.substring(1));
    }
  }
  return ToolDiff(path: path, oldText: oldLines.join('\n'), newText: newLines.join('\n'));
}
