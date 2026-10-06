/// How a line of a rendered diff relates to the file.
enum DiffKind { same, add, del, gap }

class DiffLine {
  const DiffLine(this.kind, this.text);

  final DiffKind kind;

  /// The line, or for [DiffKind.gap] a sentence naming the lines left out.
  final String text;
}

/// A line diff of [oldText] (null for a new file) against [newText], as the
/// changed lines with [context] unchanged lines around each change and a
/// [DiffKind.gap] line where a longer unchanged run was left out.
///
/// The common head and tail are cut off first. When what remains would need
/// more than [maxCells] cells of the longest-common-subsequence table, the
/// middle is shown as all removed then all added: right, never slow. A diff
/// of two huge files therefore costs two passes over their lines, not a
/// quadratic table.
List<DiffLine> diffLines(String? oldText, String newText, {int context = 2, int maxCells = 250000}) {
  final a = oldText == null ? const <String>[] : _lines(oldText);
  final b = _lines(newText);

  var head = 0;
  while (head < a.length && head < b.length && a[head] == b[head]) {
    head++;
  }
  var tail = 0;
  while (tail < a.length - head && tail < b.length - head && a[a.length - 1 - tail] == b[b.length - 1 - tail]) {
    tail++;
  }
  final midA = a.sublist(head, a.length - tail);
  final midB = b.sublist(head, b.length - tail);

  final ops = <DiffLine>[
    for (var i = 0; i < head; i++) DiffLine(DiffKind.same, a[i]),
    ..._middle(midA, midB, maxCells),
    for (var i = a.length - tail; i < a.length; i++) DiffLine(DiffKind.same, a[i]),
  ];
  return _collapse(ops, context);
}

List<String> _lines(String text) {
  final lines = text.split('\n');
  // A final newline ends the last line; it does not start another.
  if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
  return lines;
}

List<DiffLine> _middle(List<String> a, List<String> b, int maxCells) {
  if (a.isEmpty || b.isEmpty || (a.length + 1) * (b.length + 1) > maxCells) {
    return [
      for (final line in a) DiffLine(DiffKind.del, line),
      for (final line in b) DiffLine(DiffKind.add, line),
    ];
  }
  final w = b.length + 1;
  // lcs[i * w + j]: the longest common subsequence of a[i..] and b[j..].
  final lcs = List<int>.filled((a.length + 1) * w, 0);
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      lcs[i * w + j] = a[i] == b[j] ? lcs[(i + 1) * w + j + 1] + 1 : _max(lcs[(i + 1) * w + j], lcs[i * w + j + 1]);
    }
  }
  final out = <DiffLine>[];
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] == b[j]) {
      out.add(DiffLine(DiffKind.same, a[i]));
      i++;
      j++;
    } else if (lcs[(i + 1) * w + j] >= lcs[i * w + j + 1]) {
      out.add(DiffLine(DiffKind.del, a[i++]));
    } else {
      out.add(DiffLine(DiffKind.add, b[j++]));
    }
  }
  while (i < a.length) {
    out.add(DiffLine(DiffKind.del, a[i++]));
  }
  while (j < b.length) {
    out.add(DiffLine(DiffKind.add, b[j++]));
  }
  return out;
}

int _max(int a, int b) => a > b ? a : b;

List<DiffLine> _collapse(List<DiffLine> ops, int context) {
  final keep = List<bool>.filled(ops.length, false);
  for (var i = 0; i < ops.length; i++) {
    if (ops[i].kind == DiffKind.same) continue;
    final from = i - context < 0 ? 0 : i - context;
    final to = i + context >= ops.length ? ops.length - 1 : i + context;
    for (var k = from; k <= to; k++) {
      keep[k] = true;
    }
  }
  final out = <DiffLine>[];
  var i = 0;
  while (i < ops.length) {
    if (keep[i]) {
      out.add(ops[i++]);
      continue;
    }
    var end = i;
    while (end < ops.length && !keep[end]) {
      end++;
    }
    final n = end - i;
    if (n == 1) {
      out.add(ops[i]);
    } else {
      out.add(DiffLine(DiffKind.gap, '$n unchanged lines'));
    }
    i = end;
  }
  return out;
}
