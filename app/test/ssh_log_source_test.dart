import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/observed/observed_contracts.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart';
import 'package:herdr_mobile/data/services/ssh_agent_host.dart';
import 'package:herdr_mobile/data/services/ssh_log_source.dart';

import 'support/fake_exec.dart';
import 'support/fake_transport.dart';

const _path = '/home/u/.omp/agent/sessions/--work--/2026-01-01_abc.jsonl';

/// What a listener of [SshLogSource.follow] saw.
class _Run {
  _Run(Stream<LogBatch> stream) {
    sub = stream.listen(
      batches.add,
      onError: errors.add,
      onDone: () => ended = true,
    );
  }

  late final StreamSubscription<LogBatch> sub;
  final batches = <LogBatch>[];
  final errors = <Object>[];
  var ended = false;

  List<String> get lines => [for (final b in batches) ...b.lines];
}

/// Lets the stream machinery (and the host's 50 ms script check) run.
Future<void> settle([int ms = 120]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late FakeTransport transport;
  late SshLogSource source;
  late FakeExecChannel channel;

  setUp(() {
    transport = FakeTransport();
    channel = FakeExecChannel();
    transport.onExec = (command) async => channel;
    source = SshLogSource(SshAgentHost(transport, attachCheck: const Duration(milliseconds: 50)));
  });

  group('records', () {
    test('opens the follow command for the path, and for the offset when resuming', () async {
      transport.onExec = (command) async => FakeExecChannel();
      _Run(source.follow(_path));
      await settle();
      _Run(source.follow(_path, from: 4096));
      await settle();
      _Run(source.follow(_path, tailBytes: 1 << 20));
      await settle();

      expect(transport.execCommands, [
        keeperFollowCommand(_path),
        keeperFollowCommand(_path, from: 4096),
        keeperFollowCommand(_path, tailBytes: 1 << 20),
      ]);
    });

    test('lines that arrive together are one batch, ended by the last offset', () async {
      final run = _Run(source.follow(_path));
      await settle();
      channel
        ..emit('10\t{"a":1}')
        ..emit('25\t{"b":"x"}')
        ..emit('40\t{"c":[1,2]}');
      await settle();
      channel.emit('52\t{"d":null}');
      await settle();

      expect(run.batches.map((b) => b.lines), [
        ['{"a":1}', '{"b":"x"}', '{"c":[1,2]}'],
        ['{"d":null}'],
      ]);
      expect(run.batches.map((b) => b.endOffset), [40, 52]);
      expect(run.batches.any((b) => b.reset), isFalse);
      expect(run.errors, isEmpty);
    });

    test('a body is whatever follows the first tab, undecoded', () async {
      final run = _Run(source.follow(_path));
      await settle();
      channel.emit('7\t{"raw":"a\tb"}');
      channel.emit('9\tnot json at all');
      await settle();

      expect(run.lines, ['{"raw":"a\tb"}', 'not json at all']);
    });

    test('a login banner and records that are not ours are skipped', () async {
      final run = _Run(source.follow(_path));
      await settle();
      channel
        ..emit('Welcome to the box')
        ..emit('Last login: today')
        ..emit('\t{"no":"offset"}')
        ..emit('abc\t{"bad":"offset"}')
        ..emit('R\tx')
        ..emit('5\t{"ok":1}')
        ..emit('12 no tab');
      await settle();

      expect(run.lines, ['{"ok":1}']);
      expect(run.batches.single.endOffset, 5);
      expect(run.errors, isEmpty);
    });

    test('a burst of 5000 lines is cut into small batches, in order, none lost', () async {
      final run = _Run(source.follow(_path));
      await settle();
      for (var i = 0; i < 5000; i++) {
        channel.emit('${(i + 1) * 10}\t{"n":$i}');
      }
      await settle(300);

      expect(run.batches.every((b) => b.lines.length <= 512), isTrue);
      expect(run.batches.length, greaterThan(5000 ~/ 512));
      expect(run.lines, [for (var i = 0; i < 5000; i++) '{"n":$i}']);
      expect(run.batches.last.endOffset, 50000);
    });

    test('a huge line passes through whole', () async {
      final run = _Run(source.follow(_path));
      await settle();
      final big = '{"t":"${'x' * (4 * 1024 * 1024)}"}';
      channel.emit('${big.length + 1}\t$big');
      await settle();

      expect(run.lines.single, big);
    });

    test('nothing at all is not an error: no batch, still open', () async {
      final run = _Run(source.follow(_path));
      await settle();

      expect(run.batches, isEmpty);
      expect(run.ended, isFalse);
      expect(run.errors, isEmpty);
    });
  });

  group('reset', () {
    test('lines before the marker are delivered first; the marker is an empty reset batch; then the new content', () async {
      final run = _Run(source.follow(_path));
      await settle();
      channel
        ..emit('10\t{"old":1}')
        ..emit('R\t0')
        ..emit('8\t{"new":1}')
        ..emit('16\t{"new":2}');
      await settle();

      expect(run.batches.map((b) => '${b.reset} ${b.lines.join(' ')} ${b.endOffset}'), [
        'false {"old":1} 10',
        'true  0',
        'false {"new":1} {"new":2} 16',
      ]);
    });

    test('two resets in a row are two markers', () async {
      final run = _Run(source.follow(_path));
      await settle();
      channel
        ..emit('R\t0')
        ..emit('R\t300');
      await settle();

      expect(run.batches.map((b) => '${b.reset} ${b.endOffset}'), ['true 0', 'true 300']);
    });
  });

  group('failures', () {
    test('E is a failure in the host\'s words, after the lines before it, and ends the stream', () async {
      final run = _Run(source.follow(_path));
      await settle();
      channel
        ..emit('10\t{"a":1}')
        ..emit('E\tInput/output error');
      await settle();

      expect(run.lines, ['{"a":1}']);
      expect(run.errors, hasLength(1));
      expect(run.errors.single, isA<AgentHostException>().having((e) => e.message, 'message', 'Input/output error').having((e) => e.fatal, 'fatal', isFalse));
      expect(run.ended, isTrue);
      expect(channel.closeCalls, greaterThan(0));
    });

    test('exit 66 (not a log of this user) is fatal and says what the host said', () async {
      final run = _Run(source.follow(_path));
      await settle();
      channel.exit(66, stderr: 'herdr-mobile: not a log file in your home folder: /x.jsonl');
      await settle();

      expect(run.errors.single, isA<AgentHostException>()
          .having((e) => e.fatal, 'fatal', isTrue)
          .having((e) => e.message, 'message', contains('home folder')));
      expect(run.ended, isTrue);
    });

    test('a host without python3 is fatal', () async {
      transport.onExec = (_) async => FakeExecChannel.run(code: 78, stderr: 'herdr-mobile: agent sessions need python3 on this host');
      final run = _Run(source.follow(_path));
      await settle();

      expect(run.errors.single, isA<AgentHostException>().having((e) => e.fatal, 'fatal', isTrue).having((e) => e.message, 'message', contains('python3')));
    });

    test('a link that drops is a retryable transport error, after the lines that did arrive', () async {
      final run = _Run(source.follow(_path));
      await settle();
      channel.emit('10\t{"a":1}');
      channel.exit(null);
      await settle();

      expect(run.lines, ['{"a":1}']);
      expect(run.errors.single, isA<HerdrTransportException>().having((e) => e.fatal, 'fatal', isFalse));
      expect(run.ended, isTrue);
    });

    test('a stream error from the channel is a retryable transport error', () async {
      final erroring = StreamController<String>();
      transport.onExec = (_) async => _ErroringChannel(erroring.stream);
      final run = _Run(source.follow(_path));
      await settle();
      erroring.addError(StateError('worker died'));
      await settle();

      expect(run.errors.single, isA<HerdrTransportException>());
      expect(run.ended, isTrue);
    });

    test('exit 0 ends the stream cleanly', () async {
      final run = _Run(source.follow(_path));
      await settle();
      channel.emit('3\t{"a":1}');
      channel.exit(0);
      await settle();

      expect(run.lines, ['{"a":1}']);
      expect(run.errors, isEmpty);
      expect(run.ended, isTrue);
    });

    test('a connection that cannot be opened is a retryable transport error', () async {
      transport.onExec = (_) => Future.error(const HerdrTransportException('Cannot connect'));
      final run = _Run(source.follow(_path));
      await settle();

      expect(run.errors.single, isA<HerdrTransportException>()
          .having((e) => e.message, 'message', 'Cannot connect')
          .having((e) => e.fatal, 'fatal', isFalse));
      expect(run.ended, isTrue);
    });

    test('a connection that cannot be opened for good stays fatal', () async {
      transport.onExec = (_) => Future.error(const HerdrTransportException('Host key changed', fatal: true));
      final run = _Run(source.follow(_path));
      await settle();

      expect(run.errors.single, isA<AgentHostException>().having((e) => e.fatal, 'fatal', isTrue).having((e) => e.message, 'message', 'Host key changed'));
    });

    test('a path that cannot be put on a command line fails at once, fatally, opening nothing', () async {
      final run = _Run(source.follow('/home/u/a\nb.jsonl'));
      await settle();

      expect(run.errors.single, isA<AgentHostException>().having((e) => e.fatal, 'fatal', isTrue));
      expect(run.ended, isTrue);
      expect(transport.execCommands, isEmpty);
    });
  });

  group('cancelling', () {
    test('closes the channel and delivers nothing more', () async {
      final run = _Run(source.follow(_path));
      await settle();
      channel.emit('3\t{"a":1}');
      await settle();

      await run.sub.cancel();
      expect(channel.closeCalls, greaterThan(0));
      channel.emit('9\t{"late":1}');
      await settle();

      expect(run.lines, ['{"a":1}']);
      expect(run.errors, isEmpty);
    });

    test('cancelling before the channel is open still closes it when it arrives', () async {
      final opening = Completer<ExecChannel>();
      transport.onExec = (_) => opening.future;
      final run = _Run(source.follow(_path));
      await settle();
      await run.sub.cancel();
      opening.complete(channel);
      await settle();

      expect(channel.closeCalls, greaterThan(0));
      expect(run.batches, isEmpty);
    });

    test('a paused listener holds the channel back, and gets everything on resume', () async {
      final run = _Run(source.follow(_path));
      await settle();
      run.sub.pause();
      channel
        ..emit('3\t{"a":1}')
        ..emit('6\t{"a":2}');
      await settle();
      expect(run.batches, isEmpty);

      run.sub.resume();
      await settle();

      expect(run.lines, ['{"a":1}', '{"a":2}']);
    });
  });

  group('installing the helper', () {
    final installCommand = keeperInstallCommand();

    /// A host that has the script only after the install command ran.
    late bool there;
    late int installs;
    late FakeExecChannel followChannel;

    void scripted({required bool present}) {
      there = present;
      installs = 0;
      followChannel = FakeExecChannel();
      transport.onExec = (command) async {
        if (command == installCommand) {
          installs++;
          final installer = FakeExecChannel();
          installer.onInputClosed = () {
            there = true;
            installer.emit('{"ok":true}');
            installer.exit(0);
          };
          return installer;
        }
        if (!there) return FakeExecChannel.run(code: 65, stderr: 'herdr-mobile: the keeper is not installed');
        return followChannel;
      };
    }

    test('a host without the helper gets it, then the follow is run again', () async {
      scripted(present: false);
      final run = _Run(source.follow(_path));
      await settle(300);
      followChannel.emit('4\t{"a":1}');
      await settle();

      expect(installs, 1);
      expect(transport.execCommands, [keeperFollowCommand(_path), installCommand, keeperFollowCommand(_path)]);
      expect(run.lines, ['{"a":1}']);
      expect(run.errors, isEmpty);
    });

    test('a host that has it is not asked to install', () async {
      scripted(present: true);
      _Run(source.follow(_path));
      await settle(300);

      expect(installs, 0);
      expect(transport.execCommands, [keeperFollowCommand(_path)]);
    });

    test('a helper that vanished after it was seen is installed again, once', () async {
      scripted(present: true);
      final run = _Run(source.follow(_path));
      await settle(300); // the first channel passed the check: the host is known to have it
      there = false;
      final first = followChannel;
      followChannel = FakeExecChannel();
      first.exit(65, stderr: 'herdr-mobile: the keeper is not installed');
      await settle(400);
      followChannel.emit('4\t{"a":1}');
      await settle();

      expect(installs, 1);
      expect(transport.execCommands, [
        keeperFollowCommand(_path),
        keeperFollowCommand(_path),
        installCommand,
        keeperFollowCommand(_path),
      ]);
      expect(run.lines, ['{"a":1}']);
      expect(run.errors, isEmpty);
    });

    test('a host that cannot install fails the follow fatally', () async {
      transport.onExec = (command) async => command == installCommand
          ? FakeExecChannel.run(code: 78, stderr: 'herdr-mobile: agent sessions need python3 on this host')
          : FakeExecChannel.run(code: 65);
      final run = _Run(source.follow(_path));
      await settle(300);

      expect(run.errors.single, isA<AgentHostException>().having((e) => e.fatal, 'fatal', isTrue).having((e) => e.message, 'message', contains('python3')));
    });
  });

  group('against the real script on this machine', skip: _hasPython ? false : 'python3 is not installed', () {
    late Directory home;
    late SshLogSource local;

    setUp(() {
      home = Directory.systemTemp.createTempSync('log_source_test_');
      final t = FakeTransport();
      t.onExec = (command) async => _ProcessChannel.start(command, home.path);
      // The script is not on this "host" yet: the first follow installs it.
      local = SshLogSource(SshAgentHost(t, attachCheck: const Duration(milliseconds: 300)));
    });
    tearDown(() => home.deleteSync(recursive: true));

    File log(List<String> lines) => File('${home.path}/s.jsonl')..writeAsStringSync(lines.map((l) => '$l\n').join());

    test('gives the tail, then new lines within a second, and resumes from an offset', () async {
      final f = log(['{"n":1}', '{"n":2}']);
      final run = _Run(local.follow(f.path));
      await _until(() => run.lines.length == 2, 'the tail');
      expect(run.lines, ['{"n":1}', '{"n":2}']);
      expect(run.batches.last.endOffset, f.lengthSync());

      final watch = Stopwatch()..start();
      f.writeAsStringSync('{"n":3}\n', mode: FileMode.append, flush: true);
      await _until(() => run.lines.length == 3, 'the appended line', const Duration(seconds: 1));
      expect(run.lines.last, '{"n":3}');
      // ignore: avoid_print
      print('append to batch through the real script: ${watch.elapsedMilliseconds} ms');
      final end = run.batches.last.endOffset;
      expect(end, f.lengthSync());
      await run.sub.cancel();

      final resumed = _Run(local.follow(f.path, from: end));
      await settle(600);
      expect(resumed.batches, isEmpty, reason: 'nothing is replayed');
      f.writeAsStringSync('{"n":4}\n', mode: FileMode.append, flush: true);
      await _until(() => resumed.lines.length == 1, 'the line after the offset', const Duration(seconds: 2));
      expect(resumed.lines, ['{"n":4}']);
      await resumed.sub.cancel();
    });

    test('never ships more than 16 KB per field, and a truncation is a reset', () async {
      final f = log([jsonEncode({'text': 'x' * 200000, 'image': {'type': 'image', 'data': 'QUJD' * 50000}})]);
      final run = _Run(local.follow(f.path, from: 0)); // the line is far bigger than the default tail
      await _until(() => run.lines.length == 1, 'the line');
      final line = jsonDecode(run.lines.single) as Map;
      expect((line['text']! as String).length, lessThan(16384 + 40));
      expect(((line['image']! as Map)['data']! as String), contains('bytes of data not sent'));
      expect(run.lines.single.length, lessThan(17000));

      f.writeAsStringSync('{"n":9}\n'); // truncates
      await _until(() => run.batches.any((b) => b.reset), 'the reset');
      await _until(() => run.lines.length == 2, 'the new content');
      expect(run.batches.last.endOffset, f.lengthSync());
      await run.sub.cancel();
    });

    test('a file outside the home folder is refused with the host\'s words, fatally', () async {
      final far = File('${Directory.systemTemp.path}/log_source_far_${DateTime.now().microsecondsSinceEpoch}.jsonl')..writeAsStringSync('{}\n');
      addTearDown(far.deleteSync);
      final run = _Run(local.follow(far.path));
      await _until(() => run.ended, 'the end');

      expect(run.errors.single, isA<AgentHostException>().having((e) => e.fatal, 'fatal', isTrue).having((e) => e.message, 'message', contains('home folder')));
    });

    test('cancelling ends the process on the host', () async {
      final f = log(['{"n":1}']);
      final run = _Run(local.follow(f.path));
      await _until(() => run.lines.length == 1, 'the tail');
      final pid = _ProcessChannel.last!.pid;
      await run.sub.cancel();
      await _until(() => Process.runSync('kill', ['-0', '$pid']).exitCode != 0, 'the process to be gone', const Duration(seconds: 5));
    });
  });
}

final bool _hasPython = () {
  try {
    return Process.runSync('python3', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}();

Future<void> _until(bool Function() check, String what, [Duration timeout = const Duration(seconds: 10)]) async {
  final end = DateTime.now().add(timeout);
  while (!check()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A command run on this machine the way an SSH server would run it, with
/// [home] as the home folder, as an [ExecChannel].
class _ProcessChannel implements ExecChannel {
  _ProcessChannel._(this._process) {
    lines = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((l) => l.isNotEmpty);
    _process.stderr.transform(utf8.decoder).listen((s) => _stderr = s.length > 2048 ? s.substring(s.length - 2048) : s);
    unawaited(_process.exitCode.then((c) => _exit.complete(c)));
  }

  static _ProcessChannel? last;

  static Future<_ProcessChannel> start(String command, String home) async {
    final p = await Process.start('/bin/sh', ['-c', command],
        environment: {'HOME': home, 'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin'},
        includeParentEnvironment: false,
        workingDirectory: home);
    return last = _ProcessChannel._(p);
  }

  final Process _process;
  final _exit = Completer<int?>();
  var _stderr = '';

  int get pid => _process.pid;

  @override
  late final Stream<String> lines;

  @override
  void send(String line) => _process.stdin.writeln(line);

  @override
  Future<void> closeInput() async {
    try {
      await _process.stdin.close();
    } on Object {
      // already gone
    }
  }

  @override
  Future<int?> get exitCode => _exit.future;

  @override
  String get stderrTail => _stderr;

  @override
  Future<void> close() => closeInput();
}

/// A channel whose output is [lines] and that never exits.
class _ErroringChannel extends FakeExecChannel {
  _ErroringChannel(this._lines);

  final Stream<String> _lines;

  @override
  Stream<String> get lines => _lines;
}
