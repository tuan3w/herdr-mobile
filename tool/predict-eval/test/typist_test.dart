import 'package:predict_eval/predictor.dart';
import 'package:predict_eval/typist.dart';
import 'package:predict_eval/vietnamese.dart';
import 'package:test/test.dart';

/// Offers fixed chips for a fixed draft, nothing otherwise.
class _Script implements Predictor {
  _Script(this.byDraft);
  final Map<String, List<Chip>> byDraft;
  @override
  String get name => 'script';
  @override
  List<Chip> suggest(String draft, int slots) => byDraft[draft] ?? const [];
  @override
  void learn(String message) {}
}

Chip _word(String insert, {int replace = 0}) =>
    Chip(label: insert, insert: insert, replace: replace, space: true, confidence: 0.9);

void main() {
  group('Vietnamese', () {
    test('Telex costs the marks: việt is vieejt', () {
      final keys = 'việt'.split('').fold<int>(0, (a, c) => a + telexKeys(c));
      expect(keys, 6);
      expect(telexKeys('đ'), 2);
      expect(telexKeys('a'), 1);
    });

    test('fold drops marks and keeps case and length', () {
      expect(foldVietnamese('Việt Nam đẹp, Đà Nẵng'), 'Viet Nam dep, Da Nang');
      expect(foldVietnamese('refactor'), 'refactor');
    });

    test('only a mark is evidence of Vietnamese', () {
      expect(hasVietnameseMark('không'), isTrue);
      expect(hasVietnameseMark('khong'), isFalse);
      expect(hasVietnameseMark('đi'), isTrue);
    });
  });

  group('typist', () {
    const sim = Simulation(style: Style.chars);

    test('one tap finishes a message and nothing was typed', () {
      final t = typeMessage(
        'run the tests',
        _Script({'': [const Chip(label: 'run the tests', insert: 'run the tests', confidence: 1)]}),
        sim,
        0,
      );
      expect(t.keys, 1, reason: 'a tap costs one key, not 13');
      expect(t.tapOnly, 1);
      expect(t.ksr, closeTo(1 - 1 / 13, 1e-9));
    });

    test('a chip that is wrong is never tapped, and is counted as noise', () {
      final t = typeMessage('hello', _Script({'': [_word('goodbye')]}), sim, 0);
      expect(t.taps, 0);
      expect(t.keys, 5);
      expect(t.noisyWords, 1);
    });

    test('a chip worth no more than its tap is not tapped', () {
      // "to" -> chip "to " saves 0 keys after typing "t": one char for one tap.
      final t = typeMessage('to', _Script({'t': [_word('o')]}), sim, 0);
      expect(t.taps, 0);
    });

    test('a word chip leaves a space the text did not want: that costs a backspace', () {
      final withComma = typeMessage('refactor, then', _Script({'ref': [_word('actor')]}), sim, 0);
      expect(withComma.taps, 1);
      // 3 typed + 1 tap + 1 backspace + ", then" (6) = 11.
      expect(withComma.keys, 11);
      final withSpace = typeMessage('refactor then', _Script({'ref': [_word('actor')]}), sim, 0);
      // 3 typed + 1 tap + "then" (4) = 8: the space came with the chip.
      expect(withSpace.keys, 8);
    });

    test('a changing first chip while one word is typed is a flip', () {
      final t = typeMessage(
        'abcd',
        _Script({
          'a': [_word('x')],
          'ab': [_word('y')],
          'abc': [_word('y')],
        }),
        sim,
        0,
      );
      expect(t.flips, 1);
    });

    test('the person who skips marks pays one key per character and gets the marked word', () {
      const bare = Simulation(style: Style.bare);
      final t = typeMessage(
        'không sao',
        _Script({'kho': [_word('không', replace: 3)]}),
        bare,
        0,
      );
      // k h o typed, one tap, "sao" typed: 3 + 1 + 3 = 7 against 9 keys.
      expect(t.taps, 1);
      expect(t.keys, 7);
    });

    test('noticing half the time keeps the same decision for the whole word', () {
      const half = Simulation(style: Style.chars, notice: 0.5);
      var taken = 0;
      for (var i = 0; i < 200; i++) {
        final t = typeMessage(
          'refactor',
          _Script({
            'ref': [_word('actor')],
            'refa': [_word('ctor')],
            'refac': [_word('tor')],
          }),
          half,
          i,
        );
        taken += t.taps;
      }
      expect(taken, inInclusiveRange(70, 130), reason: 'about half of 200, not 1 - 0.5^3');
    });
  });
}
