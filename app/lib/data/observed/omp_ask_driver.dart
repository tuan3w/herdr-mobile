import 'observed_contracts.dart';

/// Answers omp's question tool (`ask`) by KEYS, from what the pane shows.
///
/// omp draws the tool as a modal "Ask" box at the bottom of the pane
/// (`AskDialogComponent`, packages/tui/src/overlays/ask-dialog.ts, omp 18.4):
///
/// ```
/// ╭─ Ask ───────────────────────────────╮
/// │  Storage    extras    name    Submit │   tab strip (only with 2+ questions
/// │ Where should data live?              │   or any multi-select question)
/// ├──────────────────────────────────────┤
/// │   ○ SQLite                           │   ❯ marks the cursor row, ○/◉ a
/// │       Single file                    │   single choice, ☐/☑ a multi-select
/// │ ❯ ○ Postgres (Recommended)           │
/// │   ○ Other (type your own)            │   always the last row
/// ├──────────────────────────────────────┤
/// │ ⏎ select · n note · ↑/↓ move · …     │
/// ╰──────────────────────────────────────╯
/// ```
///
/// Keys (verified on a real omp 18.4.12, see `test/fixtures/prompts/omp/`):
///
/// | key | where | effect |
/// | --- | --- | --- |
/// | `up` / `down` | question tab | cursor one row (clamped, no wrap) |
/// | `enter` | single choice, on an option | select it and go to the next tab; a lone single-choice question submits |
/// | `space` | multi-select, on an option | toggle it |
/// | `enter` | multi-select, on an option | NO toggle: go to the next tab; a lone multi-select question submits |
/// | `enter` | on `Other (type your own)` | open the custom-answer editor |
/// | `tab` / `shift+tab` | with a tab strip | next / previous tab, wrapping through `Submit` (the review tab) |
/// | `enter` | review tab | submit |
/// | `esc` | anywhere | cancel the whole tool call |
/// | `enter` / `ctrl+u` / `esc` | editor | submit its text / clear the line / back to the dialog |
///
/// The tab strip does not say which tab is active in plain text (only the
/// colour does), so the active question is found by matching the question
/// text and the option labels on screen against the structured [PendingAsk]
/// that the session log gave us.
///
/// The screen is the truth. [OmpAskDriver.next] reads a screen and gives the
/// ONE next thing to send; the caller sends it, reads the pane again and asks
/// again, until [AskDone]. Nothing is assumed about where the cursor, the tab
/// or the checkboxes were, so it works from any state, and a key that did not
/// land only costs another round. The driver keeps one memory: the checked
/// state of multi-select rows that scrolled out of view (they cannot change
/// while out of view), and counters that stop an endless loop.

// ------------------------------------------------------------------ steps

/// What to do next.
sealed class AskStep {
  const AskStep();
}

/// Send [text] (through the bracketed-paste-aware text path, WITHOUT enter),
/// then [keys] (`pane.send_keys`); either may be empty, not both.
final class AskSend extends AskStep {
  const AskSend({this.keys = const [], this.text, this.submits = false, this.why = ''});

  final List<String> keys;
  final String? text;

  /// These keys end the dialog: the tool call gets its answer.
  final bool submits;

  /// What the step is for, for logs and tests.
  final String why;

  @override
  String toString() => 'AskSend($keys${text == null ? '' : ', text: "$text"'}${submits ? ', submits' : ''}: $why)';
}

/// The dialog is gone (answered, cancelled or timed out): check the log.
final class AskDone extends AskStep {
  const AskDone();

  @override
  String toString() => 'AskDone';
}

/// The screen cannot be driven (not the expected dialog, a draft in the
/// composer, the dialog ignored the keys, ...). Nothing was sent.
final class AskMismatch extends AskStep {
  const AskMismatch(this.why);

  final String why;

  @override
  String toString() => 'AskMismatch($why)';
}

// ------------------------------------------------------------ screen model

enum AskScreenKind {
  /// No ask dialog is showing.
  none,

  /// A question tab.
  question,

  /// The review tab (`Submit`).
  review,

  /// The custom-answer (or note) editor over the dialog.
  editor,
}

/// One option row as drawn.
class AskScreenRow {
  const AskScreenRow({
    required this.label,
    required this.cursor,
    required this.checked,
    required this.multi,
    this.description = '',
  });

  /// The label as drawn: wrapped lines joined with a space, `(Recommended)`
  /// still on it.
  final String label;
  final bool cursor;
  final bool checked;

  /// A checkbox (`☐`/`☑`), not a radio (`○`/`◉`).
  final bool multi;

  /// The description rows (at most two while collapsed), or for the `Other`
  /// row the custom answer drawn under it.
  final String description;

  /// The free-text row, always last.
  bool get isOther => _key(label) == _otherKey;

  @override
  String toString() => '${cursor ? '❯' : ' '} ${checked ? 'x' : '_'} $label';
}

/// One line of the review tab.
class AskReviewLine {
  const AskReviewLine(this.index, this.answer);

  /// Zero-based question index.
  final int index;

  /// What the review shows after the label; `unanswered` when empty.
  final String answer;
}

/// What the ask dialog on a screen says. Pure reading; no judgement.
class AskScreenState {
  const AskScreenState({
    this.kind = AskScreenKind.none,
    this.tabs = const [],
    this.title = '',
    this.rows = const [],
    this.review = const [],
    this.unanswered = 0,
    this.secondsLeft,
    this.editorText = '',
    this.blockedByDraft = false,
  });

  final AskScreenKind kind;

  /// Tab labels including the final `Submit`; empty without a tab strip. The
  /// active one is not marked in plain text.
  final List<String> tabs;

  /// The question as drawn (wrapped rows joined; ends in `…` when cut), the
  /// editor's question, or `Review answers`.
  final String title;

  /// Question tab: the VISIBLE option rows, the `Other` row last when in view.
  final List<AskScreenRow> rows;

  /// Review tab.
  final List<AskReviewLine> review;
  final int unanswered;

  /// The countdown in the box title (`Ask (12s)`), when the agent set a timeout.
  final int? secondsLeft;

  /// Editor: what is typed so far.
  final String editorText;

  /// The composer holds a draft, so the dialog ignores keys until it is cleared.
  final bool blockedByDraft;

  bool get hasTabs => tabs.isNotEmpty;

  /// Index into [rows] of the cursor, or null.
  int? get cursorRow {
    final i = rows.indexWhere((r) => r.cursor);
    return i < 0 ? null : i;
  }

  /// Whether the visible rows are checkboxes.
  bool get multi => rows.any((r) => r.multi);

  /// Same dialog, same cursor, same checks, same text.
  String get fingerprint => [
        kind.name,
        tabs.join('|'),
        title,
        for (final r in rows) '${r.cursor}${r.checked}${r.label}${r.description}',
        for (final l in review) '${l.index}${l.answer}',
        editorText,
      ].join('\n');
}

final _ansi = RegExp(
  r'\x1B\[[0-9;:?<=>]*[ -/]*[@-~]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|\x1B[()][A-Za-z0-9]|\x1B[=>]',
);

List<String> _screenLines(String screen) => [
      for (final l in screen.split('\n')) l.replaceAll('\r', '').replaceAll(_ansi, '').trimRight(),
    ];

final _topBox = RegExp(r'^╭─+ (.+?) ─*╮$');
final _askTitle = RegExp(r'^Ask(?: \((\d+)s\))?$');
final _editorTitle = RegExp(r'^(Custom answer|Note for .*?)(?:: (.*))?$');

// cursor slot, marker, label
final _rowRe = RegExp(
  r'^([❯>\uf054]|\s) (○|◉|☐|☑|\( \)|\(o\)|\[ \]|\[x\]|[\uf14a\uf096\uf192\uf10c])(?: (.*))?$',
);
const _checkedMarkers = {'◉', '☑', '(o)', '[x]', '\uf14a', '\uf192'};
const _multiMarkers = {'☐', '☑', '[ ]', '[x]', '\uf14a', '\uf096'};

final _reviewRe = RegExp(r'^(\d+)\. (.*)$');
final _unansweredRe = RegExp(r'^(\d+) unanswered questions?;');

/// The box a cell lives in: its text between the side bars, one space of
/// padding and the trailing bar removed. Null for a line that is not a box row.
String? _cell(String line) {
  final t = line.trimLeft();
  if (!t.startsWith('│')) return null;
  var c = t.substring(1);
  if (c.startsWith(' ')) c = c.substring(1);
  c = c.trimRight();
  if (c.endsWith('│')) c = c.substring(0, c.length - 1);
  return c.trimRight();
}

final _scrollbar = RegExp(r'\s[█│▐▌┃]$');

/// Lower-case letters and digits only: what two renderings of the same text
/// share (markdown marks, quotes, ellipses and spacing are dropped).
String _key(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}\p{M}]', unicode: true), '');

final _otherKey = _key('Other (type your own)');

/// Whether an ask dialog (or its custom-answer editor) is on [screen].
bool looksLikeAsk(String screen) => parseAskScreen(screen).kind != AskScreenKind.none;

/// Reads the ask dialog out of [screen] (plain or ANSI; whole rows of the
/// pane, at least the dialog's height: 45 rows are safe).
AskScreenState parseAskScreen(String screen) {
  final lines = _screenLines(screen);
  // The last titled box wins; an earlier one is a finished tool call.
  var top = -1;
  String? title;
  for (var i = lines.length - 1; i >= 0; i--) {
    final m = _topBox.firstMatch(lines[i].trimLeft());
    if (m == null) continue;
    top = i;
    title = m[1]!;
    break;
  }
  if (top < 0) return const AskScreenState();
  final ask = _askTitle.firstMatch(title!);
  final editor = _editorTitle.firstMatch(title);
  if (ask == null && editor == null) return const AskScreenState();
  var bottom = -1;
  for (var i = top + 1; i < lines.length; i++) {
    if (lines[i].trimLeft().startsWith('╰')) {
      bottom = i;
      break;
    }
  }
  if (bottom < 0) return const AskScreenState();

  // Sections between the dividers.
  final sections = <List<String>>[[]];
  for (var i = top + 1; i < bottom; i++) {
    final t = lines[i].trimLeft();
    if (t.startsWith('├')) {
      sections.add([]);
      continue;
    }
    final c = _cell(lines[i]);
    if (c != null) sections.last.add(c);
  }
  final footer = sections.last.isEmpty ? '' : sections.last.last;
  final draft = footer.contains('Finish or clear the current prompt');

  if (editor != null && ask == null) {
    return _parseEditor(editor[2] ?? '', sections.first, draft);
  }

  final seconds = ask![1] == null ? null : int.tryParse(ask[1]!);
  if (sections.length < 3) return const AskScreenState();
  final header = [...sections.first];
  final body = [for (final c in sections[1]) c.replaceFirst(_scrollbar, '')];

  var tabs = const <String>[];
  if (header.isNotEmpty && header.first.startsWith(' ') && header.first.trimRight().endsWith('Submit')) {
    final parts = header.first.trim().split(RegExp(r'\s{2,}'));
    if (parts.length >= 2) {
      tabs = parts;
      header.removeAt(0);
    }
  }
  final title0 = header.map((l) => l.trim()).where((l) => l.isNotEmpty).join(' ');

  if (title0 == 'Review answers') {
    final rows = <AskReviewLine>[];
    var unanswered = 0;
    for (final c in body) {
      final u = _unansweredRe.firstMatch(c);
      if (u != null) {
        unanswered = int.parse(u[1]!);
        continue;
      }
      final m = _reviewRe.firstMatch(c);
      if (m == null) continue;
      final index = int.parse(m[1]!) - 1;
      var rest = m[2]!;
      final label = index < tabs.length ? tabs[index] : null;
      if (label != null && rest.startsWith('$label:')) {
        rest = rest.substring(label.length + 1);
      } else {
        final cut = rest.indexOf(': ');
        rest = cut < 0 ? rest : rest.substring(cut + 1);
      }
      rows.add(AskReviewLine(index, rest.trim()));
    }
    return AskScreenState(
      kind: AskScreenKind.review,
      tabs: tabs,
      title: title0,
      review: rows,
      unanswered: unanswered,
      secondsLeft: seconds,
      blockedByDraft: draft,
    );
  }

  final rows = <AskScreenRow>[];
  String? label;
  var description = '';
  var cursor = false, checked = false, multi = false;
  void flush() {
    if (label != null) {
      rows.add(AskScreenRow(
        label: label!.trim(),
        cursor: cursor,
        checked: checked,
        multi: multi,
        description: description.trim(),
      ));
    }
    label = null;
    description = '';
  }

  for (final c in body) {
    if (c.trim().isEmpty) continue;
    final m = _rowRe.firstMatch(c);
    if (m != null) {
      flush();
      cursor = m[1] != ' ' && m[1]!.trim().isNotEmpty;
      checked = _checkedMarkers.contains(m[2]);
      multi = _multiMarkers.contains(m[2]);
      label = m[3] ?? '';
    } else if (label == null) {
      continue; // the tail of a row that scrolled off the top
    } else if (c.startsWith('      ')) {
      description = '$description ${c.trim()}';
    } else if (c.startsWith('    ')) {
      label = '$label ${c.trim()}';
    }
  }
  flush();

  return AskScreenState(
    kind: AskScreenKind.question,
    tabs: tabs,
    title: title0,
    rows: rows,
    secondsLeft: seconds,
    blockedByDraft: draft,
  );
}

AskScreenState _parseEditor(String question, List<String> cells, bool draft) {
  var start = cells.indexWhere((c) => c.startsWith('>'));
  final text = <String>[];
  if (start >= 0) {
    for (var i = start; i < cells.length; i++) {
      final c = cells[i];
      if (c.contains('submit') && c.contains('cancel')) break;
      text.add(i == start ? c.substring(1).trimLeft() : c.trim());
    }
  }
  while (text.isNotEmpty && text.last.isEmpty) {
    text.removeLast();
  }
  return AskScreenState(
    kind: AskScreenKind.editor,
    title: question,
    editorText: text.join('\n'),
    blockedByDraft: draft,
  );
}

// ------------------------------------------------------------------ matching

/// Whether the title drawn on screen is [question]'s (the screen cuts a long
/// title with `…`).
bool _titleMatches(String screenTitle, String question) {
  final q = _key(question);
  if (screenTitle.endsWith('…')) {
    final s = _key(screenTitle.substring(0, screenTitle.length - 1));
    return s.isNotEmpty && q.startsWith(s);
  }
  return _key(screenTitle) == q;
}

/// Per visible row: the option index, `-1` for the Other row, null when the
/// row is none of [q]'s options. Rows are a window of the options in order.
List<int?> _align(AskQuestion q, List<AskScreenRow> rows) {
  final out = <int?>[];
  var next = 0;
  for (final r in rows) {
    if (r.isOther) {
      out.add(-1);
      continue;
    }
    int? found;
    final k = _key(r.label);
    for (var i = next; i < q.options.length; i++) {
      final o = _key(q.options[i].label);
      if (k == o || k == '${o}recommended') {
        found = i;
        break;
      }
    }
    if (found != null) next = found + 1;
    out.add(found);
  }
  return out;
}

String _inline(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Whether the text drawn under the `Other` row is [custom] (it is cut with
/// `…` when long).
bool _previewMatches(String preview, String custom) {
  final c = _key(_inline(custom));
  if (preview.endsWith('…')) {
    final p = _key(preview.substring(0, preview.length - 1));
    return c.startsWith(p);
  }
  return _key(preview) == c;
}

// -------------------------------------------------------------------- driver

/// Plans the keys that answer one [PendingAsk] with [answers] (one per
/// question, same order). One instance per attempt; call [next] with each
/// fresh screen.
class OmpAskDriver {
  OmpAskDriver(this.ask, this.answers, {this.maxSteps = 80})
      : assert(answers.length == ask.questions.length, 'one answer per question');

  final PendingAsk ask;
  final List<AskAnswer> answers;

  /// Steps after which the driver gives up ([AskMismatch]).
  final int maxSteps;

  int _steps = 0;
  int _repeats = 0;
  String? _lastPrint;
  bool _lastWasSend = false;
  bool _clearing = false;
  final _known = <int, Map<int, bool>>{};
  final _revisits = <int, int>{};

  /// The next step for [screen].
  AskStep next(String screen) {
    final s = parseAskScreen(screen);
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

  AskStep _plan(AskScreenState s) {
    if (s.kind == AskScreenKind.none) return const AskDone();
    if (s.blockedByDraft) {
      return const AskMismatch('the composer holds a draft: clear it first');
    }
    if (s.hasTabs && s.tabs.length != ask.questions.length + 1) {
      return AskMismatch('${s.tabs.length - 1} tabs on screen, ${ask.questions.length} questions asked');
    }
    return switch (s.kind) {
      AskScreenKind.editor => _editor(s),
      AskScreenKind.review => _review(s),
      _ => _question(s),
    };
  }

  /// Index of the question the screen is on, or null when unsure.
  int? _which(AskScreenState s, {required bool editor}) {
    final qs = ask.questions;
    final byTitle = [
      for (var i = 0; i < qs.length; i++)
        if (_titleMatches(s.title, qs[i].question)) i,
    ];
    if (editor) return byTitle.length == 1 ? byTitle.single : null;
    final fits = <int>[];
    for (final i in byTitle.isEmpty ? List.generate(qs.length, (i) => i) : byTitle) {
      final rows = _align(qs[i], s.rows);
      if (rows.any((r) => r == null)) continue;
      if (byTitle.isEmpty && rows.where((r) => r != -1).isEmpty) continue;
      fits.add(i);
    }
    return fits.length == 1 ? fits.single : null;
  }

  int get _n => ask.questions.length;

  AskStep _editor(AskScreenState s) {
    if (s.title.startsWith('Note for')) {
      return const AskSend(keys: ['esc'], why: 'leave a note editor');
    }
    final k = _which(s, editor: true);
    if (k == null) return const AskMismatch('cannot tell which question the editor belongs to');
    final custom = answers[k].custom?.trim() ?? '';
    final q = ask.questions[k];
    if (custom.isEmpty) {
      if (s.editorText.isNotEmpty) {
        _clearing = true;
        return const AskSend(keys: ['ctrl+u'], why: 'clear the custom answer');
      }
      return _clearing
          ? const AskSend(keys: ['enter'], why: 'an empty custom answer drops it')
          : const AskSend(keys: ['esc'], why: 'no custom answer wanted');
    }
    _clearing = false;
    if (_key(s.editorText) == _key(custom)) {
      return AskSend(keys: const ['enter'], submits: _n == 1 && !q.multi, why: 'submit the custom answer');
    }
    if (s.editorText.isNotEmpty) {
      return const AskSend(keys: ['ctrl+u'], why: 'clear the prefilled text');
    }
    return AskSend(text: custom, why: 'type the custom answer');
  }

  List<String> _moves(int from, int to) =>
      List.filled((to - from).abs(), to > from ? 'down' : 'up');

  AskStep _question(AskScreenState s) {
    final k = _which(s, editor: false);
    if (k == null) return const AskMismatch('the question on screen is not the one asked');
    final q = ask.questions[k];
    final a = answers[k];
    final n = q.options.length;
    final align = _align(q, s.rows);
    final cr = s.cursorRow;
    if (cr == null || align[cr] == null) return const AskMismatch('cannot find the cursor row');
    final cursor = align[cr]! == -1 ? n : align[cr]!;
    final custom = a.custom?.trim() ?? '';
    final wants = {for (final i in a.selected) if (i >= 0 && i < n) i}.toList()..sort();
    final multiTab = s.rows.any((r) => r.multi);
    if (multiTab != q.multi) {
      return AskMismatch('${q.multi ? 'checkboxes' : 'radios'} expected, the other drawn');
    }

    final otherIdx = align.indexOf(-1);
    final other = otherIdx < 0 ? null : s.rows[otherIdx];
    final customShown = other != null && other.checked && _previewMatches(other.description, custom);

    if (!q.multi) {
      if (custom.isNotEmpty) {
        if (customShown && s.hasTabs) {
          return const AskSend(keys: ['tab'], why: 'custom answer already set, next tab');
        }
        return AskSend(keys: [..._moves(cursor, n), 'enter'], why: 'open the custom answer editor');
      }
      if (wants.length > 1) return const AskMismatch('several answers for a single choice');
      if (wants.isEmpty) {
        if (!s.hasTabs) return const AskMismatch('nothing to answer');
        // Skipping must also drop an old custom answer, so look at the Other row.
        if (other == null) {
          return AskSend(keys: _moves(cursor, n), why: 'look at the Other row');
        }
        return other.checked
            ? AskSend(keys: [..._moves(cursor, n), 'enter'], why: 'open the editor to drop the custom answer')
            : const AskSend(keys: ['tab'], why: 'no answer wanted, next tab');
      }
      return AskSend(
        keys: [..._moves(cursor, wants.single), 'enter'],
        submits: !s.hasTabs,
        why: 'choose ${q.options[wants.single].label}',
      );
    }

    // Multi-select. Rows in view are re-read every time; rows out of view keep
    // what was last seen.
    final known = _known.putIfAbsent(k, () => {});
    for (var r = 0; r < s.rows.length; r++) {
      final i = align[r]!;
      known[i == -1 ? n : i] = s.rows[r].checked;
    }
    final toggles = <int>[
      for (var i = 0; i < n; i++)
        if (known.containsKey(i) && known[i] != wants.contains(i)) i,
    ];
    if (toggles.isNotEmpty) {
      final keys = <String>[];
      var at = cursor;
      final left = [...toggles];
      while (left.isNotEmpty) {
        left.sort((x, y) => (x - at).abs().compareTo((y - at).abs()));
        final t = left.removeAt(0);
        keys
          ..addAll(_moves(at, t))
          ..add('space');
        at = t;
        known[t] = !known[t]!;
      }
      return AskSend(keys: keys, why: 'toggle ${toggles.map((i) => q.options[i].label).join(', ')}');
    }
    final unseen = [
      for (var i = 0; i <= n; i++)
        if (!known.containsKey(i)) i,
    ];
    if (unseen.isNotEmpty) {
      unseen.sort((x, y) => (x - cursor).abs().compareTo((y - cursor).abs()));
      return AskSend(
        keys: _moves(cursor, unseen.first),
        why: 'scroll to ${unseen.first == n ? 'Other' : q.options[unseen.first].label}',
      );
    }
    final otherChecked = other?.checked ?? known[n] ?? false;
    if (custom.isNotEmpty && !(otherChecked && (other == null || customShown))) {
      return AskSend(keys: [..._moves(cursor, n), 'enter'], why: 'open the custom answer editor');
    }
    if (custom.isEmpty && otherChecked) {
      return AskSend(keys: [..._moves(cursor, n), 'enter'], why: 'open the editor to drop the custom answer');
    }
    if (n == 0) {
      return s.hasTabs
          ? const AskSend(keys: ['tab'], why: 'no answer wanted, next tab')
          : const AskMismatch('nothing to answer');
    }
    return AskSend(
      keys: [if (cursor == n) 'up', 'enter'],
      submits: _n == 1,
      why: _n == 1 ? 'submit' : 'next tab',
    );
  }

  String _expectedSummary(int k) {
    final q = ask.questions[k];
    final a = answers[k];
    final custom = a.custom?.trim() ?? '';
    final wants = {for (final i in a.selected) if (i >= 0 && i < q.options.length) i}.toList()..sort();
    String label(int i) => q.recommended == i ? '${q.options[i].label} (Recommended)' : q.options[i].label;
    if (!q.multi) {
      if (custom.isNotEmpty) return '“${_inline(custom)}”';
      return wants.isEmpty ? 'unanswered' : label(wants.first);
    }
    final parts = [for (final i in wants) label(i), if (custom.isNotEmpty) 'Other: “${_inline(custom)}”'];
    return parts.isEmpty ? 'unanswered' : parts.join(', ');
  }

  bool _reviewMatches(String shown, String expected) {
    if (shown.endsWith('…')) {
      final p = _key(shown.substring(0, shown.length - 1));
      return _key(expected).startsWith(p);
    }
    return _key(shown) == _key(expected);
  }

  AskStep _review(AskScreenState s) {
    for (var j = 0; j < _n; j++) {
      final line = s.review.where((l) => l.index == j);
      final shown = line.isEmpty ? 'unanswered' : line.first.answer;
      if (_reviewMatches(shown, _expectedSummary(j))) continue;
      if ((_revisits[j] = (_revisits[j] ?? 0) + 1) > 2) {
        return AskMismatch('review shows "$shown" for question ${j + 1}, wanted "${_expectedSummary(j)}"');
      }
      final back = _n - j, forward = j + 1;
      return AskSend(
        keys: back <= forward ? List.filled(back, 'shift+tab') : List.filled(forward, 'tab'),
        why: 'back to question ${j + 1}',
      );
    }
    return const AskSend(keys: ['enter'], submits: true, why: 'submit the answers');
  }
}

/// [OmpAskDriver.next] without memory: right for lists that fit in the box
/// (rows scrolled out of view are only remembered by an instance).
AskStep nextAskStep(PendingAsk ask, List<AskAnswer> answers, String screen) =>
    OmpAskDriver(ask, answers).next(screen);

// ------------------------------------------------------------------ menus

/// One row of a menu with a cursor.
class OmpMenuOption {
  const OmpMenuOption(this.label, this.cursor);

  final String label;
  final bool cursor;
}

/// A cursor menu (tool approval, plan review): choosing = move the cursor
/// there, `enter`. The move is computed from where the cursor IS on screen.
abstract class OmpMenuScreen {
  const OmpMenuScreen(this.options);

  final List<OmpMenuOption> options;

  int? get cursorIndex {
    final i = options.indexWhere((o) => o.cursor);
    return i < 0 ? null : i;
  }

  /// Keys that choose option [index] from the current cursor; null when the
  /// cursor cannot be found.
  List<String>? keysFor(int index) {
    final c = cursorIndex;
    if (c == null || index < 0 || index >= options.length) return null;
    return [...List.filled((index - c).abs(), index > c ? 'down' : 'up'), 'enter'];
  }

  /// Keys for the option labelled [label] (case-insensitive prefix), or null.
  List<String>? keysForLabel(String label) {
    final i = options.indexWhere((o) => o.label.toLowerCase().startsWith(label.toLowerCase()));
    return i < 0 ? null : keysFor(i);
  }
}

/// omp's tool approval (`Allow tool: bash`): `Approve` / `Deny`.
class OmpApprovalScreen extends OmpMenuScreen {
  const OmpApprovalScreen({required this.tool, required this.detail, required List<OmpMenuOption> options})
      : super(options);

  /// The tool name from the title.
  final String tool;

  /// The rows above the options as drawn: `Reason: …`, `Command: …`, `Path: …`.
  final List<String> detail;

  List<String>? get approve => keysForLabel('Approve');
  List<String>? get deny => keysForLabel('Deny');

  /// `esc` also denies.
  static const cancel = ['esc'];
}

/// omp's plan review ("Plan mode - next step"): Approve and execute / compact
/// context / keep context, Refine plan, Save and quit. Needs the focus on the
/// option list (the default; `tab` moves it to the plan text).
class OmpPlanReviewScreen extends OmpMenuScreen {
  const OmpPlanReviewScreen(super.options);

  List<String>? get approve => keysForLabel('Approve and execute');
}

final _approvalTitle = RegExp(r'^Allow tool: (.+)$');
final _menuRow = RegExp(r'^\s?([❯>\uf054]|\s) (\S.*)$');

/// Reads a tool approval dialog; null when none is on [screen].
OmpApprovalScreen? parseOmpApproval(String screen) {
  final lines = _screenLines(screen);
  var top = -1;
  String? title;
  for (var i = lines.length - 1; i >= 0; i--) {
    final m = _topBox.firstMatch(lines[i].trimLeft());
    if (m == null) continue;
    top = i;
    title = m[1]!;
    break;
  }
  if (top < 0) return null;
  final t = _approvalTitle.firstMatch(title!);
  if (t == null) return null;
  final cells = <String>[];
  for (var i = top + 1; i < lines.length; i++) {
    if (lines[i].trimLeft().startsWith('╰')) break;
    final c = _cell(lines[i]);
    if (c != null) cells.add(c);
  }
  while (cells.isNotEmpty && cells.last.trim().isEmpty) {
    cells.removeLast();
  }
  if (cells.isEmpty) return null;
  cells.removeLast(); // the key hint
  while (cells.isNotEmpty && cells.last.trim().isEmpty) {
    cells.removeLast();
  }
  // The options are the last block of rows.
  var start = cells.length;
  while (start > 0 && cells[start - 1].trim().isNotEmpty) {
    start--;
  }
  final options = <OmpMenuOption>[];
  for (var i = start; i < cells.length; i++) {
    final m = _menuRow.firstMatch(cells[i]);
    if (m == null) return null;
    options.add(OmpMenuOption(m[2]!.trim(), m[1] != ' '));
  }
  if (options.isEmpty) return null;
  return OmpApprovalScreen(
    tool: t[1]!.trim(),
    detail: [
      for (var i = 0; i < start; i++)
        if (cells[i].trim().isNotEmpty) cells[i].trimRight(),
    ],
    options: options,
  );
}

/// Reads the plan review options; null when it is not on [screen].
OmpPlanReviewScreen? parseOmpPlanReview(String screen) {
  final lines = _screenLines(screen);
  final at = lines.lastIndexWhere((l) => _cell(l)?.trim() == 'Plan mode - next step');
  if (at < 0) return null;
  final options = <OmpMenuOption>[];
  for (var i = at + 1; i < lines.length; i++) {
    if (lines[i].trimLeft().startsWith('├') || lines[i].trimLeft().startsWith('╰')) break;
    final c = _cell(lines[i]);
    if (c == null || c.trim().isEmpty) continue;
    final m = _menuRow.firstMatch(' $c');
    if (m == null) return null;
    options.add(OmpMenuOption(m[2]!.trim(), m[1] != ' '));
  }
  return options.isEmpty ? null : OmpPlanReviewScreen(options);
}
