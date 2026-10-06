import 'dart:collection';
import 'dart:math' as math;

import 'package:characters/characters.dart';

/// Decides how much of the text that arrived is shown now, so text appears at
/// a steady pace instead of in the lumps the agent, SSH and the keeper
/// deliver. Pure Dart: no clock (the caller passes the time that passed), no
/// Flutter, no allocation proportional to anything but the backlog.
///
/// Usage, once per frame while there is anything to show: [append] what
/// arrived, then `advance(dt)` and add the returned delta to the text on
/// screen. [snap] ends the pacing for good measure (below).
///
/// **Rate.** Per frame ([frame], 16 ms) the pacer reveals
/// `max(minRate, backlog * k, deadline rate)` characters, where
/// - `minRate` keeps a trickle moving (a few characters a frame);
/// - `backlog * k` drains a lump quickly at first and a steady stream with a
///   short backlog (at `k = 1/6` a stream of `r` characters a frame settles at
///   a backlog of `6 r`, about 100 ms of text);
/// - the *deadline rate* is what it takes to show every piece that arrived
///   within [maxLag] of its arrival: the lag between a character arriving and
///   being shown stays at most about [maxLag] (200 ms; with the frame and the
///   cut to a word the visible lag stays under ~250 ms), whatever the cadence.
///   Time is the sum of the `dt`s passed to [advance]; a piece is stamped
///   with the time of the last [advance], up to a frame early, never late.
///
/// **Cuts.** The revealed text always ends
/// - on a *grapheme cluster* boundary (`package:characters`: combining marks,
///   emoji ZWJ sequences, surrogate pairs, flags, and CRLF stay whole), and
///   never inside the last cluster of the pending text, which the next chunk
///   may still extend (`e` now, U+0301 next);
/// - on a *word boundary* (right after whitespace): a word is shown when it is
///   whole, so the partial last word of the pending text waits for its
///   whitespace (or for its deadline). A token with no whitespace within
///   [longToken] characters (a path, a URL, a hash) is cut on characters
///   instead, so it does not wait for its end.
/// A piece past its deadline is shown whatever it takes (to the next word
/// boundary when one is within [longToken], else to the character).
///
/// **Reduced motion** ([reducedMotion]): no rate; every *complete line* is
/// shown as soon as it is pending, and the partial last line waits for its
/// newline or its deadline. Long single-line paragraphs therefore arrive in
/// steps of [maxLag] at most.
///
/// **The caller snaps** (shows everything pending with no animation, via
/// [snap]) when: the turn ends, the app resumes, the person touches the
/// transcript, the text is history (a replay, a message that was already
/// there when the row first showed), or the reveal is not wanted. The pacer
/// snaps by itself, in [advance], when the backlog grows past [snapBacklog]
/// (a paste, a replay arriving as chunks): pacing 8 KB would only delay it.
///
/// Deterministic: the same appends and the same `dt`s give the same deltas.
/// The concatenation of every delta and the final [snap] is exactly the
/// concatenation of everything appended; the text is never altered.
class RevealPacer {
  RevealPacer({
    this.frame = const Duration(milliseconds: 16),
    this.minRate = 2,
    this.k = 1 / 6,
    this.maxLag = const Duration(milliseconds: 200),
    this.snapBacklog = 8192,
    this.longToken = 24,
    this.reducedMotion = false,
  }) : assert(frame > Duration.zero && minRate > 0 && k >= 0 && longToken > 0 && snapBacklog > 0);

  /// The frame the rate is counted in.
  final Duration frame;

  /// Characters per frame at least, while anything is pending.
  final double minRate;

  /// Fraction of the backlog shown per frame.
  final double k;

  /// How long after it arrived a character is shown at the latest, apart from
  /// one frame and the cut to a word.
  final Duration maxLag;

  /// A backlog past this many characters is shown at once.
  final int snapBacklog;

  /// A token longer than this is cut on characters, not on its end.
  final int longToken;

  /// Whole lines at a time instead of a rate (the system asks for less motion).
  bool reducedMotion;

  String _pending = '';
  final _pieces = ListQueue<_Piece>();
  Duration _now = Duration.zero;
  double _credit = 0;

  /// Characters that arrived and are not shown yet.
  int get backlog => _pending.length;

  /// The text that arrived and is not shown yet.
  String get pending => _pending;

  bool get isIdle => _pending.isEmpty;

  /// Takes [text] that just arrived.
  void append(String text) {
    if (text.isEmpty) return;
    _pending += text;
    _pieces.add(_Piece(text.length, _now + maxLag));
  }

  /// Shows everything pending, now.
  String snap() {
    final all = _pending;
    _pending = '';
    _pieces.clear();
    _credit = 0;
    return all;
  }

  /// [dt] passed since the last call: the next part of the text to show (may be
  /// empty).
  String advance(Duration dt) {
    _now += dt;
    if (_pending.isEmpty) {
      _credit = 0;
      return '';
    }
    if (_pending.length > snapBacklog) return snap();
    final frames = dt.inMicroseconds / frame.inMicroseconds;
    final must = _overdue();
    int n;
    if (reducedMotion) {
      n = _lineEnd();
    } else {
      var rate = math.max(minRate, _pending.length * k);
      rate = math.max(rate, _deadlineRate());
      _credit = math.min(_credit + rate * frames, _pending.length.toDouble());
      n = _wordCut(_credit.floor());
    }
    if (n < must) n = _forcedCut(must);
    if (n <= 0) return '';
    return _reveal(n);
  }

  String _reveal(int n) {
    final out = _pending.substring(0, n);
    _pending = _pending.substring(n);
    _credit = math.min(math.max(0, _credit - n), _pending.length.toDouble());
    var left = n;
    while (left > 0 && _pieces.isNotEmpty) {
      final head = _pieces.first;
      if (head.left <= left) {
        left -= head.left;
        _pieces.removeFirst();
      } else {
        head.left -= left;
        left = 0;
      }
    }
    return out;
  }

  /// Characters per frame that show every piece by its deadline.
  double _deadlineRate() {
    var cumulative = 0;
    var rate = 0.0;
    for (final p in _pieces) {
      cumulative += p.left;
      final frames = math.max(1.0, (p.deadline - _now).inMicroseconds / frame.inMicroseconds);
      rate = math.max(rate, cumulative / frames);
    }
    return rate;
  }

  /// Characters of the pieces whose deadline has come.
  int _overdue() {
    var n = 0;
    for (final p in _pieces) {
      if (p.deadline > _now) break;
      n += p.left;
    }
    return n;
  }

  static bool _space(int unit) => unit == 0x20 || unit == 0x0A || unit == 0x09;

  /// The cut for a rate that allows [want] characters: the last word boundary
  /// at or before it; characters for a long token; nothing while the word is
  /// not whole.
  int _wordCut(int want) {
    final text = _pending;
    final reach = math.min(want, text.length);
    for (var i = reach; i > 0; i--) {
      if (_after(i)) return i;
    }
    // No boundary in reach. A short token that may still grow waits; a token
    // longer than [longToken] is cut on characters.
    final limit = math.min(text.length, longToken + 1);
    for (var i = 0; i < limit; i++) {
      if (_space(text.codeUnitAt(i))) return 0;
    }
    if (text.length <= longToken) return 0;
    return _graphemeDown(reach, allowLast: false);
  }

  /// Whether [i] is a place to cut after whitespace: the whitespace is a
  /// cluster of its own (no combining mark follows it).
  bool _after(int i) {
    final text = _pending;
    if (!_space(text.codeUnitAt(i - 1))) return false;
    if (i >= text.length) return true;
    return text.substring(i - 1, math.min(text.length, i + 4)).characters.first.length == 1;
  }

  /// The end of the last complete line.
  int _lineEnd() {
    final i = _pending.lastIndexOf('\n');
    return i < 0 ? 0 : i + 1;
  }

  /// A cut of at least [must] characters (a deadline came): the next word
  /// boundary when one is near, else the character.
  int _forcedCut(int must) {
    final text = _pending;
    if (must >= text.length) return _graphemeDown(text.length, allowLast: true, hold: _trailingReturn);
    final limit = math.min(text.length, must + longToken);
    for (var i = math.max(must, 1); i <= limit; i++) {
      if (_after(i)) return i;
    }
    return _graphemeUp(must);
  }

  /// A lone `\r` at the end may be half of a CRLF: it waits for its `\n`.
  bool get _trailingReturn => _pending.codeUnitAt(_pending.length - 1) == 0x0D;

  /// The largest grapheme boundary at or before [p]. The last cluster of the
  /// pending text counts only with [allowLast] (the next chunk may extend
  /// it), and a lone `\r` at the end only without [hold].
  int _graphemeDown(int p, {required bool allowLast, bool hold = false}) {
    final text = _pending;
    var at = 0;
    final it = text.characters.iterator;
    while (it.moveNext()) {
      final next = at + it.current.length;
      if (next > p) break;
      if (next == text.length && (!allowLast || hold)) break;
      at = next;
    }
    return at;
  }

  /// The smallest grapheme boundary at or after [p].
  int _graphemeUp(int p) {
    final text = _pending;
    var at = 0;
    final it = text.characters.iterator;
    while (at < p && it.moveNext()) {
      at += it.current.length;
    }
    return at;
  }
}

class _Piece {
  _Piece(this.left, this.deadline);

  /// Characters of this piece not shown yet.
  int left;

  /// When the last of them must be shown, on the pacer's time.
  final Duration deadline;
}
