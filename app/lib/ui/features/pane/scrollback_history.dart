import 'dart:math' as math;

/// Keeps the rows that scrolled off the top of a sliding `pane.read` window.
///
/// The server only ever returns the last N rows of a pane, and the window
/// slides as output scrolls. Every read is merged with what is already known
/// so the user can scroll back further than the server limit, and so that a
/// deeper read (300 -> 1000 rows) can reveal rows older than anything seen.
///
/// Rows are compared as raw strings (ANSI escapes and the trailing `\r`
/// included) and never parsed here. The caller parses `rows` followed by the
/// live window starting from the default style, which is why dropping rows
/// from the top (the size cap) needs no style bookkeeping: there is no parser
/// state to repair, and [gapRow] resets its own style on both ends so it
/// never leaks colour into its neighbours.
///
/// Terminology used below: `H` is the history ([rows]), `P` the previous
/// window, `N` the new window and `K = H + P` everything known, in order.
class ScrollbackHistory {
  ScrollbackHistory({this.maxRows = 20000, this.maxBytes = 8 * 1024 * 1024});

  /// Oldest history rows are discarded past this many rows.
  final int maxRows;

  /// Oldest history rows are discarded past this many UTF-16 code units.
  final int maxBytes;

  /// Marks output that was never captured (the pane jumped further than one
  /// read can see). Dim and self-contained: it starts and ends with a reset.
  static const gapRow = '\x1b[0m\x1b[2m··· output not captured ···\x1b[0m';

  /// How many rows the window may have shrunk at the bottom (rows deleted in
  /// place) and still be recognised as the same pane. A fixed small margin
  /// keeps the candidate scan bounded by the window size.
  static const _slack = 64;

  /// Mutable so the common case (a few rows scrolled off) is an `addAll`
  /// instead of a copy of up to [maxRows] rows.
  final List<String> _history = [];
  List<String> _snapshot = const [];
  bool _snapshotStale = false;

  /// UTF-16 length of every row in [_history], maintained incrementally.
  int _historyBytes = 0;

  /// Index in [_history] of the newest [gapRow], or -1. Rows after it are
  /// provably contiguous with the window.
  int _lastGap = -1;

  /// Rows of the current window (`P` for the next merge).
  List<String> _windowRows = const [];
  String _window = '';
  bool _truncated = false;
  int _dropped = 0;
  int _revision = 0;

  /// Rows above the live window, oldest first (may contain [gapRow]).
  ///
  /// An immutable snapshot, rebuilt lazily and only after the history changed,
  /// so the same instance is returned until then and callers can use
  /// `identical()` for change detection.
  List<String> get rows {
    if (_snapshotStale) {
      _snapshot = _history.isEmpty ? const [] : List.unmodifiable(_history);
      _snapshotStale = false;
    }
    return _snapshot;
  }

  /// The live window exactly as the last read returned it.
  String get window => _window;

  /// Whether the last read said older rows exist on the server.
  bool get truncated => _truncated;

  /// Rows removed from the top because of [maxRows]/[maxBytes], ever.
  int get dropped => _dropped;

  /// Rows of the window.
  int get windowRows => _windowRows.length;

  /// Rows provably contiguous with the window: those after the last
  /// [gapRow] plus the window itself. A deeper read can only reveal older
  /// rows while this is below the server's read limit.
  int get contiguousRows => _history.length - 1 - _lastGap + _windowRows.length;

  /// Bumped on every change to [rows] or [window].
  int get revision => _revision;

  /// Splits a `pane.read` payload into rows: on `\n`, dropping ONE final empty
  /// piece so a trailing newline does not start another row (it mirrors how a
  /// terminal ends its last line).
  static List<String> splitRows(String text) {
    final rows = text.split('\n');
    if (rows.last.isEmpty) rows.removeLast();
    return rows;
  }

  /// Merges a new read. Idempotent for an identical read.
  void update(String text, {required bool truncated}) {
    if (text == _window) {
      if (truncated != _truncated) {
        _truncated = truncated;
        _revision++;
      }
      return;
    }
    final next = splitRows(text);
    if (_history.isNotEmpty || _windowRows.isNotEmpty) {
      _merge(next, previousTruncated: _truncated);
    }
    _window = text;
    _windowRows = next;
    _truncated = truncated;
    _revision++;
    _enforceCap();
  }

  /// Forgets everything (used when the read source switches).
  void clear() {
    _history.clear();
    _snapshot = const [];
    _snapshotStale = false;
    _historyBytes = 0;
    _lastGap = -1;
    _windowRows = const [];
    _window = '';
    _truncated = false;
    _dropped = 0;
    _revision++;
  }

  /// Brings the history in line with [next], the freshly read window.
  ///
  /// Alignment is searched only in the part of `K` after the last [gapRow]:
  /// rows on either side of a gap are not adjacent in the pane, so comparing
  /// across it can never line up. When [next] reaches above that part (a
  /// deeper read), [_bridgeGap] checks whether it also reached the rows
  /// before the gap.
  void _merge(List<String> next, {required bool previousTruncated}) {
    final start = _lastGap + 1;
    final historyLength = _history.length;
    final end = historyLength + _windowRows.length;
    final viewLength = end - start;
    final s = _align(
      next,
      from: start,
      to: end,
      lo: math.max(viewLength - next.length - _slack, 1 - next.length),
      hi: viewLength - 1,
      // Without scrolling, N[0] sits where the previous window began.
      ref: historyLength - start,
    );
    if (s == null) {
      _openGap(previousTruncated);
    } else if (s >= 0) {
      _setHistoryLength(start + s);
    } else if (start == 0) {
      // N starts above everything known: all of it is inside N now.
      _setHistoryLength(0);
    } else {
      _bridgeGap(next, revealed: -s);
    }
  }

  /// No acceptable alignment: the pane was cleared, redrawn, or output
  /// jumped further than one read can see.
  ///
  /// When the previous read was truncated, P was a slice of long scrollback,
  /// so its rows were real output and are kept. When it was not, P was the
  /// whole pane and is simply replaced; keeping it would pile up a screen
  /// per redraw of a full-screen app.
  void _openGap(bool previousTruncated) {
    if (previousTruncated) _append(_windowRows);
    if (_history.isEmpty || identical(_history.last, gapRow)) return;
    _lastGap = _history.length;
    _append(const [gapRow]);
  }

  /// [next] reaches `revealed` rows above the first row after the last gap.
  /// If it also contains the end of the pre-gap history, nothing is missing
  /// any more: the pre-gap rows it duplicates are cut and the gap closes.
  /// Otherwise the gap stays and [next] simply replaces everything after it.
  void _bridgeGap(List<String> next, {required int revealed}) {
    final gapIndex = _lastGap;
    // Demand a few rows of overlap so one coincidentally repeated line
    // cannot close a gap.
    final s = _align(
      next,
      from: 0,
      to: gapIndex,
      lo: math.max(gapIndex - revealed, 1 - next.length),
      hi: gapIndex - math.min(4, gapIndex),
      ref: gapIndex - math.min(4, gapIndex),
    );
    _setHistoryLength(s == null ? gapIndex + 1 : math.max(s, 0));
  }

  /// Finds where `next[0]` sits inside `K[from, to)` (view coordinates), or
  /// null when no candidate in `[lo, hi]` is acceptable.
  ///
  /// Candidates are visited by increasing distance from [ref] (the position
  /// implying the least scrolling) and only a strictly better score replaces
  /// the current best, so ties resolve towards [ref], and towards more
  /// scrolling when equally far.
  int? _align(
    List<String> next, {
    required int from,
    required int to,
    required int lo,
    required int hi,
    required int ref,
  }) {
    if (lo > hi) return null;
    final viewLength = to - from;
    int? found;
    var best = 0;
    final farthest = math.max((ref - lo).abs(), (hi - ref).abs());
    for (var d = 0; d <= farthest; d++) {
      for (var side = 0; side < (d == 0 ? 1 : 2); side++) {
        final s = side == 0 ? ref + d : ref - d;
        if (s < lo || s > hi) continue;
        final matches = _matchesAt(next, from, viewLength, s, best);
        if (matches > best) {
          best = matches;
          found = s;
        }
      }
    }
    return found;
  }

  /// Number of equal row pairs when `next[0]` sits at [s] in the view, or 0
  /// if the candidate is unacceptable or cannot beat [best].
  ///
  /// Acceptable means: at least `min(overlap, 4)` and half of the overlap
  /// matches, and a matching row has content (unless there are 4+ blank
  /// matches, a legitimately blank stretch). The first overlapping rows must
  /// be equal: the top of the overlap is stable scrollback, while the live
  /// region at the bottom (spinners, prompts) rewrites in place. Rejecting on
  /// the first mismatch plus a miss budget derived from [best] keeps
  /// degenerate input (hundreds of identical rows) from going quadratic.
  int _matchesAt(List<String> next, int from, int viewLength, int s, int best) {
    final knownStart = from + (s > 0 ? s : 0);
    final nextStart = s < 0 ? -s : 0;
    final overlap = math.min(
      viewLength - (s > 0 ? s : 0),
      next.length - nextStart,
    );
    if (overlap <= 0 || _known(knownStart) != next[nextStart]) return 0;
    final needed = math.max(
      math.max(best + 1, (overlap + 1) >> 1),
      math.min(overlap, 4),
    );
    var missBudget = overlap - needed;
    if (missBudget < 0) return 0;
    var matches = 0;
    var hasContent = false;
    for (var i = 0; i < overlap; i++) {
      final row = next[nextStart + i];
      if (_known(knownStart + i) == row) {
        matches++;
        if (!hasContent && !_isBlank(row)) hasContent = true;
      } else if (--missBudget < 0) {
        return 0;
      }
    }
    return hasContent || overlap >= 4 ? matches : 0;
  }

  /// Row `i` of `K`, without materialising `H + P`.
  String _known(int i) {
    final historyLength = _history.length;
    return i < historyLength ? _history[i] : _windowRows[i - historyLength];
  }

  /// Whether a row shows nothing: whitespace, `\r` and SGR sequences only.
  /// Any other escape (cursor movement, ...) counts as content.
  static bool _isBlank(String row) {
    var i = 0;
    while (i < row.length) {
      final c = row.codeUnitAt(i);
      if (c == 0x20 || c == 0x09 || c == 0x0d || c == 0x0a) {
        i++;
      } else if (c == 0x1b &&
          i + 1 < row.length &&
          row.codeUnitAt(i + 1) == 0x5b) {
        i += 2;
        while (i < row.length && !_isCsiFinal(row.codeUnitAt(i))) {
          i++;
        }
        if (i >= row.length || row.codeUnitAt(i) != 0x6d) return false;
        i++;
      } else {
        return false;
      }
    }
    return true;
  }

  static bool _isCsiFinal(int c) => c >= 0x40 && c <= 0x7e;

  /// Makes the history exactly `K[0, length)`: shorter drops rows from the
  /// end (a deeper read replaced them with fresher ones), longer appends rows
  /// of P that scrolled off the window.
  void _setHistoryLength(int length) {
    final current = _history.length;
    if (length == current) return;
    _snapshotStale = true;
    if (length > current) {
      _append(_windowRows.sublist(0, length - current));
      return;
    }
    for (var i = length; i < current; i++) {
      _historyBytes -= _history[i].length;
    }
    _history.removeRange(length, current);
    if (_lastGap >= length) {
      var i = length - 1;
      while (i >= 0 && !identical(_history[i], gapRow)) {
        i--;
      }
      _lastGap = i;
    }
  }

  void _append(List<String> added) {
    if (added.isEmpty) return;
    for (final row in added) {
      _historyBytes += row.length;
    }
    _history.addAll(added);
    _snapshotStale = true;
  }

  /// Drops the oldest rows until [maxRows] and [maxBytes] hold. Done after
  /// merging so the cap never influences which rows are kept as contiguous.
  void _enforceCap() {
    if (_history.length <= maxRows && _historyBytes <= maxBytes) return;
    final length = _history.length;
    var count = 0;
    var freed = 0;
    while (count < length &&
        (length - count > maxRows || _historyBytes - freed > maxBytes)) {
      freed += _history[count].length;
      count++;
    }
    // A gap marker at the very top would describe nothing above it.
    if (count < length && identical(_history[count], gapRow)) {
      freed += gapRow.length;
      count++;
    }
    for (var i = 0; i < count; i++) {
      if (!identical(_history[i], gapRow)) _dropped++;
    }
    _history.removeRange(0, count);
    _historyBytes -= freed;
    _lastGap = _lastGap < count ? -1 : _lastGap - count;
    _snapshotStale = true;
  }
}
