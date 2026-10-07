import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where [QuickPhrases] are kept between launches.
abstract interface class QuickPhrasesStore {
  /// The saved list; null when none was ever saved (the person has not touched
  /// the phrases, so the defaults apply, and may change in a later release).
  Future<List<String>?> read();

  Future<void> write(List<String> phrases);
}

class PrefsQuickPhrasesStore implements QuickPhrasesStore {
  static const _key = 'quickPhrases.v1';

  @override
  Future<List<String>?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! List) return null;
      return [
        for (final item in json)
          if (item is String) item,
      ];
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(List<String> phrases) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(phrases));
  }
}

/// Why a phrase cannot join the list; shown under the editor's field.
enum PhraseProblem {
  empty,
  duplicate,
  full;

  String get message => switch (this) {
        PhraseProblem.empty => 'Write something to say',
        PhraseProblem.duplicate => 'Already in the list',
        PhraseProblem.full => 'The list is full (${QuickPhrases.maxCount} phrases)',
      };
}

/// Short lines the person types to an agent over and over, offered as one-tap
/// chips above the composer. A chip only fills the composer: the person still
/// presses send.
///
/// The list is kept clean by construction (see [clean]): trimmed, single-line,
/// at most [maxLength] characters, no empties, no duplicates, at most
/// [maxCount] entries. The order is the order of the chips.
class QuickPhrases extends ChangeNotifier {
  QuickPhrases(this._store);

  /// Most phrases kept: the chip row is a row, not a library.
  static const maxCount = 12;

  /// Longest phrase, in characters.
  static const maxLength = 80;

  static const defaults = [
    'continue',
    'yes, go ahead',
    'run the tests',
    'explain what you changed',
  ];

  final QuickPhrasesStore _store;
  List<String> _phrases = defaults;

  /// [text] as it is stored: whitespace (newlines included) folded to single
  /// spaces, trimmed, cut to [maxLength] characters. Empty stays empty.
  static String clean(String text) {
    final folded = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final runes = folded.runes;
    if (runes.length <= maxLength) return folded;
    return String.fromCharCodes(runes.take(maxLength)).trim();
  }

  /// [raw] as a list: each entry cleaned, empties and repeats dropped, cut to
  /// [maxCount].
  static List<String> normalize(Iterable<String> raw) {
    final seen = <String>{};
    final out = <String>[];
    for (final item in raw) {
      final phrase = clean(item);
      if (phrase.isEmpty || !seen.add(phrase)) continue;
      out.add(phrase);
      if (out.length == maxCount) break;
    }
    return out;
  }

  /// Reads what was saved. Anything unreadable gives the defaults.
  Future<void> load() async {
    try {
      final saved = await _store.read();
      _phrases = saved == null ? defaults : normalize(saved);
    } on Object {
      _phrases = defaults;
    }
    notifyListeners();
  }

  /// The chips, in order.
  List<String> get phrases => _phrases;

  /// Whether the person never changed the list: it is still the shipped
  /// [defaults], which a message they really send may come before.
  bool get untouched => identical(_phrases, defaults);

  /// Whether [text] could be added, or could replace [replacing]; null when it
  /// can. An edit that changes nothing is fine.
  PhraseProblem? problem(String text, {String? replacing}) {
    final phrase = clean(text);
    if (phrase.isEmpty) return PhraseProblem.empty;
    if (phrase == replacing) return null;
    if (_phrases.contains(phrase)) return PhraseProblem.duplicate;
    if (replacing == null && _phrases.length >= maxCount) return PhraseProblem.full;
    return null;
  }

  /// Appends [text]. Returns false (and changes nothing) when [problem] says no.
  Future<bool> add(String text) async {
    if (problem(text) != null) return false;
    await _set([..._phrases, clean(text)]);
    return true;
  }

  /// Puts [text] where [old] was. Returns false when [problem] says no.
  Future<bool> replace(String old, String text) async {
    final at = _phrases.indexOf(old);
    if (at < 0 || problem(text, replacing: old) != null) return false;
    await _set([..._phrases]..[at] = clean(text));
    return true;
  }

  Future<void> remove(String phrase) async {
    if (!_phrases.contains(phrase)) return;
    await _set([..._phrases]..remove(phrase));
  }

  Future<void> _set(List<String> next) {
    _phrases = List.unmodifiable(next);
    notifyListeners();
    return _store.write(_phrases).catchError((Object _) {});
  }
}
