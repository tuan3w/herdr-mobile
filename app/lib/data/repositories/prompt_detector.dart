import '../models/pane_preview.dart';
import 'command_risk.dart';

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
///
/// What the question is about goes into `PromptInfo.subject`: Claude Code's
/// command block (the rows indented under a short header, above "Do you want
/// to proceed?"), Codex's command row (between its question and the menu) and,
/// for any menu with no such block, the row above the question when it is what
/// made the question risky (it may as well be scrollback otherwise). What is
/// shown is in the digest, so the card and a notification's button cover it.
/// A reply that needs a second tap carries the reason in `QuickReply.risk`,
/// judged by `command_risk.dart` on the subject, the question, the row above
/// the question and the option's own text; never on the scrollback around.
/// The subject is read whole for risk, however much of it is shown: when a row
/// or the row count had to be cut (`…`), or the 12-row window dropped the rows
/// above a block that runs to its top, the affirmative answers also ask for a
/// second tap ([longCommand]) unless a more specific reason applies.
PromptInfo? detectPrompt(List<String> rows) {
  var lines = <String>[];
  for (final raw in rows) {
    final c = cleanPreviewRow(raw);
    if (c != null) lines.add(c);
  }
  lines = _withoutDashedRules(lines);
  // The window drops the older rows: a block of rows that runs to the top of
  // what is left may go on above it (see [_subjectAbove]).
  final scrolled = lines.length > _window;
  if (scrolled) lines.removeRange(0, lines.length - _window);
  if (lines.isEmpty) return null;

  // Hint and key-help rows that Claude Code / Codex draw under a menu.
  var end = lines.length;
  var footer = 0;
  while (end > 1 && footer < 3 && _isFooter(lines[end - 1])) {
    end--;
    footer++;
  }
  final body = lines.sublist(0, end);

  return _numberedMenu(body, scrolled) ??
      _markerMenu(body, scrolled) ??
      _inlineYesNo(body) ??
      _enterToContinue(lines);
}

/// A terminal row as shown in a preview: side bars of a box removed,
/// trailing spaces trimmed, `null` when nothing readable is left (blank, or
/// only box-drawing/rule characters). Indentation is kept.
String? cleanPreviewRow(String raw) {
  var t = raw.replaceFirstMapped(_leftBar, (m) => m[1]!);
  t = t.replaceFirst(_rightBar, '').trimRight();
  // A rule is a whole row of them with no bar: a row of a multi-line command
  // that is only dashes (drawn behind ` │ `) is the command's, not a rule.
  if (_dashedRule.hasMatch(raw.trim()) || raw == dashedRuleRow) return dashedRuleRow;
  if (t.isEmpty || _ruleOnly.hasMatch(t)) return null;
  return t;
}

/// What a dashed rule (`╌╌╌`) cleans to. Claude Code draws the command of a
/// permission dialog between two of them, under a description that is not part
/// of it: [detectPrompt] needs them to tell the command from the rows around.
/// Every other rule is dropped. This row is never shown (see [isDashedRule]).
const dashedRuleRow = '\uE000rule\uE000';

final _dashedRule = RegExp(r'^[╌┄┈]{20,}$');

/// Whether [row] is the stand-in of a dashed rule: a preview leaves it out.
bool isDashedRule(String row) => row == dashedRuleRow;

/// A title row of a dialog about a command (`Bash command`, `Bash command ·
/// from the general-purpose agent`).
final _commandHeader = RegExp(r'^[A-Z][A-Za-z ]{1,24}?(?:\s+·\s+.*)?$');

/// The header of a dialog about a file: its two rules hold a diff or the new
/// content, which is not a command.
final _fileHeader = RegExp(
  r'^\s*(?:edit|create|overwrite|update|delete|read|write)\s+(?:file|notebook)s?(?:\s+·.*)?\s*$',
  caseSensitive: false,
);

/// [lines] without the dashed rules. Claude Code's dialog about a command is
/// drawn as
///
/// ```
///  Bash command
///  Tip: ...                       (sometimes)
///  <the description>
///  ╌╌╌╌╌╌╌╌
///  <the command>
///  ╌╌╌╌╌╌╌╌
///  This command requires approval    (sometimes)
///  Do you want to proceed?
/// ```
///
/// The command becomes the block the rest of the detector reads (rows indented
/// under the header, the description and the tip left out); a dialog about a
/// file, or one that does not look like this, only loses its rules.
List<String> _withoutDashedRules(List<String> lines) {
  List<String> plain() => [for (final l in lines) if (!isDashedRule(l)) l];
  final marks = [for (var i = 0; i < lines.length; i++) if (isDashedRule(lines[i])) i];
  if (marks.isEmpty) return lines;
  if (marks.length < 2) return plain();
  final a = marks[marks.length - 2];
  final b = marks.last;
  // The question, or a note ("This command requires approval") and then it.
  var q = b + 1;
  if (q + 1 < lines.length && !_questionish(lines[q]) && _questionish(lines[q + 1])) q++;
  if (b - a < 2 || q >= lines.length || !_questionish(lines[q])) return plain();
  for (var i = a - 1; i >= 0 && i >= a - 3; i--) {
    if (_fileHeader.hasMatch(lines[i])) return plain();
  }
  var header = -1;
  for (var i = a - 1; i >= 0 && i >= a - 3; i--) {
    final t = lines[i].trim();
    if (_commandHeader.hasMatch(t) && !t.endsWith('.') && !t.contains('?')) {
      header = i;
      break;
    }
  }
  if (header < 0) return plain();
  return [
    for (var i = 0; i < header; i++)
      if (!isDashedRule(lines[i])) lines[i],
    // "Bash command · from the general-purpose agent": the title is the part
    // before the dot (a title row is short, see [_isHeader]).
    lines[header].split(' · ').first,
    for (var i = a + 1; i < b; i++) '  ${lines[i]}',
    ...lines.sublist(q),
  ];
}

const _window = 12;
const _maxReplies = 9;
const _labelMax = 40;
const _questionMax = 160;
const _subjectRows = 6;
const _subjectRowMax = 160;

/// Starts a transcript row (a tool call, its output, a prompt), never a title.
final _marker = RegExp(r'^[●⏺⎿└├│>$#✻✔✘]');

final _leftBar = RegExp(r'^(\s*)[│┃║] ?');
final _rightBar = RegExp(r'\s*[│┃║]\s*$');
final _ruleOnly = RegExp(r'^[\s─━═╭╮╰╯┌┐└┘├┤┬┴┼│┃║╌┄┈\-_=*·•]+$');

// indent, pointer, number, text
final _numbered = RegExp(r'^(\s*)([❯›▶▸➤>→]?)\s*(\d{1,2})[.)]\s+(\S.*)$');
final _codexQuestionHeader = RegExp(r'^\s*Question (\d+)/(\d+)\b');
final _strongPointer = RegExp(r'^[❯›▶▸➤→]$');
final _pointerRow = RegExp(r'^(\s*)([❯›▶▸➤])\s*(\S.*)$');
final _radioRow = RegExp(r'^(\s*)([●◉○◯])\s+(\S.*)$');
final _checkbox = RegExp(r'^[☐☑☒]');

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

final _negative = RegExp(
  r"^(?:no\b|not now\b|not yet\b|maybe later\b|remind me\b|later\b|don.t\b|do not\b|"
  r'deny\b|denied\b|reject\w*|cancel\w*|abort\w*|stop\b|skip\b|never\b|exit\b|'
  r'quit\b|decline\w*|esc\b)',
  caseSensitive: false,
);

bool _isNegative(String text) => _negative.hasMatch(text.trim());

/// Whether [reply] declines: its label, without the number in front, starts
/// as a refusal does ("No", "Deny", "Cancel"). The observed chat shows such a
/// reply as a rejection and every other one as an allow.
bool isNegativeReply(QuickReply reply) =>
    _isNegative(reply.label.replaceFirst(RegExp(r'^\s*\d{1,2}[.)]\s*'), ''));

bool _questionish(String line) {
  final t = line.trim().replaceFirst(RegExp('["\'”’)\\]]+\$'), '');
  return t.endsWith('?') || t.endsWith(':') || _questionPhrase.hasMatch(t);
}

String _cap(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max - 1).trimRight()}…';

// ---------------------------------------------------------------- numbered

PromptInfo? _numberedMenu(List<String> body, bool scrolled) {
  // The menu starts at the LAST row numbered 1 whose tail is a clean menu.
  for (var i = body.length - 1; i >= 0; i--) {
    final first = _numbered.firstMatch(body[i]);
    if (first == null || first[3] != '1') continue;
    final options = _parseNumbered(body, i);
    if (options == null) continue;
    return _buildNumbered(body, i, options, scrolled);
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

  /// Everything said about the option, for the risk check.
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

PromptInfo? _buildNumbered(List<String> body, int start, List<_Opt> options, bool scrolled) {
  // Claude Code's question tool (a `Chat about this` row): its rows toggle
  // boxes and type text, which no reply of a card can say. It is answered by
  // the question driver from the log, or in the terminal.
  if (options.any((o) => o.text.startsWith('Chat about this'))) return null;
  final pointers = options.where((o) => o.pointer.isNotEmpty).toList();
  if (pointers.length > 1) return null;
  final strong = pointers.length == 1 && _strongPointer.hasMatch(pointers.single.pointer);
  final above = body.sublist(0, start);
  final at = _questionRowAbove(above);
  // A bare `>` is also a quote marker: it only counts next to a question.
  if (!strong && at == null) return null;

  // Without a question, a strong pointer still makes a menu: the row above
  // stands in for the question.
  final q = at ?? above.length - 1;
  final block = at == null
      ? const <String>[]
      : at == above.length - 1
          ? _subjectAbove(above, at)
          // Codex: the command is the rows between the question and the menu,
          // after its `Environment:` / `Reason:` rows.
          : _rowsAfterReason(above, at);
  // Codex's question tool ("Question 1/2" above the question): the digit
  // selects, and on the last question submits; with more questions to come an
  // `enter` after it would answer the next one with its first option.
  final header = at != null && at > 0 ? _codexQuestionHeader.firstMatch(above[at - 1]) : null;
  final digitOnly = header != null;
  // A row that is a place to type feedback ("Tell Claude what to change") is
  // not an answer a tap can give.
  final offered = [for (final o in options) if (!_needsTyping.hasMatch(o.text)) o];
  if (offered.length < 2) return null;
  final prompt = _promptOf(
    body: above,
    q: q,
    block: block,
    scrolled: scrolled,
    replies: (reason, cut) => [
      for (final o in offered)
        _quickReply(
          label: '${o.number}. ${_shortLabel(o.text)}',
          keys: digitOnly ? ['${o.number}'] : ['${o.number}', 'enter'],
          optionText: o.full,
          negativeText: o.text,
          scopeRisk: reason,
          cutRisk: cut ? longCommand : null,
        ),
    ],
  );
  // Which question of the form this is: the card is one at a time.
  if (header == null) return prompt;
  return PromptInfo(
    question: _cap('${header[1]} of ${header[2]} · ${prompt.question}', _questionMax),
    subject: prompt.subject,
    replies: prompt.replies,
  );
}

/// A reply that opens a field for the person's own words: it cannot be given by
/// a tap (`Tell Claude what to change`, `Yes, and tell Claude what to do next`).
final _needsTyping = RegExp(r'^(?:tell\b|yes,? and tell\b)', caseSensitive: false);

final _reasonRow = RegExp(r'^\s*(?:Environment|Reason|Description|Permissions?|Working directory):');

/// The rows under the question at [q] that are the command: all of them, after
/// the last row that gives a reason or an environment; the last row when that
/// leaves none.
List<String> _rowsAfterReason(List<String> above, int q) {
  var from = q + 1;
  for (var i = q + 1; i < above.length; i++) {
    if (_reasonRow.hasMatch(above[i])) from = i + 1;
  }
  return from < above.length ? above.sublist(from) : [above.last];
}

/// The question at row [q] of [body] with what it is about, and its replies
/// (given the scope reason and whether the subject was cut).
///
/// [block] is the rows drawn under a header or between the question and the
/// menu, read as a command, all of it (the cut that keeps the card short must
/// not hide a dangerous tail). Without one, the row above the question is read
/// as a command or a sentence, and shown when it flags something ([_rowAbove]).
/// [scrolled]: the 12-row window dropped older rows, so a block that runs to
/// the top of it was cut.
PromptInfo _promptOf({
  required List<String> body,
  required int q,
  required List<String> block,
  required bool scrolled,
  required List<QuickReply> Function(String? reason, bool cut) replies,
}) {
  final subject = block.isNotEmpty ? block : _rowAbove(body, q);
  final reason = _scopeRisk(
    commands: block,
    sentences: [
      if (q >= 0) body[q],
      if (block.isEmpty && q > 0) body[q - 1],
    ],
  );
  final topCut = scrolled && block.isNotEmpty && q - block.length == 0;
  return PromptInfo(
    question: q < 0 ? '' : _cap(body[q].trim(), _questionMax),
    subject: _subjectText(subject),
    replies: replies(reason, topCut || _isCut(subject)),
  );
}

/// The row right above the question at [q] when it is what made the question
/// risky and is no deeper than the question: a command or a sentence drawn as
/// part of the prompt, so the card shows the reason's cause and the digest
/// tells `rm -rf x` from `rm -rf y`. A row that flags nothing is not shown:
/// there it may as well be the scrollback (a tab title, a log line), which
/// would put noise on every card and change the digest as it scrolls. One
/// deeper than the question is the output of something else (a diff above an
/// edit dialog); it is judged, and its reason shows, but it is not the subject.
List<String> _rowAbove(List<String> body, int q) {
  if (q <= 0 || _indent(body[q - 1]) > _indent(body[q])) return const [];
  final row = body[q - 1];
  return _scopeRisk(commands: [row], sentences: [row]) == null ? const [] : [row];
}

/// Why a second tap is needed when the subject could not be shown whole.
const longCommand = 'long command, check it all';

/// The first reason in [commands] (read as commands) or [sentences] (as a
/// command, else as a sentence): a command reason anywhere wins over prose.
String? _scopeRisk({List<String> commands = const [], required List<String> sentences}) =>
    commandRisk([...commands, ...sentences].join('\n')) ?? proseRisk(sentences.join('\n'));

/// The subject as shown: at most [_subjectRows] rows of [_subjectRowMax]
/// characters, every cut marked with `…` so the card never claims to be whole.
String _subjectText(List<String> rows) {
  final shown = [for (final row in rows.take(_subjectRows)) _shownRow(row)];
  if (rows.length > _subjectRows && !shown.last.endsWith('…')) {
    shown[shown.length - 1] = _cap('${shown.last}…', _subjectRowMax);
  }
  return shown.join('\n');
}

String _shownRow(String row) {
  final t = row.trim();
  if (t.length > _subjectRowMax) return _cap(t, _subjectRowMax);
  return _rowCut(row) ? _cap('$t…', _subjectRowMax) : t;
}

/// The pane previews cut every row at this many characters, indentation
/// included, without a mark.
const _previewRowMax = 160;

/// A row (untrimmed) that is longer than shown, or about as long as the
/// previews allow, which means it was probably cut there (a box's side bars
/// were already taken off it).
bool _rowCut(String row) =>
    row.trim().length > _subjectRowMax || row.length >= _previewRowMax - 4;

/// Whether [rows] (untrimmed) hold more than [_subjectText] shows.
bool _isCut(List<String> rows) => rows.length > _subjectRows || rows.any(_rowCut);

/// A reply with the reason it needs a second tap, if any. In order: a
/// permission that outlives this answer, then [scopeRisk] (what the question
/// is about), then the option's own words, then [cutRisk] (the subject was cut
/// and may hide something). A negative option never carries one: declining is
/// always safe. [negativeText] is the option's own row when [optionText] also
/// holds wrapped rows.
QuickReply _quickReply({
  required String label,
  required List<String> keys,
  required String optionText,
  required String? scopeRisk,
  String? negativeText,
  String? cutRisk,
}) {
  final risk = _isNegative(negativeText ?? optionText)
      ? null
      : grantsStandingPermission(optionText)
          ? standingPermission
          : scopeRisk ?? riskOf(optionText) ?? cutRisk;
  return QuickReply(label: label, keys: keys, needsConfirm: risk != null, risk: risk);
}

/// Index of the row that introduces a menu: the nearest row ending in `?`
/// within six rows above it (else `:` or a typical opening such as "Do you
/// want"); null when there is none.
int? _questionRowAbove(List<String> above) {
  final from = above.length > 6 ? above.length - 6 : 0;
  for (var i = above.length - 1; i >= from; i--) {
    if (above[i].trim().endsWith('?')) return i;
  }
  for (var i = above.length - 1; i >= from; i--) {
    if (_questionish(above[i])) return i;
  }
  return null;
}

int _indent(String row) => row.length - row.trimLeft().length;

/// The rows drawn right above the question at [q], indented deeper than it
/// (Claude Code: the command and its description under "Bash command"), all of
/// them. Empty when there are none, or when the row above them does not look
/// like a header (then they are some other output); the block may also run
/// to the top of the visible rows, its header scrolled out, and then it may
/// go on above them too (see [_promptOf] on `scrolled`).
List<String> _subjectAbove(List<String> above, int q) {
  final indent = _indent(above[q]);
  var top = q;
  while (top > 0 && _indent(above[top - 1]) > indent) {
    top--;
  }
  if (top == q) return const [];
  if (top > 0 && !_isHeader(above[top - 1], indent)) return const [];
  return [for (var i = top; i < q; i++) above[i]];
}

/// A short title row ("Bash command", "Tool use", "Fetch"): not deeper than
/// the question, no sentence, no question and no transcript marker.
bool _isHeader(String row, int questionIndent) {
  final t = row.trim();
  return _indent(row) <= questionIndent &&
      t.length <= 30 &&
      !t.contains('?') &&
      !t.endsWith('.') &&
      !t.endsWith(':') &&
      !_marker.hasMatch(t);
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
  // Codex's question rows pad the label and its description into columns, and
  // tell about notes the phone cannot add.
  var t = text.replaceFirst(RegExp(r'\s+Optionally, add details in notes \(tab\)\.?'), '').replaceFirst(_trailingHint, '').trim();
  t = t.replaceAll(RegExp(r'\s{2,}'), ' · ');
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

PromptInfo? _markerMenu(List<String> body, bool scrolled) =>
    _radioMenu(body, scrolled) ?? _pointerMenu(body, scrolled);

/// Short enough to be a choice rather than prose.
bool _choiceLength(String line) => line.trim().length <= 60;

PromptInfo? _pointerMenu(List<String> body, bool scrolled) {
  // The pointed row is within the last few rows; its siblings share its
  // text column and run to the very end.
  for (var p = body.length - 1; p >= 0 && p >= body.length - _maxReplies; p--) {
    final m = _pointerRow.firstMatch(body[p]);
    if (m == null) continue;
    // A checkbox list (omp's multi-select question) is answered with space to
    // tick and enter to go on; a row's keys here would only go on.
    if (_checkbox.hasMatch(m[3]!)) return null;
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
    return _arrowMenu(body, start, texts, p - start, scrolled);
  }
  return null;
}

PromptInfo? _radioMenu(List<String> body, bool scrolled) {
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
  return _arrowMenu(body, start, texts, texts.length - 1 - selected, scrolled);
}

/// A menu answered with up/down to the wanted row, then enter. Needs a
/// question row right above it.
PromptInfo? _arrowMenu(
  List<String> body,
  int start,
  List<String> texts,
  int selected,
  bool scrolled,
) {
  if (texts.length < 2 || texts.length > _maxReplies) return null;
  if (start == 0 || !_isQuestionRow(body[start - 1])) return null;
  // The question and what it is about (rows under a header, else the row
  // above it: a tool name, a command) are read as a command or a sentence and
  // shown; each option is judged on its own text.
  return _promptOf(
    body: body,
    q: start - 1,
    block: _subjectAbove(body, start - 1),
    scrolled: scrolled,
    replies: (reason, cut) => [
      for (var k = 0; k < texts.length; k++)
        _quickReply(
          label: _shortLabel(texts[k]),
          keys: [
            ...List.filled((k - selected).abs(), k > selected ? 'down' : 'up'),
            'enter',
          ],
          optionText: texts[k],
          scopeRisk: reason,
          cutRisk: cut ? longCommand : null,
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
  final prev = lines.length > 1 ? lines[lines.length - 2].trim() : '';
  // The last row and the one before it: what the question says and what it
  // refers to. Only Yes can carry a reason.
  final reason = riskOf(last) ?? (prev.isEmpty ? null : riskOf(prev));
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
        needsConfirm: reason != null,
        risk: reason,
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
