import 'model.dart';

/// A fixed word list with a kind per word, looked up straight in the line
/// text (no substring allocation): bucketed by first letter and length.
final class Words {
  /// [lists] maps a kind to its words, separated by whitespace. With
  /// [ignoreCase] the lookup ignores ASCII case (SQL).
  Words(Map<TokenKind, String> lists, {this.ignoreCase = false}) {
    for (final entry in lists.entries) {
      for (final word in entry.value.split(RegExp(r'\s+'))) {
        if (word.isEmpty) continue;
        final w = ignoreCase ? word.toLowerCase() : word;
        final c = w.codeUnitAt(0);
        (_buckets[c] ??= <_Entry>[]).add(_Entry(w, entry.key));
      }
    }
  }

  final bool ignoreCase;
  final List<List<_Entry>?> _buckets = List<List<_Entry>?>.filled(128, null);

  /// The kind of the word `t[s..e)`, or null.
  TokenKind? find(String t, int s, int e) {
    var c0 = t.codeUnitAt(s);
    if (c0 >= 128) return null;
    if (ignoreCase && c0 >= 0x41 && c0 <= 0x5A) c0 += 32;
    final bucket = _buckets[c0];
    if (bucket == null) return null;
    final len = e - s;
    entries:
    for (var k = 0; k < bucket.length; k++) {
      final entry = bucket[k];
      final w = entry.word;
      if (w.length != len) continue;
      for (var x = 1; x < len; x++) {
        var c = t.codeUnitAt(s + x);
        if (ignoreCase && c >= 0x41 && c <= 0x5A) c += 32;
        if (c != w.codeUnitAt(x)) continue entries;
      }
      return entry.kind;
    }
    return null;
  }
}

final class _Entry {
  const _Entry(this.word, this.kind);
  final String word;
  final TokenKind kind;
}
