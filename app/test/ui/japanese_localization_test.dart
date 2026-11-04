import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/notification_settings.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/notifier.dart';
import 'package:herdr_mobile/l10n/app_localizations.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/settings/settings_screen.dart';
import 'package:provider/provider.dart';

import '../support/memory_app_settings_store.dart';
import '../support/memory_terminal_settings_store.dart';
import '../support/settings_support.dart';
import '../support/shot.dart' show loadAppFonts, shoot;

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
}
