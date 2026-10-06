import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/markdown/md_text.dart';
import 'package:herdr_mobile/ui/core/terminal_links.dart';

/// What a link must be: kind, displayed text, target, line and column.
typedef _Link = ({
  TerminalLinkKind kind,
  String text,
  String target,
  int? line,
  int? column,
});

/// A path link displayed as [text]; [target] defaults to [text], so a case
/// with a position suffix names its target.
_Link _p(String text, {String? target, int? line, int? col}) => (
  kind: TerminalLinkKind.path,
  text: text,
  target: target ?? text,
  line: line,
  column: col,
);

_Link _u(String url) => (
  kind: TerminalLinkKind.url,
  text: url,
  target: url,
  line: null,
  column: null,
);

/// A line of terminal output or agent text and the links it must give, in
/// order. `[]` means the line must stay plain: every entry that expects
/// nothing is a guard against noise (slash commands, folders, versions...).
typedef _Case = (String input, List<_Link> links);

final List<_Case> _cases = [
  // -- compiler errors, stack traces, test runners ----------------------------
  (
    "lib/a.dart:12:5: error: Undefined name 'x'.",
    [_p('lib/a.dart:12:5', target: 'lib/a.dart', line: 12, col: 5)],
  ),
  (
    '    at Foo (src/x.ts:10:3)',
    [_p('src/x.ts:10:3', target: 'src/x.ts', line: 10, col: 3)],
  ),
  (
    '    at Object.<anonymous> (/home/me/app/index.js:5:9)',
    [
      _p(
        '/home/me/app/index.js:5:9',
        target: '/home/me/app/index.js',
        line: 5,
        col: 9,
      ),
    ],
  ),
  ('    at async Promise.all (index 0)', []),
  (
    '    at com.foo.Bar.run(Bar.java:42)',
    [_p('Bar.java:42', target: 'Bar.java', line: 42)],
  ),
  (
    ' --> src/main.rs:4:5',
    [_p('src/main.rs:4:5', target: 'src/main.rs', line: 4, col: 5)],
  ),
  (
    './main.go:10:2: undefined: foo',
    [_p('./main.go:10:2', target: './main.go', line: 10, col: 2)],
  ),
  (
    "src/app.ts(10,3): error TS2304: Cannot find name 'x'.",
    [_p('src/app.ts(10,3)', target: 'src/app.ts', line: 10, col: 3)],
  ),
  ('  File "/x/y.py", line 12, in <module>', [_p('/x/y.py', line: 12)]),
  (
    "error • Undefined name 'x' • lib/a.dart:12:5 • undefined_identifier",
    [_p('lib/a.dart:12:5', target: 'lib/a.dart', line: 12, col: 5)],
  ),
  (
    '  error - lib/a.dart:12:5 - msg - rule',
    [_p('lib/a.dart:12:5', target: 'lib/a.dart', line: 12, col: 5)],
  ),
  (
    'FAIL test/a_test.dart: loading test/a_test.dart',
    [_p('test/a_test.dart'), _p('test/a_test.dart')],
  ),
  (
    "thread 'main' panicked at src/main.rs:4:5:",
    [_p('src/main.rs:4:5', target: 'src/main.rs', line: 4, col: 5)],
  ),
  (
    '\t/usr/local/go/src/runtime/panic.go:770 +0x118',
    [
      _p(
        '/usr/local/go/src/runtime/panic.go:770',
        target: '/usr/local/go/src/runtime/panic.go',
        line: 770,
      ),
    ],
  ),
  ('tests/test_a.py::test_x FAILED', [_p('tests/test_a.py')]),
  (
    'tests/test_a.py:12: AssertionError',
    [_p('tests/test_a.py:12', target: 'tests/test_a.py', line: 12)],
  ),
  ('/home/me/app/src/a.js', [_p('/home/me/app/src/a.js')]),
  ('TODO(me): fix lib/a.dart', [_p('lib/a.dart')]),
  ('Wrote build/app.apk (12.3MB)', [_p('build/app.apk')]),
  ('Saved to ~/out/report.pdf', [_p('~/out/report.pdf')]),
  ('open /tmp/x.png', [_p('/tmp/x.png')]),
  ('docs/DESIGN.md has the rules', [_p('docs/DESIGN.md')]),
  // -- git --------------------------------------------------------------------
  ('modified:   lib/x.dart', [_p('lib/x.dart')]),
  ('new file:   test/y_test.dart', [_p('test/y_test.dart')]),
  ('deleted:    old/z.dart', [_p('old/z.dart')]),
  ('renamed:    a.dart -> lib/b.dart', [_p('a.dart'), _p('lib/b.dart')]),
  (' M lib/a.dart', [_p('lib/a.dart')]),
  ('?? notes.md', [_p('notes.md')]),
  (' lib/a.dart | 12 ++--', [_p('lib/a.dart')]),
  // A stat line is not a diff header: the leading `a/` is a real folder.
  (' a/b/c.dart | 12 ++--', [_p('a/b/c.dart')]),
  (' 3 files changed, 14 insertions(+), 2 deletions(-)', []),
  ('--- a/lib/x.dart', [_p('a/lib/x.dart', target: 'lib/x.dart')]),
  ('+++ b/lib/x.dart', [_p('b/lib/x.dart', target: 'lib/x.dart')]),
  (
    'diff --git a/lib/x.dart b/lib/y.dart',
    [
      _p('a/lib/x.dart', target: 'lib/x.dart'),
      _p('b/lib/y.dart', target: 'lib/y.dart'),
    ],
  ),
  ('--- /dev/null', []),
  ('+++ b/new.txt', [_p('b/new.txt', target: 'new.txt')]),
  ('@@ -1,3 +1,4 @@ void main() {', []),
  ('index 83db48f..bf2a3c1 100644', []),
  ('a/lib/x.dart', [_p('a/lib/x.dart')]),
  // -- ls, listings -----------------------------------------------------------
  ('-rw-r--r--  1 me me  1234 Jan  5 09:00 notes.md', [_p('notes.md')]),
  ('drwxr-xr-x  2 me me  4096 Jan  5 09:00 src', []),
  ('drwxr-xr-x  2 me me  4096 Jan  5 09:00 lib', []),
  (
    'lrwxrwxrwx  1 me me    11 Jan  5 09:00 link -> target.txt',
    [_p('target.txt')],
  ),
  ('-rwxr-xr-x  1 me me   100 Jan  5 09:00 run.sh', [_p('run.sh')]),
  (
    'lib  test  build  pubspec.yaml  README.md',
    [_p('pubspec.yaml'), _p('README.md')],
  ),
  ('total 48', []),
  ('src/  docs/  tests/', []),
  ('README.md  39B', [_p('README.md')]),
  // -- prose, markdown, quoting ----------------------------------------------
  ('See `lib/a.dart` for details.', [_p('lib/a.dart')]),
  ('Edit(/home/me/p/a.md)', [_p('/home/me/p/a.md')]),
  ('Read(lib/a.dart)', [_p('lib/a.dart')]),
  ('"lib/a.dart"', [_p('lib/a.dart')]),
  ("'lib/a.dart'", [_p('lib/a.dart')]),
  ('(lib/a.dart)', [_p('lib/a.dart')]),
  ('[lib/a.dart]', [_p('lib/a.dart')]),
  ('<lib/a.dart>', [_p('lib/a.dart')]),
  ('lib/a.dart,', [_p('lib/a.dart')]),
  ('lib/a.dart.', [_p('lib/a.dart')]),
  ('lib/a.dart;', [_p('lib/a.dart')]),
  ('lib/a.dart:', [_p('lib/a.dart')]),
  ('lib/a.dart)', [_p('lib/a.dart')]),
  ('*lib/a.dart*', [_p('lib/a.dart')]),
  ('**lib/a.dart**', [_p('lib/a.dart')]),
  ('|lib/a.dart|', [_p('lib/a.dart')]),
  ('→ lib/a.dart', [_p('lib/a.dart')]),
  ('“lib/a.dart”', [_p('lib/a.dart')]),
  ('lib/a.dart and lib/b.dart', [_p('lib/a.dart'), _p('lib/b.dart')]),
  ('2>/tmp/err.log', [_p('/tmp/err.log')]),
  ('cat file.txt > out.txt', [_p('file.txt'), _p('out.txt')]),
  ('--out=build/app.apk', [_p('build/app.apk')]),
  ('│ src/a.dart │', [_p('src/a.dart')]),
  (
    '[path/to/results.tsv] [--format text|json|md]',
    [_p('path/to/results.tsv')],
  ),
  ('<img src="assets/logo.png"/>', [_p('assets/logo.png')]),
  ('x-foo/bar.txt', [_p('x-foo/bar.txt')]),
  // -- positions --------------------------------------------------------------
  ('a.dart:12', [_p('a.dart:12', target: 'a.dart', line: 12)]),
  (
    'lib/a.dart:12:5.',
    [_p('lib/a.dart:12:5', target: 'lib/a.dart', line: 12, col: 5)],
  ),
  (
    'lib/a.dart:12-20',
    [_p('lib/a.dart:12-20', target: 'lib/a.dart', line: 12)],
  ),
  (
    'lib/a.dart:12:5-9',
    [_p('lib/a.dart:12:5-9', target: 'lib/a.dart', line: 12, col: 5)],
  ),
  ('lib/a.dart (line 12)', [_p('lib/a.dart', line: 12)]),
  ('lib/a.dart (lines 12-20)', [_p('lib/a.dart', line: 12)]),
  ('lib/a.dart#L12', [_p('lib/a.dart#L12', target: 'lib/a.dart', line: 12)]),
  (
    'lib/a.dart#L12-L20',
    [_p('lib/a.dart#L12-L20', target: 'lib/a.dart', line: 12)],
  ),
  (
    'lib/a.dart#L12C3',
    [_p('lib/a.dart#L12C3', target: 'lib/a.dart', line: 12, col: 3)],
  ),
  ('lib/a.dart (12)', [_p('lib/a.dart')]),
  ('lib/a.dart:x', [_p('lib/a.dart')]),
  ('lib/a.dart:12345678', [_p('lib/a.dart')]),
  // -- prefixes ---------------------------------------------------------------
  ('~/x/y.md', [_p('~/x/y.md')]),
  ('see ~/notes.md.', [_p('~/notes.md')]),
  ('./x.sh', [_p('./x.sh')]),
  ('../x/y.dart', [_p('../x/y.dart')]),
  ('../../a.txt', [_p('../../a.txt')]),
  ('~/.bashrc', [_p('~/.bashrc')]),
  ('~/.ssh/config', [_p('~/.ssh/config')]),
  ("add 'set -g x on' to ~/.tmux.conf and reattach", [_p('~/.tmux.conf')]),
  ('/etc/hosts', [_p('/etc/hosts')]),
  ('/main.py', [_p('/main.py')]),
  ('/skills/tdd/SKILL.md', [_p('/skills/tdd/SKILL.md')]),
  ('.github/workflows/ci.yml', [_p('.github/workflows/ci.yml')]),
  // -- well-known names and dotfiles -----------------------------------------
  ('Makefile', [_p('Makefile')]),
  ('Dockerfile', [_p('Dockerfile')]),
  ('LICENSE', [_p('LICENSE')]),
  ('README', [_p('README')]),
  ('Gemfile', [_p('Gemfile')]),
  ('go.mod', [_p('go.mod')]),
  ('lib/Makefile', [_p('lib/Makefile')]),
  ('docker/Dockerfile', [_p('docker/Dockerfile')]),
  ('Dockerfile.dev', [_p('Dockerfile.dev')]),
  ('.gitignore', [_p('.gitignore')]),
  ('lib/.gitignore', [_p('lib/.gitignore')]),
  ('.env', [_p('.env')]),
  ('.env.local', [_p('.env.local')]),
  ('.eslintrc.json', [_p('.eslintrc.json')]),
  ('__init__.py', [_p('__init__.py')]),
  ('src/__init__.py', [_p('src/__init__.py')]),
  ('_config.yml', [_p('_config.yml')]),
  ('package.json', [_p('package.json')]),
  ('main.py', [_p('main.py')]),
  ('x.tar.gz', [_p('x.tar.gz')]),
  ('2024-report.pdf', [_p('2024-report.pdf')]),
  ('báo-cáo.md', [_p('báo-cáo.md')]),
  ('~/Tài_liệu/báo-cáo.md', [_p('~/Tài_liệu/báo-cáo.md')]),
  ('日本語/ファイル.txt', [_p('日本語/ファイル.txt')]),
  ('src/app.component.spec.ts', [_p('src/app.component.spec.ts')]),
  ('src/App.vue', [_p('src/App.vue')]),
  ('#include "foo.h"', [_p('foo.h')]),
  ("import 'bar.dart';", [_p('bar.dart')]),
  ("import 'lib/bar.dart';", [_p('lib/bar.dart')]),
  // -- URLs -------------------------------------------------------------------
  ('https://x.dev/a', [_u('https://x.dev/a')]),
  ('see https://x.dev/a.', [_u('https://x.dev/a')]),
  ('(https://x.dev/a)', [_u('https://x.dev/a')]),
  ('[docs](https://x.dev/a)', [_u('https://x.dev/a')]),
  ('http://localhost:3000/health', [_u('http://localhost:3000/health')]),
  (
    'https://github.com/foo/bar/blob/main/lib/a.dart#L10',
    [_u('https://github.com/foo/bar/blob/main/lib/a.dart#L10')],
  ),
  ('https://x.dev/a lib/b.dart', [_u('https://x.dev/a'), _p('lib/b.dart')]),
  // -- slash commands are never paths -----------------------------------------
  ('/model', []),
  ('/compact', []),
  ('/resume', []),
  ('/help', []),
  ('/clear', []),
  ('/plan', []),
  ('❯ /model', []),
  ('> /compact', []),
  ('\$ /resume', []),
  ('/model sonnet', []),
  ('Use /resume to continue', []),
  ('(/help)', []),
  ('type /help.', []),
  ('/model.', []),
  ('/ars-cache-invalidate — drop cached entries', []),
  ('/loop 5m /foo', []),
  ("You've used 90% of your weekly limit · /usage-credits to keep using", []),
  ('/init - create an AGENTS.md file with instructions', [_p('AGENTS.md')]),
  ('/review src/a.dart', [_p('src/a.dart')]),
  ('/add-dir ~/x/y.md', [_p('~/x/y.md')]),
  ('/', []),
  ('//', []),
  // -- folders do not link ----------------------------------------------------
  ('src/', []),
  ('lib/ui/', []),
  ('/etc/', []),
  ('~/Documents/', []),
  ('./build/', []),
  ('../', []),
  ('./', []),
  ('~/', []),
  ('/usr/local/bin', []),
  ('/tmp/scratch', []),
  ('/home/me/project', []),
  ('lib/ui', []),
  ('~/Desktop', []),
  ('./x', []),
  ('../x', []),
  ('~/.omp', []),
  ('~/.config/nvim', []),
  ('node_modules/.bin/tsc', []),
  ('ls -1 /tmp/scratch', []),
  ('- tests/ for the suites', []),
  // -- versions, dates, ratios, words, flags ----------------------------------
  ('1.2.3', []),
  ('v1.2.3', []),
  ('0.4.12+34', []),
  ('10.0.0.1:8080', []),
  ('3.14', []),
  ('12:30:45', []),
  ('2026-10-05T12:00:00Z', []),
  ('and/or', []),
  ('w/o', []),
  ('10/05/2026', []),
  ('2026/10/05', []),
  ('05/10/26.', []),
  ('TCP/IP', []),
  ('input/output', []),
  ('input/output.', []),
  ('read/write access', []),
  ('50/50', []),
  ('1/2 cup', []),
  ('km/h', []),
  ('a/b', []),
  ('src/lib', []),
  ('--foo/bar', []),
  ('--no-color', []),
  ('-rw-r--r--', []),
  ('e.g. this, i.e. that, etc.', []),
  ('foo.bar', []),
  ('a.b.c', []),
  ('The quick brown fox jumps over the lazy dog.', []),
  // -- not on this machine's file system --------------------------------------
  ('C:\\Users\\me\\a.txt', []),
  ('C:/Users/me/a.txt', []),
  ('\\\\server\\share\\a.txt', []),
  ('https://', []),
  ('https:', []),
  ('file:///etc/passwd', []),
  ('ftp://x.dev/a.txt', []),
  ('me@example.com', []),
  ('git@github.com:foo/bar.git', []),
  ('user@host:/var/log/x.log', []),
  ('www.example.com', []),
  ('example.com/index.html', []),
  ('github.com/foo/bar/x.go', []),
  // -- code and patterns ------------------------------------------------------
  ('src/**/*.dart', []),
  ('*.md', []),
  ('lib/a?.dart', []),
  ('</div>', []),
  ('<br/>', []),
  ('#include <stdio.h>', []),
  ('#include <sys/types.h>', []),
  ("import 'package:foo/bar.dart';", []),
  ('console.log("x")', []),
  ('const data = await res.json();', []),
  ('Math.max(1, 2)', []),
  ('process.env.NODE_ENV', []),
  ('\$HOME/x.md', []),
  ('…/deep/file.dart', []),
  ('.../foo/bar.dart', []),
  ('src/…/a.dart', []),
  ('a//b.txt', []),
];

/// Links of [text] the way the tests compare them.
List<_Link> _found(String text) => [
  for (final l in detectLinks(text))
    (
      kind: l.kind,
      text: l.text,
      target: l.target,
      line: l.line,
      column: l.column,
    ),
];

/// Every `(line, link)` the table expects or the detector produced, to count
/// true positives, false positives and misses.
({int tp, int fp, int fn, int lines}) _score() {
  var tp = 0, fp = 0, fn = 0;
  for (final (input, expected) in _cases) {
    final got = [..._found(input)];
    for (final e in expected) {
      final at = got.indexWhere(
        (g) =>
            g.kind == e.kind &&
            g.target == e.target &&
            g.line == e.line &&
            g.column == e.column,
      );
      if (at >= 0) {
        tp++;
        got.removeAt(at);
      } else {
        fn++;
      }
    }
    fp += got.length;
  }
  return (tp: tp, fp: fp, fn: fn, lines: _cases.length);
}

final RegExp _ansi = RegExp(
  r'\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)',
);

void _collectStrings(Object? v, Set<String> out) {
  if (v is String) {
    for (final l in v.split('\n')) {
      if (l.trim().isNotEmpty && l.length <= 400) out.add(l);
    }
  } else if (v is List) {
    for (final e in v) {
      _collectStrings(e, out);
    }
  } else if (v is Map) {
    for (final e in v.values) {
      _collectStrings(e, out);
    }
  }
}

/// Every line of the recorded terminal screens (`prompts/*.txt`) and every
/// string in the recorded sessions (`traces`, `omp_logs`).
Set<String> _fixtureLines() {
  final lines = <String>{};
  for (final f in Directory(
    'test/fixtures',
  ).listSync(recursive: true).whereType<File>()) {
    if (f.path.endsWith('.txt')) {
      for (final l in f.readAsLinesSync()) {
        if (l.startsWith('#')) continue;
        final s = l.replaceAll(_ansi, '');
        if (s.trim().isNotEmpty && s.length <= 400) lines.add(s);
      }
    } else if (f.path.endsWith('.jsonl')) {
      for (final l in f.readAsLinesSync()) {
        try {
          _collectStrings(jsonDecode(l), lines);
        } on FormatException {
          // A torn line in a recording.
        }
      }
    }
  }
  return lines;
}

/// Why [link] should not have been one, or null: a slash command, a folder, a
/// name without extension.
String? _noise(TerminalLink link) {
  if (link.kind != TerminalLinkKind.path) return null;
  final t = link.target;
  if (t.endsWith('/')) return 'folder';
  final cut = t.lastIndexOf('/');
  final name = t.substring(cut + 1);
  if (t.startsWith('/') && cut == 0 && !name.contains('.')) {
    return 'slash command';
  }
  const bare = {'Makefile', 'Dockerfile', 'README', 'LICENSE', 'Gemfile'};
  if (!name.contains('.') && !bare.contains(name)) return 'no extension';
  return null;
}

void main() {
  group('table', () {
    for (final (input, expected) in _cases) {
      test(input.isEmpty ? '(empty)' : input.replaceAll('\t', r'\t'), () {
        expect(_found(input), expected);
      });
    }
  });

  test('the table is big enough to mean something', () {
    expect(_cases.length, greaterThanOrEqualTo(120));
    expect(_cases.where((c) => c.$2.isEmpty).length, greaterThanOrEqualTo(50));
    expect(
      _cases.where((c) => c.$2.isNotEmpty).length,
      greaterThanOrEqualTo(80),
    );
  });

  test('precision and recall on the table', () {
    final s = _score();
    final precision = s.tp / (s.tp + s.fp);
    final recall = s.tp / (s.tp + s.fn);
    // ignore: avoid_print
    print(
      'link-sense table: ${s.lines} lines, tp ${s.tp}, fp ${s.fp}, fn ${s.fn}, '
      'precision ${precision.toStringAsFixed(3)}, recall ${recall.toStringAsFixed(3)}',
    );
    expect(s.fp, 0);
    expect(s.fn, 0);
  });

  group('recorded sessions and screens', () {
    final lines = _fixtureLines();

    test('are loaded', () {
      expect(lines.length, greaterThan(1000));
    });

    test('no link is a slash command, a folder or a name without extension', () {
      final noise = <String>[];
      var links = 0;
      for (final line in lines) {
        for (final link in detectLinks(line)) {
          links++;
          final why = _noise(link);
          if (why != null) noise.add('$why: ${link.target}  <- $line');
        }
      }
      // ignore: avoid_print
      print(
        'link-sense fixtures: ${lines.length} lines, $links links, ${noise.length} noisy',
      );
      expect(noise, isEmpty);
    });

    test('the files the agents touched are still found', () {
      final targets = {
        for (final line in lines)
          for (final link in detectLinks(line))
            if (link.kind == TerminalLinkKind.path) link.target,
      };
      expect(
        targets,
        containsAll([
          'hello.txt',
          'notes.txt',
          'src/main.py',
          'README.md',
          'AGENTS.md',
          '/work/proj/new.txt',
        ]),
      );
      expect(targets, isNot(contains('/model')));
      expect(targets, isNot(contains('/resume')));
    });
  });

  group('the Markdown surface uses the same rules', () {
    test('a link target that is a slash command is not a path', () {
      expect(classifyLink('/model').$1, MdLinkKind.none);
      expect(classifyLink('/compact').$1, MdLinkKind.none);
      expect(classifyLink('/usr/bin/env').$1, MdLinkKind.path);
      expect(classifyLink('lib/a.dart#L12').$2, (path: 'lib/a.dart', line: 12));
    });
  });

  group('speed', () {
    final realistic = <String>[
      ...(_cases.map((c) => c.$1).toList()),
      ..._fixtureLines().take(2000),
      '    at Object.<anonymous> (/home/me/app/node_modules/express/lib/router/index.js:284:15)',
      'drwxr-xr-x  12 me me  4096 Oct  5 09:00 .github',
      '  Compiling herdr_mobile v0.4.12 (/home/me/herdr-mobile/app)',
      'The change touches lib/ui/core/terminal_links.dart and test/link_sense_test.dart, and the 2026/10/05 notes.',
    ];

    test('5,000 realistic lines are scanned well under the budget', () {
      final lines = [
        for (var i = 0; i < 5000; i++) realistic[i % realistic.length],
      ];
      detectLinks(lines.first); // warm the regexes
      final watch = Stopwatch()..start();
      var links = 0;
      for (final l in lines) {
        links += detectLinks(l).length;
      }
      watch.stop();
      // ignore: avoid_print
      print(
        'link-sense speed: 5000 lines, $links links, ${watch.elapsedMilliseconds} ms',
      );
      expect(links, greaterThan(300));
      expect(watch.elapsedMilliseconds, lessThan(300));
    });
  });
}
