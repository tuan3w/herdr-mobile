/// A word is letters, marks and apostrophes: `don't`, `không`, `refactor`.
/// A Vietnamese syllable is a word (the language writes a space between them).
final wordPattern = RegExp(r"[\p{L}\p{M}']+", unicode: true);
final _trailingWord = RegExp(r"[\p{L}\p{M}']+$", unicode: true);

/// A word touching one of these is code or a path, not prose: never learned
/// from, never completed.
const _codeish = r'\/@_=:{}[]<>#$%&*+|~^`';

bool isCodeChar(String char) => _codeish.contains(char);

/// The word being typed at the end of [draft] ('' after a space).
String trailingWord(String draft) => _trailingWord.firstMatch(draft)?.group(0) ?? '';

/// Prose words of [text] with their spans, leaving out any word that touches
/// code characters.
List<({int start, int end})> proseWords(String text) {
  final out = <({int start, int end})>[];
  for (final m in wordPattern.allMatches(text)) {
    final before = m.start > 0 ? text[m.start - 1] : '';
    final after = m.end < text.length ? text[m.end] : '';
    if (before.isNotEmpty && isCodeChar(before)) continue;
    if (after.isNotEmpty && isCodeChar(after)) continue;
    out.add((start: m.start, end: m.end));
  }
  return out;
}

/// Every word of [text], code or not: what a typist has to type.
List<({int start, int end})> allWords(String text) => [
      for (final m in wordPattern.allMatches(text)) (start: m.start, end: m.end),
    ];
