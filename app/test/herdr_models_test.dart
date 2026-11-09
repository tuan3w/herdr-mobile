import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/worktrees.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import 'support/fake_transport.dart';
import 'support/worktree_fixtures.dart';

Pane _pane(String title) => Pane.fromJson({
  'pane_id': 'w1:p1',
  'workspace_id': 'w1',
  'tab_id': 'w1:t1',
  'agent': 'omp',
  'agent_status': 'working',
  'terminal_title_stripped': title,
});

Map<String, dynamic> _wirePane([Object? session = _absent]) => {
  'pane_id': 'w1:p1',
  'workspace_id': 'w1',
  'tab_id': 'w1:t1',
  'agent': 'omp',
  'agent_status': 'idle',
  if (!identical(session, _absent)) 'agent_session': session,
};

const Object _absent = Object();

FleetAgent _agent(Pane pane) {
  final machine = MachineConnection(
    profile: const MachineProfile(id: 'm', label: 'box', host: 'h', username: 'u'),
    api: HerdrApi(FakeTransport()),
  );
  addTearDown(machine.dispose);
  return FleetAgent(machine: machine, pane: pane, workspace: null);
}

void main() {
  group('terminal titles', () {
    // Busy agents animate a braille spinner in the title several times a
    // second. If frames made panes differ, every snapshot would "change",
    // refetching and rebuilding the whole UI for nothing.
    test('spinner frames do not make panes differ', () {
      expect(_pane('π ⠹ Fix the tests'), _pane('π ⠦ Fix the tests'));
      expect(_pane('⠋ Fix the tests').title, 'Fix the tests');
    });

    test('a genuinely different title does', () {
      expect(_pane('π ⠹ Fix the tests'), isNot(_pane('π ⠹ Fix the lint')));
    });

    test('agent chrome is stripped, content kept', () {
      expect(cleanTerminalTitle('π ⠼ Merge Branch To Master Push'), 'Merge Branch To Master Push');
      expect(cleanTerminalTitle('✳ Refactor webhook retry'), 'Refactor webhook retry');
      expect(cleanTerminalTitle('重构支付网关 🚀'), '重构支付网关 🚀');
      expect(cleanTerminalTitle('⠋'), '');
      expect(cleanTerminalTitle(''), '');
    });

    test('cleaning is idempotent, so cached snapshots round-trip', () {
      final once = _pane('π ⠹ Fix the tests');
      expect(Pane.fromJson(once.toJson()), once);
    });
  });

  group('agent session', () {
    const path = '/home/u/.omp/agent/sessions/--work--/2026-01-01_abc.jsonl';

    test('reads the agent, kind, value and source herdr reports', () {
      final s = Pane.fromJson(_wirePane({'agent': 'omp', 'kind': 'path', 'value': path, 'source': 'herdr:omp'}))
          .session!;

      expect((s.agent, s.kind, s.value, s.source), ('omp', 'path', path, 'herdr:omp'));
    });

    test('anything that is not a map with a string value is no session', () {
      for (final bad in <Object?>[
        null,
        'a string',
        42,
        true,
        <Object?>[],
        [path],
        <String, Object?>{},
        {'agent': 'omp', 'kind': 'path'},
        {'value': null},
        {'value': 7},
        {'value': ''},
        {
          'value': ['x'],
        },
      ]) {
        expect(Pane.fromJson(_wirePane(bad)).session, isNull, reason: '$bad');
      }
      expect(Pane.fromJson(_wirePane()).session, isNull);
    });

    test('the other fields are tolerated when odd', () {
      final s = AgentSessionRef.tryParse({
        'agent': 3,
        'kind': null,
        'value': 'x',
        'source': [1],
        'extra': {},
      })!;

      expect((s.agent, s.kind, s.value, s.source), ('', '', 'x', null));
    });

    test('it survives the cache and the copies, and a changed session is a changed pane', () {
      final pane = Pane.fromJson(_wirePane({'agent': 'omp', 'kind': 'path', 'value': path, 'source': 's'}));

      expect(Pane.fromJson(pane.toJson()), pane);
      expect(pane.withStatus(AgentStatus.working).session, pane.session);
      expect(pane.withCompletionSeq(3).session, pane.session);
      expect(Pane.fromJson(_wirePane({'agent': 'omp', 'kind': 'path', 'value': '$path.2'})), isNot(pane));
      expect(Pane.fromJson(_wirePane()), isNot(pane));
    });

    test('a snapshot carries it per pane', () {
      final snap = Snapshot.fromJson({
        'version': '1',
        'workspaces': <Object?>[],
        'tabs': <Object?>[],
        'panes': [
          _wirePane({'agent': 'omp', 'kind': 'path', 'value': path}),
        ],
      });

      expect(snap.panes.single.session!.value, path);
    });

    test('FleetAgent names the log of a path session that is a .jsonl file, and nothing else', () {
      Pane pane(Object? session) => Pane.fromJson(_wirePane(session));
      expect(_agent(pane({'agent': 'omp', 'kind': 'path', 'value': path})).sessionLogPath, path);
      expect(_agent(pane({'agent': 'omp', 'kind': 'id', 'value': 'abc'})).sessionLogPath, isNull);
      expect(_agent(pane({'agent': 'omp', 'kind': 'path', 'value': '/x/session.json'})).sessionLogPath, isNull);
      expect(_agent(pane({'agent': 'omp', 'kind': 'path', 'value': '/x/a.jsonl.bak'})).sessionLogPath, isNull);
      expect(_agent(pane({'value': path})).sessionLogPath, isNull, reason: 'a session that does not say it is a path');
      expect(_agent(pane(null)).sessionLogPath, isNull);
    });

    test('FleetAgent.agentKind prefers what the agent says about its session', () {
      expect(_agent(Pane.fromJson(_wirePane({'agent': 'claude', 'kind': 'id', 'value': 'abc'}))).agentKind, 'claude');
      expect(_agent(Pane.fromJson(_wirePane({'kind': 'id', 'value': 'abc'}))).agentKind, 'omp');
      expect(_agent(Pane.fromJson(_wirePane())).agentKind, 'omp');
    });
  });

  group('snapshot wire projection', () {
    // The mux drops every field of a snapshot that is not in
    // snapshotWireFields before it crosses the network. A model that starts
    // reading another field would silently get null on every real connection.
    test('covers every field the models read', () {
      final panes = _Spy({'pane_id': 'p', 'workspace_id': 'w', 'tab_id': 't'});
      final tabs = _Spy({'tab_id': 't', 'workspace_id': 'w'});
      final workspaces = _Spy({'workspace_id': 'w'});
      final agents = _Spy({'pane_id': 'p', 'completion_seq': 3});
      Snapshot.fromJson({
        'version': '1',
        'workspaces': [workspaces],
        'tabs': [tabs],
        'panes': [panes],
        'agents': [agents],
      });

      for (final (name, spy) in [('workspaces', workspaces), ('tabs', tabs), ('panes', panes), ('agents', agents)]) {
        final wire = (snapshotWireFields[name]! as Map).keys.toSet();
        expect(
          wire.containsAll(spy.read),
          isTrue,
          reason: '$name reads ${spy.read.difference(wire)} which is not on the wire',
        );
        // ...and nothing is listed that no model reads.
        expect(
          spy.read.containsAll(wire),
          isTrue,
          reason: '$name lists ${wire.difference(spy.read)} but never reads it',
        );
      }
    });

    test('a workspace\'s worktree is read from the five keys the wire keeps', () {
      final worktree = _Spy({...wireLinkedWorktree});
      Workspace.fromJson({'workspace_id': 'w', 'worktree': worktree});

      final wire = ((snapshotWireFields['workspaces']! as Map)['worktree']! as Map).keys.toSet();
      expect(wire, worktree.read);
    });

    test('covers every field a pane read is parsed from', () {
      final read = _Spy({});
      PaneRead.fromJson(read);

      expect(paneReadWireFields.keys.toSet(), read.read);
    });
  });

  group('workspace worktree', () {
    Workspace parse(Object? worktree) => Workspace.fromJson(wireWorkspace('w1', worktree: worktree));

    test('is read, survives the disk cache and a status roll-up', () {
      final w = parse(wireLinkedWorktree);

      expect(w.worktree!.isLinked, isTrue);
      expect(w.worktree!.checkoutPath, wireLinkedWorktree['checkout_path']);
      expect(Workspace.fromJson(w.toJson()), w);
      expect(w.withStatus(AgentStatus.blocked).worktree, w.worktree);
      expect(parse(wirePrimaryWorktree), isNot(w));
    });

    test('null or a malformed map leaves a plain workspace, never drops it', () {
      expect(parse(null).worktree, isNull);
      expect(parse('x').worktree, isNull);
      expect(parse({...wireLinkedWorktree, 'checkout_path': ''}).worktree, isNull);
      expect(parse({...wireLinkedWorktree}..remove('repo_name')).worktree, isNull);
      expect(parse({...wireLinkedWorktree, 'repo_key': 3}).id, 'w1');
    });

    test('a checkout that went detached stops showing its old branch', () {
      final machine = MachineConnection(
        profile: const MachineProfile(id: 'm', label: 'box', host: 'h', username: 'u'),
        api: HerdrApi(FakeTransport()),
      );
      addTearDown(machine.dispose);
      const path = '/r/wt';
      machine.noteBranches([const WorktreeInfo(path: path, label: 'x', isLinked: true, branch: 'feat/x')]);
      expect(machine.branchOf(path), 'feat/x');

      machine.noteBranches([const WorktreeInfo(path: path, label: 'x', isLinked: true, isDetached: true)]);
      expect(machine.branchOf(path), isNull);
    });
  });

  group('host metadata', () {
    Map<String, dynamic> pane(Map<String, dynamic> extra) => {..._wirePane(), ...extra};

    test('tokens are kept in key order, whatever order herdr sent them in', () {
      final w = Workspace.fromJson({
        ...wireWorkspace('w1'),
        'tokens': {'stage': '🤖 building 24/165 ↻2', 'row': 'some-feature'},
      });
      expect(w.tokens.keys, ['row', 'stage']);

      // herdr's map is a Rust HashMap: the next snapshot may list it the other way.
      final reversed = Workspace.fromJson({
        ...wireWorkspace('w1'),
        'tokens': {'row': 'some-feature', 'stage': '🤖 building 24/165 ↻2'},
      });
      expect(reversed, w);
      expect(reversed.hashCode, w.hashCode);
      expect(w, isNot(Workspace.fromJson(wireWorkspace('w1'))), reason: 'a token change is a change');
    });

    test('host text is one safe line: no bidi override, no newline, nothing empty', () {
      final w = Workspace.fromJson({
        ...wireWorkspace('w1'),
        'tokens': {'evil': 'build \u202Eok\u202C\nnext  line', 'empty': '  \n ', 'odd': 42},
      });
      expect(w.tokens, {'evil': 'build ok next line'});
    });

    test('the name the person gave wins over a hook\'s title, which wins over the terminal\'s', () {
      expect(Pane.fromJson(pane({'title': 'Hook title', 'label': 'Mine', 'terminal_title': 'zsh'})).title, 'Mine');
      expect(Pane.fromJson(pane({'title': 'Hook title', 'terminal_title': 'zsh'})).title, 'Hook title');
      expect(Pane.fromJson(pane({'terminal_title': 'zsh'})).title, 'zsh');
    });

    test('a hook\'s title is never generic, so a session name never replaces it', () {
      expect(_agent(Pane.fromJson(pane({'terminal_title': 'omp'}))).hasGenericTitle, isTrue);
      expect(_agent(Pane.fromJson(pane({'title': 'omp', 'terminal_title': 'omp'}))).hasGenericTitle, isFalse);
    });

    test('survives the launch cache and the status and completion copies', () {
      final p = Pane.fromJson(
        pane({
          'title': 'Migrate the ledger',
          'display_agent': 'Codex (gpt-5.5 high)',
          'state_labels': {'working': 'Running tests'},
          'tokens': {'ci': '142/165'},
          'restore_error': 'Saved directory is unavailable.',
        }),
      );
      expect(Pane.fromJson(p.toJson()), p);
      final copied = p.withStatus(AgentStatus.blocked).withCompletionSeq(4);
      expect(copied.metadataTitle, p.metadataTitle);
      expect(copied.displayAgent, p.displayAgent);
      expect(copied.stateLabels, p.stateLabels);
      expect(copied.tokens, p.tokens);
      expect(copied.restoreError, p.restoreError);

      final w = Workspace.fromJson({
        ...wireWorkspace('w1'),
        'tokens': {'stage': 'building'},
      });
      expect(Workspace.fromJson(w.toJson()), w);
      expect(w.withStatus(AgentStatus.blocked).tokens, w.tokens);
    });
  });
}

/// A map that notes which keys were looked up.
class _Spy extends MapBase<String, dynamic> {
  _Spy(this._m);

  final Map<String, dynamic> _m;
  final read = <String>{};

  @override
  dynamic operator [](Object? key) {
    read.add(key! as String);
    return _m[key];
  }

  @override
  void operator []=(String key, dynamic value) => _m[key] = value;

  @override
  void clear() => _m.clear();

  @override
  Iterable<String> get keys => _m.keys;

  @override
  dynamic remove(Object? key) => _m.remove(key);
}
