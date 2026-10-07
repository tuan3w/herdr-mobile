import '../predictor.dart';

/// Nothing: the phone's keyboard alone. The baseline every other row is read against.
class NonePredictor implements Predictor {
  @override
  String get name => 'none';

  @override
  List<Chip> suggest(String draft, int slots) => const [];

  @override
  void learn(String message) {}
}

/// Today's app: the hand-written quick phrases (`QuickPhrases.defaults`), shown
/// in a row above an empty composer. A chip fills the composer; the row is only
/// useful before the first character.
class StaticPhrases implements Predictor {
  StaticPhrases([this.phrases = const [
    'continue',
    'yes, go ahead',
    'run the tests',
    'explain what you changed',
  ]]);

  final List<String> phrases;

  @override
  String get name => 'chips-default';

  @override
  List<Chip> suggest(String draft, int slots) => draft.isNotEmpty
      ? const []
      : [
          for (final p in phrases.take(slots))
            Chip(label: p, insert: p, confidence: 1),
        ];

  @override
  void learn(String message) {}
}
