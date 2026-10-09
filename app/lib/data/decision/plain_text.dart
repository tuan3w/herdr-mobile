/// Text hygiene for what the agent sends and the person is asked to judge.
///
/// The data layer cannot import the `ui/` copy of these rules
/// (`visible_text.dart`), so the decision data keeps its own. Same sets: C0
/// and C1 controls, zero-width and direction marks, line and paragraph
/// separators, byte-order marks, soft hyphens, annotation marks and the
/// invisible "tag" block.
library;

// An OSC is stripped only when it ends with BEL or ST on its own line: an
// unterminated `ESC ]` used to delete everything after it (a path or a plan
// cut at the first `ESC ]`), while a terminal would still show that text.
final _osc = RegExp(r'\x1B\][^\x07\x1B\n]*(?:\x07|\x1B\\)');
// A CSI is parameters (digits and `;:<=>?`), optional intermediates, one final
// byte. A space is an intermediate only before `q` (the cursor-style
// `ESC[2 q`): anywhere else `ESC[31 hello` would swallow the `h` of a word.
final _csi = RegExp(r'\x1B\[[0-?]*(?: q|[!-/]*[@-~])');
// Two-byte escapes. `[` and `]` are left out: a CSI or OSC that did not
// complete is not a sequence, and its ESC stays in the text for [showHidden]
// to show.
final _otherEscape = RegExp(r'\x1B[@-Z\\^_]|\x1B[ -/]*[0-Z\\^-~]');

/// [text] without terminal escape sequences (colour, cursor, OSC titles). A
/// sequence that does not complete keeps its ESC, which [isHiddenRune] flags.
String stripAnsi(String text) =>
    text.contains('\x1B') ? text.replaceAll(_osc, '').replaceAll(_csi, '').replaceAll(_otherEscape, '') : text;

/// Whether [rune] can hide or reorder text, or is a control other than
/// newline and tab.
bool isHiddenRune(int r) {
  if (r < 0x20) return r != 0x0A && r != 0x09;
  if (r < 0x7F) return false;
  if (r <= 0x9F) return true; // DEL and C1.
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

/// `‹U+202E›`: how a hidden character shows.
String _escapeOf(int rune) => '\u2039U+${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}\u203a';

/// [text] with ANSI sequences removed and every other hidden character
/// replaced by a visible escape, so the person reads what the machine would
/// read. For text that is judged (a plan, a path).
String showHidden(String text) {
  final s = stripAnsi(text);
  StringBuffer? out;
  var copied = 0;
  var i = 0;
  while (i < s.length) {
    final rune = _runeAt(s, i);
    final width = rune > 0xFFFF ? 2 : 1;
    if (isHiddenRune(rune)) {
      out ??= StringBuffer();
      out
        ..write(s.substring(copied, i))
        ..write(_escapeOf(rune));
      copied = i + width;
    }
    i += width;
  }
  if (out == null) return s;
  out.write(s.substring(copied));
  return out.toString();
}

/// [text] as one clean line: ANSI sequences removed, hidden characters and
/// controls dropped (a direction override must not reorder a sentence),
/// whitespace runs (and newlines and tabs) folded into single spaces.
String plainLine(String text) {
  final s = stripAnsi(text);
  final out = StringBuffer();
  var space = false;
  var i = 0;
  while (i < s.length) {
    final rune = _runeAt(s, i);
    final width = rune > 0xFFFF ? 2 : 1;
    if (rune == 0x0A || rune == 0x09 || rune == 0x20 || rune == 0xA0 || rune == 0x2028 || rune == 0x2029) {
      space = true;
    } else if (!isHiddenRune(rune)) {
      if (space && out.isNotEmpty) out.write(' ');
      space = false;
      out.write(s.substring(i, i + width));
    }
    i += width;
  }
  return out.toString();
}

int _runeAt(String s, int index) {
  final unit = s.codeUnitAt(index);
  if (unit >= 0xD800 && unit <= 0xDBFF && index + 1 < s.length) {
    final next = s.codeUnitAt(index + 1);
    if (next >= 0xDC00 && next <= 0xDFFF) return 0x10000 + ((unit - 0xD800) << 10) + (next - 0xDC00);
  }
  return unit;
}

/// [s] cut to at most [limit] UTF-16 units, never inside a surrogate pair,
/// and at a line start when one lies within the last 500 units. Returns the
/// kept text and how many characters were dropped (0 when [s] fits).
(String, int) capText(String s, int limit) {
  if (s.length <= limit) return (s, 0);
  var cut = limit;
  final unit = s.codeUnitAt(cut - 1);
  if (unit >= 0xD800 && unit <= 0xDBFF) cut--;
  final nl = s.lastIndexOf('\n', cut - 1);
  if (nl >= 0 && cut - nl <= 500) cut = nl + 1;
  return (s.substring(0, cut), s.length - cut);
}

/// [s] cut to [limit] units with a trailing ellipsis (so the result is at
/// most [limit] long), at a space when one is near the end.
String ellipsize(String s, int limit) {
  if (s.length <= limit) return s;
  var cut = limit - 1;
  final unit = s.codeUnitAt(cut - 1);
  if (unit >= 0xD800 && unit <= 0xDBFF) cut--;
  final space = s.lastIndexOf(' ', cut - 1);
  if (space > cut - 24 && space > 0) cut = space;
  return '${s.substring(0, cut).trimRight()}\u2026';
}
