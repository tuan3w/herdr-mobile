import 'package:herdr_mobile/data/repositories/sent_phrases.dart';

/// Keeps what was learned in memory and records writes.
class MemorySentPhrasesStore implements SentPhrasesStore {
  MemorySentPhrasesStore([this.saved = const SentPhrasesSnapshot()]);

  SentPhrasesSnapshot saved;
  Object? writeFailure;
  int writes = 0;

  @override
  Future<SentPhrasesSnapshot> read() async => saved;

  @override
  Future<void> write(SentPhrasesSnapshot snapshot) async {
    if (writeFailure case final failure?) throw failure;
    saved = snapshot;
    writes++;
  }
}
