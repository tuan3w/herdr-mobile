// What the agents tab lists, derived from the fleet without any widgets.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart' show AgentStatus;
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/features/agents/agents_grouping.dart';

import 'ui_harness.dart';

MachineProfile _machine(String id, String label, {bool enabled = true}) => MachineProfile(
      id: id,
      label: label,
      host: '$id.example',
      username: 'dev',
      enabled: enabled,
    );

Pane _pane(int i, String status, {String? agent = 'claude'}) =>
    (id: 'w1:p$i', ws: 'w1', agent: agent, status: status);

Future<UiHarness> _fleet(
  Map<String, List<Pane>> machines, {
  Set<String> disabled = const {},
  String Function(String)? title,
  String Function(String)? cwd,
}) async {
  final h = await UiHarness.create([
    for (final MapEntry(:key, :value) in machines.entries)
      (
        profile: _machine(key, 'm-$key', enabled: !disabled.contains(key)),
        snapshot: snapshotWith(value, title: title, cwd: cwd),
      ),
  ]);
  await pumpEventQueue(times: 50);
  return h;
}

AgentRowData _row(String key, AgentStatus status, MachineConnection machine) => (
      key: key,
      machine: machine,
      paneId: key,
      status: status,
      title: key,
      subtitle: '',
      stale: false,
    );

void main() {
  group('agent rows', () {
    test('the second line is kind, machine, workspace, folder; one machine is not named',
        () async {
      final one = await _fleet(
        {'a': [_pane(1, 'working')]},
        title: (_) => 'Fix the retry test',
        cwd: (_) => '/src/payments-api',
      );
      final several = await _fleet(
        {'a': [_pane(1, 'working')], 'b': const []},
        title: (_) => 'Fix the retry test',
        cwd: (_) => '/src/payments-api',
      );
      addTearDown(one.dispose);
      addTearDown(several.dispose);

      final solo = AgentsOverview.of(one.fleet).agents.single;
      expect(solo.subtitle, 'claude · main · payments-api');
      final multi = AgentsOverview.of(several.fleet).agents.single;
      expect(multi.subtitle, 'claude · m-a · main · payments-api');
    });

    test('a pane with no title is named after its agent, which the line then omits',
        () async {
      final h = await _fleet(
        {'a': [_pane(1, 'idle', agent: 'codex')]},
        title: (_) => '',
        cwd: (_) => '/src/main',
      );
      addTearDown(h.dispose);

      final rows = AgentsOverview.of(h.fleet).agents;
      expect(rows.single.title, 'codex');
      expect(rows.single.subtitle, 'main', reason: 'workspace and folder are the same name');
    });

    test('equal data is an equal overview, so an unchanged tab does not rebuild', () async {
      final h = await _fleet({'a': [_pane(1, 'blocked'), _pane(2, 'done')]});
      addTearDown(h.dispose);

      expect(AgentsOverview.of(h.fleet), AgentsOverview.of(h.fleet));
      expect(AgentsOverview.of(h.fleet).hashCode, AgentsOverview.of(h.fleet).hashCode);
    });
  });

  group('troubled machines', () {
    test('a machine the person disabled is not a problem', () async {
      final h = await _fleet(
        {'a': [_pane(1, 'working')], 'b': [_pane(1, 'working')]},
        disabled: {'b'},
      );
      addTearDown(h.dispose);

      expect(h.fleet.connections.last.state, LinkState.disabled);
      expect(AgentsOverview.of(h.fleet).troubled, isEmpty);
    });

    test('one that fails is, with its reason', () async {
      final h = await _fleet({'a': [_pane(1, 'working')], 'b': [_pane(1, 'working')]});
      addTearDown(h.dispose);
      h.transports['b']!.failure = HerdrTransportException('Host key changed', fatal: true);
      h.fleet.connections.last.reconnect();
      await pumpEventQueue(times: 50);

      final troubled = AgentsOverview.of(h.fleet).troubled.single;
      expect(troubled.label, 'm-b');
      expect(troubled.state, LinkState.attention);
      expect(troubled.error, 'Host key changed');
    });

    test('the worst state colours a summary', () {
      expect(
        worstLinkState([LinkState.offline, LinkState.attention, LinkState.reconnecting]),
        LinkState.attention,
      );
      expect(
        worstLinkState([LinkState.offline, LinkState.connecting]),
        LinkState.connecting,
      );
    });
  });

  group('entries', () {
    late UiHarness h;
    late MachineConnection m;
    late Map<AgentStatus, List<AgentRowData>> groups;

    setUp(() async {
      h = await _fleet({'a': const []});
      m = h.fleet.connections.single;
      groups = groupByStatus([
        _row('1', AgentStatus.blocked, m),
        _row('2', AgentStatus.blocked, m),
        _row('3', AgentStatus.working, m),
        _row('4', AgentStatus.idle, m),
      ]);
    });
    tearDown(() => h.dispose());

    test('groups are in urgency order and empty ones are left out', () {
      expect(groups.keys, [AgentStatus.blocked, AgentStatus.working, AgentStatus.idle]);
    });

    test('a header per group, then its rows, the last one marked', () {
      final e = agentEntries(groups);
      expect(e.map((x) => x is AgentHeader ? 'h' : 'r'), ['h', 'r', 'r', 'h', 'r', 'h', 'r']);
      expect([for (final x in e) if (x is AgentLine) x.last], [false, true, true, true]);
    });

    test('a filter keeps one group; one whose group is gone keeps all', () {
      final one = agentEntries(groups, filter: AgentStatus.working);
      expect(one.whereType<AgentHeader>().map((h) => h.status), [AgentStatus.working]);
      final all = agentEntries(groups, filter: AgentStatus.done);
      expect(all.whereType<AgentHeader>(), hasLength(3));
    });

    test('a collapsed group keeps its rows in the list, closed', () {
      final e = agentEntries(groups, collapsed: {AgentStatus.blocked});
      final header = e.whereType<AgentHeader>().first;
      expect(header.expanded, isFalse);
      final lines = e.whereType<AgentLine>().toList();
      expect(lines.take(2).every((l) => !l.open), isTrue);
      expect(lines.skip(2).every((l) => l.open), isTrue);
    });

    test('keys are unique, and a group keeps its key when others come and go', () {
      final e = agentEntries(groups);
      expect(e.map((x) => x.key).toSet(), hasLength(e.length));

      final without = agentEntries(groupByStatus([_row('3', AgentStatus.working, m)]));
      expect(without.first.key, ValueKey(AgentStatus.working));
      expect(entryIndexes(without)[ValueKey(AgentStatus.working)], 0);
      expect(entryIndexes(e)[ValueKey(AgentStatus.working)], 3);
    });
  });

  group('time in state', () {
    test('is minutes, then hours, then days: never seconds', () {
      expect(formatElapsed(Duration.zero), '<1m');
      expect(formatElapsed(const Duration(seconds: 59)), '<1m');
      expect(formatElapsed(const Duration(seconds: 60)), '1m');
      expect(formatElapsed(const Duration(minutes: 12, seconds: 59)), '12m');
      expect(formatElapsed(const Duration(minutes: 59, seconds: 59)), '59m');
      expect(formatElapsed(const Duration(hours: 1)), '1h');
      expect(formatElapsed(const Duration(hours: 1, minutes: 5)), '1h 05m');
      expect(formatElapsed(const Duration(hours: 23, minutes: 59)), '23h 59m');
      expect(formatElapsed(const Duration(hours: 24)), '1d');
      expect(formatElapsed(const Duration(days: 3, hours: 7)), '3d');
    });

    test('a clock that stepped back (a set-back device clock) never shows a negative', () {
      expect(formatElapsed(const Duration(minutes: -5)), '<1m');
    });

    test('is a state word and a duration; unknown has no word to say', () {
      const d = Duration(minutes: 12);
      expect(timeInState(AgentStatus.working, d), 'working 12m');
      expect(timeInState(AgentStatus.blocked, const Duration(minutes: 3)), 'needs you 3m');
      expect(timeInState(AgentStatus.done, const Duration(hours: 2)), 'done 2h');
      expect(timeInState(AgentStatus.idle, d), 'idle 12m');
      expect(timeInState(AgentStatus.unknown, d), '');
    });
  });

  group('triage list', () {
    test('keeps blocked agents that can be reached, in board order', () async {
      final h = await _fleet({'a': [_pane(1, 'blocked'), _pane(2, 'working'), _pane(3, 'blocked')]});
      final m = h.fleet.connections.single;
      AgentRowData row(String k, AgentStatus s, {bool stale = false}) =>
          (key: k, machine: m, paneId: k, status: s, title: k, subtitle: '', stale: stale);

      final list = blockedAgents([
        row('1', AgentStatus.blocked),
        row('2', AgentStatus.working),
        row('3', AgentStatus.blocked, stale: true),
        row('4', AgentStatus.blocked),
      ]);
      expect(list.map((a) => a.key), ['1', '4'], reason: 'offline "needs you" cannot be answered');
      h.dispose();
    });
  });
}
