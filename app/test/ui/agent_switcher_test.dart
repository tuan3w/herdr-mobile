// The agent screen's title is the switcher: a tap lists every agent the board
// lists, in its sections and order; a row replaces the screen (Back still
// reaches the board); the count beside the chevron is the other agents that
// need the person, and nothing at 0.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_bar.dart';
import 'package:herdr_mobile/ui/features/agents/agent_navigation.dart';
import 'package:herdr_mobile/ui/features/pane/pane_bar.dart';
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import '../support/fake_agent_session.dart';
import '../support/shot.dart' show loadAppFonts;
import 'ui_harness.dart';

const _machine = 'm1';

String _id(int i) => 'w1:p$i';

Pane _pane(int i, String status) => (id: _id(i), ws: 'w1', agent: 'claude', status: status);

Map<String, dynamic> _snapshot(List<Pane> panes) => snapshotWith(panes, title: (id) => 'task ${id.split('p').last}');

/// p4 and p2 need the person (p4 longer), p3 works, p1 is idle.
List<Pane> _waiting() => [_pane(1, 'idle'), _pane(2, 'blocked'), _pane(3, 'working'), _pane(4, 'blocked')];

/// Where Back leads: one row per agent, each opening it the app's way.
class _Home extends StatelessWidget {
  const _Home({required this.agents});

  final List<(String, AgentRef)> agents;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          for (final (label, agent) in agents)
            GestureDetector(
              onTap: () => unawaited(openAgent(context, agent)),
              child: Padding(padding: const EdgeInsets.all(12), child: Text('open $label')),
            ),
        ],
      ),
    ),
  );
}

/// Nobody waits yet: [_report] says who does, in order.
Future<UiHarness> _harness() => UiHarness.create([
  (
    profile: const MachineProfile(id: _machine, label: 'box', host: 'h', username: 'u'),
    snapshot: _snapshot([_pane(1, 'idle'), _pane(2, 'idle'), _pane(3, 'working'), _pane(4, 'idle')]),
  ),
]);

/// Statuses arrive one at a time, as herdr reports them: p4 needs the person
/// first, then p2, so the board lists p4 first (longest waiting).
Future<void> _report(WidgetTester tester, UiHarness h) async {
  final t = h.transports[_machine]!;
  t.snapshot = _snapshot([_pane(1, 'idle'), _pane(2, 'idle'), _pane(3, 'working'), _pane(4, 'blocked')]);
  t.emit(const {'event': 'pane.agent_status_changed'});
  await settle(tester);
  t.snapshot = _snapshot(_waiting());
  t.emit(const {'event': 'pane.agent_status_changed'});
  await settle(tester);
}

Future<void> _pump(
  WidgetTester tester,
  UiHarness h, {
  List<(String, AgentRef)> extraHome = const [],
  List<SingleChildWidget> extra = const [],
  Size size = const Size(412, 892),
  double textScale = 1,
}) async {
  tester.view
    ..physicalSize = size * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: h.machines),
        ChangeNotifierProvider.value(value: h.fleet),
        ChangeNotifierProvider.value(value: h.terminalSettings),
        ChangeNotifierProvider.value(value: h.appSettings),
        ChangeNotifierProvider.value(value: h.agentScreens),
        Provider<PanePreviews>.value(value: h.previews),
        ...extra,
        attentionSetProvider(),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: _Home(agents: [for (var i = 1; i <= 4; i++) (_id(i), PaneAgent(_machine, _id(i))), ...extraHome]),
      ),
    ),
  );
  await settle(tester);
}

Future<void> _open(WidgetTester tester, String label) async {
  await tester.tap(find.text('open $label'));
  await settle(tester);
}

/// The switcher title of the bar in front.
Finder _title() => find.bySemanticsLabel(RegExp('^Switch agent'));

Future<void> _openSwitcher(WidgetTester tester) async {
  await tester.tap(_title());
  await settle(tester);
}

Finder _inSheet(Finder f) => find.descendant(of: find.byType(BottomSheet), matching: f);

String _onScreen(WidgetTester tester) => tester.widget<PaneScreen>(find.byType(PaneScreen)).agent.paneId;

/// The count beside the chevron, or null when none shows.
int? _badge(WidgetTester tester, Finder bar) {
  final badges = find.descendant(of: bar, matching: find.byType(CountBadge));
  if (badges.evaluate().isEmpty) return null;
  return tester.widget<CountBadge>(badges).count;
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('the title opens the switcher, which lists the board\'s sections, in the board\'s order', (tester) async {
    final h = await _harness();
    await _pump(tester, h);
    await _report(tester, h);
    await _open(tester, _id(4));

    await _openSwitcher(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    double y(String text) => tester.getTopLeft(_inSheet(find.text(text)).first).dy;
    final order = ['Needs you', 'task 4', 'task 2', 'Working', 'task 3', 'Idle', 'task 1', 'All agents on the board'];
    for (final text in order) {
      expect(_inSheet(find.text(text)), findsOneWidget, reason: '$text is listed once');
    }
    final ys = [for (final text in order) y(text)];
    expect(ys, orderedEquals([...ys]..sort()), reason: 'longest waiting first, then each section, as the board');
    // Each row says which feature it is, as on the board.
    expect(_inSheet(find.text('w1 · Claude Code')), findsNWidgets(4));

    // The agent in front is marked and does nothing.
    final here = _inSheet(find.text('Here'));
    expect(here, findsOneWidget);
    expect((tester.getCenter(here).dy - y('task 4')).abs(), lessThan(40), reason: 'on the row of the agent in front');
    await tester.tap(_inSheet(find.text('task 4')));
    await settle(tester);
    expect(find.byType(BottomSheet), findsOneWidget, reason: 'Here goes nowhere');
    expect(_onScreen(tester), _id(4));
    await teardownUi(tester, h);
  });

  testWidgets('a row replaces the screen: Back reaches the board, not the agent before', (tester) async {
    final h = await _harness();
    await _pump(tester, h);
    await _report(tester, h);
    await _open(tester, _id(4));

    await _openSwitcher(tester);
    await tester.tap(_inSheet(find.text('task 1')));
    await settle(tester);
    expect(find.byType(BottomSheet), findsNothing);
    expect(_onScreen(tester), _id(1), reason: 'an idle agent, which the swipe does not reach');

    await tester.tap(find.byTooltip('Back'));
    await settle(tester);
    expect(find.byType(PaneScreen), findsNothing);
    expect(find.text('open ${_id(1)}'), findsOneWidget);
    await teardownUi(tester, h);
  });

  testWidgets('the last row goes back to the board', (tester) async {
    final h = await _harness();
    await _pump(tester, h);
    await _report(tester, h);
    await _open(tester, _id(3));

    await _openSwitcher(tester);
    await tester.tap(_inSheet(find.text('All agents on the board')));
    await settle(tester);
    expect(find.byType(PaneScreen), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('open ${_id(1)}'), findsOneWidget);
    await teardownUi(tester, h);
  });

  testWidgets('the badge counts the other agents that need the person, and hides at 0', (tester) async {
    final h = await _harness();
    await _pump(tester, h);
    await _report(tester, h);

    await _open(tester, _id(4));
    expect(_badge(tester, find.byType(PaneTopBar)), 1, reason: 'p2; the agent in front is not counted');
    expect(_title(), findsOneWidget);
    expect(tester.getSemantics(_title()).label, contains('1 other agent needs you'));

    final t = h.transports[_machine]!;
    t.snapshot = _snapshot([_pane(1, 'idle'), _pane(2, 'working'), _pane(3, 'working'), _pane(4, 'blocked')]);
    t.emit(const {'event': 'pane.agent_status_changed'});
    await settle(tester);
    expect(_badge(tester, find.byType(PaneTopBar)), isNull, reason: 'only the agent in front needs the person');

    t.snapshot = _snapshot([_pane(1, 'blocked'), _pane(2, 'blocked'), _pane(3, 'working'), _pane(4, 'blocked')]);
    t.emit(const {'event': 'pane.agent_status_changed'});
    await settle(tester);
    expect(_badge(tester, find.byType(PaneTopBar)), 2);
    await teardownUi(tester, h);
  });

  testWidgets('a long title at 320 dp and large text gives way to the chevron and the count', (tester) async {
    final h = await _harness();
    await _pump(tester, h, size: const Size(320, 640), textScale: 2);
    final t = h.transports[_machine]!;
    final long = [_pane(1, 'blocked'), _pane(2, 'blocked'), _pane(3, 'working'), _pane(4, 'blocked')];
    t.snapshot = snapshotWith(long, title: (id) => 'Refactor the Hà Nội locale parser and add tests for $id');
    t.emit(const {'event': 'pane.agent_status_changed'});
    await settle(tester);
    await _open(tester, _id(4));

    expect(tester.takeException(), isNull, reason: 'nothing overflows');
    final bar = tester.getRect(find.byType(PaneTopBar));
    final badge = tester.getRect(find.descendant(of: find.byType(PaneTopBar), matching: find.byType(CountBadge)));
    final chevron = tester.getRect(
      find.descendant(of: find.byType(PaneTopBar), matching: find.byIcon(LucideIcons.chevronDown)),
    );
    expect(chevron.right, lessThan(badge.left), reason: 'the count follows the chevron');
    expect(badge.right, lessThanOrEqualTo(bar.right), reason: 'the count is whole on screen');
    final options = tester.getRect(find.byTooltip('Pane options'));
    expect(badge.right, lessThanOrEqualTo(options.left), reason: 'and does not run under the options');
    await teardownUi(tester, h);
  });

  testWidgets('the chat\'s title is the same switcher, with the session marked Here', (tester) async {
    final h = await _harness();
    final session = FakeAgentSession(
      title: 'payments',
      state: stateWith(items: [userMsg('u1', 'fix the build'), agentMsg('a1', 'Fixed it.')]),
    );
    await _pump(
      tester,
      h,
      extraHome: [('session', SessionAgent(session.key))],
      extra: [
        ListenableProvider<AgentSessions>.value(value: FakeAgentSessions([session])),
      ],
    );
    await _report(tester, h);
    await _open(tester, 'session');
    expect(find.byType(AgentSessionScreen), findsOneWidget);
    expect(_badge(tester, find.byType(SessionBar)), 2, reason: 'p4 and p2 need the person; the session does not');

    await _openSwitcher(tester);
    final here = _inSheet(find.text('Here'));
    expect(here, findsOneWidget);
    final sessionRow = tester.getTopLeft(_inSheet(find.text('payments'))).dy;
    expect((tester.getCenter(here).dy - sessionRow).abs(), lessThan(40));

    await tester.tap(_inSheet(find.text('task 2')));
    await settle(tester);
    expect(find.byType(AgentSessionScreen), findsNothing);
    expect(_onScreen(tester), _id(2));
    await teardownUi(tester, h);
  });
}
