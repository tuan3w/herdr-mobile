import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/isolate_transport.dart';

import 'support/fake_exec.dart';

/// A remote command that answers every line it is sent.
class _Echo extends FakeExecChannel {
  @override
  void send(String line) {
    super.send(line);
    if (!ended) emit('echo:$line');
  }
}

/// A command whose arrival of input kills the whole worker isolate.
class _Fatal extends FakeExecChannel {
  @override
  void send(String line) => Isolate.exit();
}

/// A command that reads its input to the end, then answers with it.
class _Reader extends FakeExecChannel {
  _Reader() {
    onInputClosed = () {
      emit('got:${sent.join(',')}');
      exit(0);
    };
  }
}

/// Runs inside the worker isolate; the command text picks the behaviour.
class _ExecProbe implements HerdrTransport {
  final channels = <FakeExecChannel>[];
  var closed = false;

  @override
  Future<ExecChannel> openExec(String command, {bool zipped = false}) async {
    final parts = command.split(':');
    final FakeExecChannel channel;
    switch (parts[0]) {
      case 'burst':
        channel = FakeExecChannel.run(
          stdout: [for (var i = 0; i < int.parse(parts[1]); i++) 'line-$i'],
        );
      case 'wide':
        channel = FakeExecChannel.run(stdout: [
          for (var i = 0; i < int.parse(parts[1]); i++) '$i:'.padRight(1000, 'w'),
        ]);
      case 'ticker':
        // Lines from a timer, so two channels really are live at once.
        channel = FakeExecChannel();
        var i = 0;
        Timer.periodic(const Duration(milliseconds: 1), (timer) {
          if (channel.ended) {
            timer.cancel();
          } else if (i == 300) {
            channel.exit(0);
            timer.cancel();
          } else {
            channel.emit('${parts[1]}-${i++}');
          }
        });
      case 'zipflag':
        // What the worker was asked for: the transport inflates there, so the
        // flag has to arrive.
        channel = FakeExecChannel.run(stdout: ['zipped=$zipped']);
      case 'echo':
        channel = _Echo();
      case 'reader':
        channel = _Reader();
      case 'fatal':
        channel = _Fatal();
      case 'failing':
        channel = FakeExecChannel.run(stdout: ['partial'], code: 3, stderr: 'boom: no such folder');
      case 'refuse':
        throw const HerdrTransportException('no free channel', fatal: true);
      default:
        channel = FakeExecChannel(); // idle until closed
    }
    channels.add(channel);
    return channel;
  }

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async =>
      {
        'closed': closed,
        'closeCalls': [for (final c in channels) c.closeCalls],
      };

  @override
  Future<void> close() async => closed = true;

  @override
  Stream<Map<String, dynamic>> events(List<Map<String, dynamic>> subscriptions) =>
      throw UnsupportedError('events');

  @override
  void setBackground(bool background) {}

  @override
  void reset() {}

  @override
  bool get supportsFiles => false;

  @override
  Future<RemoteStat> statFile(String path) => throw UnsupportedError('files');

  @override
  Future<List<RemoteEntry>> listDirectory(String path) => throw UnsupportedError('files');

  @override
  Future<Uint8List> readFile(String path, {int offset = 0, int length = remoteReadCap}) =>
      throw UnsupportedError('files');

  @override
  Future<String> realPath(String path) => throw UnsupportedError('files');

  @override
  Future<void> makeDirs(String path) => throw UnsupportedError('files');

  @override
  Future<void> removeFile(String path) => throw UnsupportedError('files');

  @override
  UploadJob uploadFile({
    required String localPath,
    required String remotePath,
    void Function(int sent, int total)? onProgress,
  }) => throw UnsupportedError('files');
}

HerdrTransport _build(
  Object? config,
  void Function(String) onPin,
  void Function(String) onNotice,
) =>
    _ExecProbe();

/// What a channel delivered until it ended.
class _Drained {
  final lines = <String>[];
  final errors = <Object>[];
}

Future<_Drained> _drain(ExecChannel channel) {
  final out = _Drained();
  final done = Completer<_Drained>();
  channel.lines.listen(
    out.lines.add,
    onError: out.errors.add,
    onDone: () => done.complete(out),
  );
  return done.future.timeout(const Duration(seconds: 10));
}

void main() {
  late IsolateTransport t;
  setUp(() => t = IsolateTransport(builder: _build, config: () => null, onPin: (_) {}));
  tearDown(() => t.close());

  Future<Map<String, dynamic>> probe() => t.request('probe');

  test('whether the lines are zipped reaches the worker, where the transport reads them back', () async {
    expect((await _drain(await t.openExec('zipflag'))).lines, ['zipped=false']);
    expect((await _drain(await t.openExec('zipflag', zipped: true))).lines, ['zipped=true']);
  });

  test('a burst arrives whole, in order, in a handful of messages', () async {
    final channel = await t.openExec('burst:6000');

    final got = await _drain(channel);

    expect(got.lines, [for (var i = 0; i < 6000; i++) 'line-$i']);
    expect(got.errors, isEmpty);
    expect(await channel.exitCode, 0);
    // 256 lines per batch at most: 6000 lines are 24 batches, not 6000 messages.
    expect(t.execBatchesReceived, inInclusiveRange(24, 40));
  });

  test('a batch is also cut by size, so long lines do not make one huge message', () async {
    final channel = await t.openExec('wide:300');

    final got = await _drain(channel);

    expect(got.lines, hasLength(300));
    expect(got.lines.every((l) => l.length == 1000), isTrue);
    expect(got.lines.first.startsWith('0:'), isTrue);
    expect(got.lines.last.startsWith('299:'), isTrue);
    // 48 KB per batch is 48 of these lines: 300 lines are 7 batches (the line
    // limit alone would have made 2).
    expect(t.execBatchesReceived, inInclusiveRange(6, 12));
  });

  test('lines that arrive before anyone listens are kept', () async {
    final channel = await t.openExec('burst:50');
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final got = await _drain(channel);

    expect(got.lines.length, 50);
    expect(got.lines.first, 'line-0');
    expect(got.lines.last, 'line-49');
  });

  test('a lone line is not held back waiting for a full batch', () async {
    final channel = await t.openExec('echo');
    final first = channel.lines.first;

    channel.send('ping');

    expect(await first.timeout(const Duration(seconds: 2)), 'echo:ping');
  });

  test('what is sent reaches the remote command, in order', () async {
    final channel = await t.openExec('echo');
    final got = <String>[];
    channel.lines.listen(got.add);

    for (final line in ['{"a":1}', 'second', 'third']) {
      channel.send(line);
    }
    while (got.length < 3) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(got, ['echo:{"a":1}', 'echo:second', 'echo:third']);
  });

  test('the channel ends when the remote command does, with its status and stderr', () async {
    final channel = await t.openExec('failing');

    final got = await _drain(channel);

    expect(got.lines, ['partial']);
    expect(got.errors, isEmpty);
    expect(await channel.exitCode, 3);
    expect(channel.stderrTail, 'boom: no such folder');
  });

  test('a channel that cannot be opened keeps the error and its fatal flag', () async {
    await expectLater(
      t.openExec('refuse'),
      throwsA(isA<HerdrTransportException>()
          .having((e) => e.fatal, 'fatal', isTrue)
          .having((e) => e.message, 'message', 'no free channel')),
    );
  });

  test('when the worker dies the channel ends with a retryable error, and a new one works', () async {
    final channel = await t.openExec('fatal');
    final idle = await t.openExec('idle');
    final dead = _drain(channel);
    final deadIdle = _drain(idle);

    channel.send('anything');

    for (final got in [await dead, await deadIdle]) {
      expect(got.errors, hasLength(1));
      expect(got.errors.single, isA<HerdrTransportException>().having((e) => e.fatal, 'fatal', isFalse));
    }
    expect(await channel.exitCode, isNull);
    expect(await idle.exitCode, isNull);
    // Sending to a channel whose worker is gone is not an error the caller can act on.
    channel.send('late');

    final again = await t.openExec('echo');
    final reply = again.lines.first;
    again.send('hi');
    expect(await reply.timeout(const Duration(seconds: 5)), 'echo:hi');
  });

  test('opening on a dead worker retries on a fresh one, not an error', () async {
    final channel = await t.openExec('fatal');
    final dead = _drain(channel);
    channel.send('x');
    await dead;

    final next = await t.openExec('burst:3');

    expect((await _drain(next)).lines, ['line-0', 'line-1', 'line-2']);
  });

  test('closeInput delivers what was sent, then the command answers; the channel stays open', () async {
    final channel = await t.openExec('reader');
    final answer = <String>[];
    final drained = Completer<void>();
    channel.lines.listen(answer.add, onDone: drained.complete);

    channel.send('first');
    channel.send('second');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(answer, isEmpty, reason: 'the command waits for the end of its input');

    await channel.closeInput();
    await channel.closeInput();
    await drained.future.timeout(const Duration(seconds: 5));

    expect(answer, ['got:first,second']);
    expect(await channel.exitCode, 0);
    expect(() => channel.send('late'), throwsStateError);
  });

  test('close is idempotent, ends the stream, and leaves the transport running', () async {
    final channel = await t.openExec('idle');
    final drained = _drain(channel);

    await Future.wait([channel.close(), channel.close()]);
    await channel.close();

    final got = await drained;
    expect(got.errors, isEmpty, reason: 'closing is not a failure');
    expect(() => channel.send('x'), throwsStateError);
    final state = await probe();
    expect(state['closed'], isFalse, reason: 'the connection is not closed');
    expect(state['closeCalls'], [1], reason: 'the remote command was closed once');
    final other = await t.openExec('burst:2');
    expect((await _drain(other)).lines, ['line-0', 'line-1']);
  });

  test('closing one channel leaves another untouched', () async {
    final a = await t.openExec('echo');
    final b = await t.openExec('echo');
    final fromB = <String>[];
    b.lines.listen(fromB.add);

    await a.close();
    b.send('still here');
    while (fromB.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(fromB, ['echo:still here']);
    expect((await probe())['closeCalls'], [1, 0]);
  });

  test('closing the transport ends open channels without an error', () async {
    final channel = await t.openExec('idle');
    final drained = _drain(channel);

    await t.close();

    final got = await drained;
    expect(got.errors, isEmpty);
    expect(await channel.exitCode.timeout(const Duration(seconds: 5)), isNull);
  });

  test('two channels do not see each other\'s lines', () async {
    final a = await t.openExec('ticker:A');
    final b = await t.openExec('ticker:B');

    final results = await Future.wait([_drain(a), _drain(b)]);

    expect(results[0].lines, [for (var i = 0; i < 300; i++) 'A-$i']);
    expect(results[1].lines, [for (var i = 0; i < 300; i++) 'B-$i']);
  });

  test('sends go to their own channel', () async {
    final a = await t.openExec('echo');
    final b = await t.openExec('echo');
    final fromA = <String>[];
    final fromB = <String>[];
    a.lines.listen(fromA.add);
    b.lines.listen(fromB.add);

    for (var i = 0; i < 20; i++) {
      a.send('a$i');
      b.send('b$i');
    }
    while (fromA.length < 20 || fromB.length < 20) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(fromA, [for (var i = 0; i < 20; i++) 'echo:a$i']);
    expect(fromB, [for (var i = 0; i < 20; i++) 'echo:b$i']);
  });
}
