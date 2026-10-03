import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/repositories/new_session_settings.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/features/create/new_session_view_model.dart';

import 'support/create_harness.dart';
import 'support/fake_transport.dart';
import 'support/herdr_stub.dart';

Map<String, dynamic> _snapshot({List<({String id, String? agent, String cwd})> panes = const []}) {
  final json = snapshotJson(
    workspaces: const [(id: 'w1', label: 'main')],
    panes: [for (final p in panes) (id: p.id, ws: 'w1', agent: p.agent, status: 'idle')],
  );
  for (final p in json['panes'] as List) {
    final m = p as Map<String, dynamic>;
    m['cwd'] = panes.firstWhere((x) => x.id == m['pane_id']).cwd;
  }
  return json;
}

/// A harness with two online machines (`a`, `b`) and one that is off (`off`).
Future<CreateHarness> _two({Map<String, dynamic>? a, Map<String, dynamic>? b}) async {
  final h = await CreateHarness.create([
    (profile: profileOf('a', 'workstation'), snapshot: a ?? snapshotJson()),
    (profile: profileOf('b', 'laptop'), snapshot: b ?? snapshotJson()),
    (profile: profileOf('off', 'staging', enabled: false), snapshot: snapshotJson()),
  ]);
  addTearDown(h.dispose);
  for (final t in h.stubs.values) {
    t.on['workspace.create'] = (params) {
      addWorkspaceTo(t.snapshot, label: params['label'] as String? ?? '', cwd: params['cwd'] as String? ?? '/home/u');
      return workspaceCreated(cwd: params['cwd'] as String? ?? '/home/u');
    };
    t.on['server.agent_manifests'] = (_) => {
          'manifests': [
            {'agent': 'pi'},
            {'agent': 'claude'},
          ],
        };
  }
  return h;
}

NewSessionViewModel _vm(CreateHarness h, {String? machineId, Duration? manifestTimeout}) {
  final vm = NewSessionViewModel(
    fleet: h.fleet,
    settings: h.settings,
    machineId: machineId,
    manifestTimeout: manifestTimeout ?? const Duration(seconds: 4),
  );
  addTearDown(vm.dispose);
  return vm;
}

void main() {
  group('input checks', () {
    test('a folder is required and must be absolute or under ~', () {
      expect(folderError(''), isNotNull);
      expect(folderError('   '), isNotNull);
      expect(folderError('code/app'), isNotNull, reason: 'herdr would silently open the home folder');
      expect(folderError('~user/app'), isNotNull);
      expect(folderError('/srv/app'), isNull);
      expect(folderError('  /srv/my app  '), isNull);
      expect(folderError('~'), isNull);
      expect(folderError('~/code'), isNull);
    });

    test('a ~ folder is typed into a shell, so no line breaks or control characters', () {
      expect(folderError('~/a\nrm -rf /'), isNotNull);
      expect(folderError('/srv/a\u0007b'), isNotNull);
    });

    test('a command is one non-empty line', () {
      expect(commandError(''), isNotNull);
      expect(commandError('claude'), isNull);
      expect(commandError('claude --resume'), isNull);
      expect(commandError('claude\nrm -rf /'), isNotNull);
      expect(commandError('claude\r'), isNull, reason: 'trailing whitespace is trimmed');
      expect(commandError('a\rb'), isNotNull);
    });

    test('the default workspace name is the folder name', () {
      expect(defaultWorkspaceName('/work/payments-api'), 'payments-api');
      expect(defaultWorkspaceName('/work/payments-api/'), 'payments-api');
      expect(defaultWorkspaceName('~'), 'home');
      expect(defaultWorkspaceName('~/code/ứng dụng'), 'ứng dụng');
      expect(defaultWorkspaceName('/'), 'root');
    });
  });

  test('recent folders: distinct, absolute, agents first, capped', () {
    final snap = Snapshot.fromJson(_snapshot(panes: [
      (id: 'p1', agent: null, cwd: '/work/shell-only'),
      (id: 'p2', agent: 'claude', cwd: '/work/app'),
      (id: 'p3', agent: 'codex', cwd: '/work/app'),
      (id: 'p4', agent: null, cwd: '/'),
      (id: 'p5', agent: null, cwd: '/work/app'),
      for (var i = 0; i < 12; i++) (id: 'q$i', agent: null, cwd: '/work/many$i'),
    ]));

    final recent = recentFolders(snap);

    expect(recent.take(2), ['/work/app', '/work/shell-only']);
    expect(recent, hasLength(maxRecentFolders));
    expect(recent.toSet(), hasLength(recent.length));
    expect(recent, isNot(contains('/')));
  });

  group('what is remembered', () {
    test('survives a restart, per machine and per agent', () async {
      final store = MemoryNewSessionStore();
      final first = NewSessionSettings(store);
      await first.remember(machineId: 'a', kind: 'claude', command: 'claude --resume');
      await first.remember(machineId: 'b', kind: '');

      final second = NewSessionSettings(store);
      await second.load();

      expect(second.lastMachineId, 'b');
      expect(second.kindFor('a'), 'claude');
      expect(second.kindFor('b'), '', reason: 'a plain shell is remembered too');
      expect(second.kindFor('c'), isNull);
      expect(second.commandFor('a', 'claude'), 'claude --resume');
      expect(second.commandFor('b', 'claude'), isNull);
    });

    test('a command equal to its default is forgotten, so the default can move on', () async {
      final s = NewSessionSettings(MemoryNewSessionStore());
      await s.remember(machineId: 'a', kind: 'claude', command: 'claude --resume');
      await s.remember(machineId: 'a', kind: 'claude', command: 'claude');

      expect(s.commandFor('a', 'claude'), isNull);
    });

    test('unreadable saved data starts empty instead of failing', () async {
      expect(NewSessionMemory.fromJson('nonsense').machineId, isNull);
      final odd = NewSessionMemory.fromJson({'machine': 3, 'kinds': 'x', 'commands': {'a': 5}});
      expect(odd.machineId, isNull);
      expect(odd.kinds, isEmpty);
      expect(odd.commands, isEmpty);
      final s = NewSessionSettings(_ThrowingStore());
      await s.load();
      expect(s.lastMachineId, isNull);
    });
  });

  group('machines', () {
    test('only online machines can be picked', () async {
      final h = await _two();

      expect(_vm(h).machines.map((c) => c.profile.id), ['a', 'b']);
    });

    test('the machine used last is preselected, else the first online one', () async {
      final h = await _two();
      expect(_vm(h).machine!.profile.id, 'a');

      await h.settings.remember(machineId: 'b', kind: '');
      expect(_vm(h).machine!.profile.id, 'b');

      await h.settings.remember(machineId: 'off', kind: '');
      expect(_vm(h).machine!.profile.id, 'a', reason: 'the last one is offline');
    });

    test('a machine asked for beats the one used last, unless it is offline', () async {
      final h = await _two();
      await h.settings.remember(machineId: 'a', kind: '');

      expect(_vm(h, machineId: 'b').machine!.profile.id, 'b');
      expect(_vm(h, machineId: 'off').machine!.profile.id, 'a');
    });

    test('the chosen machine going offline is noticed, and nothing starts on it', () async {
      final h = await _two();
      final vm = _vm(h);
      var notified = 0;
      vm.addListener(() => notified++);

      h.connection('a').goOffline();

      expect(vm.machine, isNull);
      expect(vm.machineLost, isTrue);
      expect(notified, greaterThan(0));
      expect(await vm.start(const NewSessionValues(folder: '/srv')), isNull);
      expect(vm.error, isNotNull);
      expect(h.stubs['a']!.methods, isEmpty);
    });

    test('unrelated fleet changes do not rebuild the form', () async {
      final h = await _two();
      final vm = _vm(h);
      await eventually(() => !vm.loadingKinds);
      var notified = 0;
      vm.addListener(() => notified++);

      h.stubs['b']!.snapshot = _snapshot(panes: [(id: 'p1', agent: 'claude', cwd: '/elsewhere')]);
      await h.connection('b').refresh();

      expect(notified, 0, reason: 'machine b has nothing to do with the form on a');
    });

    test('recent folders come from the chosen machine only', () async {
      final h = await _two(
        a: _snapshot(panes: [(id: 'p1', agent: 'claude', cwd: '/work/on-a')]),
        b: _snapshot(panes: [(id: 'p1', agent: 'claude', cwd: '/work/on-b')]),
      );
      final vm = _vm(h);

      expect(vm.recent, ['/work/on-a']);
      vm.selectMachine('b');
      expect(vm.recent, ['/work/on-b']);
    });
  });

  group('what to start', () {
    test('the agents come from herdr, Shell is separate', () async {
      final h = await _two();
      final vm = _vm(h);
      expect(vm.kinds, fallbackAgentKinds, reason: 'until herdr answers');

      await eventually(() => vm.kinds.contains('pi'));

      expect(vm.kinds, ['pi', 'claude']);
      expect(vm.kind, isNull);
    });

    test('an old herdr without manifests gets the fallback list', () async {
      final h = await _two();
      h.stubs['a']!.on['server.agent_manifests'] = (_) => throw unknownMethod('server.agent_manifests');
      final vm = _vm(h);

      await eventually(() => !vm.loadingKinds);

      expect(vm.kinds, fallbackAgentKinds);
    });

    test('a herdr that never answers cannot hold the form hostage', () async {
      final h = await _two();
      h.stubs['a']!.on['server.agent_manifests'] = (_) => Completer<Map<String, dynamic>>().future;
      final vm = _vm(h, manifestTimeout: const Duration(milliseconds: 50));

      await eventually(() => !vm.loadingKinds);

      expect(vm.kinds, fallbackAgentKinds);
    });

    test('the agent used last on a machine is preselected, with its edited command', () async {
      final h = await _two();
      await h.settings.remember(machineId: 'a', kind: 'claude', command: 'claude --resume');
      await h.settings.remember(machineId: 'b', kind: 'codex');
      final vm = _vm(h, machineId: 'a');

      expect(vm.kind, 'claude');
      expect(vm.commandFor('claude'), 'claude --resume');
      expect(vm.commandFor('codex'), 'codex', reason: 'its own name until edited');

      vm.selectMachine('b');
      expect(vm.kind, 'codex');
      expect(vm.commandFor('claude'), 'claude', reason: 'the edit was for machine a');
    });

    test('an agent herdr does not list stays selectable when it was the last one used', () async {
      final h = await _two();
      await h.settings.remember(machineId: 'a', kind: 'my-agent');
      final vm = _vm(h);
      await eventually(() => vm.kinds.contains('pi'));

      expect(vm.kinds, contains('my-agent'));
    });
  });

  group('start', () {
    test('creates the workspace, types the command, and remembers the choice', () async {
      final h = await _two();
      final vm = _vm(h)..selectKind('claude');
      final t = h.stubs['a']!;

      final launch = await vm.start(const NewSessionValues(
        folder: '  /work/payments-api ',
        name: '',
        command: ' claude --resume ',
      ));

      expect(launch, isNotNull);
      expect(launch!.paneId, 'wN:p1');
      expect(launch.notice, isNull);
      expect(vm.error, isNull);
      expect(t.methods, ['workspace.create', 'pane.send_input']);
      expect(t.paramsOf('workspace.create').single, {
        'cwd': '/work/payments-api',
        'label': 'payments-api',
        'focus': false,
      });
      expect(t.paramsOf('pane.send_input').single, {
        'pane_id': 'wN:p1',
        'text': 'claude --resume',
        'keys': ['enter'],
      });
      expect(h.settings.lastMachineId, 'a');
      expect(h.settings.kindFor('a'), 'claude');
      expect(h.settings.commandFor('a', 'claude'), 'claude --resume');
      expect(h.store.memory.machineId, 'a', reason: 'written to the store, not only held in memory');
    });

    test('a typed name wins over the folder name; a shell has no command', () async {
      final h = await _two();
      final vm = _vm(h);
      final t = h.stubs['a']!;

      await vm.start(const NewSessionValues(folder: '/work/app', name: ' Tôi yêu Việt Nam ', command: 'ignored'));

      expect(t.methods, ['workspace.create']);
      expect(t.paramsOf('workspace.create').single['label'], 'Tôi yêu Việt Nam');
      expect(h.settings.kindFor('a'), '');
    });

    test('the first message is handed to the launcher for later', () async {
      final h = await _two();
      final vm = _vm(h)..selectKind('claude');

      final launch = await vm.start(const NewSessionValues(
        folder: '/work/app',
        command: 'claude',
        prompt: ' fix the build ',
      ));

      expect(launch!.prompt, isNotNull);
      expect(h.stubs['a']!.paramsOf('pane.send_input'), hasLength(1), reason: 'not before the agent is up');
    });

    test('nothing is sent for a bad form', () async {
      final h = await _two();
      final vm = _vm(h)..selectKind('claude');
      final t = h.stubs['a']!;

      expect(await vm.start(const NewSessionValues(folder: '', command: 'claude')), isNull);
      expect(vm.error, isNotNull);
      expect(await vm.start(const NewSessionValues(folder: '/srv', command: 'claude\nreboot')), isNull);
      expect(await vm.start(const NewSessionValues(folder: '/srv', command: '  ')), isNull);
      expect(t.methods, isEmpty);
    });

    test('the busy state spans the launch and a second tap does nothing', () async {
      final h = await _two();
      final vm = _vm(h);
      final t = h.stubs['a']!;
      final gate = Completer<void>();
      final inner = t.on['workspace.create']!;
      t.on['workspace.create'] = (p) async {
        await gate.future;
        return inner(p);
      };

      final first = vm.start(const NewSessionValues(folder: '/srv'));
      expect(vm.busy, isTrue);
      expect(await vm.start(const NewSessionValues(folder: '/srv')), isNull);
      gate.complete();
      await first;

      expect(vm.busy, isFalse);
      expect(t.paramsOf('workspace.create'), hasLength(1));
    });

    test('an old herdr is told apart, with the machine and its version', () async {
      final h = await _two();
      final vm = _vm(h);
      h.stubs['a']!.on['workspace.create'] = (_) => throw unknownMethod('workspace.create');

      expect(await vm.start(const NewSessionValues(folder: '/srv')), isNull);

      expect(vm.error!.title, contains('Not supported'));
      expect(vm.error!.message, allOf(contains('workstation'), contains('9.9.9')));
      expect(vm.busy, isFalse);
    });

    test('a missing folder says which one and where', () async {
      final h = await _two();
      final vm = _vm(h);
      h.stubs['a']!.on['workspace.create'] = (_) => workspaceCreated(cwd: '/home/u');

      expect(await vm.start(const NewSessionValues(folder: '/work/typo')), isNull);

      expect(vm.error!.title, 'Folder not found');
      expect(vm.error!.message, allOf(contains('/work/typo'), contains('workstation')));
      expect(h.settings.lastMachineId, isNull, reason: 'a failed start is not "used"');
    });

    test('a connection problem shows its own message', () async {
      final h = await _two();
      final vm = _vm(h);
      h.stubs['a']!.on['workspace.create'] = (_) => throw const HerdrTransportException('SSH connection lost');

      expect(await vm.start(const NewSessionValues(folder: '/srv')), isNull);

      expect(vm.error!.message, 'SSH connection lost');
    });

    test('the command failing still opens the workspace, with a notice', () async {
      final h = await _two();
      final vm = _vm(h)..selectKind('claude');
      h.stubs['a']!.on['pane.send_input'] = (_) => throw const HerdrApiException('pane_send_failed', 'pty closed');

      final launch = await vm.start(const NewSessionValues(folder: '/srv', command: 'claude'));

      expect(launch, isNotNull, reason: 'the workspace exists: open it');
      expect(launch!.notice, allOf(contains('workspace was created'), contains('pty closed')));
      expect(launch.prompt, isNull);
      expect(vm.error, isNull);
    });

    test('editing the form clears the error', () async {
      final h = await _two();
      final vm = _vm(h);
      await vm.start(const NewSessionValues(folder: ''));
      expect(vm.error, isNotNull);

      vm.dismissError();

      expect(vm.error, isNull);
    });
  });
}

class _ThrowingStore implements NewSessionStore {
  @override
  Future<NewSessionMemory> read() => throw StateError('disk');

  @override
  Future<void> write(NewSessionMemory memory) => throw StateError('disk');
}
