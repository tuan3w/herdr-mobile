import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/app.dart';
import 'package:herdr_mobile/data/app_info.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/notification_settings.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/repositories/quick_phrases.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/notifier.dart';
import 'package:herdr_mobile/ui/core/chrome.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/machines/machines_screen.dart';
import 'package:herdr_mobile/ui/features/settings/app_switch.dart';
import 'package:herdr_mobile/ui/features/settings/font_size_control.dart';
import 'package:herdr_mobile/ui/features/settings/settings_screen.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../support/fake_network.dart';
import '../support/memory_app_settings_store.dart';
import '../support/memory_quick_phrases_store.dart';
import '../support/memory_snapshot_cache.dart';
import '../support/memory_stores.dart';
import '../support/memory_terminal_settings_store.dart';
import '../support/settings_support.dart';
import '../support/shot.dart' show loadAppFonts;
import 'ui_harness.dart';


class _ScreensStore implements AgentScreensStore {
  _ScreensStore(this.saved);

  FrontAgent? saved;

  @override
  Future<FrontAgent?> read() async => saved;

  @override
  Future<void> write(FrontAgent? front) async => saved = front;
}

class _Launcher extends UrlLauncherPlatform {
  final opened = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add(url);
    return true;
  }
}

/// The real app with in-memory stores and the given settings; the fleet is
/// empty, or [machine] online with one pane `w1:p1`. The fleet is made before
/// the first frame, as the app's boot makes it.
Future<void> pumpApp(
  WidgetTester tester,
  AppSettings app,
  TerminalSettings terminal, {
  AgentScreens? agentScreens,
  MachineProfile? machine,
}) async {
  final machines = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
  await machines.load();
  if (machine != null) await machines.save(machine, secrets: const MachineSecrets(password: 'x'));
  final screens = agentScreens ?? AgentScreens();
  addTearDown(screens.dispose);
  final network = FakeNetwork();
  final fleet = FleetRepository(
    machines: machines,
    network: network,
    screens: screens,
    connect: (profile, secrets) => MachineConnection(
      profile: profile,
      api: HerdrApi(UiTransport(snapshotWith(const [(id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'idle')]))),
      backoff: (_) => const Duration(hours: 1),
    ),
  );
  await fleet.settled();
  await tester.pumpWidget(HerdrMobileApp(
    machines: machines,
    network: network,
    snapshotCache: MemorySnapshotCache(),
    terminalSettings: terminal,
    appSettings: app,
    agentScreens: screens,
    fleet: fleet,
  ));
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> disposeApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 100));
}

SystemUiOverlayStyle barsOf(WidgetTester tester) => tester
    .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
      find.byType(AnnotatedRegion<SystemUiOverlayStyle>).first,
    )
    .value;

Future<void> pumpScreen(
  WidgetTester tester, {
  required AppSettings app,
  required TerminalSettings terminal,
  double width = 360,
  double height = 740,
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view
    ..physicalSize = Size(width, height) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final phrases = QuickPhrases(MemoryQuickPhrasesStore(['continue', 'run the tests']));
  await phrases.load();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: app),
        ChangeNotifierProvider.value(value: terminal),
        ChangeNotifierProvider(create: (_) => NotificationSettings(MemoryNotificationStore())),
        Provider<Notifier>.value(value: const NullNotifier()),
        ChangeNotifierProvider.value(value: phrases),
      ],
      child: MaterialApp(
        theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const Stack(children: [SettingsScreen()]),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> pumpBar(
  WidgetTester tester, {
  required int index,
  required List<TabSpec> tabs,
  ValueChanged<int>? onChanged,
  double width = 320,
  double textScale = 1,
  int settleMs = 400,
  bool reduceMotion = false,
}) async {
  tester.view
    ..physicalSize = Size(width, 400) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale), disableAnimations: reduceMotion),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: FloatingTabBar(index: index, onChanged: onChanged ?? (_) {}, tabs: tabs),
        ),
      ),
    ),
  );
  await tester.pump(Duration(milliseconds: settleMs));
}

const _threeTabs = [
  TabSpec(icon: Icons.list, label: 'Agents', badge: 2),
  TabSpec(icon: Icons.dns, label: 'Machines'),
  TabSpec(icon: Icons.settings, label: 'Settings'),
];

void main() {
  setUpAll(loadAppFonts);

  group('the app follows the theme setting', () {
    testWidgets('light on a fresh install, even when the phone is dark', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final app = AppSettings(MemoryAppSettingsStore());
      await app.load();
      await pumpApp(tester, app, TerminalSettings(MemoryTerminalSettingsStore()));
      expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.light);
      final context = tester.element(find.byType(Scaffold).first);
      expect(Theme.of(context).brightness, Brightness.light);
      expect(barsOf(tester), AppTheme.systemBars(Brightness.light));
      await disposeApp(tester);
    });

    testWidgets('changing it applies at once, bars included', (tester) async {
      final app = AppSettings(MemoryAppSettingsStore());
      await app.load();
      await pumpApp(tester, app, TerminalSettings(MemoryTerminalSettingsStore()));

      await app.setTheme(ThemeChoice.dark);
      await tester.pump();
      expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.dark);
      expect(Theme.of(tester.element(find.byType(Scaffold).first)).brightness, Brightness.dark);
      expect(barsOf(tester), AppTheme.systemBars(Brightness.dark));

      await app.setTheme(ThemeChoice.light);
      await tester.pump();
      expect(Theme.of(tester.element(find.byType(Scaffold).first)).brightness, Brightness.light);
      expect(barsOf(tester), AppTheme.systemBars(Brightness.light));
      await disposeApp(tester);
    });

    testWidgets('system follows the phone, and its bars follow the phone live', (tester) async {
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      final app = AppSettings(MemoryAppSettingsStore(ThemeChoice.system));
      await app.load();
      await pumpApp(tester, app, TerminalSettings(MemoryTerminalSettingsStore()));
      expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.system);
      expect(Theme.of(tester.element(find.byType(Scaffold).first)).brightness, Brightness.dark);
      expect(barsOf(tester), AppTheme.systemBars(Brightness.dark));

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pump();
      expect(Theme.of(tester.element(find.byType(Scaffold).first)).brightness, Brightness.light);
      expect(barsOf(tester), AppTheme.systemBars(Brightness.light));
      await disposeApp(tester);
    });

    testWidgets('a stored dark choice is dark on the very first frame', (tester) async {
      final app = AppSettings(MemoryAppSettingsStore(ThemeChoice.dark));
      await app.load();
      final machines = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
      await machines.load();
      final screens = AgentScreens();
      addTearDown(screens.dispose);
      await tester.pumpWidget(HerdrMobileApp(
        machines: machines,
        network: FakeNetwork(),
        snapshotCache: MemorySnapshotCache(),
        terminalSettings: TerminalSettings(MemoryTerminalSettingsStore()),
        appSettings: app,
        agentScreens: screens,
      ));
      expect(Theme.of(tester.element(find.byType(Scaffold).first)).brightness, Brightness.dark);
      await disposeApp(tester);
    });

    test('the mapping onto ThemeMode', () {
      expect(themeModeOf(ThemeChoice.light), ThemeMode.light);
      expect(themeModeOf(ThemeChoice.dark), ThemeMode.dark);
      expect(themeModeOf(ThemeChoice.system), ThemeMode.system);
    });
  });

  group('the Settings screen', () {
    testWidgets('picking a theme changes the setting and the screen', (tester) async {
      final store = MemoryAppSettingsStore();
      final app = AppSettings(store);
      await pumpScreen(tester, app: app, terminal: TerminalSettings(MemoryTerminalSettingsStore()));
      expect(find.text('Settings'), findsOneWidget);
      await openSettingsGroup(tester, 'Look');
      expect(find.text('Light · Auto · 11.5 pt'), findsOneWidget);

      await tester.tap(find.text('Dark'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(app.theme, ThemeChoice.dark);
      expect(store.writes, ['theme dark']);
      expect(find.text('Dark · Auto · 11.5 pt'), findsOneWidget, reason: 'the row says what it is set to');

      await tester.tap(find.text('System'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(app.theme, ThemeChoice.system);
    });

    testWidgets('font size steps within the pinch range and stays in sync with the pane',
        (tester) async {
      final store = MemoryTerminalSettingsStore();
      final terminal = TerminalSettings(store);
      await pumpScreen(tester, app: AppSettings(MemoryAppSettingsStore()), terminal: terminal, height: 1200);
      await openSettingsGroup(tester, 'Look');
      expect(find.text('11.5'), findsOneWidget);

      expect(FontSizeControl.format(12), '12');
      expect(FontSizeControl.format(12.5), '12.5');

      final plus = find.byWidgetPredicate(
        (w) => w is PressBuilder && w.semanticLabel == 'Increase font size',
      );
      final minus = find.byWidgetPredicate(
        (w) => w is PressBuilder && w.semanticLabel == 'Decrease font size',
      );
      await tester.tap(plus);
      await tester.pump();
      expect(terminal.fontSize, 12.5);
      expect(store.fontSize, 12.5, reason: 'each step is saved');
      expect(find.text('12.5'), findsOneWidget);

      // A pinch in the pane shows here at once.
      terminal.previewFontSize(15);
      await tester.pump();
      expect(find.text('15'), findsOneWidget);

      // The ends are reached exactly and then the button is inert.
      await terminal.setFontSize(8.5);
      await tester.pump();
      await tester.tap(minus);
      await tester.pump();
      expect(terminal.fontSize, minTerminalFontSize);
      await tester.tap(minus);
      await tester.pump();
      expect(terminal.fontSize, minTerminalFontSize);
      expect(store.writes.where((w) => w == 'font 8.0').length, 1, reason: 'no write when inert');

      await terminal.setFontSize(21.5);
      await tester.pump();
      await tester.tap(plus);
      await tester.pump();
      expect(terminal.fontSize, maxTerminalFontSize);
      await tester.tap(plus);
      await tester.pump();
      expect(terminal.fontSize, maxTerminalFontSize);
    });

    testWidgets('the sample line is drawn in the terminal font at the chosen size', (tester) async {
      final terminal = TerminalSettings(MemoryTerminalSettingsStore());
      await pumpScreen(tester, app: AppSettings(MemoryAppSettingsStore()), terminal: terminal);
      await openSettingsGroup(tester, 'Look');
      Text sample() => tester.widget<Text>(find.text(r'$ git status'));
      expect(sample().style!.fontFamily, monoFamily);
      expect(sample().style!.fontSize, 11.5);
      final height = tester.getSize(find.text(r'$ git status')).height;
      final box = find.ancestor(of: find.text(r'$ git status'), matching: find.byType(SizedBox)).first;
      final before = tester.getSize(box).height;
      await terminal.setFontSize(22);
      await tester.pump();
      expect(sample().style!.fontSize, 22);
      expect(tester.getSize(box).height, before, reason: 'stepping never moves what follows');
      expect(tester.getSize(find.text(r'$ git status')).height, greaterThan(height));
    });

    testWidgets('wrap long lines toggles the pane setting both ways', (tester) async {
      final store = MemoryTerminalSettingsStore();
      final terminal = TerminalSettings(store);
      final handle = tester.ensureSemantics();
      await pumpScreen(tester, app: AppSettings(MemoryAppSettingsStore()), terminal: terminal, height: 1200);
      await openSettingsGroup(tester, 'Look');
      Finder row() => find.widgetWithText(SwitchRow, 'Wrap long lines');
      expect(tester.getSemantics(row()).flagsCollection.isToggled, Tristate.isFalse);

      await tester.tap(find.text('Wrap long lines'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(terminal.wrap, isTrue);
      expect(store.wrap, isTrue);
      expect(tester.getSemantics(row()).flagsCollection.isToggled, Tristate.isTrue);

      // Changed from the pane's button.
      await terminal.setWrap(false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getSemantics(row()).flagsCollection.isToggled, Tristate.isFalse);
      handle.dispose();
    });

    testWidgets('the switch row is one node: label, toggled, not a button', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpScreen(
        tester,
        app: AppSettings(MemoryAppSettingsStore()),
        terminal: TerminalSettings(MemoryTerminalSettingsStore()),
      );
      await openSettingsGroup(tester, 'Look');
      final node = tester.getSemantics(find.widgetWithText(SwitchRow, 'Wrap long lines'));
      expect(node.label, contains('Wrap long lines'));
      expect(node.flagsCollection.isButton, isFalse);
      expect(node.flagsCollection.isToggled, isNot(Tristate.none));
      handle.dispose();
    });

    testWidgets('About shows the version and opens the repository in the browser', (tester) async {
      final launcher = _Launcher();
      UrlLauncherPlatform.instance = launcher;
      await pumpScreen(
        tester,
        app: AppSettings(MemoryAppSettingsStore()),
        terminal: TerminalSettings(MemoryTerminalSettingsStore()),
        height: 1800,
      );
      await openSettingsGroup(tester, 'About');
      expect(find.text('Version $appVersion'), findsOneWidget);
      expect(find.textContaining('sends nothing anywhere else'), findsOneWidget);
      await tester.tap(find.text('Source code'));
      await tester.pump();
      expect(launcher.opened, [appRepositoryUrl]);
    });

    testWidgets('Licenses opens the licence page', (tester) async {
      await pumpScreen(
        tester,
        app: AppSettings(MemoryAppSettingsStore()),
        terminal: TerminalSettings(MemoryTerminalSettingsStore()),
        height: 2000, // the whole screen on one page: it grows with every line of copy
      );
      await openSettingsGroup(tester, 'About');
      await tester.tap(find.text('Licenses'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(LicensePage), findsOneWidget);
    });

    for (final brightness in Brightness.values) {
      testWidgets('320 dp at 2x text scrolls without overflow (${brightness.name})', (tester) async {
        await pumpScreen(
          tester,
          app: AppSettings(MemoryAppSettingsStore()),
          terminal: TerminalSettings(MemoryTerminalSettingsStore()),
          width: 320,
          height: 640,
          textScale: 2,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
        // The four rows fit this screen at this size: nothing to scroll for.
        for (final group in ['Look', 'Agents', 'Notifications', 'About']) {
          expect(tester.getRect(find.text(group)).bottom, lessThan(640), reason: group);
        }

        await openSettingsGroup(tester, 'Look');
        expect(tester.takeException(), isNull);
        // Every interactive piece keeps a 44 dp target.
        for (final target in [
          find.byWidgetPredicate((w) => w is PressBuilder && w.semanticLabel == 'Increase font size'),
          find.byWidgetPredicate((w) => w is PressBuilder && w.semanticLabel == 'Decrease font size'),
          find.widgetWithText(SwitchRow, 'Wrap long lines'),
          find.widgetWithText(SwitchRow, 'Dark terminal'),
          find.byType(Segmented<ThemeChoice>),
        ]) {
          final size = tester.getSize(target);
          expect(size.height, greaterThanOrEqualTo(44), reason: '$target');
          expect(size.width, greaterThanOrEqualTo(44), reason: '$target');
        }
        // The three theme options all still read in full.
        for (final label in ['Light', 'Dark', 'System']) {
          final text = tester.renderObject<RenderParagraph>(find.text(label));
          expect(text.didExceedMaxLines, isFalse, reason: label);
        }

        // The Agents group too: its segmented control and the longest summary
        // ("Opens as chat · 2 phrases") meet two lines at this size.
        await openSettingsGroup(tester, 'Agents');
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(Segmented<OpenAgentsAs>)).height, greaterThanOrEqualTo(44));
        for (final label in ['Chat', 'Terminal']) {
          final text = tester.renderObject<RenderParagraph>(find.text(label));
          expect(text.didExceedMaxLines, isFalse, reason: label);
        }
        expect(
          tester.renderObject<RenderParagraph>(find.textContaining('2 phrases')).didExceedMaxLines,
          isFalse,
          reason: 'the row shows the value, wrapping rather than cutting it',
        );

        await openSettingsGroup(tester, 'About');
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        expect(find.text('Licenses'), findsOneWidget);
      });
    }
  });

  group('the floating tab bar with three tabs', () {
    testWidgets('fits 320 dp at 2x text with every tab named and the targets big enough', (tester) async {
      await pumpBar(tester, index: 0, tabs: _threeTabs, textScale: 2);
      expect(tester.takeException(), isNull);
      for (final label in ['Agents', 'Machines', 'Settings']) {
        expect(find.text(label), findsOneWidget, reason: '$label is named, selected or not');
      }

      final bar = tester.getRect(find.byType(FloatingTabBar));
      expect(bar.left, greaterThanOrEqualTo(0));
      expect(bar.right, lessThanOrEqualTo(320));
      for (final label in ['Agents', 'Machines', 'Settings']) {
        final rect = tester.getRect(find.byKey(FloatingTabBar.tabKey(label)));
        expect(rect.width, greaterThanOrEqualTo(44), reason: label);
        expect(rect.height, greaterThanOrEqualTo(44), reason: label);
        expect(rect.left, greaterThanOrEqualTo(0), reason: label);
        expect(rect.right, lessThanOrEqualTo(320), reason: label);
        final text = tester.renderObject<RenderParagraph>(find.text(label));
        expect(text.didExceedMaxLines, isFalse, reason: '$label is never cut');
        expect(tester.getRect(find.text(label)).width, lessThanOrEqualTo(rect.width), reason: label);
      }
    });

    testWidgets('the cells are equal and spread across the width', (tester) async {
      await pumpBar(tester, index: 0, tabs: _threeTabs);
      final rects = [for (final l in ['Agents', 'Machines', 'Settings']) tester.getRect(find.byKey(FloatingTabBar.tabKey(l)))];
      expect(rects[1].width, rects[0].width);
      expect(rects[2].width, rects[0].width);
      final bar = tester.getRect(find.byType(FloatingTabBar));
      expect(rects.first.left - bar.left, lessThan(20), reason: 'the cells fill the pill, not a cluster in its middle');
      expect(bar.right - rects.last.right, lessThan(20));
    });

    testWidgets('nothing moves when the selection does', (tester) async {
      Future<List<Rect>> cells(int index) async {
        await tester.pumpWidget(const SizedBox());
        await pumpBar(tester, index: index, tabs: _threeTabs);
        return [for (final l in ['Agents', 'Machines', 'Settings']) tester.getRect(find.byKey(FloatingTabBar.tabKey(l)))];
      }

      final first = await cells(0);
      expect(await cells(1), first);
      expect(await cells(2), first);
    });

    testWidgets('stops growing on a wide window and stays centred', (tester) async {
      await pumpBar(tester, index: 0, tabs: _threeTabs, width: 900);
      final left = tester.getRect(find.byKey(FloatingTabBar.tabKey('Agents'))).left;
      final right = tester.getRect(find.byKey(FloatingTabBar.tabKey('Settings'))).right;
      expect(left, greaterThan(100), reason: 'not stretched to the window edge');
      expect(left + right, closeTo(900, 1), reason: 'centred');
    });

    for (final selected in [0, 1, 2]) {
      testWidgets('a 99+ badge stays on screen and off the labels at 320 dp, tab $selected selected', (tester) async {
        await pumpBar(
          tester,
          index: selected,
          textScale: 2,
          tabs: const [
            TabSpec(icon: Icons.list, label: 'Agents', badge: 120),
            TabSpec(icon: Icons.dns, label: 'Machines'),
            TabSpec(icon: Icons.settings, label: 'Settings'),
          ],
        );
        expect(tester.takeException(), isNull);
        final badge = tester.getRect(find.text('99+'));
        expect(badge.left, greaterThanOrEqualTo(0));
        for (final label in ['Agents', 'Machines', 'Settings']) {
          expect(badge.overlaps(tester.getRect(find.text(label))), isFalse, reason: 'the count is not written over $label');
        }
      });
    }

    testWidgets('announces the selected tab and the spoken badge, once each', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpBar(tester, index: 1, tabs: _threeTabs);
      final agents = tester.getSemantics(find.byKey(FloatingTabBar.tabKey('Agents')));
      expect(agents.label, 'Agents, 2 need you');
      expect(agents.flagsCollection.isSelected, Tristate.isFalse);
      expect(agents.flagsCollection.isButton, isTrue);
      final machines = tester.getSemantics(find.byKey(FloatingTabBar.tabKey('Machines')));
      expect(machines.label, 'Machines');
      expect(machines.flagsCollection.isSelected, Tristate.isTrue);
      final settings = tester.getSemantics(find.byKey(FloatingTabBar.tabKey('Settings')));
      expect(settings.label, 'Settings');
      expect(settings.flagsCollection.isSelected, Tristate.isFalse);
      handle.dispose();
    });

    testWidgets('tapping a tab selects it', (tester) async {
      final taps = <int>[];
      await pumpBar(tester, index: 0, tabs: _threeTabs, onChanged: taps.add);
      await tester.tap(find.byKey(FloatingTabBar.tabKey('Settings')));
      await tester.tap(find.byKey(FloatingTabBar.tabKey('Machines')));
      expect(taps, [2, 1]);
    });

    group('the selection capsule', () {
      Rect capsule(WidgetTester tester) => tester.getRect(find.byKey(FloatingTabBar.capsuleKey));
      Rect cell(WidgetTester tester, String label) => tester.getRect(find.byKey(FloatingTabBar.tabKey(label)));

      testWidgets('sits under the chosen tab, and slides there from where it was, never past it', (tester) async {
        await pumpBar(tester, index: 0, tabs: _threeTabs);
        expect(capsule(tester).left, closeTo(cell(tester, 'Agents').left, 0.5));
        final from = capsule(tester).left;
        final to = cell(tester, 'Settings').left;

        // Same widgets, a new index: a move, not a new capsule.
        await pumpBar(tester, index: 2, tabs: _threeTabs, settleMs: 0);
        await tester.pump(const Duration(milliseconds: 60));
        final mid = capsule(tester).left;
        expect(mid, greaterThan(from), reason: 'it has left the old tab');
        expect(mid, lessThan(to), reason: 'and has not arrived');
        await tester.pump(const Duration(milliseconds: 400));
        expect(capsule(tester).left, closeTo(to, 0.5));
        expect(capsule(tester).width, closeTo(cell(tester, 'Settings').width, 0.5), reason: 'one cell wide, whichever');
      });

      testWidgets('a second tap retargets it from where it is, without a jump', (tester) async {
        await pumpBar(tester, index: 0, tabs: _threeTabs);
        await pumpBar(tester, index: 2, tabs: _threeTabs, settleMs: 80);
        final mid = capsule(tester).left;
        await pumpBar(tester, index: 1, tabs: _threeTabs, settleMs: 0);
        await tester.pump();
        expect((capsule(tester).left - mid).abs(), lessThan(20), reason: 'it carries on from the live position');
      });

      testWidgets('reduced motion: it is under the chosen tab at once', (tester) async {
        await pumpBar(tester, index: 0, tabs: _threeTabs, reduceMotion: true);
        await pumpBar(tester, index: 2, tabs: _threeTabs, reduceMotion: true, settleMs: 16);
        expect(capsule(tester).left, closeTo(cell(tester, 'Settings').left, 0.5));
      });

      testWidgets('is still at rest: no animation left running', (tester) async {
        await pumpBar(tester, index: 1, tabs: _threeTabs);
        expect(tester.hasRunningAnimations, isFalse);
      });

      testWidgets('the text warms as the capsule arrives under it and cools as it leaves, in step with it', (tester) async {
        Color colour(String label) => tester.widget<Text>(find.text(label)).style!.color!;
        // 0 at textSecondary, 1 at text, read off the red channel.
        double warmth(String label) =>
            (colour(label).r - Ds.paper.textSecondary.r) / (Ds.paper.text.r - Ds.paper.textSecondary.r);
        // 1 with the capsule centred on the cell, 0 a cell or more away.
        double under(WidgetTester tester, String label) {
          final c = cell(tester, label);
          return (1 - (capsule(tester).left - c.left).abs() / c.width).clamp(0.0, 1.0);
        }

        await pumpBar(tester, index: 0, tabs: _threeTabs);
        expect(warmth('Agents'), closeTo(1, 0.01));
        expect(warmth('Machines'), closeTo(0, 0.01));

        await pumpBar(tester, index: 2, tabs: _threeTabs, settleMs: 0);
        for (final ms in [16, 24, 40]) {
          await tester.pump(Duration(milliseconds: ms));
          for (final label in ['Agents', 'Machines', 'Settings']) {
            expect(warmth(label), closeTo(under(tester, label), 0.03), reason: '$label at +${ms}ms');
          }
        }
        expect(warmth('Machines'), greaterThan(0), reason: 'the capsule passed under it, so it warmed on the way');
        await tester.pump(const Duration(milliseconds: 400));
        expect(warmth('Settings'), closeTo(1, 0.01));
        expect(warmth('Agents'), closeTo(0, 0.01));
      });

      group('dragged along the bar', () {
        Future<TestGesture> grab(WidgetTester tester, List<int> taps) async {
          await pumpBar(tester, index: 0, tabs: _threeTabs, onChanged: taps.add);
          return tester.startGesture(cell(tester, 'Agents').center);
        }

        Future<void> drag(WidgetTester tester, TestGesture g, double dx) async {
          for (var moved = 0.0; moved < dx; moved += 5) {
            await g.moveBy(const Offset(5, 0));
          }
          await tester.pump(const Duration(milliseconds: 250)); // held still: no momentum
        }

        Future<void> settle(WidgetTester tester) => tester.pumpAndSettle();

        testWidgets('follows the finger, and the tab changes where it is let go', (tester) async {
          final taps = <int>[];
          final g = await grab(tester, taps);
          final from = capsule(tester).left;
          const travelled = 130.0; // the finger's steps of 5 dp, until past one cell and a bit
          await drag(tester, g, 126);
          final moved = capsule(tester).left - from;
          expect(moved, lessThanOrEqualTo(travelled), reason: 'never ahead of the finger');
          expect(moved, greaterThan(travelled - 30), reason: 'it came along with it, the touch slop aside: no glide of its own');
          expect(taps, isEmpty, reason: 'nothing is chosen while the finger is down');
          await g.up();
          expect(taps, [1]);
        });

        testWidgets('a short drag that ends nearer where it began chooses nothing, and the capsule goes back', (tester) async {
          final taps = <int>[];
          final g = await grab(tester, taps);
          await drag(tester, g, 30);
          await g.up();
          await settle(tester);
          expect(taps, isEmpty);
          expect(capsule(tester).left, closeTo(cell(tester, 'Agents').left, 0.5));
          expect(tester.hasRunningAnimations, isFalse);
        });

        testWidgets('a bar whose owner did not take the choice gets its capsule back under the chosen tab', (tester) async {
          final taps = <int>[];
          final g = await grab(tester, taps);
          await drag(tester, g, cell(tester, 'Agents').width + 30);
          await g.up();
          await settle(tester);
          expect(taps, [1]);
          expect(capsule(tester).left, closeTo(cell(tester, 'Agents').left, 0.5), reason: 'index is still 0');
        });

        testWidgets('a flick is enough: it goes where it would have coasted', (tester) async {
          final taps = <int>[];
          await pumpBar(tester, index: 0, tabs: _threeTabs, onChanged: taps.add);
          await tester.fling(find.byKey(FloatingTabBar.tabKey('Agents')), const Offset(50, 0), 900);
          await settle(tester);
          expect(taps, hasLength(1));
          expect(taps.single, greaterThan(0));
        });

        testWidgets('dragged past the last tab the capsule stops at the pill, never outside it', (tester) async {
          final taps = <int>[];
          await pumpBar(tester, index: 2, tabs: _threeTabs, onChanged: taps.add);
          final g = await tester.startGesture(cell(tester, 'Settings').center);
          for (var i = 0; i < 40; i++) {
            await g.moveBy(const Offset(5, 0));
          }
          await tester.pump();
          expect(capsule(tester).right, closeTo(cell(tester, 'Settings').right, 0.5));
          expect(capsule(tester).right, lessThanOrEqualTo(tester.getRect(find.byType(FloatingTabBar)).right));
          await tester.pump(const Duration(milliseconds: 250));
          await g.up();
          await settle(tester);
          expect(taps, isEmpty);
          expect(capsule(tester).left, closeTo(cell(tester, 'Settings').left, 0.5));
        });
      });
    });
  });

  group('the shell', () {
    testWidgets('has Settings as the third tab, kept beside the others', (tester) async {
      final h = await UiHarness.create([]);
      await pumpUi(tester, h, width: 320, textScale: 2);
      expect(tester.takeException(), isNull);
      expect(find.byType(SettingsScreen), findsNothing, reason: 'built on first visit');

      await tester.tap(find.byKey(FloatingTabBar.tabKey('Settings')));
      await settle(tester);
      expect(find.byType(SettingsScreen).hitTestable(), findsOneWidget);
      expect(find.text('Look'), findsOneWidget);

      await tester.tap(find.byKey(FloatingTabBar.tabKey('Machines')));
      await settle(tester);
      expect(find.byType(MachinesScreen).hitTestable(), findsOneWidget);
      expect(find.byType(SettingsScreen).hitTestable(), findsNothing);

      await tester.tap(find.byKey(FloatingTabBar.tabKey('Settings')));
      await settle(tester);
      expect(find.byType(SettingsScreen).hitTestable(), findsOneWidget);
      await teardownUi(tester, h);
    });

    testWidgets('the Settings tab survives the process being reclaimed', (tester) async {
      final h = await UiHarness.create([]);
      tester.view
        ..physicalSize = const Size(360, 740) * 2
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
            ChangeNotifierProvider(create: (_) => NotificationSettings(MemoryNotificationStore())),
            Provider<Notifier>.value(value: const NullNotifier()),
            attentionSetProvider(),
          ],
          child: MaterialApp(
            restorationScopeId: 'app',
            theme: AppTheme.light(),
            home: const HomeShell(),
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.byKey(FloatingTabBar.tabKey('Settings')));
      await settle(tester);
      await tester.restartAndRestore();
      await settle(tester);
      expect(find.byType(SettingsScreen).hitTestable(), findsOneWidget);
      await teardownUi(tester, h);
    });

    testWidgets('changing the theme in Settings reaches the harness settings', (tester) async {
      final h = await UiHarness.create([]);
      await pumpUi(tester, h, brightness: Brightness.light);
      await tester.tap(find.byKey(FloatingTabBar.tabKey('Settings')));
      await settle(tester);
      // The group folds open, then scrolls itself into view: the next tap is
      // after the page has stopped, as a person's would be.
      await openSettingsGroup(tester, 'Look');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dark'));
      await settle(tester);
      expect(h.appSettings.theme, ThemeChoice.dark);
      await teardownUi(tester, h);
    });
  });

  group('the app remembers where it was', () {
    testWidgets('it opens on the tab it was left on, and remembers a switch', (tester) async {
      final store = MemoryAppSettingsStore()..homeTab = 1;
      final app = AppSettings(store);
      await app.load();
      await pumpApp(tester, app, TerminalSettings(MemoryTerminalSettingsStore()));
      expect(find.byType(MachinesScreen).hitTestable(), findsOneWidget);

      await tester.tap(find.byKey(FloatingTabBar.tabKey('Settings')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(app.homeTab, 2);
      expect(store.homeTab, 2);
      await disposeApp(tester);
    });

    testWidgets('a theme change does not put the shell back on its first tab', (tester) async {
      final app = AppSettings(MemoryAppSettingsStore()..homeTab = 2);
      await app.load();
      await pumpApp(tester, app, TerminalSettings(MemoryTerminalSettingsStore()));
      await app.setTheme(ThemeChoice.dark);
      await tester.pump();
      expect(find.byType(SettingsScreen).hitTestable(), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('the app puts the agent screen it was left on back in front, once, without the slide; leaving to the board forgets it', (tester) async {
      const machine = MachineProfile(id: 'm1', label: 'workstation', host: 'h', username: 'u');
      const pane = PaneAgent('m1', 'w1:p1');
      final store = _ScreensStore(const FrontAgent(pane, AgentView.terminal));
      final screens = AgentScreens(store);
      await screens.load();
      final app = AppSettings(MemoryAppSettingsStore());
      await app.load();
      await pumpApp(tester, app, TerminalSettings(MemoryTerminalSettingsStore()), agentScreens: screens, machine: machine);
      // No time passes: a page transition would still be under way.
      for (var i = 0; i < 3; i++) {
        await tester.pump();
      }
      expect(tester.widget<PaneScreen>(find.byType(PaneScreen)).agent, pane);
      expect(
        ModalRoute.of(tester.element(find.byType(PaneScreen)))!.animation!.status,
        AnimationStatus.completed,
        reason: 'in place on the first frames, as if the app never closed',
      );
      expect(screens.takeResume(), isNull, reason: 'once');

      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(PaneScreen), findsNothing);
      expect(find.byType(HomeShell), findsOneWidget);
      expect(store.saved, isNull, reason: 'back on the board: nothing to put back');
      await disposeApp(tester);

      final next = AgentScreens(store);
      await next.load();
      await pumpApp(tester, app, TerminalSettings(MemoryTerminalSettingsStore()), agentScreens: next, machine: machine);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(PaneScreen), findsNothing, reason: 'the next launch opens on the board');
      await disposeApp(tester);
    });
  });

  group('the terminal palette follows the theme', () {
    TerminalPalette paletteUnder(WidgetTester tester) =>
        tester.element(find.byType(Scaffold).first).terminal;

    testWidgets('light on paper, dark on ink, dark on paper when asked', (tester) async {
      final app = AppSettings(MemoryAppSettingsStore());
      await app.load();
      await pumpApp(tester, app, TerminalSettings(MemoryTerminalSettingsStore()));
      expect(paletteUnder(tester), same(TerminalPalette.light));

      await app.setTheme(ThemeChoice.dark);
      await tester.pump();
      expect(paletteUnder(tester), same(TerminalPalette.dark));

      await app.setTheme(ThemeChoice.light);
      await app.setDarkTerminal(true);
      await tester.pump();
      expect(paletteUnder(tester), same(TerminalPalette.dark));

      await app.setDarkTerminal(false);
      await tester.pump();
      expect(paletteUnder(tester), same(TerminalPalette.light));
      await disposeApp(tester);
    });

    testWidgets('the Dark terminal switch in Settings sets it', (tester) async {
      final app = AppSettings(MemoryAppSettingsStore());
      await pumpScreen(tester, app: app, terminal: TerminalSettings(MemoryTerminalSettingsStore()));
      await openSettingsGroup(tester, 'Look');
      await tester.ensureVisible(find.text('Dark terminal'));
      await tester.pump();
      await tester.tap(find.text('Dark terminal'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(app.darkTerminal, isTrue);
    });
  });
}
