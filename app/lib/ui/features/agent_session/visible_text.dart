/// [text] with every character that can hide or reorder what it says replaced
/// by a visible escape (`‹U+202E›`), so the person reads what the machine
/// would run.
///
/// Replaced: C0 and C1 controls except newline and tab (an ANSI sequence
/// shows as `‹U+001B›[31m`), the zero-width and direction marks
/// (U+200B-200F, U+202A-202E, U+2066-2069, U+061C), the line and paragraph
/// separators, byte-order marks and soft hyphens, interlinear annotation
/// marks and the invisible "tag" block, and a lone UTF-16 surrogate (half of an
/// emoji cut in two, or a bad `\ud800` escape in the agent's JSON), which would
/// make Flutter's paragraph builder throw. Everything else is left alone, so
/// Vietnamese and other scripts read as written.
///
/// Anything that judges the text (the risk gate) must read this string, not
/// the raw one: the gate then sees what the person sees.
String visibleText(String text) {
  StringBuffer? out;
  var copied = 0;
  var i = 0;
  while (i < text.length) {
    final rune = text.runeAt(i);
    final width = rune > 0xFFFF ? 2 : 1;
    if (_hidden(rune)) {
      out ??= StringBuffer();
      out
        ..write(text.substring(copied, i))
        ..write(escapeOf(rune));
      copied = i + width;
    }
    i += width;
  }
  if (out == null) return text;
  out.write(text.substring(copied));
  return out.toString();
}

/// `‹U+202E›`: how a hidden character shows.
String escapeOf(int rune) => '\u2039U+${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}\u203a';

/// Whether [text] holds a character [visibleText] would replace.
bool hasHiddenCharacters(String text) => visibleText(text) != text;

final _osc = RegExp(r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)?');
final _csi = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
final _otherEscape = RegExp(r'\x1B[@-Z\\-_]|\x1B[ -/]*[0-~]');

/// Command output as a panel shows it: colour and cursor sequences removed,
/// a line rewritten with a carriage return (a progress bar) kept as its last
/// version, and what remains made visible by [visibleText].
String terminalText(String raw) {
  var text = raw;
  if (text.contains('\x1B')) {
    text = text.replaceAll(_osc, '').replaceAll(_csi, '').replaceAll(_otherEscape, '');
  }
  if (text.contains('\r')) {
    text = text.replaceAll('\r\n', '\n');
    if (text.contains('\r')) {
      text = text.split('\n').map((line) {
        var end = line.length;
        while (end > 0 && line.codeUnitAt(end - 1) == 0x0D) {
          end--;
        }
        final cr = end == 0 ? -1 : line.lastIndexOf('\r', end - 1);
        return cr < 0 ? line.substring(0, end) : line.substring(cr + 1, end);
      }).join('\n');
    }
  }
  return visibleText(text);
}

bool _hidden(int r) {
  if (r < 0x20) return r != 0x0A && r != 0x09;
  if (r < 0x7F) return false;
  if (r >= 0xD800 && r <= 0xDFFF) return true; // a surrogate that is not half of a pair (runeAt joins pairs).
  return r == 0x00AD ||
      r == 0x061C ||
      r == 0x180E ||
      (r >= 0x200B && r <= 0x200F) ||
      (r >= 0x2028 && r <= 0x202E) ||
      (r >= 0x2060 && r <= 0x206F) ||
      r == 0xFEFF ||
      (r >= 0xFFF9 && r <= 0xFFFB) ||
      (r >= 0xE0000 && r <= 0xE007F);
}

extension on String {
  int runeAt(int index) {
    final unit = codeUnitAt(index);
    if (unit >= 0xD800 && unit <= 0xDBFF && index + 1 < length) {
      final next = codeUnitAt(index + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) {
        return 0x10000 + ((unit - 0xD800) << 10) + (next - 0xDC00);
      }
    }
    return unit;
  }
}
