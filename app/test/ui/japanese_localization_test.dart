import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/notification_settings.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/notifier.dart';
import 'package:herdr_mobile/data/words/elapsed.dart';
import 'package:herdr_mobile/l10n/app_localizations.dart';
import 'package:herdr_mobile/l10n/app_localizations_en.dart';
import 'package:herdr_mobile/l10n/app_localizations_ja.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/settings/settings_screen.dart';
import 'package:provider/provider.dart';

import '../support/memory_app_settings_store.dart';
import '../support/memory_terminal_settings_store.dart';
import '../support/settings_support.dart';
import '../support/shot.dart' show loadAppFonts, shoot;
import 'ui_harness.dart';

Widget _app(ValueNotifier<Locale> locale, {Brightness brightness = Brightness.light, double scale = 1}) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppSettings(MemoryAppSettingsStore())),
        ChangeNotifierProvider(create: (_) => TerminalSettings(MemoryTerminalSettingsStore())),
        ChangeNotifierProvider(create: (_) => NotificationSettings(MemoryNotificationStore())),
        Provider<Notifier>.value(value: const NullNotifier()),
      ],
      child: ValueListenableBuilder<Locale>(
        valueListenable: locale,
        builder: (_, language, _) => MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          locale: language,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SettingsScreen(),
        ),
      ),
    );

void main() {
  setUpAll(loadAppFonts);
  if (Platform.environment['HERDR_JA_SHOTS'] == '1') {
    final out = Directory('/tmp/herdr-ja-shots')..createSync(recursive: true);
    for (final brightness in Brightness.values) {
      for (final size in [const Size(412, 892), const Size(320, 640)]) {
        for (final scale in [1.0, 1.6]) {
          final name = '${brightness.name}-${size.width.toInt()}-$scale';
          testWidgets('Japanese settings render $name', (tester) async {
            final locale = ValueNotifier(const Locale('ja'));
            addTearDown(locale.dispose);
            await shoot(
              tester,
              _app(locale, brightness: brightness, scale: scale),
              '${out.path}/settings-$name.png',
              brightness: brightness,
              size: size,
              pump: (tester) => openSettingsGroup(tester, '外観'),
            );
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  }

  testWidgets('Japanese controls retain the selected theme across a locale change', (tester) async {
    final locale = ValueNotifier(const Locale('ja', 'JP'));
    addTearDown(locale.dispose);
    await tester.pumpWidget(_app(locale));
    await tester.pumpAndSettle();
    for (final label in ['設定', '外観', 'エージェント', '通知', 'ストレージ', 'このアプリについて']) {
      expect(find.text(label), findsOneWidget);
    }
    await openSettingsGroup(tester, '外観');
    expect(find.text('文字サイズ'), findsOneWidget);
    expect(find.text('自動'), findsOneWidget);
    await tester.tap(find.text('ダーク'));
    await tester.pumpAndSettle();
    final settings = tester.element(find.byType(SettingsScreen)).read<AppSettings>();
    expect(settings.theme, ThemeChoice.dark);
    locale.value = const Locale('en');
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);
    expect(settings.theme, ThemeChoice.dark);
    expect(tester.takeException(), isNull);
  });
  testWidgets('an unsupported language falls back to English', (tester) async {
    final locale = ValueNotifier(const Locale('fr'));
    addTearDown(locale.dispose);
    await tester.pumpWidget(_app(locale));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Look'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('Japanese counts and freshness', () {
    final ja = AppLocalizationsJa();
    final en = AppLocalizationsEn();

    test('the count resources say the Japanese words and keep the English plurals', () {
      expect(ja.machinesHealth(2, 5), '5台中2台');
      expect(ja.machineCount(1), 'マシン1台');
      expect(ja.machineCount(5), 'マシン5台');
      expect(ja.agentCount(3), 'エージェント3件');
      expect(ja.statusNeedsYou(1), '対応待ち1件');
      expect(ja.statusNeedsYou(2), '対応待ち2件');
      expect(ja.statusToReview(2), '確認待ち2件');
      expect(ja.statusWorking(4), '実行中4件');
      expect(ja.statusNotConnected(1), '未接続1件');
      expect(ja.machinesNotConnected(2), '未接続2台');
      expect(ja.allMachinesOff, '全マシン停止');
      expect(ja.noAgents, 'エージェントなし');
      expect(ja.heardJustNow, 'たった今応答');
      expect(ja.heardAgo(Elapsed.compact(const Duration(minutes: 3), seconds: false, l10n: ja)), '最終応答：3分前');

      expect(en.machineCount(1), '1 machine');
      expect(en.machineCount(2), '2 machines');
      expect(en.agentCount(1), '1 agent');
      expect(en.agentCount(2), '2 agents');
      expect(en.machinesHealth(1, 2), '1 of 2 machines');
      expect(en.statusNeedsYou(1), '1 needs you');
      expect(en.statusNeedsYou(2), '2 need you');
      expect(en.heardJustNow, 'heard just now');
      expect(en.heardAgo('3m'), 'heard 3m ago');
    });

    test('the compact elapsed labels use Japanese units and keep English', () {
      expect(Elapsed.compact(Duration.zero, seconds: false, l10n: ja), '1分未満');
      expect(Elapsed.compact(const Duration(minutes: 59), seconds: false, l10n: ja), '59分');
      expect(Elapsed.compact(const Duration(hours: 1, minutes: 5), seconds: false, l10n: ja), '1時間5分');
      expect(Elapsed.compact(const Duration(days: 3), seconds: false, l10n: ja), '3日');

      expect(Elapsed.compact(Duration.zero, seconds: false, l10n: en), '<1m');
      expect(Elapsed.compact(const Duration(minutes: 59), seconds: false, l10n: en), '59m');
      expect(Elapsed.compact(const Duration(hours: 1, minutes: 5), seconds: false, l10n: en), '1h 05m');
      expect(Elapsed.compact(const Duration(days: 3), seconds: false, l10n: en), '3d');
      expect(Elapsed.compact(const Duration(hours: 23, minutes: 59), seconds: false), '23h 59m');
    });

    testWidgets('the board says its counts and freshness in Japanese', (tester) async {
      final h = await UiHarness.create([
        (
          profile: const MachineProfile(id: 'a', label: 'solo', host: 'a.example', username: 'dev'),
          snapshot: snapshotWith([
            (id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'blocked'),
            (id: 'w1:p2', ws: 'w1', agent: 'claude', status: 'working'),
          ]),
        ),
      ]);
      await pumpUi(tester, h, locale: const Locale('ja'), height: 1600);

      expect(find.text('1台中1台'), findsOneWidget);
      expect(find.textContaining('対応待ち1件', findRichText: true), findsOneWidget);
      expect(find.textContaining('実行中1件', findRichText: true), findsOneWidget);
      expect(find.textContaining('たった今応答', findRichText: true), findsOneWidget);
      expect(find.textContaining(' needs you', findRichText: true), findsNothing);
      await teardownUi(tester, h);
    });

    testWidgets('the machines screen counts machines and agents in Japanese', (tester) async {
      final h = await UiHarness.create([
        (
          profile: const MachineProfile(id: 'a', label: 'solo', host: 'a.example', username: 'dev'),
          snapshot: snapshotWith([
            (id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'working'),
            (id: 'w1:p2', ws: 'w1', agent: 'codex', status: 'idle'),
          ]),
        ),
      ]);
      await pumpUi(tester, h, locale: const Locale('ja'), height: 1600);
      await tester.tap(find.byKey(const ValueKey('machine-health')));
      await settle(tester);

      expect(find.text('マシン1台'), findsOneWidget);
      expect(find.textContaining('エージェント2件', findRichText: true), findsOneWidget);
      expect(find.textContaining(' machines', findRichText: true), findsNothing);
      await teardownUi(tester, h);
    });
  });
}
