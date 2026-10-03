import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/ansi.dart';
import 'package:herdr_mobile/ui/core/line_wrap.dart';
import 'package:herdr_mobile/ui/core/terminal_document.dart';
import 'package:herdr_mobile/ui/core/theme.dart';

const _esc = '\x1b';

String _sgr(String params) => '$_esc[${params}m';

String _show(String s) => s
    .replaceAll(_esc, r'\e')
    .replaceAll('\r', r'\r')
    .replaceAll('\n', r'\n')
    .replaceAll('\t', r'\t');

/// Everything observable about parsed lines, as comparable values.
List<Object> _dump(List<List<AnsiRun>> lines, int columns) => [
      columns,
      for (final line in lines)
        [
          for (final r in line)
            [
              r.text,
              r.fg?.toARGB32(),
              r.bg?.toARGB32(),
              r.bold,
              r.dim,
              r.italic,
              r.underline,
              r.strike,
            ],
        ],
    ];

List<Object> _dumpDoc(TerminalDocument doc) =>
    _dump([for (final l in doc.lines) l.runs], doc.columns);

List<Object> _dumpParsed(AnsiDocument doc) => _dump(doc.lines, doc.columns);

/// What a document of [history] rows over a window [text] must show: the
/// history parsed as one text, the window as another (the window starts in
/// the default style whatever the last history row left open).
List<Object> _expected(List<String> history, String text) {
  final above = parseAnsi(history.isEmpty ? '' : '${history.join('\n')}\n');
  final window = parseAnsi(text);
  return _dump(
    [...above.lines, ...window.lines],
    max(above.columns, window.columns),
  );
}

const _words = [
  'ls', 'hello', 'x', '   ', '  ', '│', '日本語', '😀', 'é', 'a\u0301', '░▒▓',
  '[', ']', ';', ':', '\\', '\x7f', '\x00', '\x08', '\t',
];

const _escapes = [
  '0', '', '1', '2', '3', '4', '4:0', '4:3', '7', '9', '22', '23', '24', '27',
  '29', '31', '32', '39', '41', '49', '90', '97', '100', '107',
  '38;5;196', '38;5;300', '48;5;16', '38;2;1;2;3', '48;2;10;20;30',
  '38;2;1;2', '38:2::10:20:30', '38:2:10:20:30', '38:5:100', '48:2::300:0:0',
  '1;31;44', '0;1;38;2;94;234;212', '38', '48;5', '999999999999', ';;', '?25',
];

const _other = [
  '\x1b[2J', '\x1b[H', '\x1b[?25h', '\x1b[1;1H', '\x1b[K', '\x1b(B', '\x1b=',
  '\x1b]0;title\x07', '\x1b]8;;http://x\x1b\\', '\x1b]0;unterminated',
  '\x1bPdcs\x1b\\', '\x1b_apc\x07', '\x1b[3', '\x1b[', '\x1b', '\x1b[38;5;',
  '\x1b[31', '\x1b\x1b[31m', '\x1b[\x1b[1m', '\r', '\r\r',
];

/// A random line (without line feed) of text, SGR, other escapes and lone CRs.
String _genLine(Random rng) {
  final b = StringBuffer();
  for (var i = rng.nextInt(7); i > 0; i--) {
    switch (rng.nextInt(10)) {
      case < 4:
        b.write(_words[rng.nextInt(_words.length)]);
      case < 8:
        b.write(_sgr(_escapes[rng.nextInt(_escapes.length)]));
      default:
        b.write(_other[rng.nextInt(_other.length)]);
    }
  }
  return b.toString();
}

/// Lines joined as a pane read would: CRLF or LF, with or without a final one.
String _joinLines(Random rng, List<String> lines) {
  final b = StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    b.write(lines[i]);
    if (i < lines.length - 1 || rng.nextInt(3) > 0) {
      b.write(rng.nextInt(4) == 0 ? '\n' : '\r\n');
    }
  }
  return b.toString();
}

void main() {
  group('equals a one-shot parse', () {
    test('across related texts, whatever the document holds', () {
      final rng = Random(20260503);
      for (var round = 0; round < 150; round++) {
        final doc = TerminalDocument();
        var lines = [for (var i = 0; i < 1 + rng.nextInt(40); i++) _genLine(rng)];
        for (var step = 0; step < 14; step++) {
          final text = _joinLines(rng, lines);
          doc.update(const [], text);
          expect(
            _dumpDoc(doc),
            _dumpParsed(parseAnsi(text)),
            reason: 'round $round step $step: ${_show(text)}',
          );
          switch (rng.nextInt(7)) {
            case 0:
              lines = [...lines, _genLine(rng)];
            case 1 when lines.isNotEmpty:
              lines = [...lines.take(lines.length - 1), _genLine(rng)];
            case 2 when lines.isNotEmpty:
              lines = [...lines]..[rng.nextInt(lines.length)] = _genLine(rng);
            case 3 when lines.isNotEmpty:
              lines = lines.skip(1 + rng.nextInt(lines.length)).toList();
            case 4:
              // A sliding window: drop from the top, add at the bottom.
              lines = [
                ...lines.skip(min(lines.length, 1 + rng.nextInt(3))),
                _genLine(rng),
                if (rng.nextBool()) _genLine(rng),
              ];
            case 5:
              lines = [for (var i = 0; i < rng.nextInt(30); i++) _genLine(rng)];
            default:
              break; // same text again
          }
        }
      }
    });

    test('with scrollback above the window, as it moves, grows and is trimmed', () {
      final rng = Random(7);
      for (var round = 0; round < 100; round++) {
        final doc = TerminalDocument();
        var history = <String>[];
        var window = [for (var i = 0; i < 1 + rng.nextInt(20); i++) _genLine(rng)];
        for (var step = 0; step < 14; step++) {
          final text = _joinLines(rng, window);
          doc.update(history, text);
          expect(
            _dumpDoc(doc),
            _expected(history, text),
            reason: 'round $round step $step',
          );
          switch (rng.nextInt(5)) {
            case 0: // The window slides: its top rows join the history.
              final k = min(window.length, 1 + rng.nextInt(3));
              history = [...history, ...window.take(k)];
              window = [...window.skip(k), _genLine(rng)];
            case 1: // Older rows are revealed above.
              history = [for (var i = 0; i < 1 + rng.nextInt(4); i++) _genLine(rng), ...history];
            case 2: // The oldest rows are let go.
              history = history.skip(min(history.length, 1 + rng.nextInt(3))).toList();
            case 3:
              window = [...window, _genLine(rng)];
            default:
              break;
          }
        }
      }
    });

    test('empty input has no lines and no width', () {
      final doc = TerminalDocument()..update(const [], '');
      expect(doc.lines, isEmpty);
      expect(doc.columns, 0);
      doc.update(const [], '\n');
      expect(doc.lines, hasLength(1));
      doc.update(const [], _sgr('0'));
      expect(doc.lines, isEmpty, reason: 'an unterminated line that shows nothing');
    });
  });

  group('lines are reused', () {
    test('unchanged lines come back as the same DocLine, runs and all', () {
      final doc = TerminalDocument()..update(const [], 'one\r\n${_sgr('31')}two\r\nthree\r\n');
      final before = [...doc.lines];
      doc.update(const [], 'one\r\n${_sgr('31')}two\r\nthree\r\nfour');
      expect(doc.lines, hasLength(4));
      for (var i = 0; i < 3; i++) {
        expect(doc.lines[i], same(before[i]), reason: 'line $i');
      }
    });

    test('a changed line is parsed again; its neighbours are not', () {
      final doc = TerminalDocument()..update(const [], 'a\nb\nc');
      final before = [...doc.lines];
      doc.update(const [], 'a\nB\nc');
      expect(doc.lines[0], same(before[0]));
      expect(doc.lines[1].runs.single.text, 'B');
      expect(doc.lines[2], same(before[2]));
    });

    test('a line whose start state changed is parsed again, not served stale', () {
      final doc = TerminalDocument()
        ..update(const [], '${_sgr('31')}x\nplain\n${_sgr('0')}z\nq');
      final before = [...doc.lines];
      expect(before[1].runs.single.fg, TerminalColors.ansi[1]);

      // The first line stops colouring what follows it.
      doc.update(const [], 'x\nplain\n${_sgr('0')}z\nq');
      expect(doc.lines[1].runs.single.fg, isNull);
      expect(doc.lines[1], isNot(same(before[1])));
      expect(doc.lines[3], same(before[3]));

      doc.update(const [], '${_sgr('31')}x\nplain\n${_sgr('0')}z\nq');
      expect(doc.lines[1].runs.single.fg, TerminalColors.ansi[1]);
    });

    test('every attribute of the start state is part of the match', () {
      for (final sgr in ['1', '2', '3', '4', '7', '9', '31', '41', '38;5;200', '48;2;1;2;3']) {
        final doc = TerminalDocument()..update(const [], '${_sgr(sgr)}x\nline');
        final styled = doc.lines[1];
        doc.update(const [], 'x\nline');
        expect(doc.lines[1], isNot(same(styled)), reason: sgr);
        expect(_dumpDoc(doc), _dumpParsed(parseAnsi('x\nline')), reason: sgr);
      }
    });

    test('scrollback that has not changed is not parsed again', () {
      final history = [for (var i = 0; i < 5000; i++) '${_sgr('3${i % 8}')}row $i'];
      final doc = TerminalDocument()..update(history, 'live 1\nlive 2');
      final kept = [...doc.lines];
      doc.update(history, 'live 1\nlive 3');
      for (var i = 0; i < history.length; i++) {
        if (!identical(doc.lines[i], kept[i])) fail('row $i was parsed again');
      }
      expect(doc.lines[history.length], same(kept[history.length]));
      expect(doc.lines.last, isNot(same(kept.last)));
    });
  });

  group('where the top moved', () {
    test('lines that fall off the top are counted and ids follow their lines', () {
      final doc = TerminalDocument();
      doc.update(const [], 'a\nb\nc\nd\ne\nf\ng');
      final idOfE = doc.base + 4;
      final shift = doc.update(const [], 'c\nd\ne\nf\ng\nh');
      expect(shift, (dropped: 2, prepended: 0));
      expect(doc.base + 2, idOfE);
      expect(doc.lines[2].runs.single.text, 'e');
    });

    test('lines inserted above are counted and ids follow their lines', () {
      final doc = TerminalDocument();
      doc.update(const [], 'e\nf\ng\nh\ni\nj');
      final first = doc.lines.first;
      final idOfE = doc.base;
      final shift = doc.update(const [], 'a\nb\nc\nd\ne\nf\ng\nh\ni\nj');
      expect(shift, (dropped: 0, prepended: 4));
      expect(doc.base + 4, idOfE);
      expect(doc.lines[4], same(first));
      expect(doc.base, lessThan(idOfE));
    });

    test('history that arrives above the window counts as lines inserted above', () {
      final doc = TerminalDocument()..update(const [], 'e\nf\ng\nh\ni\nj');
      final shift = doc.update(['a', 'b', 'c', 'd'], 'e\nf\ng\nh\ni\nj');
      expect(shift.prepended, 4);
      expect(doc.lines.map((l) => l.runs.single.text), [
        'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j',
      ]);
    });

    test('a slide that moves rows into the history keeps every id', () {
      final doc = TerminalDocument()..update(const [], 'a\nb\nc\nd\ne');
      final ids = {for (var i = 0; i < 5; i++) doc.lines[i].src: doc.base + i};
      final shift = doc.update(['a', 'b'], 'c\nd\ne\nf\ng');
      expect(shift, (dropped: 0, prepended: 0));
      for (final line in doc.lines) {
        final id = ids[line.src];
        if (id != null) expect(doc.base + doc.lines.indexOf(line), id, reason: line.src);
      }
    });

    test('no shared lines: nothing survives, ids are never reused', () {
      final doc = TerminalDocument()..update(const [], 'a\nb\nc');
      final oldIds = {doc.base, doc.base + 1, doc.base + 2};
      final shift = doc.update(const [], 'x\ny\nz\nw');
      expect(shift, (dropped: 0, prepended: 0));
      for (var i = 0; i < 4; i++) {
        expect(oldIds, isNot(contains(doc.base + i)));
      }
    });

    test('a short document that grows keeps its lines', () {
      final doc = TerminalDocument()..update(const [], 'a\nb\nc');
      final before = [...doc.lines];
      final id = doc.base;
      doc.update(const [], 'a\nb\nc\nd');
      expect(doc.base, id);
      expect(doc.lines.take(3), orderedEquals(before));
    });
  });

  group('style does not cross into the window', () {
    test('a colour left open by the last scrolled-off row stops at the window', () {
      final doc = TerminalDocument()
        ..update(['${_sgr('31')}red and never reset'], 'live row\n${_sgr('0')}end');
      expect(doc.lines[0].runs.single.fg, TerminalColors.ansi[1]);
      expect(doc.lines[1].runs.single.fg, isNull, reason: 'the window starts afresh');
    });

    test('style still carries from row to row inside the history and the window', () {
      final doc = TerminalDocument()
        ..update(['${_sgr('31')}one', 'two'], '${_sgr('32')}three\nfour');
      expect(doc.lines[1].runs.single.fg, TerminalColors.ansi[1]);
      expect(doc.lines[3].runs.single.fg, TerminalColors.ansi[2]);
    });

    test('dropping the oldest rows leaves a clean first row', () {
      final doc = TerminalDocument()
        ..update(['${_sgr('31')}red', 'carried'], 'live');
      expect(doc.lines[1].runs.single.fg, TerminalColors.ansi[1]);
      doc.update(['carried'], 'live');
      expect(doc.lines[0].runs.single.fg, isNull);
    });
  });

  group('rows', () {
    test('a line that fits is one row, the very same runs', () {
      final doc = TerminalDocument()..update(const [], 'short');
      final line = doc.lines.single;
      expect(line.rows(0).single, same(line.runs));
      expect(line.rows(10).single, same(line.runs));
      expect(line.rows(10), same(line.rows(80)));
    });

    test('rowCount agrees with the rows actually cut, wide characters included', () {
      final rng = Random(5);
      for (var round = 0; round < 300; round++) {
        final text = [for (var i = 0; i < rng.nextInt(60); i++) _words[rng.nextInt(_words.length)]].join();
        final doc = TerminalDocument()..update(const [], text);
        for (final line in doc.lines) {
          for (final columns in [0, 1, 2, 3, 7, 40]) {
            expect(line.rowCount(columns), line.rows(columns).length, reason: '$columns: $text');
          }
        }
      }
    });

    test('a long line wraps like wrapLine, and the rows are kept per width', () {
      final doc = TerminalDocument()..update(const [], 'abcdefghij');
      final line = doc.lines.single;
      final rows = line.rows(4);
      expect(rows.map((r) => r.single.text), ['abcd', 'efgh', 'ij']);
      expect(line.rows(4), same(rows));
      expect(
        [for (final r in line.rows(3)) r.single.text],
        [for (final r in wrapLine(line.runs, 3)) r.single.text],
      );
      expect(line.rows(4), isNot(same(rows)), reason: 'rebuilt for the new width');
    });
  });

  group('links per row', () {
    test('a link that wraps is split over the rows it covers, in row cells', () {
      final doc = TerminalDocument()..update(const [], 'see https://example.com/a/b/c ok');
      final line = doc.lines.single;
      expect(line.links, hasLength(1));
      final link = line.links.single;
      expect(link.start, 4);

      // Rows of 10 cells: `see https:`, `//example.`, `com/a/b/c `, `ok`.
      final rows = [for (var i = 0; i < line.rows(10).length; i++) line.linksOnRow(i, 10)];
      expect(rows[0].map((l) => (l.start, l.end)), [(4, 10)]);
      expect(rows[1].map((l) => (l.start, l.end)), [(0, 10)]);
      expect(rows[2].map((l) => (l.start, l.end)), [(0, 9)]);
      expect(rows[3], isEmpty);
      for (final row in rows.expand((r) => r)) {
        expect(row.link, same(link));
      }
    });

    test('wide characters before a link shift its cells, not its text', () {
      final doc = TerminalDocument()..update(const [], '日本語 /tmp/x.txt');
      final links = doc.lines.single.linksOnRow(0, 0);
      expect(links.single.start, 7);
      expect(links.single.end, 7 + '/tmp/x.txt'.length);
    });

    test('a line without links has none and does not scan twice', () {
      final doc = TerminalDocument()..update(const [], 'nothing to see here');
      final line = doc.lines.single;
      expect(line.links, isEmpty);
      expect(line.linksOnRow(0, 0), isEmpty);
      expect(line.links, same(line.links));
    });
  });
}
