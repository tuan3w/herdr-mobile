// Settings is four rows (Look, Agents, Notifications, About), each saying what
// it is set to and opening in place, one at a time, with a newer version's row
// above them. These tests hold the rules that keep it four rows long.
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/app_info.dart';
import 'package:herdr_mobile/data/models/release_info.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/app_update.dart';
import 'package:herdr_mobile/data/repositories/notification_settings.dart';
import 'package:herdr_mobile/data/repositories/quick_phrases.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/notifier.dart';
import 'package:herdr_mobile/ui/core/motion.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/settings/quick_phrases_editor.dart';
import 'package:herdr_mobile/ui/features/settings/settings_screen.dart';
import 'package:provider/provider.dart';

import '../support/fake_notifier.dart';
import '../support/memory_app_settings_store.dart';
import '../support/memory_quick_phrases_store.dart';
import '../support/memory_terminal_settings_store.dart';
import '../support/settings_support.dart';
import '../support/shot.dart' show loadAppFonts;
import '../support/update_fakes.dart';

final _release = ReleaseInfo(
  version: '99.0.0',
  apkUrl: 'https://example.invalid/herdr-mobile-99.0.0.apk',
  size: 48 * 1024 * 1024,
  pageUrl: 'https://example.invalid/releases/tag/v99.0.0',
  notes: '',
  sha256: 'a' * 64,
);

/// An updater with the fakes behind it; [found] is whether a newer version was
/// already found.
({AppUpdate update, FakeReleaseFeed feed, FakeReleaseFiles files}) _updater(WidgetTester tester) {
  final feed = FakeReleaseFeed()..answer = _release;
  final files = FakeReleaseFiles();
  final update = AppUpdate(
    store: MemoryUpdateStore(),
    feed: feed,
    files: files,
    installer: FakeApkInstaller(),
    current: AppVersion.tryParse('0.1.0'),
  );
  addTearDown(update.dispose);
  return (update: update, feed: feed, files: files);
}

/// [showing] is whether the tab is in front: the shell turns tickers off in the
/// tabs that are not.
Future<void> _pump(
  WidgetTester tester, {
  AppUpdate? update,
  Notifier? notifier,
  NotificationChoice notifications = const NotificationChoice(),
  List<String>? phrases = const ['continue', 'run the tests'],
  ValueNotifier<bool>? showing,
}) async {
  tester.view
    ..physicalSize = const Size(360, 740) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final notificationSettings = NotificationSettings(MemoryNotificationStore(notifications));
  await notificationSettings.load();
  QuickPhrases? quick;
  if (phrases != null) {
    quick = QuickPhrases(MemoryQuickPhrasesStore(phrases));
    await quick.load();
  }
  final front = showing ?? ValueNotifier(true);
  addTearDown(front.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppSettings(MemoryAppSettingsStore())),
        ChangeNotifierProvider(create: (_) => TerminalSettings(MemoryTerminalSettingsStore())),
        ChangeNotifierProvider.value(value: notificationSettings),
        if (quick != null) ChangeNotifierProvider.value(value: quick),
        Provider<Notifier>.value(value: notifier ?? const NullNotifier()),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: ValueListenableBuilder<bool>(
          valueListenable: front,
          builder: (context, on, _) => TickerMode(enabled: on, child: SettingsScreen(update: update)),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUpAll(loadAppFonts);

  group('the four groups', () {
    testWidgets('start closed; nothing inside one is on the screen', (tester) async {
      await _pump(tester);
      for (final title in ['Look', 'Agents', 'Notifications', 'About']) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.text('Theme'), findsNothing);
      expect(find.text('Open agents as'), findsNothing);
      expect(find.text('Licenses'), findsNothing);
      expect(find.text('Update available'), findsNothing, reason: 'no newer version, no row');
    });

    testWidgets('opening one closes the other; tapping the open one closes it', (tester) async {
      await _pump(tester);
      await openSettingsGroup(tester, 'Look');
      expect(find.text('Theme'), findsOneWidget);

      await openSettingsGroup(tester, 'Agents');
      expect(find.text('Open agents as'), findsOneWidget);
      expect(find.text('Theme'), findsNothing, reason: 'one at a time');

      await openSettingsGroup(tester, 'Agents');
      expect(find.text('Open agents as'), findsNothing);
    });

    testWidgets('a group that closes folds away; its controls do not vanish first', (tester) async {
      await _pump(tester);
      await openSettingsGroup(tester, 'Look');
      await tester.ensureVisible(find.text('Agents'));
      await tester.pump();
      await tester.tap(find.text('Agents'));
      await tester.pump();
      await tester.pump(Motion.expand ~/ 4);
      expect(find.text('Theme'), findsOneWidget, reason: 'still there while the space folds');
      await tester.pump(Motion.expand + const Duration(milliseconds: 30));
      expect(find.text('Theme'), findsNothing);
    });

    testWidgets('a row says whether it is open', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester);
      Tristate expanded() => tester.getSemantics(find.text('Look')).flagsCollection.isExpanded;
      expect(expanded(), Tristate.isFalse);
      await openSettingsGroup(tester, 'Look');
      expect(expanded(), Tristate.isTrue);
      handle.dispose();
    });

    testWidgets('reduced motion: a group opens at once and nothing is left moving', (tester) async {
      await _pump(tester);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await tester.pump();
      await tester.tap(find.text('Look'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Theme'), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('rows that say what is set', () {
    testWidgets('Notifications says Android blocks them while it is closed', (tester) async {
      await _pump(
        tester,
        notifier: FakeNotifier(granted: false),
        notifications: const NotificationChoice(enabled: true),
      );
      expect(find.text('Blocked by Android'), findsOneWidget);
      expect(find.textContaining('Android is blocking'), findsNothing, reason: 'the detail waits for the tap');
      await openSettingsGroup(tester, 'Notifications');
      expect(find.textContaining('Android is blocking'), findsOneWidget);
    });

    testWidgets('Agents counts its phrases, and has no count or row without them', (tester) async {
      await _pump(tester);
      expect(find.textContaining('2 phrases'), findsOneWidget);

      await _pump(tester, phrases: null);
      expect(find.textContaining('phrase'), findsNothing);
      await openSettingsGroup(tester, 'Agents');
      expect(find.text('Quick phrases'), findsNothing);
    });
  });

  group('a newer version', () {
    testWidgets('is the one row open on entry, with Download one tap away', (tester) async {
      final u = _updater(tester);
      await u.update.check();
      await _pump(tester, update: u.update);
      expect(find.text('Update available'), findsOneWidget);
      expect(find.text('Theme'), findsNothing, reason: 'the others stay closed');

      await tester.tap(find.text('Download'));
      await tester.pump();
      expect(u.update.stage, UpdateStage.downloading);
    });

    testWidgets('found while the tab is behind another opens when it is next shown', (tester) async {
      final u = _updater(tester);
      final showing = ValueNotifier(true);
      await _pump(tester, update: u.update, showing: showing);
      expect(find.text('Update available'), findsNothing);
      await openSettingsGroup(tester, 'Look');

      showing.value = false;
      await tester.pump();
      await u.update.check();
      await tester.pump();
      showing.value = true;
      await tester.pump();
      await tester.pump(Motion.expand * 2);
      expect(find.text('Download'), findsOneWidget, reason: 'the dot brought the person here: one tap');
      expect(find.text('Theme'), findsNothing, reason: 'Look made way for it');
    });

    testWidgets('found while the page is showing does not move what the person has open', (tester) async {
      final u = _updater(tester);
      await _pump(tester, update: u.update);
      await openSettingsGroup(tester, 'Look');

      await u.update.check();
      await tester.pump();
      await tester.pump(Motion.expand * 2);
      expect(find.text('Update available'), findsOneWidget, reason: 'the row appears');
      expect(find.text('Theme'), findsOneWidget, reason: 'nothing moves under the thumb');
      expect(find.text('Download'), findsNothing);
    });

    testWidgets('keeps its progress in sight behind another group', (tester) async {
      final u = _updater(tester);
      await u.update.check();
      await _pump(tester, update: u.update);
      await tester.tap(find.text('Download'));
      await tester.pump();
      u.files.report(20 * 1024 * 1024);
      await tester.pump();

      await openSettingsGroup(tester, 'Look');
      expect(find.text('Download'), findsNothing, reason: 'its body closed with the others');
      expect(find.textContaining('Downloading 20 MB of 48 MB'), findsOneWidget);
      expect(find.bySemanticsLabel('Download progress'), findsOneWidget);
    });

    testWidgets('a failure is a short line on the row and the whole sentence once, in the body', (tester) async {
      const reason = 'The download stopped at 31 MB of 48 MB. It continues from there when you try again.';
      final u = _updater(tester);
      await u.update.check();
      await _pump(tester, update: u.update);
      await tester.tap(find.text('Download'));
      await tester.pump();
      u.files.running!.completeError(const UpdateException(reason));
      await tester.pump();
      await tester.pump();

      expect(find.text(reason), findsOneWidget, reason: 'said once, whole');
      expect(find.text('Update failed, open to see why'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('a download that finishes or fails is announced with its group closed', (tester) async {
      final handle = tester.ensureSemantics();
      final u = _updater(tester);
      await u.update.check();
      await _pump(tester, update: u.update);
      bool live() => tester.getSemantics(find.text('Update available')).flagsCollection.isLiveRegion;
      expect(live(), isFalse, reason: 'nothing to announce yet');

      await tester.tap(find.text('Download'));
      await tester.pump();
      await openSettingsGroup(tester, 'Look');
      u.files.running!.complete(File('/x.apk'));
      await tester.pump();
      await tester.pump();
      expect(u.update.stage, UpdateStage.ready);
      expect(live(), isTrue);
      handle.dispose();
    });

    testWidgets('says the version once: About points up instead of repeating it', (tester) async {
      final u = _updater(tester);
      await u.update.check();
      await _pump(tester, update: u.update);
      await openSettingsGroup(tester, 'About');
      expect(find.text('Version $appVersion'), findsOneWidget, reason: 'only About\'s own row');
      expect(find.textContaining('99.0.0 is available'), findsOneWidget);
    });
  });

  group('quick phrases', () {
    testWidgets('are their own page, opened from Agents and left by Back', (tester) async {
      await _pump(tester);
      await openSettingsGroup(tester, 'Agents');
      await tester.tap(find.text('Quick phrases'));
      await tester.pumpAndSettle();
      expect(find.byType(QuickPhrasesPage), findsOneWidget);
      expect(find.text('run the tests'), findsOneWidget);
      expect(find.text('Add a phrase'), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(QuickPhrasesPage), findsNothing);
      expect(find.text('Open agents as'), findsOneWidget, reason: 'back where it was');
    });
  });
}
