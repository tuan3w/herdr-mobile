// What `keeper attach --z` looks like to whoever reads the channel: plain
// lines, whatever the transport did on the way. The inflating happens where
// the transport decodes the network (its worker isolate), not in the UI.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/zipped_lines.dart';
import 'package:herdr_mobile/data/services/zipped_exec_channel.dart';

import 'support/fake_exec.dart';

String _piece(RawZLibFilter filter, String text) {
  final data = utf8.encode(text);
  filter.process(data, 0, data.length);
  final out = <int>[];
  while (true) {
    final chunk = filter.processed(flush: true);
    if (chunk == null || chunk.isEmpty) break;
    out.addAll(chunk);
  }
  return 'Z${base64.encode(out)}';
}

void main() {
  test('the lines are plain whichever way the command wrote them; the rest is the channel\'s', () async {
    final inner = FakeExecChannel();
    final zipped = ZippedExecChannel(inner);
    final got = <String>[];
    final done = Completer<void>();
    zipped.lines.listen(got.add, onDone: done.complete);

    final z = RawZLibFilter.deflateFilter(level: 6);
    final big = [for (var i = 0; i < 30; i++) '{"n":$i,"pad":"${'y' * 50}"}'];
    inner
      ..emit('{"id":1}')
      ..emit(_piece(z, '${big.join('\n')}\n'))
      ..emit('{"id":2}');
    zipped.send('{"id":9}');
    expect(inner.sent, ['{"id":9}']);
    inner.exit(0, stderr: 'bye');
    await done.future;

    expect(got, ['{"id":1}', ...big, '{"id":2}']);
    expect(await zipped.exitCode, 0);
    expect(zipped.stderrTail, 'bye');
  });

  test('a piece that does not inflate ends the lines with an error and closes the command', () async {
    final inner = FakeExecChannel();
    final zipped = ZippedExecChannel(inner);
    final events = <Object>[];
    final done = Completer<void>();
    zipped.lines.listen(events.add, onError: events.add, onDone: done.complete);

    inner
      ..emit('{"id":1}')
      ..emit('Z${base64.encode([9, 9, 9, 9])}')
      ..emit('{"id":2}');
    await done.future;

    expect(events.first, '{"id":1}');
    expect(events[1], isA<CorruptZippedLines>());
    expect(events, hasLength(2), reason: 'nothing after it is read');
    expect(inner.closeCalls, 1, reason: 'the command would run on, and its exit status never come');
    expect(await zipped.exitCode, isNull, reason: 'a killed command has no status: the caller attaches again');
  });

  test('another error of the stream passes through and leaves the command alone', () async {
    final inner = FakeExecChannel();
    final zipped = ZippedExecChannel(inner);
    final events = <Object>[];
    zipped.lines.listen(events.add, onError: events.add);
    inner.emitError(const FormatException('line too long'));
    await Future<void>.delayed(Duration.zero);
    expect(events.single, isA<FormatException>());
    expect(inner.closeCalls, 0);
  });
}
