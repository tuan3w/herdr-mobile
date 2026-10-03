import '../models/pane_preview.dart';

/// Recognises the question a blocked agent is waiting on in the last rows of
/// its terminal and turns it into one-tap answers.
///
/// Deliberately conservative: a miss costs the user one tap in the full pane
/// view, a wrong match could approve something. The caller must only ask
/// while herdr reports the pane as `blocked`; this function additionally
/// insists the prompt sits at the very bottom of [rows] (a few hint/border
/// rows may follow it), so a numbered list that merely scrolled past is never
/// mistaken for a menu.
///
/// [rows] are ANSI-stripped terminal rows, oldest first (blank rows are
/// ignored). Recognised, in this order:
///
///  * numbered menus (`❯ 1. Yes` / `2. Yes, and don't ask again` / `3. No`) —
///    consecutive numbers from 1, a selection marker or a question right above;
///  * un-numbered menus with a pointer (`❯ Allow once`) or radio (`●`/`○`)
///    marker and a question right above;
///  * inline `[y/N]`, `(Y/n)`, `(yes/no)` on the last row;
///  * `Press Enter to continue` on the last row.
///
/// Numbered replies send the digit then `enter`: Claude Code and Codex select
/// on the digit alone (the `enter` then lands in an empty input box), other
/// menus only move the highlight (the `enter` confirms). Un-numbered menus
/// are answered by walking the highlight with `up`/`down` then `enter`.
PromptInfo? detectPrompt(List<String> rows) {
  final lines = <String>[];
  for (final raw in rows) {
    final c = cleanPreviewRow(raw);
    if (c != null) lines.add(c);
  }
  if (lines.length > _window) lines.removeRange(0, lines.length - _window);
  if (lines.isEmpty) return null;

  // Hint and key-help rows that Claude Code / Codex draw under a menu.
  var end = lines.length;
  var footer = 0;
  while (end > 1 && footer < 3 && _isFooter(lines[end - 1])) {
    end--;
    footer++;
  }
  final body = lines.sublist(0, end);

  return _numberedMenu(body) ??
      _markerMenu(body) ??
      _inlineYesNo(body) ??
      _enterToContinue(lines);
}

/// A terminal row as shown in a preview: side bars of a box removed,
/// trailing spaces trimmed, `null` when nothing readable is left (blank, or
/// only box-drawing/rule characters). Indentation is kept.
String? cleanPreviewRow(String raw) {
  var t = raw.replaceFirstMapped(_leftBar, (m) => m[1]!);
  t = t.replaceFirst(_rightBar, '').trimRight();
  if (t.isEmpty || _ruleOnly.hasMatch(t)) return null;
  return t;
}

const _window = 12;
const _maxReplies = 9;
const _labelMax = 40;
const _questionMax = 160;

final _leftBar = RegExp(r'^(\s*)[│┃║] ?');
final _rightBar = RegExp(r'\s*[│┃║]\s*$');
final _ruleOnly = RegExp(r'^[\s─━═╭╮╰╯┌┐└┘├┤┬┴┼│┃║╌┄┈\-_=*·•]+$');

// indent, pointer, number, text
final _numbered = RegExp(r'^(\s*)([❯›▶▸➤>→]?)\s*(\d{1,2})[.)]\s+(\S.*)$');
final _strongPointer = RegExp(r'^[❯›▶▸➤→]$');
final _pointerRow = RegExp(r'^(\s*)([❯›▶▸➤])\s*(\S.*)$');
final _radioRow = RegExp(r'^(\s*)([●◉○◯])\s+(\S.*)$');

final _footer = RegExp(
  r'(\besc(ape)?\b|enter to |to navigate|\btab to\b|ctrl\+|shift\+tab|[↑↓]|'
  r'shortcuts|press enter|arrow keys|to select|to cancel|to confirm|to exit)',
  caseSensitive: false,
);

bool _isFooter(String line) =>
    line.length <= 140 && !_numbered.hasMatch(line) && _footer.hasMatch(line);

final _yesNoRe = RegExp(
  r'[\[(]\s*(y(?:es)?)\s*/\s*(n(?:o)?)(?:\s*/\s*\[?fingerprint\]?)?\s*[\])]'
  r'[\s?:]*$',
  caseSensitive: false,
);

final _pressEnterRe = RegExp(
  r'\b(?:press|hit)\s+(?:enter|return|any\s+key)\s+to\s+'
  r'(?:continue|proceed|close|exit|start|begin|dismiss)\b[^a-z]*$',
  caseSensitive: false,
);

final _questionPhrase = RegExp(
  r'^(?:do you want|would you like|are you sure|allow|approve|proceed|'
  r'continue|choose|select|which|what|how|confirm|trust)\b',
  caseSensitive: false,
);

final _destructive = RegExp(
  r'\b(?:rm|rmdir|unlink|drop|mkfs|sudo|delet\w*|remov\w*|truncat\w*|'
  r'forc\w*|wip\w*|destroy\w*|eras\w*|overwrit\w*|purg\w*)\b|--force|-rf\b|'
  r'reset\s+--hard|clean\s+-\w*f|\bdd\s+if=|chmod\s+-R',
  caseSensitive: false,
);

final _negative = RegExp(
  r"^(?:no\b|don.t\b|do not\b|deny\b|denied\b|reject\w*|cancel\w*|abort\w*|"
  r'stop\b|skip\b|never\b|exit\b|quit\b|decline\w*|esc\b)',
  caseSensitive: false,
);

bool _isNegative(String text) => _negative.hasMatch(text.trim());

bool _questionish(String line) {
  final t = line.trim().replaceFirst(RegExp('["\'”’)\\]]+\$'), '');
  return t.endsWith('?') || t.endsWith(':') || _questionPhrase.hasMatch(t);
}

String _cap(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max - 1).trimRight()}…';

// ---------------------------------------------------------------- numbered

PromptInfo? _numberedMenu(List<String> body) {
  // The menu starts at the LAST row numbered 1 whose tail is a clean menu.
  for (var i = body.length - 1; i >= 0; i--) {
    final first = _numbered.firstMatch(body[i]);
    if (first == null || first[3] != '1') continue;
    final options = _parseNumbered(body, i);
    if (options == null) continue;
    return _buildNumbered(body, i, options);
  }
  return null;
}

class _Opt {
  _Opt(this.number, this.text, this.pointer);
  final int number;

  /// The option's own row: what the chip shows.
  final String text;

  /// Wrapped or description rows under it.
  String more = '';
  final String pointer;

  /// Everything said about the option, for the destructive check.
  String get full => '$text $more';
}

/// Options from row [start] to the end, numbered 1..n in order, with
/// indented continuation rows allowed; null if anything else interrupts.
List<_Opt>? _parseNumbered(List<String> body, int start) {
  final out = <_Opt>[];
  var digitColumn = 0;
  var continuation = 0;
  for (var i = start; i < body.length; i++) {
    final m = _numbered.firstMatch(body[i]);
    if (m != null) {
      final n = int.parse(m[3]!);
      if (n != out.length + 1) return null;
      out.add(_Opt(n, m[4]!.trim(), m[2]!));
      digitColumn = body[i].indexOf(m[3]!, m[1]!.length + m[2]!.length);
      continuation = 0;
    } else {
      // A wrapped option or its description: indented under the number.
      final indent = body[i].length - body[i].trimLeft().length;
      if (out.isEmpty || indent <= digitColumn || ++continuation > 3) return null;
      out.last.more = '${out.last.more} ${body[i].trim()}';
    }
  }
  if (out.length < 2 || out.length > _maxReplies) return null;
  return out;
}

PromptInfo? _buildNumbered(List<String> body, int start, List<_Opt> options) {
  final pointers = options.where((o) => o.pointer.isNotEmpty).toList();
  if (pointers.length > 1) return null;
  final strong = pointers.length == 1 && _strongPointer.hasMatch(pointers.single.pointer);
  final above = body.sublist(0, start);
  final question = _questionAbove(above);
  // A bare `>` is also a quote marker: it only counts next to a question.
  if (!strong && question == null) return null;

  final context = above.length > 8 ? above.sublist(above.length - 8) : above;
  final destructive = context.any(_destructive.hasMatch);
  return PromptInfo(
    question: question ?? _cap(above.isEmpty ? '' : above.last.trim(), _questionMax),
    replies: [
      for (final o in options)
        QuickReply(
          label: '${o.number}. ${_shortLabel(o.text)}',
          keys: ['${o.number}', 'enter'],
          needsConfirm: !_isNegative(o.text) &&
              (destructive || _destructive.hasMatch(o.full)),
        ),
    ],
  );
}

/// The question that introduces a menu: the nearest row ending in `?` within
/// six rows above it (else `:` or a typical opening such as "Do you want"),
/// plus the row right above the menu when that is something else (Codex puts
/// the command there).
String? _questionAbove(List<String> above) {
  if (above.isEmpty) return null;
  final from = above.length > 6 ? above.length - 6 : 0;
  int? at;
  for (var i = above.length - 1; i >= from && at == null; i--) {
    if (above[i].trim().endsWith('?')) at = i;
  }
  for (var i = above.length - 1; i >= from && at == null; i--) {
    if (_questionish(above[i])) at = i;
  }
  if (at == null) return null;
  final q = above[at].trim();
  if (at == above.length - 1) return _cap(q, _questionMax);
  return _cap('$q\n${above.last.trim()}', _questionMax * 2);
}

final _trailingHint = RegExp(
  r'\s*\((?:esc|[a-z]|tab|enter|shift\+tab|ctrl\+\w|alt\+\w)\)\s*$',
  caseSensitive: false,
);
final _noAndTell = RegExp(r'^(no),\s+and\s+tell\b.*$', caseSensitive: false);
final _yesDontAsk = RegExp(
  r"^(yes),?\s+and\s+(don.t\s+ask\s+again)\b.*$",
  caseSensitive: false,
);

String _shortLabel(String text) {
  var t = text.replaceFirst(_trailingHint, '').trim();
  t = t.replaceFirstMapped(_noAndTell, (m) => m[1]!);
  t = t.replaceFirstMapped(_yesDontAsk, (m) => "${m[1]}, ${m[2]!.toLowerCase()}");
  return _capAtWord(t, _labelMax - 3);
}

/// [s] cut to [max] characters on a word boundary when one is near.
String _capAtWord(String s, int max) {
  if (s.length <= max) return s;
  var cut = s.substring(0, max - 1);
  final space = cut.lastIndexOf(' ');
  if (space > max ~/ 2) cut = cut.substring(0, space);
  return '${cut.trimRight()}…';
}

// --------------------------------------------------------- un-numbered menu

/// A question row: ends in `?` or `:` (stricter than [_questionish]).
bool _isQuestionRow(String line) {
  final t = line.trim();
  return t.endsWith('?') || t.endsWith(':');
}

PromptInfo? _markerMenu(List<String> body) =>
    _radioMenu(body) ?? _pointerMenu(body);

/// Short enough to be a choice rather than prose.
bool _choiceLength(String line) => line.trim().length <= 60;

PromptInfo? _pointerMenu(List<String> body) {
  // The pointed row is within the last few rows; its siblings share its
  // text column and run to the very end.
  for (var p = body.length - 1; p >= 0 && p >= body.length - _maxReplies; p--) {
    final m = _pointerRow.firstMatch(body[p]);
    if (m == null) continue;
    if (!_choiceLength(body[p])) return null;
    final column = body[p].indexOf(m[3]!, m[1]!.length + m[2]!.length);
    bool sibling(int i) =>
        _choiceLength(body[i]) &&
        !_isQuestionRow(body[i]) &&
        body[i].length - body[i].trimLeft().length == column;
    for (var i = p + 1; i < body.length; i++) {
      if (!sibling(i)) return null;
    }
    var start = p;
    while (start > 0 && sibling(start - 1)) {
      start--;
    }
    final texts = [
      for (var i = start; i < body.length; i++)
        i == p ? m[3]!.trim() : body[i].trim(),
    ];
    return _arrowMenu(body, start, texts, p - start);
  }
  return null;
}

PromptInfo? _radioMenu(List<String> body) {
  var start = body.length;
  var selected = -1;
  final texts = <String>[];
  while (start > 0 && texts.length <= _maxReplies) {
    final m = _radioRow.firstMatch(body[start - 1]);
    if (m == null || !_choiceLength(body[start - 1])) break;
    start--;
    texts.insert(0, m[3]!.trim());
    if (m[2] == '●' || m[2] == '◉') {
      if (selected != -1) return null;
      selected = body.length - 1 - start;
    }
  }
  if (selected == -1) return null;
  // `selected` was counted from the bottom; make it an index into [texts].
  return _arrowMenu(body, start, texts, texts.length - 1 - selected);
}

/// A menu answered with up/down to the wanted row, then enter. Needs a
/// question row right above it.
PromptInfo? _arrowMenu(
  List<String> body,
  int start,
  List<String> texts,
  int selected,
) {
  if (texts.length < 2 || texts.length > _maxReplies) return null;
  if (start == 0 || !_isQuestionRow(body[start - 1])) return null;
  final context = body.sublist(start > 8 ? start - 8 : 0, start);
  final destructive = context.any(_destructive.hasMatch);
  return PromptInfo(
    question: _cap(body[start - 1].trim(), _questionMax),
    replies: [
      for (var k = 0; k < texts.length; k++)
        QuickReply(
          label: _shortLabel(texts[k]),
          keys: [
            ...List.filled((k - selected).abs(), k > selected ? 'down' : 'up'),
            'enter',
          ],
          needsConfirm:
              !_isNegative(texts[k]) && (destructive || _destructive.hasMatch(texts[k])),
        ),
    ],
  );
}

// ------------------------------------------------------------ inline prompts

PromptInfo? _inlineYesNo(List<String> lines) {
  final last = lines.last;
  if (last.length > 200) return null;
  final m = _yesNoRe.firstMatch(last);
  if (m == null) return null;
  final full = m[1]!.toLowerCase() == 'yes';
  final context = lines.length > 1
      ? lines.sublist(lines.length > 7 ? lines.length - 7 : 0, lines.length - 1)
      : const <String>[];
  final destructive = _destructive.hasMatch(last) || context.any(_destructive.hasMatch);
  final prev = lines.length > 1 ? lines[lines.length - 2].trim() : '';
  // A short "Continue? [y/N]" is meaningless without the row that says what.
  final question = last.trim().length < 40 && prev.isNotEmpty
      ? '$prev\n${last.trim()}'
      : last.trim();
  return PromptInfo(
    question: _cap(question, _questionMax * 2),
    replies: [
      QuickReply(
        label: 'Yes',
        keys: [...(full ? ['y', 'e', 's'] : ['y']), 'enter'],
        needsConfirm: destructive,
      ),
      QuickReply(label: 'No', keys: [...(full ? ['n', 'o'] : ['n']), 'enter']),
    ],
  );
}

PromptInfo? _enterToContinue(List<String> lines) {
  final last = lines.last;
  if (last.length > 160 || !_pressEnterRe.hasMatch(last)) return null;
  if (RegExp(r'esc|cancel', caseSensitive: false).hasMatch(last)) return null;
  return PromptInfo(
    question: _cap(last.trim(), _questionMax),
    replies: const [QuickReply(label: 'Enter', keys: ['enter'])],
  );
}
