import 'dart:convert';

/// What an omp session log says the session is called, and what the person
/// said last: the two things the board can name an agent by.
///
/// Read from two slices of the file, not the whole of it (a log runs to
/// megabytes): the head, where omp keeps its title record (a fixed-width first
/// line it rewrites in place; older logs put the title in the `session` entry),
/// and the tail, for a later `title_change` and the last message of the person.
/// Records that are not understood are skipped: the log is omp's own and its
/// shape is not ours to rely on (`omp_log_mapper.dart` reads the same entries).
typedef OmpSessionName = ({String? title, String? lastPrompt});

/// The longest prompt kept, in characters. The board cuts it again to fit.
const ompPromptChars = 60;

/// [head] is the first bytes of the log decoded as text and [tail] the last
/// ones. A [tail] that starts in the middle of the file ([tailStartsMidLine])
/// has its first line dropped: it is a fragment.
OmpSessionName parseOmpSessionName({
  required String head,
  required String tail,
  bool tailStartsMidLine = false,
}) {
  String? title;
  String? prompt;

  void scan(String text, {required bool dropFirst, required bool readPrompts}) {
    final lines = const LineSplitter().convert(text);
    for (var i = dropFirst ? 1 : 0; i < lines.length; i++) {
      final Object? entry;
      try {
        entry = jsonDecode(lines[i]);
      } on FormatException {
        continue; // a line cut by the slice, or not JSON
      }
      if (entry is! Map<String, dynamic>) continue;
      switch (entry['type']) {
        case 'session' || 'title' || 'title_change':
          final t = entry['title'];
          if (t is String && t.trim().isNotEmpty) title = t.trim();
        case 'message' when readPrompts:
          final p = _promptOf(entry['message']);
          if (p != null) prompt = p;
      }
    }
  }

  scan(head, dropFirst: false, readPrompts: false);
  scan(tail, dropFirst: tailStartsMidLine, readPrompts: true);
  return (title: title, lastPrompt: prompt);
}

/// The first line of what the person typed, or null for a message that is not
/// theirs, has no text, or is a slash command or a system note (those say
/// nothing about the work).
String? _promptOf(Object? message) {
  if (message is! Map<String, dynamic> || message['role'] != 'user') return null;
  final content = message['content'];
  String? text;
  if (content is String) {
    text = content;
  } else if (content is List) {
    for (final block in content) {
      if (block is Map<String, dynamic> && block['type'] == 'text' && block['text'] is String) {
        text = block['text'] as String;
        break;
      }
    }
  }
  if (text == null) return null;
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (line.isEmpty) continue;
    if (line.startsWith('/') || line.startsWith('<')) return null;
    final runes = line.runes.toList();
    return runes.length <= ompPromptChars
        ? line
        : '${String.fromCharCodes(runes.take(ompPromptChars - 1)).trimRight()}\u2026';
  }
  return null;
}
