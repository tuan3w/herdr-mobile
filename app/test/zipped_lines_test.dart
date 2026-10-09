// The lines `keeper attach --z` writes: plain ones pass, `Z` lines are pieces
// of one zlib stream that inflate to whole lines, in order.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/zipped_lines.dart';

/// The pieces a keeper would send: one zlib stream, a sync flush after each.
class _Zipper {
  final _filter = RawZLibFilter.deflateFilter(level: 6);

  String piece(String text) {
    final data = utf8.encode(text);
    _filter.process(data, 0, data.length);
    final out = <int>[];
    while (true) {
      final chunk = _filter.processed(flush: true);
      if (chunk == null || chunk.isEmpty) break;
      out.addAll(chunk);
    }
    return 'Z${base64.encode(out)}';
  }
}

Future<List<String>> _read(Iterable<String> lines) => zippedLines(Stream.fromIterable(lines)).toList();

void main() {
  test('plain lines pass, zipped ones come out as the lines they hold, in order', () async {
    final z = _Zipper();
    final big = List.generate(40, (i) => '{"jsonrpc":"2.0","method":"session/update","params":{"n":$i,"pad":"${'x' * 60}"}}');
    final out = await _read([
      '{"id":1}',
      z.piece('${big.take(20).join('\n')}\n'),
      '{"id":2}',
      z.piece('${big.skip(20).join('\n')}\n'),
      '{"id":3}',
    ]);
    expect(out, ['{"id":1}', ...big.take(20), '{"id":2}', ...big.skip(20), '{"id":3}']);
  });

  test('a multi-byte character cut by the inflater\'s chunk boundary survives', () async {
    // One piece that inflates to far more than the inflater's 64 KiB output
    // chunk, in 3- and 4-byte characters: some character always straddles a
    // boundary, and decoding each chunk alone turned it into U+FFFD.
    final random = Random(7);
    final lines = [
      for (var i = 0; i < 700; i++)
        '{"n":$i,"text":"${String.fromCharCodes([for (var c = 0; c < 120; c++) 0x4E00 + random.nextInt(0x4000)])}😀${String.fromCharCode(0x1F600 + random.nextInt(60))}"}',
    ];
    final text = '${lines.join('\n')}\n';
    expect(utf8.encode(text).length, greaterThan(3 * 65536), reason: 'several inflater chunks');

    final out = await _read([_Zipper().piece(text)]);

    expect(out, lines);
  });

  test('a later piece is read with what the earlier ones taught the stream', () async {
    // The second piece is mostly back-references into the first: it is only
    // readable by an inflater that kept its window, never by one per piece.
    final z = _Zipper();
    final line = '{"a":"${'repeat me ' * 30}"}';
    final first = z.piece('$line\n');
    final second = z.piece('$line\n');
    expect(second.length, lessThan(first.length ~/ 2), reason: 'a window is shared');
    expect(await _read([first, second]), [line, line]);
  });

  test('a message that merely starts like a piece but is JSON is never touched', () async {
    expect(await _read(['{"Z":1}', '{"method":"Z"}']), ['{"Z":1}', '{"method":"Z"}']);
  });

  test('a piece that does not inflate ends the stream with an error and nothing after it is read', () async {
    final z = _Zipper();
    final events = <Object>[];
    final done = Completer<void>();
    zippedLines(Stream.fromIterable(['{"id":1}', 'Z${base64.encode([1, 2, 3, 4])}', '{"id":2}', z.piece('{"id":3}\n')])).listen(
      events.add,
      onError: events.add,
      onDone: done.complete,
    );
    await done.future;
    expect(events.first, '{"id":1}');
    expect(events[1], isA<CorruptZippedLines>());
    expect(events, hasLength(2));
  });

  test('base64 that is not base64 is the same failure', () async {
    final events = <Object>[];
    await zippedLines(Stream.fromIterable(['Z!!!not base64!!!'])).handleError(events.add).toList();
    expect(events.single, isA<CorruptZippedLines>());
  });
}
