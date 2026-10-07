/// Vietnamese text facts the harness needs, in plain Dart: Dart has no
/// `String.normalize`, so everything here assumes NFC (precomposed) text, which
/// is what Android keyboards produce. The corpus extractor converts to NFC.
library;

/// Rows of the Vietnamese vowel table: the plain-ASCII base letter, whether the
/// vowel carries a shape mark (breve, circumflex, horn), then the six forms by
/// tone: none, grave, acute, hook above, tilde, dot below.
const _rows = <(String, bool, String)>[
  ('a', false, 'aàáảãạ'),
  ('a', true, 'ăằắẳẵặ'),
  ('a', true, 'âầấẩẫậ'),
  ('e', false, 'eèéẻẽẹ'),
  ('e', true, 'êềếểễệ'),
  ('i', false, 'iìíỉĩị'),
  ('o', false, 'oòóỏõọ'),
  ('o', true, 'ôồốổỗộ'),
  ('o', true, 'ơờớởỡợ'),
  ('u', false, 'uùúủũụ'),
  ('u', true, 'ưừứửữự'),
  ('y', false, 'yỳýỷỹỵ'),
];

/// A lowercase Vietnamese letter's ASCII base and its Telex cost beyond that base.
class _Letter {
  const _Letter(this.base, this.extraKeys);
  final String base;
  final int extraKeys;
}

final Map<String, _Letter> _letters = () {
  final map = <String, _Letter>{'đ': const _Letter('d', 1)};
  for (final (base, shaped, forms) in _rows) {
    final chars = forms.runes.map(String.fromCharCode).toList();
    assert(chars.length == 6, 'row $forms');
    for (var tone = 0; tone < 6; tone++) {
      map[chars[tone]] = _Letter(base, (shaped ? 1 : 0) + (tone > 0 ? 1 : 0));
    }
  }
  return map;
}();

/// True when [text] holds a letter only Vietnamese writes (a shape mark, a
/// tone mark or đ). A word that only uses ASCII is not evidence of anything.
bool hasVietnameseMark(String text) {
  for (final rune in text.toLowerCase().runes) {
    if ((_letters[String.fromCharCode(rune)]?.extraKeys ?? 0) > 0) return true;
  }
  return false;
}

/// [text] without tone and shape marks, the way a person types when the marks
/// cost too much (`không` -> `khong`). Each character maps to exactly one, so
/// positions in the folded text are positions in the original.
String foldVietnamese(String text) {
  StringBuffer? out;
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    final lower = char.toLowerCase();
    final letter = _letters[lower];
    if (letter == null || letter.base == lower) {
      out?.write(char);
      continue;
    }
    out ??= StringBuffer(text.substring(0, i));
    out.write(char == lower ? letter.base : letter.base.toUpperCase());
  }
  return out?.toString() ?? text;
}

/// Key presses to type [char] with the Telex method (the default of Gboard's
/// Vietnamese layout): the letter, plus one key for a shape mark (`aa`, `aw`,
/// `ow`, `dd`) and one for a tone (`s f r x j`). `việt` is `vieejt`, 6 for 4
/// characters. Shift is not counted: the keyboard capitalizes for free at a
/// sentence start and the harness does not model the rest.
int telexKeys(String char) => 1 + (_letters[char.toLowerCase()]?.extraKeys ?? 0);
