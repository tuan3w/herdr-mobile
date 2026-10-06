import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart';
import 'package:herdr_mobile/data/services/ssh_agent_host.dart';

import 'support/fake_exec.dart';
import 'support/fake_transport.dart';

Matcher _hostError({bool? fatal, Object? message}) => isA<AgentHostException>()
    .having((e) => e.fatal, 'fatal', fatal ?? anything)
    .having((e) => e.message, 'message', message ?? anything);

void main() {
  late FakeTransport transport;
  late List<FakeExecChannel> channels;
  late SshAgentHost host;

  /// Every command opens a channel built by [make].
  void answer(FakeExecChannel Function() make) {
    transport.onExec = (command) async {
      final channel = make();
      channels.add(channel);
      return channel;
    };
  }

  FakeExecChannel Function() prints(List<String> lines) =>
      () => FakeExecChannel.run(stdout: lines);
  FakeExecChannel Function() fails(int? code, [String stderr = '']) =>
      () => FakeExecChannel.run(code: code, stderr: stderr);

  setUp(() {
    transport = FakeTransport();
    channels = [];
    host = SshAgentHost(
      transport,
      quickTimeout: const Duration(milliseconds: 200),
      startTimeout: const Duration(milliseconds: 400),
      installTimeout: const Duration(milliseconds: 400),
      attachCheck: const Duration(milliseconds: 50),
    );
  });

  group('available', () {
    test('reads the routes of the probe line and runs the probe command', () async {
      answer(prints(['{"routes":["omp","claude"]}']));

      expect(await host.available(), {'omp', 'claude'});
      expect(transport.execCommands, [keeperProbeCommand()]);
    });

    test('a host with no agents is an empty set, not an error', () async {
      answer(prints(['{"routes":[]}']));

      expect(await host.available(), isEmpty);
    });

    test('a shell banner before the answer does not break it', () async {
      answer(prints(['Welcome to the box', '42', '{"routes":["pi"]}']));

      expect(await host.available(), {'pi'});
    });

    test('a missing python3 is fatal and says so in the host\'s words', () async {
      answer(fails(78, 'herdr-mobile: agent sessions need python3 on this host'));

      await expectLater(
        host.available(),
        throwsA(_hostError(fatal: true, message: contains('need python3'))),
      );
    });

    test('an answer of the wrong shape is reported with what came back', () async {
      answer(prints(['{"agents":["omp"]}']));

      await expectLater(
        host.available(),
        throwsA(_hostError(fatal: false, message: contains('agents'))),
      );
    });
  });

  group('list', () {
    test('parses every keeper, running and exited', () async {
      answer(prints([
        '[{"id":"k2","agent":"claude","cwd":"/home/me/b","state":"running","started_at":1700000100000,'
            '"pid":77,"session_id":"s-1","title":"Fix tests","pending":2,"last_event_at":1700000200000},'
            '{"id":"k1","agent":"omp","cwd":"/home/me/a","state":"exited","started_at":1700000000000,'
            '"exit_code":1,"exit_reason":"crashed"}]',
      ]));

      final keepers = await host.list();

      expect(keepers.map((k) => k.id), ['k2', 'k1']);
      expect(keepers[0].state, KeeperState.running);
      expect(keepers[0].pending, 2);
      expect(keepers[0].title, 'Fix tests');
      expect(keepers[0].lastEventAt, DateTime.fromMillisecondsSinceEpoch(1700000200000));
      expect(keepers[1].state, KeeperState.exited);
      expect(keepers[1].exitCode, 1);
      expect(transport.execCommands, [keeperListCommand()]);
    });

    test('no keepers is an empty list', () async {
      answer(prints(['[]']));

      expect(await host.list(), isEmpty);
    });

    test('an object instead of an array is reported', () async {
      answer(prints(['{"id":"k1"}']));

      await expectLater(host.list(), throwsA(_hostError(message: contains('unexpected'))));
    });
  });

  group('start', () {
    test('runs the start command for the agent and folder and returns the keeper', () async {
      answer(prints([
        '{"id":"k9","agent":"codex","cwd":"/home/me/it\'s a dir","state":"running","started_at":1700000000000}',
      ]));

      final info = await host.start(agent: 'codex', cwd: "/home/me/it's a dir");

      expect(info.id, 'k9');
      expect(info.cwd, "/home/me/it's a dir");
      expect(transport.execCommands, [keeperStartCommand(agent: 'codex', cwd: "/home/me/it's a dir")]);
    });

    test('a folder that is missing is fatal, with the host\'s text', () async {
      answer(fails(66, 'herdr-keeper: /nope is not a folder'));

      await expectLater(
        host.start(agent: 'omp', cwd: '/nope'),
        throwsA(_hostError(fatal: true, message: 'herdr-keeper: /nope is not a folder')),
      );
    });

    test('an agent that is not installed is fatal even without stderr', () async {
      answer(fails(69));

      await expectLater(
        host.start(agent: 'pi', cwd: '/x'),
        throwsA(_hostError(fatal: true, message: contains('not installed'))),
      );
    });

    test('an agent that died while starting can be retried and shows its stderr', () async {
      answer(fails(70, 'Error: not logged in\nrun `claude login`'));

      await expectLater(
        host.start(agent: 'claude', cwd: '/x'),
        throwsA(_hostError(fatal: false, message: contains('claude login'))),
      );
    });

    test('an unknown exit status is retryable and keeps stderr and the status', () async {
      answer(fails(1, 'Traceback: boom'));

      await expectLater(
        host.start(agent: 'omp', cwd: '/x'),
        throwsA(_hostError(fatal: false, message: 'Traceback: boom')),
      );
      answer(fails(5));
      await expectLater(
        host.start(agent: 'omp', cwd: '/x'),
        throwsA(_hostError(fatal: false, message: contains('exit status 5'))),
      );
    });

    test('a folder or agent the command builder refuses never reaches the host', () async {
      answer(prints(['{}']));

      await expectLater(
        host.start(agent: 'omp', cwd: 'line\nbreak'),
        throwsA(_hostError(fatal: true, message: contains('folder'))),
      );
      await expectLater(
        host.start(agent: 'emacs', cwd: '/x'),
        throwsA(_hostError(fatal: true, message: contains('agent'))),
      );
      expect(transport.execCommands, isEmpty);
    });

    test('a long traceback is cut to its end, where the error is', () async {
      final stderr = '${'frame\n' * 500}ValueError: the actual problem';
      answer(fails(1, stderr));

      await expectLater(
        host.start(agent: 'omp', cwd: '/x'),
        throwsA(_hostError(
          message: allOf(endsWith('ValueError: the actual problem'), hasLength(lessThan(500))),
        )),
      );
    });

    test('exit 0 with no output is reported, with stderr if there is any', () async {
      answer(() => FakeExecChannel.run(stderr: 'warning: x'));

      await expectLater(
        host.start(agent: 'omp', cwd: '/x'),
        throwsA(_hostError(fatal: false, message: allOf(contains('nothing'), contains('warning: x')))),
      );
    });

    test('output that is not JSON is reported with an excerpt', () async {
      answer(prints(['segmentation fault (core dumped)']));

      await expectLater(
        host.start(agent: 'omp', cwd: '/x'),
        throwsA(_hostError(fatal: false, message: contains('segmentation fault'))),
      );
    });

    test('a link that drops mid-command is retryable', () async {
      answer(fails(null));

      await expectLater(
        host.start(agent: 'omp', cwd: '/x'),
        throwsA(_hostError(fatal: false, message: contains('dropped'))),
      );
    });

    test('a command that never ends times out, and its channel is closed', () async {
      answer(FakeExecChannel.new);

      await expectLater(
        host.start(agent: 'omp', cwd: '/x'),
        throwsA(_hostError(fatal: false, message: contains('in time'))),
      );
      expect(channels.single.closeCalls, 1);
    });

    test('the default start timeout outlasts the keeper\'s own initialize timeout', () {
      final script = RegExp(r'INIT_TIMEOUT = (\d+)').firstMatch(keeperScript());
      final keeperSeconds = int.parse(script!.group(1)!);

      expect(keeperInitTimeoutSeconds, keeperSeconds,
          reason: 'the constant in ssh_agent_host.dart must follow the script');
      expect(SshAgentHost(transport).startTimeout,
          greaterThanOrEqualTo(Duration(seconds: keeperSeconds + 30)),
          reason: 'the keeper\'s stderr must arrive before the app gives up');
    });

    test('start waits longer than the quick commands do', () async {
      answer(() {
        final channel = FakeExecChannel();
        Timer(const Duration(milliseconds: 300), () {
          channel.emit('{"id":"k1","agent":"omp","cwd":"/x","state":"running","started_at":1}');
          channel.exit(0);
        });
        return channel;
      });

      expect((await host.start(agent: 'omp', cwd: '/x')).id, 'k1');
      await expectLater(host.list(), throwsA(_hostError(message: contains('in time'))));
    });
  });

  group('history', () {
    test('runs the history command and reads the line, with the capabilities', () async {
      answer(prints([
        '{"agent":"omp","list":true,"load":true,"resume":false,"more":true,"sessions":['
            '{"sessionId":"s2","cwd":"/home/me/a","title":"Fix it","updatedAt":"2026-10-05T10:00:00Z","_meta":{"messageCount":12}},'
            '{"sessionId":"s1","cwd":"/home/me/a"},'
            '{"cwd":"/no/id"}]}',
      ]));

      final past = await host.history(agent: 'omp', cwd: '/home/me/a');

      expect(transport.execCommands, [keeperHistoryCommand(agent: 'omp', cwd: '/home/me/a')]);
      expect(past.sessions.map((s) => s.sessionId), ['s2', 's1']);
      expect(past.sessions.first.messageCount, 12);
      expect((past.canList, past.canLoad, past.canResume, past.more), (true, true, false, true));
    });

    test('without a folder the command lists every folder', () async {
      answer(prints(['{"agent":"codex","list":false,"load":true,"resume":false,"more":false,"sessions":[]}']));

      final past = await host.history(agent: 'codex');

      expect(transport.execCommands, [keeperHistoryCommand(agent: 'codex')]);
      expect(past.canList, isFalse);
    });

    test('a folder that is gone and an agent that is not installed are fatal', () async {
      answer(fails(66, 'herdr-mobile: the folder does not exist on this host: /gone'));
      await expectLater(
        host.history(agent: 'omp', cwd: '/gone'),
        throwsA(_hostError(fatal: true, message: contains('does not exist'))),
      );
      answer(fails(69));
      await expectLater(
        host.history(agent: 'pi'),
        throwsA(_hostError(fatal: true, message: contains('not installed'))),
      );
    });

    test('an agent that fails or does not answer can be tried again, with its words', () async {
      answer(fails(70, 'herdr-mobile: omp: store unreadable'));

      await expectLater(
        host.history(agent: 'omp'),
        throwsA(_hostError(fatal: false, message: contains('store unreadable'))),
      );
    });

    test('a folder or agent the command builder refuses never reaches the host', () async {
      answer(prints(['{}']));

      await expectLater(
        host.history(agent: 'omp', cwd: 'line\nbreak'),
        throwsA(_hostError(fatal: true, message: contains('folder'))),
      );
      await expectLater(
        host.history(agent: 'emacs'),
        throwsA(_hostError(fatal: true, message: contains('agent'))),
      );
      expect(transport.execCommands, isEmpty);
    });

    test('a line that is not the answer is reported, and a command that hangs times out', () async {
      answer(prints(['segmentation fault']));
      await expectLater(host.history(agent: 'omp'), throwsA(_hostError(message: contains('segmentation'))));

      answer(FakeExecChannel.new);
      await expectLater(host.history(agent: 'omp'), throwsA(_hostError(message: contains('in time'))));
      expect(channels.last.closeCalls, 1);
    });
  });

  group('channels', () {
    test('every one-shot command leaves its channel closed, whether it worked or not', () async {
      answer(prints(['{"routes":[]}']));
      await host.available();
      answer(fails(1, 'x'));
      await expectLater(host.list(), throwsA(isA<AgentHostException>()));
      answer(prints(['not json']));
      await expectLater(host.list(), throwsA(isA<AgentHostException>()));
      answer(prints(['{"ok":true}']));
      await host.kill('kp1');

      expect(channels.map((c) => c.closeCalls), [1, 1, 1, 1]);
    });

    test('a connection error from the transport keeps its fatal flag', () async {
      transport.onExec = (_) => Future.error(
            const HerdrTransportException('Host key changed', fatal: true),
          );
      await expectLater(
        host.list(),
        throwsA(_hostError(fatal: true, message: 'Host key changed')),
      );

      transport.onExec = (_) => Future.error(const HerdrTransportException('Cannot connect'));
      await expectLater(host.list(), throwsA(_hostError(fatal: false, message: 'Cannot connect')));
    });

    test('a channel that opens after the timeout is closed, not leaked', () async {
      final arriving = Completer<ExecChannel>();
      transport.onExec = (_) => arriving.future;

      await expectLater(host.list(), throwsA(_hostError(message: contains('in time'))));
      final channel = FakeExecChannel();
      arriving.complete(channel);
      await Future<void>.delayed(Duration.zero);

      expect(channel.closeCalls, 1);
    });
  });

  group('kill', () {
    test('runs the kill command and succeeds on exit 0', () async {
      answer(prints(['{"ok":true}']));

      await host.kill('kp1');

      expect(transport.execCommands, [keeperKillCommand('kp1')]);
    });

    test('exit 0 without output is still a success', () async {
      answer(() => FakeExecChannel.run());

      await host.kill('kp1');
    });

    test('an unknown keeper is reported', () async {
      answer(fails(66, 'no such keeper'));

      await expectLater(host.kill('gone1'), throwsA(_hostError(message: 'no such keeper')));
    });
  });

  group('installing the keeper script', () {
    final installCommand = keeperInstallCommand();
    late bool there;
    late FakeExecChannel attachChannel;
    late int installs;
    final installers = <FakeExecChannel>[];

    /// A host that has the script only after the install command succeeded
    /// (when [present] is false). [install] builds the answer to the install
    /// command; the default is a good one.
    void scripted({bool present = false, FakeExecChannel Function()? install}) {
      there = present;
      installs = 0;
      installers.clear();
      attachChannel = FakeExecChannel();
      transport.onExec = (command) async {
        if (command == installCommand) {
          installs++;
          if (install != null) return install();
          // Like the real installer: reads its input to the end, then answers.
          final installer = FakeExecChannel();
          installer.onInputClosed = () {
            there = true;
            installer.emit('{"ok":true}');
            installer.exit(0);
          };
          installers.add(installer);
          return installer;
        }
        if (!there) {
          return FakeExecChannel.run(code: 65, stderr: 'herdr-mobile: the keeper is not installed');
        }
        if (command == keeperAttachCommand('kp1', zipped: true)) return attachChannel;
        if (command == keeperListCommand()) return FakeExecChannel.run(stdout: ['[]']);
        return FakeExecChannel.run(stdout: ['{"routes":["omp"]}']);
      };
    }

    test('exit 65 installs the script and repeats the command once', () async {
      scripted();

      expect(await host.list(), isEmpty);

      expect(transport.execCommands, [keeperListCommand(), installCommand, keeperListCommand()]);
    });

    test('the script travels on stdin, whole and in order, and stdin is closed after it', () async {
      scripted();

      await host.list();

      final installer = installers.single;
      expect(installer.inputClosed, isTrue, reason: 'the installer reads until end of input');
      expect(installer.sent, hasLength(1));
      expect('${installer.sent.single}\n', keeperInstallPayload());
      expect(installCommand.length, lessThan(8000), reason: 'Dropbear caps an exec at 9000 bytes');
    });

    test('after an install no command installs again', () async {
      scripted();

      await host.list();
      await host.available();
      await host.kill('kp1');

      expect(installs, 1);
      expect(transport.execCommands.where((c) => c == keeperListCommand()), hasLength(2));
    });

    test('a host that has the script is never asked to install', () async {
      scripted(present: true);

      await host.list();

      expect(installs, 0);
      expect(transport.execCommands, [keeperListCommand()]);
    });

    test('history installs the script when the host has none, then asks again', () async {
      final historyCommand = keeperHistoryCommand(agent: 'omp');
      scripted();
      final scripted0 = transport.onExec!;
      transport.onExec = (command) async => command == historyCommand && there
          ? FakeExecChannel.run(stdout: ['{"agent":"omp","list":true,"load":true,"resume":true,"more":false,"sessions":[]}'])
          : scripted0(command);

      final past = await host.history(agent: 'omp');

      expect(past.canReopen, isTrue);
      expect(transport.execCommands, [historyCommand, installCommand, historyCommand]);
      expect(installs, 1);
    });

    test('if the script goes missing later, the next 65 installs it again', () async {
      scripted();
      await host.list();
      there = false; // someone cleaned ~/.herdr-mobile

      await host.list();

      expect(installs, 2);
    });

    test('two commands that both find it missing install once', () async {
      scripted();

      await Future.wait([host.list(), host.available()]);

      expect(installs, 1);
    });

    test('a host without python3 fails the install fatally, and the command is not repeated', () async {
      scripted(install: () => FakeExecChannel.run(
            code: 78,
            stderr: 'herdr-mobile: agent sessions need python3 on this host',
          ));

      await expectLater(
        host.list(),
        throwsA(_hostError(fatal: true, message: contains('need python3'))),
      );

      expect(transport.execCommands, [keeperListCommand(), installCommand]);
    });

    test('an install that fails for another reason is retryable and shows its stderr', () async {
      scripted(install: () => FakeExecChannel.run(code: 1, stderr: 'No space left on device'));

      await expectLater(
        host.list(),
        throwsA(_hostError(fatal: false, message: contains('No space left'))),
      );
    });

    test('an install that does not say ok is a failure', () async {
      scripted(install: () => FakeExecChannel.run(stdout: ['{"ok":false}'], stderr: 'bad hash'));

      await expectLater(
        host.list(),
        throwsA(_hostError(message: allOf(contains('set up'), contains('bad hash')))),
      );
    });

    test('an install that never answers times out', () async {
      scripted(install: FakeExecChannel.new);

      await expectLater(host.list(), throwsA(_hostError(message: contains('in time'))));
    });

    test('a script that is still missing after the install is reported, not looped on', () async {
      scripted(install: () => FakeExecChannel.run(stdout: ['{"ok":true}']));

      await expectLater(host.list(), throwsA(_hostError(message: contains('still missing'))));

      expect(transport.execCommands, [keeperListCommand(), installCommand, keeperListCommand()]);
    });

    test('kill repeats its own command after the install', () async {
      scripted();

      await host.kill('kp1');

      expect(transport.execCommands, [keeperKillCommand('kp1'), installCommand, keeperKillCommand('kp1')]);
    });

    test('attach installs before it returns and sends on the second channel', () async {
      scripted();

      final attached = await host.attach('kp1');
      attached.send('{"hello":1}');

      expect(transport.execCommands,
          [keeperAttachCommand('kp1', zipped: true), installCommand, keeperAttachCommand('kp1', zipped: true)]);
      expect(attachChannel.sent, ['{"hello":1}']);
    });

    test('attach fails when the install does, and opens nothing long-lived', () async {
      scripted(install: () => FakeExecChannel.run(code: 78, stderr: 'need python3'));

      await expectLater(host.attach('kp1'), throwsA(_hostError(fatal: true, message: contains('python3'))));

      expect(transport.execCommands, [keeperAttachCommand('kp1', zipped: true), installCommand]);
    });

    test('attach on a host not yet known waits only the check, then returns the live channel', () async {
      scripted(present: true);

      final attached = await host.attach('kp1');
      attached.send('x');

      expect(installs, 0);
      expect(attachChannel.sent, ['x']);
    });

    test('once a command has worked, attach does not wait for any check', () async {
      final patient = SshAgentHost(transport, attachCheck: const Duration(seconds: 30));
      scripted(present: true);
      await patient.list();

      final attached = await patient.attach('kp1').timeout(const Duration(seconds: 2));
      attached.send('x');

      expect(attachChannel.sent, ['x']);
    });
  });

  group('attach', () {
    late FakeExecChannel channel;
    setUp(() {
      channel = FakeExecChannel();
      transport.onExec = (command) async => channel;
    });

    test('opens the attach command and relays both directions', () async {
      final attached = await host.attach('kp1');
      final got = <String>[];
      attached.lines.listen(got.add);

      attached.send('{"jsonrpc":"2.0","id":1,"method":"initialize"}');
      channel.emit('{"jsonrpc":"2.0","id":1,"result":{}}');
      channel.emit('{"jsonrpc":"2.0","method":"session/update"}');
      await Future<void>.delayed(Duration.zero);

      expect(transport.execCommands, [keeperAttachCommand('kp1', zipped: true)]);
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
      expect(transport.execCommands, [keeperAttachCommand('kp1', zipped: true)],
          reason: 'no kill command is ever run by a detach');
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

    test('a transport that cannot open the channel fails the attach', () async {
      transport.onExec = (_) => Future.error(const HerdrTransportException('Cannot connect'));

      await expectLater(host.attach('kp1'), throwsA(_hostError(message: 'Cannot connect')));
    });
  });
}
