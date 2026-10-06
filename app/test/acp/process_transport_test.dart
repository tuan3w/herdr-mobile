import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/process_transport.dart';

void main() {
  final posix = Platform.isLinux || Platform.isMacOS;

  test('lines go to the child and come back, and EOF ends the child', () async {
    final t = await ProcessTransport.start('cat', const []);
    final got = <String>[];
    final done = Completer<void>();
    t.lines.listen(got.add, onDone: done.complete);
    t.send('{"a":1}');
    t.send('{"b":"é"}');
    await t.close();
    await done.future.timeout(const Duration(seconds: 5));
    expect(got, ['{"a":1}', '{"b":"é"}']);
    expect(await t.exitCode, 0);
    expect(() => t.send('x'), throwsStateError);
  }, skip: posix ? null : 'needs cat');

  test('stderr is drained and kept as a tail', () async {
    final t = await ProcessTransport.start('sh', ['-c', 'echo oops 1>&2; cat']);
    t.lines.listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await t.close();
    expect(t.stderrTail, contains('oops'));
  }, skip: posix ? null : 'needs sh');

  test('close() stops a child that ignores EOF after the grace period', () async {
    final t = await ProcessTransport.start('sh', ['-c', 'sleep 30']);
    t.lines.listen((_) {});
    final watch = Stopwatch()..start();
    await t.close(grace: const Duration(milliseconds: 100));
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    expect(await t.exitCode, isNot(0));
  }, skip: posix ? null : 'needs sh');
}
