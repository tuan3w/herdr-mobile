import 'package:herdr_mobile/ui/core/markdown/highlight/highlight.dart';

/// A (kind, source text) pair of a token.
typedef Tok = (TokenKind, String);

/// Tokenizes [code] line by line with the state carried over; returns every
/// token as (kind, text), in order.
List<Tok> tokenize(String language, String code) {
  final h = highlighterFor(language)!;
  var state = h.initial;
  final out = <Tok>[];
  for (final line in code.split('\n')) {
    final (tokens, next) = h.line(line, state);
    state = next;
    for (final t in tokens) {
      out.add((t.kind, line.substring(t.start, t.end)));
    }
  }
  return out;
}

Tok kw(String s) => (TokenKind.keyword, s);
Tok str(String s) => (TokenKind.string, s);
Tok com(String s) => (TokenKind.comment, s);
Tok num(String s) => (TokenKind.number, s);
Tok typ(String s) => (TokenKind.type, s);
Tok fn(String s) => (TokenKind.function, s);
Tok con(String s) => (TokenKind.constant, s);
Tok op(String s) => (TokenKind.operator, s);
Tok punct(String s) => (TokenKind.punctuation, s);
Tok prop(String s) => (TokenKind.property, s);
Tok tag(String s) => (TokenKind.tag, s);
Tok attr(String s) => (TokenKind.attribute, s);

/// Throws unless [tokens] are sorted, inside [line] and non-overlapping, with
/// no empty token.
void checkTokens(String line, List<Token> tokens) {
  var end = 0;
  for (final t in tokens) {
    if (t.start < end || t.end <= t.start || t.end > line.length) {
      throw StateError('bad token $t in "$line" (previous end $end)');
    }
    end = t.end;
  }
}
