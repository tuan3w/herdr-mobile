import '../predictor.dart';

class _Entry {
  _Entry(this.surface, this.order);
  String surface;
  int count = 0;

  /// Message number of the latest send; the tie-break between equally common ones.
  int order;
}

/// Whole-message completion from what the person has already sent: the draft
/// `ru` offers `run the tests` when most past messages starting with `ru` were
/// that. No language model, one sorted list.
///
/// Hygiene: a message becomes suggestible only after it was sent at least
/// [minCount] times (one-off messages are where secrets and paths live), and
/// only single-line ones up to [maxLength] (a chip is a row, not a paragraph).
class PhrasePredictor implements Predictor {
  PhrasePredictor({
    this.tau = 0.3,
    this.minCount = 2,
    this.maxLength = 80,
    this.minChars = 1,
    this.emptyTop = true,
  });

  /// Confidence a chip needs once something is typed.
  final double tau;
  final int minCount;
  final int maxLength;

  /// Characters typed before the first phrase chip.
  final int minChars;

  /// With an empty composer, show the most-sent messages (learned quick
  /// phrases), whatever their share.
  final bool emptyTop;

  final _entries = <String, _Entry>{};
  final _sorted = <String>[];
  int _sent = 0;

  @override
  String get name => 'phrase';

  bool _eligible(String key, _Entry e) =>
      e.count >= minCount && key.length <= maxLength && !key.contains('\n');

  int _lowerBound(String key) {
    var lo = 0, hi = _sorted.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_sorted[mid].compareTo(key) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  @override
  void learn(String message) {
    final text = message.trim();
    final key = text.toLowerCase();
    if (text.isEmpty || key.length != text.length) return;
    _sent++;
    var e = _entries[key];
    if (e == null) {
      e = _entries[key] = _Entry(text, _sent);
      _sorted.insert(_lowerBound(key), key);
    }
    e.count++;
    e.surface = text;
    e.order = _sent;
  }

  @override
  List<Chip> suggest(String draft, int slots) {
    final fd = draft.toLowerCase();
    if (fd.length != draft.length) return const [];
    if (draft.isEmpty && !emptyTop) return const [];
    if (draft.isNotEmpty && draft.length < minChars) return const [];

    final best = <MapEntry<String, _Entry>>[];
    var total = 0;
    void consider(String key, _Entry e) {
      total += e.count;
      if (key.length <= fd.length || !_eligible(key, e)) return;
      var at = best.length;
      while (at > 0 && _beats(e, best[at - 1].value)) {
        at--;
      }
      if (at >= slots) return;
      best.insert(at, MapEntry(key, e));
      if (best.length > slots) best.removeLast();
    }

    if (fd.isEmpty) {
      _entries.forEach(consider);
    } else {
      for (var i = _lowerBound(fd); i < _sorted.length && _sorted[i].startsWith(fd); i++) {
        consider(_sorted[i], _entries[_sorted[i]]!);
      }
    }
    return [
      for (final b in best)
        if (fd.isEmpty || b.value.count / total >= tau)
          Chip(
            label: b.value.surface,
            insert: b.value.surface.substring(fd.length),
            confidence: b.value.count / total,
          ),
    ];
  }

  static bool _beats(_Entry a, _Entry b) =>
      a.count != b.count ? a.count > b.count : a.order > b.order;
}
