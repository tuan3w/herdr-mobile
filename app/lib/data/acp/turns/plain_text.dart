import 'package:characters/characters.dart';

import '../../decision/plain_text.dart' show stripAnsi;

/// Small text helpers for the turn model. Pure Dart. They produce plain
/// strings for a UI to lay out; making what a string hides visible (control
/// and direction characters) stays the UI's job (`visibleText`).

/// [raw] without colour and cursor sequences ([stripAnsi]), a line that was
/// rewritten with a carriage return (a progress bar) kept as its last version.
/// Same result as `terminalText` in `ui/features/agent_session/visible_text.dart`
/// before it makes hidden characters visible (a layer this file must not
/// import).
String stripTerminalEscapes(String raw) {
  var text = stripAnsi(raw);
  if (text.contains('\r')) {
    text = text.replaceAll('\r\n', '\n');
    if (text.contains('\r')) {
      text = text.split('\n').map((line) {
        var end = line.length;
        while (end > 0 && line.codeUnitAt(end - 1) == 0x0D) {
          end--;
        }
        final cr = end == 0 ? -1 : line.lastIndexOf('\r', end - 1);
        return cr < 0 ? line.substring(0, end) : line.substring(cr + 1, end);
      }).join('\n');
    }
  }
  return text;
}

/// [text] cut to at most [max] grapheme clusters, with an ellipsis when it was
/// cut. Never splits a surrogate pair or a letter and its combining marks
/// (Vietnamese in NFD).
String clip(String text, int max) {
  if (text.length <= max) return text;
  final chars = text.characters;
  if (chars.length <= max) return text;
  return '${chars.take(max - 1)}…';
}

/// The last component of [path] (either separator; trailing separators
/// ignored); [path] itself when it has none.
String basenameOf(String path) {
  var end = path.length;
  while (end > 0 && _isSeparator(path.codeUnitAt(end - 1))) {
    end--;
  }
  var start = end;
  while (start > 0 && !_isSeparator(path.codeUnitAt(start - 1))) {
    start--;
  }
  return end == start ? path : path.substring(start, end);
}

/// The directory of [path], shortened to its last two components
/// (`lib/locale`), as a hint next to a file name; null for a bare name or a
/// file at the root.
String? dirHintOf(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).toList();
  if (parts.length < 2) return null;
  final dirs = parts.sublist(0, parts.length - 1);
  return dirs.length <= 2 ? dirs.join('/') : dirs.sublist(dirs.length - 2).join('/');
}

bool _isSeparator(int unit) => unit == 0x2F || unit == 0x5C;

/// The last line of [text] that says something: not blank, not a fence of a
/// code block, not a `Wall time:` footer (omp appends one to every command's
/// output). Null when there is none.
String? lastMeaningfulLine(String text) {
  final lines = text.split('\n');
  for (var i = lines.length - 1; i >= 0; i--) {
    final line = lines[i].trim();
    if (line.isEmpty || line.startsWith('```') || line.startsWith('Wall time:')) continue;
    return line;
  }
  return null;
}

/// The first line of [text] that is not blank, trimmed; null when none.
String? firstLine(String text) {
  for (final line in text.split('\n')) {
    final t = line.trim();
    if (t.isNotEmpty) return t;
  }
  return null;
}

final _lead = RegExp(r'^(?:#{1,6}\s+|>\s*|[-*+]\s+|\d+[.)]\s+)');
final _decor = RegExp(r'\*\*|__|`|~~');
final _sentenceEnd = RegExp(r'[.!?…。！？](?=\s|$)');

/// The first sentence of [text] as plain text for a status line: the first
/// line that says something (a heading, a list marker, emphasis and code
/// marks removed), cut at its first sentence end, at most [max] clusters.
/// Null when [text] holds no words.
String? firstSentence(String text, {int max = 120}) {
  for (final raw in text.split('\n')) {
    var line = raw.trim();
    if (line.isEmpty || line.startsWith('```') || RegExp(r'^[-*_=\s]{3,}$').hasMatch(line)) continue;
    line = line.replaceFirst(_lead, '').replaceAll(_decor, '').trim();
    if (line.isEmpty) continue;
    final end = _sentenceEnd.firstMatch(line);
    if (end != null) line = line.substring(0, end.end);
    return clip(line, max);
  }
  return null;
}
