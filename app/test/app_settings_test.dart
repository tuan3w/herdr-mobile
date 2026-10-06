import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/app_info.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_app_settings_store.dart';

class _BrokenStore implements AppSettingsStore {
  @override
  Future<ThemeChoice?> readTheme() async => throw StateError('disk gone');

  @override
  Future<void> writeTheme(ThemeChoice theme) async {}

  @override
  Future<bool?> readDarkTerminal() async => throw StateError('disk gone');

  @override
  Future<void> writeDarkTerminal(bool dark) async {}

  @override
  Future<int?> readHomeTab() async => throw StateError('disk gone');

  @override
  Future<void> writeHomeTab(int tab) async {}

  @override
  Future<BoardDensity?> readDensity() async => throw StateError('disk gone');

  @override
  Future<void> writeDensity(BoardDensity density) async {}

  @override
  Future<OpenAgentsAs?> readOpenAgentsAs() async => throw StateError('disk gone');

  @override
  Future<void> writeOpenAgentsAs(OpenAgentsAs value) async {}

  @override
  Future<bool?> readSmoothText() async => throw StateError('disk gone');

  @override
  Future<void> writeSmoothText(bool value) async {}
}

void main() {
  group('AppSettings', () {
    test('is light when nothing was ever stored', () async {
      final settings = AppSettings(MemoryAppSettingsStore());
      expect(settings.theme, ThemeChoice.light, reason: 'before load');
      await settings.load();
      expect(settings.theme, ThemeChoice.light);
      expect(AppSettings.defaultTheme, ThemeChoice.light);
    });

    test('is light when the store cannot be read', () async {
      final settings = AppSettings(_BrokenStore());
      await settings.load();
      expect(settings.theme, ThemeChoice.light);
    });

    test('every stored choice survives a restart', () async {
      for (final choice in ThemeChoice.values) {
        final store = MemoryAppSettingsStore();
        await AppSettings(store).setTheme(choice);
        final reopened = AppSettings(store);
        await reopened.load();
        expect(reopened.theme, choice);
      }
    });

    test('a change notifies once, applies before the save finishes, and is saved', () async {
      final store = MemoryAppSettingsStore();
      final settings = AppSettings(store);
      var notified = 0;
      settings.addListener(() => notified++);
      final saved = settings.setTheme(ThemeChoice.dark);
      expect(settings.theme, ThemeChoice.dark);
      expect(notified, 1);
      await saved;
      expect(store.writes, ['theme dark']);
      await settings.setTheme(ThemeChoice.dark);
      expect(notified, 1, reason: 'same value: no rebuild');
    });

    test('the terminal follows the theme until told to stay dark', () async {
      final store = MemoryAppSettingsStore();
      final settings = AppSettings(store);
      await settings.load();
      expect(settings.darkTerminal, isFalse);
      var notified = 0;
      settings.addListener(() => notified++);
      await settings.setDarkTerminal(true);
      expect(settings.darkTerminal, isTrue);
      expect(notified, 1);
      expect(store.writes, ['darkTerminal true']);

      final reopened = AppSettings(store);
      await reopened.load();
      expect(reopened.darkTerminal, isTrue);
    });

    test('the tab the app was left on is remembered, quietly', () async {
      final store = MemoryAppSettingsStore();
      final settings = AppSettings(store);
      await settings.load();
      expect(settings.homeTab, 0);
      var notified = 0;
      settings.addListener(() => notified++);
      await settings.setHomeTab(2);
      await settings.setHomeTab(2);
      expect(notified, 0, reason: 'the shell already shows it');
      expect(store.writes, ['homeTab 2']);

      final reopened = AppSettings(store);
      await reopened.load();
      expect(reopened.homeTab, 2);
    });

    test('a tab that does not exist falls back to Agents', () async {
      for (final bad in [-1, 3, 99]) {
        final settings = AppSettings(MemoryAppSettingsStore()..homeTab = bad);
        await settings.load();
        expect(settings.homeTab, 0, reason: '$bad');
      }
      final settings = AppSettings(MemoryAppSettingsStore());
      await settings.setHomeTab(7);
      expect(settings.homeTab, 0);
    });

    test('smooth text is on until turned off, applies at once and is remembered', () async {
      final store = MemoryAppSettingsStore();
      final settings = AppSettings(store);
      expect(settings.smoothText, isTrue, reason: 'before load');
      await settings.load();
      expect(settings.smoothText, isTrue);
      var notified = 0;
      settings.addListener(() => notified++);
      await settings.setSmoothText(false);
      expect(settings.smoothText, isFalse);
      expect(notified, 1);
      expect(store.writes, ['smoothText false']);

      final reopened = AppSettings(store);
      await reopened.load();
      expect(reopened.smoothText, isFalse);
    });

    test('a store that cannot be read gives smooth text on', () async {
      final settings = AppSettings(_BrokenStore());
      await settings.load();
      expect(settings.smoothText, isTrue);
    });

    test('an unreadable store gives the defaults for all of it', () async {
      final settings = AppSettings(_BrokenStore());
      await settings.load();
      expect((settings.theme, settings.darkTerminal, settings.homeTab), (ThemeChoice.light, false, 0));
    });
  });

  group('PrefsAppSettingsStore', () {
    test('round-trips through SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final store = PrefsAppSettingsStore();
      expect(await store.readTheme(), isNull);
      for (final choice in ThemeChoice.values) {
        await store.writeTheme(choice);
        expect(await store.readTheme(), choice);
      }
    });

    test('smooth text round-trips and a value of the wrong type is ignored', () async {
      SharedPreferences.setMockInitialValues({});
      final store = PrefsAppSettingsStore();
      expect(await store.readSmoothText(), isNull);
      await store.writeSmoothText(false);
      expect(await store.readSmoothText(), isFalse);
      SharedPreferences.setMockInitialValues({'app.smoothText.v1': 'yes'});
      expect(await PrefsAppSettingsStore().readSmoothText(), isNull);
    });

    test('ignores a value this version does not know, or of the wrong type', () async {
      SharedPreferences.setMockInitialValues({'app.theme.v1': 'solarized'});
      expect(await PrefsAppSettingsStore().readTheme(), isNull);
      SharedPreferences.setMockInitialValues({'app.theme.v1': 3});
      expect(await PrefsAppSettingsStore().readTheme(), isNull);
    });

    test('an existing install (other prefs, no theme) opens in light', () async {
      SharedPreferences.setMockInitialValues({'terminal.wrap.v1': true});
      final settings = AppSettings(PrefsAppSettingsStore());
      await settings.load();
      expect(settings.theme, ThemeChoice.light);
    });
  });

  test('the version shown in About is the one in pubspec.yaml', () {
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('version:'));
    final name = line.substring('version:'.length).trim().split('+').first;
    expect(appVersion, name, reason: 'bump lib/data/app_info.dart with pubspec.yaml');
  });
}
