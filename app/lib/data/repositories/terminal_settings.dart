import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Smallest, largest and default terminal font size, in logical pixels.
const minTerminalFontSize = 8.0;
const maxTerminalFontSize = 22.0;
const defaultTerminalFontSize = 11.5;

/// Where [TerminalSettings] are kept between launches.
abstract interface class TerminalSettingsStore {
  /// The saved font size and wrap mode; null for whatever was never saved.
  Future<({double? fontSize, bool? wrap})> read();

  Future<void> writeFontSize(double fontSize);

  Future<void> writeWrap(bool wrap);
}

class PrefsTerminalSettingsStore implements TerminalSettingsStore {
  static const _fontKey = 'terminal.fontSize.v1';
  static const _wrapKey = 'terminal.wrap.v1';

  @override
  Future<({double? fontSize, bool? wrap})> read() async {
    final prefs = await SharedPreferences.getInstance();
    return (fontSize: prefs.getDouble(_fontKey), wrap: prefs.getBool(_wrapKey));
  }

  @override
  Future<void> writeFontSize(double fontSize) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_fontKey, fontSize);
  }

  @override
  Future<void> writeWrap(bool wrap) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_wrapKey, wrap);
  }
}

/// How the pane terminal is shown, remembered across launches: font size
/// (changed by pinching) and whether lines are wrapped to the screen.
class TerminalSettings extends ChangeNotifier {
  TerminalSettings(this._store);

  final TerminalSettingsStore _store;

  double _fontSize = defaultTerminalFontSize;
  bool _wrap = false;

  /// Font size in logical pixels, within [minTerminalFontSize]..[maxTerminalFontSize].
  double get fontSize => _fontSize;

  /// Re-flow lines to the screen width, instead of the terminal's own layout
  /// with sideways scrolling.
  bool get wrap => _wrap;

  /// Reads the saved settings. Anything unreadable or out of range falls back
  /// to the default.
  Future<void> load() async {
    ({double? fontSize, bool? wrap}) saved;
    try {
      saved = await _store.read();
    } on Object {
      // A stored value of another type (the platform throws on it) is a
      // setting lost, not an app that cannot start.
      saved = (fontSize: null, wrap: null);
    }
    final fontSize = saved.fontSize;
    _fontSize = fontSize == null || !fontSize.isFinite
        ? defaultTerminalFontSize
        : _clamp(fontSize);
    _wrap = saved.wrap ?? false;
    notifyListeners();
  }

  /// Shows [fontSize] without saving it, for the middle of a pinch.
  void previewFontSize(double fontSize) {
    final clamped = _clamp(fontSize);
    if (clamped == _fontSize) return;
    _fontSize = clamped;
    notifyListeners();
  }

  /// Sets and saves the font size.
  Future<void> setFontSize(double fontSize) {
    previewFontSize(fontSize);
    return _store.writeFontSize(_fontSize);
  }

  /// Sets and saves wrap mode.
  Future<void> setWrap(bool wrap) {
    if (wrap != _wrap) {
      _wrap = wrap;
      notifyListeners();
    }
    return _store.writeWrap(_wrap);
  }

  static double _clamp(double v) =>
      v.clamp(minTerminalFontSize, maxTerminalFontSize).toDouble();
}
