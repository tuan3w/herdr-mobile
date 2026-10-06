/// Syntax tokenizer for code blocks: hand-written, line-based scanners, pure
/// Dart (no Flutter, no packages). It decides *what* a span is
/// ([TokenKind]); colours are the renderer's business.
///
/// ```dart
/// final h = highlighterFor('dart');           // null: unknown language
/// var state = h!.initial;
/// for (final line in code.split('\n')) {
///   final (tokens, next) = h.line(line, state);
///   state = next;
///   // tokens: sorted, non-overlapping, inside the line; gaps are plain
/// }
/// ```
///
/// ## Languages and aliases (matched case-insensitively)
///
/// | Language | Names |
/// | --- | --- |
/// | JavaScript (+JSX markup left plain) | `js`, `javascript`, `jsx`, `mjs`, `cjs`, `node` |
/// | TypeScript | `ts`, `typescript`, `tsx`, `mts`, `cts` |
/// | Python | `py`, `python`, `python3`, `py3` |
/// | Shell | `sh`, `bash`, `zsh`, `shell`, `ksh` (a leading `$ ` is a prompt) |
/// | Console session | `console`, `shellsession`, `sh-session` (only `$ ` lines are commands) |
/// | JSON | `json`, `jsonc`, `json5` |
/// | YAML | `yaml`, `yml` |
/// | TOML | `toml` |
/// | SQL | `sql`, `psql`, `postgres`, `postgresql`, `mysql`, `sqlite`, `plsql` |
/// | Rust | `rust`, `rs` |
/// | Go | `go`, `golang` |
/// | C | `c` |
/// | C++ | `cpp`, `c++`, `cc`, `cxx`, `hpp`, `hh`, `h` |
/// | Java | `java` |
/// | Kotlin | `kotlin`, `kt`, `kts` |
/// | Swift | `swift` |
/// | Dart | `dart` |
/// | HTML / XML | `html`, `htm`, `xhtml`, `xml`, `svg`, `xsd`, `xsl`, `plist` |
/// | CSS | `css` |
/// | SCSS | `scss` |
/// | Diff | `diff`, `patch`, `udiff` |
/// | Markdown | `md`, `markdown` |
/// | Dockerfile | `dockerfile`, `docker` |
/// | Makefile | `make`, `makefile`, `mk` |
///
/// Anything else (an info string such as `js title="x"` is cut at the first
/// space or brace) is unknown: [highlighterFor] returns null and the block
/// stays plain.
///
/// ## What the kinds mean
///
/// `keyword` (also directives, headings, `fn`), `string` (also regex
/// literals, chars, YAML scalars, heredoc bodies), `comment`, `number`,
/// `type` (builtin types, `Capitalized` names, lifetimes, TOML tables),
/// `function` (a name followed by `(`, Rust `name!`, shell commands, make
/// targets), `constant` (`true`, `null`, `ALL_CAPS`, `$VAR`), `operator`
/// (runs of `+ - * / = < > ! & | ^ ~ ?`, shell pipes and redirects),
/// `property` (object keys, YAML / TOML / JSON keys, CSS properties, quoted
/// SQL identifiers), `tag` and `attribute` (markup, annotations, decorators,
/// CLI options), `punctuation` (prompt `$`, YAML dashes, Markdown markers),
/// `diffAdd` / `diffRemove` / `diffMeta` (whole diff lines). Plain text,
/// brackets, commas and dots are not emitted: a gap is plain.
///
/// ## The state model
///
/// [HighlightState] is opaque, immutable and value-equal, so a renderer may
/// cache a line's tokens under `(text, state)`. Every scanner carries the same
/// small record (mode, two integers, an optional string) and returns the very
/// same instance when a line changes nothing. What is carried:
///
///  * an open block comment (nested in Rust, Kotlin, Swift, Dart);
///  * an open multi-line string: `"""` / `'''` (Python, Dart, Java, Kotlin,
///    Swift), JS template literal, Go raw string, Rust `"` and raw
///    `r#"..."#` (hash count), SQL `'...'`, shell `"..."` / `'...'`, TOML
///    `"""` / `'''`;
///  * a shell heredoc (terminator word and `<<-`), and a trailing `\` (the
///    next line continues the command; Dockerfile and Makefile use it too);
///  * a YAML block scalar (`|`, `>`) and its parent indent;
///  * a TOML multi-line array (depth);
///  * an HTML / XML comment, or a tag whose attributes span lines;
///  * CSS brace depth (selector context outside, declarations inside);
///  * an open Markdown fence.
///
/// A line's tokens and next state depend only on its text and the incoming
/// state. So a renderer may start reading at any line whose incoming state
/// is `initial` (a block that is cut into pieces, a blank line inserted at a
/// seam) and get the tokens it would have got reading from the top.
///
/// ## Bounds
///
/// A line over 2000 code units is one plain token and leaves the state as it
/// was (a minified bundle costs nothing). Scanners never throw, on any input
/// (unterminated strings and comments, lone surrogates). Cost is linear in the
/// line length, with no allocation beyond the token list (and the state when
/// it changes).
library;

import 'src/data_langs.dart';
import 'src/langs_clike.dart';
import 'src/markdown_lang.dart';
import 'src/markup.dart';
import 'src/model.dart';
import 'src/shell.dart';

export 'src/model.dart'
    show HighlightState, LineHighlighter, Token, TokenKind;

/// The highlighter for the language named [language] (an info string or file
/// extension, any case), or null when there is none.
LineHighlighter? highlighterFor(String language) {
  var name = language.trim().toLowerCase();
  if (name.isEmpty) return null;
  for (var i = 0; i < name.length; i++) {
    final c = name.codeUnitAt(i);
    if (c <= 0x20 || c == 0x7B || c == 0x2C || c == 0x3A || c == 0x28) {
      name = name.substring(0, i);
      break;
    }
  }
  if (name.startsWith('language-')) name = name.substring(9);
  final canonical = _aliases[name];
  if (canonical == null) return null;
  return _cache[canonical] ??= _build(canonical);
}

final Map<String, LineHighlighter> _cache = {};

const Map<String, String> _aliases = {
  'js': 'js', 'javascript': 'js', 'jsx': 'js', 'mjs': 'js', 'cjs': 'js',
  'node': 'js',
  'ts': 'ts', 'typescript': 'ts', 'tsx': 'ts', 'mts': 'ts', 'cts': 'ts',
  'py': 'python', 'python': 'python', 'python3': 'python', 'py3': 'python',
  'sh': 'shell', 'bash': 'shell', 'zsh': 'shell', 'shell': 'shell',
  'ksh': 'shell',
  'console': 'console', 'shellsession': 'console', 'sh-session': 'console',
  'json': 'json', 'jsonc': 'json', 'json5': 'json',
  'yaml': 'yaml', 'yml': 'yaml',
  'toml': 'toml',
  'sql': 'sql', 'psql': 'sql', 'postgres': 'sql', 'postgresql': 'sql',
  'mysql': 'sql', 'sqlite': 'sql', 'plsql': 'sql',
  'rust': 'rust', 'rs': 'rust',
  'go': 'go', 'golang': 'go',
  'c': 'c',
  'cpp': 'cpp', 'c++': 'cpp', 'cc': 'cpp', 'cxx': 'cpp', 'hpp': 'cpp',
  'hh': 'cpp', 'h': 'cpp',
  'java': 'java',
  'kotlin': 'kotlin', 'kt': 'kotlin', 'kts': 'kotlin',
  'swift': 'swift',
  'dart': 'dart',
  'html': 'html', 'htm': 'html', 'xhtml': 'html', 'xml': 'html',
  'svg': 'html', 'xsd': 'html', 'xsl': 'html', 'plist': 'html',
  'css': 'css', 'scss': 'scss',
  'diff': 'diff', 'patch': 'diff', 'udiff': 'diff',
  'md': 'markdown', 'markdown': 'markdown',
  'dockerfile': 'dockerfile', 'docker': 'dockerfile',
  'make': 'make', 'makefile': 'make', 'mk': 'make',
};

LineHighlighter _build(String canonical) {
  switch (canonical) {
    case 'js':
      return javascriptHighlighter();
    case 'ts':
      return typescriptHighlighter();
    case 'python':
      return pythonHighlighter();
    case 'shell':
      return ShellHighlighter(console: false);
    case 'console':
      return ShellHighlighter(console: true);
    case 'json':
      return JsonHighlighter();
    case 'yaml':
      return YamlHighlighter();
    case 'toml':
      return TomlHighlighter();
    case 'sql':
      return sqlHighlighter();
    case 'rust':
      return rustHighlighter();
    case 'go':
      return goHighlighter();
    case 'c':
      return cHighlighter();
    case 'cpp':
      return cppHighlighter();
    case 'java':
      return javaHighlighter();
    case 'kotlin':
      return kotlinHighlighter();
    case 'swift':
      return swiftHighlighter();
    case 'dart':
      return dartHighlighter();
    case 'html':
      return MarkupHighlighter();
    case 'css':
      return CssHighlighter(scss: false);
    case 'scss':
      return CssHighlighter(scss: true);
    case 'diff':
      return DiffHighlighter();
    case 'markdown':
      return MarkdownHighlighter();
    case 'dockerfile':
      return DockerfileHighlighter();
    default:
      return MakefileHighlighter();
  }
}
