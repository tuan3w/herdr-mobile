import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../features/agent_session/visible_text.dart';
import '../theme.dart';
import 'highlight/highlight.dart';

/// The colours of a code block: the page it is drawn on, the plain text, and
/// one colour per [TokenKind], all from the theme's terminal palette
/// (`context.terminal`).
///
/// A palette is built for its own background. When it matches the theme (the
/// default: light on paper, dark on ink) the block sits on the quiet fill of
/// the theme and the palette's colours read on it (asserted in
/// `md_highlight_test.dart`). When the person chose a dark terminal on paper
/// the block takes the terminal's page too, so it reads as the terminal does.
@immutable
final class MdCodeColors {
  const MdCodeColors._({
    required this.background,
    required this.plain,
    required this.muted,
    required this.border,
    required this._kinds,
    required this._key,
  });

  factory MdCodeColors.of(BuildContext context) {
    final ds = context.ds;
    final term = context.terminal;
    final same = term.isDark == ds.isDark;
    final plain = same ? ds.text : term.foreground;
    final a = term.ansi;
    final comment = term.dim;
    return MdCodeColors._(
      background: same ? ds.fill : term.background,
      plain: plain,
      muted: same ? ds.textMuted : term.dim,
      border: same ? ds.hairline : term.border,
      key: (ds, term),
      kinds: [
        for (final k in TokenKind.values)
          switch (k) {
            TokenKind.plain => plain,
            TokenKind.keyword => a[5],
            TokenKind.string => a[2],
            TokenKind.comment => comment,
            TokenKind.number => a[3],
            TokenKind.type => a[6],
            TokenKind.function => a[4],
            TokenKind.constant => a[3],
            TokenKind.operator => plain,
            TokenKind.punctuation => plain,
            TokenKind.property => a[1],
            TokenKind.tag => a[1],
            TokenKind.attribute => a[3],
            TokenKind.diffAdd => a[2],
            TokenKind.diffRemove => a[1],
            TokenKind.diffMeta => a[6],
          },
      ],
    );
  }

  final Color background;
  final Color plain;

  /// The language label and the hint rows.
  final Color muted;
  final Color border;
  final List<Color> _kinds;
  final Object _key;

  Color of(TokenKind kind) => _kinds[kind.index];

  @override
  bool operator ==(Object other) => other is MdCodeColors && other._key == _key;

  @override
  int get hashCode => _key.hashCode;
}

/// Longest line the block draws; the rest is named, not drawn.
const mdCodeLineLimit = 2000;

/// Past this many lines nothing is highlighted: a message that long is data.
const mdHighlightLineBudget = 3000;

/// [raw] as a code block draws it: every character that could hide or
/// reorder what the code says made visible (`‹U+202E›`), tabs laid out to the
/// next multiple of four, one string per line, a line over [mdCodeLineLimit]
/// cut with its count.
List<String> mdCodeLines(String raw) {
  var text = visibleText(raw);
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    if (line.contains('\t')) line = _expandTabs(line);
    if (line.length > mdCodeLineLimit) {
      line = '${line.substring(0, mdCodeLineLimit)} … +${line.length - mdCodeLineLimit} characters';
    }
    lines[i] = line;
  }
  return lines;
}

String _expandTabs(String line) {
  final b = StringBuffer();
  var column = 0;
  for (var i = 0; i < line.length; i++) {
    final c = line.codeUnitAt(i);
    if (c == 0x09) {
      final n = 4 - column % 4;
      b.write(' ' * n);
      column += n;
    } else {
      b.writeCharCode(c);
      column++;
    }
  }
  return b.toString();
}

/// The lines of one code block with their syntax colours, kept between builds.
///
/// A new text keeps every leading line that is unchanged (its tokens and the
/// highlighter state after it), so a block that grows line by line costs one
/// line of tokenizing per new line, and a scroll costs none. Lines are
/// highlighted only as far as the caller shows them ([highlightUpTo]) and only
/// when complete: the caller keeps the open last line plain while it streams,
/// so a colour is never taken back.
final class MdCodeLines {
  MdCodeLines(String language) : _highlighter = language.isEmpty ? null : highlighterFor(language);

  final LineHighlighter? _highlighter;

  List<String> lines = const [''];
  final List<List<Token>> _tokens = [];
  final List<HighlightState> _after = [];
  final List<TextSpan?> _spans = [];
  MdCodeColors? _colors;

  /// Whether the language is known to the highlighter.
  bool get highlights => _highlighter != null;

  /// Points the cache at [raw]; returns true when the text changed.
  bool setText(String raw) {
    final next = mdCodeLines(raw);
    final old = lines;
    var keep = 0;
    final most = math.min(old.length, next.length);
    while (keep < most && old[keep] == next[keep]) {
      keep++;
    }
    if (keep == old.length && keep == next.length) return false;
    if (_tokens.length > keep) {
      _tokens.length = keep;
      _after.length = keep;
    }
    if (_spans.length > keep) _spans.length = keep;
    lines = next;
    return true;
  }

  /// Highlights lines `[0, count)` that are not yet (up to the budget).
  void highlightUpTo(int count) {
    final hl = _highlighter;
    if (hl == null) return;
    final end = math.min(math.min(count, lines.length), mdHighlightLineBudget);
    var state = _tokens.isEmpty ? hl.initial : _after[_tokens.length - 1];
    for (var i = _tokens.length; i < end; i++) {
      final (tokens, next) = hl.line(lines[i], state);
      _tokens.add(tokens);
      _after.add(next);
      // A line shown plain while it was still open is coloured now.
      if (i < _spans.length) _spans[i] = null;
      state = next;
    }
  }

  /// Line [i] as spans in [colors]: coloured when highlighted, else one plain
  /// span (the block's own text style gives the plain colour).
  TextSpan span(int i, MdCodeColors colors) {
    if (_colors != colors) {
      _colors = colors;
      _spans.clear();
    }
    while (_spans.length <= i) {
      _spans.add(null);
    }
    final have = _spans[i];
    if (have != null) return have;
    final text = lines[i];
    final TextSpan built;
    if (i >= _tokens.length || _tokens[i].isEmpty) {
      built = TextSpan(text: text);
    } else {
      final children = <TextSpan>[];
      var at = 0;
      for (final t in _tokens[i]) {
        final s = t.start.clamp(at, text.length);
        final e = t.end.clamp(s, text.length);
        if (s > at) children.add(TextSpan(text: text.substring(at, s)));
        if (e > s) {
          children.add(TextSpan(text: text.substring(s, e), style: t.kind == TokenKind.plain ? null : TextStyle(color: colors.of(t.kind))));
        }
        at = e;
      }
      if (at < text.length) children.add(TextSpan(text: text.substring(at)));
      built = TextSpan(children: children);
    }
    return _spans[i] = built;
  }
}
