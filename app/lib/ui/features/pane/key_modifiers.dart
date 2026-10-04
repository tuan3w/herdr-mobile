import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Ctrl and Alt armed from the key row. Each applies to exactly one following
/// key (a latch, not a lock): arm Ctrl, type `r`, and the pane gets `ctrl+r`.
/// That reaches every hotkey the system keyboard can type without a button
/// per hotkey.
class StickyModifiers extends ChangeNotifier {
  bool _ctrl = false;
  bool _alt = false;

  bool get ctrl => _ctrl;
  bool get alt => _alt;
  bool get armed => _ctrl || _alt;

  void toggleCtrl() {
    _ctrl = !_ctrl;
    notifyListeners();
  }

  void toggleAlt() {
    _alt = !_alt;
    notifyListeners();
  }

  void clear() {
    if (!armed) return;
    _ctrl = false;
    _alt = false;
    notifyListeners();
  }

  /// The herdr key combo for [key] with the armed modifiers in front, and
  /// disarms. `null` when nothing is armed, or when [key] already names a
  /// combo (`ctrl+c`, `shift+tab`): those are sent as they are.
  String? chord(String key) {
    if (!armed) return null;
    if (key.length > 1 && key.contains('+')) return null;
    final combo = '${_ctrl ? 'ctrl+' : ''}${_alt ? 'alt+' : ''}$key';
    clear();
    return combo;
  }

  /// [keys] with [chord] applied to a lone key; the same list when nothing
  /// is armed.
  List<String> apply(List<String> keys) {
    if (keys.length != 1) return keys;
    final combo = chord(keys.single);
    return combo == null ? keys : [combo];
  }

  /// The herdr name of a typed character, e.g. `r`, `space`, `plus`.
  static String keyName(String char) => switch (char) {
        ' ' => 'space',
        '+' => 'plus',
        _ => char.toLowerCase(),
      };
}

/// Turns the next typed character into a chord while a modifier is armed: the
/// character never reaches the field, [onChord] gets the combo instead.
///
/// Only a plain one-character insertion counts. Deleting, pasting and
/// replacing a selection pass through, so a modifier armed by mistake does not
/// eat an edit.
class ModifierTypingFormatter extends TextInputFormatter {
  ModifierTypingFormatter(this.modifiers, this.onChord);

  final StickyModifiers modifiers;
  final ValueChanged<String> onChord;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (!modifiers.armed) return newValue;
    final char = insertedChar(oldValue.text, newValue.text);
    if (char == null) return newValue;
    final combo = modifiers.chord(StickyModifiers.keyName(char));
    if (combo == null) return newValue;
    onChord(combo);
    return oldValue.copyWith(composing: TextRange.empty);
  }

  /// The one character [next] has more than [previous], if that is all that
  /// changed.
  @visibleForTesting
  static String? insertedChar(String previous, String next) {
    if (next.length != previous.length + 1) return null;
    var i = 0;
    while (i < previous.length && previous.codeUnitAt(i) == next.codeUnitAt(i)) {
      i++;
    }
    if (next.substring(i + 1) != previous.substring(i)) return null;
    final unit = next.codeUnitAt(i);
    // Half of a surrogate pair is not a key.
    if (unit >= 0xD800 && unit <= 0xDFFF) return null;
    return next[i];
  }
}
