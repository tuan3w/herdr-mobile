import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/host/host_link.dart' show HostException, HostLinkLost;
import 'package:herdr_mobile/data/observed/observed_contracts.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/ssh_agent_host.dart';
import 'package:herdr_mobile/data/services/ssh_log_source.dart';

import 'support/fake_exec.dart';
import 'support/fake_transport.dart';
import 'support/keeper_harness.dart' show KeeperHost;

const _path = '/home/u/.omp/agent/sessions/--work--/2026-01-01_abc.jsonl';

/// What a listener of [SshLogSource.follow] saw.
class _Run {
  _Run(Stream<LogBatch> stream) {
    sub = stream.listen(batches.add, onError: errors.add, onDone: () => ended = true);
  }

  late final StreamSubscription<LogBatch> sub;
  final batches = <LogBatch>[];
  final errors = <Object>[];
  var ended = false;

  List<String> get lines => [for (final b in batches) ...b.lines];
}

/// A few turns of the event loop, for what must NOT happen (what must happen
/// is waited for with [_until]).
Future<void> _quiet() => Future<void>.delayed(const Duration(milliseconds: 30));

Future<void> _until(bool Function() check, String what, [Duration timeout = const Duration(seconds: 20)]) async {
  final end = DateTime.now().add(timeout);
  while (!check()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Matcher _hostError({bool? fatal, Object? message}) => isA<AgentHostException>()
    .having((e) => e.fatal, 'fatal', fatal ?? anything)
    .having((e) => e.message, 'message', message ?? anything);

Matcher _transportError({bool? fatal, Object? message}) => isA<HerdrTransportException>()
    .having((e) => e.fatal, 'fatal', fatal ?? anything)
    .having((e) => e.message, 'message', message ?? anything);

void main() {
  late FakeTransport transport;
  late SshLogSource source;
  late FakeExecChannel channel;

  /// What each `keeper.*` stream was opened with, in order.
  late List<({String method, Map<String, Object?> args})> opened;

  setUp(() {
    transport = FakeTransport();
    channel = FakeExecChannel();
    opened = [];
    transport.onHostStream = (service, method, args) async {
      expect(service, 'keeper');
      opened.add((method: method, args: args));
      return channel;
    };
    source = SshLogSource(SshAgentHost(transport));
  });

  group('blob', () {
    const hash = '0123456789abcdef';
    final bytes = List<int>.generate(100000, (i) => i % 251);
    final text = base64.encode(bytes);

    List<String> records({int? length, int pieceSize = 60000}) => [
      for (var i = 0; i < text.length; i += pieceSize)
        'B\t${text.substring(i, i + pieceSize > text.length ? text.length : i + pieceSize)}',
      'D\t${length ?? text.length}',
    ];

    test('opens keeper.blob for the path, offset and hash, and decodes what comes back', () async {
      channel = FakeExecChannel.run(stdout: records());

      expect(await source.blob(_path, start: 4096, hash: hash), bytes);
      expect(transport.hostCalls, ['keeper.blob']);
      expect(opened.single.args, {'path': _path, 'start': 4096, 'hash': hash});
      expect(channel.closeCalls, 1, reason: 'the stream is closed once it was read');
    });

    test('a small picture, in one piece, decodes too', () async {
      channel = FakeExecChannel.run(
        stdout: [
          'B\t${base64.encode([1, 2, 3, 4])}',
          'D\t8',
        ],
      );

      expect(await source.blob(_path, start: 0, hash: hash), [1, 2, 3, 4]);
    });

    test('a reply whose length is not the one it announced is incomplete, never a damaged picture', () async {
      channel = FakeExecChannel.run(stdout: records(length: text.length + 4));
      await expectLater(
        source.blob(_path, start: 0, hash: hash),
        throwsA(_hostError(message: 'The picture came back incomplete.')),
      );

      channel = FakeExecChannel.run(stdout: records().sublist(0, 1));
      await expectLater(source.blob(_path, start: 0, hash: hash), throwsA(_hostError(message: contains('incomplete'))));

      channel = FakeExecChannel.run(stdout: ['D\t0']);
      await expectLater(source.blob(_path, start: 0, hash: hash), throwsA(_hostError(message: contains('incomplete'))));
    });

    test('text that is not base64 is not a picture, and trying again cannot help', () async {
      channel = FakeExecChannel.run(stdout: ['B\t!!!!', 'D\t4']);

      await expectLater(
        source.blob(_path, start: 0, hash: hash),
        throwsA(_hostError(fatal: true, message: 'That isn’t a picture.')),
      );
    });

    test('the host’s sentence reaches the person as it is said', () async {
      channel = FakeExecChannel.run(code: 66, stderr: 'That picture is not in the log any more.');

      await expectLater(
        source.blob(_path, start: 0, hash: hash),
        throwsA(_hostError(fatal: true, message: 'That picture is not in the log any more.')),
      );
      expect(channel.closeCalls, 1);
    });

    test('a link that drops mid-way is retryable, even after some pieces', () async {
      channel = FakeExecChannel.run(stdout: records().sublist(0, 1), code: null);

      await expectLater(
        source.blob(_path, start: 0, hash: hash),
        throwsA(_hostError(fatal: false, message: contains('dropped'))),
      );
    });

    test('a path the host refuses or cannot find fails the blob in its words', () async {
      transport.onHostStream = (_, _, _) =>
          Future.error(const HostException('bad_request', 'not a log file in your home folder: /x'));
      await expectLater(
        source.blob('/x', start: 0, hash: hash),
        throwsA(_hostError(fatal: true, message: 'not a log file in your home folder: /x')),
      );

      transport.onHostStream = (_, _, _) => Future.error(const HostException('not_found', 'cannot read /y.jsonl'));
      await expectLater(
        source.blob('/y.jsonl', start: 0, hash: hash),
        throwsA(_hostError(fatal: true, message: 'cannot read /y.jsonl')),
      );

      transport.onHostStream = (_, _, _) => Future.error(const HostLinkLost('serve exited'));
      await expectLater(
        source.blob(_path, start: 0, hash: hash),
        throwsA(_hostError(fatal: false, message: contains('dropped'))),
      );
    });

    test('a path with a control character goes to the host as it is', () async {
      transport.onHostStream = (service, method, args) {
        opened.add((method: method, args: args));
        return Future.error(const HostException('bad_request', 'the path has a control character'));
      };

      await expectLater(
        source.blob('/home/u/a\nb.jsonl', start: 0, hash: hash),
        throwsA(_hostError(fatal: true, message: 'the path has a control character')),
      );
      expect(opened.single.args['path'], '/home/u/a\nb.jsonl');
    });

    test('a host that never ends the reply times out after 90 s, and its stream is closed', () {
      fakeAsync((async) {
        Object? error;
        source.blob(_path, start: 0, hash: hash).then<void>((_) {}, onError: (Object e) => error = e);
        async.elapse(const Duration(seconds: 89));
        expect(error, isNull, reason: 'a picture over a slow link may take its time');
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();

        expect(error, _hostError(fatal: false, message: 'The machine didn’t answer in time (read the picture).'));
        expect(channel.closeCalls, 1);
      });
    });
  });

  group('records', () {
    test('opens keeper.follow for the path, and for the offset, the window and the tail when asked', () async {
      transport.onHostStream = (service, method, args) async {
        opened.add((method: method, args: args));
        return FakeExecChannel();
      };
      _Run(source.follow(_path));
      _Run(source.follow(_path, from: 4096));
      _Run(source.follow(_path, tailBytes: 1 << 20));
      _Run(source.follow(_path, from: 10, until: 500, digest: true));
      await _until(() => opened.length == 4, 'four follows');

      expect(opened.map((o) => o.method), everyElement('follow'));
      expect(transport.hostCalls, everyElement('keeper.follow'));
      expect(opened.map((o) => o.args), [
        {'path': _path},
        {'path': _path, 'from': 4096},
        {'path': _path, 'tail_bytes': 1 << 20},
        {'path': _path, 'from': 10, 'to': 500, 'digest': true},
      ]);
    });

    test('lines that arrive together are one batch, ended by the last offset', () async {
      final run = _Run(source.follow(_path));
      channel
        ..emit('10\t{"a":1}')
        ..emit('25\t{"b":"x"}')
        ..emit('40\t{"c":[1,2]}');
      await _until(() => run.batches.length == 1, 'the first batch');
      channel.emit('52\t{"d":null}');
      await _until(() => run.batches.length == 2, 'the second batch');

      expect(run.batches.map((b) => b.lines), [
        ['{"a":1}', '{"b":"x"}', '{"c":[1,2]}'],
        ['{"d":null}'],
      ]);
      expect(run.batches.map((b) => b.endOffset), [40, 52]);
      expect(run.batches.any((b) => b.reset), isFalse);
      expect(run.errors, isEmpty);
    });

    test('the caught-up record is the only batch of a log with nothing to replay', () async {
      final run = _Run(source.follow(_path, from: 300));
      channel.emit('C\t300');
      await _until(() => run.batches.isNotEmpty, 'the caught-up batch');
      await _quiet();

      expect(run.batches.map((b) => '${b.lines.length} ${b.endOffset} ${b.reset}'), ['0 300 false']);
      expect(run.batches.single.caughtUp, isTrue);
    });

    test('the caught-up record after lines is an empty batch that says so, with where the tail starts', () async {
      final run = _Run(source.follow(_path));
      channel
        ..emit('S\t4')
        ..emit('10\t{"a":1}')
        ..emit('C\t10');
      await _until(() => run.batches.length == 2, 'both batches');

      expect(run.batches.map((b) => '${b.lines.join(' ')} ${b.endOffset} ${b.head} ${b.caughtUp}'), [
        '{"a":1} 10 4 false',
        ' 10 null true',
      ]);
    });

    test('the head rides on the first batch after it, and only that one', () async {
      final run = _Run(source.follow(_path));
      channel
        ..emit('S\t128')
        ..emit('C\t128');
      await _until(() => run.batches.isNotEmpty, 'the caught-up batch');
      channel.emit('140\t{"a":1}');
      await _until(() => run.batches.length == 2, 'the next batch');

      expect(run.batches.map((b) => b.head), [128, null]);
    });

    test('a bounded read ends after its caught-up record, cleanly', () async {
      final run = _Run(source.follow(_path, from: 0, until: 40));
      channel
        ..emit('S\t0')
        ..emit('20\t{"a":1}')
        ..emit('40\t{"b":2}')
        ..emit('C\t40')
        ..exit(0);
      await _until(() => run.ended, 'the end');

      expect(run.lines, ['{"a":1}', '{"b":2}']);
      expect(run.batches.last.caughtUp, isTrue);
      expect(run.errors, isEmpty);
    });

    test('a body is whatever follows the first tab, undecoded', () async {
      final run = _Run(source.follow(_path));
      channel.emit('7\t{"raw":"a\tb"}');
      channel.emit('9\tnot json at all');
      await _until(() => run.lines.length == 2, 'both lines');

      expect(run.lines, ['{"raw":"a\tb"}', 'not json at all']);
    });

    test('a login banner and records that are not ours are skipped', () async {
      final run = _Run(source.follow(_path));
      channel
        ..emit('Welcome to the box')
        ..emit('Last login: today')
        ..emit('\t{"no":"offset"}')
        ..emit('abc\t{"bad":"offset"}')
        ..emit('R\tx')
        ..emit('S\tx')
        ..emit('C\tx')
        ..emit('12 no tab')
        ..emit('5\t{"ok":1}');
      await _until(() => run.batches.isNotEmpty, 'the line that is ours');
      await _quiet();

      expect(run.lines, ['{"ok":1}']);
      expect(run.batches.single.endOffset, 5);
      expect(run.errors, isEmpty);
    });

    test('a burst of 5000 lines is cut into small batches, in order, none lost', () async {
      final run = _Run(source.follow(_path));
      for (var i = 0; i < 5000; i++) {
        channel.emit('${(i + 1) * 10}\t{"n":$i}');
      }
      await _until(() => run.lines.length == 5000, 'all the lines');

      expect(run.batches.every((b) => b.lines.length <= 512), isTrue);
      expect(run.batches.length, greaterThan(5000 ~/ 512));
      expect(run.lines, [for (var i = 0; i < 5000; i++) '{"n":$i}']);
      expect(run.batches.last.endOffset, 50000);
    });

    test('a huge line passes through whole', () async {
      final run = _Run(source.follow(_path));
      final big = '{"t":"${'x' * (4 * 1024 * 1024)}"}';
      channel.emit('${big.length + 1}\t$big');
      await _until(() => run.lines.isNotEmpty, 'the 4 MB line');

      expect(run.lines.single, big);
    });

    test('nothing at all is not an error: no batch, still open', () async {
      final run = _Run(source.follow(_path));
      await _until(() => opened.isNotEmpty, 'the stream to open');
      await _quiet();

      expect(run.batches, isEmpty);
      expect(run.ended, isFalse);
      expect(run.errors, isEmpty);
    });
  });

  group('reset', () {
    test(
      'lines before the marker are delivered first; the marker is an empty reset batch; then the new content',
      () async {
        final run = _Run(source.follow(_path));
        channel
          ..emit('10\t{"old":1}')
          ..emit('R\t0')
          ..emit('8\t{"new":1}')
          ..emit('16\t{"new":2}');
        await _until(() => run.batches.length == 3, 'the three batches');

        expect(run.batches.map((b) => '${b.reset} ${b.lines.join(' ')} ${b.endOffset}'), [
          'false {"old":1} 10',
          'true  0',
          'false {"new":1} {"new":2} 16',
        ]);
      },
    );

    test('two resets in a row are two markers', () async {
      final run = _Run(source.follow(_path));
      channel
        ..emit('R\t0')
        ..emit('R\t300');
      await _until(() => run.batches.length == 2, 'both markers');

      expect(run.batches.map((b) => '${b.reset} ${b.endOffset}'), ['true 0', 'true 300']);
    });

    test('a reset carries where the tail that follows it begins', () async {
      final run = _Run(source.follow(_path));
      channel
        ..emit('S\t64')
        ..emit('R\t0');
      await _until(() => run.batches.isNotEmpty, 'the marker');

      expect(run.batches.single.reset, isTrue);
      expect(run.batches.single.head, 64);
    });
  });

  group('failures', () {
    test('E is a failure in the host’s words, after the lines before it, and ends the stream', () async {
      final run = _Run(source.follow(_path));
      channel
        ..emit('10\t{"a":1}')
        ..emit('E\tInput/output error');
      await _until(() => run.ended, 'the end');

      expect(run.lines, ['{"a":1}']);
      expect(run.errors.single, _hostError(fatal: false, message: 'Input/output error'));
      expect(channel.closeCalls, greaterThan(0));
    });

    test('E without words says the log could not be read', () async {
      final run = _Run(source.follow(_path));
      channel.emit('E\t');
      await _until(() => run.ended, 'the end');

      expect(run.errors.single, _hostError(fatal: false, message: contains('couldn’t read')));
    });

    // The host ends a stream with the keeper's exit status for its error code:
    // 0 ok, 64 bad_request, 66 not_found, 67 agent_exited, 69 agent_missing, 70 failed.
    final endings = <(int, String, bool, Object)>[
      (64, 'the path is not absolute', true, 'the path is not absolute'),
      (65, '', false, 'The machine couldn’t set up agent sessions.'),
      (66, 'not a log file in your home folder: /x.jsonl', true, contains('home folder')),
      (67, 'agent exited', true, 'agent exited'),
      (69, '', true, contains('installed')),
      (70, 'reading failed', false, 'reading failed'),
      (5, '', false, 'Couldn’t follow the session (exit status 5).'),
    ];
    for (final (code, stderr, fatal, message) in endings) {
      test(
        'a stream that ends with status $code is an AgentHostException (fatal: $fatal) in the host’s words',
        () async {
          final run = _Run(source.follow(_path));
          channel
            ..emit('10\t{"a":1}')
            ..exit(code, stderr: stderr);
          await _until(() => run.ended, 'the end');

          expect(run.lines, ['{"a":1}'], reason: 'what arrived before the end is delivered first');
          expect(run.errors.single, _hostError(fatal: fatal, message: message));
          expect(channel.closeCalls, greaterThan(0));
        },
      );
    }

    test('a link that drops is a retryable transport error, after the lines that did arrive', () async {
      final run = _Run(source.follow(_path));
      channel
        ..emit('10\t{"a":1}')
        ..exit(null);
      await _until(() => run.ended, 'the end');

      expect(run.lines, ['{"a":1}']);
      expect(run.errors.single, _transportError(fatal: false, message: contains('dropped')));
    });

    test('a stream error from the channel is a retryable transport error', () async {
      final run = _Run(source.follow(_path));
      await _until(() => opened.isNotEmpty, 'the stream to open');
      channel.emitError(StateError('worker died'));
      await _until(() => run.ended, 'the end');

      expect(run.errors.single, _transportError(fatal: false));
    });

    test('exit 0 ends the stream cleanly', () async {
      final run = _Run(source.follow(_path));
      channel
        ..emit('3\t{"a":1}')
        ..exit(0);
      await _until(() => run.ended, 'the end');

      expect(run.lines, ['{"a":1}']);
      expect(run.errors, isEmpty);
    });

    // A stream the host would not open: what the person can fix by waiting
    // (the link, the helper) is a retryable HerdrTransportException; what the
    // host cannot do at all stays an AgentHostException, fatal.
    final refusals = <(String, Object, Matcher)>[
      (
        'bad_request',
        const HostException('bad_request', 'not a log file in your home folder: /x'),
        _hostError(fatal: true, message: 'not a log file in your home folder: /x'),
      ),
      (
        'not_found',
        const HostException('not_found', 'cannot read /x.jsonl'),
        _hostError(fatal: true, message: 'cannot read /x.jsonl'),
      ),
      (
        'agent_missing',
        const HostException('agent_missing', ''),
        _hostError(fatal: true, message: contains('installed')),
      ),
      ('agent_exited', const HostException('agent_exited', ''), _hostError(fatal: true, message: contains('exited'))),
      (
        'failed',
        const HostException('failed', 'reading failed'),
        _transportError(fatal: false, message: 'reading failed'),
      ),
      (
        'unavailable',
        const HostException('unavailable', 'no helper'),
        _transportError(fatal: false, message: 'The machine couldn’t set up agent sessions.'),
      ),
      (
        'install_failed',
        const HostException('install_failed', 'No space left on device'),
        _transportError(fatal: false, message: 'No space left on device'),
      ),
      ('timeout', const HostException('timeout', 'slow'), _transportError(fatal: false, message: contains('in time'))),
      ('link_lost', const HostLinkLost('serve exited'), _transportError(fatal: false, message: contains('dropped'))),
      (
        'a connection that cannot be opened',
        const HerdrTransportException('Cannot connect'),
        _transportError(fatal: false, message: 'Cannot connect'),
      ),
      (
        'a connection that cannot be opened for good',
        const HerdrTransportException('Host key changed', fatal: true),
        _hostError(fatal: true, message: 'Host key changed'),
      ),
    ];
    for (final (name, error, matcher) in refusals) {
      test('a stream refused as $name reaches the listener as the right error, and ends it', () async {
        transport.onHostStream = (_, _, _) => Future.error(error);
        final run = _Run(source.follow(_path));
        await _until(() => run.ended, 'the end');

        expect(run.errors.single, matcher);
        expect(run.batches, isEmpty);
      });
    }

    test('a machine with no helper link at all is a retryable transport error', () async {
      transport.onHostStream = null;
      final run = _Run(source.follow(_path));
      await _until(() => run.ended, 'the end');

      expect(run.errors.single, _transportError(fatal: false, message: 'The machine couldn’t set up agent sessions.'));
    });

    test('a path with a control character is sent to the host as it is; the host’s refusal is fatal', () async {
      transport.onHostStream = (service, method, args) {
        opened.add((method: method, args: args));
        return Future.error(const HostException('bad_request', 'the path has a control character'));
      };
      final run = _Run(source.follow('/home/u/a\nb.jsonl'));
      await _until(() => run.ended, 'the end');

      expect(opened.single.args['path'], '/home/u/a\nb.jsonl');
      expect(run.errors.single, _hostError(fatal: true, message: 'the path has a control character'));
    });
  });

  group('cancelling', () {
    test('closes the channel and delivers nothing more', () async {
      final run = _Run(source.follow(_path));
      channel.emit('3\t{"a":1}');
      await _until(() => run.lines.length == 1, 'the line');

      await run.sub.cancel();
      expect(channel.closeCalls, greaterThan(0));
      channel.emit('9\t{"late":1}');
      await _quiet();

      expect(run.lines, ['{"a":1}']);
      expect(run.errors, isEmpty);
    });

    test('cancelling before the stream is open still closes it when it arrives', () async {
      final opening = Completer<ExecChannel>();
      transport.onHostStream = (_, _, _) => opening.future;
      final run = _Run(source.follow(_path));
      await _until(() => transport.hostCalls.isNotEmpty, 'the stream to be asked for');
      await run.sub.cancel();
      opening.complete(channel);
      await _until(() => channel.closeCalls > 0, 'the stream to be closed');

      expect(run.batches, isEmpty);
    });

    test('a paused listener holds the channel back, and gets everything on resume', () async {
      final run = _Run(source.follow(_path));
      await _until(() => opened.isNotEmpty, 'the stream to open');
      run.sub.pause();
      channel
        ..emit('3\t{"a":1}')
        ..emit('6\t{"a":2}');
      await _quiet();
      expect(run.batches, isEmpty);

      run.sub.resume();
      await _until(() => run.lines.length == 2, 'both lines');

      expect(run.lines, ['{"a":1}', '{"a":2}']);
    });
  });

  group('against the real helper on this machine', () {
    late KeeperHost host;
    late SshLogSource local;

    setUp(() async {
      host = await KeeperHost.create({});
      addTearDown(host.dispose);
      await host.install();
      local = SshLogSource(host.agentHost);
    });

    File log(List<String> lines) =>
        File('${host.home.path}/s.jsonl')..writeAsStringSync(lines.map((l) => '$l\n').join());

    test('gives the tail, then new lines, and resumes from an offset', () async {
      final f = log(['{"n":1}', '{"n":2}']);
      final run = _Run(local.follow(f.path));
      await _until(() => run.lines.length == 2, 'the tail');
      expect(run.lines, ['{"n":1}', '{"n":2}']);
      expect(run.batches.last.endOffset, f.lengthSync());

      f.writeAsStringSync('{"n":3}\n', mode: FileMode.append, flush: true);
      // How soon a line arrives (the poll) is the host's business; here only
      // that it arrives, however slow the machine.
      await _until(() => run.lines.length == 3, 'the appended line');
      expect(run.lines.last, '{"n":3}');
      final end = run.batches.last.endOffset;
      expect(end, f.lengthSync());
      await run.sub.cancel();

      final resumed = _Run(local.follow(f.path, from: end));
      // The helper's first batch says the phone is up to date; waiting for it, not a time, keeps this off the clock.
      await _until(() => resumed.batches.isNotEmpty, 'the up-to-date note');
      expect(resumed.lines, isEmpty, reason: 'nothing is replayed');
      expect(resumed.batches.single.endOffset, end, reason: 'the helper says the phone is up to date at once');
      f.writeAsStringSync('{"n":4}\n', mode: FileMode.append, flush: true);
      await _until(() => resumed.lines.length == 1, 'the line after the offset');
      expect(resumed.lines, ['{"n":4}']);
      await resumed.sub.cancel();
    });

    test('never ships more than 16 KB per field, and a truncation is a reset', () async {
      final f = log([
        jsonEncode({
          'text': 'x' * 200000,
          'image': {'type': 'image', 'data': 'QUJD' * 50000},
        }),
      ]);
      final run = _Run(local.follow(f.path, from: 0)); // the line is far bigger than the default tail
      await _until(() => run.lines.length == 1, 'the line');
      final line = jsonDecode(run.lines.single) as Map;
      expect((line['text']! as String).length, lessThan(16384 + 40));
      expect((line['image']! as Map)['data']! as String, contains('bytes of data not sent'));
      expect(run.lines.single.length, lessThan(17000));

      f.writeAsStringSync('{"n":9}\n'); // truncates
      await _until(() => run.batches.any((b) => b.reset), 'the reset');
      await _until(() => run.lines.length == 2, 'the new content');
      expect(run.batches.last.endOffset, f.lengthSync());
      await run.sub.cancel();
    });

    test('a file outside the home folder is refused with the host’s words, fatally', () async {
      final far = File('${Directory.systemTemp.path}/log_source_far_${DateTime.now().microsecondsSinceEpoch}.jsonl')
        ..writeAsStringSync('{}\n');
      addTearDown(far.deleteSync);
      final run = _Run(local.follow(far.path));
      await _until(() => run.ended, 'the end');

      expect(run.errors.single, _hostError(fatal: true, message: contains('home folder')));
    });

    test('cancelling frees the stream on the host', () async {
      final f = log(['{"n":1}']);
      final run = _Run(local.follow(f.path));
      await _until(() => run.lines.length == 1, 'the tail');
      await run.sub.cancel();
      // The stream is reset: a follow of the same file is served at once on the same link.
      final again = _Run(local.follow(f.path));
      await _until(() => again.lines.length == 1, 'a new follow');
      await again.sub.cancel();
    });
  });
}
