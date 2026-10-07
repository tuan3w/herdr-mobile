import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'quick_phrases.dart';

/// What [SentPhrases] keeps between launches: the learned messages, and
/// whether learning is on.
abstract interface class SentPhrasesStore {
  Future<SentPhrasesSnapshot> read();

  Future<void> write(SentPhrasesSnapshot snapshot);
}

class SentPhrasesSnapshot {
  const SentPhrasesSnapshot({this.enabled = true, this.entries = const []});

  final bool enabled;
  final List<SentPhrase> entries;
}

/// One message the person sent, how often, and when last (a sequence number:
/// larger is later).
class SentPhrase {
  const SentPhrase(this.text, this.count, this.last);

  final String text;
  final int count;
  final int last;

  SentPhrase sentAgain(String text, int at) => SentPhrase(text, count + 1, at);

  Map<String, Object> toJson() => {'t': text, 'n': count, 'l': last};
}

class PrefsSentPhrasesStore implements SentPhrasesStore {
  static const _key = 'sentPhrases.v1';
  static const _enabledKey = 'sentPhrases.enabled.v1';

  @override
  Future<SentPhrasesSnapshot> read() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_enabledKey) ?? true;
    final raw = prefs.getString(_key);
    if (raw == null) return SentPhrasesSnapshot(enabled: enabled);
    try {
      final json = jsonDecode(raw);
      if (json is! List) return SentPhrasesSnapshot(enabled: enabled);
      return SentPhrasesSnapshot(
        enabled: enabled,
        entries: [
          for (final item in json)
            if (item case {'t': final String t, 'n': final int n, 'l': final int l}) SentPhrase(t, n, l),
        ],
      );
    } on FormatException {
      return SentPhrasesSnapshot(enabled: enabled);
    }
  }

  @override
  Future<void> write(SentPhrasesSnapshot snapshot) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, snapshot.enabled);
    if (snapshot.entries.isEmpty) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, jsonEncode([for (final e in snapshot.entries) e.toJson()]));
    }
  }
}

/// The short messages this person sends over and over, learned on the phone
/// from what they send to an agent, and offered as chips next to the
/// [QuickPhrases] (`quickChips`).
///
/// Replayed on a year of one person's real messages, 14% were an exact repeat
/// of an earlier one and the top chips would have finished 5% of messages in
/// one tap: twice what the four default phrases do (`tool/predict-eval`).
///
/// A learned message is text typed by the person, so what may become a chip is
/// narrow, and the reason is next to each rule:
/// - sent at least [minSends] times: a message sent once is where a secret or
///   a one-off path lives, and is not "popular" anyway;
/// - one line of at most [QuickPhrases.maxLength] characters: a chip is a row;
/// - no address and no unbroken token of [longestToken] characters or more: those are
///   keys, tokens and hashes;
/// - only [maxTracked] messages are remembered, the rarest and oldest dropped
///   first, so what is kept stays small and recent;
/// - learning can be turned off, and what was learned forgotten, in Settings.
///
/// Callers learn only from text sent to an agent, never from a line typed into
/// a shell (a pane without an agent): a command is not a phrase.
class SentPhrases extends ChangeNotifier {
  SentPhrases(this._store);

  static const minSends = 2;
  static const maxTracked = 300;
  static const longestToken = 24;

  /// Learned chips shown beside the person's own: the row is a row.
  static const maxChips = 3;

  final SentPhrasesStore _store;
  bool _enabled = true;
  final _entries = <String, SentPhrase>{};
  var _seq = 0;

  bool get enabled => _enabled;

  /// How many messages are remembered, those still below [minSends] too.
  int get tracked => _entries.length;

  Future<void> load() async {
    try {
      final snapshot = await _store.read();
      _enabled = snapshot.enabled;
      _entries.clear();
      for (final e in snapshot.entries) {
        final key = _key(e.text);
        if (key != null) _entries[key] = e;
        if (e.last > _seq) _seq = e.last;
      }
    } on Object {
      _entries.clear();
    }
    notifyListeners();
  }

  /// The lookup key of [text], or null when [text] may never be learned.
  static String? _key(String text) {
    final line = text.trim();
    if (line.length < 2 || line.length > QuickPhrases.maxLength) return null;
    if (line.contains('\n') || line.startsWith('/')) return null;
    if (line.contains('://')) return null;
    for (final token in line.split(RegExp(r'\s+'))) {
      if (token.length >= longestToken) return null;
    }
    return line.toLowerCase();
  }

  /// Counts [text] as sent. Not learned while off, or when [_key] refuses it.
  Future<void> learn(String text) {
    if (!_enabled) return Future.value();
    final key = _key(text);
    if (key == null) return Future.value();
    final line = text.trim();
    final seen = _entries[key];
    _entries[key] = seen == null ? SentPhrase(line, 1, ++_seq) : seen.sentAgain(line, ++_seq);
    _trim();
    notifyListeners();
    return _save();
  }

  void _trim() {
    if (_entries.length <= maxTracked) return;
    final worst = _entries.entries.toList()..sort((a, b) => _rank(b.value, a.value));
    for (final e in worst.take(_entries.length - maxTracked)) {
      _entries.remove(e.key);
    }
  }

  /// Orders the likeliest chip first: most sends, then latest.
  static int _rank(SentPhrase a, SentPhrase b) {
    if (a.count != b.count) return b.count.compareTo(a.count);
    return b.last.compareTo(a.last);
  }

  /// The chips to show, most sent first, leaving out [except] (the person's
  /// own phrases, compared without regard to case).
  List<String> chips({Iterable<String> except = const []}) {
    final skip = {for (final p in except) p.toLowerCase()};
    final ranked = [
      for (final e in _entries.entries)
        if (_enabled && e.value.count >= minSends && !skip.contains(e.key)) e.value,
    ]..sort(_rank);
    return [for (final e in ranked.take(maxChips)) e.text];
  }

  Future<void> setEnabled(bool value) {
    if (value == _enabled) return Future.value();
    _enabled = value;
    notifyListeners();
    return _save();
  }

  /// Forgets everything learned. Learning stays as it was.
  Future<void> forget() {
    if (_entries.isEmpty) return Future.value();
    _entries.clear();
    notifyListeners();
    return _save();
  }

  Future<void> _save() => _store
      .write(SentPhrasesSnapshot(enabled: _enabled, entries: _entries.values.toList()))
      .catchError((Object _) {});
}

/// The chips above the composer: the person's own phrases, then what they send
/// most. While the phrases are still the shipped [QuickPhrases.defaults] the
/// learned ones go first: the person has not chosen the defaults, and a message
/// they really send beats a guess. A list they edited stays where it is. A
/// phrase that is also learned shows once, where the order puts it first.
List<String> quickChips({
  required List<String> phrases,
  required bool untouched,
  required List<String> learned,
}) {
  final seen = <String>{};
  return [
    for (final p in untouched ? [...learned, ...phrases] : [...phrases, ...learned])
      if (seen.add(p.toLowerCase())) p,
  ];
}
