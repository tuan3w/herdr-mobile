// The board through the real shell: its status sections and their folds,
// connection notices and the states around an empty or failing fleet.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agents/agent_card.dart';
import 'package:herdr_mobile/ui/features/agents/agents_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machines_screen.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../support/shot.dart' show loadAppFonts;
import 'ui_harness.dart';

MachineProfile _machine(String id, String label) =>
    MachineProfile(id: id, label: label, host: '$id.example', username: 'dev');

Pane _pane(int i, String status, {String? agent = 'claude'}) => (id: 'w1:p$i', ws: 'w1', agent: agent, status: status);

/// A status change event: herdr refreshes after a short delay, not the
/// 1.5 s churn spacing of title and cwd updates.
const _statusEvent = {'event': 'pane.agent_status_changed'};

/// Replaces what machine `a` reports and tells the connection it changed.
void _push(UiHarness h, List<Pane> panes) {
  h.transports['a']!.snapshot = snapshotWith(panes, title: (id) => 'task ${id.split('p').last}');
  h.transports['a']!.emit(_statusEvent);
}

/// An agent on the board, the card in front or a row.
Finder _row(String title) => find.ancestor(
  of: find.text(title),
  matching: find.byWidgetPredicate((w) => w is AgentCard || w is AgentCompactRow),
);

/// A section's header, by status name (`working`, `idle`).
Finder _section(String status) => find.byKey(ValueKey('header/$status'));

/// The card's tappable body: one semantics node reading the whole card.
Finder _body(String title) => find.descendant(of: _row(title), matching: find.byType(PressBuilder)).first;

/// Tall enough to build every agent of a small fleet at once.
const _tall = 2400.0;

/// Makes every machine fail like a rejected login, so each becomes a notice.
Future<void> _failAll(WidgetTester tester, UiHarness h, String error) async {
  for (final t in h.transports.values) {
    t.failure = HerdrTransportException(error, fatal: true);
  }
  for (final c in h.fleet.connections) {
    c.reconnect();
  }
  await settle(tester);
}

void main() {
  setUpAll(loadAppFonts);

  group('sections', () {
    testWidgets('Needs you, then Working, then Idle; a section folds, Needs you stays', (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'workstation'),
          snapshot: snapshotWith([
            _pane(1, 'idle'),
            _pane(2, 'working'),
            _pane(3, 'blocked'),
          ], title: (id) => 'task ${id.split('p').last}'),
        ),
      ]);
      await pumpUi(tester, h, height: _tall);

      double y(String t) => tester.getTopLeft(_row(t)).dy;
      expect(y('task 3'), lessThan(y('task 2')));
      expect(y('task 2'), lessThan(y('task 1')), reason: 'working above idle');

      await tester.tap(_section('working'));
      await settle(tester);
      expect(_row('task 2'), findsNothing);
      expect(_row('task 1'), findsOneWidget, reason: 'Idle is its own section');
      await tester.tap(find.byKey(const ValueKey('header/blocked')), warnIfMissed: false);
      await settle(tester);
      expect(_row('task 3'), findsOneWidget, reason: 'Needs you never folds');

      await tester.tap(_section('working'));
      await settle(tester);
      expect(_row('task 2'), findsOneWidget);
      await teardownUi(tester, h);
    });

    testWidgets('a row with no title is named after its agent, never blank', (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'workstation'),
          snapshot: snapshotWith([
            _pane(1, 'working'),
            _pane(2, 'idle', agent: 'codex'),
          ], title: (id) => id.endsWith('p1') ? '⠋' : ''),
        ),
      ]);
      await pumpUi(tester, h, height: _tall);

      expect(_row('Claude Code'), findsOneWidget);
      expect(_row('Codex'), findsOneWidget);
      await teardownUi(tester, h);
    });

    testWidgets('a very long title stops at two lines', (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'workstation'),
          snapshot: snapshotWith([_pane(1, 'working')], title: (_) => 'Refactor ${'the webhook retry handling ' * 12}'),
        ),
      ]);
      await pumpUi(tester, h, height: _tall);

      final row = find.byType(AgentCompactRow);
      expect(tester.getSize(row).height, lessThan(230));
      final title = find.descendant(of: row, matching: find.textContaining('Refactor'));
      expect(tester.widget<Text>(title).maxLines, 2);
      await teardownUi(tester, h);
    });

    testWidgets('a row says its repo and agent, and its machine only among several', (tester) async {
      Future<void> expectLine(List<String> machines, String line) async {
        final h = await UiHarness.create([
          for (final id in machines)
            (
              profile: _machine(id, 'box-$id'),
              snapshot: id == machines.first
                  ? snapshotWith([_pane(1, 'working')], title: (_) => 'Task', cwd: (_) => '/src/main')
                  : snapshotWith(const []),
            ),
        ]);
        await pumpUi(tester, h, height: _tall);
        expect(find.descendant(of: _row('Task'), matching: find.text(line)), findsOneWidget);
        await teardownUi(tester, h);
      }

      await expectLine(['a'], 'main · Claude Code');
      await expectLine(['a', 'b'], 'main · Claude Code · box-a');
    });

    testWidgets('120 agents in one section: counted in full, the list ends clear of the bottom edge', (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'workstation'),
          snapshot: snapshotWith([
            for (var i = 1; i <= 120; i++) _pane(i, 'working'),
          ], title: (id) => 'task ${id.split('p').last}'),
        ),
      ]);
      await pumpUi(tester, h, height: _tall);
      expect(
        find.descendant(of: find.byType(SliverLargeTitle), matching: find.textContaining('120 working')),
        findsOneWidget,
      );

      await tester.fling(find.byType(CustomScrollView).first, const Offset(0, -20000), 20000);
      await settle(tester);
      await tester.fling(find.byType(CustomScrollView).first, const Offset(0, -20000), 20000);
      await settle(tester);

      final last = tester
          .widgetList(find.byType(AgentCompactRow))
          .map((w) => tester.getRect(find.byWidget(w)).bottom)
          .reduce((a, b) => a > b ? a : b);
      final screen = tester.view.physicalSize.height / tester.view.devicePixelRatio;
      expect(last, lessThanOrEqualTo(screen - Gap.xl + 0.01), reason: 'the list ends clear of the bottom edge');
      await teardownUi(tester, h);
    });
  });

  // Worktrees of one repo are named by their branch on the board, read once
  // per machine for the app run, never per rebuild.
  group('branches', () {
    const primary = '/r/app';
    const login = '/wt/app-login';

    Map<String, dynamic> repoSnapshot(List<Pane> panes) {
      final snapshot = snapshotWith(
        panes,
        workspaces: const [(id: 'w1', label: 'app'), (id: 'w2', label: 'app-login')],
        title: (id) => 'task ${id.split('p').last}',
        cwd: (id) => id.startsWith('w1') ? primary : login,
      );
      for (final w in snapshot['workspaces'] as List) {
        final ws = w as Map<String, dynamic>;
        final path = ws['workspace_id'] == 'w1' ? primary : login;
        ws['worktree'] = {
          'checkout_path': path,
          'is_linked_worktree': path == login,
          'repo_key': '$primary/.git',
          'repo_name': 'app',
          'repo_root': primary,
        };
      }
      return snapshot;
    }

    List<Pane> panes(String status) => [
      (id: 'w1:p1', ws: 'w1', agent: 'claude', status: status),
      (id: 'w2:p2', ws: 'w2', agent: 'claude', status: 'working'),
    ];

    testWidgets('the board reads a machine\'s branches once, names rows by them, and never asks again', (tester) async {
      final h = await UiHarness.create([(profile: _machine('a', 'studio'), snapshot: repoSnapshot(panes('working')))]);
      final transport = h.transports['a']!;
      transport.answers['worktree.list'] = {
        'type': 'worktree_list',
        'worktrees': [
          {'path': primary, 'branch': 'main', 'label': 'app', 'is_linked_worktree': false, 'open_workspace_id': 'w1'},
          {
            'path': login,
            'branch': 'fix/login',
            'label': 'app-login',
            'is_linked_worktree': true,
            'open_workspace_id': 'w2',
          },
        ],
      };
      int reads() => transport.calls.where((c) => c.$1 == 'worktree.list').length;

      await pumpUi(tester, h, height: _tall);
      expect(reads(), 1, reason: 'one repo with several checkouts: one read');
      expect(find.descendant(of: _row('task 2'), matching: find.text('app · fix/login · Claude Code')), findsOneWidget);
      expect(find.descendant(of: _row('task 1'), matching: find.text('app · main · Claude Code')), findsOneWidget);

      for (final status in ['done', 'working', 'idle']) {
        transport.snapshot = repoSnapshot(panes(status));
        transport.emit(_statusEvent);
        await settle(tester);
      }
      await tester.tap(_section('working'));
      await settle(tester);
      expect(reads(), 1, reason: 'the board rebuilt and folded, and asked nothing again');
      await teardownUi(tester, h);
    });

    testWidgets('a branch not read yet leaves the checkout\'s folder, never an empty line', (tester) async {
      final h = await UiHarness.create([(profile: _machine('a', 'studio'), snapshot: repoSnapshot(panes('working')))]);
      // No answer: the read fails and the rows keep their folders.
      await pumpUi(tester, h, height: _tall);
      expect(find.descendant(of: _row('task 2'), matching: find.text('app · app-login · Claude Code')), findsOneWidget);
      expect(
        find.descendant(of: _row('task 1'), matching: find.text('app · Claude Code')),
        findsOneWidget,
        reason: 'the primary checkout\'s folder is the repo\'s own name',
      );
      await teardownUi(tester, h);
    });
  });

  // The left of home's header: the fleet at a glance, and the way to Machines.
  group('the machines chip', () {
    LinkDot mark(WidgetTester tester) => tester.widget<LinkDot>(find.byKey(const ValueKey('machine-health-mark')));

    testWidgets('counts the machines that are on; one needing the person changes the mark\'s shape', (tester) async {
      final h = await UiHarness.create([
        (profile: _machine('a', 'one'), snapshot: snapshotWith([_pane(1, 'working')])),
        (profile: _machine('b', 'two'), snapshot: snapshotWith([_pane(2, 'working')])),
        (
          profile: const MachineProfile(id: 'c', label: 'off', host: 'c.example', username: 'dev', enabled: false),
          snapshot: snapshotWith(const []),
        ),
      ]);
      await pumpUi(tester, h, height: _tall);
      final ds = tester.element(find.byType(AgentsScreen)).ds;

      expect(find.text('2 of 2 machines'), findsOneWidget, reason: 'switched off is neither a problem nor online');
      expect(mark(tester).mark, LinkMark.dot, reason: 'all online: the quiet filled dot, as on Machines');
      expect(mark(tester).colorIn(ds), isNot(ds.done), reason: 'healthy is not news: no status colour');

      h.transports['b']!.failure = const HerdrTransportException('Host key changed', fatal: true);
      h.fleet.connection('b')!.reconnect();
      await settle(tester);
      expect(find.text('1 of 2 machines'), findsOneWidget);
      expect(mark(tester).mark, LinkMark.target, reason: 'one needs the person: a different shape, not only a colour');
      expect(mark(tester).colorIn(ds), ds.blocked);
      expect(find.bySemanticsLabel('1 of 2 machines online'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('machine-health')));
      await settle(tester);
      expect(find.byType(MachinesScreen).hitTestable(), findsOneWidget);
      await teardownUi(tester, h);
    });

    testWidgets('a long count at 320 dp and large text shrinks, it never pushes the actions off', (tester) async {
      final h = await UiHarness.create([
        for (var i = 0; i < 12; i++)
          (profile: _machine('m$i', 'box $i'), snapshot: snapshotWith([_pane(i, 'working')])),
      ]);
      await pumpUi(tester, h, width: 320, height: 640, textScale: 2);
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Settings').hitTestable(), findsOneWidget);
      expect(find.byTooltip('New agent session').hitTestable(), findsOneWidget);
      await teardownUi(tester, h);
    });
  });

  group('states', () {
    testWidgets('no machines offers to add one', (tester) async {
      final h = await UiHarness.create(const []);
      await pumpUi(tester, h, height: _tall);

      await tester.tap(find.text('Add your first machine'));
      await settle(tester);
      expect(find.byType(MachineFormScreen), findsOneWidget);
      await teardownUi(tester, h);
    });

    testWidgets('machines with no agents say so', (tester) async {
      final h = await UiHarness.create([
        (profile: _machine('a', 'solo'), snapshot: snapshotWith(const [])),
        (profile: _machine('b', 'duo'), snapshot: snapshotWith(const [])),
      ]);
      await pumpUi(tester, h, height: _tall);

      expect(find.text('No agents running'), findsOneWidget);
      await teardownUi(tester, h);
    });

    testWidgets('every machine failing: one strip sums it up and leads to Machines', (tester) async {
      final h = await UiHarness.create([
        for (final id in ['a', 'b', 'c'])
          (
            profile: _machine(id, id == 'a' ? 'x' : 'build-server-eu-west-2-primary-$id'),
            snapshot: snapshotWith([
              _pane(1, 'blocked'),
              _pane(2, 'working'),
              _pane(3, 'done'),
            ], title: (id) => 'task ${id.split('p').last}'),
          ),
      ]);
      await pumpUi(tester, h, height: 640);
      await _failAll(tester, h, 'Host key changed. ${'Check it. ' * 30}');

      expect(find.byType(StatusStrip), findsOneWidget);
      expect(find.text('3 machines not connected'), findsOneWidget);
      expect(find.text('Retry'), findsNothing, reason: 'Machines has the detail');
      expect(find.textContaining('3 not connected'), findsOneWidget);

      // The agents the person came for are still on the first screen.
      expect(tester.getTopLeft(find.byType(AgentCompactRow).first).dy, lessThan(300));

      await tester.tap(find.byType(StatusStrip));
      await settle(tester);
      expect(find.byType(MachinesScreen).hitTestable(), findsOneWidget);
      await teardownUi(tester, h);
    });

    testWidgets('one machine failing: its own strip, and Retry works from there', (tester) async {
      final h = await UiHarness.create([
        (profile: _machine('a', 'x'), snapshot: snapshotWith([_pane(1, 'working')], title: (_) => 'task')),
        (profile: _machine('b', 'duo'), snapshot: snapshotWith(const [])),
      ]);
      await pumpUi(tester, h, height: _tall);
      h.transports['a']!.failure = HerdrTransportException('Host key changed', fatal: true);
      h.fleet.connections.first.reconnect();
      await settle(tester);

      expect(find.byType(StatusStrip), findsOneWidget);
      expect(find.textContaining('Host key changed'), findsNothing);
      expect(find.textContaining('Needs attention'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      h.transports['a']!.failure = null;
      await tester.tap(find.text('Retry'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await settle(tester);
      expect(find.byType(StatusStrip), findsNothing);
      expect(h.fleet.connections.first.state, LinkState.online);
      await teardownUi(tester, h);
    });

    testWidgets('a failing machine and long rows fit at 320dp and double text size', (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'tailnet-build-server-eu-west-2-primary'),
          snapshot: snapshotWith([
            _pane(1, 'blocked'),
            _pane(2, 'working'),
          ], title: (_) => 'Hôm nay chúng ta cập nhật và kiểm tra ${'dài ' * 20}'),
        ),
        (profile: _machine('b', 'duo'), snapshot: snapshotWith(const [])),
      ]);
      await pumpUi(tester, h, width: 320, height: 640, textScale: 2);
      h.transports['a']!.failure = HerdrTransportException('Host key changed', fatal: true);
      h.fleet.connections.first.reconnect();
      await settle(tester);

      expect(find.byType(StatusStrip), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await teardownUi(tester, h);
    });

    testWidgets('a machine that was switched off is not a failure', (tester) async {
      final h = await UiHarness.create([
        (profile: _machine('a', 'solo'), snapshot: snapshotWith([_pane(1, 'working')], title: (_) => 'task')),
        (
          profile: MachineProfile(id: 'b', label: 'old-laptop', host: 'b.example', username: 'dev', enabled: false),
          snapshot: snapshotWith(const []),
        ),
      ]);
      await pumpUi(tester, h, height: _tall);

      expect(h.fleet.connections.last.state, LinkState.disabled);
      expect(find.byType(StatusStrip), findsNothing);
      expect(find.textContaining('not connected'), findsNothing);
      await teardownUi(tester, h);
    });

    testWidgets('an offline machine keeps its agents under a strip, dimmed once', (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'solo'),
          snapshot: snapshotWith([_pane(1, 'blocked')], title: (_) => 'Needs a decision'),
        ),
      ]);
      await pumpUi(tester, h, height: _tall);
      h.network.goOffline();
      await settle(tester);

      expect(find.textContaining('Offline'), findsOneWidget);
      expect(_row('Needs a decision'), findsOneWidget);
      // The row's own Opacity and no second one on the glyph: dimmed twice,
      // the status shape is all but invisible.
      expect(find.descendant(of: _row('Needs a decision'), matching: find.byType(Opacity)), findsOneWidget);
      await teardownUi(tester, h);
    });
  });

  testWidgets('the status line counts what needs you, not finished work', (tester) async {
    final h = await UiHarness.create([
      (
        profile: _machine('a', 'solo'),
        snapshot: snapshotWith([_pane(1, 'blocked'), _pane(2, 'done'), _pane(3, 'working')]),
      ),
    ]);
    await pumpUi(tester, h, height: _tall);

    expect(
      find.textContaining('1 needs you'),
      findsOneWidget,
      reason: 'the loud colour is for a question; the finished one waits quietly on the board',
    );
    await teardownUi(tester, h);
  });

  // What a narrow phone at large text does to the header and the section
  // headers: everything that says something stays whole.
  group('fit', () {
    RenderParagraph paragraph(WidgetTester tester, Finder f) => tester.renderObject<RenderParagraph>(f);

    for (final scale in [1.6, 2.0]) {
      testWidgets('the status line takes a second line at 320 dp and ${scale}x instead of cutting its end', (
        tester,
      ) async {
        final h = await UiHarness.create([
          (
            profile: _machine('a', 'studio'),
            snapshot: snapshotWith([_pane(1, 'blocked'), _pane(2, 'working'), _pane(3, 'working')]),
          ),
          (profile: _machine('b', 'laptop'), snapshot: snapshotWith([_pane(4, 'working')])),
        ]);
        await pumpUi(tester, h, width: 320, height: 640, textScale: scale);
        h.transports['b']!.failure = const HerdrTransportException('Host key changed', fatal: true);
        h.fleet.connection('b')!.reconnect();
        await settle(tester);

        final line = find.descendant(
          of: find.byType(SliverLargeTitle),
          matching: find.textContaining('not connected', findRichText: true),
        );
        expect(line, findsOneWidget);
        final p = paragraph(tester, line);
        expect(p.didExceedMaxLines, isFalse, reason: 'the end, "1 not connected", is the part that matters');
        final oneLine = Type.secondary.fontSize! * Type.secondary.height! * kBarTextScale;
        expect(p.size.height, greaterThan(oneLine * 1.5), reason: 'it wrapped to a second line');
        // The header grew with it: the strip under it is not overlapped.
        expect(tester.getRect(line).bottom, lessThanOrEqualTo(tester.getRect(find.byType(StatusStrip)).top));
        expect(tester.takeException(), isNull);
        await teardownUi(tester, h);
      });
    }

    testWidgets('the to-review count stays whole and tappable at 320 dp and 2x, beside a long line', (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'studio'),
          snapshot: snapshotWith([_pane(1, 'blocked'), _pane(2, 'done'), _pane(3, 'done'), _pane(4, 'working')]),
        ),
        (profile: _machine('b', 'laptop'), snapshot: snapshotWith([_pane(5, 'working')])),
      ]);
      await pumpUi(tester, h, width: 320, height: _tall, textScale: 2);
      h.transports['b']!.failure = const HerdrTransportException('Host key changed', fatal: true);
      h.fleet.connection('b')!.reconnect();
      await settle(tester);

      final count = find.descendant(of: find.byKey(const ValueKey('to-review')), matching: find.text('2 to review'));
      expect(count, findsOneWidget);
      expect(paragraph(tester, count).didExceedMaxLines, isFalse);
      expect(count.hitTestable(), findsOneWidget);
      final line = find.descendant(
        of: find.byType(SliverLargeTitle),
        matching: find.textContaining('not connected', findRichText: true),
      );
      expect(paragraph(tester, line).didExceedMaxLines, isFalse, reason: 'the end still shows');
      expect(tester.takeException(), isNull);
      await teardownUi(tester, h);
    });
  });

  group('motion and identity', () {
    Future<UiHarness> two() => UiHarness.create([
      (
        profile: _machine('a', 'workstation'),
        snapshot: snapshotWith([
          _pane(1, 'working'),
          _pane(2, 'working'),
          _pane(3, 'idle'),
        ], title: (id) => 'task ${id.split('p').last}'),
      ),
    ]);

    Future<void> change(WidgetTester tester, UiHarness h, List<Pane> panes) async {
      _push(h, panes);
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('folding a section animates its rows away instead of cutting them', (tester) async {
      final h = await two();
      await pumpUi(tester, h, height: _tall);

      await tester.tap(_section('working'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 110));
      expect(_row('task 2'), findsOneWidget, reason: 'still on its way out');

      await settle(tester);
      expect(_row('task 2'), findsNothing);
      await teardownUi(tester, h);
    });

    testWidgets('an agent moving to Needs you moves no other row\'s element', (tester) async {
      final h = await two();
      await pumpUi(tester, h, height: _tall);
      final before = {
        for (final t in ['task 2', 'task 3']) t: tester.element(_row(t)),
      };

      await change(tester, h, [_pane(1, 'blocked'), _pane(2, 'working'), _pane(3, 'idle')]);
      await settle(tester);

      for (final MapEntry(key: t, value: element) in before.entries) {
        expect(identical(tester.element(_row(t)), element), isTrue, reason: '$t was inflated again instead of moved');
      }
      await teardownUi(tester, h);
    });

    testWidgets('a folded section stays still when Needs you above it disappears', (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'workstation'),
          snapshot: snapshotWith([
            _pane(1, 'blocked'),
            _pane(2, 'working'),
          ], title: (id) => 'task ${id.split('p').last}'),
        ),
      ]);
      await pumpUi(tester, h, height: _tall);
      await tester.tap(_section('working'));
      await settle(tester);

      await change(tester, h, [_pane(2, 'working')]);

      final chevron = find.descendant(of: _section('working'), matching: find.byType(RotationTransition));
      // Folded, the caret points right (no turn).
      expect(tester.widget<RotationTransition>(chevron).turns.value, 0, reason: 'the caret must not spin to catch up');
      await teardownUi(tester, h);
    });

    testWidgets('the pull-to-refresh spinner starts below the whole header', (tester) async {
      final h = await two();
      await pumpUi(tester, h, height: _tall);

      final header = tester.getRect(
        find.descendant(of: find.byType(SliverPersistentHeader), matching: find.byType(ClipRect)).first,
      );
      final refresh = tester.widget<RefreshIndicator>(find.byType(RefreshIndicator));
      expect(refresh.edgeOffset, header.bottom);
      await teardownUi(tester, h);
    });
  });

  group('rebuilds', () {
    /// Elements rebuilt under the board while the next frame is pumped.
    Future<int> rebuiltUnderAgents(WidgetTester tester) async {
      var n = 0;
      final previous = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (e, _) {
        e.visitAncestorElements((a) {
          if (a.widget is! AgentsScreen) return true;
          n++;
          return false;
        });
      };
      try {
        await tester.pump(const Duration(milliseconds: 300));
      } finally {
        debugOnRebuildDirtyWidget = previous;
      }
      return n;
    }

    testWidgets('only a change to what the board draws rebuilds it, and not while hidden', (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'workstation'),
          snapshot: snapshotWith([_pane(1, 'working'), _pane(2, 'idle')], title: (id) => 'task ${id.split('p').last}'),
        ),
      ]);
      await pumpUi(tester, h, height: _tall);

      // The fleet spoke but nothing the board draws changed.
      _push(h, [_pane(1, 'working'), _pane(2, 'idle')]);
      expect(await rebuiltUnderAgents(tester), 0);

      // Something it does draw changed.
      _push(h, [_pane(1, 'done'), _pane(2, 'idle')]);
      expect(await rebuiltUnderAgents(tester), greaterThan(0));

      // Machines is in front: the board under it sleeps...
      await tester.tap(find.byKey(const ValueKey('machine-health')));
      await settle(tester);
      _push(h, [_pane(1, 'blocked'), _pane(2, 'idle')]);
      expect(await rebuiltUnderAgents(tester), 0);

      // ...and is up to date the moment it returns.
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.text('Needs you'), findsWidgets);
      await teardownUi(tester, h);
    });
  });

  group('accessibility', () {
    testWidgets('a row reads as one label: title, status and where, each once', (tester) async {
      final handle = tester.ensureSemantics();
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'solo'),
          snapshot: snapshotWith([_pane(1, 'blocked')], title: (_) => 'Pick a strategy'),
        ),
      ]);
      await pumpUi(tester, h, height: _tall);

      final label = tester.getSemantics(_body('Pick a strategy')).label;
      for (final part in ['Pick a strategy', 'Needs you', 'Claude Code']) {
        expect(RegExp(RegExp.escape(part)).allMatches(label), hasLength(1), reason: '"$part" in: $label');
      }
      handle.dispose();
      await teardownUi(tester, h);
    });
  });

  group('restoration', () {
    Future<void> pumpRestorable(WidgetTester tester, UiHarness h) async {
      tester.view
        ..physicalSize = const Size(360, 740) * 2
        ..devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: h.machines),
            ChangeNotifierProvider.value(value: h.fleet),
            ChangeNotifierProvider.value(value: h.appSettings),
            ChangeNotifierProvider.value(value: h.agentScreens),
            Provider<PanePreviews>.value(value: h.previews),
            attentionSetProvider(),
          ],
          child: MaterialApp(restorationScopeId: 'app', theme: AppTheme.dark(), home: const HomeShell()),
        ),
      );
      await settle(tester);
    }

    testWidgets('the folded sections survive the process', (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'workstation'),
          snapshot: snapshotWith([
            _pane(1, 'blocked'),
            _pane(2, 'working'),
          ], title: (id) => 'task ${id.split('p').last}'),
        ),
      ]);
      await pumpRestorable(tester, h);
      await tester.tap(_section('working'));
      await settle(tester);
      expect(_row('task 2'), findsNothing);

      await tester.restartAndRestore();
      await settle(tester);
      expect(_row('task 1'), findsOneWidget);
      expect(_row('task 2'), findsNothing, reason: 'Working stayed folded');
      await teardownUi(tester, h);
    });
  });
}
