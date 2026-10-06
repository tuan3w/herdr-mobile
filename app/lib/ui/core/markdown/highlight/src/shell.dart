import 'lex.dart';
import 'model.dart';
import 'words.dart';

// Keywords after which another command may follow (cmd stays true) are listed
// as `operator` in the word table (a marker, they are emitted as keywords).
final Words _shellWords = Words({
  TokenKind.operator: 'if then else elif while until do time ! { export local '
      'declare typeset readonly',
  TokenKind.keyword: 'for case select function in fi done esac [[ ]] coproc '
      'return exit break continue',
});

const int _smNormal = 0, _smDq = 1, _smSq = 2, _smHeredoc = 3;

/// The bash-ish scanner shared by shell, console, Dockerfile RUN lines and
/// Makefile recipes. It is a plain object, not a highlighter: the wrappers
/// load/store its state ([packed] and [tag]).
///
/// State: open `"` or `'` string, open heredoc (terminator in `tag`), a
/// trailing `\` (the next line continues the command), and whether a command
/// name was expected at that point.
final class ShellCore {
  ShellCore({this.make = false, this.docker = false});

  /// `$(VAR)`, `$@` are make variables, `$(shell ...)` a make function.
  final bool make;

  /// `AS` is a keyword (`FROM x AS y`).
  final bool docker;

  int smode = _smNormal;
  bool dash = false, cont = false, cmdEnd = false;
  String? tag;

  String? _pending;

  /// Where the value of a `NAME=` assignment starts (the command position
  /// survives a quoted or `$` value).
  int _assignEnd = -1;
  bool _pendingDash = false;

  int get packed =>
      smode | (dash ? 4 : 0) | (cont ? 8 : 0) | (cmdEnd ? 16 : 0);

  void unpack(int m, String? tg) {
    smode = m & 3;
    dash = m & 4 != 0;
    cont = m & 8 != 0;
    cmdEnd = m & 16 != 0;
    tag = tg;
  }

  /// Handles a line that starts inside a string or heredoc; returns where the
  /// rest of the line starts (`n` when it is all consumed).
  int resume(String t, int n, List<Token> out) {
    switch (smode) {
      case _smDq:
      case _smSq:
        final q = smode == _smDq ? 0x22 : 0x27;
        final e = _closeQuote(t, 0, n, q);
        emit(out, 0, e, TokenKind.string);
        if (e <= n && _closed) {
          smode = _smNormal;
          return e;
        }
        return n;
      case _smHeredoc:
        var k = 0;
        if (dash) k = _tabs(t, n);
        final term = tag ?? '';
        if (n - k == term.length && t.startsWith(term, k)) {
          emit(out, 0, n, TokenKind.constant);
          smode = _smNormal;
          tag = null;
          dash = false;
        } else {
          emit(out, 0, n, TokenKind.string);
        }
        return n;
    }
    return 0;
  }

  int _tabs(String t, int n) {
    var k = 0;
    while (k < n && t.codeUnitAt(k) == 0x09) {
      k++;
    }
    return k;
  }

  bool _closed = false;

  /// Index just past the closing [q] from [from], or [n] (and [_closed] false).
  int _closeQuote(String t, int from, int n, int q) {
    var i = from;
    while (i < n) {
      final c = t.codeUnitAt(i);
      if (c == 0x5C && q == 0x22) {
        i += 2;
      } else if (c == q) {
        _closed = true;
        return i + 1;
      } else {
        i++;
      }
    }
    _closed = false;
    return n;
  }

  static bool _delimiter(int c) {
    if (c <= 0x20) return true;
    switch (c) {
      case 0x3B: // ;
      case 0x7C: // |
      case 0x26: // &
      case 0x28: // (
      case 0x29: // )
      case 0x3C: // <
      case 0x3E: // >
      case 0x22: // "
      case 0x27: // '
      case 0x60: // `
      case 0x24: // $
        return true;
    }
    return false;
  }

  int _wordEnd(String t, int i, int n) {
    var j = i;
    while (j < n) {
      final c = t.codeUnitAt(j);
      if (c == 0x5C) {
        j += 2;
      } else if (_delimiter(c)) {
        break;
      } else {
        j++;
      }
    }
    return j > n ? n : j;
  }

  /// Scans [t] from [from]; [cmd] says a command name is expected first.
  /// [heredocs] is off for make.
  void run(String t, int from, int n, List<Token> out, {required bool cmd}) {
    var i = from;
    _pending = null;
    _assignEnd = -1;
    while (i < n) {
      final c = t.codeUnitAt(i);
      if (c <= 0x20) {
        i++;
        continue;
      }
      switch (c) {
        case 0x23: // #
          emit(out, i, n, TokenKind.comment);
          i = n;
        case 0x24: // $
          final keep = i == _assignEnd;
          final r = _dollar(t, i, n, out, cmd);
          cmd = keep || r.cmd;
          i = r.end;
        case 0x22: // "
          final keep = i == _assignEnd;
          final e = _closeQuote(t, i + 1, n, 0x22);
          emit(out, i, e, TokenKind.string);
          if (!_closed) smode = _smDq;
          cmd = keep;
          i = e;
        case 0x27: // '
          final keep = i == _assignEnd;
          final e = _closeQuote(t, i + 1, n, 0x27);
          emit(out, i, e, TokenKind.string);
          if (!_closed) smode = _smSq;
          cmd = keep;
          i = e;
        case 0x5C: // a trailing backslash continues the line
          if (i + 1 < n) {
            final r = _word(t, i, n, out, cmd);
            cmd = r.cmd;
            i = r.end;
          } else {
            i++;
          }
        case 0x60: // `
          cmd = true;
          i++;
        case 0x28: // (
          cmd = true;
          i++;
        case 0x29: // )
          cmd = false;
          i++;
        case 0x3C: // <
        case 0x3E: // >
        case 0x7C: // |
        case 0x26: // &
        case 0x3B: // ;
          final h = !make && c == 0x3C ? _heredoc(t, i, n, out) : -1;
          if (h >= 0) {
            i = h;
            break;
          }
          var j = i + 1;
          var redirect = c == 0x3C || c == 0x3E;
          while (j < n) {
            final d = t.codeUnitAt(j);
            if (d != 0x3C &&
                d != 0x3E &&
                d != 0x7C &&
                d != 0x26 &&
                d != 0x3B) {
              break;
            }
            if (d == 0x3C || d == 0x3E) redirect = true;
            j++;
          }
          emit(out, i, j, TokenKind.operator);
          if (!redirect) cmd = true;
          i = j;
        default:
          final r = _word(t, i, n, out, cmd);
          cmd = r.cmd;
          i = r.end;
      }
    }
    if (_pending != null) {
      smode = _smHeredoc;
      tag = _pending;
      dash = _pendingDash;
    }
    cont = n > 0 && t.codeUnitAt(n - 1) == 0x5C && smode == _smNormal;
    cmdEnd = cont && cmd;
  }

  /// `<<TAG`, `<<-TAG`, `<<'TAG'`, `<<"TAG"`: returns the index after it, or
  /// -1 when this `<` is not a heredoc.
  int _heredoc(String t, int i, int n, List<Token> out) {
    if (i + 2 >= n || t.codeUnitAt(i + 1) != 0x3C) return -1;
    if (t.codeUnitAt(i + 2) == 0x3C) return -1;
    if (i > 0 && t.codeUnitAt(i - 1) == 0x3C) return -1;
    var j = i + 2;
    final dashed = t.codeUnitAt(j) == 0x2D;
    if (dashed) j++;
    j = skipBlanks(t, j, n);
    if (j >= n) return -1;
    final q = t.codeUnitAt(j);
    int tagStart, tagEnd, end;
    if (q == 0x27 || q == 0x22) {
      tagStart = j + 1;
      tagEnd = tagStart;
      while (tagEnd < n && t.codeUnitAt(tagEnd) != q) {
        tagEnd++;
      }
      if (tagEnd >= n || tagEnd == tagStart) return -1;
      end = tagEnd + 1;
    } else if (isIdentStart(q)) {
      tagStart = j;
      tagEnd = j + 1;
      while (tagEnd < n && isIdentPart(t.codeUnitAt(tagEnd))) {
        tagEnd++;
      }
      end = tagEnd;
    } else {
      return -1;
    }
    emit(out, i, dashed ? i + 3 : i + 2, TokenKind.operator);
    emit(out, j, end, TokenKind.constant);
    _pending = t.substring(tagStart, tagEnd);
    _pendingDash = dashed;
    return end;
  }

  ({int end, bool cmd}) _dollar(
      String t, int i, int n, List<Token> out, bool cmd) {
    if (i + 1 >= n) return (end: i + 1, cmd: cmd);
    final c1 = t.codeUnitAt(i + 1);
    if (c1 == 0x7B) {
      var j = i + 2;
      while (j < n && t.codeUnitAt(j) != 0x7D) {
        j++;
      }
      if (j < n) j++;
      emit(out, i, j, TokenKind.constant);
      return (end: j, cmd: false);
    }
    if (c1 == 0x28) {
      if (i + 2 < n && t.codeUnitAt(i + 2) == 0x28) {
        return (end: i + 3, cmd: false);
      }
      if (make) return _makeCall(t, i, n, out);
      emit(out, i, i + 2, TokenKind.operator);
      return (end: i + 2, cmd: true);
    }
    if (isIdentStart(c1)) {
      var j = i + 2;
      while (j < n && isIdentPart(t.codeUnitAt(j))) {
        j++;
      }
      emit(out, i, j, TokenKind.constant);
      return (end: j, cmd: false);
    }
    if (isDigit(c1) || _specialParam(c1)) {
      emit(out, i, i + 2, TokenKind.constant);
      return (end: i + 2, cmd: false);
    }
    return (end: i + 1, cmd: cmd);
  }

  bool _specialParam(int c) {
    switch (c) {
      case 0x40: // @
      case 0x2A: // *
      case 0x23: // #
      case 0x3F: // ?
      case 0x21: // !
      case 0x24: // $
      case 0x2D: // -
        return true;
      case 0x3C: // <
      case 0x5E: // ^
      case 0x2B: // +
      case 0x25: // %
        return make;
    }
    return false;
  }

  /// Make: `$(NAME)` is a variable, `$(name args)` a function call.
  ({int end, bool cmd}) _makeCall(String t, int i, int n, List<Token> out) {
    var j = i + 2;
    while (j < n) {
      final c = t.codeUnitAt(j);
      if (isIdentPart(c) || c == 0x2D || c == 0x2E) {
        j++;
      } else {
        break;
      }
    }
    if (j < n && t.codeUnitAt(j) == 0x29) {
      emit(out, i, j + 1, TokenKind.constant);
      return (end: j + 1, cmd: false);
    }
    if (j < n && j > i + 2 && t.codeUnitAt(j) == 0x20) {
      emit(out, i, i + 2, TokenKind.operator);
      emit(out, i + 2, j, TokenKind.function);
      return (end: j, cmd: false);
    }
    // `$(SRC:.c=.o)`, `$(call f,x)`: a variable reference up to its `)`
    var depth = 1;
    for (var x = i + 2; x < n; x++) {
      final c = t.codeUnitAt(x);
      if (c == 0x28) depth++;
      if (c == 0x29 && --depth == 0) {
        emit(out, i, x + 1, TokenKind.constant);
        return (end: x + 1, cmd: false);
      }
    }
    emit(out, i, i + 2, TokenKind.operator);
    return (end: i + 2, cmd: false);
  }

  ({int end, bool cmd}) _word(
      String t, int s, int n, List<Token> out, bool cmd) {
    final c = t.codeUnitAt(s);
    if (cmd && isIdentStart(c) && c != 0x24) {
      // NAME=value / NAME+=value
      var k = s + 1;
      while (k < n && isIdentPart(t.codeUnitAt(k))) {
        k++;
      }
      final plus = k < n && t.codeUnitAt(k) == 0x2B;
      final eq = plus ? k + 1 : k;
      if (eq < n && t.codeUnitAt(eq) == 0x3D) {
        emit(out, s, k, TokenKind.property);
        emit(out, k, eq + 1, TokenKind.operator);
        _assignEnd = eq + 1;
        return (end: _wordEnd(t, eq + 1, n), cmd: true);
      }
    }
    var e = _wordEnd(t, s, n);
    if (e == s) e = s + 1;
    if (cmd) {
      if (c == 0x2D && e - s > 1 && !isDigit(t.codeUnitAt(s + 1))) {
        emit(out, s, _optionEnd(t, s, e), TokenKind.attribute);
        return (end: e, cmd: true);
      }
      final k = _shellWords.find(t, s, e);
      if (k != null) {
        emit(out, s, e, TokenKind.keyword);
        return (end: e, cmd: k == TokenKind.operator);
      }
      if (e - s == 1 && c == 0x7D) {
        emit(out, s, e, TokenKind.keyword);
        return (end: e, cmd: false);
      }
      emit(out, s, e, TokenKind.function);
      return (end: e, cmd: false);
    }
    if (c == 0x2D && e - s > 1) {
      if (!isDigit(t.codeUnitAt(s + 1))) {
        emit(out, s, _optionEnd(t, s, e), TokenKind.attribute);
      } else if (_allDigits(t, s + 1, e)) {
        emit(out, s, e, TokenKind.number);
      }
    } else if (isDigit(c)) {
      if (_allDigits(t, s, e)) emit(out, s, e, TokenKind.number);
    } else if (_isWord(t, s, e, 'in') ||
        _isWord(t, s, e, '[[') ||
        _isWord(t, s, e, ']]') ||
        (docker && (_isWord(t, s, e, 'AS') || _isWord(t, s, e, 'as')))) {
      emit(out, s, e, TokenKind.keyword);
    }
    return (end: e, cmd: false);
  }

  int _optionEnd(String t, int s, int e) {
    for (var k = s; k < e; k++) {
      if (t.codeUnitAt(k) == 0x3D) return k;
    }
    return e;
  }

  bool _allDigits(String t, int s, int e) {
    for (var k = s; k < e; k++) {
      if (!isDigit(t.codeUnitAt(k))) return false;
    }
    return true;
  }

  bool _isWord(String t, int s, int e, String w) =>
      e - s == w.length && t.startsWith(w, s);
}

/// Shell, bash, zsh, sh and `console` (a session: only `$ ` prompt lines are
/// commands, the rest is output and stays plain). In shell languages a leading
/// `$ ` is also read as a prompt.
final class ShellHighlighter extends LineScanner {
  ShellHighlighter({required this.console});

  final bool console;
  final ShellCore _core = ShellCore();

  @override
  void scan(String t, int n, List<Token> out) {
    final core = _core..unpack(mode, tag);
    var i = 0;
    var cmd = true;
    if (core.smode != _smNormal) {
      i = core.resume(t, n, out);
      cmd = false;
    } else if (core.cont) {
      cmd = core.cmdEnd;
      final k = skipBlanks(t, 0, n);
      if (console && k + 1 < n && t.codeUnitAt(k) == 0x3E &&
          t.codeUnitAt(k + 1) == 0x20) {
        emit(out, k, k + 1, TokenKind.punctuation);
        i = k + 1;
      }
    } else {
      final k = skipBlanks(t, 0, n);
      if (k < n && t.codeUnitAt(k) == 0x24 && (k + 1 == n || t.codeUnitAt(k + 1) == 0x20)) {
        emit(out, k, k + 1, TokenKind.punctuation);
        i = k + 1;
      } else if (console) {
        if (k < n && t.codeUnitAt(k) == 0x23) emit(out, k, n, TokenKind.comment);
        core
          ..cont = false
          ..cmdEnd = false;
        mode = core.packed;
        tag = core.tag;
        return;
      }
    }
    if (core.smode == _smNormal) core.run(t, i, n, out, cmd: cmd);
    mode = core.packed;
    tag = core.tag;
  }
}

/// Dockerfile: instructions, flags, and shell-scanned RUN/CMD/ENTRYPOINT.
/// State: the shell core's, plus (bit 8) "this instruction is a shell form".
final class DockerfileHighlighter extends LineScanner {
  DockerfileHighlighter();

  final ShellCore _core = ShellCore(docker: true);

  static final Words _instructions = Words({
    TokenKind.keyword: 'from run cmd label maintainer expose env add copy '
        'entrypoint volume user workdir arg onbuild stopsignal healthcheck '
        'shell',
  }, ignoreCase: true);

  @override
  void scan(String t, int n, List<Token> out) {
    final core = _core..unpack(mode & 0xFF, tag);
    var shellForm = mode & 0x100 != 0;
    var i = 0;
    var cmd = false;
    if (core.smode != _smNormal) {
      i = core.resume(t, n, out);
      if (core.smode != _smNormal || i >= n) {
        _store(core, shellForm);
        return;
      }
      cmd = false;
    } else if (core.cont) {
      final k = skipBlanks(t, 0, n);
      if (k < n && t.codeUnitAt(k) == 0x23) {
        emit(out, k, n, TokenKind.comment);
        _store(core, shellForm);
        return;
      }
      cmd = shellForm && core.cmdEnd;
    } else {
      shellForm = false;
      var k = skipBlanks(t, 0, n);
      if (k >= n) {
        _store(core..cont = false, false);
        return;
      }
      if (t.codeUnitAt(k) == 0x23) {
        emit(out, k, n, TokenKind.comment);
        _store(core..cont = false, false);
        return;
      }
      var e = _word(t, k, n);
      var inst = _instructions.find(t, k, e);
      if (inst != null) {
        emit(out, k, e, TokenKind.keyword);
        var word = t.substring(k, e).toLowerCase();
        if (word == 'onbuild') {
          final k2 = skipBlanks(t, e, n);
          final e2 = _word(t, k2, n);
          if (_instructions.find(t, k2, e2) != null) {
            emit(out, k2, e2, TokenKind.keyword);
            word = t.substring(k2, e2).toLowerCase();
            e = e2;
          }
        }
        shellForm = word == 'run' || word == 'cmd' || word == 'entrypoint';
        if (word == 'healthcheck') shellForm = false;
        i = e;
        cmd = shellForm;
        if (shellForm) {
          // `RUN ["a", "b"]` is the exec form.
          final k3 = skipBlanks(t, e, n);
          if (k3 < n && t.codeUnitAt(k3) == 0x5B) cmd = false;
        }
      } else {
        i = k;
      }
    }
    core.run(t, i, n, out, cmd: cmd);
    _store(core, shellForm);
  }

  int _word(String t, int k, int n) {
    var e = k;
    while (e < n && isLetter(t.codeUnitAt(e))) {
      e++;
    }
    return e;
  }

  void _store(ShellCore core, bool shellForm) {
    mode = core.packed | (shellForm ? 0x100 : 0);
    tag = core.tag;
  }
}

/// Makefile: comments, directives, assignments, rule targets, `$(VAR)`,
/// recipes scanned as shell.
final class MakefileHighlighter extends LineScanner {
  MakefileHighlighter();

  final ShellCore _core = ShellCore(make: true);

  static final Words _directives = Words({
    TokenKind.keyword: 'ifeq ifneq ifdef ifndef else endif include -include '
        'sinclude define endef export unexport override vpath undefine',
  });

  @override
  void scan(String t, int n, List<Token> out) {
    final core = _core..unpack(mode, tag);
    var i = 0;
    var cmd = false;
    if (core.smode != _smNormal) {
      i = core.resume(t, n, out);
      if (core.smode != _smNormal || i >= n) {
        _store(core);
        return;
      }
    } else if (core.cont) {
      cmd = core.cmdEnd;
      i = skipBlanks(t, 0, n);
    } else if (n > 0 && t.codeUnitAt(0) == 0x09) {
      i = 1;
      while (i < n) {
        final c = t.codeUnitAt(i);
        if (c == 0x40 || c == 0x2D || c == 0x2B || isSpace(c)) {
          if (!isSpace(c)) emit(out, i, i + 1, TokenKind.operator);
          i++;
        } else {
          break;
        }
      }
      cmd = true;
    } else {
      i = _statement(t, n, out);
      if (i < 0) {
        core.cont = false;
        _store(core);
        return;
      }
    }
    core.run(t, i, n, out, cmd: cmd);
    _store(core);
  }

  /// Handles the head of a non-recipe line; returns where the shell scan
  /// starts, or -1 when the whole line is done.
  int _statement(String t, int n, List<Token> out) {
    final k = skipBlanks(t, 0, n);
    if (k >= n) return -1;
    if (t.codeUnitAt(k) == 0x23) {
      emit(out, k, n, TokenKind.comment);
      return -1;
    }
    var e = k;
    while (e < n && !isSpace(t.codeUnitAt(e)) && t.codeUnitAt(e) != 0x3A) {
      e++;
    }
    if (_directives.find(t, k, e) != null) {
      emit(out, k, e, TokenKind.keyword);
      return e;
    }
    // assignment: NAME [:?+!]= value
    var j = k;
    while (j < n) {
      final c = t.codeUnitAt(j);
      if (isIdentPart(c) || c == 0x2E || c == 0x2D) {
        j++;
      } else {
        break;
      }
    }
    if (j > k) {
      var m = skipBlanks(t, j, n);
      final op = m;
      while (m < n && ":?+!".contains(t[m])) {
        m++;
      }
      if (m < n && t.codeUnitAt(m) == 0x3D) {
        emit(out, k, j, TokenKind.property);
        emit(out, op, m + 1, TokenKind.operator);
        return m + 1;
      }
    }
    // rule: targets : prerequisites
    var depth = 0;
    for (var x = k; x < n; x++) {
      final c = t.codeUnitAt(x);
      if (c == 0x24 && x + 1 < n) {
        final d = t.codeUnitAt(x + 1);
        if (d == 0x28 || d == 0x7B) {
          depth++;
          x++;
        }
      } else if ((c == 0x29 || c == 0x7D) && depth > 0) {
        depth--;
      } else if (c == 0x3A && depth == 0) {
        _targets(t, k, x, out);
        var end = x + 1;
        if (end < n && t.codeUnitAt(end) == 0x3A) end++;
        emit(out, x, end, TokenKind.operator);
        return end;
      }
    }
    return k;
  }

  void _targets(String t, int from, int to, List<Token> out) {
    var i = from;
    while (i < to) {
      if (isSpace(t.codeUnitAt(i))) {
        i++;
        continue;
      }
      var e = i;
      while (e < to && !isSpace(t.codeUnitAt(e))) {
        e++;
      }
      final special = t.codeUnitAt(i) == 0x2E &&
          i + 1 < e &&
          isUpper(t.codeUnitAt(i + 1));
      emit(out, i, e, special ? TokenKind.keyword : TokenKind.function);
      i = e;
    }
  }

  void _store(ShellCore core) {
    mode = core.packed;
    tag = core.tag;
  }
}
