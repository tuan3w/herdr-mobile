// Renders the bottom bars to PNGs for review (light and dark, 412x892 and
// 320x640, text scale 1 and 2): the board at rest (the tab bar and the triage
// pill over it), the board picking (the batch actions in the tab bar's slot),
// the agent session's bar with its subagents chip, and the session overview
// sheet it opens (tall: it must stop below the status bar). Off by default; it
// writes files:
//
//   BARS_SHOTS=1 flutter test test/ui/bottom_bars_shots_test.dart
//
// Output: $BARS_SHOTS_DIR (default /tmp/bars_shots)/<case>-<light|dark>-<w>x<h>[-x<scale>].png
@TestOn('vm')
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/core/toast.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_bar.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import '../support/fake_agent_session.dart';
import '../support/shot.dart' show loadAppFonts;
import '../support/subagent_fixtures.dart';
import 'board_support.dart';
import 'ui_harness.dart';

Pane _pane(int i, String status) => (id: 'w1:p$i', ws: 'w1', agent: 'claude', status: status);

/// Three working, two waiting, two done, three idle, on one machine.
List<Pane> _ten() => [
  for (var i = 1; i <= 3; i++) _pane(i, 'working'),
  for (var i = 4; i <= 5; i++) _pane(i, 'blocked'),
  for (var i = 6; i <= 7; i++) _pane(i, 'done'),
  for (var i = 8; i <= 10; i++) _pane(i, 'idle'),
];

/// 25 subagent runs, one of them asking the person.
FakeAgentSession _subagents() {
  final updates = <Json>[];
  for (var i = 0; i < 25; i++) {
    updates.add(launch('r$i', description: 'Subagent number $i', type: 'Explore', status: 'in_progress'));
    if (i >= 4) updates.add(i % 7 == 0 ? toolUpdate('r$i', status: 'failed') : finished('r$i', seconds: 20 + i, tools: i));
  }
  updates.add(childTool('askc', 'r0'));
  return FakeAgentSession(title: 'payments-api', state: play(updates).withPending(PendingPermission(1, askFor('askc'))));
}

void main() {
  if (Platform.environment['BARS_SHOTS'] == null) {
    test('bottom bars shots are off (set BARS_SHOTS=1)', () {}, skip: 'set BARS_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['BARS_SHOTS_DIR'] ?? '/tmp/bars_shots';

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  Future<void> shoot(
    WidgetTester tester,
    String name,
    Widget Function() home,
    Size size,
    Brightness brightness, {
    double scale = 1,
    List<SingleChildWidget> providers = const [],
    Future<void> Function()? then,
  }) async {
    const dpr = 2.625;
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    tester.view.padding = const FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr);
    tester.view.viewPadding = tester.view.padding;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    final app = MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      navigatorObservers: [ToastRouteObserver()],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: RepaintBoundary(key: key, child: child!),
      ),
      home: home(),
    );
    // `flutter test` paints a BoxShadow without its blur (`debugDisableShadows`,
    // on in the test binding), as a hard offset band. These shots exist to
    // judge the shadow, so they draw it as a phone does; the binding checks
    // the flag is back before the test ends, so it is put back right here.
    debugDisableShadows = false;
    try {
      await tester.pumpWidget(providers.isEmpty ? app : MultiProvider(providers: providers, child: app));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await then?.call();
      await tester.pump(const Duration(milliseconds: 600));
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final tag = '${size.width.toInt()}x${size.height.toInt()}${scale == 1 ? '' : '-x${scale.toInt()}'}';
        await File('$out/$name-${brightness.name}-$tag.png').writeAsBytes(data!.buffer.asUint8List());
      });
    } finally {
      debugDisableShadows = true;
    }
    expect(tester.takeException(), isNull, reason: '$name ${brightness.name} $size x$scale');
  }

  const sizes = [Size(412, 892), Size(320, 640)];
  const scales = [1.0, 2.0];

  for (final brightness in Brightness.values) {
    for (final size in sizes) {
      for (final scale in scales) {
        final tag = '${brightness.name} ${size.width.toInt()}x${size.height.toInt()} x$scale';

        testWidgets('board at rest $tag', (tester) async {
          final h = await BoardHarness.create([
            (
              profile: const MachineProfile(id: 'a', label: 'studio-mac', host: 'a.example', username: 'dev'),
              snapshot: snapshotWith(_ten(), title: (id) => 'task ${id.split('p').last}'),
            ),
          ]);
          await shoot(tester, 'board', HomeShell.new, size, brightness, scale: scale, providers: h.providers);
          await teardownBoard(tester, h);
        });

        testWidgets('board picking $tag', (tester) async {
          final h = await BoardHarness.create([
            (
              profile: const MachineProfile(id: 'a', label: 'studio-mac', host: 'a.example', username: 'dev'),
              snapshot: snapshotWith(_ten(), title: (id) => 'task ${id.split('p').last}'),
            ),
          ]);
          await shoot(
            tester,
            'board-picking',
            HomeShell.new,
            size,
            brightness,
            scale: scale,
            providers: h.providers,
            then: () async {
              await tester.longPress(find.text('task 4').first);
              await tester.pump(const Duration(milliseconds: 600));
            },
          );
          await teardownBoard(tester, h);
        });

        testWidgets('session bar $tag', (tester) async {
          final session = _subagents();
          await shoot(tester, 'session-bar', () => Scaffold(body: SessionBar(session: session)), size, brightness, scale: scale);
        });

        testWidgets('session overview $tag', (tester) async {
          final session = FakeAgentSession(title: 'payments-api', state: overviewState());
          await shoot(
            tester,
            'session-overview',
            () => Scaffold(body: SessionBar(session: session)),
            size,
            brightness,
            scale: scale,
            then: () async {
              await tester.tap(find.text('payments-api'));
              await tester.pumpAndSettle();
            },
          );
        });
      }
    }
  }
}
