// Renders the first frames of an open from the board to PNGs for review
// (light and dark, 412x892): what the person sees the first moment the screen
// is up, and the entrance part-way through (t = 60 ms). Off by default:
//
//   OPEN_SHOTS=1 flutter test test/ui/open_instant_shots_test.dart
//
// Output: $OPEN_SHOTS_DIR (default /dev/shm/opensessions/shots)/<case>-<light|dark>.png
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/observed/omp_kind.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/observed_sessions.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agents/agent_navigation.dart';
import 'package:herdr_mobile/ui/features/agents/preconnect_tap.dart';
import 'package:provider/provider.dart';

import '../support/fake_agent_session.dart';
import '../support/fake_log_source.dart';
import '../support/shot.dart';
import 'ui_harness.dart';

const _machine = 'm1';

/// What a pane's card does with its finger: down starts the hold, the tap
/// hands it on.
class _PaneRow extends StatelessWidget {
  const _PaneRow(this.agent, [this.title = 'Fix the login retry']);

  final PaneAgent agent;
  final String title;

  @override
  Widget build(BuildContext context) => PreconnectTap(
    start: (c) => preconnectObservedChat(c, agent),
    builder: (c, take) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(openAgent(c, agent, preconnect: take())),
      child: _Card(title: title, where: 'api · main · omp'),
    ),
  );
}

class _SessionRow extends StatelessWidget {
  const _SessionRow(this.key_);

  final String key_;

  @override
  Widget build(BuildContext context) => PreconnectTap(
    sessionKey: key_,
    builder: (c, take) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(openAgent(c, SessionAgent(key_), preconnect: take())),
      child: _Card(title: 'Fix the login retry', where: 'api · main · claude'),
    ),
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.where});

  final String title;
  final String where;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Type.bodyStrong),
        const SizedBox(height: 4),
        Text(where, style: Type.secondary),
      ],
    ),
  );
}

class _Board extends StatelessWidget {
  const _Board(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Agents')),
    body: Column(children: [child]),
  );
}

List<String> _log() => [
  sessionLine(),
  userLine('u1', 'The login retry hammers the server when the token expires. Can you make it back off?'),
  assistantLine(
    'a1',
    'The retry loop never backs off: it sleeps a fixed 200 ms and tries again forever.\n\n'
        'I will change it to an exponential back-off with jitter, capped at 30 s, and stop after 6 attempts.',
  ),
  userLine('u2', 'Yes, and add a test.'),
  assistantLine('a2', 'Done: `retry.dart` now backs off, and `retry_test.dart` covers the cap and the jitter.'),
];

void main() {
  if (Platform.environment['OPEN_SHOTS'] == null) {
    test('open shots are off (set OPEN_SHOTS=1)', () {}, skip: 'set OPEN_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['OPEN_SHOTS_DIR'] ?? '/dev/shm/opensessions/shots';
  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  Future<void> grab(WidgetTester tester, GlobalKey key, String name) async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/$name.png').writeAsBytes(data!.buffer.asUint8List());
    });
  }

  Future<void> firstFrame(WidgetTester tester, [int ms = 16]) async {
    await tester.pump();
    await tester.pump(Duration(milliseconds: ms));
  }

  Widget app(GlobalKey key, Brightness brightness, Widget home) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    builder: (context, child) => RepaintBoundary(key: key, child: child!),
    home: home,
  );

  void size(WidgetTester tester) {
    tester.view
      ..physicalSize = phone * 2.625
      ..devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
  }

  for (final brightness in Brightness.values) {
    final mode = brightness.name;

    // -- an observed chat: omp in a pane ---------------------------------------
    Future<(UiHarness, ObservedSessions, GlobalKey)> observedWorld(
      WidgetTester tester, {
      bool holdTails = false,
      int panes = 1,
      String status = 'working',
    }) async {
      size(tester);
      final snapshot = snapshotWith([
        for (var i = 1; i <= panes; i++) (id: 'w1:p$i', ws: 'w1', agent: 'omp', status: status),
      ]);
      for (final p in (snapshot['panes'] as List).cast<Map<String, dynamic>>()) {
        p['agent_session'] = {'agent': 'omp', 'kind': 'path', 'value': ompLog};
      }
      final h = await UiHarness.create([
        (profile: const MachineProfile(id: _machine, label: 'box', host: 'h', username: 'u'), snapshot: snapshot),
      ]);
      h.transports[_machine]!.paneText = 'ready';
      final source = FakeLogSource()
        ..holdTails = holdTails
        ..write(_log());
      final observed = ObservedSessions(
        fleet: h.fleet,
        previews: h.previews,
        sourceFor: (_) => source,
        kinds: {'omp': ompKind},
      );
      final key = GlobalKey();
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
          child: app(
            key,
            brightness,
            _Board(
              Column(
                children: [for (var i = 1; i <= panes; i++) _PaneRow(PaneAgent(_machine, 'w1:p$i'), 'Agent number $i')],
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      return (h, observed, key);
    }

    Future<void> done(WidgetTester tester, UiHarness h, ObservedSessions observed) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 30));
      observed.dispose();
      h.dispose();
      await tester.pump(const Duration(seconds: 1));
    }

    // The finger rests on the card for ~100 ms before it lifts: what the hold
    // has had time to bring.
    testWidgets('observed, finger down 100 ms, first frame ($mode)', (tester) async {
      final (h, observed, key) = await observedWorld(tester);
      final finger = await tester.startGesture(tester.getCenter(find.text('Agent number 1')));
      await tester.pump(const Duration(milliseconds: 100));
      await finger.up();
      await firstFrame(tester);
      await grab(tester, key, 'observed-press-first-$mode');
      await tester.pump(const Duration(milliseconds: 400));
      await grab(tester, key, 'observed-press-settled-$mode');
      await done(tester, h, observed);
    });

    // The log is slow: nothing has come when the screen is up.
    testWidgets('observed, nothing read yet, first frame and 400 ms ($mode)', (tester) async {
      final (h, observed, key) = await observedWorld(tester, holdTails: true);
      await tester.tap(find.text('Agent number 1'));
      await firstFrame(tester);
      await grab(tester, key, 'observed-cold-first-$mode');
      await tester.pump(const Duration(milliseconds: 400));
      await grab(tester, key, 'observed-cold-t400-$mode');
      await done(tester, h, observed);
    });

    // The entrance: a cut. First shown frame, and 60 ms in.
    testWidgets('entrance cut ($mode)', (tester) async {
      final (h, observed, key) = await observedWorld(tester);
      await tester.tap(find.text('Agent number 1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await grab(tester, key, 'entrance-t16ms-$mode');
      await tester.pump(const Duration(milliseconds: 44));
      await grab(tester, key, 'entrance-t60ms-$mode');
      await done(tester, h, observed);
    });

    // Back: the pop, part-way through.
    testWidgets('back pop ($mode)', (tester) async {
      final (h, observed, key) = await observedWorld(tester);
      await tester.tap(find.text('Agent number 1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      await grab(tester, key, 'back-pop-60ms-$mode');
      await done(tester, h, observed);
    });

    // The swipe walk's step: the next agent slides in (200 ms, 20% of the width).
    testWidgets('swipe walk step ($mode)', (tester) async {
      final (h, observed, key) = await observedWorld(tester, panes: 2, status: 'blocked');
      await tester.tap(find.text('Agent number 1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      swipeToAgent(tester.element(find.byType(Scaffold).last), const PaneAgent(_machine, 'w1:p1'), 1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await grab(tester, key, 'swipe-walk-t16ms-$mode');
      await tester.pump(const Duration(milliseconds: 44));
      await grab(tester, key, 'swipe-walk-t60ms-$mode');
      await tester.pump(const Duration(milliseconds: 60));
      await grab(tester, key, 'swipe-walk-t120ms-$mode');
      await tester.pump(const Duration(milliseconds: 400));
      await done(tester, h, observed);
    });

    // -- a session the app started (ACP) ---------------------------------------
    Future<GlobalKey> sessionWorld(WidgetTester tester, FakeAgentSession session) async {
      size(tester);
      final key = GlobalKey();
      await tester.pumpWidget(
        ListenableProvider<AgentSessions>.value(
          value: FakeAgentSessions([session]),
          child: app(key, brightness, _Board(_SessionRow(session.key))),
        ),
      );
      await settle(tester);
      return key;
    }

    testWidgets('session over a saved copy, first frame ($mode)', (tester) async {
      final session = FakeAgentSession(
        key: '$_machine/k1',
        state: stateWith(
          items: [
            userMsg('u1', 'The login retry hammers the server when the token expires. Can you make it back off?'),
            agentMsg('a1', 'The retry loop never backs off: it sleeps a fixed 200 ms and tries again forever.'),
          ],
        ),
        link: AgentLink.connecting,
      )..cachedAsOfValue = DateTime.now().subtract(const Duration(minutes: 3));
      final key = await sessionWorld(tester, session);
      final finger = await tester.startGesture(tester.getCenter(find.text('Fix the login retry')));
      await tester.pump(const Duration(milliseconds: 100));
      await finger.up();
      await firstFrame(tester);
      await grab(tester, key, 'session-copy-first-$mode');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('session with no saved copy and a cold link, first frame and 400 ms ($mode)', (tester) async {
      final session = FakeAgentSession(key: '$_machine/k1', link: AgentLink.connecting);
      final key = await sessionWorld(tester, session);
      await tester.tap(find.text('Fix the login retry'));
      await firstFrame(tester);
      await grab(tester, key, 'session-cold-first-$mode');
      await tester.pump(const Duration(milliseconds: 400));
      await grab(tester, key, 'session-cold-t400-$mode');
      await tester.pumpWidget(const SizedBox());
    });
  }
}
