import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';

void main() {
  group('unwrapResponse', () {
    test('returns the result object', () {
      final r = unwrapResponse('{"id":"1","result":{"type":"pong","version":"0.8.2"}}');
      expect(r['version'], '0.8.2');
    });

    test('maps an error response to HerdrApiException', () {
      expect(
        () => unwrapResponse(
            '{"id":"1","error":{"code":"pane_not_found","message":"no such pane"}}'),
        throwsA(isA<HerdrApiException>()
            .having((e) => e.code, 'code', 'pane_not_found')
            .having((e) => e.message, 'message', 'no such pane')),
      );
    });

    test('garbage and shape errors are transport errors, not crashes', () {
      for (final bad in ['not json', '[]', '{"id":"1"}', '']) {
        expect(() => unwrapResponse(bad), throwsA(isA<HerdrTransportException>()),
            reason: bad);
      }
    });
  });

  group('Snapshot.fromJson (shape captured from herdr 0.8.2)', () {
    final snap = Snapshot.fromJson({
      'version': '0.8.2',
      'workspaces': [
        {
          'workspace_id': 'wB',
          'number': 1,
          'label': 'research',
          'focused': false,
          'pane_count': 2,
          'tab_count': 1,
          'active_tab_id': 'wB:t1',
          'agent_status': 'working',
        },
      ],
      'tabs': [
        {
          'tab_id': 'wB:t1',
          'workspace_id': 'wB',
          'number': 1,
          'label': '1',
          'focused': false,
          'pane_count': 2,
          'agent_status': 'working',
        },
      ],
      'panes': [
        {
          'pane_id': 'wB:p1',
          'workspace_id': 'wB',
          'tab_id': 'wB:t1',
          'cwd': '/work',
          'foreground_cwd': '/work/sub',
          'agent': 'omp',
          'terminal_title': 'raw',
          'terminal_title_stripped': 'stripped',
          'agent_status': 'blocked',
          'revision': 394,
          'scroll': {'viewport_rows': 28},
        },
        {
          'pane_id': 'wB:p3',
          'workspace_id': 'wB',
          'tab_id': 'wB:t1',
          'cwd': '/work',
          'agent_status': 'unknown',
        },
      ],
    });

    test('parses panes, preferring stripped title and foreground cwd', () {
      final p = snap.panes.first;
      expect(p.title, 'stripped');
      expect(p.cwd, '/work/sub');
      expect(p.status, AgentStatus.blocked);
    });

    test('only panes with a detected agent count as agents', () {
      expect(snap.agentPanes.map((p) => p.id), ['wB:p1']);
    });

    test('round-trips through toJson and the tolerant fromJson', () {
      final copy = Snapshot.fromJson(snap.toJson());
      expect(copy, snap);
      expect(copy.hashCode, snap.hashCode);
      expect(copy.panes.first.cwd, '/work/sub');
      expect(copy.panes.last.agent, isNull);
      expect(copy.workspace('wB')!.status, AgentStatus.working);
      expect(Snapshot.fromJson(Snapshot.empty.toJson()), Snapshot.empty);
    });

    test('navigates workspace → tab → pane', () {
      final tab = snap.tabsOf('wB').single;
      expect(snap.panesOf(tab.id).map((p) => p.id), ['wB:p1', 'wB:p3']);
      expect(snap.workspace('wB')!.label, 'research');
      expect(snap.workspace('nope'), isNull);
    });
  });

  group('value equality', () {
    Map<String, dynamic> pane({int revision = 1, String title = 't'}) => {
          'pane_id': 'w1:p1',
          'workspace_id': 'w1',
          'tab_id': 'w1:t1',
          'terminal_title': title,
          'agent': 'omp',
          'agent_status': 'working',
          'revision': revision,
          'scroll': {'viewport_rows': 20 + revision},
        };

    Snapshot snapshot(List<Map<String, dynamic>> panes) => Snapshot.fromJson({
          'version': '1',
          'workspaces': [
            {'workspace_id': 'w1', 'label': 'a', 'agent_status': 'working'},
          ],
          'tabs': [
            {'tab_id': 'w1:t1', 'workspace_id': 'w1', 'agent_status': 'working'},
          ],
          'panes': panes,
        });

    test('a refetched identical snapshot is equal even if revision churned', () {
      final a = snapshot([pane(revision: 1)]);
      final b = snapshot([pane(revision: 99)]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('any visible field change makes snapshots differ', () {
      final base = snapshot([pane()]);
      expect(snapshot([pane(title: 'spinner')]), isNot(base));
      expect(snapshot([pane(), pane()..['pane_id'] = 'w1:p2']), isNot(base));
      expect(snapshot(const []), isNot(base));
      expect(Snapshot.fromJson({...base.toJson(), 'version': '2'}), isNot(base));
      final moved = base.toJson();
      (moved['workspaces'] as List).first['label'] = 'renamed';
      expect(Snapshot.fromJson(moved), isNot(base));
      final retabbed = base.toJson();
      (retabbed['tabs'] as List).first['pane_count'] = 3;
      expect(Snapshot.fromJson(retabbed), isNot(base));
    });
  });

  test('unknown or missing status values degrade to unknown', () {
    expect(AgentStatus.parse('something-new'), AgentStatus.unknown);
    expect(AgentStatus.parse(null), AgentStatus.unknown);
  });

  test('urgency order puts blocked first, then working, done, idle', () {
    final sorted = [...AgentStatus.values]
      ..sort((a, b) => a.attentionRank.compareTo(b.attentionRank));
    expect(sorted.take(4),
        [AgentStatus.blocked, AgentStatus.working, AgentStatus.done, AgentStatus.idle]);
  });
}
