import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which look the app wears. [system] follows the phone's dark mode.
enum ThemeChoice { light, dark, system }

/// Where [AppSettings] are kept between launches. Null is "never saved" (or
/// saved as something this version does not know).
abstract interface class AppSettingsStore {
  Future<ThemeChoice?> readTheme();

  Future<void> writeTheme(ThemeChoice theme);

  Future<bool?> readDarkTerminal();

  Future<void> writeDarkTerminal(bool dark);

  Future<int?> readHomeTab();

  Future<void> writeHomeTab(int tab);
}

class PrefsAppSettingsStore implements AppSettingsStore {
  static const _themeKey = 'app.theme.v1';
  static const _darkTerminalKey = 'app.darkTerminal.v1';
  static const _homeTabKey = 'app.homeTab.v1';

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

  @override
  Future<bool?> readDarkTerminal() async {
    final saved = (await SharedPreferences.getInstance()).get(_darkTerminalKey);
    return saved is bool ? saved : null;
  }

  @override
  Future<void> writeDarkTerminal(bool dark) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_darkTerminalKey, dark);
  }

  @override
  Future<int?> readHomeTab() async {
    final saved = (await SharedPreferences.getInstance()).get(_homeTabKey);
    return saved is int ? saved : null;
  }

  @override
  Future<void> writeHomeTab(int tab) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_homeTabKey, tab);
  }
}

/// App-wide preferences that are not about one screen. Load it before
/// `runApp`, so the very first frame is already in the chosen theme and on the
/// tab the person left.
class AppSettings extends ChangeNotifier {
  AppSettings(this._store);

  final AppSettingsStore _store;

  /// Light until the person chooses otherwise, which includes every install
  /// that predates this setting.
  static const defaultTheme = ThemeChoice.light;

  /// The root tabs: Agents, Machines, Settings.
  static const homeTabCount = 3;

  ThemeChoice _theme = defaultTheme;
  bool _darkTerminal = false;
  int _homeTab = 0;

  ThemeChoice get theme => _theme;

  /// Panes stay dark on the light theme. Off by default: a pane is drawn in
  /// the colours of the theme.
  bool get darkTerminal => _darkTerminal;

  /// The root tab the app opens on: the one it was left on.
  int get homeTab => _homeTab;

  /// Reads the saved settings. Anything missing or unreadable is the default.
  Future<void> load() async {
    try {
      _theme = await _store.readTheme() ?? defaultTheme;
      _darkTerminal = await _store.readDarkTerminal() ?? false;
      final tab = await _store.readHomeTab() ?? 0;
      _homeTab = tab >= 0 && tab < homeTabCount ? tab : 0;
    } on Object {
      _theme = defaultTheme;
      _darkTerminal = false;
      _homeTab = 0;
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

  Future<void> setDarkTerminal(bool dark) {
    if (dark != _darkTerminal) {
      _darkTerminal = dark;
      notifyListeners();
    }
    return _store.writeDarkTerminal(_darkTerminal);
  }

  /// Remembers the root tab being shown. Nothing listens: the shell already
  /// shows it, so this does not rebuild anything.
  Future<void> setHomeTab(int tab) {
    if (tab < 0 || tab >= homeTabCount) return Future.value();
    if (tab == _homeTab) return Future.value();
    _homeTab = tab;
    return _store.writeHomeTab(tab);
  }
}
