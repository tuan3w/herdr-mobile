import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which look the app wears. [system] follows the phone's dark mode.
enum ThemeChoice { light, dark, system }

/// How the Agents board draws its rows. [auto] is cards up to
/// [AppSettings.autoCompactFrom] - 1 agents and compact rows from there;
/// [cards] and [compact] are the person's own choice and always win.
enum BoardDensity { auto, cards, compact }

/// What opening an agent that runs in a herdr pane (and can be followed
/// through its own log, see `ObservedSessions`) shows: the [chat] the app has
/// for agent sessions, or the pane's [terminal]. Agents without a readable
/// log always open as a terminal.
enum OpenAgentsAs { chat, terminal }

/// Where [AppSettings] are kept between launches. Null is "never saved" (or
/// saved as something this version does not know).
abstract interface class AppSettingsStore {
  Future<ThemeChoice?> readTheme();

  Future<void> writeTheme(ThemeChoice theme);

  Future<bool?> readDarkTerminal();

  Future<void> writeDarkTerminal(bool dark);

  Future<int?> readHomeTab();

  Future<void> writeHomeTab(int tab);

  Future<BoardDensity?> readDensity();

  Future<void> writeDensity(BoardDensity density);

  Future<OpenAgentsAs?> readOpenAgentsAs();

  Future<void> writeOpenAgentsAs(OpenAgentsAs value);

  Future<bool?> readSmoothText();

  Future<void> writeSmoothText(bool value);
}

class PrefsAppSettingsStore implements AppSettingsStore {
  static const _themeKey = 'app.theme.v1';
  static const _darkTerminalKey = 'app.darkTerminal.v1';
  static const _homeTabKey = 'app.homeTab.v1';
  static const _densityKey = 'app.density.v1';
  static const _openAsKey = 'app.openAgentsAs.v1';
  static const _smoothTextKey = 'app.smoothText.v1';

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

  @override
  Future<BoardDensity?> readDensity() async {
    final saved = (await SharedPreferences.getInstance()).get(_densityKey);
    for (final choice in BoardDensity.values) {
      if (choice.name == saved) return choice;
    }
    return null;
  }

  @override
  Future<void> writeDensity(BoardDensity density) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_densityKey, density.name);
  }

  @override
  Future<OpenAgentsAs?> readOpenAgentsAs() async {
    final saved = (await SharedPreferences.getInstance()).get(_openAsKey);
    for (final choice in OpenAgentsAs.values) {
      if (choice.name == saved) return choice;
    }
    return null;
  }

  @override
  Future<void> writeOpenAgentsAs(OpenAgentsAs value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_openAsKey, value.name);
  }

  @override
  Future<bool?> readSmoothText() async {
    final saved = (await SharedPreferences.getInstance()).get(_smoothTextKey);
    return saved is bool ? saved : null;
  }

  @override
  Future<void> writeSmoothText(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_smoothTextKey, value);
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

  /// With [BoardDensity.auto], the board turns compact from this many agents.
  static const autoCompactFrom = 5;

  ThemeChoice _theme = defaultTheme;
  bool _darkTerminal = false;
  int _homeTab = 0;
  BoardDensity _density = BoardDensity.auto;
  OpenAgentsAs _openAs = OpenAgentsAs.chat;
  bool _smoothText = true;

  ThemeChoice get theme => _theme;

  /// Panes stay dark on the light theme. Off by default: a pane is drawn in
  /// the colours of the theme.
  bool get darkTerminal => _darkTerminal;

  /// The root tab the app opens on: the one it was left on.
  int get homeTab => _homeTab;

  /// What the person chose for the board's rows; [BoardDensity.auto] until
  /// they choose.
  BoardDensity get density => _density;

  /// How agents that can be followed through their log open; [OpenAgentsAs.chat]
  /// until the person chooses.
  OpenAgentsAs get openAgentsAs => _openAs;

  /// Streaming answers appear at an even pace (`RevealPacer`) instead of in
  /// the lumps they arrive in. On until the person turns it off; what is
  /// shown and when it ends do not change, only the pace.
  bool get smoothText => _smoothText;

  /// Whether a board of [agentCount] agents draws cards (a live preview each)
  /// rather than compact rows.
  bool cardsFor(int agentCount) => switch (_density) {
        BoardDensity.cards => true,
        BoardDensity.compact => false,
        BoardDensity.auto => agentCount < autoCompactFrom,
      };

  /// Reads the saved settings. Anything missing or unreadable is the default.
  Future<void> load() async {
    try {
      _theme = await _store.readTheme() ?? defaultTheme;
      _darkTerminal = await _store.readDarkTerminal() ?? false;
      final tab = await _store.readHomeTab() ?? 0;
      _homeTab = tab >= 0 && tab < homeTabCount ? tab : 0;
      _density = await _store.readDensity() ?? BoardDensity.auto;
      _openAs = await _store.readOpenAgentsAs() ?? OpenAgentsAs.chat;
      _smoothText = await _store.readSmoothText() ?? true;
    } on Object {
      _theme = defaultTheme;
      _darkTerminal = false;
      _homeTab = 0;
      _density = BoardDensity.auto;
      _openAs = OpenAgentsAs.chat;
      _smoothText = true;
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

  /// Applies [density] right away and saves it.
  Future<void> setDensity(BoardDensity density) {
    if (density != _density) {
      _density = density;
      notifyListeners();
    }
    return _store.writeDensity(_density);
  }

  /// Applies [value] right away and saves it.
  Future<void> setOpenAgentsAs(OpenAgentsAs value) {
    if (value != _openAs) {
      _openAs = value;
      notifyListeners();
    }
    return _store.writeOpenAgentsAs(_openAs);
  }

  /// Applies [value] right away and saves it.
  Future<void> setSmoothText(bool value) {
    if (value != _smoothText) {
      _smoothText = value;
      notifyListeners();
    }
    return _store.writeSmoothText(_smoothText);
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
