import 'package:herdr_mobile/data/repositories/quick_phrases.dart';

/// Keeps the saved phrases in memory (null = never saved) and records writes.
class MemoryQuickPhrasesStore implements QuickPhrasesStore {
  MemoryQuickPhrasesStore([this.saved]);

  List<String>? saved;
  Object? readFailure;
  Object? writeFailure;
  int writes = 0;

  @override
  Future<List<String>?> read() async {
    if (readFailure case final failure?) throw failure;
    return saved;
  }

  @override
  Future<void> write(List<String> phrases) async {
    if (writeFailure case final failure?) throw failure;
    saved = List.of(phrases);
    writes++;
  }
}
