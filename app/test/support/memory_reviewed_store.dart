import 'package:herdr_mobile/data/repositories/reviewed_state.dart';

/// Keeps the reviewed map in memory, as a store that survives a "restart":
/// give the same instance to a second [ReviewedState].
class MemoryReviewedStore implements ReviewedStore {
  ReviewedMap? saved;
  int writes = 0;

  /// While set, [write] throws (a phone that cannot write its preferences).
  bool failing = false;

  @override
  Future<ReviewedMap?> read() async => saved == null
      ? null
      : {for (final MapEntry(:key, :value) in saved!.entries) key: Map.of(value)};

  @override
  Future<void> write(ReviewedMap reviewed) async {
    if (failing) throw StateError('disk full');
    writes++;
    saved = {for (final MapEntry(:key, :value) in reviewed.entries) key: Map.of(value)};
  }
}
