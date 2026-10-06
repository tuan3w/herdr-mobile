// One agent per screen: a quick swipe goes to the next agent in the board's
// order and replaces the screen, the bar's toggle shows the other view of the
// same agent, a screen whose machine is gone says so, and launch puts the
// agent screen that was in front back.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/observed/omp_log_mapper.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/observed_sessions.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_view.dart';
import 'package:herdr_mobile/ui/features/agents/agent_navigation.dart';
import 'package:herdr_mobile/ui/features/agents/agent_swipe.dart';
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import '../support/fake_agent_session.dart';
import '../support/fake_log_source.dart';
import '../support/shot.dart' show loadAppFonts;
import 'ui_harness.dart';

const _machine = 'm1';

String _id(int i) => 'w1:p$i';

PaneAgent _agent(int i) => PaneAgent(_machine, _id(i));

Pane _pane(int i, String status, {String agent = 'claude'}) => (id: _id(i), ws: 'w1', agent: agent, status: status);

Map<String, dynamic> _snapshot(List<Pane> panes) => snapshotWith(panes, title: (id) => 'task ${id.split('p').last}');

/// The four panes of most tests, as herdr first reports them.
List<Pane> _start() => [_pane(1, 'idle'), _pane(2, 'idle'), _pane(3, 'working'), _pane(4, 'idle')];

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

List<(String, AgentRef)> _panesHome([int count = 4]) => [
  for (var i = 1; i <= count; i++) (_id(i), _agent(i)),
];

Future<UiHarness> _harness({List<Pane>? panes, bool wrap = true}) async {
  final h = await UiHarness.create([
    (
      profile: const MachineProfile(id: _machine, label: 'box', host: 'h', username: 'u'),
      snapshot: _snapshot(panes ?? _start()),
    ),
  ]);
  h.transports[_machine]!.paneText = [for (var i = 0; i < 200; i++) 'line $i of the output'].join('\n');
  await h.terminalSettings.setWrap(wrap);
  return h;
}

Future<void> _pump(
  WidgetTester tester,
  UiHarness h, {
  List<(String, AgentRef)>? home,
  AgentScreens? screens,
  List<SingleChildWidget> extra = const [],
}) async {
  tester.view
    ..physicalSize = const Size(412, 892) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: h.machines),
        ChangeNotifierProvider.value(value: h.fleet),
        ChangeNotifierProvider.value(value: h.terminalSettings),
        ChangeNotifierProvider.value(value: h.appSettings),
        ChangeNotifierProvider.value(value: screens ?? h.agentScreens),
        Provider<PanePreviews>.value(value: h.previews),
        ...extra,
        // After the sessions, if any: the board's order needs both.
        attentionSetProvider(),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: _Home(agents: home ?? _panesHome()),
      ),
    ),
  );
  await settle(tester);
}

/// herdr reports p4 needing the person, and a moment later p2: the board
/// lists p4 first (longest waiting), p2, then p3 working, then p1 idle.
Future<void> _waitInOrder(WidgetTester tester, UiHarness h) async {
  final t = h.transports[_machine]!;
  t.snapshot = _snapshot([_pane(1, 'idle'), _pane(2, 'idle'), _pane(3, 'working'), _pane(4, 'blocked')]);
  t.emit(const {'event': 'pane.agent_status_changed'});
  await settle(tester);
  t.snapshot = _snapshot([_pane(1, 'idle'), _pane(2, 'blocked'), _pane(3, 'working'), _pane(4, 'blocked')]);
  t.emit(const {'event': 'pane.agent_status_changed'});
  await settle(tester);
}

Future<void> _open(WidgetTester tester, String label) async {
  await tester.tap(find.text('open $label'));
  await settle(tester);
}

/// The pane whose terminal is on screen; there is only ever one.
String _onScreen(WidgetTester tester) {
  final screens = tester.widgetList<PaneScreen>(find.byType(PaneScreen)).toList();
  expect(screens, hasLength(1), reason: 'one agent per screen');
  return screens.single.agent.paneId;
}

const _middle = Offset(206, 400);

Future<void> _swipe(
  WidgetTester tester, {
  Offset from = _middle,
  required Offset by,
  Duration over = const Duration(milliseconds: 200),
}) async {
  await tester.timedDragFrom(from, by, over);
  await settle(tester);
}

Future<void> _swipeLeft(WidgetTester tester, {Offset from = _middle}) =>
    _swipe(tester, from: from, by: const Offset(-160, 0));

Future<void> _swipeRight(WidgetTester tester, {Offset from = _middle}) =>
    _swipe(tester, from: from, by: const Offset(160, 4));

Future<void> _back(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Back'));
  await settle(tester);
}

void _expectHome() {
  expect(find.text('open ${_id(1)}'), findsOneWidget);
  expect(find.byType(PaneScreen), findsNothing);
  expect(find.byType(AgentSessionScreen), findsNothing);
}

class _ScreensStore implements AgentScreensStore {
  _ScreensStore(this.saved);

  FrontAgent? saved;

  @override
  Future<FrontAgent?> read() async => saved;

  @override
  Future<void> write(FrontAgent? front) async => saved = front;
}

void main() {
  setUpAll(loadAppFonts);

  group('swipe between agents', () {
    testWidgets('left goes to the next agent in the board\'s order, right to the previous; Back goes home', (
      tester,
    ) async {
      final h = await _harness();
      await _pump(tester, h);
      await _waitInOrder(tester, h);
      await _open(tester, _id(4));
      expect(_onScreen(tester), _id(4));

      await _swipeLeft(tester);
      expect(_onScreen(tester), _id(2), reason: 'the other one that needs you, waiting less long');
      await _swipeLeft(tester);
      expect(_onScreen(tester), _id(3), reason: 'then what works');
      await _swipeLeft(tester);
      expect(_onScreen(tester), _id(1), reason: 'then what is idle');

      await _swipeRight(tester);
      expect(_onScreen(tester), _id(3));

      await _back(tester);
      _expectHome();
      await teardownUi(tester, h);
    });

    testWidgets('at either end nothing changes', (tester) async {
      final h = await _harness();
      await _pump(tester, h);
      await _waitInOrder(tester, h);

      await _open(tester, _id(4));
      await _swipeRight(tester);
      expect(_onScreen(tester), _id(4), reason: 'the first one has nothing before it');
      await _back(tester);
      _expectHome();

      await _open(tester, _id(1));
      await _swipeLeft(tester);
      expect(_onScreen(tester), _id(1), reason: 'the last one has nothing after it');
      await _back(tester);
      _expectHome();
      await teardownUi(tester, h);
    });

    testWidgets('a draft typed for one agent is there again after swiping away and back', (tester) async {
      final h = await _harness();
      await _pump(tester, h);
      await _waitInOrder(tester, h);
      await _open(tester, _id(4));

      await tester.enterText(find.byType(TextField), 'half a thought');
      await tester.pump();
      await _swipeLeft(tester);
      expect(_onScreen(tester), _id(2));
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty,
          reason: 'the next agent has its own composer');

      await _swipeRight(tester);
      expect(_onScreen(tester), _id(4));
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'half a thought');
      await teardownUi(tester, h);
    });

    testWidgets('from an agent session\'s transcript to the terminal before it, and back', (tester) async {
      final h = await _harness();
      final session = FakeAgentSession(
        title: 'payments',
        state: stateWith(items: [userMsg('u1', 'fix the build'), agentMsg('a1', 'Fixed it.')]),
      );
      final sessions = FakeAgentSessions([session]);
      await _pump(
        tester,
        h,
        home: [..._panesHome(), ('session', SessionAgent(session.key))],
        extra: [ListenableProvider<AgentSessions>.value(value: sessions)],
      );
      await _waitInOrder(tester, h);
      // The session is idle: last, after the idle pane p1.
      await _open(tester, 'session');
      expect(find.byType(AgentSessionScreen), findsOneWidget);

      await _swipeRight(tester, from: tester.getCenter(find.byType(TranscriptView)));
      expect(find.byType(AgentSessionScreen), findsNothing);
      expect(_onScreen(tester), _id(1));

      await _swipeLeft(tester);
      expect(find.byType(PaneScreen), findsNothing);
      expect(find.byType(AgentSessionScreen), findsOneWidget);

      await _swipeLeft(tester, from: tester.getCenter(find.byType(TranscriptView)));
      expect(find.byType(AgentSessionScreen), findsOneWidget, reason: 'the session is the last agent');

      await _back(tester);
      _expectHome();
      await teardownUi(tester, h);
    });
  });

  group('what is not a swipe to the next agent', () {
    // p2 has an agent on either side (p4 before it, p3 after), so a step
    // either way would show.
    Future<UiHarness> inTheMiddle(WidgetTester tester) async {
      final h = await _harness();
      await _pump(tester, h);
      await _waitInOrder(tester, h);
      await _open(tester, _id(2));
      return h;
    }

    testWidgets('a vertical scroll, even a slanted one', (tester) async {
      final h = await inTheMiddle(tester);

      await _swipe(tester, by: const Offset(0, -240));
      await _swipe(tester, by: const Offset(-70, -200));
      await _swipe(tester, by: const Offset(-40, 300));

      expect(_onScreen(tester), _id(2));
      await teardownUi(tester, h);
    });

    testWidgets('a drag after holding still (a selection)', (tester) async {
      final h = await inTheMiddle(tester);

      final g = await tester.startGesture(_middle);
      await tester.pump(const Duration(milliseconds: 600));
      for (var i = 1; i <= 8; i++) {
        await g.moveBy(const Offset(-20, 0), timeStamp: Duration(milliseconds: 600 + i * 16));
      }
      await g.up();
      await settle(tester);

      expect(_onScreen(tester), _id(2));
      await teardownUi(tester, h);
    });

    testWidgets('a slow crawl', (tester) async {
      final h = await inTheMiddle(tester);

      await _swipe(tester, by: const Offset(-120, 0), over: const Duration(milliseconds: 1500));

      expect(_onScreen(tester), _id(2));
      await teardownUi(tester, h);
    });

    testWidgets('a tap and a short nudge', (tester) async {
      final h = await inTheMiddle(tester);

      await tester.tapAt(_middle);
      await settle(tester);
      await _swipe(tester, by: const Offset(-30, 0));

      expect(_onScreen(tester), _id(2));
      await teardownUi(tester, h);
    });

    testWidgets('a pinch (two fingers)', (tester) async {
      final h = await inTheMiddle(tester);

      final a = await tester.startGesture(const Offset(150, 400));
      final b = await tester.startGesture(const Offset(300, 400));
      for (var i = 0; i < 6; i++) {
        await a.moveBy(const Offset(-25, 0));
        await b.moveBy(const Offset(-25, 0));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await a.up();
      await b.up();
      await settle(tester);

      expect(_onScreen(tester), _id(2));
      await teardownUi(tester, h);
    });

    testWidgets('a swipe that starts at the screen edge (the system back gesture)', (tester) async {
      final h = await inTheMiddle(tester);

      await _swipe(tester, from: const Offset(20, 400), by: const Offset(160, 0));
      await _swipe(tester, from: const Offset(392, 400), by: const Offset(-160, 0));

      expect(_onScreen(tester), _id(2));
      await teardownUi(tester, h);
    });

    testWidgets('a swipe over the composer', (tester) async {
      final h = await inTheMiddle(tester);

      await _swipe(tester, from: tester.getCenter(find.byType(TextField)), by: const Offset(-160, 0));

      expect(_onScreen(tester), _id(2));
      await teardownUi(tester, h);
    });

    testWidgets('a swipe on a terminal wider than the screen (wrap off) scrolls it sideways instead', (tester) async {
      final h = await _harness(wrap: false);
      h.transports[_machine]!.paneTexts[_id(4)] = [
        'x' * 300,
        for (var i = 0; i < 40; i++) 'line $i of the output',
      ].join('\n');
      await _pump(tester, h);
      await _waitInOrder(tester, h);
      await _open(tester, _id(4));

      await _swipeLeft(tester);

      expect(_onScreen(tester), _id(4));
      await teardownUi(tester, h);
    });

    testWidgets('the same swipe with wrap on and short lines does go to the next agent', (tester) async {
      final h = await _harness(wrap: true);
      await _pump(tester, h);
      await _waitInOrder(tester, h);
      await _open(tester, _id(4));

      await _swipeLeft(tester);

      expect(_onScreen(tester), _id(2));
      await teardownUi(tester, h);
    });
  });

  group('the detector alone', () {
    Future<List<int>> run(
      WidgetTester tester,
      Future<void> Function(WidgetTester, List<int> swipes) gesture, {
      bool enabled = true,
      Widget child = const ColoredBox(color: Color(0xFF000000)),
    }) async {
      final swipes = <int>[];
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 300,
              height: 300,
              child: AgentSwipeDetector(enabled: enabled, onSwipe: swipes.add, child: child),
            ),
          ),
        ),
      );
      await gesture(tester, swipes);
      await tester.pump();
      return swipes;
    }

    const centre = Offset(400, 300);

    Future<void> quickLeft(WidgetTester t, List<int> _) =>
        t.timedDragFrom(centre, const Offset(-150, 0), const Duration(milliseconds: 150));

    testWidgets('fires once per swipe, as soon as it is clear', (tester) async {
      final swipes = await run(tester, (t, swipes) async {
        final g = await t.startGesture(centre);
        await g.moveBy(const Offset(-40, 0));
        await g.moveBy(const Offset(-40, 2));
        await t.pump();
        expect(swipes, [1], reason: 'before the finger lifts');
        await g.moveBy(const Offset(-40, 2));
        await g.moveBy(const Offset(-40, 2));
        await g.up();
      });

      expect(swipes, [1]);
    });

    testWidgets('a swipe to the right is the previous one', (tester) async {
      final swipes = await run(
        tester,
        (t, _) => t.timedDragFrom(centre, const Offset(150, 0), const Duration(milliseconds: 150)),
      );

      expect(swipes, [-1]);
    });

    testWidgets('disabled does nothing', (tester) async {
      final swipes = await run(tester, quickLeft, enabled: false);

      expect(swipes, isEmpty);
    });

    testWidgets('going vertical first spoils the touch', (tester) async {
      final swipes = await run(tester, (t, _) async {
        final g = await t.startGesture(centre);
        await g.moveBy(const Offset(0, -40));
        await g.moveBy(const Offset(-200, 0));
        await g.up();
      });

      expect(swipes, isEmpty);
    });

    testWidgets('a second finger spoils the touch, even after the first lifts', (tester) async {
      final swipes = await run(tester, (t, _) async {
        final a = await t.startGesture(centre);
        final b = await t.startGesture(centre + const Offset(30, 0));
        await a.moveBy(const Offset(-200, 0));
        await a.up();
        await b.moveBy(const Offset(-200, 0));
        await b.up();
      });

      expect(swipes, isEmpty);
    });

    testWidgets('does not take a tap from what is under it', (tester) async {
      var taps = 0;
      await run(
        tester,
        (t, _) => t.tapAt(centre),
        child: GestureDetector(onTap: () => taps++, child: const ColoredBox(color: Color(0xFF000000))),
      );

      expect(taps, 1);
    });

    testWidgets('content under the finger that scrolls sideways takes the swipe', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final swipes = await run(
        tester,
        quickLeft,
        child: SingleChildScrollView(
          controller: controller,
          scrollDirection: Axis.horizontal,
          child: const SizedBox(width: 900, height: 300),
        ),
      );

      expect(swipes, isEmpty);
      expect(controller.offset, greaterThan(0), reason: 'it scrolled instead');
    });

    testWidgets('a sideways scroller with nothing to scroll does not stop the step', (tester) async {
      final swipes = await run(
        tester,
        quickLeft,
        child: const SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: 200, height: 300),
        ),
      );

      expect(swipes, [1]);
    });
  });

  group('the Chat | Terminal toggle', () {
    // p1 runs claude in a plain terminal; p2 runs omp, whose log the app can
    // follow, so it has a chat too.
    Future<(UiHarness, List<SingleChildWidget>)> withOmp() async {
      final snapshot = _snapshot([_pane(1, 'idle'), _pane(2, 'idle', agent: 'omp')]);
      final p2 = (snapshot['panes'] as List).cast<Map<String, dynamic>>().firstWhere((p) => p['pane_id'] == _id(2));
      p2['agent_session'] = {'agent': 'omp', 'kind': 'path', 'value': ompLog};
      final h = await UiHarness.create([
        (
          profile: const MachineProfile(id: _machine, label: 'box', host: 'h', username: 'u'),
          snapshot: snapshot,
        ),
      ]);
      h.transports[_machine]!.paneText = 'ready';
      final source = FakeLogSource()..write([sessionLine(), userLine('u1', 'fix the build'), assistantLine('a1', 'Fixed it.')]);
      return (
        h,
        <SingleChildWidget>[
          ChangeNotifierProvider(
            create: (_) => ObservedSessions(
              fleet: h.fleet,
              previews: h.previews,
              sourceFor: (_) => source,
              mappers: {'omp': OmpLogMapper.new},
            ),
          ),
        ],
      );
    }

    /// Opens the screen's options and picks the row named [label].
    Future<void> pickFromMenu(WidgetTester tester, String tooltip, String label) async {
      await tester.tap(find.byTooltip(tooltip));
      await settle(tester);
      await tester.tap(find.text(label));
      await settle(tester);
    }

    testWidgets('switches between the chat and the terminal of the same agent, remembered for this run', (tester) async {
      final (h, observed) = await withOmp();
      await _pump(tester, h, home: _panesHome(2), extra: observed);

      await _open(tester, _id(2));
      expect(find.byType(AgentSessionScreen), findsOneWidget, reason: 'chat first');

      await pickFromMenu(tester, 'Session options', 'Show terminal');
      expect(find.byType(AgentSessionScreen), findsNothing);
      expect(_onScreen(tester), _id(2), reason: 'the same agent\'s terminal');

      await _back(tester);
      _expectHome();

      await _open(tester, _id(2));
      expect(_onScreen(tester), _id(2), reason: 'opened as it was last shown');

      await pickFromMenu(tester, 'Pane options', 'Show chat');
      expect(find.byType(PaneScreen), findsNothing);
      expect(find.byType(AgentSessionScreen), findsOneWidget);

      await _back(tester);
      _expectHome();

      await _open(tester, _id(2));
      expect(find.byType(AgentSessionScreen), findsOneWidget);
      await teardownUi(tester, h);
    });

    testWidgets('a pane whose agent has no chat offers no way to one', (tester) async {
      final (h, observed) = await withOmp();
      await _pump(tester, h, home: _panesHome(2), extra: observed);

      await _open(tester, _id(1));
      expect(_onScreen(tester), _id(1));

      await tester.tap(find.byTooltip('Pane options'));
      await settle(tester);
      expect(find.text('Duplicate'), findsOneWidget, reason: 'the sheet is open');
      expect(find.text('Show chat'), findsNothing);
      await teardownUi(tester, h);
    });
  });

  group('an agent screen whose machine is gone', () {
    testWidgets('a removed machine shows a placeholder, and Back still goes home', (tester) async {
      final h = await _harness();
      await _pump(tester, h);
      await _open(tester, _id(1));

      await tester.runAsync(() => h.machines.remove(_machine));
      await settle(tester);
      await tester.runAsync(h.fleet.settled);
      await settle(tester);

      expect(find.text('This machine is no longer saved'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _back(tester);
      expect(find.text('open ${_id(1)}'), findsOneWidget);
      expect(find.byType(PaneScreen), findsNothing);
      await teardownUi(tester, h);
    });
  });

  group('resume at launch', () {
    testWidgets('the screen that was in front is back at once, without a transition; Back goes home', (tester) async {
      final h = await _harness();
      await _pump(tester, h);

      unawaited(
        resumeAgent(
          tester.state<NavigatorState>(find.byType(Navigator)),
          FrontAgent(_agent(2), AgentView.terminal),
        ),
      );
      await tester.pump();

      expect(_onScreen(tester), _id(2));
      expect(find.text('open ${_id(1)}'), findsNothing, reason: 'fully in front on the first frame');

      await settle(tester);
      await _back(tester);
      _expectHome();
      await teardownUi(tester, h);
    });

    testWidgets('a session that never shows up is forgotten', (tester) async {
      final h = await _harness();
      const gone = FrontAgent(SessionAgent('m1/gone'), AgentView.chat);
      final store = _ScreensStore(gone);
      final screens = AgentScreens(store);
      await screens.load();
      await _pump(
        tester,
        h,
        screens: screens,
        extra: [ListenableProvider<AgentSessions>.value(value: FakeAgentSessions([]))],
      );

      unawaited(
        resumeAgent(
          tester.state<NavigatorState>(find.byType(Navigator)),
          screens.takeResume()!,
          patience: const Duration(seconds: 1),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1200));
      await settle(tester);

      _expectHome();
      expect(store.saved, isNull, reason: 'the next launch does not try again');
      await teardownUi(tester, h);
      screens.dispose();
    });
  });
}
