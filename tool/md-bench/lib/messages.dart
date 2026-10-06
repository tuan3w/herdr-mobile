/// Synthetic messages of a given size built from realistic corpus content.
library;

import '../../../app/test/markdown/support/corpus.dart';

const corpusDir = '../../app/test/markdown/corpus';

/// Source material: the realistic agent answers of the corpus.
List<String> pieces() => [
      for (final c in loadCorpus(corpusDir))
        if (c.file == 'agent.case') c.input,
      for (final m in loadMessages('$corpusDir/messages')) m.text,
    ];

/// A message of at least [bytes] characters, cut on a block boundary, made by
/// repeating the pieces.
String message(int bytes) {
  final p = pieces();
  final b = StringBuffer();
  var i = 0;
  while (b.length < bytes) {
    b
      ..write(p[i++ % p.length])
      ..write('\n\n');
  }
  return b.toString();
}
