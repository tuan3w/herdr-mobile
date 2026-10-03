import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which look the app wears. [system] follows the phone's dark mode.
enum ThemeChoice { light, dark, system }

/// Where [AppSettings] are kept between launches.
abstract interface class AppSettingsStore {
  /// The saved theme; null when none was ever saved, or the saved value is not
  /// one this version knows.
  Future<ThemeChoice?> readTheme();

  Future<void> writeTheme(ThemeChoice theme);
}

class PrefsAppSettingsStore implements AppSettingsStore {
  static const _themeKey = 'app.theme.v1';

  @override
  Future<ThemeChoice?> readTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.get(_themeKey);
    for (final choice in ThemeChoice.values) {
      if (choice.name == saved) return choice;
    }
    return null;
  }

  @override
  Future<void> writeTheme(ThemeChoice theme) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, theme.name);
  }
}

/// App-wide preferences that are not about one screen. Load it before
/// `runApp`, so the very first frame is already in the chosen theme.
class AppSettings extends ChangeNotifier {
  AppSettings(this._store);

  final AppSettingsStore _store;

  /// Light until the person chooses otherwise, which includes every install
  /// that predates this setting.
  static const defaultTheme = ThemeChoice.light;

  ThemeChoice _theme = defaultTheme;

  ThemeChoice get theme => _theme;

  /// Reads the saved settings. Anything missing or unreadable is the default.
  Future<void> load() async {
    try {
      _theme = await _store.readTheme() ?? defaultTheme;
    } on Object {
      _theme = defaultTheme;
    }
    notifyListeners();
  }

  /// Applies [theme] right away and saves it.
  Future<void> setTheme(ThemeChoice theme) {
    if (theme != _theme) {
      _theme = theme;
      notifyListeners();
    }
    return _store.writeTheme(_theme);
  }
}
