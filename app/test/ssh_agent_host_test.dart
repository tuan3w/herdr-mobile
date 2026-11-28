import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/host/host_link.dart' show HostException, HostLinkLost;
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/ssh_agent_host.dart';

import 'support/fake_exec.dart';
import 'support/fake_transport.dart';

Matcher _hostError({bool? fatal, Object? message}) => isA<AgentHostException>()
    .having((e) => e.fatal, 'fatal', fatal ?? anything)
    .having((e) => e.message, 'message', message ?? anything);

/// A call or stream the host was asked for.
typedef _Asked = ({String service, String method, Map<String, Object?> args});

void main() {
  late FakeTransport transport;
  late SshAgentHost host;
  late List<_Asked> asked;
  late List<FakeExecChannel> channels;

  /// Every call answers [make]'s result (or error) and is written to [asked].
  void answerCalls(Future<Object?> Function(String method, Map<String, Object?> args) make) {
    transport.onHostCall = (service, method, args) {
      asked.add((service: service, method: method, args: args));
      return make(method, args);
    };
  }

  void replies(Object? answer) => answerCalls((_, _) async => answer);
  void rejects(Object error) => answerCalls((_, _) => Future<Object?>.error(error));

  /// Every stream opens a channel built by [make] and is written to [asked].
  void answerStreams(FakeExecChannel Function() make) {
    transport.onHostStream = (service, method, args) async {
      asked.add((service: service, method: method, args: args));
      final channel = make();
      channels.add(channel);
      return channel;
    };
  }

  setUp(() {
    transport = FakeTransport();
    asked = [];
    channels = [];
    host = SshAgentHost(
      transport,
      quickTimeout: const Duration(milliseconds: 200),
      startTimeout: const Duration(milliseconds: 400),
    );
  });

  group('available', () {
    test('asks keeper.probe and reads the routes of the answer', () async {
      replies({
        'routes': ['omp', 'claude'],
      });

      expect(await host.available(), {'omp', 'claude'});
      expect(transport.hostCalls, ['keeper.probe']);
      expect(asked.single.args, isEmpty);
    });

    test('a host with no agents is an empty set, not an error', () async {
      replies({'routes': <Object?>[]});

      expect(await host.available(), isEmpty);
    });

    test('an answer of the wrong shape is reported with what came back', () async {
      replies({
        'agents': ['omp'],
      });

      await expectLater(host.available(), throwsA(_hostError(fatal: false, message: contains('agents'))));
    });
  });

  group('list', () {
    test('asks keeper.list and parses every keeper, running and exited', () async {
      replies([
        {
          'id': 'k2',
          'agent': 'claude',
          'cwd': '/home/me/b',
          'state': 'running',
          'started_at': 1700000100000,
          'pid': 77,
          'session_id': 's-1',
          'title': 'Fix tests',
          'pending': 2,
          'last_event_at': 1700000200000,
        },
        {
          'id': 'k1',
          'agent': 'omp',
          'cwd': '/home/me/a',
          'state': 'exited',
          'started_at': 1700000000000,
          'exit_code': 1,
          'exit_reason': 'crashed',
        },
      ]);

      final keepers = await host.list();

      expect(keepers.map((k) => k.id), ['k2', 'k1']);
      expect(keepers[0].state, KeeperState.running);
      expect(keepers[0].pending, 2);
      expect(keepers[0].title, 'Fix tests');
      expect(keepers[0].lastEventAt, DateTime.fromMillisecondsSinceEpoch(1700000200000));
      expect(keepers[1].state, KeeperState.exited);
      expect(keepers[1].exitCode, 1);
      expect(transport.hostCalls, ['keeper.list']);
      expect(asked.single.args, isEmpty);
    });

    test('a row that is no keeper is left out, never hiding the others', () async {
      replies([
        {'agent': 'omp'},
        'junk',
        {'id': 'k1', 'agent': 'omp', 'cwd': '/a', 'state': 'running'},
      ]);

      expect((await host.list()).map((k) => k.id), ['k1']);
    });

    test('no keepers is an empty list', () async {
      replies(<Object?>[]);

      expect(await host.list(), isEmpty);
    });

    test('an object instead of an array is reported', () async {
      replies({'id': 'k1'});

      await expectLater(host.list(), throwsA(_hostError(message: contains('unexpected'))));
    });
  });

  group('start', () {
    test('asks keeper.start with the agent and folder as they are, and returns the keeper', () async {
      replies({
        'id': 'k9',
        'agent': 'codex',
        'cwd': '/home/me/it’s a dir',
        'state': 'running',
        'started_at': 1700000000000,
      });

      final info = await host.start(agent: 'codex', cwd: "/home/me/it’s a dir");

      expect(info.id, 'k9');
      expect(info.cwd, '/home/me/it’s a dir');
      expect(transport.hostCalls, ['keeper.start']);
      expect(asked.single.args, {'agent': 'codex', 'cwd': '/home/me/it’s a dir'});
    });

    test('a folder with a control character goes to the host untouched: the host refuses it', () async {
      rejects(const HostException('bad_request', 'the folder has a control character'));

      await expectLater(
        host.start(agent: 'omp', cwd: 'line\nbreak'),
        throwsA(_hostError(fatal: true, message: 'the folder has a control character')),
      );
      expect(asked.single.args, {'agent': 'omp', 'cwd': 'line\nbreak'});
    });

    test('an answer that names no keeper is reported with what came back', () async {
      replies({'ok': true});
      await expectLater(host.start(agent: 'omp', cwd: '/x'), throwsA(_hostError(message: contains('unexpected'))));

      replies('segmentation fault (core dumped)');
      await expectLater(
        host.start(agent: 'omp', cwd: '/x'),
        throwsA(_hostError(fatal: false, message: contains('segmentation fault'))),
      );
    });

    test('a call that never answers times out', () async {
      answerCalls((_, _) => Completer<Object?>().future);

      await expectLater(
        host.start(agent: 'omp', cwd: '/x'),
        throwsA(_hostError(fatal: false, message: 'The machine didn’t answer in time (start the agent).')),
      );
    });

    test('the default start timeout outlasts the keeper’s own initialize timeout', () {
      // The phone runs the Rust keeper (herdr-host); its initialize timeout is
      // INIT_TIMEOUT in records.rs. The test reads the source so the Dart
      // constant in ssh_agent_host.dart cannot drift from it.
      final source = File('${Directory.current.path}/../rust/crates/keeper/src/records.rs').readAsStringSync();
      final keeperSeconds = int.parse(
        RegExp(r'INIT_TIMEOUT: Duration = Duration::from_secs\((\d+)\)').firstMatch(source)!.group(1)!,
      );

      expect(
        keeperInitTimeoutSeconds,
        keeperSeconds,
        reason: 'the constant in ssh_agent_host.dart must follow the keeper',
      );
      expect(
        SshAgentHost(transport).startTimeout,
        greaterThanOrEqualTo(Duration(seconds: keeperSeconds + startMarginSeconds)),
        reason: 'the keeper\'s message must arrive before the app gives up',
      );
    });

    test('start waits longer than the quick calls do', () {
      // On a fake clock: the call answers 300 ms after it is made, between the
      // quick timeout (200 ms) and the start one (400 ms), so no real timer
      // races another on a loaded machine.
      fakeAsync((async) {
        answerCalls(
          (method, _) => Future<Object?>.delayed(
            const Duration(milliseconds: 300),
            () => {'id': 'k1', 'agent': 'omp', 'cwd': '/x', 'state': 'running', 'started_at': 1},
          ),
        );

        String? startedId;
        host.start(agent: 'omp', cwd: '/x').then((info) => startedId = info.id);
        async.elapse(const Duration(milliseconds: 300));
        expect(startedId, 'k1');

        Object? listError;
        host.list().then<void>((_) {}, onError: (Object e) => listError = e);
        async.elapse(const Duration(milliseconds: 199));
        expect(listError, isNull, reason: 'the quick timeout is 200 ms');
        async.elapse(const Duration(milliseconds: 1));
        expect(listError, _hostError(message: contains('in time')));
      });
    });
  });

  group('history', () {
    test('asks keeper.history for the agent and folder, and reads the capabilities', () async {
      replies({
        'agent': 'omp',
        'list': true,
        'load': true,
        'resume': false,
        'more': true,
        'sessions': [
          {
            'sessionId': 's2',
            'cwd': '/home/me/a',
            'title': 'Fix it',
            'updatedAt': '2026-10-05T10:00:00Z',
            '_meta': {'messageCount': 12},
          },
          {'sessionId': 's1', 'cwd': '/home/me/a'},
          {'cwd': '/no/id'},
        ],
      });

      final past = await host.history(agent: 'omp', cwd: '/home/me/a');

      expect(transport.hostCalls, ['keeper.history']);
      expect(asked.single.args, {'agent': 'omp', 'cwd': '/home/me/a'});
      expect(past.sessions.map((s) => s.sessionId), ['s2', 's1']);
      expect(past.sessions.first.messageCount, 12);
      expect((past.canList, past.canLoad, past.canResume, past.more), (true, true, false, true));
    });

    test('without a folder the request has no cwd key, so the host lists every folder', () async {
      replies({'agent': 'codex', 'list': false, 'load': true, 'resume': false, 'more': false, 'sessions': <Object?>[]});

      final past = await host.history(agent: 'codex');

      expect(asked.single.args, {'agent': 'codex'});
      expect(past.canList, isFalse);
    });

    test('an answer that isn’t the object is reported', () async {
      replies('segmentation fault');

      await expectLater(host.history(agent: 'omp'), throwsA(_hostError(message: contains('segmentation'))));
    });

    test('a call that never answers times out with the history’s own words', () async {
      answerCalls((_, _) => Completer<Object?>().future);

      await expectLater(
        host.history(agent: 'omp'),
        throwsA(_hostError(fatal: false, message: 'The machine didn’t answer in time (read the past sessions).')),
      );
    });
  });

  group('kill', () {
    test('asks keeper.kill for the keeper, whatever object the host answers', () async {
      replies({'ok': true});

      await host.kill('kp1');

      expect(transport.hostCalls, ['keeper.kill']);
      expect(asked.single.args, {'id': 'kp1'});
    });

    test('an answer with nothing in it is still a success', () async {
      replies(null);

      await host.kill('kp1');
    });

    test('an unknown keeper is reported in the host’s words', () async {
      rejects(const HostException('not_found', 'no such keeper'));

      await expectLater(host.kill('gone1'), throwsA(_hostError(fatal: true, message: 'no such keeper')));
    });
  });

  group('what went wrong, in words', () {
    /// Every one-shot call, with the words it uses for what it was doing.
    final calls = <(String, Future<Object?> Function(SshAgentHost))>[
      ('check the agents', (h) => h.available()),
      ('list the sessions', (h) => h.list()),
      ('start the agent', (h) => h.start(agent: 'omp', cwd: '/x')),
      ('read the past sessions', (h) => h.history(agent: 'omp')),
      ('end the session', (h) => h.kill('k1')),
    ];

    /// [error] as the host answers it, and the [fatal] and [message] the person gets.
    final failures = <(String, HostException, bool, Object)>[
      (
        'a folder that is missing is fatal, with the host’s text',
        const HostException('not_found', 'herdr-keeper: /nope isn’t a folder'),
        true,
        'herdr-keeper: /nope isn’t a folder',
      ),
      (
        'not_found without words says the folder or session doesn’t exist',
        const HostException('not_found', ''),
        true,
        'That folder or session doesn’t exist on the machine.',
      ),
      (
        'an agent that exited is fatal',
        const HostException('agent_exited', 'keeper k1: agent exited (code 1)'),
        true,
        'keeper k1: agent exited (code 1)',
      ),
      (
        'agent_exited without words has its own',
        const HostException('agent_exited', ''),
        true,
        'The agent of this session has exited.',
      ),
      (
        'an agent that is not installed is fatal',
        const HostException('agent_missing', 'omp is not on the PATH'),
        true,
        'omp is not on the PATH',
      ),
      (
        'agent_missing without words says it is not installed',
        const HostException('agent_missing', ''),
        true,
        'That agent isn’t installed on the machine.',
      ),
      (
        'an agent that died while starting can be retried and shows its words',
        const HostException('failed', 'Error: not logged in\nrun `claude login`'),
        false,
        contains('claude login'),
      ),
      (
        'failed without words says the agent exited while starting',
        const HostException('failed', ''),
        false,
        'The agent exited while starting.',
      ),
      (
        'bad_request is fatal: the app asked something the host does not understand',
        const HostException('bad_request', 'cwd must be a path'),
        true,
        'cwd must be a path',
      ),
      (
        'bad_request without words has its own',
        const HostException('bad_request', ''),
        true,
        'The app asked the machine something it didn’t understand.',
      ),
      (
        'any other code can be retried and keeps the words',
        const HostException('permission', 'Traceback: boom'),
        false,
        'Traceback: boom',
      ),
      (
        'a host that is not available is not blamed on anything else, and can be retried',
        const HostException('unavailable', 'no herdr socket'),
        false,
        'The machine couldn’t set up agent sessions.',
      ),
      (
        'a helper that could not be installed keeps the installer’s words',
        const HostException('install_failed', 'No space left on device'),
        false,
        'No space left on device',
      ),
      (
        'a link that was lost can be retried',
        const HostLinkLost('serve exited'),
        false,
        'The connection to the machine dropped.',
      ),
      (
        'a call that was cancelled reads as a dropped connection',
        const HostException('cancelled', 'cancelled'),
        false,
        'The connection to the machine dropped.',
      ),
      (
        'a long traceback is cut to its end, where the error is',
        HostException('failed', '${'frame\n' * 500}ValueError: the actual problem'),
        false,
        allOf(endsWith('ValueError: the actual problem'), hasLength(lessThan(500))),
      ),
    ];

    for (final (name, error, fatal, message) in failures) {
      test('$name (${error.code})', () async {
        rejects(error);

        for (final (_, run) in calls) {
          await expectLater(run(host), throwsA(_hostError(fatal: fatal, message: message)));
        }
      });
    }

    test('a call that never answers says what was being done', () async {
      answerCalls((_, _) => Completer<Object?>().future);

      for (final (what, run) in calls) {
        await expectLater(
          run(host),
          throwsA(_hostError(fatal: false, message: 'The machine didn’t answer in time ($what).')),
        );
      }
    });

    test('a host that answers timeout says what was being done', () async {
      rejects(const HostException('timeout', 'the host took too long'));

      for (final (what, run) in calls) {
        await expectLater(
          run(host),
          throwsA(_hostError(fatal: false, message: 'The machine didn’t answer in time ($what).')),
        );
      }
    });

    test('an unknown code with no words says what was being done and the exit status', () async {
      rejects(const HostException('mystery', ''));

      for (final (what, run) in calls) {
        await expectLater(run(host), throwsA(_hostError(fatal: false, message: 'Couldn’t $what (exit status 1).')));
      }
    });

    test('a connection error from the transport keeps its words and its fatal flag', () async {
      rejects(const HerdrTransportException('Host key changed', fatal: true));
      for (final (_, run) in calls) {
        await expectLater(run(host), throwsA(_hostError(fatal: true, message: 'Host key changed')));
      }

      rejects(const HerdrTransportException('Can’t connect'));
      for (final (_, run) in calls) {
        await expectLater(run(host), throwsA(_hostError(fatal: false, message: 'Can’t connect')));
      }
    });

    test('a host that has no helper link (no handler) is the machine that cannot set up sessions', () async {
      transport.onHostCall = null;

      await expectLater(
        host.list(),
        throwsA(_hostError(fatal: false, message: 'The machine couldn’t set up agent sessions.')),
      );
    });
  });

  group('attach', () {
    late FakeExecChannel channel;
    setUp(() {
      channel = FakeExecChannel();
      answerStreams(() => channel);
    });

    test('opens the keeper.attach stream for the keeper and relays both directions', () async {
      final attached = await host.attach('kp1');
      final got = <String>[];
      attached.lines.listen(got.add);

      attached.send('{"jsonrpc":"2.0","id":1,"method":"initialize"}');
      channel.emit('{"jsonrpc":"2.0","id":1,"result":{}}');
      channel.emit('{"jsonrpc":"2.0","method":"session/update"}');
      await Future<void>.delayed(Duration.zero);

      expect(transport.hostCalls, ['keeper.attach']);
      expect(asked.single.args, {'id': 'kp1'});
      expect(channel.sent, ['{"jsonrpc":"2.0","id":1,"method":"initialize"}']);
      expect(got, ['{"jsonrpc":"2.0","id":1,"result":{}}', '{"jsonrpc":"2.0","method":"session/update"}']);
    });

    test('close detaches: the channel is closed, nothing is killed', () async {
      final attached = await host.attach('kp1');
      final ended = Completer<void>();
      attached.lines.listen((_) {}, onDone: ended.complete);

      await attached.close();
      await attached.close();
      await ended.future.timeout(const Duration(seconds: 2));

      expect(channel.closeCalls, greaterThan(0), reason: 'the channel behind it is closed');
      expect(transport.hostCalls, ['keeper.attach'], reason: 'no kill is ever asked by a detach');
      expect(() => attached.send('x'), throwsStateError);
    });

    test('a consumer that stops listening closes the channel', () async {
      final attached = await host.attach('kp1');
      final sub = attached.lines.listen((_) {});

      await sub.cancel();

      expect(channel.closeCalls, 1);
    });

    test('a keeper that has gone ends the stream with its words and a fatal error', () async {
      final attached = await host.attach('kp1') as KeeperAttachment;
      final errors = <Object>[];
      final ended = Completer<void>();
      attached.lines.listen((_) {}, onError: errors.add, onDone: ended.complete);

      channel.exit(67, stderr: 'keeper k1: agent exited (code 1)');
      await ended.future;

      expect(errors, [_hostError(fatal: true, message: 'keeper k1: agent exited (code 1)')]);
      expect(await attached.endReason, _hostError(fatal: true, message: contains('agent exited')));
    });

    test('an unknown keeper is fatal', () async {
      final attached = await host.attach('nope1') as KeeperAttachment;
      attached.lines.listen((_) {}, onError: (Object _) {});

      channel.exit(66, stderr: 'no such keeper nope');

      expect(await attached.endReason, _hostError(fatal: true, message: 'no such keeper nope'));
    });

    test('a stream that ends as unavailable or failed can be tried again', () async {
      final unavailable = await host.attach('kp1') as KeeperAttachment;
      unavailable.lines.listen((_) {}, onError: (Object _) {});
      channel.exit(65);
      expect(
        await unavailable.endReason,
        _hostError(fatal: false, message: 'The machine couldn’t set up agent sessions.'),
      );

      channel = FakeExecChannel();
      final failed = await host.attach('kp1') as KeeperAttachment;
      failed.lines.listen((_) {}, onError: (Object _) {});
      channel.exit(70, stderr: 'the keeper could not start');
      expect(await failed.endReason, _hostError(fatal: false, message: 'the keeper could not start'));
    });

    test('a clean end (evicted, agent exited) and a dropped link have no failure', () async {
      final clean = await host.attach('kp1') as KeeperAttachment;
      final errors = <Object>[];
      clean.lines.listen((_) {}, onError: errors.add);
      channel.emit('{"method":"_herdr/evicted"}');
      channel.exit(0);

      expect(await clean.endReason, isNull);
      expect(errors, isEmpty);

      channel = FakeExecChannel();
      final dropped = await host.attach('kp1') as KeeperAttachment;
      dropped.lines.listen((_) {}, onError: errors.add);
      channel.exit(null);

      expect(await dropped.endReason, isNull);
      expect(errors, isEmpty);
    });

    test('a stream the host refuses to open fails the attach in its words', () async {
      transport.onHostStream = (_, _, _) => Future.error(const HostException('not_found', 'no such keeper nope'));
      await expectLater(host.attach('nope1'), throwsA(_hostError(fatal: true, message: 'no such keeper nope')));

      transport.onHostStream = (_, _, _) => Future.error(const HostException('agent_exited', ''));
      await expectLater(host.attach('k1'), throwsA(_hostError(fatal: true, message: contains('has exited'))));

      transport.onHostStream = (_, _, _) => Future.error(const HostException('unavailable', 'no helper'));
      await expectLater(host.attach('k1'), throwsA(_hostError(fatal: false, message: contains('set up'))));

      transport.onHostStream = (_, _, _) => Future.error(const HostLinkLost('serve exited'));
      await expectLater(host.attach('k1'), throwsA(_hostError(fatal: false, message: contains('dropped'))));

      transport.onHostStream = (_, _, _) => Future.error(const HostException('timeout', 'slow'));
      await expectLater(host.attach('k1'), throwsA(_hostError(fatal: false, message: contains('in time'))));
    });

    test('a transport that can’t open the stream fails the attach, keeping the fatal flag', () async {
      transport.onHostStream = (_, _, _) => Future.error(const HerdrTransportException('Can’t connect'));
      await expectLater(host.attach('kp1'), throwsA(_hostError(fatal: false, message: 'Can’t connect')));

      transport.onHostStream = (_, _, _) =>
          Future.error(const HerdrTransportException('Host key changed', fatal: true));
      await expectLater(host.attach('kp1'), throwsA(_hostError(fatal: true, message: 'Host key changed')));
    });

    test('a stream that opens after the timeout is closed, not leaked', () {
      fakeAsync((async) {
        final arriving = Completer<ExecChannel>();
        transport.onHostStream = (_, _, _) => arriving.future;

        Object? error;
        host.attach('kp1').then<void>((_) {}, onError: (Object e) => error = e);
        async.elapse(const Duration(seconds: 29));
        expect(error, isNull, reason: 'a stream may take its time to open');
        async.elapse(const Duration(seconds: 1));
        expect(error, _hostError(fatal: false, message: 'The machine didn’t answer in time (reach the machine).'));

        final arrived = FakeExecChannel();
        arriving.complete(arrived);
        async.flushMicrotasks();

        expect(arrived.closeCalls, 1);
      });
    });
  });

  group('follow', () {
    test('opens keeper.follow for the path alone: no keys for what was not asked', () async {
      answerStreams(FakeExecChannel.new);

      await host.follow('/home/u/s.jsonl');

      expect(transport.hostCalls, ['keeper.follow']);
      expect(asked.single.args, {'path': '/home/u/s.jsonl'});
    });

    test('carries from, to, digest and tail_bytes when asked', () async {
      answerStreams(FakeExecChannel.new);

      await host.follow('/home/u/s.jsonl', from: 4096, to: 9000, digest: true, tailBytes: 1 << 20);
      await host.follow('/home/u/s.jsonl', from: 0, digest: false);

      expect(asked.first.args, {
        'path': '/home/u/s.jsonl',
        'from': 4096,
        'to': 9000,
        'digest': true,
        'tail_bytes': 1 << 20,
      });
      expect(asked.last.args, {'path': '/home/u/s.jsonl', 'from': 0});
    });

    test('returns the channel the transport opened, running', () async {
      final channel = FakeExecChannel();
      answerStreams(() => channel);

      final followed = await host.follow('/home/u/s.jsonl');
      final got = <String>[];
      followed.lines.listen(got.add);
      channel.emit('12\t{"a":1}');
      await Future<void>.delayed(Duration.zero);

      expect(followed, same(channel));
      expect(got, ['12\t{"a":1}']);
    });

    test('a host that refuses the path fails the follow in its words', () async {
      transport.onHostStream = (_, _, _) =>
          Future.error(const HostException('bad_request', 'not a log file in your home folder: /x'));
      await expectLater(
        host.follow('/x'),
        throwsA(_hostError(fatal: true, message: 'not a log file in your home folder: /x')),
      );

      transport.onHostStream = (_, _, _) => Future.error(const HostException('not_found', 'cannot read /x.jsonl'));
      await expectLater(host.follow('/x.jsonl'), throwsA(_hostError(fatal: true, message: 'cannot read /x.jsonl')));
    });
  });

  group('keeperCommandFailure', () {
    test('words a stream that ended after it ran, by its exit status', () {
      expect(
        keeperCommandFailure(null, '', 'follow the session'),
        _hostError(fatal: false, message: contains('dropped')),
      );
      expect(keeperCommandFailure(66, 'gone', 'follow the session'), _hostError(fatal: true, message: 'gone'));
      expect(
        keeperCommandFailure(5, '', 'follow the session'),
        _hostError(fatal: false, message: 'Couldn’t follow the session (exit status 5).'),
      );
    });
  });
}
