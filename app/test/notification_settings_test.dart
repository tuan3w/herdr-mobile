import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/notification_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CountingStore extends MemoryNotificationStore {
  int writes = 0;

  @override
  Future<void> write(NotificationChoice choice) {
    writes++;
    return super.write(choice);
  }
}

void main() {
  group('NotificationSettings', () {
    test('everything is off until the person turns it on', () async {
      final settings = NotificationSettings(MemoryNotificationStore());
      expect(settings.enabled, isFalse, reason: 'before load');
      await settings.load();
      expect(settings.enabled, isFalse);
      expect(settings.alsoDone, isFalse);
    });

    test('"also when finished" does nothing while notifications are off', () async {
      final store = MemoryNotificationStore(const NotificationChoice(alsoDone: true));
      final settings = NotificationSettings(store);
      await settings.load();
      expect(settings.enabled, isFalse);
      expect(settings.alsoDone, isFalse);

      await settings.setEnabled(true);
      expect(settings.alsoDone, isTrue, reason: 'the earlier choice comes back with the switch');
      await settings.setEnabled(false);
      expect(settings.alsoDone, isFalse);
    });

    test('a change notifies once and is written; repeating it does neither', () async {
      final store = _CountingStore();
      final settings = NotificationSettings(store);
      var notified = 0;
      settings.addListener(() => notified++);

      await settings.setEnabled(true);
      expect((notified, store.writes), (1, 1));
      expect(store.choice, const NotificationChoice(enabled: true));

      await settings.setEnabled(true);
      expect((notified, store.writes), (1, 1));

      await settings.setAlsoDone(true);
      expect((notified, store.writes), (2, 2));
      expect(store.choice, const NotificationChoice(enabled: true, alsoDone: true));
    });

    test('survives a restart through shared preferences', () async {
      SharedPreferences.setMockInitialValues({});
      final first = NotificationSettings(PrefsNotificationStore());
      await first.load();
      expect(first.enabled, isFalse);
      await first.setEnabled(true);
      await first.setAlsoDone(true);

      final second = NotificationSettings(PrefsNotificationStore());
      await second.load();
      expect(second.enabled, isTrue);
      expect(second.alsoDone, isTrue);

      await second.setEnabled(false);
      final third = NotificationSettings(PrefsNotificationStore());
      await third.load();
      expect(third.enabled, isFalse);
      expect(third.alsoDone, isFalse);
    });
  });
}
