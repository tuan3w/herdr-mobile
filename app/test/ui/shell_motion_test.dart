// The shell's motion and Back: the tab fade, tapping the active tab, Back
// through the tabs, and what sheets and pages do under reduced motion.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/ui/core/chrome.dart';
import 'package:herdr_mobile/ui/core/motion.dart';
import 'package:herdr_mobile/ui/core/theme.dart' hide Type;
import 'package:herdr_mobile/ui/features/agents/agents_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machines_screen.dart';
import 'package:herdr_mobile/ui/features/settings/settings_screen.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../support/shot.dart' show loadAppFonts;
import 'board_support.dart';
import 'ui_harness.dart';

({MachineProfile profile, Map<String, dynamic> snapshot}) _machine(int agents) => (
      profile: MachineProfile(id: 'a', label: 'box-a', host: 'a.example', username: 'dev'),
      snapshot: snapshotWith(
        [for (var i = 1; i <= agents; i++) (id: 'w1:p$i', ws: 'w1', agent: 'claude', status: 'working')],
        title: (id) => 'task ${id.split('p').last}',
      ),
    );

void main() {
  setUpAll(loadAppFonts);

  late List<int> changed;
  late List<MethodCall> platformCalls;
  late int systemPops;
  late int moves;

  setUp(() {
    changed = [];
    platformCalls = [];
    systemPops = 0;
    moves = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call);
      if (call.method == 'SystemNavigator.pop') systemPops++;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<BoardHarness> pump(
    WidgetTester tester, {
    int agents = 14,
    bool reduceMotion = false,
    bool mover = false,
  }) async {
    final h = await BoardHarness.create([_machine(agents)]);
    tester.view
      ..physicalSize = const Size(360, 740) * 2
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: h.providers,
        child: MaterialApp(
          theme: AppTheme.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
            child: child!,
          ),
          home: HomeShell(
            onTabChanged: changed.add,
            moveToBackground: mover
                ? () async {
                    moves++;
                    return true;
                  }
                : null,
          ),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return h;
  }

  Future<void> tapTab(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(FloatingTabBar.tabKey(label)));
    await tester.pump();
  }

  int tabIndex(WidgetTester tester) => tester.widget<FloatingTabBar>(find.byType(FloatingTabBar)).index;

  // The fade over a tab's content, as the shell wraps it.
  double opacityOf(WidgetTester tester, Type screen) => tester
      .widget<FadeTransition>(
        find.ancestor(of: find.byType(screen), matching: find.byType(FadeTransition)).first,
      )
      .opacity
      .value;

  ScrollPosition boardScroll(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byType(AgentsScreen),
          matching: find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical),
        ),
      )
      .position;

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  group('tab switch', () {
    testWidgets('the incoming tab fades in over ~120 ms, opacity only', (tester) async {
      final h = await pump(tester);
      expect(MediaQuery.disableAnimationsOf(tester.element(find.byType(HomeShell))), isFalse);
      expect(opacityOf(tester, AgentsScreen), 1, reason: 'nothing animates at rest or at first paint');

      await tapTab(tester, 'Machines');
      expect(find.byType(MachinesScreen), findsOneWidget);
      final first = opacityOf(tester, MachinesScreen);
      expect(first, lessThan(0.1), reason: 'starts from transparent, never one frame at full opacity');

      await tester.pump(const Duration(milliseconds: 40));
      final mid = opacityOf(tester, MachinesScreen);
      expect(mid, greaterThan(first));
      expect(mid, lessThan(1));
      // No slide: the content sits where it will rest.
      final top = tester.getTopLeft(find.byType(MachinesScreen));
      await tester.pump(const Duration(milliseconds: 100));
      expect(opacityOf(tester, MachinesScreen), 1);
      expect(tester.getTopLeft(find.byType(MachinesScreen)), top);
      expect(Motion.fade, lessThanOrEqualTo(const Duration(milliseconds: 150)));
      await teardownBoard(tester, h);
    });

    testWidgets('switching again restarts the fade for the new tab', (tester) async {
      final h = await pump(tester);
      await tapTab(tester, 'Machines');
      await tester.pump(const Duration(milliseconds: 200));
      await tapTab(tester, 'Settings');
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(opacityOf(tester, SettingsScreen), lessThan(0.1));
      await tester.pump(const Duration(milliseconds: 150));
      expect(opacityOf(tester, SettingsScreen), 1);
      await teardownBoard(tester, h);
    });

    testWidgets('reduced motion: no fade at all', (tester) async {
      final h = await pump(tester, reduceMotion: true);
      await tapTab(tester, 'Machines');
      expect(opacityOf(tester, MachinesScreen), 1);
      await teardownBoard(tester, h);
    });

    testWidgets('a hidden tab is not built before its first visit and does not tick', (tester) async {
      final h = await pump(tester);
      expect(find.byType(MachinesScreen), findsNothing);
      await tapTab(tester, 'Machines');
      await tester.pump(const Duration(milliseconds: 200));
      expect(TickerMode.valuesOf(tester.element(find.byType(AgentsScreen, skipOffstage: false))).enabled, isFalse);
      expect(TickerMode.valuesOf(tester.element(find.byType(MachinesScreen))).enabled, isTrue);
      await teardownBoard(tester, h);
    });
  });

  group('tapping the active tab', () {
    testWidgets('Agents scrolls the board to the top, smoothly, with no tab change and no haptic', (tester) async {
      final h = await pump(tester);
      await tester.drag(find.byType(AgentsScreen), const Offset(0, -900));
      await tester.pumpAndSettle();
      final position = boardScroll(tester);
      expect(position.pixels, greaterThan(300));
      platformCalls.clear();

      await tapTab(tester, 'Agents');
      await tester.pump(const Duration(milliseconds: 60));
      expect(position.pixels, greaterThan(0), reason: 'animated, not a jump');
      await tester.pumpAndSettle();
      expect(position.pixels, 0);
      expect(changed, isEmpty);
      expect(tabIndex(tester), 0);
      expect(platformCalls.where((c) => c.method == 'HapticFeedback.vibrate'), isEmpty);
      await teardownBoard(tester, h);
    });

    testWidgets('under reduced motion the board jumps to the top', (tester) async {
      final h = await pump(tester, reduceMotion: true);
      await tester.drag(find.byType(AgentsScreen), const Offset(0, -900));
      await tester.pumpAndSettle();
      final position = boardScroll(tester);
      expect(position.pixels, greaterThan(300));

      await tapTab(tester, 'Agents');
      expect(position.pixels, 0);
      await teardownBoard(tester, h);
    });

    testWidgets('at the top it stays put; Settings and Machines ignore a re-tap', (tester) async {
      final h = await pump(tester);
      await tapTab(tester, 'Agents');
      await tester.pumpAndSettle();
      expect(boardScroll(tester).pixels, 0);
      expect(changed, isEmpty);

      await tapTab(tester, 'Settings');
      await tester.pumpAndSettle();
      expect(changed, [2]);
      platformCalls.clear();
      await tapTab(tester, 'Settings');
      await tester.pumpAndSettle();
      expect(changed, [2], reason: 'no onTabChanged churn');
      expect(opacityOf(tester, SettingsScreen), 1, reason: 'no new fade');
      expect(platformCalls.where((c) => c.method == 'HapticFeedback.vibrate'), isEmpty);
      await teardownBoard(tester, h);
    });

    testWidgets('a real switch does tick (the control the re-tap test relies on)', (tester) async {
      final h = await pump(tester);
      platformCalls.clear();
      await tapTab(tester, 'Machines');
      expect(platformCalls.where((c) => c.method == 'HapticFeedback.vibrate'), hasLength(1));
      await tester.pumpAndSettle();
      await teardownBoard(tester, h);
    });

    testWidgets('the scroll position of the board survives a trip to another tab', (tester) async {
      final h = await pump(tester);
      await tester.drag(find.byType(AgentsScreen), const Offset(0, -900));
      await tester.pumpAndSettle();
      final before = boardScroll(tester).pixels;
      await tapTab(tester, 'Machines');
      await tester.pumpAndSettle();
      await tapTab(tester, 'Agents');
      await tester.pumpAndSettle();
      expect(boardScroll(tester).pixels, before, reason: 'switching tabs is not "back to the top"');
      await teardownBoard(tester, h);
    });
  });

  group('Back', () {
    testWidgets('from Settings lands on Agents, without leaving the app', (tester) async {
      final h = await pump(tester);
      await tapTab(tester, 'Settings');
      await tester.pumpAndSettle();
      expect(tabIndex(tester), 2);

      await back(tester);
      expect(tabIndex(tester), 0);
      expect(systemPops, 0);
      expect(changed, [2, 0], reason: 'the tab the app is left on is remembered');
      expect(opacityOf(tester, AgentsScreen), 1);

      // Now at the root: Back is the app's again.
      await back(tester);
      expect(systemPops, 1);
      await teardownBoard(tester, h);
    });

    testWidgets('from Machines lands on Agents; watching: only then it goes to the background', (tester) async {
      final h = await pump(tester, mover: true);
      h.fleet.keepAliveInBackground = true;
      await tester.pump();
      await tapTab(tester, 'Machines');
      await tester.pumpAndSettle();

      await back(tester);
      expect(tabIndex(tester), 0);
      expect(moves, 0, reason: 'the first Back only returns to Agents');
      expect(systemPops, 0);

      await back(tester);
      expect(moves, 1);
      expect(systemPops, 0);
      await teardownBoard(tester, h);
    });

    testWidgets('on Agents Back is what it was: a pushed screen first, then leaving', (tester) async {
      final h = await pump(tester);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('pane'))));
      await tester.pumpAndSettle();
      await back(tester);
      await tester.pumpAndSettle();
      expect(find.text('pane'), findsNothing);
      expect(systemPops, 0);
      await back(tester);
      expect(systemPops, 1);
      await teardownBoard(tester, h);
    });
  });

  group('reduced motion: sheets and pages', () {
    // [reduced] is what `Motion.reduced(context)` reads (MediaQuery); [platform]
    // is the OS flag, which route durations read (they have no context) and
    // which the framework's own controllers also shorten themselves for.
    Future<void> pumpApp(
      WidgetTester tester,
      Widget Function(BuildContext) home, {
      bool reduced = false,
      bool platform = false,
    }) async {
      tester.view
        ..physicalSize = const Size(360, 740) * 2
        ..devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      if (platform) {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          builder: reduced
              ? (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(disableAnimations: true),
                    child: child!,
                  )
              : null,
          home: Builder(builder: home),
        ),
      );
    }

    Widget opener(void Function(BuildContext) open) => Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(onPressed: () => open(context), child: const Text('open')),
            ),
          ),
        );

    Widget pusher() => opener(
          (c) => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('page')))),
        );

    FadeTransition pageFade(WidgetTester tester) => tester.widget<FadeTransition>(
          find.ancestor(of: find.text('page'), matching: find.byType(FadeTransition)).first,
        );

    testWidgets('a sheet opens with the usual slide when motion is on', (tester) async {
      await pumpApp(tester, (_) => opener((c) => showAppSheet<void>(c, builder: (_) => const Text('sheet body'))));
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump();
      final route = ModalRoute.of(tester.element(find.text('sheet body')))!;
      expect(route.transitionDuration, Motion.sheetIn);
      expect(route.reverseTransitionDuration, Motion.sheetOut);
      await tester.pumpAndSettle();
    });

    testWidgets('a sheet appears and goes without moving, and still drags away', (tester) async {
      await pumpApp(
        tester,
        (_) => opener(
          (c) => showAppSheet<void>(c, builder: (_) => const SizedBox(height: 200, child: Text('sheet body'))),
        ),
        reduced: true,
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump();
      final route = ModalRoute.of(tester.element(find.text('sheet body')))!;
      expect(route.transitionDuration, Duration.zero);
      expect(route.reverseTransitionDuration, Duration.zero);
      expect(tester.getTopLeft(find.text('sheet body')).dy, lessThan(740), reason: 'on screen at once');

      await tester.fling(find.text('sheet body'), const Offset(0, 400), 1500);
      await tester.pumpAndSettle();
      expect(find.text('sheet body'), findsNothing);
    });

    testWidgets('a page slides in and shifts its parent when motion is on', (tester) async {
      await pumpApp(tester, (_) => pusher());
      final home = tester.getTopLeft(find.text('open'));
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.getTopLeft(find.text('page')).dx, greaterThan(50), reason: 'sliding in');
      expect(tester.getTopLeft(find.text('open')).dx, lessThan(home.dx), reason: 'parallax');
      await tester.pumpAndSettle();
    });

    testWidgets('a page cross-fades: in place from the first frame, parent unmoved', (tester) async {
      await pumpApp(tester, (_) => pusher(), reduced: true);
      final home = tester.getTopLeft(find.text('open'));
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(pageFade(tester).opacity.value, inExclusiveRange(0, 1));
      expect(tester.getTopLeft(find.text('page')).dx, 0, reason: 'no slide');
      expect(tester.getTopLeft(find.text('open')).dx, home.dx, reason: 'no parallax');
      await tester.pumpAndSettle();
      expect(pageFade(tester).opacity.value, 1);

      // And back out the same way.
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(pageFade(tester).opacity.value, inExclusiveRange(0, 1));
      expect(tester.getTopLeft(find.text('page')).dx, 0);
      await tester.pumpAndSettle();
      expect(find.text('page'), findsNothing);
    });

    testWidgets('page routes last <= 150 ms under the OS flag, 260 ms otherwise', (tester) async {
      await pumpApp(tester, (_) => pusher(), platform: true);
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      var route = ModalRoute.of(tester.element(find.text('page')))!;
      expect(route.transitionDuration, lessThanOrEqualTo(const Duration(milliseconds: 150)));
      expect(route.reverseTransitionDuration, lessThanOrEqualTo(const Duration(milliseconds: 150)));
      await tester.pumpAndSettle();
      tester.platformDispatcher.clearAccessibilityFeaturesTestValue();

      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      route = ModalRoute.of(tester.element(find.text('page')))!;
      expect(route.transitionDuration, Motion.page);
      await tester.pumpAndSettle();
    });

    testWidgets('the edge swipe still takes a page back under reduced motion', (tester) async {
      await pumpApp(tester, (_) => pusher(), reduced: true);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('page'), findsOneWidget);

      final gesture = await tester.startGesture(const Offset(4, 300));
      await gesture.moveBy(const Offset(120, 0));
      await tester.pump();
      expect(tester.getTopLeft(find.text('page')).dx, 0, reason: 'the page is not dragged along; it fades');
      expect(pageFade(tester).opacity.value, lessThan(1), reason: 'the fade follows the finger');
      await gesture.moveBy(const Offset(200, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('page'), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });
  });
}
