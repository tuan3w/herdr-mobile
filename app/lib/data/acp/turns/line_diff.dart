import 'dart:typed_data';

/// Lines added and removed between two texts.
class LineStats {
  const LineStats(this.added, this.removed);

  static const none = LineStats(0, 0);

  final int added;
  final int removed;

  @override
  bool operator ==(Object other) => other is LineStats && other.added == added && other.removed == removed;

  @override
  int get hashCode => Object.hash(added, removed);

  @override
  String toString() => '+$added -$removed';
}

/// Most lines per side that get the exact count. Beyond it, and beyond
/// [maxEdits] edits, the count is by multiset (see [lineStats]).
const maxDiffLines = 5000;

/// Most edit steps (lines added plus lines removed in the shortest edit
/// script) the exact count searches for.
const maxEdits = 2000;

/// How many lines [newText] adds to [oldText] and how many it removes (`null`
/// for [oldText]: a new file, everything is added). A changed line counts as
/// one removed and one added, as `git diff --numstat` does.
///
/// Exact: the length of the shortest edit script (Myers, O(ND) time and
/// O(N+M) space; only its length is needed, so no trace is kept) after the
/// common head and tail of lines are cut away. Bounded: when a side has more
/// than [maxDiffLines] lines or the script is longer than [maxEdits], the
/// count is by multiset instead: a line is added when [newText] holds more
/// copies of it than [oldText], removed when it holds fewer. That is linear,
/// exact for any edit that does not reorder lines, and never wrong by more
/// than the lines that moved.
LineStats lineStats(String? oldText, String newText) {
  final a = _lines(oldText ?? '');
  final b = _lines(newText);
  if (a.isEmpty) return LineStats(b.length, 0);
  if (b.isEmpty) return LineStats(0, a.length);

  // Lines as small integers: compares are int compares, and the multiset is
  // a count per id.
  final ids = <String, int>{};
  final x = Int32List(a.length);
  final y = Int32List(b.length);
  for (var i = 0; i < a.length; i++) {
    x[i] = ids.putIfAbsent(a[i], () => ids.length);
  }
  for (var i = 0; i < b.length; i++) {
    y[i] = ids.putIfAbsent(b[i], () => ids.length);
  }

  var head = 0;
  while (head < x.length && head < y.length && x[head] == y[head]) {
    head++;
  }
  var tail = 0;
  while (tail < x.length - head && tail < y.length - head && x[x.length - 1 - tail] == y[y.length - 1 - tail]) {
    tail++;
  }
  final n = x.length - head - tail;
  final m = y.length - head - tail;
  if (n == 0) return LineStats(m, 0);
  if (m == 0) return LineStats(0, n);

  final oldMid = Int32List.sublistView(x, head, head + n);
  final newMid = Int32List.sublistView(y, head, head + m);
  if (a.length <= maxDiffLines && b.length <= maxDiffLines) {
    final d = _shortestScript(oldMid, newMid, maxEdits);
    if (d >= 0) {
      final common = (n + m - d) ~/ 2;
      return LineStats(m - common, n - common);
    }
  }
  return _multiset(oldMid, newMid, ids.length);
}

/// [text] as lines: no `\r` at the end of a line, and no empty last line for
/// a text that ends with a line feed.
List<String> _lines(String text) {
  if (text.isEmpty) return const [];
  final lines = text.split('\n');
  if (lines.last.isEmpty) lines.removeLast();
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (l.isNotEmpty && l.codeUnitAt(l.length - 1) == 0x0D) lines[i] = l.substring(0, l.length - 1);
  }
  return lines;
}

/// The length of the shortest script of insertions and deletions that turns
/// [a] into [b] (Myers 1986, forward pass only), or -1 when it is longer than
/// [limit].
int _shortestScript(Int32List a, Int32List b, int limit) {
  final n = a.length, m = b.length;
  final top = n + m < limit ? n + m : limit;
  final offset = top + 1;
  final v = Int32List(2 * top + 3);
  for (var d = 0; d <= top; d++) {
    for (var k = -d; k <= d; k += 2) {
      var px = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1;
      var py = px - k;
      while (px < n && py < m && a[px] == b[py]) {
        px++;
        py++;
      }
      v[offset + k] = px;
      if (px >= n && py >= m) return d;
    }
  }
  return -1;
}

LineStats _multiset(Int32List a, Int32List b, int distinct) {
  final delta = Int32List(distinct);
  for (final id in a) {
    delta[id]--;
  }
  for (final id in b) {
    delta[id]++;
  }
  var added = 0, removed = 0;
  for (final d in delta) {
    if (d > 0) {
      added += d;
    } else {
      removed -= d;
    }
  }
  return LineStats(added, removed);
}
