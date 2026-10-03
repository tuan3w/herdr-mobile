import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/session_launcher.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';

import 'support/fake_transport.dart';
import 'support/herdr_stub.dart';

const _profile = MachineProfile(id: 'm', label: 'box', host: 'h', username: 'u');

Future<(HerdrStub, MachineConnection)> _online({Map<String, dynamic>? snapshot}) async {
  final t = HerdrStub(snapshot ?? snapshotJson());
  t.on['workspace.create'] = (params) {
    addWorkspaceTo(t.snapshot, label: params['label'] as String? ?? '', cwd: params['cwd'] as String? ?? '/home/u');
    return workspaceCreated(cwd: params['cwd'] as String? ?? '/home/u');
  };
  final c = MachineConnection(
    profile: _profile,
    api: HerdrApi(t),
    backoff: (_) => const Duration(hours: 1),
    pollInterval: const Duration(hours: 1),
    structuralDelay: const Duration(milliseconds: 20),
  )..start();
  addTearDown(c.dispose);
  await eventually(() => c.isLive && t.subscriptions == 1);
  return (t, c);
}

SessionLauncher _launcher(MachineConnection c, {Duration timeout = const Duration(seconds: 5)}) =>
    SessionLauncher(c, promptTimeout: timeout, pollInterval: const Duration(milliseconds: 25));

/// herdr detects the agent in the new pane.
void _agentAppears(HerdrStub t, {String agent = 'claude'}) {
  final pane = (t.snapshot['panes'] as List).last as Map<String, dynamic>;
  pane['agent'] = agent;
  pane['agent_status'] = 'idle';
  t.emit({'event': 'pane_agent_detected'});
}

void main() {
  group('shell quoting', () {
    test('a path with quotes, spaces and substitutions stays one literal word', () {
      expect(cdLine('~'), r'cd -- "$HOME"');
      expect(cdLine('~/'), r'cd -- "$HOME"');
      expect(cdLine('~/code/my app'), r'''cd -- "$HOME"/'code/my app' ''' .trim());
      expect(
        cdLine(r"~/a'; rm -rf /; echo '$(id)`id`"),
        r'''cd -- "$HOME"/'a'\''; rm -rf /; echo '\''$(id)`id`' ''' .trim(),
      );
    });

    test('only ~ and ~/... are home folders', () {
      expect(isHomeFolder('~'), isTrue);
      expect(isHomeFolder('~/x'), isTrue);
      expect(isHomeFolder('~root/x'), isFalse);
      expect(isHomeFolder('/home/u'), isFalse);
    });
  });

  test('creates the workspace unfocused, types the command and returns the new pane', () async {
    final (t, c) = await _online();

    final r = await _launcher(c).launch(const LaunchRequest(
      folder: '/work/app',
      label: 'app',
      command: 'claude',
    ));

    expect(r.paneId, 'wN:p1');
    expect(r.workspaceId, 'wN');
    expect(r.commandError, isNull);
    expect(r.prompt, isNull, reason: 'no prompt was asked for');
    expect(t.methods, ['workspace.create', 'pane.send_input']);
    expect(t.paramsOf('workspace.create').single, {'cwd': '/work/app', 'label': 'app', 'focus': false});
    expect(t.paramsOf('pane.send_input').single, {
      'pane_id': 'wN:p1',
      'text': 'claude',
      'keys': ['enter'],
    });
    expect(c.snapshot.panes.any((p) => p.id == 'wN:p1'), isTrue, reason: 'the list is refreshed so the pane exists');
  });

  test('a plain shell types nothing', () async {
    final (t, c) = await _online();

    final r = await _launcher(c).launch(const LaunchRequest(folder: '/work/app', label: 'app'));

    expect(r.commandError, isNull);
    expect(t.methods, ['workspace.create']);
  });

  group('home folders', () {
    test('~ cannot go to herdr as a cwd: the shell changes directory, quoted', () async {
      final (t, c) = await _online();

      await _launcher(c).launch(const LaunchRequest(folder: "~/it's here", label: 'x', command: 'codex'));

      expect(t.paramsOf('workspace.create').single, {'label': 'x', 'focus': false});
      expect(t.paramsOf('pane.send_input').single['text'], r'''cd -- "$HOME"/'it'\''s here' && codex''');
    });

    test('a plain shell in ~ just changes directory', () async {
      final (t, c) = await _online();

      await _launcher(c).launch(const LaunchRequest(folder: '~', label: 'home'));

      expect(t.paramsOf('pane.send_input').single['text'], r'cd -- "$HOME"');
    });
  });

  group('a folder that does not exist', () {
    test('herdr falls back to home: the stray workspace is removed and nothing is typed', () async {
      final (t, c) = await _online();
      t.on['workspace.create'] = (_) => workspaceCreated(cwd: '/home/u'); // not what was asked for

      await expectLater(
        _launcher(c).launch(const LaunchRequest(folder: '/work/typo', command: 'claude')),
        throwsA(isA<FolderNotFoundException>()
            .having((e) => e.folder, 'folder', '/work/typo')
            .having((e) => e.actual, 'actual', '/home/u')),
      );

      expect(t.methods, ['workspace.create', 'workspace.close']);
      expect(t.paramsOf('workspace.close').single, {'workspace_id': 'wN'});
    });

    test('a trailing slash is the same folder', () async {
      final (t, c) = await _online();
      t.on['workspace.create'] = (_) => workspaceCreated(cwd: '/work/app');

      await _launcher(c).launch(const LaunchRequest(folder: '/work/app/', command: 'claude'));

      expect(t.methods, ['workspace.create', 'pane.send_input']);
    });
  });

  group('failures', () {
    test('nothing is created when herdr is too old', () async {
      final (t, c) = await _online();
      t.on['workspace.create'] = (_) => throw unknownMethod('workspace.create');

      await expectLater(
        _launcher(c).launch(const LaunchRequest(folder: '/work/app', command: 'claude')),
        throwsA(isA<HerdrUnsupportedException>()),
      );
      expect(t.methods, ['workspace.create']);
    });

    test('the command failing leaves the workspace and says so', () async {
      final (t, c) = await _online();
      t.on['pane.send_input'] = (_) => throw const HerdrApiException('pane_send_failed', 'pty closed');

      final r = await _launcher(c).launch(const LaunchRequest(
        folder: '/work/app',
        command: 'claude',
        prompt: 'fix the build',
      ));

      expect(r.paneId, 'wN:p1');
      expect(r.commandError, isA<HerdrApiException>());
      expect(r.prompt, isNull, reason: 'no agent can have started');
      expect(t.methods, ['workspace.create', 'pane.send_input'], reason: 'the workspace is not closed');
    });
  });

  group('first prompt', () {
    test('waits for the agent, then sends it as its own line', () async {
      final (t, c) = await _online();

      final r = await _launcher(c).launch(const LaunchRequest(
        folder: '/work/app',
        label: 'app',
        command: 'claude',
        prompt: 'fix the build',
      ));
      var settled = false;
      unawaited(r.prompt!.whenComplete(() => settled = true));

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(settled, isFalse, reason: 'no agent yet');
      expect(t.paramsOf('pane.send_input'), hasLength(1), reason: 'only the command so far');

      _agentAppears(t);

      expect(await r.prompt, PromptOutcome.sent);
      expect(t.paramsOf('pane.send_input').last, {
        'pane_id': 'wN:p1',
        'text': 'fix the build',
        'keys': ['enter'],
      });
    });

    test('is not sent when no agent starts in time', () async {
      final (t, c) = await _online();

      final r = await _launcher(c, timeout: const Duration(milliseconds: 150)).launch(const LaunchRequest(
        folder: '/work/app',
        command: 'claudee',
        prompt: 'fix the build',
      ));

      expect(await r.prompt, PromptOutcome.timedOut);
      expect(t.paramsOf('pane.send_input'), hasLength(1), reason: 'the prompt never reached a shell');
    });

    test('is dropped when the pane is closed while waiting', () async {
      final (t, c) = await _online();
      final r = await _launcher(c).launch(const LaunchRequest(
        folder: '/work/app',
        command: 'claude',
        prompt: 'hi',
      ));

      (t.snapshot['panes'] as List).removeLast();
      t.emit({'event': 'pane_closed'});

      expect(await r.prompt, PromptOutcome.gone);
      expect(t.paramsOf('pane.send_input'), hasLength(1));
    });

    test('reports when the agent was up but the input was refused', () async {
      final (t, c) = await _online();
      final r = await _launcher(c).launch(const LaunchRequest(
        folder: '/work/app',
        command: 'claude',
        prompt: 'hi',
      ));
      t.on['pane.send_input'] = (_) => throw const HerdrApiException('pane_send_failed', 'closed');

      _agentAppears(t);

      expect(await r.prompt, PromptOutcome.failed);
    });

    test('a safety-net poll notices an agent even without any event', () async {
      final (t, c) = await _online();
      final r = await _launcher(c).launch(const LaunchRequest(
        folder: '/work/app',
        command: 'claude',
        prompt: 'hi',
      ));

      final pane = (t.snapshot['panes'] as List).last as Map<String, dynamic>;
      pane['agent'] = 'claude';
      pane['agent_status'] = 'working';

      expect(await r.prompt, PromptOutcome.sent);
    });
  });
}
