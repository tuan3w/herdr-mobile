import '../predictor.dart';

/// Chips of several engines in one strip, likeliest first. Each engine's
/// confidence is the probability its chip is exactly right, so they compare.
class BlendPredictor implements Predictor {
  BlendPredictor(this.parts, {this.label = 'blend'});

  final List<Predictor> parts;
  final String label;

  @override
  String get name => label;

  @override
  void learn(String message) {
    for (final p in parts) {
      p.learn(message);
    }
  }

  @override
  List<Chip> suggest(String draft, int slots) {
    final all = <Chip>[for (final p in parts) ...p.suggest(draft, slots)]
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    final seen = <String>{};
    return [
      for (final c in all)
        if (seen.add('${c.replace}|${c.insert}')) c,
    ].take(slots).toList();
  }
}
