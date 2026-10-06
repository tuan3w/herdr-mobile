import 'dart:io' show Platform;
import 'dart:math' show Random;

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/markdown/markdown.dart';
import 'package:herdr_mobile/ui/core/markdown/md_chunker.dart';
import 'package:herdr_mobile/ui/core/markdown/md_parser.dart' show parseMdUnchunked;

import 'support/all_texts.dart';
import 'support/corpus.dart';
import 'support/md_dump.dart';
import 'support/traces.dart';

String _stream(String prefix, {bool soft = true}) {
  final s = StreamingMd(softBreaksAsNewlines: soft)..append(prefix);
  return dumpDocument(s.document());
}

void main() {
  final texts = allCorpusTexts();

  group('stream(prefix) == parse(prefix)', () {
    // The streaming invariant (a stream's document equals the parse of the
    // same text), at EVERY prefix (one
    // character at a time, so a block freezes exactly when the text allows) of
    // every corpus text.
    for (final t in texts) {
      test(t.name, () {
        final s = StreamingMd();
        for (var p = 1; p <= t.text.length; p++) {
          s.append(t.text[p - 1]);
          final got = dumpDocument(s.document());
          final want = dumpDocument(parseMd(t.text.substring(0, p)));
          if (got != want) {
            fail('prefix $p of ${t.name}: ${_show(t.text.substring(0, p))}\n'
                'stream:\n$got\nparse:\n$want');
          }
        }
      });
    }

    test('the real chunking of the trace fixtures gives the same blocks', () {
      for (final m in loadTraceMessages(tracesDir)) {
        final s = StreamingMd();
        final b = StringBuffer();
        for (final c in m.chunks) {
          s.append(c);
          b.write(c);
          expect(dumpDocument(s.document()), dumpDocument(parseMd(b.toString())),
              reason: '${m.name} after ${b.length} chars');
        }
      }
    });
  });

  group('chunked parse == one engine call', () {
    // The chunker must never split a block: parseMd (chunks) against the
    // engine run over the whole text, at the end and after every line.
    for (final t in texts) {
      test(t.name, () {
        final lines = t.text.split('\n');
        var upTo = '';
        for (var i = 0; i < lines.length; i++) {
          upTo = i == 0 ? lines[0] : '$upTo\n${lines[i]}';
          final a = dumpDocument(parseMd(upTo));
          final b = dumpDocument(parseMdUnchunked(upTo));
          if (a != b) {
            fail('after line $i of ${t.name}: ${_show(upTo)}\nchunked:\n$a\nwhole:\n$b');
          }
        }
      });
    }
  });

  group('fuzz: chunked == one engine call', () {
    // Random documents from the line shapes that make a chunker go wrong:
    // lists with continuations, fences in items, quotes, tables, html, setext.
    const pool = [
      '- a', '  - b', '    - c', '* item', '+ item', '1. one', '2) two', '   more text',
      '  indented 2', '    indented 4', '\tTabbed', '', '', '', '> quote', '> > nested',
      '>', '```', '```dart', '~~~', '````', '  ```', '    ```', 'text', 'more text **b**',
      '# Heading', '## H2 ##', '---', '===', '***', '- - -', '| a | b |', '|---|---|',
      '| 1 | 2 |', '|', '<div>', '</div>', '<!-- c -->', '<!--', '-->', '<pre>', '</pre>',
      '[x]', '- [ ] task', '  - [x] done', 'Setext', '> [!NOTE]',
      '> text', 'a  ', 'hard\\', '<br>', '![i](u)', '`code`', '`', '``', '**', '~~',
    ];
    // MD_FUZZ_DOCS / MD_FUZZ_SEED widen a one-off run; CI keeps the defaults.
    final rnd = Random(int.tryParse(Platform.environment['MD_FUZZ_SEED'] ?? '') ?? 20260705);
    final docs = int.tryParse(Platform.environment['MD_FUZZ_DOCS'] ?? '') ?? 400;
    for (var d = 0; d < docs; d++) {
      final n = 3 + rnd.nextInt(24);
      final lines = [for (var i = 0; i < n; i++) pool[rnd.nextInt(pool.length)]];
      test('doc $d', () {
        var upTo = '';
        for (var i = 0; i < lines.length; i++) {
          upTo = i == 0 ? lines[0] : '$upTo\n${lines[i]}';
          final whole = parseMdUnchunked(upTo);
          // The engine throws on a few random inputs (its block parser stops
          // advancing); parseMd shows such a chunk as text. Not the chunker's.
          if (whole.blocks.length == 1 && whole.blocks.single.plainText == upTo.trimRight()) {
            continue;
          }
          final a = dumpDocument(parseMd(upTo));
          final b = dumpDocument(whole);
          if (a != b) {
            fail('after line $i: ${_show(upTo)}\nchunked:\n$a\nwhole:\n$b');
          }
        }
      });
    }
  });

  group('freezing', () {
    test('a paragraph freezes at its blank line, not later', () {
      final s = StreamingMd()..append('first paragraph\n');
      expect(s.frozen, isEmpty);
      s.append('\n');
      expect(s.frozen.length, 1);
      expect(s.tail().length, 0);
      s.append('second');
      expect(s.frozen.length, 1);
      expect(s.tail().length, 1);
    });

    test('a list that may continue stays in the tail', () {
      final s = StreamingMd()..append('- a\n- b\n\n');
      expect(s.frozen, isEmpty);
      s.append('  more\n');
      expect(s.frozen, isEmpty);
      expect(dumpDocument(s.document()), contains('p "more"'));
      s.append('\nnext paragraph\n');
      expect(s.frozen.length, 1, reason: 'the list ends where a paragraph starts');
      expect((s.frozen.single as MdList).items.last.blocks.length, 2);
    });

    test('an open code fence swallows blank lines and stays in the tail', () {
      final s = StreamingMd()..append('intro\n\n```dart\nvoid a() {}\n\nvoid b() {}\n\n');
      expect(s.frozen.length, 1);
      expect(s.tail().single, isA<MdCode>());
      s.append('```\n\nafter\n');
      expect(s.frozen.length, 2);
      expect((s.frozen[1] as MdCode).text, 'void a() {}\n\nvoid b() {}\n');
    });

    test('a table row after its delimiter is still in the tail', () {
      final s = StreamingMd()..append('| a | b |\n|---|---|\n| 1 | 2 |\n');
      expect(s.frozen, isEmpty);
      expect(s.tail().single, isA<MdTable>());
      s.append('\nafter\n');
      expect(s.frozen.single, isA<MdTable>());
    });

    test('an unterminated last line never decides a boundary', () {
      final s = StreamingMd()..append('- a\n\n ');
      expect(s.frozen, isEmpty);
      s.append(' more');
      expect(dumpDocument(s.document()), contains('p "more"'));
    });

    test('frozen blocks keep their identity while the message grows', () {
      final text = texts.firstWhere((t) => t.name.contains('answer_review')).text;
      final s = StreamingMd();
      var seen = <MdBlock>[];
      for (var p = 1; p <= text.length; p++) {
        s.append(text[p - 1]);
        final now = List<MdBlock>.of(s.frozen);
        expect(now.length, greaterThanOrEqualTo(seen.length));
        for (var i = 0; i < seen.length; i++) {
          expect(identical(now[i], seen[i]), isTrue, reason: 'block $i @$p');
        }
        seen = now;
      }
      expect(seen, isNotEmpty);
    });

    test('frozen is an unmodifiable view of one growing list', () {
      final s = StreamingMd()..append('a\n\n');
      final f = s.frozen;
      s.append('b\n\nc');
      expect(identical(f, s.frozen), isTrue);
      expect(f.length, 2);
      expect(() => f.add(const MdRule()), throwsUnsupportedError);
    });

    test('version changes with every append and tail() is cached between', () {
      final s = StreamingMd()..append('a');
      final v = s.version;
      final t = s.tail();
      expect(identical(t, s.tail()), isTrue);
      s.append('b');
      expect(s.version, greaterThan(v));
      expect(identical(t, s.tail()), isFalse);
    });

    test('CRLF split across appends is one newline', () {
      final s = StreamingMd()
        ..append('a\r')
        ..append('\nb\r\n')
        ..append('\r\nc');
      expect(dumpDocument(s.document()), dumpDocument(parseMd('a\nb\n\nc')));
      expect(s.text, 'a\nb\n\nc');
    });
  });

  group('healing applies to the tail only', () {
    test('a half-written span is closed in the tail, never in frozen blocks', () {
      final s = StreamingMd()..append('done **early\n\nnow **bo');
      expect(dumpBlocks(s.frozen), 'p "done **early"');
      expect(dumpBlocks(s.tail()), 'p "now **bo"');
      expect(dumpBlocks(s.tail(heal: true)), 'p "now " b"bo"');
    });

    test('the unhealed document is exactly the final one', () {
      final s = StreamingMd()..append('text **bold');
      expect(dumpDocument(s.document()), dumpDocument(parseMd('text **bold')));
      expect(dumpDocument(s.document(heal: true)), 'p "text " b"bold"');
    });

    test('a marker-only line is held back', () {
      final s = StreamingMd()..append('Intro\n\n##');
      expect(dumpBlocks(s.tail(heal: true)), isEmpty);
      s.append(' Title');
      expect(dumpBlocks(s.tail(heal: true)), 'h2 "Title"');
    });
  });

  group('softBreaksAsNewlines', () {
    test('default keeps a newline, false joins with a space', () {
      expect(_stream('a\nb'), 'p "a\\nb"');
      expect(_stream('a\nb', soft: false), 'p "a b"');
      expect(dumpDocument(parseMd('a\nb', softBreaksAsNewlines: false)), 'p "a b"');
    });

    test('code text keeps its newlines either way', () {
      expect(dumpDocument(parseMd('```\na\nb\n```', softBreaksAsNewlines: false)),
          'code "a\\nb"');
    });
  });

  group('chunker', () {
    List<String> chunks(String text) {
      final c = MdChunker();
      for (final l in text.split('\n')) {
        c.addLine(l);
      }
      return [for (final r in c.closed) c.source(r.start, r.end)];
    }

    test('blank lines split plain blocks, fences and html comments do not', () {
      expect(chunks('a\n\nb\n\n'), ['a', 'b']);
      expect(chunks('```\na\n\nb\n```\n\nc'), ['```\na\n\nb\n```']);
      expect(chunks('<!--\nx\n\ny\n-->\n\nc'), ['<!--\nx\n\ny\n-->']);
      expect(chunks('~~~\n```\n\n~~~\n\nc'), ['~~~\n```\n\n~~~']);
    });

    test('lists continue over blank lines when indented or another item', () {
      expect(chunks('- a\n\n  b\n\nc'), ['- a\n\n  b']);
      expect(chunks('- a\n\n- b\n\nc'), ['- a\n\n- b']);
      expect(chunks('1. a\n\n   ```\n   x\n   ```\n\nc'), ['1. a\n\n   ```\n   x\n   ```']);
      expect(chunks('text\n- a\n\n  b\n\nc'), ['text\n- a\n\n  b']);
    });

    test('indented code continues while indented', () {
      expect(chunks('    a\n\n    b\n\nc'), ['    a\n\n    b']);
    });

    test('quotes end at a blank line', () {
      expect(chunks('> a\n>\n> b\n\n> c\n\nd'), ['> a\n>\n> b', '> c']);
    });
  });

  group('closed chunks never change', () {
    test('appending never alters what was closed', () {
      final text = texts.map((t) => t.text).where((t) => t.length > 800).join('\n\n');
      final c = MdChunker();
      final seen = <String>[];
      for (final line in text.split('\n')) {
        c.addLine(line);
        for (var i = 0; i < seen.length; i++) {
          final r = c.closed[i];
          expect(c.source(r.start, r.end), seen[i]);
        }
        for (var i = seen.length; i < c.closed.length; i++) {
          final r = c.closed[i];
          seen.add(c.source(r.start, r.end));
        }
      }
      expect(seen.length, greaterThan(10));
    });
  });

  test('a corpus is present', () {
    expect(loadCorpus(corpusDir), isNotEmpty);
    expect(texts.length, greaterThan(150));
  });
}

String _show(String s) => s.length > 400 ? '…${s.substring(s.length - 400)}' : s;
