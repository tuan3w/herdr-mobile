// Opening an agent from the board feels instant: the work starts when the
// finger goes down (an observed chat follows its log; a pane's chat and a
// session's attach already did), what is known is on the first frame and the
// first rows land in one swap, and the screen is simply there (a cut, no
// fade: two opaque screens cross-fading show the board through the new one).
// Radio: a hold is one stream start for a tap that was coming anyway, never in
// the background, never past a small cap, and it lets go by itself. All time
// is the test's own clock.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart' show KeeperInfo;
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/agent_session_repository.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/support/deep_link.dart' show DeepLinks;
import 'package:herdr_mobile/data/observed/omp_kind.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/observed_sessions.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agents/agent_navigation.dart';
import 'package:herdr_mobile/ui/features/agents/preconnect_tap.dart';
import 'package:provider/provider.dart';

import '../support/fake_agent_host.dart';
import '../support/fake_agent_session.dart';
import '../support/fake_log_source.dart';
import 'ui_harness.dart';

const _machine = 'm1';

/// A host whose listing can be held back (a slow link).
class _SlowList extends FakeAgentHost {
  Completer<void>? listGate;

  @override
  Future<List<KeeperInfo>> list() async {
    if (listGate case final gate?) await gate.future;
    return super.list();
  }
}

String _id(int i) => 'w1:p$i';

PaneAgent _agent(int i) => PaneAgent(_machine, _id(i));

/// What a pane's card does: a finger down starts the hold, the tap hands it on.
class _Row extends StatelessWidget {
  const _Row(this.agent);

  final PaneAgent agent;

  @override
  Widget build(BuildContext context) => PreconnectTap(
    start: (c) => preconnectObservedChat(c, agent),
    builder: (c, take) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(openAgent(c, agent, preconnect: take())),
      child: SizedBox(height: 56, width: double.infinity, child: Text('open ${agent.paneId}')),
    ),
  );
}

class _Board extends StatelessWidget {
  const _Board(this.count);

  final int count;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(child: Column(children: [for (var i = 1; i <= count; i++) _Row(_agent(i))])),
  );
}

class _World {
  _World(this.h, this.source, this.observed);

  final UiHarness h;
  final FakeLogSource source;
  final ObservedSessions observed;

  /// The follows the host was asked for (a wider read for earlier history is
  /// another thing and none is asked here).
  int get follows => source.calls.length;
}

Future<_World> _world(
  WidgetTester tester, {
  int panes = 2,
  int maxWarm = 3,
  List<String>? log,
  bool holdTails = false,
  String status = 'idle',
}) async {
  tester.view
    ..physicalSize = const Size(412, 892) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final snapshot = snapshotWith([
    for (var i = 1; i <= panes; i++) (id: _id(i), ws: 'w1', agent: 'omp', status: status),
  ], title: (id) => 'task ${id.split('p').last}');
  for (final p in (snapshot['panes'] as List).cast<Map<String, dynamic>>()) {
    p['agent_session'] = {'agent': 'omp', 'kind': 'path', 'value': ompLog};
  }
  final h = await UiHarness.create([
    (profile: const MachineProfile(id: _machine, label: 'box', host: 'h', username: 'u'), snapshot: snapshot),
  ]);
  h.transports[_machine]!.paneText = 'ready';
  final source = FakeLogSource()
    ..holdTails = holdTails
    ..write(log ?? [sessionLine(), userLine('u1', 'fix the build'), assistantLine('a1', 'Fixed it.')]);
  final observed = ObservedSessions(
    fleet: h.fleet,
    previews: h.previews,
    sourceFor: (_) => source,
    kinds: {'omp': ompKind},
    maxWarm: maxWarm,
  );
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: h.machines),
        ChangeNotifierProvider.value(value: h.fleet),
        ChangeNotifierProvider.value(value: h.terminalSettings),
        ChangeNotifierProvider.value(value: h.appSettings),
        ChangeNotifierProvider.value(value: h.agentScreens),
        Provider<PanePreviews>.value(value: h.previews),
        ChangeNotifierProvider.value(value: observed),
        attentionSetProvider(),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: _Board(panes)),
    ),
  );
  await settle(tester);
  return _World(h, source, observed);
}

/// Tears the tree and the sessions down so no timer outlives the test.
Future<void> _finish(WidgetTester tester, _World w) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 30)); // what lingers lets go
  w.observed.dispose();
  w.h.dispose();
  await tester.pump(const Duration(seconds: 1));
}

/// The first frame of a pushed route the person can see: the route is built
/// off screen once, to be measured (`ModalRoute.offstage`), and shown from
/// the frame after.
Future<void> _firstFrame(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

Finder _row(int i) => find.text('open ${_id(i)}', skipOffstage: false);

void main() {
  group('an observed chat starts following when the finger goes down', () {
    testWidgets('one follow at the press; the tap opens the screen on it, and no second read is made', (tester) async {
      final w = await _world(tester);
      expect(w.follows, 0, reason: 'nothing is read before a finger touches the row');

      final finger = await tester.startGesture(tester.getCenter(_row(2)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(w.follows, 1, reason: 'the log is being followed while the finger is still down');

      await finger.up();
      await tester.pump(); // the route
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AgentSessionScreen), findsOneWidget);
      expect(w.follows, 1, reason: 'the screen took over the stream the finger started');
      expect(find.textContaining('Fixed it.', findRichText: true), findsOneWidget);
      await _finish(tester, w);
    });

    testWidgets('a finger that slides away stops the follow once the hold has run its short course', (tester) async {
      final w = await _world(tester);
      final finger = await tester.startGesture(tester.getCenter(_row(1)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(w.follows, 1);
      expect(w.source.cancelled, isEmpty);

      await finger.moveBy(const Offset(0, -60)); // a scroll: past the touch slop
      await tester.pump(const Duration(milliseconds: 50));
      await finger.up();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(AgentSessionScreen), findsNothing);
      expect(w.follows, 1, reason: 'the one stream a press costs, no more');
      expect(w.source.cancelled, isEmpty, reason: 'a second tap on the same row would find it warm');

      await tester.pump(const Duration(seconds: 7)); // the hold TTL (6 s), virtual time
      expect(w.source.cancelled, [0], reason: 'nobody looks: the stream is closed');
      expect(w.follows, 1);
      await _finish(tester, w);
    });

    testWidgets('a hold nobody lets go of lets go by itself', (tester) async {
      final w = await _world(tester);
      await tester.startGesture(tester.getCenter(_row(1)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(w.follows, 1);
      await tester.pump(const Duration(seconds: 13)); // the TTL, then the same again
      expect(w.source.cancelled, [0]);
      await _finish(tester, w);
    });

    testWidgets('nothing starts while the app is in the background', (tester) async {
      final w = await _world(tester);
      w.observed.onLifecycleState(AppLifecycleState.paused);
      final finger = await tester.startGesture(tester.getCenter(_row(1)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(w.follows, 0, reason: 'the radio sleeps: no speculative stream');
      await finger.cancel();
      await tester.pump(const Duration(seconds: 1));
      expect(w.follows, 0);
      w.observed.onLifecycleState(AppLifecycleState.resumed);
      await _finish(tester, w);
    });

    testWidgets('leaving the app while a finger is down lets the hold go at once', (tester) async {
      final w = await _world(tester);
      await tester.startGesture(tester.getCenter(_row(1)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(w.follows, 1);
      w.observed.onLifecycleState(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 7)); // the short linger of a hold, not the 20 s of a screen
      expect(w.source.cancelled, [0], reason: 'nothing follows once nobody looks');
      w.observed.onLifecycleState(AppLifecycleState.resumed);
      await _finish(tester, w);
    });

    testWidgets('at most a few logs are warmed at once: a scroll across the board opens no stream per card', (
      tester,
    ) async {
      final w = await _world(tester, panes: 5, maxWarm: 3);
      final fingers = [for (var i = 1; i <= 5; i++) await tester.startGesture(tester.getCenter(_row(i)), pointer: i)];
      await tester.pump(const Duration(milliseconds: 50));
      expect(w.follows, 3, reason: 'the cap');
      for (final f in fingers) {
        await f.cancel();
      }
      await tester.pump(const Duration(seconds: 7));
      expect(w.source.cancelled, hasLength(3), reason: 'every one of them closes again');
      await _finish(tester, w);
    });
  });

  group('the first frame of an observed chat', () {
    testWidgets('is quiet, says it is connecting, and the first rows come in one swap, not batch by batch', (
      tester,
    ) async {
      final w = await _world(tester, holdTails: true);
      await tester.tap(_row(2));
      await _firstFrame(tester);
      expect(find.byType(AgentSessionScreen), findsOneWidget);
      expect(find.text('Nothing said yet'), findsNothing, reason: 'it is not that nothing was said: nothing is read');
      expect(
        find.descendant(of: find.byType(StatusStrip), matching: find.text('Connecting…')),
        findsOneWidget,
        reason: 'honest: the link is coming up',
      );

      // The host sends the tail in several batches.
      await tester.pump(const Duration(milliseconds: 50));
      expect(w.follows, 1);
      final batches = w.source.tailOf(null, batchLines: 1);
      final last = batches.removeLast();
      expect(last.caughtUp, isTrue);
      for (final b in batches) {
        w.source.streams.first.add(b);
        await tester.pump(const Duration(milliseconds: 40));
        expect(find.textContaining('fix the build', findRichText: true), findsNothing, reason: 'not row by row');
        expect(find.textContaining('Fixed it.', findRichText: true), findsNothing);
      }
      w.source.streams.first.add(last);
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.textContaining('fix the build', findRichText: true), findsOneWidget);
      expect(find.textContaining('Fixed it.', findRichText: true), findsOneWidget, reason: 'all of it, at once');
      await _finish(tester, w);
    });

    testWidgets('a log that never says it caught up still shows what it sent, once the wait is over', (tester) async {
      final w = await _world(tester, holdTails: true);
      await tester.tap(_row(2));
      await tester.pump(const Duration(milliseconds: 50));
      final first = w.source.tailOf(null, batchLines: 1).first;
      w.source.streams.first.add(first);
      await tester.pump(const Duration(milliseconds: 40));
      w.source.streams.first.add(w.source.tailOf(null, batchLines: 1)[1]);
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.textContaining('fix the build', findRichText: true), findsNothing);
      await tester.pump(const Duration(seconds: 3)); // the quiet fallback
      expect(find.textContaining('fix the build', findRichText: true), findsOneWidget);
      await _finish(tester, w);
    });
  });

  group('the entrance of a tap on the board', () {
    testWidgets('is a cut: opaque and in place the first frame it is shown, the board neither moves nor shows', (
      tester,
    ) async {
      final w = await _world(tester);
      final board = tester.getTopLeft(_row(2)).dx;
      await tester.tap(_row(1));
      await tester.pump(); // the route is built off screen once, to be measured
      expect(tester.getTopLeft(_row(2)).dx, board, reason: 'the board is not shifted by a route that is not shown yet');

      for (final ms in [16, 44]) {
        await tester.pump(Duration(milliseconds: ms)); // t = 16 ms, then 60 ms
        final screen = find.byType(AgentSessionScreen);
        expect(screen, findsOneWidget, reason: 'there at t=$ms');
        expect(tester.getTopLeft(screen).dx, 0, reason: 'no slide at t=$ms');
        expect(
          find.ancestor(of: screen, matching: find.byType(FadeTransition)),
          findsNothing,
          reason: 'no fade at t=$ms: opaque from the first frame',
        );
        expect(find.text('open ${_id(2)}'), findsNothing, reason: 'the board is not drawn through it at t=$ms');
      }
      await _finish(tester, w);
    });

    testWidgets('Back is still a pop: the screen slides out and the board comes back from under it', (tester) async {
      final w = await _world(tester);
      final at = tester.getTopLeft(_row(2)).dx;
      await tester.tap(_row(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(); // the board is tied to the page once the entrance has played
      expect(tester.getTopLeft(_row(2)).dx, lessThan(at), reason: 'the board waits to the left, under the page');

      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.getTopLeft(find.byType(AgentSessionScreen)).dx, greaterThan(0), reason: 'it slides away');
      expect(tester.getTopLeft(_row(2)).dx, lessThan(at), reason: 'the board is still sliding back in');
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.getTopLeft(_row(2)).dx, at);
      await _finish(tester, w);
    });

    testWidgets('a tap that replaces the screen in front (the title switcher) is a cut too, and Back is a pop', (
      tester,
    ) async {
      final w = await _world(tester);
      final at = tester.getTopLeft(_row(2)).dx;
      await tester.tap(_row(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      unawaited(openAgent(tester.element(find.byType(AgentSessionScreen)), _agent(2), replace: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.getTopLeft(find.byType(AgentSessionScreen).last).dx, 0, reason: 'in place, no slide');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.getTopLeft(find.byType(AgentSessionScreen)).dx, greaterThan(0), reason: 'it slides away');
      expect(tester.getTopLeft(_row(2)).dx, lessThan(at), reason: 'the board comes back from under it');
      await tester.pump(const Duration(milliseconds: 400));
      await _finish(tester, w);
    });

    testWidgets('a swipe to the next agent slides in from the side, opaque: the old screen is not drawn through it', (
      tester,
    ) async {
      final w = await _world(tester, status: 'blocked');
      await tester.tap(_row(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      swipeToAgent(tester.element(find.byType(AgentSessionScreen)), _agent(1), 1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final incoming = find.byType(AgentSessionScreen).last;
      final first = tester.getTopLeft(incoming).dx;
      await tester.pump(const Duration(milliseconds: 44)); // t = 60 ms
      final dx = tester.getTopLeft(incoming).dx;
      expect(dx, greaterThan(0), reason: 'in from the right');
      expect(dx, lessThan(first), reason: 'the offset animates');
      expect(first, lessThanOrEqualTo(412 * 0.2));
      expect(find.ancestor(of: incoming, matching: find.byType(FadeTransition)), findsNothing);
      expect(find.ancestor(of: incoming, matching: find.byType(Opacity)), findsNothing);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.getTopLeft(find.byType(AgentSessionScreen)).dx, 0, reason: 'in place at the end');
      await _finish(tester, w);
    });
  });

  group('a notification that opens a session', () {
    testWidgets('takes the hold before the route is pushed, as a finger on its row does', (tester) async {
      final sessions = FakeAgentSessions([FakeAgentSession(key: '$_machine/k1')]);
      await tester.pumpWidget(
        ListenableProvider<AgentSessions>.value(
          value: sessions,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => unawaited(openAgentFromLink(context, const SessionAgent('$_machine/k1'))),
                child: const Text('link'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('link'));
      expect(sessions.preconnected, ['$_machine/k1'], reason: 'the attach starts before the first frame of the route');
      expect(sessions.openPreconnects, 1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AgentSessionScreen), findsOneWidget);
      expect(sessions.openPreconnects, 0, reason: 'the screen took the hold over');
    });

    testWidgets('opens the session when its machine lists it, not "no longer on" because a listing was under way', (
      tester,
    ) async {
      final h = await UiHarness.create([
        (
          profile: const MachineProfile(id: _machine, label: 'Mac mini', host: 'h', username: 'u'),
          snapshot: snapshotWith(const []),
        ),
      ]);
      final host = _SlowList();
      host.add(id: 'k1', sessionId: 's1');
      final t = h.transports[_machine]!;
      // The machine is down when the link comes in (the app was just started).
      t.failure = const HerdrTransportException('network down');
      h.fleet.connection(_machine)!.reconnect();
      await settle(tester);
      expect(h.fleet.connection(_machine)!.isLive, isFalse);
      final repo = AgentSessionRepository(fleet: h.fleet, hostFor: (_) => host, recentAttached: 0);
      final opened = <AgentRef>[];
      final links = DeepLinks(
        machines: h.machines,
        fleet: h.fleet,
        patience: const Duration(seconds: 30),
        open: (context, agent) async => opened.add(agent),
        sessions: repo,
      )..attach();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          navigatorKey: links.navigatorKey,
          home: const Scaffold(body: Text('board')),
        ),
      );
      await settle(tester);

      unawaited(links.follow('herdr://session/Mac%20mini/k1'));
      await settle(tester);
      expect(opened, isEmpty, reason: 'nothing to open yet');

      host.listGate = Completer<void>();
      t.failure = null;
      h.fleet.connection(_machine)!.reconnect();
      await settle(tester);
      expect(h.fleet.connection(_machine)!.isLive, isTrue);
      expect(opened, isEmpty, reason: 'the host has not listed yet');
      expect(find.byKey(toastKey), findsNothing, reason: 'a listing under way is not an answer');

      host.listGate!.complete();
      await settle(tester);
      expect(opened, [const SessionAgent('$_machine/k1')]);
      expect(find.byKey(toastKey), findsNothing);
      expect(host.listCalls, 1, reason: 'one listing, asked for once');

      links.dispose();
      await tester.pumpWidget(const SizedBox());
      repo.dispose();
      h.dispose();
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('a session of the board', () {
    // A row as the board's session rows are: a finger down takes the hold.
    Widget sessionBoard(List<String> keys) => Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            for (final key in keys)
              PreconnectTap(
                sessionKey: key,
                builder: (c, take) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => unawaited(openAgent(c, SessionAgent(key), preconnect: take())),
                  child: SizedBox(height: 56, width: double.infinity, child: Text('open $key')),
                ),
              ),
          ],
        ),
      ),
    );

    Future<void> pumpBoard(WidgetTester tester, AgentSessions sessions, List<String> keys, {Widget? under}) async {
      tester.view
        ..physicalSize = const Size(412, 892) * 2
        ..devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ListenableProvider<AgentSessions>.value(
          value: sessions,
          child: MaterialApp(theme: AppTheme.light(), home: sessionBoard(keys)),
        ),
      );
      await settle(tester);
    }

    testWidgets('over a saved copy the first frame already has its rows, under a quiet Updating… strip', (
      tester,
    ) async {
      final session = FakeAgentSession(
        key: '$_machine/k1',
        state: stateWith(items: [userMsg('u1', 'Fix the build'), agentMsg('a1', 'The retry loop never backs off.')]),
        link: AgentLink.connecting,
      )..cachedAsOfValue = DateTime.now().subtract(const Duration(minutes: 3));
      final sessions = FakeAgentSessions([session]);
      await pumpBoard(tester, sessions, ['$_machine/k1']);

      final finger = await tester.startGesture(tester.getCenter(find.text('open $_machine/k1')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(sessions.openPreconnects, 1, reason: 'the attach and the copy are asked for with the finger down');
      await finger.up();
      await _firstFrame(tester);
      expect(find.textContaining('Fix the build', findRichText: true), findsOneWidget, reason: 'rows on frame one');
      expect(find.textContaining('The retry loop never backs off.', findRichText: true), findsOneWidget);
      expect(
        find.descendant(of: find.byType(StatusStrip), matching: find.textContaining('Updating…')),
        findsOneWidget,
        reason: 'honest: it is a saved copy until the keeper has answered',
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(sessions.openPreconnects, 0);
    });

    testWidgets('A, then B, then A: A comes back with its transcript on the first frame', (tester) async {
      final h = await UiHarness.create([
        (
          profile: const MachineProfile(id: _machine, label: 'box', host: 'h', username: 'u'),
          snapshot: snapshotWith(const []),
        ),
      ]);
      final host = FakeAgentHost();
      host.add(id: 'a', sessionId: 'sa')
        ..update(userChunk('question for A', messageId: 'u1'))
        ..update(agentChunk('answer from A', messageId: 'a1'));
      host.add(id: 'b', sessionId: 'sb')
        ..update(userChunk('question for B', messageId: 'u1'))
        ..update(agentChunk('answer from B', messageId: 'a1'));
      // Nothing else keeps a channel: only the screens do.
      final repo = AgentSessionRepository(fleet: h.fleet, hostFor: (_) => host, recentAttached: 0);
      await tester.pump(const Duration(milliseconds: 100));
      await repo.refresh();
      final keys = ['$_machine/a', '$_machine/b'];
      await pumpBoard(tester, repo, keys);

      Future<void> open(String key) async {
        await tester.tap(find.text('open $key'));
        await settle(tester);
      }

      Future<void> back() async {
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await settle(tester);
      }

      await open(keys[0]);
      expect(find.textContaining('answer from A', findRichText: true), findsOneWidget);
      await back();
      await open(keys[1]);
      expect(find.textContaining('answer from B', findRichText: true), findsOneWidget);
      await back();
      expect(host.openLinks, 0, reason: 'nobody holds a channel: both let go');

      host.attachGate = Completer<void>(); // the keeper is slow to answer this time
      await tester.tap(find.text('open ${keys[0]}'));
      await _firstFrame(tester);
      expect(
        find.textContaining('answer from A', findRichText: true),
        findsOneWidget,
        reason: 'what was replayed is still in memory: A paints at once',
      );
      expect(find.textContaining('answer from B', findRichText: true), findsNothing);

      host.attachGate!.complete();
      await settle(tester);
      await tester.pumpWidget(const SizedBox());
      repo.dispose();
      h.dispose();
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
