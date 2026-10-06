import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/markdown/markdown.dart';

import 'support/all_texts.dart';

/// Every inline container of [blocks], depth first.
Iterable<MdInlines> _inlinesOf(Iterable<MdBlock> blocks) sync* {
  for (final b in blocks) {
    switch (b) {
      case MdParagraph():
        yield b.inlines;
      case MdHeading():
        yield b.inlines;
      case MdQuote():
        yield* _inlinesOf(b.blocks);
      case MdAlert():
        yield* _inlinesOf(b.blocks);
      case MdList():
        for (final i in b.items) {
          yield* _inlinesOf(i.blocks);
        }
      case MdTable():
        yield* b.header;
        for (final r in b.rows) {
          yield* r;
        }
      case MdCode() || MdRule():
        break;
    }
  }
}

void main() {
  final texts = allCorpusTexts();

  group('UTF-16 offset invariant', () {
    test('text is the concatenation of the runs and every run knows its start', () {
      var checked = 0;
      for (final t in texts) {
        final doc = parseMd(t.text);
        for (final inl in _inlinesOf(doc.blocks)) {
          var at = 0;
          for (var i = 0; i < inl.items.length; i++) {
            final run = inl.items[i];
            expect(inl.startOf(i), at, reason: '${t.name} run $i');
            expect(inl.text.substring(at, at + run.text.length), run.text,
                reason: '${t.name} run $i');
            at += run.text.length;
            expect(inl.endOf(i), at);
          }
          expect(inl.text.length, at, reason: t.name);
          expect(inl.length, at);
          checked++;
        }
      }
      expect(checked, greaterThan(300));
    });

    test('indexAt finds the run that holds each offset', () {
      for (final t in texts.take(120)) {
        for (final inl in _inlinesOf(parseMd(t.text).blocks)) {
          for (var off = 0; off <= inl.length; off++) {
            final i = inl.indexAt(off);
            if (inl.isEmpty) {
              expect(i, -1);
              continue;
            }
            expect(inl.startOf(i), lessThanOrEqualTo(off), reason: t.name);
            if (off < inl.length) {
              expect(inl.endOf(i), greaterThan(off), reason: '${t.name} @$off');
            } else {
              expect(i, inl.items.length - 1);
            }
          }
        }
      }
    });

    test('offsets count UTF-16 units: diacritics, emoji, ZWJ, bidi controls', () {
      final doc = parseMd('Hà **Nội** 👨‍👩‍👧 \u202eab\u202c `c`');
      final inl = (doc.blocks.single as MdParagraph).inlines;
      expect(inl.text, 'Hà Nội 👨‍👩‍👧 \u202eab\u202c c');
      expect(inl.length, inl.text.length);
      expect(inl.startOf(1), 'Hà '.length);
      expect(inl.items[1].text, 'Nội');
      expect(inl.items[2].text.runes.length, lessThan(inl.items[2].text.length));
    });

    test('a hard break is one newline, an image is its alt text', () {
      final doc = parseMd('a<br>b ![chart](https://x.y/c.png) c');
      final inl = (doc.blocks.single as MdParagraph).inlines;
      expect(inl.text, 'a\nb chart c');
      expect(inl.items.whereType<MdBreak>().single.text, '\n');
      final img = inl.items.whereType<MdImage>().single;
      expect(img.text, 'chart');
      expect(img.src, 'https://x.y/c.png');
      expect(inl.startOf(inl.items.indexOf(img)), 'a\nb '.length);
    });
  });

  group('plainText', () {
    test('blocks, lists, quotes and tables', () {
      final doc = parseMd('# T\n\n- a\n- **b**\n\n> q1\n>\n> q2\n\n| x | y |\n|---|---|\n| 1 | 2 |\n\n```\ncode\n```\n\n---');
      expect(doc.blocks.map((b) => b.plainText).toList(),
          ['T', 'a\nb', 'q1\nq2', 'x\ty\n1\t2', 'code', '']);
      expect(doc.plainText, 'T\n\na\nb\n\nq1\nq2\n\nx\ty\n1\t2\n\ncode\n\n');
    });

    test('nested lists and task items keep their text, not their markers', () {
      final doc = parseMd('- [x] one\n  - two\n- three');
      expect(doc.plainText, 'one\ntwo\nthree');
      final list = doc.blocks.single as MdList;
      expect(list.items.first.checked, isTrue);
      expect(list.items.last.checked, isNull);
    });
  });

  group('model', () {
    test('MdSpan.tappable: null and empty links are not tappable', () {
      expect(const MdSpan('a').tappable, isFalse);
      expect(const MdSpan('a', link: '').tappable, isFalse);
      expect(const MdSpan('a', link: 'https://x.y').tappable, isTrue);
      final partial = parseMd(healTail('[the docs](https://exa'));
      final span = (partial.blocks.single as MdParagraph).inlines.items.single as MdSpan;
      expect(span.link, '');
      expect(span.tappable, isFalse);
      expect(span.text, 'the docs');
    });

    test('MdStyle is a set', () {
      final s = MdStyle.bold | MdStyle.code;
      expect(s.has(MdStyle.bold), isTrue);
      expect(s.has(MdStyle.code), isTrue);
      expect(s.has(MdStyle.italic), isFalse);
      expect(MdStyle.none.has(MdStyle.bold), isFalse);
    });

    test('list facts: ordered start, tight and loose', () {
      final doc = parseMd('3. a\n4. b\n\n- x\n\n- y');
      final ordered = doc.blocks[0] as MdList;
      expect([ordered.ordered, ordered.start, ordered.tight], [true, 3, true]);
      final loose = doc.blocks[1] as MdList;
      expect([loose.ordered, loose.start, loose.tight], [false, 1, false]);
    });

    test('table rows always have one cell per column', () {
      final t = parseMd('| a | b | c |\n|:-|:-:|-:|\n| 1 |\n| 1 | 2 | 3 | 4 |').blocks.single as MdTable;
      expect(t.columns, 3);
      expect(t.aligns, [MdAlign.left, MdAlign.center, MdAlign.right]);
      expect(t.rows.every((r) => r.length == 3), isTrue);
    });

    test('code keeps its text exactly, minus the list indent', () {
      final doc = parseMd('1. step\n\n   ```sh\n   a\n\n     b\n   ```');
      final item = (doc.blocks.single as MdList).items.single;
      expect((item.blocks[1] as MdCode).text, 'a\n\n  b');
      expect((item.blocks[1] as MdCode).language, 'sh');
    });

    test('the engine is never visible: only model types come out', () {
      for (final t in texts.take(40)) {
        for (final b in parseMd(t.text).blocks) {
          expect(b, isA<MdBlock>());
        }
      }
    });

    test('empty and blank input give an empty document', () {
      expect(parseMd('').isEmpty, isTrue);
      expect(parseMd('  \n\n \t\n').isEmpty, isTrue);
      expect(MdDocument.empty.plainText, '');
    });

    test('an engine failure shows the text instead of throwing', () {
      // Found by the fuzz test: the engine's block parser stops advancing.
      const nasty = '>\n[x]\n|---|---|\n> text';
      expect(() => parseMd(nasty), returnsNormally);
      expect(parseMd(nasty).plainText, isNotEmpty);
    });
  });
}
