import 'observed_contracts.dart';
import 'omp_ask_driver.dart' show AskDone, AskMismatch, AskSend, AskStep;

/// Answers Claude Code's question tool (`AskUserQuestion`) by KEYS, from what
/// the pane shows, with the same protocol as the omp driver: [next] reads a
/// screen and gives the ONE next thing to send; the caller sends it, reads the
/// pane again and asks again, until [AskDone].
///
/// Claude Code 2.1.29x draws the tool in the pane, under the transcript
/// (captured in `test/fixtures/prompts/claude/askfull-*`):
///
/// ```
/// ─────────────────────────────────────────────
///  ☐ Lang  ☒ Extras  ✔ Submit  →         tab strip (a lone single-choice question
///                                        has only ` ☐ Color`; ☒ = answered)
/// Which language do I prefer?            the question
///
/// ❯ 1. Python                            ❯ marks the cursor row
///      Python as your preferred language
///   2. Go ✔                              ✔ after the label: answered with it
///   3. Rust
///   4. Type something.                   the Other row: typing goes in the row
/// ─────────────────────────────────────────────
///   5. Chat about this
/// Enter to select · Tab/Arrow keys to navigate · Esc to cancel
/// ```
///
/// A multi-select question shows `1. [ ] Apple` rows, `5. [ ] Type something`
/// and an unnumbered `Submit` row before the rule. After the last question
/// comes the review tab: `Review your answers`, a `● question` / `→ answer` pair
/// per question, `Ready to submit your answers?`, `1. Submit answers`,
/// `2. Cancel`.
///
/// Keys (observed on Claude Code 2.1.293 and 2.1.295, see the findings of the
/// capture):
///
/// | key | where | effect |
/// | --- | --- | --- |
/// | `up` / `down` | any tab | cursor one row; clamped at the ends (`up` from row 1 may wrap) |
/// | `enter` | single choice, on an option | select it; a lone question submits, a form goes to the next tab |
/// | `enter` | multi-select, on an option | toggle its checkbox |
/// | `enter` | on the Other row with text | single choice: submits it (form: next tab); multi: toggles the box |
/// | digit | an option row (cursor not on the Other row) | the same as moving there and `enter`; on the Other row a digit is TEXT |
/// | typed text | on the Other row | edits the row in place (a multi-select box checks itself) |
/// | `right` / `left` | any tab | next / previous tab; `right` from the last question goes to the review |
/// | `1` / `enter` on row 1 | review | submit (all questions) |
/// | `2` / `esc` | review / anywhere | cancel: the tool call is declined |
///
/// The screen is the truth: nothing is assumed about where the cursor, the tab
/// or the checkboxes were, so a key that did not land only costs another
/// round. The driver remembers which questions it has answered in this attempt
/// and counters that stop an endless loop.
class ClaudeAskDriver {
  ClaudeAskDriver(this.ask, this.answers, {this.maxSteps = 60})
    : assert(answers.length == ask.questions.length, 'one answer per question');

  final PendingAsk ask;
  final List<AskAnswer> answers;

  /// Steps after which the driver gives up ([AskMismatch]).
  final int maxSteps;

  int _steps = 0;
  int _repeats = 0;
  String? _lastPrint;
  bool _lastWasSend = false;

  /// Questions this attempt has sent the answer of.
  final _sent = <int>{};
  final _revisits = <int, int>{};

  /// The next step for [screen].
  AskStep next(String screen) {
    final s = parseClaudeAsk(screen);
    final step = _plan(s);
    if (step is AskSend) {
      if (++_steps > maxSteps) return const AskMismatch('too many steps');
      _repeats = _lastWasSend && _lastPrint == s.fingerprint ? _repeats + 1 : 0;
      if (_repeats >= 2) return const AskMismatch('the dialog did not react to the keys');
      _lastPrint = s.fingerprint;
      _lastWasSend = true;
    } else {
      _lastWasSend = false;
    }
    return step;
  }

  AskStep _plan(ClaudeAskScreen s) {
    if (s.kind == ClaudeAskKind.none) return const AskDone();
    final qs = ask.questions.length;
    if (s.tabs.isNotEmpty && s.tabs.length != qs) {
      return AskMismatch('${s.tabs.length} tabs on screen, $qs questions asked');
    }
    return s.kind == ClaudeAskKind.review ? _review(s) : _question(s);
  }

  // -- the review tab ----------------------------------------------------------

  AskStep _review(ClaudeAskScreen s) {
    final n = ask.questions.length;
    // Everything on it must be what the person answered, in order of asking.
    for (var i = 0; i < n; i++) {
      final shown = s.reviewAnswerOf(ask.questions[i].question);
      final want = expectedAnswer(ask.questions[i], answers[i]);
      if (shown != null && _sameAnswer(shown, want)) continue;
      // Not answered, or answered otherwise: back to that question.
      if ((_revisits[i] = (_revisits[i] ?? 0) + 1) > 2) {
        return AskMismatch('question ${i + 1} would not take its answer');
      }
      _sent.remove(i);
      return AskSend(keys: List.filled(n - i, 'left'), why: 'back to question ${i + 1}');
    }
    // Digit 1 submits at once, wherever the cursor is.
    return const AskSend(keys: ['1'], submits: true, why: 'submit the answers');
  }

  // -- a question tab ----------------------------------------------------------

  /// The index of the question [s] shows: the only one of a lone question, else
  /// the one whose text is the title.
  int? _which(ClaudeAskScreen s) {
    final qs = ask.questions;
    if (s.tabs.isEmpty && qs.length == 1 && s.title.isEmpty) return 0;
    final hits = [
      for (var i = 0; i < qs.length; i++)
        if (_same(s.title, qs[i].question)) i,
    ];
    return hits.length == 1 ? hits.single : null;
  }

  AskStep _question(ClaudeAskScreen s) {
    final i = _which(s);
    if (i == null) return const AskMismatch('the question on screen is not the one asked');
    final q = ask.questions[i];
    final a = answers[i];
    final lone = s.tabs.length <= 1 && ask.questions.length == 1 && !q.multi;
    final n = q.options.length;
    // Rows 1..n are the options, n+1 is Other: anything else is a dialog this
    // driver does not know.
    if (s.options.length != n + 1) return AskMismatch('${s.options.length - 1} options on screen, $n asked');
    for (var k = 0; k < n; k++) {
      if (!_labelMatches(s.options[k].label, q.options[k].label)) {
        return AskMismatch('option ${k + 1} on screen is not "${q.options[k].label}"');
      }
    }
    final custom = a.custom?.trim() ?? '';
    final other = s.options[n];
    // 1-based among the rows the arrows visit: the options, Other, the Submit
    // row of a multi-select, `Chat about this`.
    final cursor = s.cursorNumber;
    if (cursor == null) return const AskMismatch('the cursor is not on a row of the dialog');

    List<String> moveTo(int row) =>
        cursor == row ? const [] : List.filled((row - cursor).abs(), row > cursor ? 'down' : 'up');

    if (q.multi) {
      final want = {...a.selected};
      for (var k = 0; k < n; k++) {
        if (s.options[k].checked != want.contains(k)) {
          return AskSend(keys: [...moveTo(k + 1), 'enter'], why: 'toggle ${q.options[k].label}');
        }
      }
      if (custom.isNotEmpty) {
        if (!(other.checked && _same(other.label, custom))) {
          if (cursor != n + 1) return AskSend(keys: moveTo(n + 1), why: 'to the Other row');
          if (_isPlaceholder(other.label)) return AskSend(text: custom, why: 'type the other answer');
          return const AskMismatch('the Other row holds other text');
        }
      } else if (other.checked) {
        return AskSend(keys: [...moveTo(n + 1), 'enter'], why: 'uncheck the Other row');
      }
      return _advance(s, i, onOtherRow: cursor == n + 1);
    }

    // A single choice.
    if (custom.isNotEmpty) {
      if (_same(other.label, custom)) {
        if (cursor != n + 1) return AskSend(keys: moveTo(n + 1), why: 'to the Other row');
        _sent.add(i);
        return AskSend(keys: const ['enter'], submits: lone, why: 'submit the other answer');
      }
      if (cursor != n + 1) return AskSend(keys: moveTo(n + 1), why: 'to the Other row');
      if (_isPlaceholder(other.label)) return AskSend(text: custom, why: 'type the other answer');
      return const AskMismatch('the Other row holds other text');
    }
    if (a.selected.length != 1 || a.selected.single < 0 || a.selected.single >= n) {
      return AskMismatch('question ${i + 1} needs exactly one option');
    }
    final k = a.selected.single;
    // Already answered with it (the tab strip says so and the row is marked):
    // on to the next tab.
    if (_sent.contains(i) && s.tabAnswered(i) && s.options[k].marked) return _advance(s, i, onOtherRow: cursor == n + 1);
    // Sent but the dialog did not take it: ask again.
    _sent.remove(i);
    _sent.add(i);
    return AskSend(keys: [...moveTo(k + 1), 'enter'], submits: lone, why: 'choose ${q.options[k].label}');
  }

  /// Goes on from a finished question to the next tab (the review after the
  /// last), off the Other row first: there the arrow keys may move the text
  /// cursor.
  AskStep _advance(ClaudeAskScreen s, int i, {required bool onOtherRow}) {
    _sent.add(i);
    if (onOtherRow) return const AskSend(keys: ['up'], why: 'off the Other row');
    return const AskSend(keys: ['right'], why: 'next tab');
  }
}

// -------------------------------------------------------------- answer text

/// What the dialog shows (and the tool result says) for [a] to [q]: the label of
/// the chosen option; for several, the labels in order, joined with a comma; the
/// custom text instead of an option on a single choice, after the labels on a
/// multi-select.
String expectedAnswer(AskQuestion q, AskAnswer a) {
  final custom = a.custom?.trim() ?? '';
  final labels = [
    for (final k in ([...a.selected]..sort()))
      if (k >= 0 && k < q.options.length) q.options[k].label,
  ];
  if (!q.multi) return custom.isNotEmpty ? custom : (labels.isEmpty ? '' : labels.first);
  return [...labels, if (custom.isNotEmpty) custom].join(', ');
}

String _flat(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

bool _same(String a, String b) => _flat(a) == _flat(b);

/// [shown] is [want], or its start when the row cut it with `…`.
bool _sameAnswer(String shown, String want) {
  final s = _flat(shown);
  final w = _flat(want);
  if (s == w) return true;
  return s.endsWith('…') && w.startsWith(s.substring(0, s.length - 1));
}

/// A label on screen is the label asked: the same, or its start when a long one
/// was wrapped (only the first row is read).
bool _labelMatches(String shown, String want) {
  final s = _flat(shown);
  final w = _flat(want);
  return s == w || (s.isNotEmpty && w.startsWith(s)) || (w.isNotEmpty && s.startsWith(w));
}

bool _isPlaceholder(String label) => _flat(label).toLowerCase().startsWith('type something');

/// Whether the tool result [output] Claude recorded says what the person
/// answered: `... "<question>"="<answer>" ...` for every question (Claude words
/// the lead-in two ways, `Your questions have been answered:` and `The user
/// answered:`).
bool claudeAskResultMatches(String? output, PendingAsk ask, List<AskAnswer> answers) {
  if (output == null || answers.length != ask.questions.length || answers.isEmpty) return false;
  final text = _flat(output);
  for (final (i, q) in ask.questions.indexed) {
    final pair = '"${_flat(q.question)}"="${_flat(expectedAnswer(q, answers[i]))}"';
    if (!text.contains(pair)) return false;
  }
  return true;
}

// ------------------------------------------------------------- screen model

enum ClaudeAskKind { none, question, review }

/// One option row as drawn.
class ClaudeAskRow {
  const ClaudeAskRow({required this.number, required this.label, required this.cursor, required this.checked, required this.marked});

  final int number;

  /// The first row of the label, without the checkbox and the answered mark.
  final String label;
  final bool cursor;

  /// `[✔]` of a multi-select row.
  final bool checked;

  /// `✔` after the label of a single choice: the answer given earlier.
  final bool marked;
}

/// One tab of the strip: the question's header and whether it is answered.
class ClaudeAskTab {
  const ClaudeAskTab(this.label, this.answered);

  final String label;
  final bool answered;
}

/// What [parseClaudeAsk] read from a screen.
class ClaudeAskScreen {
  const ClaudeAskScreen({
    required this.kind,
    this.tabs = const [],
    this.title = '',
    this.options = const [],
    this.cursorNumber,
    this.cursorOnSubmit = false,
    this.review = const [],
    this.fingerprint = '',
  });

  static const none = ClaudeAskScreen(kind: ClaudeAskKind.none);

  final ClaudeAskKind kind;

  /// The questions' tabs (the `Submit` tab is not one); empty without a strip.
  final List<ClaudeAskTab> tabs;
  final String title;

  /// The numbered rows, the Other row last; empty on the review tab.
  final List<ClaudeAskRow> options;

  /// The number of the row the cursor is on among the numbered rows and `Chat
  /// about this`; null when it is on the multi-select `Submit` row.
  final int? cursorNumber;
  final bool cursorOnSubmit;

  /// `(question, answer)` of the review tab, in the order shown.
  final List<(String, String)> review;

  /// Same dialog in the same state, to tell a key that did not land.
  final String fingerprint;

  bool tabAnswered(int i) => i >= 0 && i < tabs.length && tabs[i].answered;

  /// The answer the review shows for question [text], or null.
  String? reviewAnswerOf(String text) {
    for (final (q, a) in review) {
      if (_same(q, text)) return a;
    }
    return null;
  }
}

final _ansi = RegExp('\u001b\\[[0-9;?]*[ -/]*[@-~]');
final _rule = RegExp(r'^\s*─{5,}\s*$');
final _optionRow = RegExp(r'^\s*(❯)?\s*(\d{1,2})\.\s+(.*?)\s*$');
final _submitRow = RegExp(r'^\s*(❯)?\s+Submit\s*$');
final _stripRow = RegExp(r'^\s*←?\s*([☐☒✔☑].*?)\s*→?\s*$');
final _footerRow = RegExp(r'^\s*Enter to select\b');

/// Whether a Claude Code question dialog (or its review tab) is on [screen].
bool looksLikeClaudeAsk(String screen) => parseClaudeAsk(screen).kind != ClaudeAskKind.none;

/// Reads the question dialog out of [screen] (plain or ANSI; whole rows of the
/// pane, at least the dialog's height: 45 rows are safe). Only the dialog at
/// the bottom counts.
ClaudeAskScreen parseClaudeAsk(String screen) {
  final lines = [
    for (final raw in screen.split('\n'))
      _cleanRow(raw),
  ];
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  if (lines.isEmpty) return ClaudeAskScreen.none;

  // The review tab ends with its own menu; a question tab with the footer.
  final ready = lines.lastIndexWhere((l) => l.trim() == 'Ready to submit your answers?');
  if (ready >= 0 && lines.length - ready <= 4) return _parseReview(lines, ready);
  final footer = lines.lastIndexWhere(_footerRow.hasMatch);
  if (footer < 0 || lines.length - footer > 2) return ClaudeAskScreen.none;
  return _parseQuestion(lines, footer);
}

String _cleanRow(String raw) {
  final cr = raw.lastIndexOf('\r');
  var t = (cr < 0 ? raw : raw.substring(cr + 1)).replaceAll(_ansi, '').trimRight();
  // The question wraps under a bar of its own (`│ ...`).
  t = t.replaceFirst(RegExp(r'^│ ?'), '');
  return t;
}

ClaudeAskScreen _parseQuestion(List<String> lines, int footer) {
  // Up to the rule above the dialog's own rows.
  var chat = -1;
  for (var i = footer - 1; i >= 0 && i >= footer - 3; i--) {
    final m = _optionRow.firstMatch(lines[i]);
    if (m != null && m[3]!.startsWith('Chat about this')) {
      chat = i;
      break;
    }
  }
  if (chat < 0) return ClaudeAskScreen.none;
  final chatCursor = _optionRow.firstMatch(lines[chat])![1] != null;
  var bottom = chat - 1;
  while (bottom >= 0 && !_rule.hasMatch(lines[bottom])) {
    bottom--;
  }
  if (bottom < 0) return ClaudeAskScreen.none;
  var top = bottom - 1;
  while (top >= 0 && !_rule.hasMatch(lines[top])) {
    top--;
  }
  if (top < 0) return ClaudeAskScreen.none;

  final body = lines.sublist(top + 1, bottom);
  var at = 0;
  while (at < body.length && body[at].trim().isEmpty) {
    at++;
  }
  final tabs = <ClaudeAskTab>[];
  if (at < body.length && _stripRow.hasMatch(body[at])) {
    for (final part in _stripRow.firstMatch(body[at])![1]!.split(RegExp(r'\s{2,}(?=[☐☒✔☑])'))) {
      final m = RegExp(r'^([☐☒✔☑])\s+(.*?)\s*$').firstMatch(part.trim());
      if (m == null) continue;
      if (m[2] == 'Submit') continue;
      tabs.add(ClaudeAskTab(m[2]!, m[1] == '☒' || m[1] == '☑'));
    }
    at++;
  }
  // The title: the rows before the first option.
  final title = <String>[];
  while (at < body.length && !_optionRow.hasMatch(body[at])) {
    if (body[at].trim().isNotEmpty) title.add(body[at].trim());
    at++;
  }
  final options = <ClaudeAskRow>[];
  int? cursorNumber;
  var onSubmit = false;
  var hasSubmit = false;
  for (; at < body.length; at++) {
    final row = body[at];
    final m = _optionRow.firstMatch(row);
    if (m != null) {
      var label = m[3]!;
      var checked = false;
      final box = RegExp(r'^\[([ ✔])\]\s*(.*)$').firstMatch(label);
      if (box != null) {
        checked = box[1] == '✔';
        label = box[2]!;
      }
      var marked = false;
      if (label.endsWith(' ✔')) {
        marked = true;
        label = label.substring(0, label.length - 2).trimRight();
      }
      final cursor = m[1] != null;
      if (cursor) cursorNumber = int.parse(m[2]!);
      options.add(ClaudeAskRow(number: int.parse(m[2]!), label: label, cursor: cursor, checked: checked, marked: marked));
    } else if (_submitRow.hasMatch(row)) {
      hasSubmit = true;
      onSubmit = _submitRow.firstMatch(row)![1] != null;
    }
  }
  // The arrow rows in order: the numbered options (Other last), a multi-select's
  // unnumbered `Submit`, then `Chat about this`.
  if (onSubmit) cursorNumber = options.length + 1;
  if (chatCursor) cursorNumber = options.length + (hasSubmit ? 2 : 1);
  // Numbered 1..n in order, or it is not the dialog this driver knows.
  for (final (i, o) in options.indexed) {
    if (o.number != i + 1) return ClaudeAskScreen.none;
  }
  if (options.length < 2) return ClaudeAskScreen.none;
  final print = [
    tabs.map((t) => '${t.answered ? 1 : 0}').join(),
    title.join(' '),
    for (final o in options) '${o.cursor ? '>' : ''}${o.checked ? 'x' : ''}${o.marked ? 'v' : ''}${o.label}',
    if (onSubmit) 'submit>',
    if (chatCursor) 'chat>',
  ].join('|');
  return ClaudeAskScreen(
    kind: ClaudeAskKind.question,
    tabs: tabs,
    title: title.join(' '),
    options: options,
    cursorNumber: cursorNumber,
    cursorOnSubmit: onSubmit,
    fingerprint: print,
  );
}

ClaudeAskScreen _parseReview(List<String> lines, int ready) {
  var head = ready;
  while (head >= 0 && lines[head].trim() != 'Review your answers') {
    head--;
    if (ready - head > 60) return ClaudeAskScreen.none;
  }
  if (head < 0) return ClaudeAskScreen.none;
  final pairs = <(String, String)>[];
  String? question;
  final answer = StringBuffer();
  void flush() {
    if (question != null) pairs.add((question!, answer.toString().trim()));
    question = null;
    answer.clear();
  }

  for (var i = head + 1; i < ready; i++) {
    final t = lines[i].trim();
    if (t.startsWith('●')) {
      flush();
      question = t.substring(1).trim();
    } else if (t.startsWith('→') && question != null) {
      answer.write(t.substring(1).trim());
    } else if (question != null && t.isNotEmpty && answer.isNotEmpty) {
      // A long answer wrapped.
      answer.write(' $t');
    } else if (question != null && t.isNotEmpty && !t.startsWith('⚠')) {
      question = '$question $t';
    }
  }
  flush();
  // Its menu: `1. Submit answers`, `2. Cancel`.
  var hasMenu = false;
  var menuCursor = 0;
  for (var i = ready + 1; i < lines.length; i++) {
    final m = _optionRow.firstMatch(lines[i]);
    if (m == null) continue;
    if (m[2] == '1' && m[3]!.startsWith('Submit answers')) hasMenu = true;
    if (m[1] != null) menuCursor = int.parse(m[2]!);
  }
  if (!hasMenu) return ClaudeAskScreen.none;
  // The strip above `Review your answers`, if it is on screen.
  final tabs = <ClaudeAskTab>[];
  for (var i = head - 1; i >= 0 && i >= head - 2; i--) {
    if (!_stripRow.hasMatch(lines[i])) continue;
    for (final part in _stripRow.firstMatch(lines[i])![1]!.split(RegExp(r'\s{2,}(?=[☐☒✔☑])'))) {
      final m = RegExp(r'^([☐☒✔☑])\s+(.*?)\s*$').firstMatch(part.trim());
      if (m == null || m[2] == 'Submit') continue;
      tabs.add(ClaudeAskTab(m[2]!, m[1] == '☒' || m[1] == '☑'));
    }
    break;
  }
  return ClaudeAskScreen(
    kind: ClaudeAskKind.review,
    tabs: tabs,
    review: pairs,
    cursorNumber: menuCursor == 0 ? null : menuCursor,
    fingerprint: 'review|${pairs.map((p) => '${p.$1}=${p.$2}').join('|')}|$menuCursor',
  );
}
