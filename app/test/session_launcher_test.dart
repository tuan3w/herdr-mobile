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

SessionLauncher _launcher(MachineConnection c) => SessionLauncher(c);

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

  test('creates the workspace unfocused and returns the new pane, which exists in the list', () async {
    final (t, c) = await _online();

    final r = await _launcher(c).launch(const LaunchRequest(folder: '/work/app', label: 'app'));

    expect(r.paneId, 'wN:p1');
    expect(r.workspaceId, 'wN');
    expect(t.methods, ['workspace.create'], reason: 'a plain shell: nothing is typed');
    expect(t.paramsOf('workspace.create').single, {'cwd': '/work/app', 'label': 'app', 'focus': false});
    expect(c.snapshot.panes.any((p) => p.id == 'wN:p1'), isTrue, reason: 'the list is refreshed so the pane exists');
  });

  group('home folders', () {
    test('~ cannot go to herdr as a cwd: the shell changes directory, quoted', () async {
      final (t, c) = await _online();

      await _launcher(c).launch(const LaunchRequest(folder: "~/it's here", label: 'x'));

      expect(t.paramsOf('workspace.create').single, {'label': 'x', 'focus': false});
      expect(t.paramsOf('pane.send_input').single, {
        'pane_id': 'wN:p1',
        'text': 'cd -- "\$HOME"/\'it\'\\\'\'s here\'',
        'keys': ['enter'],
      });
    });

    test('~ alone changes to the home directory', () async {
      final (t, c) = await _online();

      await _launcher(c).launch(const LaunchRequest(folder: '~', label: 'home'));

      expect(t.paramsOf('pane.send_input').single['text'], r'cd -- "$HOME"');
    });

    test('a cd that cannot be typed fails loudly and leaves the workspace', () async {
      final (t, c) = await _online();
      t.on['pane.send_input'] = (_) => throw const HerdrApiException('pane_send_failed', 'pty closed');

      await expectLater(
        _launcher(c).launch(const LaunchRequest(folder: '~/code', label: 'x')),
        throwsA(isA<HerdrApiException>()),
      );

      expect(t.methods, ['workspace.create', 'pane.send_input'], reason: 'the workspace is not closed');
    });
  });

  group('a folder that does not exist', () {
    test('herdr falls back to home: the stray workspace is removed and nothing is typed', () async {
      final (t, c) = await _online();
      t.on['workspace.create'] = (_) => workspaceCreated(cwd: '/home/u'); // not what was asked for

      await expectLater(
        _launcher(c).launch(const LaunchRequest(folder: '/work/typo')),
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

      await _launcher(c).launch(const LaunchRequest(folder: '/work/app/'));

      expect(t.methods, ['workspace.create']);
    });
  });

  test('nothing is created when herdr is too old', () async {
    final (t, c) = await _online();
    t.on['workspace.create'] = (_) => throw unknownMethod('workspace.create');

    await expectLater(
      _launcher(c).launch(const LaunchRequest(folder: '/work/app')),
      throwsA(isA<HerdrUnsupportedException>()),
    );
    expect(t.methods, ['workspace.create']);
  });
}
