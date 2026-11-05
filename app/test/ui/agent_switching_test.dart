// One agent per screen: a quick swipe walks the agents that want the person
// (needs you, then done project by project as the board lists them, in an
// order frozen at the first swipe) and replaces
// the screen, the bar's toggle shows the other view of the
// same agent, a screen whose machine is gone says so, and launch puts the
// agent screen that was in front back.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/observed/omp_kind.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/observed_sessions.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_view.dart';
import 'package:herdr_mobile/ui/features/agents/agent_navigation.dart';
import 'package:herdr_mobile/ui/features/agents/agent_peek.dart';
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

List<(String, AgentRef)> _panesHome([int count = 4]) => [for (var i = 1; i <= count; i++) (_id(i), _agent(i))];

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

/// A peek card (an agent's or the end's) is on screen.
bool _peeking() => find.byType(PeekFrame).evaluate().isNotEmpty;

/// The peek shows [title].
Finder _peekOf(String title) => find.descendant(of: find.byType(PeekFrame), matching: find.text(title));

/// Drags [by] from [from] over [over], a move per frame, and lets go while
/// still moving. Whether a peek showed at any point.
Future<bool> _swipe(
  WidgetTester tester, {
  Offset from = _middle,
  required Offset by,
  Duration over = const Duration(milliseconds: 200),
}) async {
  final (g, at, peeked) = await _drag(tester, from: from, by: by, over: over);
  await g.up(timeStamp: at);
  await settle(tester);
  return peeked;
}

/// The finger goes down at [from] and moves [by] over [over], a move per
/// frame, and stays down: the gesture, when it was last moved, and whether a
/// peek showed on the way.
Future<(TestGesture, Duration, bool)> _drag(
  WidgetTester tester, {
  Offset from = _middle,
  required Offset by,
  Duration over = const Duration(milliseconds: 160),
}) async {
  final steps = math.max(1, over.inMilliseconds ~/ 16);
  final g = await tester.startGesture(from);
  var peeked = false;
  for (var i = 1; i <= steps; i++) {
    await g.moveBy(by / steps.toDouble(), timeStamp: over * i ~/ steps);
    await tester.pump(over ~/ steps);
    peeked |= _peeking();
  }
  return (g, over, peeked);
}

/// Lets go of [g] after holding still: no momentum.
Future<void> _letGoStill(WidgetTester tester, TestGesture g, Duration at) async {
  const still = Duration(milliseconds: 150);
  await tester.pump(still);
  await g.up(timeStamp: at + still);
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
    testWidgets('left walks what needs you, then what finished, never what works or idles; right retraces', (
      tester,
    ) async {
      final h = await _harness();
      await _pump(tester, h);
      await _waitInOrder(tester, h);
      // p1 finished too: the walk is p4, p2 (needs you), then p1 (done).
      final t = h.transports[_machine]!;
      t.snapshot = _snapshot([_pane(1, 'done'), _pane(2, 'blocked'), _pane(3, 'working'), _pane(4, 'blocked')]);
      t.emit(const {'event': 'pane.agent_status_changed'});
      await settle(tester);
      await _open(tester, _id(4));
      expect(_onScreen(tester), _id(4));

      final (g, at, _) = await _drag(tester, by: const Offset(-40, 0));
      expect(_peekOf('task 2'), findsOneWidget);
      expect(_peekOf('2 of 3'), findsOneWidget, reason: 'where the walk is');
      await _letGoStill(tester, g, at);

      await _swipeLeft(tester);
      expect(_onScreen(tester), _id(2), reason: 'the other one that needs you, waiting less long');
      await _swipeLeft(tester);
      expect(_onScreen(tester), _id(1), reason: 'then what finished; the working p3 is not on the walk');
      await _swipeLeft(tester);
      expect(_onScreen(tester), _id(1), reason: 'the walk ends there');

      await _swipeRight(tester);
      expect(_onScreen(tester), _id(2));
      await _swipeRight(tester);
      expect(_onScreen(tester), _id(4));

      await _back(tester);
      _expectHome();
      await teardownUi(tester, h);
    });

    testWidgets('after Needs you the walk takes the finished agents project by project, as the board lists them', (
      tester,
    ) async {
      Pane at(String ws, int i, String status) => (id: '$ws:p$i', ws: ws, agent: 'claude', status: status);
      final h = await _harness(
        panes: [at('w1', 1, 'done'), at('w2', 2, 'done'), at('w2', 3, 'working'), at('w1', 4, 'blocked')],
      );
      await _pump(tester, h, home: [('w1:p4', const PaneAgent(_machine, 'w1:p4'))]);
      await _open(tester, 'w1:p4');

      await _swipeLeft(tester);
      expect(_onScreen(tester), 'w1:p1', reason: 'projects in name order, as the board lists them');
      await _swipeLeft(tester);
      expect(_onScreen(tester), 'w2:p2', reason: 'though its project has work running');
      await teardownUi(tester, h);
    });

    testWidgets('the walk is frozen: answering the agent left behind does not move it, so right goes back there', (
      tester,
    ) async {
      final h = await _harness();
      await _pump(tester, h);
      await _waitInOrder(tester, h);
      await _open(tester, _id(4));

      await _swipeLeft(tester);
      expect(_onScreen(tester), _id(2));
      // p4 was answered on the desktop and went back to work: on the board it
      // is now under Working, after p2.
      final t = h.transports[_machine]!;
      t.snapshot = _snapshot([_pane(1, 'idle'), _pane(2, 'blocked'), _pane(3, 'working'), _pane(4, 'working')]);
      t.emit(const {'event': 'pane.agent_status_changed'});
      await settle(tester);

      await _swipeRight(tester);
      expect(_onScreen(tester), _id(4), reason: 'the walk retraces exactly, whatever the board says now');
      await _swipeLeft(tester);
      expect(_onScreen(tester), _id(2));
      await teardownUi(tester, h);
    });

    testWidgets('while the finger moves, the next agent shows; let go short, and nothing changes', (tester) async {
      final h = await _harness();
      await _pump(tester, h);
      await _waitInOrder(tester, h);
      await _open(tester, _id(4));

      final (g, at, _) = await _drag(tester, by: const Offset(-40, 0));
      expect(_peekOf('task 2'), findsOneWidget, reason: 'who is next, before letting go');
      expect(_onScreen(tester), _id(4));

      await _letGoStill(tester, g, at);
      expect(_onScreen(tester), _id(4));
      expect(_peeking(), isFalse, reason: 'the card went back');
      expect(tester.binding.hasScheduledFrame, isFalse, reason: 'nothing runs at rest');
      await teardownUi(tester, h);
    });

    testWidgets('let go past the commit distance, or flicked, it goes there', (tester) async {
      final h = await _harness();
      await _pump(tester, h);
      await _waitInOrder(tester, h);
      await _open(tester, _id(4));

      final (g, at, _) = await _drag(tester, by: const Offset(-110, 0), over: const Duration(milliseconds: 400));
      expect(_peekOf('Let go to open'), findsOneWidget, reason: 'past the distance the card says what letting go does');
      await _letGoStill(tester, g, at);
      expect(_onScreen(tester), _id(2), reason: 'held still past the distance');

      // A short, fast flick back: 36 dp in 48 ms.
      await _swipe(tester, by: const Offset(36, 0), over: const Duration(milliseconds: 48));
      expect(_onScreen(tester), _id(4), reason: 'the flick carries it');
      await teardownUi(tester, h);
    });

    testWidgets('it goes to the agent the card showed, even if that one stopped needing you meanwhile', (tester) async {
      final h = await _harness();
      await _pump(tester, h);
      await _waitInOrder(tester, h);
      await _open(tester, _id(4));

      final (g, at, _) = await _drag(tester, by: const Offset(-60, 0));
      expect(_peekOf('task 2'), findsOneWidget);
      // p3 starts needing the person and p2 goes back to work.
      final t = h.transports[_machine]!;
      t.snapshot = _snapshot([_pane(1, 'idle'), _pane(2, 'working'), _pane(3, 'blocked'), _pane(4, 'blocked')]);
      t.emit(const {'event': 'pane.agent_status_changed'});
      await settle(tester);

      await g.moveBy(const Offset(-60, 0), timeStamp: at + const Duration(milliseconds: 16));
      await _letGoStill(tester, g, at + const Duration(milliseconds: 16));
      expect(_onScreen(tester), _id(2));
      await _swipeRight(tester);
      expect(_onScreen(tester), _id(4), reason: 'and back along the same walk');
      await teardownUi(tester, h);
    });

    testWidgets('at either end the card says so, and nothing changes', (tester) async {
      final h = await _harness();
      await _pump(tester, h);
      await _waitInOrder(tester, h);

      await _open(tester, _id(4));
      final (g, at, _) = await _drag(tester, by: const Offset(120, 0));
      expect(find.textContaining('previous agent'), findsOneWidget, reason: 'the card says there is none');
      await _letGoStill(tester, g, at);
      expect(_onScreen(tester), _id(4), reason: 'the first one has nothing before it');
      await _swipeRight(tester);
      expect(_onScreen(tester), _id(4), reason: 'not even flicked');

      await _swipeLeft(tester);
      expect(_onScreen(tester), _id(2));
      final (g2, at2, _) = await _drag(tester, by: const Offset(-120, 0));
      expect(find.textContaining('All caught up'), findsOneWidget, reason: 'nothing else wants you');
      expect(find.textContaining('1 working'), findsOneWidget, reason: 'and p3 works on without you');
      await _letGoStill(tester, g2, at2);
      expect(_onScreen(tester), _id(2), reason: 'the last one has nothing after it');
      expect(_peeking(), isFalse);
      await _back(tester);
      _expectHome();
      await teardownUi(tester, h);
    });

    testWidgets('back on the board the walk is over: the next one begins where the person is', (tester) async {
      final h = await _harness();
      await _pump(tester, h);
      await _waitInOrder(tester, h);
      await _open(tester, _id(4));
      await _swipeLeft(tester);
      expect(_onScreen(tester), _id(2));
      await _back(tester);
      _expectHome();

      // p4 was answered meanwhile; p2 still needs the person.
      final t = h.transports[_machine]!;
      t.snapshot = _snapshot([_pane(1, 'idle'), _pane(2, 'blocked'), _pane(3, 'working'), _pane(4, 'working')]);
      t.emit(const {'event': 'pane.agent_status_changed'});
      await settle(tester);

      await _open(tester, _id(2));
      await _swipeRight(tester);
      expect(_onScreen(tester), _id(2), reason: 'a new walk starts at p2: the old one led back to p4');
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
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
        reason: 'the next agent has its own composer',
      );

      await _swipeRight(tester);
      expect(_onScreen(tester), _id(4));
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'half a thought');
      await teardownUi(tester, h);
    });

    testWidgets('from an agent session\'s transcript to a terminal on the walk, and back', (tester) async {
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
      // The session is idle: the walk starts at it, then p4 and p2.
      await _open(tester, 'session');
      expect(find.byType(AgentSessionScreen), findsOneWidget);

      await _swipeLeft(tester, from: tester.getCenter(find.byType(TranscriptView)));
      expect(find.byType(AgentSessionScreen), findsNothing);
      expect(_onScreen(tester), _id(4));

      final (g, at, _) = await _drag(tester, by: const Offset(60, 0));
      expect(_peekOf('payments'), findsOneWidget, reason: 'a session shows as the board shows it');
      expect(_peekOf('Fixed it.'), findsOneWidget, reason: 'with what it last said, already in memory');
      await g.moveBy(const Offset(100, 0), timeStamp: at + const Duration(milliseconds: 16));
      await g.up(timeStamp: at + const Duration(milliseconds: 16));
      await settle(tester);
      expect(find.byType(PaneScreen), findsNothing);
      expect(find.byType(AgentSessionScreen), findsOneWidget);

      await _swipeRight(tester, from: tester.getCenter(find.byType(TranscriptView)));
      expect(find.byType(AgentSessionScreen), findsOneWidget, reason: 'the session is where the walk began');

      await _back(tester);
      _expectHome();
      await teardownUi(tester, h);
    });
  });

  group('what is not a swipe to the next agent', () {
    // A walk from p2 leads on to p4, so a swipe left would go there.
    Future<UiHarness> inTheMiddle(WidgetTester tester) async {
      final h = await _harness();
      await _pump(tester, h);
      await _waitInOrder(tester, h);
      await _open(tester, _id(2));
      return h;
    }

    testWidgets('a vertical scroll, even a slanted one', (tester) async {
      final h = await inTheMiddle(tester);

      expect(await _swipe(tester, by: const Offset(0, -240)), isFalse);
      expect(await _swipe(tester, by: const Offset(-70, -200)), isFalse);
      expect(await _swipe(tester, by: const Offset(-40, 300)), isFalse);

      expect(_onScreen(tester), _id(2));
      await teardownUi(tester, h);
    });

    testWidgets('a sideways drag that turns into a scroll takes the card back', (tester) async {
      final h = await inTheMiddle(tester);

      final (g, at, peeked) = await _drag(tester, by: const Offset(-50, 0));
      expect(peeked, isTrue);
      await g.moveBy(const Offset(-30, -120), timeStamp: at + const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      await g.moveBy(const Offset(-60, 0), timeStamp: at + const Duration(milliseconds: 32));
      await g.up(timeStamp: at + const Duration(milliseconds: 32));
      await settle(tester);

      expect(_peeking(), isFalse);
      expect(_onScreen(tester), _id(2));
      await teardownUi(tester, h);
    });

    testWidgets('a drag after holding still (a selection)', (tester) async {
      final h = await inTheMiddle(tester);

      final g = await tester.startGesture(_middle);
      await tester.pump(const Duration(milliseconds: 600));
      var peeked = false;
      for (var i = 1; i <= 8; i++) {
        await g.moveBy(const Offset(-20, 0), timeStamp: Duration(milliseconds: 600 + i * 16));
        await tester.pump();
        peeked |= _peeking();
      }
      await g.up(timeStamp: const Duration(milliseconds: 600 + 8 * 16));
      await settle(tester);

      expect(peeked, isFalse);
      expect(_onScreen(tester), _id(2));
      await teardownUi(tester, h);
    });

    testWidgets('a crawl too slow to be a swipe', (tester) async {
      final h = await inTheMiddle(tester);

      expect(await _swipe(tester, by: const Offset(-40, 0), over: const Duration(milliseconds: 1500)), isFalse);

      expect(_onScreen(tester), _id(2));
      await teardownUi(tester, h);
    });

    testWidgets('a tap and a short nudge', (tester) async {
      final h = await inTheMiddle(tester);

      await tester.tapAt(_middle);
      await settle(tester);
      expect(await _swipe(tester, by: const Offset(-12, 0)), isFalse);
      final (g, at, _) = await _drag(tester, by: const Offset(-30, 0));
      await _letGoStill(tester, g, at);

      expect(_onScreen(tester), _id(2));
      await teardownUi(tester, h);
    });

    testWidgets('a pinch (two fingers)', (tester) async {
      final h = await inTheMiddle(tester);

      final a = await tester.startGesture(const Offset(150, 400));
      final b = await tester.startGesture(const Offset(300, 400));
      var peeked = false;
      for (var i = 0; i < 6; i++) {
        await a.moveBy(const Offset(-25, 0));
        await b.moveBy(const Offset(-25, 0));
        await tester.pump(const Duration(milliseconds: 20));
        peeked |= _peeking();
      }
      await a.up();
      await b.up();
      await settle(tester);

      expect(peeked, isFalse);
      expect(_onScreen(tester), _id(2));
      await teardownUi(tester, h);
    });

    testWidgets('a second finger after the card showed takes it back', (tester) async {
      final h = await inTheMiddle(tester);

      final (g, at, peeked) = await _drag(tester, by: const Offset(-50, 0));
      expect(peeked, isTrue);
      final b = await tester.startGesture(const Offset(100, 300));
      await g.moveBy(const Offset(-100, 0), timeStamp: at + const Duration(milliseconds: 16));
      await g.up(timeStamp: at + const Duration(milliseconds: 16));
      await b.up();
      await settle(tester);

      expect(_peeking(), isFalse);
      expect(_onScreen(tester), _id(2));
      await teardownUi(tester, h);
    });

    testWidgets('a swipe that starts at the screen edge (the system back gesture)', (tester) async {
      final h = await inTheMiddle(tester);

      expect(await _swipe(tester, from: const Offset(20, 400), by: const Offset(160, 0)), isFalse);
      expect(await _swipe(tester, from: const Offset(392, 400), by: const Offset(-160, 0)), isFalse);

      expect(_onScreen(tester), _id(2));
      await teardownUi(tester, h);
    });

    testWidgets('a swipe over the composer', (tester) async {
      final h = await inTheMiddle(tester);

      expect(await _swipe(tester, from: tester.getCenter(find.byType(TextField)), by: const Offset(-160, 0)), isFalse);

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

      expect(await _swipe(tester, by: const Offset(-160, 0)), isFalse);

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

  group('without a gesture', () {
    testWidgets('the screen offers Next agent and Previous agent to accessibility services', (tester) async {
      final semantics = tester.ensureSemantics();
      final h = await _harness();
      await _pump(tester, h);
      await _waitInOrder(tester, h);
      await _open(tester, _id(2));

      Future<void> perform(String label) async {
        final node = tester.getSemantics(find.byType(AgentSwipe));
        final action = CustomSemanticsAction.getIdentifier(CustomSemanticsAction(label: label));
        tester.binding.performSemanticsAction(
          SemanticsActionEvent(
            type: SemanticsAction.customAction,
            viewId: tester.view.viewId,
            nodeId: node.id,
            arguments: action,
          ),
        );
        await settle(tester);
      }

      await perform('Next agent');
      expect(_onScreen(tester), _id(4), reason: 'the walk from p2: the other one that needs you');
      await perform('Previous agent');
      expect(_onScreen(tester), _id(2));
      semantics.dispose();
      await teardownUi(tester, h);
    });

    testWidgets('at either end the action says so out loud, as the card does', (tester) async {
      final semantics = tester.ensureSemantics();
      final h = await _harness();
      await _pump(tester, h);
      await _waitInOrder(tester, h);
      await _open(tester, _id(4));

      Future<void> next() async {
        final node = tester.getSemantics(find.byType(AgentSwipe));
        tester.binding.performSemanticsAction(
          SemanticsActionEvent(
            type: SemanticsAction.customAction,
            viewId: tester.view.viewId,
            nodeId: node.id,
            arguments: CustomSemanticsAction.getIdentifier(const CustomSemanticsAction(label: 'Next agent')),
          ),
        );
        await settle(tester);
      }

      await next();
      expect(_onScreen(tester), _id(2));
      tester.takeAnnouncements();
      await next();

      expect(_onScreen(tester), _id(2), reason: 'the walk ends there');
      final said = tester.takeAnnouncements();
      expect(said, hasLength(1));
      expect(said.single.message, contains('All caught up'));
      semantics.dispose();
      await teardownUi(tester, h);
    });
  });

  group('the detector alone', () {
    /// Whether a step opens the agent; given the steps asked so far.
    bool Function(List<int> steps) opens = (_) => true;

    /// The steps let go far enough to go; [ends]: nothing either way.
    Future<List<int>> run(
      WidgetTester tester,
      Future<void> Function(WidgetTester, List<int> steps) gesture, {
      bool ends = false,
      bool reduced = false,
      Widget child = const ColoredBox(color: Color(0xFF000000)),
    }) async {
      final steps = <int>[];
      await tester.pumpWidget(
        Theme(
          data: AppTheme.dark(),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
                child: Center(
                  child: SizedBox(
                    width: 300,
                    height: 300,
                    child: AgentSwipeDetector(
                      peek: (step) => SwipePeek(
                        card: Text(ends ? 'nothing $step' : 'peek $step'),
                        go: ends ? null : () => opens(steps..add(step)),
                      ),
                      child: child,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await gesture(tester, steps);
      await tester.pumpAndSettle();
      return steps;
    }

    const centre = Offset(400, 300);

    Future<void> quickLeft(WidgetTester t, List<int> _) =>
        t.timedDragFrom(centre, const Offset(-150, 0), const Duration(milliseconds: 150));

    /// Moves [by] in four moves 16 ms apart and holds.
    Future<TestGesture> hold(WidgetTester t, Offset by) async {
      final g = await t.startGesture(centre);
      for (var i = 1; i <= 4; i++) {
        await g.moveBy(by / 4, timeStamp: Duration(milliseconds: 16 * i));
        await t.pump(const Duration(milliseconds: 16));
      }
      return g;
    }

    testWidgets('shows the card once the swipe is clear, and steps once, on letting go', (tester) async {
      final steps = await run(tester, (t, steps) async {
        final g = await hold(t, const Offset(-40, 2));
        expect(find.text('peek 1'), findsOneWidget, reason: 'before the finger lifts');
        expect(steps, isEmpty, reason: 'nothing is decided while the finger is down');
        await g.moveBy(const Offset(-80, 2), timeStamp: const Duration(milliseconds: 80));
        await g.up(timeStamp: const Duration(milliseconds: 80));
      });

      expect(steps, [1]);
      expect(find.text('peek 1'), findsNothing, reason: 'the card fades as the next screen comes');
    });

    testWidgets('a swipe to the right is the previous one', (tester) async {
      final steps = await run(
        tester,
        (t, _) => t.timedDragFrom(centre, const Offset(150, 0), const Duration(milliseconds: 150)),
      );

      expect(steps, [-1]);
    });

    testWidgets('let go still, short of the distance: the card goes back and nothing happens', (tester) async {
      final steps = await run(tester, (t, _) async {
        final g = await hold(t, const Offset(-50, 0));
        await t.pump(const Duration(milliseconds: 150));
        await g.up(timeStamp: const Duration(milliseconds: 214));
      });

      expect(steps, isEmpty);
      expect(find.text('peek 1'), findsNothing);
    });

    testWidgets('dragged past the distance and back again before letting go: nothing', (tester) async {
      final steps = await run(tester, (t, _) async {
        final g = await hold(t, const Offset(-100, 0));
        for (var i = 1; i <= 4; i++) {
          await g.moveBy(const Offset(15, 0), timeStamp: Duration(milliseconds: 64 + 40 * i));
          await t.pump(const Duration(milliseconds: 40));
        }
        await t.pump(const Duration(milliseconds: 150));
        await g.up(timeStamp: const Duration(milliseconds: 400));
      });

      expect(steps, isEmpty);
    });

    testWidgets('with nothing that way the card says so and letting go goes nowhere', (tester) async {
      final steps = await run(tester, ends: true, (t, _) async {
        final g = await hold(t, const Offset(-120, 0));
        expect(find.text('nothing 1'), findsOneWidget);
        await g.up(timeStamp: const Duration(milliseconds: 64));
      });

      expect(steps, isEmpty);
      expect(find.text('nothing 1'), findsNothing);
    });

    testWidgets('going vertical first spoils the touch', (tester) async {
      final steps = await run(tester, (t, _) async {
        final g = await t.startGesture(centre);
        await g.moveBy(const Offset(0, -40));
        await g.moveBy(const Offset(-200, 0));
        await t.pump();
        expect(find.text('peek 1'), findsNothing);
        await g.up();
      });

      expect(steps, isEmpty);
    });

    testWidgets('a second finger spoils the touch, even after the first lifts', (tester) async {
      final steps = await run(tester, (t, _) async {
        final a = await t.startGesture(centre);
        final b = await t.startGesture(centre + const Offset(30, 0));
        await a.moveBy(const Offset(-200, 0));
        await t.pump();
        expect(find.text('peek 1'), findsNothing);
        await a.up();
        await b.moveBy(const Offset(-200, 0));
        await b.up();
      });

      expect(steps, isEmpty);
    });

    testWidgets('does not take a tap from what is under it', (tester) async {
      var taps = 0;
      await run(
        tester,
        (t, _) => t.tapAt(centre),
        child: GestureDetector(
          onTap: () => taps++,
          child: const ColoredBox(color: Color(0xFF000000)),
        ),
      );

      expect(taps, 1);
    });

    testWidgets('content under the finger that scrolls sideways takes the swipe', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      var peeked = false;
      final steps = await run(
        tester,
        (t, _) async {
          final g = await hold(t, const Offset(-80, 0));
          peeked = find.text('peek 1').evaluate().isNotEmpty;
          await g.moveBy(const Offset(-70, 0), timeStamp: const Duration(milliseconds: 80));
          await g.up(timeStamp: const Duration(milliseconds: 80));
        },
        child: SingleChildScrollView(
          controller: controller,
          scrollDirection: Axis.horizontal,
          child: const SizedBox(width: 900, height: 300),
        ),
      );

      expect(peeked, isFalse);
      expect(steps, isEmpty);
      expect(controller.offset, greaterThan(0), reason: 'it scrolled instead');
    });

    testWidgets('a sideways scroller with nothing to scroll does not stop the step', (tester) async {
      final steps = await run(
        tester,
        quickLeft,
        child: const SingleChildScrollView(scrollDirection: Axis.horizontal, child: SizedBox(width: 200, height: 300)),
      );

      expect(steps, [1]);
    });

    testWidgets('a slanted swipe that scrolls the list under it is a scroll: the card goes, nothing steps', (
      tester,
    ) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      var peekedAtEnd = true;
      final steps = await run(tester, (t, _) async {
        // dx -120, dy -42: a slant of 0.35, under the 0.4 a swipe allows.
        final g = await t.startGesture(centre);
        for (var i = 1; i <= 6; i++) {
          await g.moveBy(const Offset(-20, -7), timeStamp: Duration(milliseconds: 16 * i));
          await t.pump(const Duration(milliseconds: 16));
        }
        await t.pump();
        peekedAtEnd = find.text('peek 1').evaluate().isNotEmpty;
        await g.up(timeStamp: const Duration(milliseconds: 96));
      }, child: ListView(controller: controller, children: const [SizedBox(height: 2000)]));

      expect(controller.offset, greaterThan(0), reason: 'the list scrolled');
      expect(peekedAtEnd, isFalse, reason: 'once the list scrolls the card is taken back');
      expect(steps, isEmpty);
    });

    testWidgets('a step that opens nothing takes the card back, as a short swipe does', (tester) async {
      opens = (_) => false;
      addTearDown(() => opens = (_) => true);
      late double before;
      late double after;
      final steps = await run(tester, (t, _) async {
        final g = await hold(t, const Offset(-120, 0));
        before = t.getTopLeft(find.byType(PeekFrame)).dx;
        await g.up(timeStamp: const Duration(milliseconds: 64));
        await t.pump();
        await t.pump(const Duration(milliseconds: 60));
        after = t.getTopLeft(find.byType(PeekFrame)).dx;
      });

      expect(steps, [1], reason: 'it was asked');
      expect(after, greaterThan(before), reason: 'the card slides back out instead of fading in place');
      expect(find.text('peek 1'), findsNothing);
    });

    testWidgets('under reduced motion the card does not slide: it fades in where it rests', (tester) async {
      final steps = await run(reduced: true, tester, (t, _) async {
        final g = await hold(t, const Offset(-40, 0));
        final at = t.getTopLeft(find.byType(PeekFrame));
        await g.moveBy(const Offset(-40, 0), timeStamp: const Duration(milliseconds: 80));
        await t.pump();
        expect(t.getTopLeft(find.byType(PeekFrame)), at, reason: 'it does not move with the finger');
        await g.up(timeStamp: const Duration(milliseconds: 80));
      });

      expect(steps, [1]);
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
        (profile: const MachineProfile(id: _machine, label: 'box', host: 'h', username: 'u'), snapshot: snapshot),
      ]);
      h.transports[_machine]!.paneText = 'ready';
      final source = FakeLogSource()
        ..write([sessionLine(), userLine('u1', 'fix the build'), assistantLine('a1', 'Fixed it.')]);
      return (
        h,
        <SingleChildWidget>[
          ChangeNotifierProvider(
            create: (_) => ObservedSessions(
              fleet: h.fleet,
              previews: h.previews,
              sourceFor: (_) => source,
              kinds: {'omp': ompKind},
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

    testWidgets('switches between the chat and the terminal of the same agent, remembered for this run', (
      tester,
    ) async {
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
        resumeAgent(tester.state<NavigatorState>(find.byType(Navigator)), FrontAgent(_agent(2), AgentView.terminal)),
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
