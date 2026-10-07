import 'dart:convert';
import 'dart:io';

class Message {
  const Message(this.t, this.text);
  final double t;
  final String text;
}

/// corpus/messages.jsonl (see extract_corpus.py), oldest first.
List<Message> loadMessages(String path) => [
      for (final line in File(path).readAsLinesSync())
        if (line.trim().isNotEmpty)
          () {
            final json = jsonDecode(line) as Map<String, dynamic>;
            return Message((json['t'] as num).toDouble(), json['text'] as String);
          }(),
    ];

/// `word count` lines, most frequent first, as probabilities summing to 1.
/// Empty when the file is missing: the prior is then simply absent.
Map<String, double> loadLexicon(String path) {
  final file = File(path);
  if (!file.existsSync()) return {};
  final counts = <String, double>{};
  var total = 0.0;
  for (final line in file.readAsLinesSync()) {
    final space = line.lastIndexOf(' ');
    if (space <= 0) continue;
    final count = double.tryParse(line.substring(space + 1));
    if (count == null) continue;
    final word = line.substring(0, space);
    counts[word] = (counts[word] ?? 0) + count;
    total += count;
  }
  return {for (final e in counts.entries) e.key: e.value / total};
}
