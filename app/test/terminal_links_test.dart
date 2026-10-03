import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/box_drawing.dart';
import 'package:herdr_mobile/ui/core/cell_width.dart';
import 'package:herdr_mobile/ui/core/terminal_links.dart';

/// A URL link whose displayed text is its target, starting at cell [start].
TerminalLink _url(String text, int start) => TerminalLink(
  kind: TerminalLinkKind.url,
  text: text,
  target: text,
  start: start,
  end: start + columnsOf(text),
);

/// A path link displayed as [text] starting at cell [start]; [target] defaults
/// to the text (no `:line:col` suffix).
TerminalLink _path(
  String text,
  int start, {
  String? target,
  int? line,
  int? column,
}) => TerminalLink(
  kind: TerminalLinkKind.path,
  text: text,
  target: target ?? text,
  start: start,
  end: start + columnsOf(text),
  line: line,
  column: column,
);

typedef _Case = (String input, List<TerminalLink> links);

/// Every input that must produce exactly these links.
final List<_Case> _positive = [
  // -- URLs ------------------------------------------------------------------
  ('https://x.dev/a', [_url('https://x.dev/a', 0)]),
  ('HTTP://X.DEV/A', [_url('HTTP://X.DEV/A', 0)]),
  ('Https://x.dev', [_url('Https://x.dev', 0)]),
  ('http://localhost:3000', [_url('http://localhost:3000', 0)]),
  ('http://[::1]:8080/x', [_url('http://[::1]:8080/x', 0)]),
  ('https://日本語.jp/x', [_url('https://日本語.jp/x', 0)]),
  ('https://x.dev/a?b=1&c=2#frag', [_url('https://x.dev/a?b=1&c=2#frag', 0)]),
  ('see https://x.dev/a for more', [_url('https://x.dev/a', 4)]),
  ('x.dev http://x.dev', [_url('http://x.dev', 6)]),
  ('(see https://x.dev/a)', [_url('https://x.dev/a', 5)]),
  ('[docs](https://x.dev/a)', [_url('https://x.dev/a', 7)]),
  ('"https://x.dev/a"', [_url('https://x.dev/a', 1)]),
  ("'https://x.dev/a'", [_url('https://x.dev/a', 1)]),
  ('<https://x.dev/a>', [_url('https://x.dev/a', 1)]),
  ('**https://x.dev/a**', [_url('https://x.dev/a', 2)]),
  ('│ https://x.dev/a │', [_url('https://x.dev/a', 2)]),
  ('日本語 https://x.dev/a', [_url('https://x.dev/a', 7)]),
  ('Visit https://x.dev/a.', [_url('https://x.dev/a', 6)]),
  ('https://x.dev/a.md.', [_url('https://x.dev/a.md', 0)]),
  ('https://x.dev/a, then', [_url('https://x.dev/a', 0)]),
  ('https://x.dev/a; then', [_url('https://x.dev/a', 0)]),
  ('https://x.dev/a: then', [_url('https://x.dev/a', 0)]),
  ('https://x.dev/a!', [_url('https://x.dev/a', 0)]),
  ('https://x.dev/a?', [_url('https://x.dev/a', 0)]),
  ('https://x.dev/a_', [_url('https://x.dev/a', 0)]),
  ('https://x.dev/a)', [_url('https://x.dev/a', 0)]),
  ('https://x.dev/a))', [_url('https://x.dev/a', 0)]),
  ('https://x.dev/a]', [_url('https://x.dev/a', 0)]),
  ('https://x.dev/a}', [_url('https://x.dev/a', 0)]),
  (
    'https://en.wikipedia.org/wiki/Foo_(bar)',
    [_url('https://en.wikipedia.org/wiki/Foo_(bar)', 0)],
  ),
  (
    '(https://en.wikipedia.org/wiki/Foo_(bar))',
    [_url('https://en.wikipedia.org/wiki/Foo_(bar)', 1)],
  ),
  (
    'https://en.wikipedia.org/wiki/Foo_(bar).',
    [_url('https://en.wikipedia.org/wiki/Foo_(bar)', 0)],
  ),
  ('https://x.dev/[a]', [_url('https://x.dev/[a]', 0)]),
  ('https://x.dev/{a}', [_url('https://x.dev/{a}', 0)]),
  // A URL with a path-looking tail is one URL, never a URL plus a path.
  ('https://x.dev/a/b.md', [_url('https://x.dev/a/b.md', 0)]),
  (
    'https://x.dev/src/main.dart:42',
    [_url('https://x.dev/src/main.dart:42', 0)],
  ),
  // -- several links on a line -----------------------------------------------
  (
    'https://x.dev/a https://y.dev/b',
    [_url('https://x.dev/a', 0), _url('https://y.dev/b', 16)],
  ),
  (
    'https://x.dev/a src/b.dart',
    [_url('https://x.dev/a', 0), _path('src/b.dart', 16)],
  ),
  (
    'src/b.dart https://x.dev/a',
    [_path('src/b.dart', 0), _url('https://x.dev/a', 11)],
  ),
  ('a.dart b.dart', [_path('a.dart', 0), _path('b.dart', 7)]),
  (
    'lib/a.dart and lib/b.dart',
    [_path('lib/a.dart', 0), _path('lib/b.dart', 15)],
  ),
  // -- absolute, home and dot-relative paths ---------------------------------
  ('/usr/bin/env', [_path('/usr/bin/env', 0)]),
  ('/home/me/a b', [_path('/home/me/a', 0)]),
  ('/dev/null', [_path('/dev/null', 0)]),
  ('/tmp/x.txt', [_path('/tmp/x.txt', 0)]),
  ('/etc/', [_path('/etc/', 0)]),
  ('/usr/bin/env.', [_path('/usr/bin/env', 0)]),
  ('~/notes.md', [_path('~/notes.md', 0)]),
  ('~/Documents/', [_path('~/Documents/', 0)]),
  ('~/.bashrc', [_path('~/.bashrc', 0)]),
  ('./run.sh', [_path('./run.sh', 0)]),
  ('./.hidden', [_path('./.hidden', 0)]),
  ('./a/', [_path('./a/', 0)]),
  ('../x/y.dart', [_path('../x/y.dart', 0)]),
  ('../../a.txt', [_path('../../a.txt', 0)]),
  ('../x/', [_path('../x/', 0)]),
  ('a/../b.md', [_path('a/../b.md', 0)]),
  // -- relative paths --------------------------------------------------------
  ('lib/ui/core/ansi.dart', [_path('lib/ui/core/ansi.dart', 0)]),
  ('src/main.rs', [_path('src/main.rs', 0)]),
  ('lib/ui/', [_path('lib/ui/', 0)]),
  ('.github/workflows/ci.yml', [_path('.github/workflows/ci.yml', 0)]),
  ('x-foo/bar.txt', [_path('x-foo/bar.txt', 0)]),
  ('--out=build/app.apk', [_path('build/app.apk', 6)]),
  // -- bare file names -------------------------------------------------------
  ('a.dart', [_path('a.dart', 0)]),
  ('a.b.c.dart', [_path('a.b.c.dart', 0)]),
  ('FOO.DART', [_path('FOO.DART', 0)]),
  ('script.PY', [_path('script.PY', 0)]),
  ('2024-report.pdf', [_path('2024-report.pdf', 0)]),
  ('Cargo.lock', [_path('Cargo.lock', 0)]),
  ('a.jpeg', [_path('a.jpeg', 0)]),
  ('x.tar.gz', [_path('x.tar.gz', 0)]),
  ('a.sqlite3', [_path('a.sqlite3', 0)]),
  ('foo.7z', [_path('foo.7z', 0)]),
  ('x.dockerfile', [_path('x.dockerfile', 0)]),
  ('Makefile', [_path('Makefile', 0)]),
  ('Dockerfile', [_path('Dockerfile', 0)]),
  ('README', [_path('README', 0)]),
  ('LICENSE', [_path('LICENSE', 0)]),
  // -- boundaries and trailing punctuation -----------------------------------
  ('(lib/a.dart)', [_path('lib/a.dart', 1)]),
  ('"lib/a.dart"', [_path('lib/a.dart', 1)]),
  ("'lib/a.dart'", [_path('lib/a.dart', 1)]),
  ('`lib/a.dart`', [_path('lib/a.dart', 1)]),
  ('[lib/a.dart]', [_path('lib/a.dart', 1)]),
  ('{lib/a.dart}', [_path('lib/a.dart', 1)]),
  ('<lib/a.dart>', [_path('lib/a.dart', 1)]),
  ('<~/notes.md>', [_path('~/notes.md', 1)]),
  ('<./a.sh>', [_path('./a.sh', 1)]),
  ('<src/a.dart>', [_path('src/a.dart', 1)]),
  ('<img src="a.png"/>', [_path('a.png', 10)]),
  ('x=lib/a.dart', [_path('lib/a.dart', 2)]),
  ('a,lib/a.dart', [_path('lib/a.dart', 2)]),
  (';lib/a.dart', [_path('lib/a.dart', 1)]),
  ('warning:lib/a.dart', [_path('lib/a.dart', 8)]),
  ('lib/a.dart.', [_path('lib/a.dart', 0)]),
  ('lib/a.dart,', [_path('lib/a.dart', 0)]),
  ('lib/a.dart;', [_path('lib/a.dart', 0)]),
  ('lib/a.dart!', [_path('lib/a.dart', 0)]),
  ('lib/a.dart?', [_path('lib/a.dart', 0)]),
  ('lib/a.dart)', [_path('lib/a.dart', 0)]),
  ('lib/a.dart#L10', [_path('lib/a.dart', 0)]),
  // -- :line:col and (line,col) suffixes -------------------------------------
  (
    'src/main.dart:42:7',
    [
      _path(
        'src/main.dart:42:7',
        0,
        target: 'src/main.dart',
        line: 42,
        column: 7,
      ),
    ],
  ),
  (
    'src/main.dart:42',
    [_path('src/main.dart:42', 0, target: 'src/main.dart', line: 42)],
  ),
  (
    'lib/a.dart(12)',
    [_path('lib/a.dart(12)', 0, target: 'lib/a.dart', line: 12)],
  ),
  (
    'lib/a.dart(12,3)',
    [_path('lib/a.dart(12,3)', 0, target: 'lib/a.dart', line: 12, column: 3)],
  ),
  (
    'lib/a.dart(12, 3)',
    [_path('lib/a.dart(12, 3)', 0, target: 'lib/a.dart', line: 12, column: 3)],
  ),
  ('a.dart:12:', [_path('a.dart:12', 0, target: 'a.dart', line: 12)]),
  (
    'lib/a.dart:12:5.',
    [_path('lib/a.dart:12:5', 0, target: 'lib/a.dart', line: 12, column: 5)],
  ),
  (
    'lib/a.dart:1234567',
    [_path('lib/a.dart:1234567', 0, target: 'lib/a.dart', line: 1234567)],
  ),
  ('lib/a.dart:', [_path('lib/a.dart', 0)]),
  ('lib/a.dart:x', [_path('lib/a.dart', 0)]),
  ('lib/a.dart:12345678', [_path('lib/a.dart', 0)]),
  ('lib/a.dart (12)', [_path('lib/a.dart', 0)]),
  (
    'src/a.dart:12:5: error',
    [_path('src/a.dart:12:5', 0, target: 'src/a.dart', line: 12, column: 5)],
  ),
  (
    '    at foo (src/a.ts:10:5)',
    [_path('src/a.ts:10:5', 12, target: 'src/a.ts', line: 10, column: 5)],
  ),
  (
    'lib/x.dart:12:34 • message • rule',
    [_path('lib/x.dart:12:34', 0, target: 'lib/x.dart', line: 12, column: 34)],
  ),
  ('File "/x/y.py", line 12', [_path('/x/y.py', 6, line: 12)]),
  ('File "/x/y.py", line 12, in <module>', [_path('/x/y.py', 6, line: 12)]),
  ('/x/y.py, line 3', [_path('/x/y.py', 0, line: 3)]),
  // -- tool output -----------------------------------------------------------
  ('modified:   lib/x.dart', [_path('lib/x.dart', 12)]),
  ('new file:   test/y_test.dart', [_path('test/y_test.dart', 12)]),
  (
    'diff --git a/lib/x.dart b/lib/x.dart',
    [_path('a/lib/x.dart', 11), _path('b/lib/x.dart', 24)],
  ),
  ('--- a/lib/x.dart', [_path('a/lib/x.dart', 4)]),
  ('+++ b/lib/x.dart', [_path('b/lib/x.dart', 4)]),
  ('│ src/a.dart │', [_path('src/a.dart', 2)]),
  ('┌──lib/a.dart──┐', [_path('lib/a.dart', 3)]),
  ('│ notes.md │ 1234 │ lib/ │', [_path('notes.md', 2), _path('lib/', 20)]),
  ('-rw-r--r--  1 me me  1234 Jan  5 09:00 notes.md', [_path('notes.md', 39)]),
  // -- non-ASCII names and columns -------------------------------------------
  ('~/Tài_liệu/báo-cáo.md', [_path('~/Tài_liệu/báo-cáo.md', 0)]),
  ('báo-cáo.md', [_path('báo-cáo.md', 0)]),
  ('ba\u0301o-ca\u0301o.md', [_path('ba\u0301o-ca\u0301o.md', 0)]),
  ('日本語/ファイル.txt', [_path('日本語/ファイル.txt', 0)]),
  ('日本語 /tmp/x.txt', [_path('/tmp/x.txt', 7)]),
  ('日本語 日本語.md', [_path('日本語.md', 7)]),
  ('🚀 src/a.dart', [_path('src/a.dart', 3)]),
  ('𠀀 src/a.dart', [_path('src/a.dart', 3)]),
  ('a\u0301 src/a.dart', [_path('src/a.dart', 2)]),
];

/// Lines that must produce no link at all.
const List<String> _negative = [
  '',
  ' ',
  // Words that merely contain a slash.
  'and/or', 'read/write', 'TCP/IP', 'yes/no', 'input/output', 'input/output.',
  'N/A', 'I/O', 'w/o', 'km/h', 'a/b', 'src/lib',
  // Dates, fractions, ratios and versions.
  '12/31', '2024/01/05', '2024/01/', '1/2', '1/2.5', '1.2/3.4', '10/20 (50%)',
  '(1/2)', '24/7', '5/10', '1.2.3', '3.14', 'v1.2.3', 'v2.0', '10.0.0.1',
  '10.0.0.1:8080', '0.8.2', '1.0.0-beta.1', '12:30:45', '2024-01-05', '50%',
  '100%',
  // Not enough path after the slash.
  '/', '//', '/*', '*/', '/ ', '/2', '//comment', '/-->', '/.', '/..', '-->',
  './', '../', '~/', '~', '.', '..', '.dart', 'lib/.gitignore',
  // Extensions: too long, not alphanumeric, unknown for bare names.
  'a/b.toolongext', 'a/b.d-art', 'foo.bar', 'x.y', 'example.com', 'www.x.com',
  'e.g.', 'i.e.', 'etc.', 'U.S.',
  // Email addresses and scp style remotes.
  'a.b@c.com', 'me@example.com', 'me@example.md', 'user@host:/x',
  'user@host:/var/log/x.log', 'git@github.com:foo/bar.git',
  // Other schemes and malformed URLs.
  'ftp://x.dev/a.txt', 'file:///etc/passwd', 'javascript:alert(1)',
  'mailto:a@b.dev', 'https://', 'http://', 'https:// x', 'http:///x',
  'https://.x', 'https://:80', 'xhttps://x.dev',
  // Windows paths.
  r'C:\x\a.txt', r'C:\x',
  // Globs, character classes and query-like tails.
  '**/*.dart', 'a/b/*', 'src/*.dart', 'lib/a?.dart', '--glob=src/*.dart',
  'foo*/bar.md', '[a-z]/x.md', 'src/a.dart[1]',
  // Empty path segment.
  'a//b.txt',
  // HTML/XML closing and self-closing tags.
  '</div>', '<p>text</p>', '</body></html>', '<br/>', '</', '/>',
  // Markdown and ASCII noise.
  '---', '===', '...', '->', '=>', '|', '^^^^', '*', '**bold**', '#123',
  '@user', '@angular/core', '-v', '--help', '-rw-r--r--', 'foo=bar',
  'x -> y', 'a + b = c', 'key: value', 'main()', 'Hello, world!',
  'The quick brown fox jumps over the lazy dog.', '┌──────┐', '│ │',
];

/// The runes of [text] whose first cell lies in `[start, end)`; walking runes
/// keeps this independent of UTF-16 indexes.
String _sliceByColumns(String text, int start, int end) {
  final out = StringBuffer();
  var column = 0;
  for (final rune in text.runes) {
    if (column >= start && column < end) out.writeCharCode(rune);
    column += cellWidth(rune);
  }
  return out.toString();
}

void _expectInvariants(String text, List<TerminalLink> links) {
  final columns = columnsOf(text);
  var previousEnd = 0;
  for (final link in links) {
    expect(link.start, greaterThanOrEqualTo(previousEnd), reason: '$links');
    expect(link.end, greaterThan(link.start), reason: '$links');
    expect(link.end, lessThanOrEqualTo(columns), reason: '$links');
    // Columns cannot tell a trailing zero-width mark that belongs to the link
    // from one that follows it, so the slice may stop just before such marks.
    final slice = _sliceByColumns(text, link.start, link.end);
    expect(link.text, startsWith(slice), reason: 'columns of $link in "$text"');
    expect(
      link.text.substring(slice.length).runes.map(cellWidth),
      everyElement(0),
      reason: 'columns of $link in "$text"',
    );
    expect(columnsOf(link.text), link.end - link.start);
    expect(link.text, startsWith(link.target));
    previousEnd = link.end;
  }
}

void main() {
  group('detects', () {
    for (final (input, expected) in _positive) {
      test(input, () {
        expect(detectLinks(input), expected);
      });
    }
  });

  group('ignores', () {
    for (final input in _negative) {
      test(input.isEmpty ? '(empty)' : input, () {
        expect(detectLinks(input), isEmpty);
      });
    }
  });

  test('the case tables are big enough to mean something', () {
    expect(_positive.length, greaterThanOrEqualTo(60));
    expect(_negative.length, greaterThanOrEqualTo(60));
  });

  group('columns count cells, not UTF-16 units', () {
    // (input, start, end) written out so the expectation does not depend on
    // the same width helper the implementation uses.
    const cases = [
      ('日本語 /tmp/x.txt', 7, 17),
      ('🚀 src/a.dart', 3, 13),
      ('𠀀 src/a.dart', 3, 13),
      ('a\u0301 src/a.dart', 2, 12),
      ('日本語/ファイル.txt', 0, 19),
      ('ba\u0301o-ca\u0301o.md', 0, 10),
      ('日本語 https://x.dev/a', 7, 22),
    ];
    for (final (input, start, end) in cases) {
      test(input, () {
        final link = detectLinks(input).single;
        expect((link.start, link.end), (start, end));
      });
    }
  });

  group('link fields', () {
    test('a position suffix is in text but not in target', () {
      final link = detectLinks('src/a.dart:12:5: error').single;
      expect(link.kind, TerminalLinkKind.path);
      expect(link.text, 'src/a.dart:12:5');
      expect(link.target, 'src/a.dart');
      expect((link.line, link.column), (12, 5));
    });

    test('a python traceback line number is not displayed', () {
      final link = detectLinks('File "/x/y.py", line 12').single;
      expect((link.text, link.target, link.line), ('/x/y.py', '/x/y.py', 12));
    });

    test('a link without a position has none', () {
      final link = detectLinks('lib/ui/').single;
      expect((link.line, link.column), (null, null));
    });

    test('value equality, hashCode and toString', () {
      final a = _path('a.dart:1', 0, target: 'a.dart', line: 1);
      final b = _path('a.dart:1', 0, target: 'a.dart', line: 1);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(_path('a.dart:1', 1, target: 'a.dart', line: 1)));
      expect(a, isNot(_path('a.dart:1', 0, target: 'a.dart', line: 2)));
      expect(a, isNot(_url('a.dart:1', 0)));
      expect(a.toString(), contains('a.dart:1'));
    });
  });

  group('box glyphs behave like spaces', () {
    test('every box and block glyph separates a path from its neighbours', () {
      for (var rune = 0x2500; rune <= 0x259f; rune++) {
        expect(isBoxGlyph(rune), isTrue);
        final glyph = String.fromCharCode(rune);
        expect(detectLinks('${glyph}src/a.dart$glyph'), [
          _path('src/a.dart', 1),
        ], reason: 'U+${rune.toRadixString(16)}');
      }
    });

    test('every box and block glyph ends a URL', () {
      final glyph = String.fromCharCode(0x2502);
      expect(detectLinks('https://x.dev/a${glyph}b'), [
        _url('https://x.dev/a', 0),
      ]);
    });
  });

  group('performance', () {
    /// Runs [text] through the detector and asserts it finishes quickly; the
    /// bound is far above the real cost so it only catches quadratic blowups.
    List<TerminalLink> timed(String text) {
      final watch = Stopwatch()..start();
      final links = detectLinks(text);
      expect(watch.elapsedMilliseconds, lessThan(1000));
      return links;
    }

    test('a 500 character line without links', () {
      final line = ('lorem ipsum, dolor sit amet ' * 20).substring(0, 500);
      expect(timed(line), isEmpty);
    });

    final hostile = <String, String>{
      'prose': 'lorem ipsum dolor ' * 6000,
      'one huge word': 'x' * 100000,
      'dots': '.' * 100000,
      'slashes': '/' * 100000,
      'colons': ':' * 100000,
      'scp colons': 'a@b:' * 25000,
      'commas': 'a,' * 50000,
      'parens': ')' * 100000,
      'open url': 'https://${'(' * 100000}',
      'path pieces': 'a/b ' * 25000,
      'wide': '日本語' * 33000,
    };
    hostile.forEach((name, text) {
      test('a 100 KB line of $name completes', () {
        final links = timed(text);
        _expectInvariants(text.substring(0, min(text.length, 2000)), links);
      });
    });

    test('only the first 2000 UTF-16 units are scanned', () {
      expect(detectLinks('${'x ' * 1100}lib/a.dart'), isEmpty);
      expect(detectLinks('lib/a.dart ${'y ' * 50000}'), [
        _path('lib/a.dart', 0),
      ]);
      expect(detectLinks('${'x ' * 900}lib/a.dart'), [
        _path('lib/a.dart', 1800),
      ]);
    });
  });

  group('invariants', () {
    test('hold for every table input', () {
      for (final (input, _) in _positive) {
        _expectInvariants(input, detectLinks(input));
      }
      for (final input in _negative) {
        _expectInvariants(input, detectLinks(input));
      }
    });

    test('hold for random lines built from link-like fragments', () {
      const fragments = [
        'src/',
        'a.dart',
        ':12',
        ':5',
        '(3,4)',
        'https://',
        'x.dev',
        '/',
        ' ',
        '日本',
        '│',
        '(',
        ')',
        '.',
        ',',
        '"',
        '*',
        '~/',
        './',
        '../',
        'é',
        '\u0301',
        '🚀',
        '@',
        '-',
        '_',
        '#',
        '=',
        '[',
        ']',
        'README',
        'line',
        'File ',
        ':',
        '\t',
        '\u3000',
        'lib/',
        'b.md',
        '?',
        '<',
        '>',
      ];
      final random = Random(20251003);
      var linked = 0;
      for (var n = 0; n < 5000; n++) {
        final text = [
          for (var k = random.nextInt(14) + 1; k > 0; k--)
            fragments[random.nextInt(fragments.length)],
        ].join();
        final links = detectLinks(text);
        linked += links.length;
        _expectInvariants(text, links);
      }
      // Guards against the generator silently producing only link-free lines.
      expect(linked, greaterThan(500));
    });
  });
}
