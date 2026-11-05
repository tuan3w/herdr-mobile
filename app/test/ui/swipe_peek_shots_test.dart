// Renders the swipe between agents mid-gesture on a terminal pane and on an
// agent session: the next (or previous) agent's card partly in (40 dp), at
// the commit distance (64), armed past it (110, `Let go to open`), and the
// end card where the walk stops. Light and
// dark, at 412x892 and at 320x640 with text at 1.6x. Off by default; it
// writes files:
//
//   SWIPE_PEEK_SHOTS=1 flutter test test/ui/swipe_peek_shots_test.dart
//
// Output: /tmp/swipe_peek_shots/<screen>-<state>-<tone>-<width>.png
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/ui/features/agents/agent_navigation.dart';
import 'package:herdr_mobile/ui/features/agents/agent_peek.dart';
import 'package:herdr_mobile/ui/features/agents/agent_swipe.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../../screenshot_test/demo_fleet.dart';
import '../support/fake_agent_session.dart';
import '../support/shot.dart';
import '../support/turn_fixtures.dart';

final _enabled = Platform.environment['SWIPE_PEEK_SHOTS'] == '1';
final _out = Directory('/tmp/swipe_peek_shots');

/// Fake time in 100 ms steps: reads, throttles and animations run on timers.
Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  for (var left = total; left > Duration.zero; left -= const Duration(milliseconds: 100)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(() async {
    await loadAppFonts();
    if (_enabled) _out.createSync(recursive: true);
  });

  const sizes = [(Size(412, 892), 1.0), (Size(320, 640), 1.6)];

  // Each screen is where its walk begins: left shows the next agent that
  // wants the person (with its place in the walk and what it asks or last
  // said), right the end (`No previous agent`).
  final screens = [
    (name: 'pane', agent: const PaneAgent('a', 'a1:p1'), toward: -1.0),
    (name: 'session', agent: const SessionAgent('a/k1'), toward: -1.0),
  ];
  final states = [
    (name: 'in40', by: 40.0, end: false),
    (name: 'at64', by: 64.0, end: false),
    (name: 'armed110', by: 110.0, end: false),
    (name: 'end', by: 110.0, end: true),
  ];

  for (final b in Brightness.values) {
    for (final (size, scale) in sizes) {
      for (final screen in screens) {
        for (final state in states) {
          final name = '${screen.name}-${state.name}-${b.name}-${size.width.toInt()}';
          testWidgets(name, (tester) async {
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
            final h = await DemoFleet.create(timed: true);
            final session = FakeAgentSession(
              key: 'a/k1',
              title: 'Review the ledger migration plan',
              cwd: projectDir,
              machine: h.fleet.connection('a'),
              state: stateWith(items: richTurn()),
            );
            final sessions = FakeAgentSessions([session]);
            TestGesture? finger;
            await shoot(
              tester,
              const HomeShell(),
              '${_out.path}/$name.png',
              brightness: b,
              size: size,
              wrap: demoProviders(h, extra: [ListenableProvider<AgentSessions>.value(value: sessions)]),
              pump: (t) async {
                await h.ageStatuses(t);
                await h.terminalSettings.setWrap(true);
                // The agents' prompt boxes are wider than a 320 dp phone: that
                // terminal scrolls sideways and keeps the swipe. Plain lines there.
                if (size.width < 400) {
                  h.transports['a']!.paneTexts['a1:p1'] = [
                    for (var i = 0; i < 30; i++) 'migrate: applied step ${i + 1} of 30',
                  ].join('\n');
                }
                unawaited(openAgent(t.element(find.byType(HomeShell)), screen.agent));
                await _pumpFor(t, const Duration(milliseconds: 1600));
                final sign = state.end ? -screen.toward : screen.toward;
                final from = t.getCenter(find.byType(AgentSwipe));
                final g = await t.startGesture(from);
                for (var i = 1; i <= 8; i++) {
                  await g.moveBy(Offset(sign * state.by / 8, 0), timeStamp: Duration(milliseconds: 16 * i));
                  await t.pump(const Duration(milliseconds: 16));
                }
                finger = g;
                expect(find.byType(PeekFrame), findsOneWidget);
              },
            );
            await finger?.up(timeStamp: const Duration(milliseconds: 800));
            await tester.pumpWidget(const SizedBox());
            sessions.dispose();
            h.dispose();
          }, skip: !_enabled);
        }
      }
    }
  }
}
