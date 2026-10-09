import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';

import 'support/herdr_stub.dart';

void main() {
  late HerdrStub t;
  late HerdrApi api;
  setUp(() {
    t = HerdrStub();
    api = HerdrApi(t);
  });

  group('createWorkspace', () {
    test('sends exactly cwd, label and focus:false, and returns the ids and where the shell started', () async {
      t.on['workspace.create'] = (_) => workspaceCreated(workspace: 'wQ', cwd: '/srv/app');
      final r = await api.createWorkspace(cwd: '/srv/app', label: 'app');

      expect(t.paramsOf('workspace.create'), [
        {'cwd': '/srv/app', 'label': 'app', 'focus': false},
      ]);
      expect(r, (workspaceId: 'wQ', tabId: 'wQ:t1', rootPaneId: 'wQ:p1', cwd: '/srv/app'));
    });

    test('leaves out what was not given, and never sends an empty env', () async {
      t.on['workspace.create'] = (_) => workspaceCreated(cwd: null);
      final r = await api.createWorkspace();

      expect(t.paramsOf('workspace.create'), [
        {'focus': false},
      ]);
      expect(r.cwd, isNull);
    });

    test('passes env and focus when asked', () async {
      t.on['workspace.create'] = (_) => workspaceCreated();
      await api.createWorkspace(cwd: '/x', env: {'A': '1'}, focus: true);

      expect(t.paramsOf('workspace.create').single, {
        'cwd': '/x',
        'focus': true,
        'env': {'A': '1'},
      });
    });

    test('a response without the ids is a transport error, not a crash', () async {
      t.on['workspace.create'] = (_) => {'type': 'workspace_created'};

      await expectLater(
        api.createWorkspace(cwd: '/x'),
        throwsA(isA<HerdrTransportException>().having((e) => e.fatal, 'fatal', isFalse)),
      );
    });
  });

  test('createTab targets the workspace and returns the tab and its pane', () async {
    t.on['tab.create'] = (_) => {
          'type': 'tab_created',
          'tab': {'tab_id': 'w1:t2'},
          'root_pane': {'pane_id': 'w1:p4'},
        };
    final r = await api.createTab(workspaceId: 'w1', cwd: '/srv', label: 'logs');

    expect(t.paramsOf('tab.create'), [
      {'workspace_id': 'w1', 'cwd': '/srv', 'label': 'logs', 'focus': false},
    ]);
    expect(r, (tabId: 'w1:t2', rootPaneId: 'w1:p4'));
  });

  test('splitPane names the target and direction and returns the new pane', () async {
    t.on['pane.split'] = (_) => {
          'type': 'pane_info',
          'pane': {'pane_id': 'w1:p9'},
        };
    final id = await api.splitPane(
      targetPaneId: 'w1:p1',
      workspaceId: 'w1',
      direction: SplitDirection.down,
      cwd: '/srv',
    );

    expect(id, 'w1:p9');
    expect(t.paramsOf('pane.split').single, {
      'direction': 'down',
      'target_pane_id': 'w1:p1',
      'workspace_id': 'w1',
      'cwd': '/srv',
      'focus': false,
    });
  });

  test('close and rename send the id herdr expects for each', () async {
    await api.closeWorkspace('w1');
    await api.closeTab('w1:t2');
    await api.closePane('w1:p3');
    await api.renameWorkspace('w1', 'api');
    await api.renameTab('w1:t2', 'logs');
    await api.renamePane('w1:p3', 'build');

    expect(t.methods, [
      'workspace.close',
      'tab.close',
      'pane.close',
      'workspace.rename',
      'tab.rename',
      'pane.rename',
    ]);
    expect([for (final c in t.calls) c.$2], [
      {'workspace_id': 'w1'},
      {'tab_id': 'w1:t2'},
      {'pane_id': 'w1:p3'},
      {'workspace_id': 'w1', 'label': 'api'},
      {'tab_id': 'w1:t2', 'label': 'logs'},
      {'pane_id': 'w1:p3', 'label': 'build'},
    ]);
  });

  test('an empty pane name clears it (herdr takes null)', () async {
    await api.renamePane('w1:p3', '');

    expect(t.paramsOf('pane.rename').single, {'pane_id': 'w1:p3', 'label': null});
  });

  group('paneProcessInfo', () {
    test('lists the foreground processes of the pane', () async {
      t.on['pane.process_info'] = (_) => {
            'type': 'pane_process_info',
            'process_info': {
              'pane_id': 'w1:p3',
              'shell_pid': 10,
              'foreground_processes': [
                {'pid': 4242, 'name': 'claude', 'argv0': 'claude', 'cmdline': 'claude --resume', 'cwd': '/work/app'},
                {'pid': 'x', 'name': 'broken'},
              ],
            },
          };

      final rows = await api.paneProcessInfo('w1:p3');

      expect(t.paramsOf('pane.process_info').single, {'pane_id': 'w1:p3'});
      expect(rows.map((p) => (p.pid, p.name, p.cmdline, p.cwd)), [(4242, 'claude', 'claude --resume', '/work/app')]);
    });

    test('an old herdr is told apart from a bad request', () async {
      t.on['pane.process_info'] = (_) => throw unknownMethod('pane.process_info');

      await expectLater(api.paneProcessInfo('w1:p3'), throwsA(isA<HerdrUnsupportedException>()));
    });
  });

  group('installIntegration', () {
    test('sends the target and returns what herdr says', () async {
      t.on['integration.install'] = (_) => {
            'type': 'integration_install',
            'target': 'claude',
            'details': {
              'messages': ['installed hook', 7, 'restart claude'],
            },
          };

      expect(await api.installIntegration('claude'), ['installed hook', 'restart claude']);
      expect(t.paramsOf('integration.install').single, {'target': 'claude'});
    });

    test('an old herdr is told apart from a bad request', () async {
      t.on['integration.install'] = (_) => throw unknownMethod('integration.install');

      await expectLater(api.installIntegration('codex'), throwsA(isA<HerdrUnsupportedException>()));
    });
  });

  group('agentManifests', () {
    test('lists the agent kinds in herdr order', () async {
      t.on['server.agent_manifests'] = (_) => {
            'type': 'agent_manifest_status',
            'manifests': [
              {'agent': 'pi', 'source_kind': 'remote'},
              {'agent': 'claude'},
              {'source_kind': 'broken'},
            ],
          };

      expect(await api.agentManifests(), ['pi', 'claude']);
    });

    test('is empty on a herdr that does not have the method', () async {
      t.on['server.agent_manifests'] = (_) => throw unknownMethod('server.agent_manifests');

      expect(await api.agentManifests(), isEmpty);
    });

    test('other failures are not swallowed', () async {
      t.on['server.agent_manifests'] = (_) => throw const HerdrTransportException('down');

      await expectLater(api.agentManifests(), throwsA(isA<HerdrTransportException>()));
    });
  });

  group('versions that cannot do it', () {
    test('an unknown method becomes HerdrUnsupportedException, still an HerdrApiException', () async {
      t.on['workspace.create'] = (_) => throw unknownMethod('workspace.create');

      await expectLater(
        api.createWorkspace(cwd: '/x'),
        throwsA(isA<HerdrUnsupportedException>()
            .having((e) => e.method, 'method', 'workspace.create')
            .having((e) => e, 'is api exception', isA<HerdrApiException>())),
      );
    });

    test('a parameter the server does not know is unsupported too', () async {
      t.on['tab.create'] = (_) => throw const HerdrApiException(
            'invalid_request',
            'invalid request: unknown field `env`, expected one of `workspace_id`',
          );

      await expectLater(
        api.createTab(workspaceId: 'w1', env: {'A': '1'}),
        throwsA(isA<HerdrUnsupportedException>()),
      );
    });

    test('a bad value is a plain API error, not "unsupported"', () async {
      t.on['pane.split'] = (_) => throw const HerdrApiException(
            'invalid_request',
            'invalid request: unknown variant `left`, expected `right` or `down`',
          );

      await expectLater(
        api.splitPane(targetPaneId: 'p'),
        throwsA(isA<HerdrApiException>().having((e) => e is HerdrUnsupportedException, 'unsupported', isFalse)),
      );
    });

    test('a vanished workspace, tab or pane reads as not found', () async {
      for (final code in ['workspace_not_found', 'tab_not_found', 'pane_not_found']) {
        expect(HerdrApiException(code, 'x').isNotFound, isTrue, reason: code);
      }
      expect(const HerdrApiException('invalid_request', 'x').isNotFound, isFalse);
    });
  });
}
