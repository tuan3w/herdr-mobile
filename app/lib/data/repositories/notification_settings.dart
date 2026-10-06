import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether the person wants notifications at all, and which. Off by default:
/// a notification is an interruption, so it is opt-in.
@immutable
class NotificationChoice {
  const NotificationChoice({this.enabled = false, this.alsoDone = false});

  /// Tell me when an agent needs me (is blocked on a question).
  final bool enabled;

  /// Also tell me when an agent finishes. Only meaningful when [enabled].
  final bool alsoDone;

  NotificationChoice copyWith({bool? enabled, bool? alsoDone}) =>
      NotificationChoice(enabled: enabled ?? this.enabled, alsoDone: alsoDone ?? this.alsoDone);

  @override
  bool operator ==(Object other) =>
      other is NotificationChoice && other.enabled == enabled && other.alsoDone == alsoDone;

  @override
  int get hashCode => Object.hash(enabled, alsoDone);
}

/// Where [NotificationSettings] are kept between launches.
abstract interface class NotificationStore {
  Future<NotificationChoice> read();

  Future<void> write(NotificationChoice choice);
}

class PrefsNotificationStore implements NotificationStore {
  static const _enabled = 'notify.enabled.v1';
  static const _alsoDone = 'notify.alsoDone.v1';

  @override
  Future<NotificationChoice> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return NotificationChoice(
        enabled: prefs.getBool(_enabled) ?? false,
        alsoDone: prefs.getBool(_alsoDone) ?? false,
      );
    } on Object {
      return const NotificationChoice();
    }
  }

  @override
  Future<void> write(NotificationChoice choice) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabled, choice.enabled);
    await prefs.setBool(_alsoDone, choice.alsoDone);
  }
}

/// For tests.
class MemoryNotificationStore implements NotificationStore {
  MemoryNotificationStore([this.choice = const NotificationChoice()]);

  NotificationChoice choice;

  @override
  Future<NotificationChoice> read() async => choice;

  @override
  Future<void> write(NotificationChoice choice) async => this.choice = choice;
}

/// The person's notification choice, loaded before the first frame.
class NotificationSettings extends ChangeNotifier {
  NotificationSettings(this._store);

  final NotificationStore _store;
  NotificationChoice _choice = const NotificationChoice();

  bool get enabled => _choice.enabled;

  /// True only when notifications are on: "also when finished" does nothing
  /// by itself.
  bool get alsoDone => _choice.enabled && _choice.alsoDone;

  Future<void> load() async {
    _choice = await _store.read();
    notifyListeners();
  }

  Future<void> setEnabled(bool value) => _set(_choice.copyWith(enabled: value));

  Future<void> setAlsoDone(bool value) => _set(_choice.copyWith(alsoDone: value));

  Future<void> _set(NotificationChoice next) async {
    if (next == _choice) return;
    _choice = next;
    notifyListeners();
    await _store.write(next);
  }
}
