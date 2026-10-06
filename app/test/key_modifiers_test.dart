import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/features/pane/key_modifiers.dart';

TextEditingValue _v(String text) => TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );

void main() {
  group('StickyModifiers', () {
    test('chord puts the armed modifiers in herdr order and disarms', () {
      final m = StickyModifiers()
        ..toggleAlt()
        ..toggleCtrl();

      expect(m.chord('left'), 'ctrl+alt+left');
      expect(m.armed, isFalse);
      expect(m.chord('left'), isNull);
    });

    test('a key that already names a combo is left alone and does not spend the latch', () {
      final m = StickyModifiers()..toggleCtrl();

      expect(m.chord('shift+tab'), isNull);
      expect(m.ctrl, isTrue);
    });

    test('the plus key is a name, not a combo', () {
      final m = StickyModifiers()..toggleCtrl();

      expect(m.chord(StickyModifiers.keyName('+')), 'ctrl+plus');
    });

    test('apply changes a lone key and passes sequences through', () {
      final m = StickyModifiers()..toggleCtrl();

      expect(m.apply(const ['a', 'b']), ['a', 'b']);
      expect(m.ctrl, isTrue, reason: 'a sequence does not spend it');
      expect(m.apply(const ['d']), ['ctrl+d']);
    });

    test('tapping an armed modifier again disarms it', () {
      final m = StickyModifiers()
        ..toggleCtrl()
        ..toggleCtrl();

      expect(m.armed, isFalse);
    });
  });

  group('ModifierTypingFormatter', () {
    late StickyModifiers m;
    late List<String> chords;
    late ModifierTypingFormatter f;

    setUp(() {
      m = StickyModifiers();
      chords = [];
      f = ModifierTypingFormatter(m, chords.add);
    });

    test('does nothing while no modifier is armed', () {
      final out = f.formatEditUpdate(_v(''), _v('r'));

      expect(out.text, 'r');
      expect(chords, isEmpty);
    });

    test('a typed letter becomes the chord and the field keeps its text', () {
      m.toggleCtrl();

      final out = f.formatEditUpdate(_v('ls'), _v('lsr'));

      expect(chords, ['ctrl+r']);
      expect(out.text, 'ls');
    });

    test('a letter typed mid-text is found wherever it landed', () {
      m.toggleCtrl();

      final out = f.formatEditUpdate(_v('ab'), _v('aXb'));

      expect(chords, ['ctrl+x'], reason: 'letters are lower-cased');
      expect(out.text, 'ab');
    });

    test('deleting, pasting and replacing are edits, not keys', () {
      m.toggleCtrl();

      expect(f.formatEditUpdate(_v('abc'), _v('ab')).text, 'ab');
      expect(f.formatEditUpdate(_v('a'), _v('abcd')).text, 'abcd');
      expect(f.formatEditUpdate(_v('abc'), _v('abx')).text, 'abx');
      expect(chords, isEmpty);
      expect(m.ctrl, isTrue, reason: 'still armed');
    });

    test('half of a surrogate pair is not a key', () {
      m.toggleCtrl();

      expect(ModifierTypingFormatter.insertedChar('', '\u{1F600}'.substring(0, 1)), isNull);
      expect(chords, isEmpty);
    });

    test('a space is the space key', () {
      m.toggleAlt();

      f.formatEditUpdate(_v('a'), _v('a '));

      expect(chords, ['alt+space']);
    });
  });
}
