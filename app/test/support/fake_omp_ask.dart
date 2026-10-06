import 'dart:math' as math;

import 'package:herdr_mobile/data/observed/observed_contracts.dart';

/// A small model of omp's ask dialog (`AskDialogComponent`, omp 18.4.12): it
/// takes herdr key names and pasted text like the real one and draws the same
/// box in plain text, so the key plans in `omp_ask_driver_test.dart` can be
/// run against it.
///
/// How faithful it is: `omp_ask_driver_test.dart` replays the key sequences
/// that produced each screen in `test/fixtures/prompts/omp/ask-*.txt` and
/// requires the drawn dialog to equal the captured one row for row (layout,
/// wrapping, tab strip, review tab, scrolling and scrollbar thumb, the footer,
/// the editor box). Keys are modelled from the component's source (what Enter,
/// Space, Tab, Esc, Ctrl+U do) and checked against the captures and a real
/// omp for the sequences the fixtures hold. NOT modelled: markdown in labels
/// (only backticks are dropped), notes (`n`), page up/down, the countdown,
/// images, the draft guard, a cursor row taller than the body, the colour that
/// marks the active tab.
class FakeOmpAsk {
  FakeOmpAsk(this.questions, {this.cols = 119, this.termRows = 40, this.headers = const {}})
      : _states = [
          for (final q in questions)
            _Q(cursor: (q.recommended ?? 0).clamp(0, math.max(0, q.options.length - 1))),
        ];

  final List<AskQuestion> questions;
  final int cols;
  final int termRows;

  /// Tab labels the agent gave (`header`), by question index; the id otherwise.
  final Map<int, String> headers;
  final List<_Q> _states;

  int _tab = 0;
  String? _editor; // text typed so far, or null when the editor is closed
  int _editorFor = 0;
  bool _expanded = false;
  int? _stableHeight;
  bool closed = false;
  bool cancelled = false;

  /// What the dialog handed back on submit: per question the selected option
  /// indexes in option order and the custom answer.
  List<AskAnswer>? submitted;

  bool get _hasTabs => questions.length > 1 || questions.any((q) => q.multi);
  bool get _onReview => _hasTabs && _tab == questions.length;
  int get tab => _tab;
  bool get editorOpen => _editor != null;

  /// The cursor row of question [k], an option index (`options.length` = Other).
  int cursorOf(int k) => _states[k].cursor;

  /// Puts question [k] in a state the person could have left it in; test
  /// set-up only. [tab] makes the dialog start on that tab.
  void seed(int k, {int? cursor, Set<int>? selected, String? custom}) {
    final s = _states[k];
    if (cursor != null) s.cursor = cursor;
    if (selected != null) {
      s.selected
        ..clear()
        ..addAll(selected);
    }
    if (custom != null) s.custom = custom;
  }

  void setTab(int tab) => _tab = tab;

  // ---------------------------------------------------------------- input

  void press(String key) {
    if (closed) return;
    if (_editor != null) {
      switch (key) {
        case 'enter' || 'ctrl+q':
          _finishEditor();
        case 'esc':
          _editor = null;
        case 'ctrl+u':
          _editor = '';
        case 'backspace':
          if (_editor!.isNotEmpty) _editor = _editor!.substring(0, _editor!.length - 1);
      }
      return;
    }
    if (key == 'esc') {
      closed = true;
      cancelled = true;
      return;
    }
    if (key == 'ctrl+o') {
      _expanded = !_expanded;
      _stableHeight = null;
      return;
    }
    if (_hasTabs) {
      if (key == 'tab' || key == 'right') return _switchTab(1);
      if (key == 'shift+tab' || key == 'left') return _switchTab(-1);
    }
    if (_onReview) {
      if (key == 'enter') _submit();
      return;
    }
    final q = questions[_tab];
    final s = _states[_tab];
    final rows = q.options.length + 1;
    switch (key) {
      case 'up':
        s.cursor = (s.cursor - 1).clamp(0, rows - 1);
      case 'down':
        s.cursor = (s.cursor + 1).clamp(0, rows - 1);
      case 'enter' || 'space':
        if (key == 'space' && !q.multi) return;
        _commit(q, s, isEnter: key == 'enter');
    }
  }

  /// Pasted text (bracketed paste) goes into the editor; elsewhere it is lost.
  void paste(String text) {
    if (_editor != null) _editor = _editor! + text;
  }

  void _switchTab(int d) {
    final count = questions.length + 1;
    _tab = (_tab + d + count) % count;
  }

  void _commit(AskQuestion q, _Q s, {required bool isEnter}) {
    if (s.cursor == q.options.length) {
      _editor = s.custom ?? '';
      _editorFor = _tab;
      return;
    }
    if (q.multi) {
      if (isEnter) return _advance();
      s.selected.contains(s.cursor) ? s.selected.remove(s.cursor) : s.selected.add(s.cursor);
      return;
    }
    s.selected
      ..clear()
      ..add(s.cursor);
    s.custom = null;
    _advance();
  }

  void _finishEditor() {
    final text = _editor!;
    final k = _editorFor;
    final q = questions[k];
    final s = _states[k];
    _editor = null;
    if (text.trim().isEmpty) {
      s.custom = null;
      return;
    }
    s.custom = text;
    if (!q.multi) s.selected.clear();
    if (q.multi && questions.length == 1) {
      _tab = questions.length;
    } else {
      _advance();
    }
  }

  void _advance() {
    if (questions.length == 1) return _submit();
    _tab = _tab + 1 < questions.length ? _tab + 1 : questions.length;
  }

  void _submit() {
    closed = true;
    submitted = [
      for (var k = 0; k < questions.length; k++)
        AskAnswer(
          selected: ([..._states[k].selected]..sort()),
          custom: _states[k].custom,
        ),
    ];
  }

  // -------------------------------------------------------------- drawing

  static const _other = 'Other (type your own)';
  int get _w => cols - 4;

  String _marker(AskQuestion q, bool checked) =>
      q.multi ? (checked ? '☑' : '☐') : (checked ? '◉' : '○');

  List<String> _wrap(String text, int width) {
    width = math.max(1, width);
    final out = <String>[];
    for (final para in text.split('\n')) {
      var line = '';
      for (var word in para.split(' ')) {
        if (word.isEmpty) continue;
        while (word.length > width) {
          if (line.isNotEmpty) {
            out.add(line);
            line = '';
          }
          out.add(word.substring(0, width));
          word = word.substring(width);
        }
        if (line.isEmpty) {
          line = word;
        } else if (line.length + 1 + word.length <= width) {
          line = '$line $word';
        } else {
          out.add(line);
          line = word;
        }
      }
      out.add(line);
    }
    return out;
  }

  String _trunc(String s, int width) {
    width = math.max(1, width);
    final r = s.runes.toList();
    return r.length <= width ? s : '${String.fromCharCodes(r.take(width - 1))}…';
  }

  String _plain(String s) => s.replaceAll('`', '');

  String _displayLabel(AskQuestion q, int i) {
    final base = _plain(q.options[i].label);
    return q.recommended == i && !base.endsWith(' (Recommended)') ? '$base (Recommended)' : base;
  }

  String _tabLabel(int k) => _trunc(headers[k] ?? questions[k].id, 16);

  /// One row of a question as lines.
  List<String> _rowLines(AskQuestion q, _Q s, int row, int width, {required bool selected}) {
    final isOther = row == q.options.length;
    final checked = isOther ? s.custom != null : s.selected.contains(row);
    final label = isOther ? _other : _displayLabel(q, row);
    final cursor = selected ? '❯ ' : '  ';
    final lines = <String>[];
    final wrapped = _wrap(label, math.max(1, width - 4));
    lines.add('$cursor${_marker(q, checked)} ${wrapped.first}');
    for (final l in wrapped.skip(1)) {
      lines.add('    $l');
    }
    if (!isOther) {
      final d = q.options[row].description.trim();
      if (d.isNotEmpty) {
        final w = _wrap(_plain(d), math.max(1, width - 6));
        for (final l in (_expanded ? w : w.take(2))) {
          lines.add('      ${_trunc(l, width - 6)}');
        }
      }
    } else if (s.custom != null) {
      lines.add('      ${_trunc(s.custom!.replaceAll(RegExp(r'\s+'), ' ').trim(), width - 6)}');
    }
    return lines;
  }

  List<String> _titleLines(AskQuestion q, int width, int maxRows) {
    final w = _wrap(_plain(q.question), width);
    if (w.length <= maxRows) return w;
    return [...w.take(maxRows - 1), _trunc(w.skip(maxRows - 1).join(' '), width)];
  }

  bool _descOverflow(AskQuestion q) => q.options.any((o) {
        final d = o.description.trim();
        return d.isNotEmpty && _wrap(_plain(d), math.max(1, _w - 6)).length > 2;
      });

  int _measureHeight() {
    final maxHeight = math.max(12, (termRows * 0.7).floor());
    final tabRows = _hasTabs ? 1 : 0;
    var needed = 12;
    for (var k = 0; k < questions.length; k++) {
      final q = questions[k];
      final header = tabRows + _titleLines(q, _w, _expanded ? 1 << 20 : 4).length;
      var body = 0;
      for (var r = 0; r <= q.options.length; r++) {
        body += _rowLines(q, _states[k], r, _w, selected: false).length;
      }
      needed = math.max(needed, 5 + header + math.max(5, body));
    }
    if (_hasTabs) {
      needed = math.max(needed, 5 + tabRows + 1 + math.max(5, 2 + questions.length + 2));
    }
    return math.min(needed, maxHeight);
  }

  String _summary(int k) {
    final q = questions[k];
    final s = _states[k];
    final sel = [for (var i = 0; i < q.options.length; i++) if (s.selected.contains(i)) _displayLabel(q, i)];
    String inline(String t) => t.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (q.multi) {
      final all = [...sel, if (s.custom != null) 'Other: “${inline(s.custom!)}”'];
      return all.isEmpty ? 'unanswered' : all.join(', ');
    }
    if (s.custom != null) return '“${inline(s.custom!)}”';
    return sel.isEmpty ? 'unanswered' : sel.first;
  }

  String _fit(String text, int width) {
    final t = _trunc(text, width);
    return t + ' ' * (width - t.runes.length);
  }

  String _row(String text) => '│ ${_fit(text, _w)} │';

  String _scrollSuffix(int offset, int rows, int total) {
    final up = offset > 0, down = offset + rows < total;
    if (up && down) return '↕';
    if (up) return '↑';
    if (down) return '↓';
    return '';
  }

  /// The dialog (or the editor over it) as rows of the drawn box.
  List<String> dialogLines() {
    if (_editor != null) return _editorLines();
    _stableHeight ??= _measureHeight();
    final total = _stableHeight!;
    final tabRows = _hasTabs ? 1 : 0;
    final header = <String>[];
    if (_hasTabs) {
      header.add([
        for (var k = 0; k < questions.length; k++) ' ${_tabLabel(k)} ',
        ' Submit ',
      ].join('  '));
    }
    final review = _onReview;
    final q = review ? null : questions[_tab];
    final maxTitleRows = math.max(1, total - 5 - 5 - tabRows);
    if (review) {
      header.add('Review answers');
    } else {
      header.addAll(_titleLines(q!, _w, _expanded ? maxTitleRows : 4));
    }
    final fixed = 1 + header.length + 1 + 1 + 1 + 1;
    final bodyRows = math.max(5, total - fixed);

    final body = <String>[];
    var indicator = '';
    if (review) {
      final unanswered = [
        for (var k = 0; k < questions.length; k++)
          if (_states[k].selected.isEmpty && _states[k].custom == null) k,
      ].length;
      if (unanswered > 0) {
        body.add('$unanswered unanswered question${unanswered == 1 ? '' : 's'}; ⏎ still submits.');
        body.add('');
      }
      for (var k = 0; k < questions.length; k++) {
        body.add('${k + 1}. ${_tabLabel(k)}: ${_summary(k)}');
      }
      body
        ..add('')
        ..add('❯ Submit');
      while (body.length < bodyRows) {
        body.add('');
      }
      indicator = _scrollSuffix(0, bodyRows, body.length);
    } else {
      final s = _states[_tab];
      List<List<String>> render(int width) => [
            for (var r = 0; r <= q!.options.length; r++)
              _rowLines(q, s, r, width, selected: r == s.cursor),
          ];
      var rows = render(_w);
      var count = rows.fold<int>(0, (a, b) => a + b.length);
      final scrollbar = count > bodyRows && _w > 1;
      if (scrollbar) {
        rows = render(_w - 1);
        count = rows.fold<int>(0, (a, b) => a + b.length);
      }
      final starts = <int>[];
      var at = 0;
      for (final r in rows) {
        starts.add(at);
        at += r.length;
      }
      final all = [for (final r in rows) ...r];
      final cursorStart = starts[s.cursor];
      final cursorEnd = s.cursor + 1 < starts.length ? starts[s.cursor + 1] : all.length;
      final maxOffset = math.max(0, all.length - bodyRows);
      var offset = s.scroll.clamp(0, maxOffset);
      if (maxOffset > 0 && (cursorStart < offset || cursorEnd > offset + bodyRows)) {
        offset = (cursorEnd - cursorStart <= bodyRows ? cursorEnd - bodyRows : cursorStart).clamp(0, maxOffset);
      }
      if (maxOffset == 0) offset = 0;
      s.scroll = offset;
      final visible = all.skip(offset).take(bodyRows).toList();
      if (scrollbar) {
        final size = math.max(1, math.min((bodyRows * bodyRows) ~/ all.length, bodyRows));
        final travel = bodyRows - size;
        final start = maxOffset == 0 ? 0 : (offset / maxOffset * travel).round();
        for (var i = 0; i < visible.length; i++) {
          final bar = i >= start && i < start + size ? '█' : '│';
          visible[i] = '${_fit(visible[i], _w - 1)}$bar';
        }
      }
      body.addAll(visible);
      while (body.length < bodyRows) {
        body.add('');
      }
      indicator = _scrollSuffix(offset, bodyRows, all.length);
    }

    final scroll = indicator.isEmpty ? '' : ' $indicator scroll ·';
    String footer;
    if (review) {
      footer = '⏎ submit · ↑/↓ scroll ·$scroll ⎋ cancel';
    } else {
      final q0 = q!;
      final enterAction = questions.length > 1 ? 'next' : 'submit';
      final action = q0.multi ? '␣ toggle · ⏎ $enterAction' : '⏎ select · n note';
      final tabs = _hasTabs ? ' · ⇥/←/→' : '';
      final titleCut = _wrap(_plain(q0.question), _w).length > 4;
      final expand = titleCut || _descOverflow(q0) ? ' · Ctrl+O ${_expanded ? 'collapse' : 'expand'}' : '';
      footer = '$action · ↑/↓ move$tabs ·$scroll ⎋ cancel$expand';
    }

    final bar = '─' * (cols - 2);
    final title = '╭─ Ask ';
    return [
      '$title${'─' * (cols - title.runes.length - 1)}╮',
      for (final h in header) _row(h),
      '├$bar┤',
      for (final b in body) _row(b),
      '├$bar┤',
      _row(footer),
      '╰$bar╯',
    ];
  }

  List<String> _editorLines() {
    final q = questions[_editorFor];
    final head = '╭─ Custom answer: ${_plain(q.question)} ';
    final bar = '─' * (cols - 2);
    final t = _editor!.split('\n');
    return [
      '${_trunc(head, cols - 1)}${'─' * math.max(0, cols - head.runes.length - 1)}╮',
      _row(''),
      for (var i = 0; i < t.length; i++) _row(i == 0 ? '> ${t[i]}' : '  ${t[i]}'),
      _row(''),
      _row('⏎ or Ctrl+Q submit  ⎋ cancel  Ctrl+G external editor'),
      _row(''),
      '╰$bar╯',
    ];
  }

  /// A pane screen: a few transcript rows, then the dialog.
  String screen({String above = 'Call the ask tool once, no other text.'}) =>
      ['', above, '', ...(closed ? const <String>[] : dialogLines())].join('\n');
}

class _Q {
  _Q({required this.cursor});

  int cursor;
  int scroll = 0;
  final selected = <int>{};
  String? custom;
}
