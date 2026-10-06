import 'dart:math';

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/streaming/reveal_pacer.dart';

import '../../benchmark/support/trace_cadence.dart';

const _frame = Duration(milliseconds: 16);

/// About [chars] characters of prose with the things agents write: words of
/// every length, paths, a URL, Vietnamese in both normalisations, emoji.
String _prose(int chars, {int seed = 1}) {
  final random = Random(seed);
  const words = [
    'the', 'parser', 'lowercases', 'before', 'it', 'normalises', 'lib/ui/core/markdown/md_parser.dart:128',
    'Hà', 'Nội', 'Việt', 'Nam', 'tiếng', 'https://example.com/docs/streaming?x=1&y=22', '`inline`', '**bold**',
    '👨\u200D👩\u200D👧\u200D👦', '🇻🇳', 'e\u0323\u0302', '–', 'a', 'of', 'anthropomorphization',
  ];
  final b = StringBuffer();
  while (b.length < chars) {
    b.write(words[random.nextInt(words.length)]);
    b.write(random.nextInt(14) == 0 ? '\n\n' : (random.nextInt(30) == 0 ? '\r\n' : ' '));
  }
  return b.toString();
}

class _Run {
  _Run(this.shown, this.maxLagMs, this.maxDelta, this.frames);

  final String shown;
  final double maxLagMs;
  final int maxDelta;
  final int frames;
}

/// Plays [text], cut into the chunks of [cadence] (`[gap, chars, ...]`, gaps in
/// tenths of a millisecond), into [pacer] at one `advance` per [dt], and
/// measures the lag: at the end of every frame, the age of the oldest
/// character that arrived and is not shown.
_Run _simulate(RevealPacer pacer, String text, List<int> cadence, {Duration dt = _frame, List<int>? jitterMs}) {
  final arrivals = <(int atUs, String chunk)>[];
  var at = 0;
  var i = 0;
  var k = 0;
  while (i < text.length) {
    at += cadence[k] * 100;
    final end = min(i + cadence[k + 1], text.length);
    arrivals.add((at, text.substring(i, end)));
    i = end;
    k = (k + 2) % cadence.length;
  }
  final starts = <int>[]; // offset of each chunk's first character
  var offset = 0;
  for (final a in arrivals) {
    starts.add(offset);
    offset += a.$2.length;
  }

  final shown = StringBuffer();
  var next = 0;
  var now = 0;
  var worstUs = 0;
  var maxDelta = 0;
  var frames = 0;
  var jitter = 0;
  while (shown.length < text.length) {
    final step = jitterMs == null ? dt.inMicroseconds : jitterMs[jitter++ % jitterMs.length] * 1000;
    now += step;
    while (next < arrivals.length && arrivals[next].$1 <= now) {
      pacer.append(arrivals[next++].$2);
    }
    final delta = pacer.advance(Duration(microseconds: step));
    shown.write(delta);
    maxDelta = max(maxDelta, delta.length);
    frames++;
    // The oldest chunk with a character not shown yet.
    var c = 0;
    while (c < next && (c + 1 < starts.length ? starts[c + 1] : text.length) <= shown.length) {
      c++;
    }
    if (c < next) worstUs = max(worstUs, now - arrivals[c].$1);
    if (frames > 100000) fail('does not end: shown ${shown.length} of ${text.length}');
  }
  return _Run(shown.toString(), worstUs / 1000, maxDelta, frames);
}

void main() {
  group('lag', () {
    final text = _prose(20000);

    for (final agent in traceCadence.keys) {
      test('$agent cadence: the lag stays under 250 ms and nothing is altered', () {
        final run = _simulate(RevealPacer(), text, traceCadence[agent]!);
        expect(run.shown, text);
        expect(run.maxLagMs, lessThanOrEqualTo(250), reason: '$agent: worst lag ${run.maxLagMs} ms');
      });

      test('$agent cadence with frames that arrive late: still bounded', () {
        final run = _simulate(RevealPacer(), text, traceCadence[agent]!, jitterMs: [16, 17, 16, 33, 16, 16, 50, 16, 16]);
        expect(run.shown, text);
        expect(run.maxLagMs, lessThanOrEqualTo(250), reason: '$agent: worst lag ${run.maxLagMs} ms');
      });
    }

    test('a lump every 500 ms (omp answers) drains inside the bound, in steps, not at once', () {
      // 176 characters together, then 500 ms of silence, the shape CADENCE.md measured.
      final run = _simulate(RevealPacer(), text, [5000, 176]);
      expect(run.shown, text);
      expect(run.maxLagMs, lessThanOrEqualTo(250));
      expect(run.maxDelta, lessThan(176 ~/ 2), reason: 'a lump is spread over frames');
    });

    test('a 200 ms burst of eight chunks (the synthetic profile) is bounded too', () {
      final run = _simulate(RevealPacer(), text, [0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 2000, 4]);
      expect(run.shown, text);
      expect(run.maxLagMs, lessThanOrEqualTo(250));
    });

    test('a steady stream keeps a short backlog, not the whole budget', () {
      // claude: 9 characters every 25 ms. The text is 100 ms or so behind, not 250.
      final run = _simulate(RevealPacer(), text, List.generate(200, (i) => i.isEven ? 250 : 9));
      expect(run.maxLagMs, lessThan(160));
    });

    test('a different tuning is honoured: maxLag 100 ms', () {
      final run = _simulate(RevealPacer(maxLag: const Duration(milliseconds: 100)), text, traceCadence['omp']!);
      expect(run.shown, text);
      expect(run.maxLagMs, lessThanOrEqualTo(150));
    });

    test('the reveal is steady: the largest step of a steady stream is a few words', () {
      final run = _simulate(RevealPacer(), text, traceCadence['claude']!);
      expect(run.maxDelta, lessThan(80));
    });
  });

  group('cuts', () {
    test('a word is shown whole; the partial last word waits for its space', () {
      final p = RevealPacer()..append('hello wor');
      final shown = StringBuffer();
      var frames = 0;
      for (; frames < 4; frames++) {
        shown.write(p.advance(_frame));
      }
      expect(shown.toString(), 'hello ');
      expect(p.pending, 'wor');

      p.append('ld again');
      for (var i = 0; i < 40 && p.backlog > 0; i++) {
        shown.write(p.advance(_frame));
      }
      expect(shown.toString().startsWith('hello world '), isTrue);
    });

    test('a partial last word is shown at its deadline when nothing follows', () {
      final p = RevealPacer()..append('done');
      var elapsed = Duration.zero;
      var shown = '';
      while (shown.isEmpty && elapsed < const Duration(seconds: 1)) {
        shown = p.advance(_frame);
        elapsed += _frame;
      }
      expect(shown, 'done');
      expect(elapsed, lessThanOrEqualTo(const Duration(milliseconds: 240)));
    });

    test('a token longer than 24 characters is cut on characters, not held for its end', () {
      final token = 'x' * 60;
      final p = RevealPacer()..append(token);
      final first = p.advance(_frame);
      expect(first, isNotEmpty);
      expect(first.length, lessThan(60));
      expect(token.startsWith(first), isTrue);
    });

    test('longToken is injectable', () {
      final p = RevealPacer(longToken: 4)..append('abcdefghij');
      expect(p.advance(_frame), isNotEmpty, reason: 'ten characters without a space is a long token at 4');
      final q = RevealPacer()..append('abcdefghij');
      expect(q.advance(_frame), isEmpty, reason: 'ten characters may be a word that is still arriving');
    });

    test('a trickle never stalls: at least minRate characters a frame once words are whole', () {
      final p = RevealPacer()..append('a ' * 200);
      var total = 0;
      for (var i = 0; i < 10; i++) {
        total += p.advance(_frame).length;
      }
      expect(total, greaterThanOrEqualTo(10 * 2 - 2));
    });

    test('nothing pending: nothing revealed, no credit saved up', () {
      final p = RevealPacer();
      expect(p.advance(const Duration(seconds: 10)), '');
      p.append('a b c d e f g h i j k l m n o p q r s t ');
      expect(p.advance(_frame).length, lessThan(12), reason: 'idle time is not banked');
    });

    test('a zero dt reveals nothing until a deadline; time does', () {
      final p = RevealPacer()..append('one two three ');
      expect(p.advance(Duration.zero), '');
      expect(p.advance(const Duration(seconds: 1)), 'one two three ');
    });
  });

  group('grapheme clusters', () {
    // Each of these must come out in whole clusters, whatever the rate.
    const clusters = [
      'Vie\u0323\u0302t', // decomposed Vietnamese: e + dot below + circumflex
      'Việt',
      '👨\u200D👩\u200D👧\u200D👦', // ZWJ family
      '🇻🇳', // flag: two regional indicators
      '😀', // surrogate pair
      '👍🏽', // emoji + skin tone
      'a\r\nb', // CRLF
      'ñ',
    ];

    bool endsOnBoundary(String full, String prefix) {
      var at = 0;
      for (final c in full.characters) {
        if (at == prefix.length) return true;
        if (at > prefix.length) return false;
        at += c.length;
      }
      return at == prefix.length;
    }

    test('every revealed prefix of a text arriving one code unit at a time ends on a boundary', () {
      for (var seed = 0; seed < 12; seed++) {
        final random = Random(seed);
        final text = [for (var i = 0; i < 120; i++) ...[clusters[random.nextInt(clusters.length)], ' ']].join();
        final p = RevealPacer(minRate: 1, k: 0.05);
        var shown = '';
        var fed = 0;
        while (shown.length < text.length) {
          final take = min(1 + random.nextInt(3), text.length - fed);
          p.append(text.substring(fed, fed + take));
          fed += take;
          shown += p.advance(_frame);
          expect(text.startsWith(shown), isTrue);
          expect(endsOnBoundary(text, shown), isTrue, reason: 'seed $seed: prefix ${shown.length} cuts a cluster');
          if (fed == text.length) shown += p.snap();
        }
        expect(shown, text);
      }
    });

    test('characters-only text (a long token of emoji and marks) is cut between clusters', () {
      final token = List.filled(40, 'Vie\u0323\u0302 👨\u200D👩\u200D👧 🇻🇳').join();
      final p = RevealPacer()..append(token);
      var shown = '';
      for (var i = 0; i < 5; i++) {
        shown += p.advance(_frame);
        expect(endsOnBoundary(token, shown), isTrue);
      }
      expect(shown, isNotEmpty);
    });

    test('the last cluster of the pending text waits: the next chunk may extend it', () {
      final p = RevealPacer(longToken: 2)..append('abcde');
      var shown = '';
      for (var i = 0; i < 5; i++) {
        shown += p.advance(_frame);
      }
      expect(shown, 'abcd', reason: 'the e may take a combining mark');
      p.append('\u0301');
      shown += p.advance(const Duration(milliseconds: 400));
      expect(shown, 'abcd\u0065\u0301');
    });

    test('a CRLF is never split, a lone CR at the end waits for its LF', () {
      final p = RevealPacer(longToken: 1)..append('ab\r');
      var shown = '';
      for (var i = 0; i < 40; i++) {
        shown += p.advance(_frame);
      }
      expect(shown.endsWith('\r'), isFalse);
      p.append('\ncd');
      for (var i = 0; i < 40; i++) {
        shown += p.advance(_frame);
      }
      expect(shown.contains('\r\n'), isTrue);
      expect(shown, startsWith('ab\r\n'));
    });

    test('a combining mark after a space does not make the space a cut', () {
      final text = 'aaa \u0301bbb ccc ';
      final p = RevealPacer(minRate: 5)..append(text);
      var shown = '';
      for (var i = 0; i < 20; i++) {
        shown += p.advance(_frame);
        expect(endsOnBoundary(text, shown), isTrue);
      }
    });
  });

  group('snapping', () {
    test('snap returns everything pending and empties the pacer', () {
      final p = RevealPacer()..append('half a wor');
      expect(p.snap(), 'half a wor');
      expect(p.backlog, 0);
      expect(p.isIdle, isTrue);
      expect(p.advance(_frame), '');
      expect(p.snap(), '');
    });

    test('a backlog past 8 KB is shown at once by advance', () {
      final big = _prose(9000);
      final p = RevealPacer()..append(big);
      expect(p.advance(_frame), big);
      expect(p.backlog, 0);
    });

    test('8 KB exactly is still paced; a paste after a trickle snaps', () {
      final p = RevealPacer(snapBacklog: 100)..append('x ' * 50);
      expect(p.advance(_frame).length, lessThan(100), reason: '100 is not past 100');
      p.append('y ' * 100);
      expect(p.advance(_frame).length, greaterThan(150));
    });

    test('a long gap (the app resumed) shows what is due, not a trickle', () {
      final p = RevealPacer()..append('some text that arrived before the pause ');
      expect(p.advance(const Duration(seconds: 30)), 'some text that arrived before the pause ');
    });
  });

  group('reduced motion', () {
    test('complete lines are shown at once, the partial line waits for its newline', () {
      final p = RevealPacer(reducedMotion: true)..append('first line\nsecond line\nthird par');
      expect(p.advance(_frame), 'first line\nsecond line\n');
      expect(p.pending, 'third par');
      expect(p.advance(_frame), '');
      p.append('tial\n');
      expect(p.advance(_frame), 'third partial\n');
    });

    test('a long paragraph with no newline arrives by its deadline, not never', () {
      final line = 'word ' * 100;
      final p = RevealPacer(reducedMotion: true)..append(line);
      var shown = '';
      var elapsed = Duration.zero;
      while (shown.isEmpty && elapsed < const Duration(seconds: 2)) {
        shown = p.advance(_frame);
        elapsed += _frame;
      }
      expect(shown, isNotEmpty);
      expect(elapsed, lessThanOrEqualTo(const Duration(milliseconds: 240)));
      expect(line.startsWith(shown), isTrue);
    });

    test('the mode can be switched while running', () {
      final p = RevealPacer()..append('a\nb');
      p.reducedMotion = true;
      expect(p.advance(_frame), 'a\n');
    });
  });

  group('determinism and integrity', () {
    test('the same appends and dts give the same deltas', () {
      List<String> run() {
        final random = Random(7);
        final p = RevealPacer();
        final text = _prose(6000, seed: 3);
        final out = <String>[];
        var fed = 0;
        while (fed < text.length || !p.isIdle) {
          if (fed < text.length) {
            final take = min(1 + random.nextInt(60), text.length - fed);
            p.append(text.substring(fed, fed + take));
            fed += take;
          }
          out.add(p.advance(Duration(milliseconds: 8 + random.nextInt(40))));
          if (out.length > 100000) fail('does not end');
        }
        return out;
      }

      expect(run(), run());
    });

    test('the deltas and the final snap are exactly what was appended, whatever the input and the dts', () {
      for (var seed = 0; seed < 40; seed++) {
        final random = Random(seed);
        final text = _prose(1 + random.nextInt(5000), seed: seed);
        final p = RevealPacer(
          minRate: 0.5 + random.nextDouble() * 4,
          k: random.nextDouble() / 3,
          maxLag: Duration(milliseconds: 50 + random.nextInt(400)),
          longToken: 1 + random.nextInt(40),
          snapBacklog: 500 + random.nextInt(9000),
          reducedMotion: random.nextInt(4) == 0,
        );
        final shown = StringBuffer();
        var fed = 0;
        for (var step = 0; step < 400 && fed < text.length; step++) {
          final take = min(random.nextInt(200), text.length - fed);
          p.append(text.substring(fed, fed + take));
          fed += take;
          shown.write(p.advance(Duration(milliseconds: random.nextInt(120))));
          if (random.nextInt(50) == 0) shown.write(p.snap());
        }
        p.append(text.substring(fed));
        shown.write(p.snap());
        expect(shown.toString(), text, reason: 'seed $seed');
      }
    });
  });
}
