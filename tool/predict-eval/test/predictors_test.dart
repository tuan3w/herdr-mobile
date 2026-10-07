import 'package:predict_eval/predictors/ngram.dart';
import 'package:predict_eval/predictors/phrase.dart';
import 'package:test/test.dart';

WordPrior _prior({bool fold = false}) => WordPrior.build(
      {'the': 0.05, 'there': 0.001, 'then': 0.002, 'refactor': 0.00001, 'would': 0.01},
      {'không': 0.05, 'khong': 0.0001, 'khác': 0.01},
      viShare: 0.1,
      fold: fold,
    );

void main() {
  group('phrase', () {
    test('offers the message most often sent under the typed start', () {
      final p = PhrasePredictor();
      for (var i = 0; i < 6; i++) {
        p.learn('run the tests');
      }
      p.learn('run the linter');
      p.learn('run the linter');
      final chips = p.suggest('ru', 3);
      expect(chips.first.insert, 'n the tests');
      expect(chips.first.confidence, closeTo(6 / 8, 1e-9));
    });

    test('a message sent once is never offered', () {
      final p = PhrasePredictor();
      p.learn('my token is abc123');
      expect(p.suggest('my', 3), isEmpty);
    });

    test('an empty composer shows the most sent messages', () {
      final p = PhrasePredictor();
      for (var i = 0; i < 3; i++) {
        p.learn('continue');
      }
      p.learn('ok');
      p.learn('ok');
      expect([for (final c in p.suggest('', 2)) c.label], ['continue', 'ok']);
    });

    test('a message that is itself the draft is not offered back', () {
      final p = PhrasePredictor();
      p.learn('continue');
      p.learn('continue');
      expect(p.suggest('continue', 3), isEmpty);
    });
  });

  group('ngram', () {
    NgramPredictor engine({NgramParams params = const NgramParams(), WordPrior? prior}) =>
        NgramPredictor(params, prior ?? _prior());

    test('learns the words of this person and completes them', () {
      final e = engine();
      for (var i = 0; i < 5; i++) {
        e.learn('please refactor the parser');
      }
      final chips = e.suggest('please refa', 3);
      expect(chips.first.label, 'refactor');
      expect(chips.first.insert, 'ctor');
    });

    test('a finished word is not swapped for a longer one it merely starts', () {
      final e = engine(params: const NgramParams(tau: 0.3));
      expect([for (final c in e.suggest('the', 3)) c.label], isNot(contains('there')));
    });

    test('a word typed once outside the dictionary is not offered', () {
      final e = engine();
      e.learn('look at xkcdparser now');
      expect(e.suggest('look at xkc', 3), isEmpty);
    });

    test('code and paths get nothing, before and while learning', () {
      final e = engine();
      for (var i = 0; i < 5; i++) {
        e.learn('open src/quokka_helper.dart');
      }
      expect(e.suggest('open src/quok', 3), isEmpty);
      expect(e.suggest('open quok', 3), isEmpty, reason: 'the code word was never learned');
    });

    test('without personal learning it is a keyboard that knows nothing of you', () {
      final e = engine(params: const NgramParams(personal: false));
      for (var i = 0; i < 5; i++) {
        e.learn('the quokka');
      }
      expect(e.suggest('the quo', 3), isEmpty);
    });

    test('next word after a space, from what usually follows', () {
      final e = engine(params: const NgramParams(nextWord: true, minPrefix: 0, tau: 0.3));
      for (var i = 0; i < 8; i++) {
        e.learn('run the tests');
      }
      expect(e.suggest('run ', 3).first.label, 'the');
      expect(e.suggest('run the ', 3).first.label, 'tests');
    });

    test('folded matching answers a word typed without marks with the marked word', () {
      final e = NgramPredictor(const NgramParams(fold: true), _prior(fold: true));
      for (var i = 0; i < 5; i++) {
        e.learn('không được');
      }
      final chip = e.suggest('kho', 3).first;
      expect(chip.label, 'không');
      expect(chip.replace, 3);
      expect(chip.insert, 'không');
    });
  });
}
