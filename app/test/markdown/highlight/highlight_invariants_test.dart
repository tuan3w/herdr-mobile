import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/markdown/highlight/highlight.dart';

import 'samples.dart';
import 'support.dart';

/// One name per scanner (aliases are tested in the golden test).
const _languages = [
  'js', 'ts', 'python', 'shell', 'console', 'json', 'yaml', 'toml', 'sql',
  'rust', 'go', 'c', 'cpp', 'java', 'kotlin', 'swift', 'dart', 'html', 'css',
  'scss', 'diff', 'markdown', 'dockerfile', 'make',
];

/// Source-like fragments that open and close things in every language.
const _fragments = [
  '"', "'", '`', '"""', "'''", '/*', '*/', '//', '#', '--', '<!--', '-->',
  '<', '>', '</', '/>', '=', ':', ';', '{', '}', '(', ')', '[', ']', '\\',
  r'$', r'${', r'$(', '<<EOF', 'EOF', '<<-', '@', '@@', '+', '-', '*', '_',
  '0x', '1e', '.5', '#[', 'r#"', '"#', "r'", 'f"', '|', '>', '&&', ' ', '\t',
  '\u00e9', '\u202E', '\u0007', '\uD800', '\uDC00', '\u{1F600}', 'let ', 'fn ',
  'def ', 'class ', 'SELECT ', 'true', 'null', 'if', 'else', 'return', 'x',
  'Foo', 'BAR', '12', '3.14', '```', '---', '...', '- ', '| ', '&amp;', '%',
];

String _randomText(Random r) {
  final b = StringBuffer();
  final pieces = r.nextInt(40);
  for (var i = 0; i < pieces; i++) {
    final roll = r.nextInt(20);
    if (roll == 0) {
      b.write('\n');
    } else if (roll == 1) {
      b.writeCharCode(r.nextInt(0x10000)); // any code unit, maybe a surrogate
    } else if (roll == 2) {
      b.write('x' * r.nextInt(300));
    } else {
      b.write(_fragments[r.nextInt(_fragments.length)]);
    }
  }
  return b.toString();
}

void main() {
  group('invariants', () {
    for (final lang in _languages) {
      test('$lang: tokens are sorted, non-overlapping and inside the line', () {
        final h = highlighterFor(lang)!;
        final code = samples[lang]!;
        var state = h.initial;
        for (final line in code.split('\n')) {
          final (tokens, next) = h.line(line, state);
          checkTokens(line, tokens);
          state = next;
        }
      });

      test('$lang: the state transition is deterministic and restartable', () {
        final h = highlighterFor(lang)!;
        final code = samples[lang]!;
        final lines = code.split('\n');
        final states = [h.initial];
        final full = <List<Token>>[];
        for (final line in lines) {
          final (tokens, next) = h.line(line, states.last);
          full.add(tokens);
          states.add(next);
        }
        // the same line in the same state always gives the same answer
        for (var i = 0; i < lines.length; i++) {
          final again = h.line(lines[i], states[i]);
          expect(again.$1, full[i], reason: '$lang line $i');
          expect(again.$2, states[i + 1], reason: '$lang line $i');
        }
        // where no state is carried, reading can restart (or pause for a
        // blank line) without changing a thing
        for (var i = 1; i < lines.length; i++) {
          if (states[i] != h.initial) continue;
          var s = h.initial;
          for (var k = i; k < lines.length; k++) {
            final (tokens, next) = h.line(lines[k], s);
            expect(tokens, full[k], reason: '$lang restart at $i, line $k');
            s = next;
          }
          var s2 = h.line('', h.initial).$2;
          expect(s2, h.initial, reason: '$lang blank line at a seam');
          for (var k = i; k < lines.length; k++) {
            final (tokens, next) = h.line(lines[k], s2);
            expect(tokens, full[k]);
            s2 = next;
          }
        }
      });
    }

    test('the sample for every language exists', () {
      for (final lang in _languages) {
        expect(samples[lang], isNotNull, reason: lang);
      }
    });
  });

  group('fuzz', () {
    for (final lang in _languages) {
      test('$lang: 2000 random texts never throw and keep the invariants', () {
        final h = highlighterFor(lang)!;
        final r = Random(lang.hashCode);
        for (var n = 0; n < 2000; n++) {
          final text = _randomText(r);
          var state = h.initial;
          for (final line in text.split('\n')) {
            final (tokens, next) = h.line(line, state);
            checkTokens(line, tokens);
            state = next;
          }
        }
      });
    }

    test('very long lines, lone surrogates and empty input', () {
      for (final lang in _languages) {
        final h = highlighterFor(lang)!;
        for (final line in [
          '',
          '\uD800',
          '\uDC00x',
          'a\uD800"\uDC00',
          '"' * 5000,
          '/*' * 3000,
          'x' * 100000,
          '\u{1F600}' * 1500,
          '"\u{1F600}' * 700,
        ]) {
          final (tokens, _) = h.line(line, h.initial);
          checkTokens(line, tokens);
        }
      }
    });

    test('foreign state objects are tolerated', () {
      final js = highlighterFor('js')!;
      final dart = highlighterFor('dart')!;
      final (_, open) = js.line('/* x', js.initial);
      checkTokens('b */', dart.line('b */', open).$1);
    });
  });

  group('perf', () {
    String lines(String lang, int count) {
      final base = samples[lang]!.split('\n');
      return [for (var i = 0; i < count; i++) base[i % base.length]].join('\n');
    }

    // Minimum of a few runs, in microseconds.
    int timeIt(String lang, String code) {
      final h = highlighterFor(lang)!;
      final all = code.split('\n');
      var best = 1 << 40;
      for (var run = 0; run < 7; run++) {
        final sw = Stopwatch()..start();
        var state = h.initial;
        var tokens = 0;
        for (final line in all) {
          final (t, next) = h.line(line, state);
          tokens += t.length;
          state = next;
        }
        sw.stop();
        if (tokens < 0) fail('unreachable');
        if (sw.elapsedMicroseconds < best) best = sw.elapsedMicroseconds;
      }
      return best;
    }

    for (final lang in ['dart', 'ts', 'python']) {
      test('$lang: 1000 lines fast, cost linear in size', () {
        final k1 = lines(lang, 1000);
        final k8 = lines(lang, 8000);
        timeIt(lang, k1); // warm up the JIT
        final t1 = timeIt(lang, k1);
        final t8 = timeIt(lang, k8);
        // ignore: avoid_print
        print('$lang: 1000 lines ${t1 / 1000} ms, 8000 lines ${t8 / 1000} ms');
        // Budget: 1000 lines under 15 ms. Measured ~0.1-0.4 ms even on the
        // JIT test VM, so the bar leaves room for a loaded machine; a
        // quadratic or regex-per-token scanner would be far above it.
        expect(t1, lessThan(15 * 1000), reason: '1000 lines took ${t1 / 1000} ms');
        expect(t8, lessThan(t1 * 8 * 2.5), reason: 'not linear: $t1 us -> $t8 us');
      });
    }

    test('a 2000-character line costs little and 4x length costs 4x at most', () {
      final h = highlighterFor('js')!;
      String body(int n) {
        final b = StringBuffer();
        while (b.length < n) {
          b.write('foo(1, "bar", baz) + ');
        }
        return b.toString().substring(0, n);
      }

      final short = body(500), long = body(2000);
      int cost(String s) {
        var best = 1 << 40;
        for (var run = 0; run < 20; run++) {
          final sw = Stopwatch()..start();
          for (var i = 0; i < 20; i++) {
            h.line(s, h.initial);
          }
          sw.stop();
          if (sw.elapsedMicroseconds < best) best = sw.elapsedMicroseconds;
        }
        return best;
      }

      cost(long);
      final a = cost(short), b = cost(long);
      expect(b, lessThan(a * 4 * 3 + 200), reason: '$a us vs $b us');
    });
  });
}
