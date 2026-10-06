import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_terminal_settings_store.dart';

void main() {
  group('TerminalSettings', () {
    test('start at 11.5 px with the exact layout', () async {
      final settings = TerminalSettings(MemoryTerminalSettingsStore());
      await settings.load();

      expect(settings.fontSize, 11.5);
      expect(settings.wrap, isFalse);
    });

    test('are restored from the store', () async {
      final store = MemoryTerminalSettingsStore()
        ..fontSize = 15
        ..wrap = true;
      final settings = TerminalSettings(store);
      await settings.load();

      expect(settings.fontSize, 15);
      expect(settings.wrap, isTrue);
    });

    test('a saved size out of range is clamped, a broken one ignored', () async {
      final store = MemoryTerminalSettingsStore()..fontSize = 400;
      final settings = TerminalSettings(store);
      await settings.load();
      expect(settings.fontSize, 22);

      store.fontSize = 1;
      await settings.load();
      expect(settings.fontSize, 8);

      store.fontSize = double.nan;
      await settings.load();
      expect(settings.fontSize, 11.5);
    });

    test('setFontSize clamps, notifies and saves', () async {
      final store = MemoryTerminalSettingsStore();
      final settings = TerminalSettings(store);
      var notified = 0;
      settings.addListener(() => notified++);

      await settings.setFontSize(30);
      expect(settings.fontSize, 22);
      expect(store.fontSize, 22);
      expect(notified, 1);

      await settings.setFontSize(2);
      expect(settings.fontSize, 8);
      expect(store.fontSize, 8);
    });

    test('previewing shows a size without saving it', () async {
      final store = MemoryTerminalSettingsStore();
      final settings = TerminalSettings(store);
      var notified = 0;
      settings.addListener(() => notified++);

      settings
        ..previewFontSize(13)
        ..previewFontSize(14)
        ..previewFontSize(14);

      expect(settings.fontSize, 14);
      expect(notified, 2, reason: 'no notification for an unchanged size');
      expect(store.writes, isEmpty);

      await settings.setFontSize(14);
      expect(store.writes, ['font 14.0']);
    });

    test('wrap mode is saved and notifies once per change', () async {
      final store = MemoryTerminalSettingsStore();
      final settings = TerminalSettings(store);
      var notified = 0;
      settings.addListener(() => notified++);

      await settings.setWrap(true);
      await settings.setWrap(true);

      expect(settings.wrap, isTrue);
      expect(store.wrap, isTrue);
      expect(notified, 1);
    });

    test('survive a restart', () async {
      final store = MemoryTerminalSettingsStore();
      final first = TerminalSettings(store);
      await first.setFontSize(17.25);
      await first.setWrap(true);

      final second = TerminalSettings(store);
      await second.load();

      expect(second.fontSize, 17.25);
      expect(second.wrap, isTrue);
    });
  });

  group('PrefsTerminalSettingsStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('reads nothing when nothing was saved', () async {
      final saved = await PrefsTerminalSettingsStore().read();
      expect(saved.fontSize, isNull);
      expect(saved.wrap, isNull);
    });

    test('round-trips through shared preferences', () async {
      final store = PrefsTerminalSettingsStore();
      await store.writeFontSize(9.75);
      await store.writeWrap(true);

      final saved = await PrefsTerminalSettingsStore().read();
      expect(saved.fontSize, 9.75);
      expect(saved.wrap, isTrue);
    });
  });
}
