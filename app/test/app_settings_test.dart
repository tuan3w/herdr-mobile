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
