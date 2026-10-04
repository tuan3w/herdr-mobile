/// Whether [text], one terminal line, is a row of a table or of a box: output
/// that was laid out for a fixed width and falls apart when it is re-flowed.
///
/// A row of a box or table drawn with line characters has two or more vertical
/// bars (`│ name │ value │`) or a corner/junction together with a horizontal
/// rule (`┌──┬──┐`, `├──┼──┤`, `╰────╯`). A markdown table row starts and ends
/// with `|` and has at least two cells, and an ASCII rule is `+---+---+`.
///
/// Deliberately a little eager: a line wrongly kept whole costs a sideways
/// scroll, a table that is wrapped costs its meaning.
bool isTableRow(String text) {
  final t = text.trim();
  if (t.length < 3) return false;
  var bars = 0;
  var corner = false;
  var rule = false;
  // Every character that counts lives in the box-drawing block (U+2500 to
  // U+2570, all one UTF-16 unit), so anything else is skipped without a set
  // lookup: most lines of ordinary output contain none.
  for (var i = 0; i < t.length; i++) {
    final rune = t.codeUnitAt(i);
    if (rune < 0x2500 || rune > 0x2570) continue;
    if (rune == 0x2502 || rune == 0x2503 || rune == 0x2551) {
      bars++;
    } else if (rune == 0x2500 || rune == 0x2501 || rune == 0x2550) {
      rule = true;
    } else if (_junctions.contains(rune)) {
      corner = true;
    }
  }
  if (bars >= 2) return true;
  if (corner && rule) return true;
  if (t.startsWith('|') && t.endsWith('|') && _count(t, 0x7C) >= 3) return true;
  if (t.startsWith('+') && t.endsWith('+') && t.contains('--')) return true;
  return false;
}

int _count(String s, int unit) {
  var n = 0;
  for (var i = 0; i < s.length; i++) {
    if (s.codeUnitAt(i) == unit) n++;
  }
  return n;
}

/// Corners, tees and crosses of the light, heavy, double and rounded sets.
const _junctions = <int>{
  0x250C, 0x2510, 0x2514, 0x2518, 0x251C, 0x2524, 0x252C, 0x2534, 0x253C, // light
  0x250F, 0x2513, 0x2517, 0x251B, 0x2523, 0x252B, 0x2533, 0x253B, 0x254B, // heavy
  0x2554, 0x2557, 0x255A, 0x255D, 0x2560, 0x2563, 0x2566, 0x2569, 0x256C, // double
  0x256D, 0x256E, 0x256F, 0x2570, // rounded
};
