// Home and its Back: the header that opens Machines and Settings as pages
// (there is no tab bar), Back from them, and what sheets and pages do under
// reduced motion.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/release_info.dart';
import 'package:herdr_mobile/data/repositories/app_update.dart';
import 'package:herdr_mobile/ui/core/kit.dart' hide Type;
import 'package:herdr_mobile/ui/features/agents/agents_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machines_screen.dart';
import 'package:herdr_mobile/ui/features/settings/settings_screen.dart';
import 'package:herdr_mobile/ui/shell/home_pages.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../support/update_fakes.dart';
import '../support/shot.dart' show loadAppFonts;
import 'board_support.dart';
import 'ui_harness.dart';

({MachineProfile profile, Map<String, dynamic> snapshot}) _machine(int agents) => (
  profile: MachineProfile(id: 'a', label: 'box-a', host: 'a.example', username: 'dev'),
  snapshot: snapshotWith([
    for (var i = 1; i <= agents; i++) (id: 'w1:p$i', ws: 'w1', agent: 'claude', status: 'working'),
  ], title: (id) => 'task ${id.split('p').last}'),
);

void main() {
  setUpAll(loadAppFonts);

  late List<MethodCall> platformCalls;
  late int systemPops;
  late int moves;

  setUp(() {
    platformCalls = [];
    systemPops = 0;
    moves = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        platformCalls.add(call);
        if (call.method == 'SystemNavigator.pop') systemPops++;
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  Future<BoardHarness> pump(
    WidgetTester tester, {
    int agents = 14,
    bool reduceMotion = false,
    bool mover = false,
    AppUpdate? update,
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
            pages: HomePages(update: update),
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

  final chip = find.byKey(const ValueKey('machine-health'));

  Future<void> openMachines(WidgetTester tester) async {
    await tester.tap(chip);
    await tester.pumpAndSettle();
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
  }

  // Home has no tab bar (owner decision: most of the time the person cares
  // about agents, not machines, and the bar cost focus and covered the end of
  // the list). Machines and Settings are pages its header opens.
  group('home', () {
    testWidgets('has no bar under it: the board runs to the bottom', (tester) async {
      final h = await pump(tester);
      expect(find.byType(FloatingBarPill), findsNothing);
      expect(find.byType(FloatingBarScrim), findsNothing);
      await teardownBoard(tester, h);
    });

    testWidgets('the header: the machines chip on the left, + and Settings on the right', (tester) async {
      final h = await pump(tester);
      expect(chip, findsOneWidget);
      expect(find.text('1 of 1 machine'), findsOneWidget);
      final title = tester.getRect(find.text('Agents').first);
      final mark = tester.getRect(find.byKey(const ValueKey('machine-health-mark')));
      expect(mark.left, moreOrLessEquals(title.left, epsilon: 1), reason: 'on the large title’s edge');
      expect(tester.getSize(chip).height, greaterThanOrEqualTo(kMinTap));
      final plus = tester.getRect(find.byTooltip('New agent session'));
      final gear = tester.getRect(find.byTooltip('Settings'));
      expect(plus.right, lessThan(gear.left), reason: '+ first, the gear last');
      expect(
        find.descendant(of: find.byType(SliverLargeTitle), matching: find.byType(CircleButton)),
        findsNWidgets(2),
        reason: 'two trailing actions, the budget',
      );
      await teardownBoard(tester, h);
    });

    testWidgets('the chip opens Machines with Back in its bar; Back returns home, then leaves', (tester) async {
      final h = await pump(tester);
      await openMachines(tester);
      expect(find.byType(MachinesScreen), findsOneWidget);
      expect(find.byType(AppBackButton), findsOneWidget);

      await back(tester);
      await tester.pumpAndSettle();
      expect(find.byType(MachinesScreen), findsNothing);
      expect(find.byType(AgentsScreen), findsOneWidget);
      expect(systemPops, 0);

      // Now at the root: Back is the app's again.
      await back(tester);
      expect(systemPops, 1);
      await teardownBoard(tester, h);
    });

    testWidgets('a quick second tap opens one page, not two', (tester) async {
      final h = await pump(tester);
      await tester.tap(chip);
      await tester.pump();
      await tester.tap(chip, warnIfMissed: false);
      await tester.pumpAndSettle();
      await back(tester);
      await tester.pumpAndSettle();
      expect(find.byType(MachinesScreen), findsNothing, reason: 'one Back is home');
      await teardownBoard(tester, h);
    });

    testWidgets('the board under a page does not tick, and keeps its place', (tester) async {
      final h = await pump(tester);
      await tester.drag(find.byType(AgentsScreen), const Offset(0, -900));
      await tester.pumpAndSettle();
      final before = boardScroll(tester).pixels;
      expect(before, greaterThan(0));
      await openMachines(tester);
      expect(TickerMode.valuesOf(tester.element(find.byType(AgentsScreen, skipOffstage: false))).enabled, isFalse);
      await back(tester);
      await tester.pumpAndSettle();
      expect(boardScroll(tester).pixels, before);
      await teardownBoard(tester, h);
    });

    testWidgets('the gear opens Settings, at its top; Back returns home', (tester) async {
      final h = await pump(tester);
      await openSettings(tester);
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.byType(AppBackButton), findsOneWidget);
      await back(tester);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing);
      expect(systemPops, 0);
      await teardownBoard(tester, h);
    });

    testWidgets('a newer version is a quiet dot on the gear, and its row is the first thing in Settings', (
      tester,
    ) async {
      final update = AppUpdate(
        store: MemoryUpdateStore(),
        feed: FakeReleaseFeed()
          ..answer = const ReleaseInfo(
            version: '99.0.0',
            apkUrl: 'https://example.invalid/herdr-mobile-99.0.0.apk',
            size: 48 * 1024 * 1024,
            pageUrl: 'https://example.invalid/releases/tag/v99.0.0',
            notes: 'notes',
            sha256: 'aaaa',
          ),
        files: FakeReleaseFiles(),
        installer: FakeApkInstaller(),
        current: AppVersion.tryParse('0.1.0'),
      );
      addTearDown(update.dispose);
      final h = await pump(tester, update: update);
      final mark = find.byKey(const ValueKey('circle-button-mark'));
      expect(mark, findsNothing);
      expect(find.bySemanticsLabel('Settings'), findsOneWidget);

      await update.check();
      await tester.pump();
      expect(mark, findsOneWidget);
      expect(find.bySemanticsLabel('Settings, update available'), findsOneWidget);

      await openSettings(tester);
      expect(find.text('Update available').hitTestable(), findsOneWidget);
      await teardownBoard(tester, h);
    });
  });

  group('Back', () {
    testWidgets('from Machines lands home; watching: only then it goes to the background', (tester) async {
      final h = await pump(tester, mover: true);
      h.fleet.keepAliveInBackground = true;
      await tester.pump();
      await openMachines(tester);

      await back(tester);
      await tester.pumpAndSettle();
      expect(find.byType(MachinesScreen), findsNothing);
      expect(moves, 0, reason: 'the first Back only returns home');
      expect(systemPops, 0);

      await back(tester);
      expect(moves, 1);
      expect(systemPops, 0);
      await teardownBoard(tester, h);
    });

    testWidgets('on home Back is what it was: a pushed screen first, then leaving', (tester) async {
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
        tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
          disableAnimations: true,
        );
        addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          builder: reduced
              ? (context, child) =>
                    MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!)
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
