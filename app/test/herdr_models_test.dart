import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import 'support/fake_transport.dart';

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
      expect(cleanTerminalTitle('π ⠼ Merge Branch To Master Push'),
          'Merge Branch To Master Push');
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
      final s = Pane.fromJson(_wirePane({'agent': 'omp', 'kind': 'path', 'value': path, 'source': 'herdr:omp'})).session!;

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
        {'value': ['x']},
      ]) {
        expect(Pane.fromJson(_wirePane(bad)).session, isNull, reason: '$bad');
      }
      expect(Pane.fromJson(_wirePane()).session, isNull);
    });

    test('the other fields are tolerated when odd', () {
      final s = AgentSessionRef.tryParse({'agent': 3, 'kind': null, 'value': 'x', 'source': [1], 'extra': {}})!;

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
        'panes': [_wirePane({'agent': 'omp', 'kind': 'path', 'value': path})],
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

      for (final (name, spy) in [
        ('workspaces', workspaces),
        ('tabs', tabs),
        ('panes', panes),
        ('agents', agents),
      ]) {
        final wire = (snapshotWireFields[name]! as Map).keys.toSet();
        expect(wire.containsAll(spy.read), isTrue,
            reason: '$name reads ${spy.read.difference(wire)} which is not on the wire');
        // ...and nothing is listed that no model reads.
        expect(spy.read.containsAll(wire), isTrue,
            reason: '$name lists ${wire.difference(spy.read)} but never reads it');
      }
    });

    test('covers every field a pane read is parsed from', () {
      final read = _Spy({});
      PaneRead.fromJson(read);

      expect(paneReadWireFields.keys.toSet(), read.read);
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
