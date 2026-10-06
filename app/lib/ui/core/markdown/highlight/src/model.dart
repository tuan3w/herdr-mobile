/// What a token is. Colours are the renderer's business.
enum TokenKind {
  plain,
  keyword,
  string,
  comment,
  number,
  type,
  function,
  constant,
  operator,
  punctuation,
  property,
  tag,
  attribute,
  diffAdd,
  diffRemove,
  diffMeta,
}

/// A coloured span of one line: `[start, end)` in UTF-16 code units of the
/// line (no newline). Tokens of a line are sorted and never overlap; the gaps
/// between them are plain.
final class Token {
  const Token(this.start, this.end, this.kind);

  final int start, end;
  final TokenKind kind;

  @override
  bool operator ==(Object other) =>
      other is Token &&
      other.start == start &&
      other.end == end &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(start, end, kind);

  @override
  String toString() => '${kind.name}[$start,$end)';
}

/// What a highlighter carries from one line to the next (an open block
/// comment, an open multi-line string...). Opaque, immutable and value-equal,
/// so a renderer may cache a line's tokens under (text, state).
abstract interface class HighlightState {}

/// A line-based tokenizer for one language.
abstract interface class LineHighlighter {
  /// The state before the first line.
  HighlightState get initial;

  /// Tokens of [text] (one line, no newline) read in [state], and the state
  /// for the next line. Never throws; a line over 2000 code units comes back
  /// as one plain token with the state unchanged.
  (List<Token>, HighlightState) line(String text, HighlightState state);
}
