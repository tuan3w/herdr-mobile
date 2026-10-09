import 'package:herdr_mobile/data/observed/observed_contracts.dart';

/// A model of Claude Code's question dialog (`AskUserQuestion`, 2.1.29x) that
/// takes the keys the real one takes and draws the screens the real one draws:
/// what `test/fixtures/prompts/claude/askfull-*` shows, with the key effects of
/// the capture's key table. The driver is tested against it; a test also checks
/// its first screens against the captured ones, so the fake cannot drift from
/// the real screens unnoticed.
class FakeClaudeAsk {
  FakeClaudeAsk(this.questions, {this.cols = 105})
    : _cursor = List.filled(questions.length, 0),
      _chosen = List.filled(questions.length, null),
      _checked = [for (final _ in questions) <int>{}],
      _text = List.filled(questions.length, ''),
      _otherChecked = List.filled(questions.length, false);

  final List<AskQuestion> questions;
  final int cols;

  /// The tab: 0..n-1 a question, n the review.
  int tab = 0;
  final List<int> _cursor;
  final List<int?> _chosen;
  final List<Set<int>> _checked;
  final List<String> _text;
  final List<bool> _otherChecked;

  /// The dialog ended: the answers given, or declined.
  bool submitted = false;
  bool declined = false;

  /// Keys that arrived, in order.
  final keys = <String>[];

  bool get open => !submitted && !declined;
  bool get _lone => questions.length == 1 && !questions.single.multi;

  /// The answer of question [q] as the dialog shows it, or null when none.
  String? answerOf(int q) {
    final question = questions[q];
    if (question.multi) {
      final labels = [for (final k in _checked[q].toList()..sort()) question.options[k].label];
      final text = _text[q].isNotEmpty && _otherChecked[q] ? [_text[q]] : const <String>[];
      final all = [...labels, ...text];
      return all.isEmpty ? null : all.join(', ');
    }
    final c = _chosen[q];
    if (c == null) return null;
    return c == question.options.length ? _text[q] : question.options[c].label;
  }

  // Rows of question [q]: options 0..n-1, Other n, Submit n+1 (multi), Chat last.
  int _rows(int q) => questions[q].options.length + 1 + (questions[q].multi ? 1 : 0) + 1;
  int _otherRow(int q) => questions[q].options.length;
  int _chatRow(int q) => _rows(q) - 1;

  void press(String key) {
    if (!open) return;
    keys.add(key);
    if (tab == questions.length) return _pressReview(key);
    final q = tab;
    final n = questions[q].options.length;
    switch (key) {
      case 'down':
        _cursor[q] = (_cursor[q] + 1).clamp(0, _rows(q) - 1);
      case 'up':
        // From the first row it wraps to the Other row.
        _cursor[q] = _cursor[q] == 0 ? _otherRow(q) : _cursor[q] - 1;
      case 'right' || 'tab':
        _go(tab + 1);
      case 'left' || 'shift+tab':
        _go(tab - 1);
      case 'esc':
        declined = true;
      case 'enter':
        _enter(q);
      default:
        if (RegExp(r'^\d$').hasMatch(key)) {
          final d = int.parse(key);
          if (_cursor[q] == _otherRow(q)) {
            _text[q] += key;
            if (questions[q].multi) _otherChecked[q] = true;
          } else if (d >= 1 && d <= n) {
            _select(q, d - 1, moveCursor: false);
          }
        }
    }
  }

  /// Text typed (pasted) where the cursor is: only the Other row takes it.
  void paste(String text) {
    if (!open || tab == questions.length) return;
    keys.add('paste:$text');
    final q = tab;
    if (_cursor[q] != _otherRow(q)) return;
    _text[q] += text;
    if (questions[q].multi) _otherChecked[q] = true;
  }

  void _go(int to) {
    final next = to.clamp(0, questions.length);
    if (next != tab && next < questions.length) _cursor[next] = 0;
    tab = next;
  }

  void _enter(int q) {
    final n = questions[q].options.length;
    final row = _cursor[q];
    if (row < n) return _select(q, row, moveCursor: true);
    if (row == _otherRow(q)) {
      if (_text[q].isEmpty) return;
      if (questions[q].multi) {
        _otherChecked[q] = !_otherChecked[q];
      } else {
        _chosen[q] = n;
        _afterChoice(q);
      }
      return;
    }
    if (questions[q].multi && row == n + 1) return _go(questions.length);
    declined = true; // Chat about this
  }

  void _select(int q, int k, {required bool moveCursor}) {
    if (questions[q].multi) {
      if (!_checked[q].remove(k)) _checked[q].add(k);
      return;
    }
    _chosen[q] = k;
    _afterChoice(q);
  }

  void _afterChoice(int q) {
    if (_lone) {
      submitted = true;
    } else {
      _go(tab + 1);
    }
  }

  void _pressReview(String key) {
    final q = questions.length;
    switch (key) {
      case '1':
        submitted = true;
      case '2' || 'esc':
        declined = true;
      case 'left' || 'shift+tab':
        _go(q - 1);
      case 'enter':
        submitted = true;
    }
  }

  // -- the screen ----------------------------------------------------------------

  String screen() {
    if (!open) return '⏺ ${submitted ? 'User answered Claude\'s questions' : 'User declined to answer questions'}\n\n❯ \n';
    final rule = '─' * cols;
    final out = <String>[
      ' ▐▛███▛█   Claude Code v2.1.295',
      '▝▜██████▀  Haiku 5.5 · Claude Max',
      '',
      '❯ ask me something',
      '',
      rule,
    ];
    final strip = _strip();
    if (tab == questions.length) {
      out.addAll([strip, '', 'Review your answers', '']);
      final answered = [for (var i = 0; i < questions.length; i++) if (answerOf(i) != null) i];
      if (answered.length < questions.length) out.add('⚠ You have not answered all questions');
      for (final i in answered) {
        out.addAll([' ● ${questions[i].question}', '   → ${answerOf(i)}']);
      }
      out.addAll(['', 'Ready to submit your answers?', '', '❯ 1. Submit answers', '  2. Cancel']);
      return out.join('\n');
    }
    final q = tab;
    final question = questions[q];
    final n = question.options.length;
    final multi = question.multi;
    if (strip.isNotEmpty) out.add(strip);
    out.addAll(['', _wrap(question.question), '']);
    String mark(int row) => _cursor[q] == row ? '❯' : ' ';
    for (var k = 0; k < n; k++) {
      final o = question.options[k];
      final box = multi ? '${_checked[q].contains(k) ? '[✔]' : '[ ]'} ' : '';
      final done = !multi && _chosen[q] == k ? ' ✔' : '';
      out.add('${mark(k)} ${k + 1}. $box${o.label}$done');
      out.add('${' ' * (multi ? 9 : 5)}${o.description.isEmpty ? o.label : o.description}');
    }
    final text = _text[q];
    final otherLabel = multi
        ? '${_otherChecked[q] && text.isNotEmpty ? '[✔]' : '[ ]'} ${text.isEmpty ? 'Type something' : text}'
        : (text.isEmpty ? 'Type something.' : text);
    out.add('${mark(n)} ${n + 1}. $otherLabel');
    if (multi) out.add('${mark(n + 1)}    Submit');
    out.add(rule);
    out.add('${mark(_chatRow(q))} ${_chatRow(q) + (multi ? 0 : 1)}. Chat about this');
    out.add('');
    out.add(
      'Enter to select · ${_lone ? '↑/↓' : 'Tab/Arrow keys'} to navigate'
      '${_cursor[q] == _otherRow(q) ? ' · ctrl+g to edit in Vim' : ''} · Esc to cancel',
    );
    return out.join('\n');
  }

  String _strip() {
    if (_lone) return ' ☐ ${questions.single.id} ';
    final tabs = [
      for (var i = 0; i < questions.length; i++) '${answerOf(i) != null ? '☒' : '☐'} ${questions[i].id}',
    ];
    return '←  ${tabs.join('  ')}  ✔ Submit  →';
  }

  String _wrap(String text) {
    if (text.length <= cols - 5) return text;
    final cut = text.lastIndexOf(' ', cols - 7);
    return '│ ${text.substring(0, cut)}\n│ ${text.substring(cut + 1)}';
  }
}
