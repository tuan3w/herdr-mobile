import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/markdown/highlight/highlight.dart';

import 'samples.dart';
import 'support.dart';

/// The important tokens of each sample, in order (not every token).
void main() {
  Matcher inOrder(List<Tok> toks) => containsAllInOrder(toks);

  group('golden', () {
    test('dart', () {
      final t = tokenize('dart', samples['dart']!);
      expect(
        t,
        inOrder([
          kw('import'),
          str("'package:flutter/widgets.dart'"),
          com('/// A counter that never goes below [min].'),
          kw('class'),
          typ('Counter'),
          kw('extends'),
          typ('ChangeNotifier'),
          kw('final'),
          typ('int'),
          kw('static'),
          kw('const'),
          typ('double'),
          num('1.5e3'),
          kw('get'),
          typ('void'),
          fn('decrement'),
          typ('bool'),
          con('false'),
          kw('if'),
          com('// never negative'),
          str(r"r'raw\n'"),
          str(r"'it\'s $_value'"),
          str('"""multi'),
          str('line"""'),
          fn('notifyListeners'),
        ]),
      );
      // `get` / `set` are only keywords before a name
      expect(tokenize('dart', 'var get = 1;'), isNot(contains(kw('get'))));
    });

    test('javascript', () {
      final t = tokenize('js', samples['js']!);
      expect(
        t,
        inOrder([
          com('// load the config'),
          kw('import'),
          kw('from'),
          str("'node:fs/promises'"),
          kw('const'),
          con('PORT'),
          num('0x1F90'),
          kw('async'),
          kw('function'),
          fn('main'),
          kw('await'),
          fn('readFile'),
          str('"utf8"'),
          str(r'/^(\d+)\s*=\s*"([^"]*)"$/gm'),
          com('/* block'),
          com('     comment */'),
          kw('of'),
          str(r"'\n'"),
          num('3.5'),
          str(r'`got ${line}`'),
          con('null'),
        ]),
      );
      // division is not a regex
      expect(tokenize('js', 'x = a / b / c'), isNot(contains(str('/ b /'))));
    });

    test('typescript', () {
      final t = tokenize('ts', samples['ts']!);
      expect(
        t,
        inOrder([
          kw('export'),
          kw('interface'),
          typ('Options'),
          kw('readonly'),
          typ('string'),
          typ('number'),
          kw('type'),
          typ('Handler'),
          typ('Promise'),
          attr('@Injectable'),
          kw('class'),
          typ('Runner'),
          kw('extends'),
          kw('private'),
          kw('async'),
          fn('run'),
          typ('boolean'),
          com('// retry loop'),
          kw('for'),
          kw('let'),
          num('0'),
          op('??'),
          kw('await'),
          kw('this'),
          con('true'),
        ]),
      );
    });

    test('python', () {
      final t = tokenize('python', samples['python']!);
      expect(
        t,
        inOrder([
          com('#!/usr/bin/env python3'),
          str('"""Tiny CLI.'),
          str('Second docstring line.'),
          str('"""'),
          kw('import'),
          kw('from'),
          attr('@dataclass'),
          kw('class'),
          typ('Job'),
          typ('str'),
          typ('int'),
          num('3'),
          kw('def'),
          fn('main'),
          con('None'),
          op('->'),
          typ('Path'),
          kw('if'),
          kw('else'),
          com('# optional'),
          str('f"hello {path!r}"'),
          str(r"r'\d+'"),
          str("b'raw'"),
          kw('is'),
          kw('not'),
          num('0x10'),
          num('1_000.5e-3'),
          fn('print'),
          fn('len'),
          con('True'),
          kw('return'),
        ]),
      );
    });

    test('shell', () {
      final t = tokenize('shell', samples['shell']!);
      expect(
        t,
        inOrder([
          com('#!/usr/bin/env bash'),
          fn('set'),
          attr('-euo'),
          com('# build the thing'),
          prop('NAME'),
          str('"herdr"'),
          prop('VERSION'),
          kw('export'),
          prop('PATH'),
          str(r'"$HOME/bin:$PATH"'),
          kw('for'),
          kw('in'),
          kw('do'),
          kw('if'),
          kw('[['),
          attr('-f'),
          con(r'${#f}'),
          attr('-gt'),
          num('3'),
          kw(']]'),
          kw('then'),
          fn('echo'),
          str("'processing'"),
          op('|'),
          fn('tee'),
          attr('-a'),
          kw('fi'),
          kw('done'),
          fn('cat'),
          op('<<-'),
          con('EOF'),
          str('  hello \$NAME'),
          con('EOF'),
          fn('grep'),
          attr('--include'),
          str('"TODO"'),
          op('||'),
          fn('curl'),
          attr('-fsSL'),
          op('|'),
          fn('sh'),
        ]),
      );
    });

    test('console: only prompt lines are commands', () {
      final t = tokenize('console', samples['console']!);
      expect(
        t,
        inOrder([
          punct(r'$'),
          fn('cd'),
          punct(r'$'),
          fn('flutter'),
          attr('--no-pub'),
          com('# run'),
          com('# a comment'),
          punct(r'$'),
          fn('echo'),
          str('"done"'),
        ]),
      );
      // the output line has no tokens at all
      final h = highlighterFor('console')!;
      expect(h.line('00:03 +42: All tests passed!', h.initial).$1, isEmpty);
      // a prompt also works in a bash block
      expect(tokenize('bash', r'$ ls -la'), [punct(r'$'), fn('ls'), attr('-la')]);
    });

    test('json', () {
      final t = tokenize('json', samples['json']!);
      expect(
        t,
        inOrder([
          prop('"name"'),
          str('"herdr-mobile"'),
          prop('"private"'),
          con('true'),
          prop('"ratio"'),
          num('-0.5e-2'),
          prop('"count"'),
          num('42'),
          prop('"note"'),
          str(r'"line\n\"quoted\" \u00e9"'),
          str('"a"'),
          str('"b"'),
          prop('"ok"'),
          con('false'),
          con('null'),
        ]),
      );
    });

    test('jsonc', () {
      expect(
        tokenize('jsonc', samples['jsonc']!),
        inOrder([
          com('// trailing comment'),
          prop('"a"'),
          num('1'),
          com('/* inline */'),
          prop('"b"'),
          con('true'),
          con('null'),
        ]),
      );
    });

    test('yaml', () {
      final t = tokenize('yaml', samples['yaml']!);
      expect(
        t,
        inOrder([
          com('# CI config'),
          prop('name'),
          str('build'),
          prop('on'),
          prop('branches'),
          str('main'),
          str('"release/*"'),
          prop('NODE_VERSION'),
          num('20'),
          prop('DEBUG'),
          con('true'),
          con('~'),
          punct('-'),
          prop('uses'),
          str('actions/checkout@v4'),
          prop('run'),
          punct('|'),
          str('npm ci'),
          str('npm test'),
          com('# trailing'),
          prop('anchors'),
          attr('&base'),
          str("'single'"),
          attr('*base'),
        ]),
      );
      // the block scalar ends at the next key
      expect(t, isNot(contains(str('anchors: &base'))));
    });

    test('toml', () {
      final t = tokenize('toml', samples['toml']!);
      expect(
        t,
        inOrder([
          com('# project'),
          typ('[package]'),
          prop('name'),
          str('"herdr"'),
          prop('edition'),
          num('2021'),
          str("'lit'"),
          con('false'),
          typ('[dependencies.serde]'),
          str('"derive"'),
          str('"rc"'),
          num('1979-05-27T07:32:00Z'),
          str('"""'),
          str('multi'),
          str('line"""'),
          typ('[[bin]]'),
          prop('path'),
        ]),
      );
      // inside the multi-line array the lines are values, not keys
      expect(t, isNot(contains(prop('"derive"'))));
    });

    test('sql', () {
      final t = tokenize('sql', samples['sql']!);
      expect(
        t,
        inOrder([
          com('-- active users'),
          kw('SELECT'),
          fn('COUNT'),
          kw('AS'),
          kw('FROM'),
          kw('LEFT'),
          kw('JOIN'),
          kw('WHERE'),
          str("'2024-01-01'"),
          kw('AND'),
          str("'O''Brien'"),
          kw('GROUP'),
          kw('BY'),
          kw('HAVING'),
          num('10'),
          com('/* big */'),
          kw('ORDER'),
          kw('DESC'),
          kw('LIMIT'),
          num('25'),
          kw('CREATE'),
          kw('TABLE'),
          prop('"events"'),
          typ('BIGSERIAL'),
          kw('PRIMARY'),
          kw('KEY'),
          typ('JSONB'),
          con('NULL'),
          str("'{}'"),
          fn('now'),
        ]),
      );
      // keywords match in any case
      expect(tokenize('sql', 'select 1 from t'), contains(kw('select')));
    });

    test('rust', () {
      final t = tokenize('rust', samples['rust']!);
      expect(
        t,
        inOrder([
          kw('use'),
          typ('HashMap'),
          com('/// A tiny cache.'),
          attr('#[derive(Debug, Clone)]'),
          kw('pub'),
          kw('struct'),
          typ("'a"),
          typ('u64'),
          kw('impl'),
          kw('fn'),
          fn('get'),
          kw('mut'),
          kw('self'),
          typ('Option'),
          com('/* count */'),
          num('1u64'),
          kw('let'),
          str('r#"say "hi""#'),
          str("'x'"),
          fn('println!'),
          str('"{} {}"'),
          num('0xFF_u8'),
        ]),
      );
    });

    test('go', () {
      final t = tokenize('go', samples['go']!);
      expect(
        t,
        inOrder([
          kw('package'),
          kw('import'),
          str('"fmt"'),
          com('// Server holds state.'),
          kw('type'),
          typ('Server'),
          kw('struct'),
          typ('string'),
          typ('int'),
          kw('func'),
          fn('Start'),
          typ('error'),
          str('`raw'),
          str('string`'),
          kw('return'),
          fn('Errorf'),
          str('"bad port %d: %w"'),
          typ('rune'),
          str("'a'"),
          fn('Println'),
          num('3.14'),
          con('nil'),
        ]),
      );
    });

    test('c', () {
      final t = tokenize('c', samples['c']!);
      expect(
        t,
        inOrder([
          kw('#include'),
          str('<stdio.h>'),
          kw('#include'),
          str('"util.h"'),
          kw('#define'),
          con('MAX_LEN'),
          num('256'),
          com('/* sum an array */'),
          kw('static'),
          typ('int'),
          fn('sum'),
          kw('const'),
          typ('size_t'),
          kw('for'),
          com('// add'),
          kw('return'),
          fn('main'),
          typ('void'),
          str(r"'\n'"),
          fn('printf'),
          str(r'"total=%d\n"'),
          con('NULL'),
          num('0u'),
        ]),
      );
    });

    test('cpp', () {
      final t = tokenize('cpp', samples['cpp']!);
      expect(
        t,
        inOrder([
          kw('#include'),
          str('<vector>'),
          kw('namespace'),
          kw('template'),
          kw('typename'),
          kw('class'),
          typ('Box'),
          kw('public'),
          kw('explicit'),
          kw('noexcept'),
          kw('private'),
          com('// namespace app'),
          typ('vector'),
          typ('string'),
          str('"a"'),
          kw('auto'),
          con('nullptr'),
          num('0x2'),
        ]),
      );
    });

    test('java', () {
      final t = tokenize('java', samples['java']!);
      expect(
        t,
        inOrder([
          kw('package'),
          kw('import'),
          attr('@SuppressWarnings'),
          str('"unchecked"'),
          kw('public'),
          kw('final'),
          kw('class'),
          typ('Main'),
          con('LIMIT'),
          num('10'),
          com('/** Entry point. */'),
          kw('static'),
          typ('void'),
          fn('main'),
          typ('String'),
          str(r"'\t'"),
          str('"""'),
          str('            hello'),
          str('            """'),
          kw('for'),
          fn('println'),
          num('1.5f'),
        ]),
      );
    });

    test('kotlin', () {
      final t = tokenize('kotlin', samples['kotlin']!);
      expect(
        t,
        inOrder([
          kw('package'),
          attr('@Serializable'),
          kw('data'),
          kw('class'),
          typ('User'),
          kw('val'),
          typ('String'),
          typ('Int'),
          num('0'),
          kw('fun'),
          fn('main'),
          fn('listOf'),
          str('"a"'),
          com('/* nested /* comment */ still */'),
          kw('val'),
          str('"""'),
          str('        raw text'),
          str('    """'),
          fn('println'),
          str(r'"max: ${max(oldest, 3)} ${raw.length}"'),
        ]),
      );
    });

    test('swift', () {
      final t = tokenize('swift', samples['swift']!);
      expect(
        t,
        inOrder([
          kw('import'),
          typ('SwiftUI'),
          attr('@main'),
          kw('struct'),
          typ('DemoApp'),
          attr('@State'),
          kw('private'),
          kw('var'),
          typ('Int'),
          kw('some'),
          typ('Scene'),
          str(r'"Count: \(count)"'),
          com('// label'),
          kw('func'),
          fn('bump'),
          kw('guard'),
          kw('else'),
          con('false'),
          kw('#if'),
          fn('print'),
          num('0x10'),
          kw('#endif'),
          con('true'),
        ]),
      );
    });

    test('html', () {
      final t = tokenize('html', samples['html']!);
      expect(
        t,
        inOrder([
          tag('<!DOCTYPE'),
          attr('html'),
          tag('>'),
          tag('<html'),
          attr('lang'),
          str('"en"'),
          tag('<meta'),
          attr('charset'),
          com('<!-- page title -->'),
          tag('<title>'),
          con('&amp;'),
          tag('</title>'),
          tag('<body'),
          attr('class'),
          str("'main'"),
          attr('data-x'),
          str('5'),
          tag('<a'),
          attr('href'),
          str('"https://example.com/?a=1&b=2"'),
          attr('target'),
          str('_blank'),
          tag('</a>'),
          tag('<input'),
          attr('disabled'),
          tag('/>'),
          tag('</html>'),
        ]),
      );
    });

    test('xml', () {
      final t = tokenize('xml', samples['xml']!);
      expect(
        t,
        inOrder([
          tag('<?xml'),
          attr('version'),
          str('"1.0"'),
          tag('?>'),
          tag('<config'),
          attr('xmlns:x'),
          tag('<entry'),
          tag('</entry>'),
          com('<!-- multi'),
          com('       line -->'),
          tag('<empty/>'),
        ]),
      );
    });

    test('css', () {
      final t = tokenize('css', samples['css']!);
      expect(
        t,
        inOrder([
          kw('@import'),
          fn('url'),
          str('theme.css'),
          kw(':root'),
          prop('--accent'),
          con('#1a73e8'),
          com('/* layout */'),
          typ('.card'),
          op('>'),
          typ('.title'),
          kw(':hover'),
          con('#main'),
          tag('a'),
          attr('[href^="http"]'),
          prop('margin'),
          num('0'),
          prop('padding'),
          num('1.5em'),
          num('12px'),
          prop('color'),
          fn('var'),
          prop('background'),
          fn('url'),
          str('"img/bg.png"'),
          kw('!important'),
          num('0.3s'),
          kw('@media'),
          prop('min-width'),
          num('600px'),
          fn('calc'),
          num('100%'),
          num('2rem'),
        ]),
      );
    });

    test('scss', () {
      final t = tokenize('scss', samples['scss']!);
      expect(
        t,
        inOrder([
          con(r'$gap'),
          num('8px'),
          com('// mixin'),
          kw('@mixin'),
          fn('flex'),
          prop('display'),
          prop('flex-direction'),
          typ('.nav'),
          kw('@include'),
          op('&'),
          kw(':hover'),
          prop('color'),
          fn('darken'),
          con('#336'),
          num('10%'),
          prop('margin'),
          num('2'),
        ]),
      );
    });

    test('diff', () {
      final h = highlighterFor('diff')!;
      final lines = samples['diff']!.split('\n');
      final kinds = [
        for (final l in lines) h.line(l, h.initial).$1.map((t) => t.kind).toList(),
      ];
      expect(kinds[0], [TokenKind.diffMeta]); // diff --git
      expect(kinds[1], [TokenKind.diffMeta]); // index
      expect(kinds[2], [TokenKind.diffMeta]); // ---
      expect(kinds[3], [TokenKind.diffMeta]); // +++
      expect(kinds[4], [TokenKind.diffMeta]); // @@
      expect(kinds[5], isEmpty); // context
      expect(kinds[6], [TokenKind.diffRemove]);
      expect(kinds[7], [TokenKind.diffAdd]);
      expect(kinds[8], isEmpty);
      expect(kinds[9], [TokenKind.diffMeta]); // \ No newline
      // the whole line is the token
      expect(h.line('+  print(1);', h.initial).$1.single.end, 12);
    });

    test('markdown', () {
      final t = tokenize('markdown', samples['markdown']!);
      expect(
        t,
        inOrder([
          kw('# Title'),
          punct('*'),
          punct('*'),
          punct('**'),
          punct('**'),
          str('`code span`'),
          str('(https://example.com/a_b)'),
          str('https://example.org/x'),
          punct('>'),
          punct('-'),
          punct('[x]'),
          punct('1.'),
          str('`ticks`'),
          punct('---'),
          punct('```'),
          kw('dart'),
          punct('```'),
        ]),
      );
      // snake_case is not emphasis; a fence's body is left alone
      expect(t, isNot(contains(punct('_'))));
      expect(t, isNot(contains(kw('var x = 1; # not a heading in a fence'))));
      expect(t.where((e) => e.$1 == TokenKind.comment), isEmpty);
    });

    test('dockerfile', () {
      final t = tokenize('dockerfile', samples['dockerfile']!);
      expect(
        t,
        inOrder([
          com('# syntax=docker/dockerfile:1'),
          kw('FROM'),
          kw('AS'),
          kw('WORKDIR'),
          kw('ENV'),
          kw('COPY'),
          attr('--from'),
          kw('RUN'),
          fn('apt-get'),
          op('&&'),
          attr('-y'),
          attr('--no-install-recommends'),
          op('&&'),
          fn('rm'),
          attr('-rf'),
          kw('EXPOSE'),
          num('8080'),
          kw('CMD'),
          str('"node"'),
          str('"server.js"'),
          kw('ENTRYPOINT'),
          fn('echo'),
          str(r'"$PORT"'),
          op('|'),
          fn('sh'),
        ]),
      );
    });

    test('makefile', () {
      final t = tokenize('make', samples['make']!);
      expect(
        t,
        inOrder([
          com('# build'),
          prop('CC'),
          op(':='),
          prop('CFLAGS'),
          op('?='),
          attr('-O2'),
          kw('.PHONY'),
          fn('all'),
          fn('app'),
          con(r'$(SRC:.c=.o)'),
          op('@'),
          fn('echo'),
          str(r'"linking $@"'),
          con(r'$(CC)'),
          con(r'$(CFLAGS)'),
          attr('-o'),
          con(r'$@'),
          con(r'$^'),
          fn('clean'),
          op('-'),
          fn('rm'),
          kw('ifeq'),
          con(r'$(OS)'),
          kw('endif'),
        ]),
      );
    });
  });

  group('contract', () {
    test('aliases and unknown languages', () {
      for (final name in [
        'js', 'javascript', 'ts', 'tsx', 'jsx', 'py', 'python', 'sh', 'bash',
        'zsh', 'shell', 'console', 'json', 'jsonc', 'yaml', 'yml', 'toml',
        'sql', 'rust', 'rs', 'go', 'c', 'cpp', 'c++', 'h', 'java', 'kotlin',
        'kt', 'swift', 'dart', 'html', 'xml', 'css', 'scss', 'diff', 'patch',
        'md', 'markdown', 'dockerfile', 'make', 'makefile',
      ]) {
        expect(highlighterFor(name), isNotNull, reason: name);
      }
      expect(highlighterFor('Dart'), same(highlighterFor('dart')));
      expect(highlighterFor('  JS title="x" '), same(highlighterFor('js')));
      expect(highlighterFor('language-python'), same(highlighterFor('py')));
      for (final name in ['', 'brainfuck', 'mermaid', 'text', 'math']) {
        expect(highlighterFor(name), isNull, reason: name);
      }
    });

    test('a quiet line returns the very same state', () {
      final h = highlighterFor('dart')!;
      final (_, s1) = h.line('final x = 1;', h.initial);
      expect(s1, same(h.initial));
      final (_, open) = h.line('/* start', h.initial);
      expect(open, isNot(h.initial));
      final (_, still) = h.line('middle', open);
      expect(still, equals(open));
      final (_, closed) = h.line('end */ int x;', open);
      expect(closed, equals(h.initial));
    });

    test('a line over 2000 code units is one plain token, state untouched', () {
      final h = highlighterFor('js')!;
      final long = 'var s = "${'x' * 2100}";';
      final (tokens, next) = h.line(long, h.initial);
      expect(tokens, [Token(0, long.length, TokenKind.plain)]);
      expect(next, same(h.initial));
      final (_, open) = h.line('/*', h.initial);
      expect(h.line(long, open).$2, same(open));
      // the limit is the length
      final ok = 'a' * 2000;
      expect(h.line(ok, h.initial).$1, isEmpty);
    });

    test('multi-line constructs carry across lines', () {
      List<Tok> go(String lang, String code) => tokenize(lang, code);
      expect(go('js', 'a = `x\ny\${1}\nz` + 1'), [
        op('='),
        str('`x'),
        str(r'y${1}'),
        str('z`'),
        op('+'),
        num('1'),
      ]);
      expect(go('python', "s = '''a\nb'''\nx = 1"), [
        op('='),
        str("'''a"),
        str("b'''"),
        op('='),
        num('1'),
      ]);
      expect(go('rust', 'let r = r##"a "# b\nc"##; // x'), [
        kw('let'),
        op('='),
        str('r##"a "# b'),
        str('c"##'),
        com('// x'),
      ]);
      expect(go('rust', 'let s = "a\nb";'), [kw('let'), op('='), str('"a'), str('b"')]);
      expect(go('rust', '/* a /* b */ c */ x'), [com('/* a /* b */ c */')]);
      expect(go('c', '/* a /* b */ c */ x'), [com('/* a /* b */'), op('*/')]);
      expect(go('sql', "select 'a\nb' from t"), [kw('select'), str("'a"), str("b'"), kw('from')]);
      expect(go('shell', 'echo "a\nb" c'), [fn('echo'), str('"a'), str('b"')]);
      expect(go('shell', "cat <<'END'\nx \$y\nEND\necho"), [
        fn('cat'),
        op('<<'),
        con("'END'"),
        str('x \$y'),
        con('END'),
        fn('echo'),
      ]);
    });

    test('untrusted text: bidi and control characters stay inside tokens', () {
      // the renderer shows these as ‹U+202E›; the tokenizer must not drop them
      const line = 'var s = "a\u202Eb"; // \u0007';
      final h = highlighterFor('dart')!;
      final tokens = h.line(line, h.initial).$1;
      final text = tokens.map((t) => line.substring(t.start, t.end)).join('|');
      expect(text, contains('"a\u202Eb"'));
      expect(text, contains('// \u0007'));
    });
  });
}
