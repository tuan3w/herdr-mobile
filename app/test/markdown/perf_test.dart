import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/markdown/markdown.dart';
import 'package:herdr_mobile/ui/core/markdown/md_parser.dart' show parseMdUnchunked;

import 'support/all_texts.dart';
import 'support/corpus.dart';
import 'support/md_dump.dart';

/// Realistic material (the corpus' agent answers) repeated up to [bytes].
String _message(int bytes) {
  final pieces = [
    for (final c in loadCorpus(corpusDir))
      if (c.file == 'agent.case') c.input,
    for (final m in loadMessages('$corpusDir/messages')) m.text,
  ];
  final b = StringBuffer();
  var i = 0;
  while (b.length < bytes) {
    b
      ..write(pieces[i++ % pieces.length])
      ..write('\n\n');
  }
  return b.toString();
}

/// Worst cases (`herdr-screen-check`) for the Markdown renderer.
Map<String, String> _worstCases() => {
      'code block of 1000 lines': '```dart\n${[
        for (var i = 0; i < 1000; i++) '  final value$i = compute($i, "line $i");',
      ].join('\n')}\n```\n\nafter',
      'table of 40 columns': () {
        final head = [for (var c = 0; c < 40; c++) 'col$c'];
        return '| ${head.join(' | ')} |\n|${List.filled(40, '---').join('|')}|\n${[
          for (var r = 0; r < 30; r++) '| ${[for (var c = 0; c < 40; c++) '$r,$c'].join(' | ')} |',
        ].join('\n')}\n\nafter';
      }(),
      'list of 300 items': [
        for (var i = 0; i < 300; i++) '- item $i with **bold** and `code` and [a link](https://x.y/$i)',
      ].join('\n'),
      '5 levels of nesting': [
        for (var d = 0; d < 5; d++) '${'  ' * d}- level $d\n${'  ' * d}  > quote $d',
      ].join('\n'),
      'quotes in quotes': '> 1\n> > 2\n> > > 3\n> > > > 4\n> > > > > 5\n> > > > > > 6 deep',
      'Vietnamese and RTL': '**Đã sửa** lỗi `Hà Nội`.\n\nنص عربي **غامق** و `code` ثم עברית.\n\nTiếng Việt: ${'ặ ế ữ ọ ' * 200}',
      'bidi overrides': 'a \u202eevil\u202c b `c\u2066d\u2069` [x\u202e](https://x.y/\u202e)',
      'a very long line': 'word ' * 20000,
      '200 KB message': _message(200 * 1024),
    };

void main() {
  group('worst cases', () {
    final cases = _worstCases();
    for (final e in cases.entries) {
      test('${e.key}: parses, streams to the same blocks, heals', () {
        final text = e.value;
        final parsed = dumpDocument(parseMd(text));
        // The chunker did not split a block anywhere.
        expect(parsed, dumpDocument(parseMdUnchunked(text)));
        // The stream equals the parse at sampled prefixes and at the end
        // (every prefix is tested on the corpus; this keeps big texts quick).
        final s = StreamingMd();
        final step = (text.length / 150).ceil().clamp(1, 1 << 30);
        for (var at = 0; at < text.length; at += step) {
          final end = (at + step).clamp(0, text.length);
          s.append(text.substring(at, end));
          if ((at ~/ step) % 15 == 0) {
            expect(dumpDocument(s.document()), dumpDocument(parseMd(text.substring(0, end))),
                reason: '${e.key} @$end');
          }
          // Healing the tail of a half-written message never throws.
          s.tail(heal: true);
        }
        expect(dumpDocument(s.document()), parsed);
      }, timeout: const Timeout(Duration(minutes: 2)));
    }

    test('nesting is structural: 5 levels of list and quote', () {
      final doc = parseMd(cases['5 levels of nesting']!);
      var depth = 0;
      List<MdBlock> blocks = doc.blocks;
      while (true) {
        final list = blocks.whereType<MdList>().firstOrNull;
        if (list == null) break;
        depth++;
        blocks = list.items.single.blocks;
      }
      expect(depth, 5);
      final q = parseMd(cases['quotes in quotes']!);
      var qd = 0;
      List<MdBlock> qb = q.blocks;
      while (qb.whereType<MdQuote>().isNotEmpty) {
        qd++;
        qb = qb.whereType<MdQuote>().first.blocks;
      }
      expect(qd, 6);
    });

    test('a 300-item list is one list; a 1000-line fence is one code block', () {
      expect(parseMd(cases['list of 300 items']!).blocks.single, isA<MdList>());
      expect((parseMd(cases['list of 300 items']!).blocks.single as MdList).items.length, 300);
      final code = parseMd(cases['code block of 1000 lines']!).blocks.first as MdCode;
      expect(code.text.split('\n').length, 1000);
    });
  });

  group('speed (JIT, debug asserts on)', () {
    test('a 200 KB message parses in well under the budget', () {
      final text = _message(200 * 1024);
      parseMd(text); // warm up
      final w = Stopwatch()..start();
      final doc = parseMd(text);
      w.stop();
      printOnFailure('200 KB parse: ${w.elapsedMilliseconds} ms, ${doc.blocks.length} blocks');
      // Budget: 3 s on this machine in the JIT. AOT on the same machine is
      // ~70 ms (tool/md-bench).
      expect(w.elapsedMilliseconds, lessThan(3000));
      expect(doc.blocks.length, greaterThan(500));
    });

    test('per-step cost does not grow with the length of the message', () {
      // A 60 KB answer arriving 6 characters at a time; every step reads the
      // blocks the way a frame would (frozen count + healed tail).
      final text = _message(60 * 1024);
      final s = StreamingMd();
      final costs = <int>[];
      final sw = Stopwatch();
      for (var at = 0; at < text.length; at += 6) {
        s.append(text.substring(at, (at + 6).clamp(0, text.length)));
        sw
          ..reset()
          ..start();
        s.frozen.length;
        s.tail(heal: true);
        sw.stop();
        costs.add(sw.elapsedMicroseconds);
      }
      double median(List<int> v) {
        final c = [...v]..sort();
        return c[c.length ~/ 2].toDouble();
      }

      final n = costs.length;
      final first = median(costs.sublist(n ~/ 20, n ~/ 5));
      final last = median(costs.sublist(n - n ~/ 5, n - n ~/ 20));
      printOnFailure('median step: first fifth $first us, last fifth $last us, $n steps');
      // Re-parsing the whole text each step would make the last fifth ~5x the
      // first; the tail only is ~1x. Allow 3x for noise and tail-size variance.
      expect(last, lessThan(first * 3 + 300));
      expect(s.frozen.length, greaterThan(300));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  test('every corpus text parses and streams without throwing', () {
    for (final t in allCorpusTexts()) {
      final s = StreamingMd()..append(t.text);
      expect(dumpDocument(s.document()), dumpDocument(parseMd(t.text)), reason: t.name);
    }
  });
}
