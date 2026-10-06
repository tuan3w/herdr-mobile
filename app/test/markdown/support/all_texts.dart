/// Every text the corpus holds, for the tests that check invariants rather
/// than a per-case expectation: case inputs, `corpus/messages/*.md`, and the
/// agent text of the trace fixtures (when present).
library;

import 'corpus.dart';
import 'traces.dart';

const corpusDir = 'test/markdown/corpus';
const tracesDir = 'test/fixtures/traces';

typedef CorpusText = ({String name, String text});

List<CorpusText> allCorpusTexts() => [
      for (final c in loadCorpus(corpusDir)) (name: c.toString(), text: c.input),
      ...loadMessages('$corpusDir/messages'),
      for (final m in loadTraceMessages(tracesDir)) (name: m.name, text: m.chunks.join()),
    ];
