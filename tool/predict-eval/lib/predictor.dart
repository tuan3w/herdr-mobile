/// One tap-able suggestion above the keyboard. Tapping it only edits the draft;
/// it never sends (the app's quick-phrase rule).
class Chip {
  const Chip({
    required this.label,
    required this.insert,
    this.replace = 0,
    this.space = false,
    required this.confidence,
  });

  /// What the chip says, whole: the word or the phrase.
  final String label;

  /// Text put at the cursor after removing [replace] characters before it.
  /// A word typed without its accents is replaced by the accented word.
  final String insert;
  final int replace;

  /// A word chip leaves a space after itself, like the keyboard's own.
  final bool space;

  /// The engine's probability that the chip is exactly what the person means.
  final double confidence;

  /// What the person sees: two chips with the same signature look the same.
  String get signature => '$replace|$insert|$space';
}

/// A prediction engine under test. Called with the draft up to the cursor
/// (which is always at its end: that is how people type on a phone).
abstract class Predictor {
  String get name;

  /// At most [slots] chips, best first, each already past the engine's own
  /// show threshold. Must not change what the engine learned.
  List<Chip> suggest(String draft, int slots);

  /// Learn from one message the person sent.
  void learn(String message);
}
