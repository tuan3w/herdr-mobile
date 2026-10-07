import 'dart:math' as math;

import '../predictor.dart';
import '../vietnamese.dart';
import '../words.dart';

/// Knobs of [NgramPredictor]. The smoothing constants are omp's
/// (`pi-predict/src/ngram/model.rs`), which tuned them on its own typist replay.
class NgramParams {
  const NgramParams({
    this.tau = 0.15,
    this.minPrefix = 2,
    this.nextWord = false,
    this.personal = true,
    this.fold = false,
    this.minCount = 2,
    this.topK = 8,
    this.mu1 = 10000,
    this.d2 = 0.9,
    this.mu2 = 2,
    this.d3 = 0.9,
    this.mu3 = 2,
  });

  /// Confidence a chip needs.
  final double tau;

  /// Letters typed before a word chip may show. 0 with [nextWord] also predicts
  /// the word after a space.
  final int minPrefix;

  /// Predict the next word right after a space (nothing typed of it).
  final bool nextWord;

  /// Learn from what the person sends. Off = "a keyboard that knows nothing about you".
  final bool personal;

  /// Match and learn words without Vietnamese marks (`khong` finds `không`),
  /// and answer with the marked spelling. For people who skip the marks.
  final bool fold;

  /// A word outside the prior must be typed this many times before it is
  /// suggested: a typo or a pasted token does not become a chip.
  final int minCount;
  final int topK;
  final double mu1, d2, mu2, d3, mu3;
}

/// The static word prior: frequencies of a language corpus, ranked by prefix.
class WordPrior {
  WordPrior._(this.keys, this.cum, this.p, this.surface);

  /// English and Vietnamese frequency lists, mixed `1 - viShare` : `viShare`.
  factory WordPrior.build(
    Map<String, double> en,
    Map<String, double> vi, {
    required double viShare,
    required bool fold,
  }) {
    final p = <String, double>{};
    final best = <String, (String, double)>{};
    void add(Map<String, double> lex, double share) {
      final word = RegExp(r"^[\p{L}\p{M}']+$", unicode: true);
      for (final e in lex.entries) {
        if (!word.hasMatch(e.key)) continue;
        final surface = e.key.toLowerCase();
        final key = fold ? foldVietnamese(surface) : surface;
        final mass = e.value * share;
        p[key] = (p[key] ?? 0) + mass;
        final current = best[key];
        if (current == null || mass > current.$2) best[key] = (surface, mass);
      }
    }

    add(en, 1 - viShare);
    add(vi, viShare);
    final keys = p.keys.toList()..sort();
    final cum = List<double>.filled(keys.length + 1, 0);
    for (var i = 0; i < keys.length; i++) {
      cum[i + 1] = cum[i] + p[keys[i]]!;
    }
    return WordPrior._(keys, cum, p, {for (final e in best.entries) e.key: e.value.$1});
  }

  final List<String> keys;
  final List<double> cum;
  final Map<String, double> p;
  final Map<String, String> surface;
  final _top = <String, List<String>>{};

  int lowerBound(String key) {
    var lo = 0, hi = keys.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (keys[mid].compareTo(key) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  ({int lo, int hi}) range(String prefix) =>
      (lo: lowerBound(prefix), hi: lowerBound('$prefix\uffff'));

  double mass(String prefix) {
    final r = range(prefix);
    return cum[r.hi] - cum[r.lo];
  }

  /// The [k] likeliest words starting with [prefix].
  List<String> top(String prefix, int k) => _top.putIfAbsent(prefix, () {
        final r = range(prefix);
        final out = <String>[];
        for (var i = r.lo; i < r.hi; i++) {
          _insertTop(out, keys[i], k, (w) => p[w]!);
        }
        return out;
      });
}

void _insertTop(List<String> out, String key, int k, double Function(String) score) {
  final s = score(key);
  var at = out.length;
  while (at > 0 && score(out[at - 1]) < s) {
    at--;
  }
  if (at >= k) return;
  out.insert(at, key);
  if (out.length > k) out.removeLast();
}

class _Followers {
  final counts = <String, int>{};
  int total = 0;
  void add(String key) {
    counts[key] = (counts[key] ?? 0) + 1;
    total++;
  }
}

const _start = '<s>';

/// Word completion from a personal trigram over the person's own messages,
/// smoothed down to a static language prior (interpolated absolute discounting,
/// the model omp ships). The chip's confidence is the posterior of the best word
/// among every word under the typed prefix, including the prefix itself, so
/// `the|` offers `there` only when it clearly beats stopping at `the`.
class NgramPredictor implements Predictor {
  NgramPredictor(this.params, this.prior, {this.label = 'ngram'});

  final NgramParams params;
  final WordPrior prior;
  final String label;

  final _uni = <String, int>{};
  final _bi = <String, _Followers>{};
  final _tri = <String, _Followers>{};
  final _surfaces = <String, Map<String, int>>{};
  final _personal = <String>[];
  var _n = 0;
  List<String>? _globalTop;

  @override
  String get name => label;

  String _key(String word) {
    final lower = word.toLowerCase();
    return params.fold ? foldVietnamese(lower) : lower;
  }

  int _personalLowerBound(String key) {
    var lo = 0, hi = _personal.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_personal[mid].compareTo(key) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  @override
  void learn(String message) {
    if (!params.personal) return;
    final prose = {for (final w in proseWords(message)) w.start};
    String? prev2;
    String? prev1 = _start;
    for (final w in allWords(message)) {
      final word = message.substring(w.start, w.end);
      if (!prose.contains(w.start) || word.length > 24) {
        prev2 = null;
        prev1 = null;
        continue;
      }
      final key = _key(word);
      if (prev1 != null) (_bi[prev1] ??= _Followers()).add(key);
      if (prev2 != null && prev1 != null) (_tri['$prev2\t$prev1'] ??= _Followers()).add(key);
      final seen = _uni[key] ?? 0;
      if (seen == 0) _personal.insert(_personalLowerBound(key), key);
      _uni[key] = seen + 1;
      _n++;
      final s = (_surfaces[key] ??= {});
      s[word] = (s[word] ?? 0) + 1;
      prev2 = prev1;
      prev1 = key;
    }
    _globalTop = null;
  }

  double _p1(String key) =>
      ((_uni[key] ?? 0) + params.mu1 * (prior.p[key] ?? 0)) / (_n + params.mu1);

  String _surface(String key, String typed) {
    final options = _surfaces[key];
    if (options == null) return prior.surface[key] ?? key;
    String? exact, loose;
    var exactCount = 0, looseCount = 0;
    final lowerTyped = typed.toLowerCase();
    for (final e in options.entries) {
      if (e.key.startsWith(typed) && e.value > exactCount) {
        exact = e.key;
        exactCount = e.value;
      }
      if (e.value > looseCount && e.key.toLowerCase().startsWith(lowerTyped)) {
        loose = e.key;
        looseCount = e.value;
      }
    }
    return exact ?? loose ?? options.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  @override
  List<Chip> suggest(String draft, int slots) {
    final prefix = trailingWord(draft);
    final headEnd = draft.length - prefix.length;
    if (prefix.isEmpty) {
      if (!params.nextWord) return const [];
      if (draft.isNotEmpty && draft.trimRight().length == draft.length) return const [];
    } else {
      if (prefix.length < params.minPrefix) return const [];
      if (headEnd > 0) {
        final before = draft[headEnd - 1];
        if (isCodeChar(before) || RegExp(r'\d').hasMatch(before)) return const [];
      }
    }

    // Context: the last two prose words of the head, or the message start.
    final head = draft.substring(0, headEnd);
    final spans = proseWords(head);
    final words = [for (final w in spans) _key(head.substring(w.start, w.end))];
    final atStart = spans.isEmpty ? head.trim().isEmpty : head.substring(0, spans.first.start).trim().isEmpty;
    if (atStart) words.insert(0, _start);
    final v = words.isEmpty ? null : words.last;
    final u = words.length >= 2 ? words[words.length - 2] : null;
    final ctxV = v == null ? null : _bi[v];
    final ctxUV = (u == null || v == null) ? null : _tri['$u\t$v'];
    final a2 = ctxV == null ? 1.0 : (params.d2 * ctxV.counts.length + params.mu2) / (ctxV.total + params.mu2);
    final a3 = ctxUV == null ? 1.0 : (params.d3 * ctxUV.counts.length + params.mu3) / (ctxUV.total + params.mu3);

    final kp = _key(prefix);
    double p3(String key) {
      var p = _p1(key);
      if (ctxV != null) {
        final c = ctxV.counts[key] ?? 0;
        p = (math.max(c - params.d2, 0) + (params.d2 * ctxV.counts.length + params.mu2) * p) /
            (ctxV.total + params.mu2);
      }
      if (ctxUV != null) {
        final c = ctxUV.counts[key] ?? 0;
        p = (math.max(c - params.d3, 0) + (params.d3 * ctxUV.counts.length + params.mu3) * p) /
            (ctxUV.total + params.mu3);
      }
      return p;
    }

    final cands = <String>{};
    for (final f in [ctxV, ctxUV]) {
      if (f == null) continue;
      for (final k in f.counts.keys) {
        if (k.startsWith(kp)) cands.add(k);
      }
    }
    cands.addAll(prior.top(kp, params.topK));

    // Personal words under the prefix: the likeliest, and their total count.
    var sumC = 0;
    if (kp.isEmpty) {
      sumC = _n;
      cands.addAll(_globalTop ??= _topPersonal(''));
    } else {
      final top = <String>[];
      for (var i = _personalLowerBound(kp); i < _personal.length && _personal[i].startsWith(kp); i++) {
        sumC += _uni[_personal[i]]!;
        _insertTop(top, _personal[i], params.topK, (w) => _uni[w]!.toDouble());
      }
      cands.addAll(top);
    }
    final sumP0 = kp.isEmpty ? 1.0 : prior.mass(kp);

    var candMass = 0.0, candRaw = 0.0;
    final scored = <(String, double)>[];
    for (final k in cands) {
      final s = p3(k);
      candMass += s;
      candRaw += (_uni[k] ?? 0) + params.mu1 * (prior.p[k] ?? 0);
      scored.add((k, s));
    }
    final tail = math.max(0.0, (sumC + params.mu1 * sumP0 - candRaw) / (_n + params.mu1));
    final z = candMass + a3 * a2 * tail;
    if (z <= 0) return const [];

    scored.sort((a, b) => b.$2.compareTo(a.$2));
    final chips = <Chip>[];
    for (final (k, s) in scored) {
      if (chips.length >= slots || s / z < params.tau) break;
      if (!prior.p.containsKey(k) && (_uni[k] ?? 0) < params.minCount) continue;
      final surface = _surface(k, prefix);
      final n = prefix.length;
      if (surface.length < n) continue;
      final same = surface.substring(0, n).toLowerCase() == prefix.toLowerCase();
      final chip = Chip(
        label: surface,
        insert: same ? surface.substring(n) : surface,
        replace: same ? 0 : n,
        space: true,
        confidence: s / z,
      );
      if (chip.insert.isEmpty && chip.replace == 0) continue;
      chips.add(chip);
    }
    return chips;
  }

  List<String> _topPersonal(String prefix) {
    final out = <String>[];
    for (final k in _personal) {
      _insertTop(out, k, params.topK, (w) => _uni[w]!.toDouble());
    }
    return out;
  }
}
