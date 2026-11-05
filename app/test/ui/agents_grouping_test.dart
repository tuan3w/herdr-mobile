// What the board lists, derived from the fleet without any widgets.
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/words/elapsed.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart' show AgentStatus;
import 'package:herdr_mobile/data/models/worktrees.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/acp/session_state.dart' show AgentSessionState;
import 'package:herdr_mobile/data/models/status_time.dart';
import 'package:herdr_mobile/data/repositories/attention_set.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:flutter/material.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agents/agent_card.dart' show StateTime;
import 'package:herdr_mobile/ui/features/agents/agents_grouping.dart';

import '../support/fake_agent_session.dart';
import 'ui_harness.dart';

MachineProfile _machine(String id, String label, {bool enabled = true}) =>
    MachineProfile(id: id, label: label, host: '$id.example', username: 'dev', enabled: enabled);

Pane _pane(int i, String status, {String? agent = 'claude'}) => (id: 'w1:p$i', ws: 'w1', agent: agent, status: status);

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
  since: null,
  quietMinutes: 0,
);

void main() {
  group('agent rows', () {
    test('the second line is repo, agent, then machine only when there are several', () async {
      final one = await _fleet(
        {
          'a': [_pane(1, 'working')],
        },
        title: (_) => 'Fix the retry test',
        cwd: (_) => '/src/payments-api',
      );
      final several = await _fleet(
        {
          'a': [_pane(1, 'working')],
          'b': const [],
        },
        title: (_) => 'Fix the retry test',
        cwd: (_) => '/src/payments-api',
      );
      addTearDown(one.dispose);
      addTearDown(several.dispose);

      final solo = AgentsOverview.of(one.fleet).agents.single;
      expect(solo.subtitle, 'payments-api · Claude Code');
      final multi = AgentsOverview.of(several.fleet).agents.single;
      expect(multi.subtitle, 'payments-api · Claude Code · m-a');
    });

    test('a pane with no title is named after its agent, which the line then omits', () async {
      final h = await _fleet(
        {
          'a': [_pane(1, 'idle', agent: 'codex')],
        },
        title: (_) => '',
        cwd: (_) => '/src/main',
      );
      addTearDown(h.dispose);

      final rows = AgentsOverview.of(h.fleet).agents;
      expect(rows.single.title, 'Codex');
      expect(rows.single.subtitle, 'main');
    });

    test('equal data is an equal overview, so an unchanged tab does not rebuild', () async {
      final h = await _fleet({
        'a': [_pane(1, 'blocked'), _pane(2, 'done')],
      });
      addTearDown(h.dispose);

      expect(AgentsOverview.of(h.fleet), AgentsOverview.of(h.fleet));
      expect(AgentsOverview.of(h.fleet).hashCode, AgentsOverview.of(h.fleet).hashCode);
    });
  });

  group('troubled machines', () {
    test('a machine the person disabled is not a problem', () async {
      final h = await _fleet(
        {
          'a': [_pane(1, 'working')],
          'b': [_pane(1, 'working')],
        },
        disabled: {'b'},
      );
      addTearDown(h.dispose);

      expect(h.fleet.connections.last.state, LinkState.disabled);
      expect(AgentsOverview.of(h.fleet).troubled, isEmpty);
    });

    test('one that fails is, with its reason', () async {
      final h = await _fleet({
        'a': [_pane(1, 'working')],
        'b': [_pane(1, 'working')],
      });
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
      expect(worstLinkState([LinkState.offline, LinkState.attention, LinkState.reconnecting]), LinkState.attention);
      expect(worstLinkState([LinkState.offline, LinkState.connecting]), LinkState.connecting);
    });
  });

  group('entries', () {
    late UiHarness h;
    late MachineConnection m;

    BoardLayout layout() => BoardLayout(
      sections: [
        BoardSection(AgentStatus.blocked, [
          PaneItem(_row('1', AgentStatus.blocked, m)),
          PaneItem(_row('2', AgentStatus.blocked, m)),
        ], count: 2),
        BoardSection(AgentStatus.working, [PaneItem(_row('3', AgentStatus.working, m))], count: 1),
        BoardSection(AgentStatus.idle, [PaneItem(_row('4', AgentStatus.idle, m))], count: 1),
      ],
    );

    setUp(() async {
      h = await _fleet({'a': const []});
      m = h.fleet.connections.single;
    });
    tearDown(() => h.dispose());

    test('a header per section, then its rows, the last one of each marked', () {
      final e = boardEntries(layout());
      expect(
        e.map(
          (x) => switch (x) {
            AgentHeader(:final status) => 'h:${status.name}',
            _ => 'r',
          },
        ),
        ['h:blocked', 'r', 'r', 'h:working', 'r', 'h:idle', 'r'],
      );
      expect(
        [
          for (final x in e)
            if (x is AgentLine) x.last,
        ],
        [false, true, true, true],
      );
    });

    test('a folded section keeps its rows in the list, closed; the others stay open', () {
      final e = boardEntries(layout(), collapsed: {AgentStatus.working});
      expect(e.whereType<AgentHeader>().firstWhere((h) => h.status == AgentStatus.working).expanded, isFalse);
      expect([for (final l in e.whereType<AgentLine>()) l.open], [true, true, false, true]);
    });

    test('Needs you has no fold: its rows are open whatever is folded', () {
      final e = boardEntries(layout(), collapsed: {...AgentStatus.values});
      final header = e.first as AgentHeader;
      expect((header.status, header.collapsible, header.expanded), (AgentStatus.blocked, false, true));
      expect(e.whereType<AgentLine>().take(2).every((l) => l.open), isTrue);
    });

    test('only the first waiting agent is a card; every other agent is a row', () {
      final e = boardEntries(layout());
      expect([for (final l in e.whereType<AgentLine>()) l.front], [true, false, false, false]);
    });

    test('keys are unique, and a section keeps its key when others come and go', () {
      final e = boardEntries(layout());
      expect(e.map((x) => x.key).toSet(), hasLength(e.length));

      final without = boardEntries(
        BoardLayout(
          sections: [
            BoardSection(AgentStatus.idle, [PaneItem(_row('4', AgentStatus.idle, m))], count: 1),
          ],
        ),
      );
      const idle = ValueKey('header/idle');
      expect(entryIndexes(without)[idle], 0);
      expect(entryIndexes(e)[idle], 5);
    });

    test('a restored fold of another version folds nothing it does not know, and never Needs you', () {
      expect(foldedSectionsOf(''), isEmpty);
      expect(foldedSectionsOf('a:/r/app\nworking\nblocked\nnonsense'), {AgentStatus.working});
      final both = {AgentStatus.idle, AgentStatus.done};
      expect(foldedSectionsOf(foldedSectionsText(both)), both);
    });

    test('finished work is called To review, the status line\'s words', () {
      expect(sectionLabel(AgentStatus.done), 'To review');
      expect(sectionLabel(AgentStatus.blocked), 'Needs you');
    });
  });

  group('time in state', () {
    test('is minutes, then hours, then days: never seconds', () {
      expect(Elapsed.compact(Duration.zero, seconds: false), '<1m');
      expect(Elapsed.compact(const Duration(seconds: 59), seconds: false), '<1m');
      expect(Elapsed.compact(const Duration(seconds: 60), seconds: false), '1m');
      expect(Elapsed.compact(const Duration(minutes: 12, seconds: 59), seconds: false), '12m');
      expect(Elapsed.compact(const Duration(minutes: 59, seconds: 59), seconds: false), '59m');
      expect(Elapsed.compact(const Duration(hours: 1), seconds: false), '1h');
      expect(Elapsed.compact(const Duration(hours: 1, minutes: 5), seconds: false), '1h 05m');
      expect(Elapsed.compact(const Duration(hours: 23, minutes: 59), seconds: false), '23h 59m');
      expect(Elapsed.compact(const Duration(hours: 24), seconds: false), '1d');
      expect(Elapsed.compact(const Duration(days: 3, hours: 7), seconds: false), '3d');
    });

    test('a clock that stepped back (a set-back device clock) never shows a negative', () {
      expect(Elapsed.compact(const Duration(minutes: -5), seconds: false), '<1m');
    });

    test('is the time only (the glyph says the state); unknown claims nothing', () {
      const d = Duration(minutes: 12);
      expect(timeInState(AgentStatus.working, d), '12m');
      expect(timeInState(AgentStatus.blocked, const Duration(minutes: 3)), '3m');
      expect(timeInState(AgentStatus.done, const Duration(hours: 2)), '2h');
      expect(timeInState(AgentStatus.idle, d), '12m');
      expect(timeInState(AgentStatus.unknown, d), '');
    });

    test('screen readers hear the state and the time in words', () {
      expect(timeInStateWords(AgentStatus.blocked, const Duration(minutes: 4)), 'needs you, 4 minutes');
      expect(timeInStateWords(AgentStatus.done, const Duration(hours: 2), exact: false), 'done, at most 2 hours');
      expect(timeInStateWords(AgentStatus.working, const Duration(seconds: 20)), 'working, under a minute');
      expect(timeInStateWords(AgentStatus.unknown, const Duration(minutes: 4)), '');
    });
  });

  group('Needs you', () {
    test('counts and orders what can be answered; the offline one is listed last, not counted', () async {
      final h = await _fleet({
        'a': [_pane(1, 'blocked'), _pane(2, 'working'), _pane(3, 'blocked')],
        'b': [_pane(4, 'blocked')],
      });
      final attention = AttentionSet(fleet: h.fleet);
      h.fleet.connection('b')!.goOffline();
      final rows = AgentsOverview.of(h.fleet).agents;

      final layout = boardLayout(rows, const [], attention);
      expect(layout.needsYouCount, 2, reason: 'offline "needs you" cannot be answered');
      expect(layout.needsYouOffline, 1);
      expect(
        [for (final i in layout.needsYou) (i as PaneItem).row.key],
        [...attention.needsYou.map((i) => i.key), 'b/w1:p4'],
        reason: 'the set\'s order first, then what is out of reach',
      );
      expect(
        [for (final i in layout.section(AgentStatus.working)!.items) (i as PaneItem).row.key],
        ['a/w1:p2'],
        reason: 'a waiting agent is in Needs you, not also listed elsewhere',
      );
      attention.dispose();
      h.dispose();
    });
  });

  // Owner decision: status sections, Needs you, then working, then finished
  // (to review), then idle, newest first within each.
  group('sections', () {
    final noon = DateTime.utc(2026, 1, 1, 12);
    late UiHarness h;
    late MachineConnection m;
    late AttentionSet attention;

    setUp(() async {
      h = await _fleet({'a': const []});
      m = h.fleet.connections.single;
      attention = AttentionSet(fleet: h.fleet);
    });
    tearDown(() {
      attention.dispose();
      h.dispose();
    });

    AgentRowData at(String key, AgentStatus status, Duration? ago, {bool stale = false}) => (
      key: key,
      machine: m,
      paneId: key,
      status: status,
      title: key,
      subtitle: '',
      stale: stale,
      since: ago == null ? null : StatusTime.exact(noon.subtract(ago)),
      quietMinutes: 0,
    );

    String keyOf(BoardItem i) => switch (i) {
      PaneItem(:final row) => row.key,
      SessionItem(:final session) => session.key,
    };

    List<List<String>> boardOf(BoardLayout l) => [
      for (final s in l.sections) [s.status.name, for (final i in s.items) keyOf(i)],
    ];

    test('in order: Needs you, Working, To review, Idle; empty sections left out', () {
      final layout = boardLayout(
        [
          at('idle', AgentStatus.idle, const Duration(minutes: 5)),
          at('done', AgentStatus.done, const Duration(minutes: 5)),
          at('working', AgentStatus.working, const Duration(minutes: 5)),
        ],
        const [],
        attention,
        now: noon,
      );
      expect([for (final s in layout.sections) s.status], [AgentStatus.working, AgentStatus.done, AgentStatus.idle]);
      expect(boardOrder.take(4), [AgentStatus.blocked, AgentStatus.working, AgentStatus.done, AgentStatus.idle]);
    });

    test('newest first within each section; no known time between the last day and older', () {
      final layout = boardLayout(
        [
          at('w-old', AgentStatus.working, const Duration(hours: 2)),
          at('w-new', AgentStatus.working, const Duration(minutes: 3)),
          at('d-old', AgentStatus.done, const Duration(hours: 5)),
          at('d-new', AgentStatus.done, const Duration(minutes: 1)),
          at('i-3d', AgentStatus.idle, const Duration(days: 3)),
          at('i-undated', AgentStatus.idle, null),
          at('i-12m', AgentStatus.idle, const Duration(minutes: 12)),
          at('i-21h', AgentStatus.idle, const Duration(hours: 21)),
        ],
        const [],
        attention,
        now: noon,
      );
      expect(boardOf(layout), [
        ['working', 'w-new', 'w-old'],
        ['done', 'd-new', 'd-old'],
        ['idle', 'i-12m', 'i-21h', 'i-undated', 'i-3d'],
      ]);
    });

    test('a finished agent moves from Working to the top of To review', () {
      BoardLayout with2(AgentStatus first) => boardLayout(
        [at('a', first, const Duration(minutes: 1)), at('b', AgentStatus.done, const Duration(minutes: 30))],
        const [],
        attention,
        now: noon,
      );
      expect(boardOf(with2(AgentStatus.working)), [
        ['working', 'a'],
        ['done', 'b'],
      ]);
      expect(boardOf(with2(AgentStatus.done)), [
        ['done', 'a', 'b'],
      ]);
    });

    test('To review lists what can be marked before what is out of reach', () {
      final layout = boardLayout(
        [
          at('d-offline', AgentStatus.done, const Duration(minutes: 1), stale: true),
          at('d-live', AgentStatus.done, const Duration(hours: 1)),
        ],
        const [],
        attention,
        now: noon,
      );
      expect(boardOf(layout).single, ['done', 'd-live', 'd-offline']);
    });

    test('sessions share the sections with panes, by when their state began', () {
      FakeAgentSession session(String key, {DateTime? since, DateTime? activity, bool working = false}) {
        return FakeAgentSession(
            key: key,
            machine: m,
            cwd: '',
            state: AgentSessionState('s1', turnActive: working),
          )
          ..phaseSinceValue = since
          ..lastActivity = activity;
      }

      final layout = boardLayout(
        [
          at('p-idle', AgentStatus.idle, const Duration(hours: 2)),
          at('p-work', AgentStatus.working, const Duration(hours: 1)),
        ],
        [
          session('s-idle', activity: noon.subtract(const Duration(minutes: 10))),
          // Working: by when its turn began, not by its last event, which
          // moves with every event and would move the row with it.
          session(
            's-work',
            since: noon.subtract(const Duration(hours: 3)),
            activity: noon.subtract(const Duration(seconds: 1)),
            working: true,
          ),
        ],
        attention,
        now: noon,
      );
      expect(boardOf(layout), [
        ['working', 'p-work', 's-work'],
        ['idle', 's-idle', 'p-idle'],
      ]);
    });
  });

  // Each row says which feature it is: `repo · branch · agent`.
  group('which feature', () {
    // One repo (`app`) with its primary checkout and a linked worktree, and a
    // plain folder.
    const primary = '/r/app';
    const login = '/wt/app-login';
    const workspaces = [(id: 'w1', label: 'app'), (id: 'w2', label: 'app-login'), (id: 'w3', label: 'notes')];

    Future<UiHarness> repoFleet(Map<String, String?> cwd, {List<String> machines = const ['a']}) async {
      final snapshot = snapshotWith(
        [for (final (i, id) in cwd.keys.indexed) (id: id, ws: 'w${i + 1}', agent: 'omp', status: 'idle')],
        workspaces: workspaces,
        title: (id) => 'task ${id.split(':').last}',
      );
      for (final p in snapshot['panes'] as List) {
        final pane = p as Map<String, dynamic>;
        pane['cwd'] = cwd[pane['pane_id']];
      }
      const checkouts = {'w1': (primary, false), 'w2': (login, true)};
      for (final w in snapshot['workspaces'] as List) {
        final ws = w as Map<String, dynamic>;
        if (checkouts[ws['workspace_id']] case (final path, final linked)?) {
          ws['worktree'] = {
            'checkout_path': path,
            'is_linked_worktree': linked,
            'repo_key': '$primary/.git',
            'repo_name': 'app',
            'repo_root': primary,
          };
        }
      }
      final h = await UiHarness.create([
        for (final id in machines)
          (profile: _machine(id, 'm-$id'), snapshot: id == 'a' ? snapshot : snapshotWith(const [])),
      ]);
      // Until the panes are listed, not a fixed 50 turns: in check.sh's one
      // shared engine each turn is slow.
      for (var i = 0; i < 500 && AgentsOverview.of(h.fleet).agents.length < cwd.length; i++) {
        await pumpEventQueue(times: 1);
      }
      return h;
    }

    String whereOf(UiHarness h, String id) =>
        AgentsOverview.of(h.fleet).agents.firstWhere((r) => r.paneId == id).subtitle;

    test('repo, then the checkout\'s folder until its branch is read, then the agent', () async {
      final h = await repoFleet({'w1:p1': primary, 'w2:p2': '$login/lib', 'w3:p3': '/src/notes'});
      addTearDown(h.dispose);

      expect(whereOf(h, 'w1:p1'), 'app · omp', reason: 'the primary checkout\'s folder is the repo\'s own name');
      expect(whereOf(h, 'w2:p2'), 'app · app-login · omp');
      expect(whereOf(h, 'w3:p3'), 'notes · omp', reason: 'a plain folder is its own name');

      h.fleet.connections.single.noteBranches(const [
        WorktreeInfo(path: primary, label: 'app', isLinked: false, branch: 'main'),
        WorktreeInfo(path: login, label: 'app-login', isLinked: true, branch: 'fix/login'),
      ]);
      expect(whereOf(h, 'w1:p1'), 'app · main · omp');
      expect(whereOf(h, 'w2:p2'), 'app · fix/login · omp');
    });

    test('the machine is named only when the board spans several', () async {
      final h = await repoFleet({'w1:p1': primary}, machines: ['a', 'b']);
      addTearDown(h.dispose);
      expect(whereOf(h, 'w1:p1'), 'app · omp · m-a');
    });

    test('a part the title says, or one said already, is left out; no folder at all leaves the agent', () async {
      final h = await _fleet({'a': const []});
      addTearDown(h.dispose);
      final m = h.fleet.connections.single;
      expect(agentWhere(m, '/src/omp', agent: 'omp', title: 'Fix it'), 'omp');
      expect(agentWhere(m, '/src/notes', agent: 'omp', title: 'notes'), 'omp');
      expect(agentWhere(m, null, agent: 'Claude Code'), 'Claude Code');
      expect(agentWhere(m, '/', agent: 'omp'), 'omp');
    });
  });

  group('the idle fold', () {
    late UiHarness h;
    late MachineConnection machine;

    setUp(() async {
      h = await _fleet({'a': const []});
      machine = h.fleet.connections.single;
    });

    tearDown(() => h.dispose());

    BoardLayout board({int idle = 0, int working = 0}) => BoardLayout(
      sections: [
        if (working > 0)
          BoardSection(AgentStatus.working, [
            for (var i = 0; i < working; i++) PaneItem(_row('w$i', AgentStatus.working, machine)),
          ], count: working),
        if (idle > 0)
          BoardSection(AgentStatus.idle, [
            for (var i = 0; i < idle; i++) PaneItem(_row('k$i', AgentStatus.idle, machine)),
          ], count: idle),
      ],
    );

    List<AgentMore> folds(List<AgentEntry> entries) => entries.whereType<AgentMore>().toList();
    List<bool> open(List<AgentEntry> entries) => [
      for (final e in entries)
        if (e is AgentLine) e.open,
    ];

    test('up to a row more than it shows, nothing folds: one hidden row is no saving', () {
      for (final n in [1, idleShown, idleShown + 1]) {
        final e = boardEntries(board(idle: n));
        expect(folds(e), isEmpty, reason: '$n idle');
        expect(open(e), everyElement(isTrue), reason: '$n idle');
      }
    });

    test('past that, the newest idle rows show and the older ones sit behind one line that says how many and what', () {
      final e = boardEntries(board(idle: 9, working: 2));

      expect(open(e), [true, true, ...List.filled(idleShown, true), ...List.filled(4, false)]);
      final more = folds(e).single;
      expect(more.hidden, 4);
      expect(more.status, AgentStatus.idle);
      expect(more.names, ['k5', 'k6'], reason: 'the first two it holds, so it is not a guess');
      expect(more.open, isFalse);
      expect(e.last, more, reason: 'after the section\'s rows');
    });

    test('opened, every row shows and the line reads Show less at the end', () {
      final e = boardEntries(board(idle: 9), idleOpen: true);
      expect(open(e), everyElement(isTrue));
      expect(folds(e).single.open, isTrue);
      expect(e.last, isA<AgentMore>());
    });

    test('a folded section has no fold line, and working rows never fold', () {
      final closed = boardEntries(board(idle: 9), collapsed: {AgentStatus.idle});
      expect(folds(closed), isEmpty);
      expect(open(closed), everyElement(isFalse));
      expect(folds(boardEntries(board(working: 12))), isEmpty);
    });

    // Owner decision, a predictable board: a row the person has seen never
    // slips into the fold while they look.
    test('a row the person has seen stays in view: one that goes idle does not push another into the fold', () {
      final seen = <String>{};
      expect(idleFoldFor(board(idle: 7), seen), {'p:k5', 'p:k6'});

      // An agent stops working: it is the newest idle row, on top.
      final now = BoardLayout(
        sections: [
          BoardSection(AgentStatus.idle, [
            PaneItem(_row('new', AgentStatus.idle, machine)),
            for (var i = 0; i < 7; i++) PaneItem(_row('k$i', AgentStatus.idle, machine)),
          ], count: 8),
        ],
      );
      final e = boardEntries(now, idleFold: idleFoldFor(now, seen));
      expect(open(e), [...List.filled(6, true), false, false], reason: 'k4 did not slip into the fold');
      expect(folds(e).single.hidden, 2);

      final afresh = boardEntries(now, idleFold: idleFoldFor(now, {}));
      expect(folds(afresh).single.hidden, 3, reason: 'looked at afresh, the fold is decided again');
    });

    test('rows the person never saw fold as usual: a machine that connects after the board opened', () {
      final seen = <String>{};
      final one = BoardLayout(
        sections: [
          BoardSection(AgentStatus.idle, [PaneItem(_row('a0', AgentStatus.idle, machine))], count: 1),
        ],
      );
      expect(idleFoldFor(one, seen), isEmpty);
      final nine = BoardLayout(
        sections: [
          BoardSection(AgentStatus.idle, [
            PaneItem(_row('a0', AgentStatus.idle, machine)),
            for (var i = 0; i < 8; i++) PaneItem(_row('b$i', AgentStatus.idle, machine)),
          ], count: 9),
        ],
      );
      expect(idleFoldFor(nine, seen), {'p:b4', 'p:b5', 'p:b6', 'p:b7'});
    });
  });

  // The working glyph does not say quiet, so the row must: a bare `14m` would
  // look like an agent that started 14 minutes ago.
  testWidgets('a quiet working agent says quiet on the row, not only to a screen reader', (tester) async {
    final h = (await tester.runAsync(() => _fleet({'a': const []})))!;
    addTearDown(h.dispose);
    final row = _row('1', AgentStatus.working, h.fleet.connections.single);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: StateTime(
            agent: (
              key: row.key,
              machine: row.machine,
              paneId: row.paneId,
              status: row.status,
              title: row.title,
              subtitle: row.subtitle,
              stale: false,
              since: null,
              quietMinutes: 14,
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('quiet'), findsOneWidget);
    expect(find.textContaining('14m'), findsOneWidget);
  });
}
