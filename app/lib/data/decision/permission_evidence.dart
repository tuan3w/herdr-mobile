import 'dart:typed_data';

import '../acp/acp_models.dart';
import '../acp/session_state.dart';
import 'plain_text.dart';

/// Most characters of a plan that are kept. The rest is cut and named in the
/// text itself; a 2 MB plan costs one `substring` here and one screen of
/// Markdown there.
const planCharLimit = 40000;

/// Most characters kept of each side (old, new) of one diff.
const diffSideCharLimit = 60000;

/// Most diffs, and most locations, kept; the number left out is reported.
const maxEvidenceDiffs = 12;
const maxEvidenceLocations = 20;

/// Longest intent: the agent's last sentence before it asked.
const intentCharLimit = 200;

/// How many edit steps the line diff may take before the counts become an
/// upper bound ([EvidenceDiff.approximate]).
const _maxEditSteps = 1000;

/// Lines of the two sides together above which the line diff is not tried.
const _maxDiffLines = 20000;

/// One file change a request asks to make.
class EvidenceDiff {
  const EvidenceDiff({
    required this.path,
    required this.oldText,
    required this.newText,
    required this.added,
    required this.removed,
    this.approximate = false,
    this.cutChars = 0,
  });

  /// Hidden characters made visible.
  final String path;

  /// The file before; null for a new file. Cut at [diffSideCharLimit].
  final String? oldText;

  /// The file after, cut at [diffSideCharLimit].
  final String newText;

  /// Lines added and removed. Exact unless [approximate].
  final int added;
  final int removed;

  /// The counts are an upper bound: the change was too large to compare line
  /// by line (or a side was cut), so every line of the changed middle counts.
  final bool approximate;

  /// Characters cut from the two sides together (0 when both are whole).
  final int cutChars;

  bool get isNew => oldText == null;
}

/// A file (and line) the call names.
class EvidenceLocation {
  const EvidenceLocation(this.path, [this.line]);

  final String path;
  final int? line;

  /// `path` or `path:line`.
  String get label => line == null ? path : '$path:$line';
}

/// What lets the person judge a request: the plan being approved, the edits
/// being made, the files touched, and what the agent said just before it
/// asked. Every part is bounded and free of hidden characters; absent data is
/// null or empty, never a placeholder.
class PermissionEvidence {
  const PermissionEvidence({
    this.planMarkdown,
    this.planCutChars = 0,
    this.planIsPreview = false,
    this.diffs = const [],
    this.hiddenDiffs = 0,
    this.locations = const [],
    this.hiddenLocations = 0,
    this.intent,
  });

  static const empty = PermissionEvidence();

  /// The plan as Markdown (Claude `ExitPlanMode`, codex plan review, omp
  /// plan approval), cut at [planCharLimit] with a closing note; null when
  /// the request carries none.
  final String? planMarkdown;

  /// Characters cut from the plan (0 when whole).
  final int planCutChars;

  /// The plan is only the start of the real one: omp puts the first 12 lines
  /// of the plan in its question and nothing more.
  final bool planIsPreview;

  /// The file changes the call carries, at most [maxEvidenceDiffs].
  final List<EvidenceDiff> diffs;

  /// Diffs beyond the ones kept.
  final int hiddenDiffs;

  /// The files and lines the call names, at most [maxEvidenceLocations].
  final List<EvidenceLocation> locations;
  final int hiddenLocations;

  /// The agent's last sentence before it asked ([lastAgentSentence]).
  final String? intent;

  bool get hasPlan => planMarkdown != null;
  bool get isEmpty => planMarkdown == null && diffs.isEmpty && locations.isEmpty && intent == null;

  PermissionEvidence withIntent(String? intent) => PermissionEvidence(
    planMarkdown: planMarkdown,
    planCutChars: planCutChars,
    planIsPreview: planIsPreview,
    diffs: diffs,
    hiddenDiffs: hiddenDiffs,
    locations: locations,
    hiddenLocations: hiddenLocations,
    intent: intent,
  );
}

/// The evidence of a `session/request_permission`. [items] is the transcript
/// the request belongs to, read for the agent's last sentence.
PermissionEvidence permissionEvidence(PermissionRequest request, {List<TranscriptItem> items = const []}) {
  final call = request.toolCall.applyTo(null);

  // -- the plan -------------------------------------------------------------
  String? plan = _planText(call.rawInput);
  if (plan == null && _isPlanCall(call, request)) plan = _firstText(call.content);
  var planCut = 0;
  if (plan != null) {
    final capped = capText(plan, planCharLimit);
    planCut = capped.$2;
    plan = _closePlan(showHidden(capped.$1), planCut);
  }

  // -- the edits ------------------------------------------------------------
  final diffs = <EvidenceDiff>[];
  var hiddenDiffs = 0;
  for (final c in call.content) {
    if (c is! ToolDiff) continue;
    if (diffs.length >= maxEvidenceDiffs) {
      hiddenDiffs++;
    } else {
      diffs.add(_diff(c));
    }
  }

  // -- the files ------------------------------------------------------------
  final locations = <EvidenceLocation>[];
  var hiddenLocations = 0;
  final seen = <String>{};
  void addLocation(String path, int? line) {
    if (path.trim().isEmpty) return;
    final loc = EvidenceLocation(showHidden(path), line);
    if (!seen.add(loc.label)) return;
    if (locations.length >= maxEvidenceLocations) {
      hiddenLocations++;
    } else {
      locations.add(loc);
    }
  }

  for (final l in call.locations) {
    addLocation(l.path, l.line);
  }
  if (call.locations.isEmpty && diffs.isEmpty) {
    final input = call.rawInput;
    if (input is Map) {
      for (final key in _pathKeys) {
        final v = input[key];
        if (v is String) addLocation(v, null);
      }
    }
  }

  return PermissionEvidence(
    planMarkdown: plan,
    planCutChars: planCut,
    diffs: diffs,
    hiddenDiffs: hiddenDiffs,
    locations: locations,
    hiddenLocations: hiddenLocations,
    intent: lastAgentSentence(items, beforeToolCallId: call.toolCallId.isEmpty ? null : call.toolCallId),
  );
}

/// The evidence of an `elicitation/create` that is a plan approval, else
/// null (a plain question is its own evidence).
///
/// omp asks to approve a plan through a form (`acp-agent.ts`,
/// `#requestAcpPlanApprovalChoice`): the message is `Approve plan "<title>"
/// and start implementation?`, a blank line, the first 12 lines of the plan
/// (and `…` when there are more), and the one field is a string enum of
/// `Approve and execute` / `Refine plan`. The plan is read from the message
/// and marked [PermissionEvidence.planIsPreview] when it was cut.
PermissionEvidence? planApprovalEvidence(ElicitationRequest request, {List<TranscriptItem> items = const []}) {
  final schema = request.schema;
  if (request.mode != 'form' || schema == null) return null;
  var approves = false;
  for (final f in schema.fields) {
    if (f is! EnumField) continue;
    final values = {for (final o in f.options) o.value.trim()};
    if (values.contains(_ompApprove) && values.contains(_ompRefine)) approves = true;
  }
  if (!approves || !request.message.trimLeft().startsWith('Approve plan')) return null;

  final message = request.message;
  final gap = message.indexOf('\n\n');
  if (gap < 0) return null;
  var body = message.substring(gap + 2).trimRight();
  final preview = body.endsWith('\n\u2026');
  if (preview) body = body.substring(0, body.length - 2).trimRight();
  if (body.trim().isEmpty) return null;
  final capped = capText(body, planCharLimit);
  return PermissionEvidence(
    planMarkdown: _closePlan(showHidden(capped.$1), capped.$2),
    planCutChars: capped.$2,
    planIsPreview: preview,
    intent: lastAgentSentence(items, beforeToolCallId: request.toolCallId),
  );
}

const _ompApprove = 'Approve and execute';
const _ompRefine = 'Refine plan';

const _pathKeys = ['file_path', 'filePath', 'path', 'notebook_path'];

String? _planText(Object? rawInput) {
  if (rawInput is! Map) return null;
  final plan = rawInput['plan'];
  return plan is String && plan.trim().isNotEmpty ? plan : null;
}

/// A call whose content text is a plan: Claude's `ExitPlanMode` and codex's
/// plan review are kind `switch_mode`; the name and the codex option ids are
/// a second opinion for adapters that omit the kind. Other calls put a
/// description in their content text, which must not pass for a plan.
bool _isPlanCall(ToolCall call, PermissionRequest request) =>
    call.kind == ToolKind.switchMode ||
    call.name == 'ExitPlanMode' ||
    request.hasOption('implement_plan') ||
    request.hasOption('revise_plan');

String? _firstText(List<ToolContent> content) {
  for (final c in content) {
    if (c is ToolContentBlock) {
      final b = c.block;
      if (b is TextBlock && b.text.trim().isNotEmpty) return b.text;
    }
  }
  return null;
}

/// The plan, with a note when it was cut and an open code fence closed so the
/// note does not render as code.
String _closePlan(String text, int cut) {
  if (cut == 0) return text;
  var fences = 0;
  var from = 0;
  while (true) {
    final at = text.indexOf('```', from);
    if (at < 0) break;
    fences++;
    from = at + 3;
  }
  final close = fences.isOdd ? '\n```' : '';
  return '${text.trimRight()}$close\n\n\u2026 $cut more characters not shown';
}

// ---------------------------------------------------------------------------
// diffs

EvidenceDiff _diff(ToolDiff d) {
  final oldCapped = d.oldText == null ? null : capText(d.oldText!, diffSideCharLimit);
  final newCapped = capText(d.newText, diffSideCharLimit);
  final cut = (oldCapped?.$2 ?? 0) + newCapped.$2;
  final oldText = oldCapped?.$1;
  final newText = newCapped.$1;
  final lines = lineDiffCounts(oldText ?? '', newText);
  return EvidenceDiff(
    path: showHidden(d.path),
    oldText: oldText,
    newText: newText,
    added: lines.added,
    removed: lines.removed,
    approximate: lines.approximate || cut > 0,
    cutChars: cut,
  );
}

/// Lines added and removed between two texts.
class LineDiffCounts {
  const LineDiffCounts(this.added, this.removed, {this.approximate = false});

  final int added;
  final int removed;

  /// An upper bound, not the minimal diff.
  final bool approximate;
}

/// The minimal line diff's counts (Myers, edit distance only), after the
/// common head and tail lines are dropped. Past [_maxEditSteps] edits or
/// [_maxDiffLines] lines it gives the upper bound: every line of the changed
/// middle, flagged approximate.
LineDiffCounts lineDiffCounts(String before, String after) {
  final ids = <String, int>{};
  List<int> toIds(String text) {
    if (text.isEmpty) return const [];
    final lines = text.split('\n');
    if (lines.last.isEmpty) lines.removeLast();
    return [for (final l in lines) ids.putIfAbsent(l, () => ids.length)];
  }

  final a = toIds(before);
  final b = toIds(after);
  var head = 0;
  while (head < a.length && head < b.length && a[head] == b[head]) {
    head++;
  }
  var tail = 0;
  while (tail < a.length - head && tail < b.length - head && a[a.length - 1 - tail] == b[b.length - 1 - tail]) {
    tail++;
  }
  final n = a.length - head - tail;
  final m = b.length - head - tail;
  if (n == 0 || m == 0) return LineDiffCounts(m, n);
  if (n + m > _maxDiffLines) return LineDiffCounts(m, n, approximate: true);

  final limit = n + m < _maxEditSteps ? n + m : _maxEditSteps;
  final off = limit + 1;
  final v = Int32List(2 * limit + 3);
  for (var d = 0; d <= limit; d++) {
    for (var k = -d; k <= d; k += 2) {
      var x = (k == -d || (k != d && v[off + k - 1] < v[off + k + 1])) ? v[off + k + 1] : v[off + k - 1] + 1;
      var y = x - k;
      while (x < n && y < m && a[head + x] == b[head + y]) {
        x++;
        y++;
      }
      v[off + k] = x;
      if (x >= n && y >= m) return LineDiffCounts((d + m - n) ~/ 2, (d - m + n) ~/ 2);
    }
  }
  return LineDiffCounts(m, n, approximate: true);
}

// ---------------------------------------------------------------------------
// the agent's last sentence

/// The last sentence the agent said before it asked, for the person to read
/// beside the request: "I'll delete the build folder now." Null when the
/// agent said nothing usable.
///
/// Reads backwards from the call [beforeToolCallId] (else from the end of
/// [items]) to the nearest agent message that has a sentence, and stops at a
/// user message: text from an earlier turn is not why the agent asks now.
/// Thoughts are not read (they are not said). The sentence is cleaned of
/// ANSI sequences, controls and direction marks, of code fences and Markdown
/// marks, and cut at [intentCharLimit] characters with an ellipsis.
///
/// Sentences end at `.` `!` `?` `…` followed by a space or the end (so
/// `src/main.py` and `3.5` stay whole, as do `e.g.`, `Dr.` and a list number)
/// and at CJK full stops (`。！？`) with no space needed, so Vietnamese,
/// Chinese and Japanese split where their readers expect.
String? lastAgentSentence(List<TranscriptItem> items, {String? beforeToolCallId}) {
  var end = items.length;
  if (beforeToolCallId != null) {
    for (var i = items.length - 1; i >= 0; i--) {
      final it = items[i];
      if (it is TranscriptTool && it.call.toolCallId == beforeToolCallId) {
        end = i;
        break;
      }
    }
  }
  for (var i = end - 1; i >= 0; i--) {
    final it = items[i];
    if (it is! TranscriptMessage) continue;
    if (it.role == MessageRole.user) return null;
    if (it.role != MessageRole.agent) continue;
    final s = lastSentence(it.text);
    if (s != null) return s;
  }
  return null;
}

/// Characters of a message read from its end; a sentence never needs more.
const _tailChars = 4000;

/// The last sentence of [text] (see [lastAgentSentence]).
String? lastSentence(String text) {
  var t = text;
  if (t.length > _tailChars) {
    var from = t.length - _tailChars;
    final unit = t.codeUnitAt(from);
    if (unit >= 0xDC00 && unit <= 0xDFFF) from++;
    t = t.substring(from);
  }
  t = _dropFences(stripAnsi(t));
  final lines = t.split(_lineBreak);

  var last = lines.length - 1;
  while (last >= 0 && !_hasWord(lines[last])) {
    last--;
  }
  if (last < 0) return null;

  // The final block: the lines up to a blank one or the start of a list item
  // or heading, joined as one paragraph.
  final parts = <String>[];
  for (var i = last; i >= 0 && parts.length < 12; i--) {
    final line = lines[i];
    if (plainLine(line).isEmpty) break;
    final marker = _blockMarker.firstMatch(line);
    parts.insert(0, marker == null ? line : line.substring(marker.end));
    if (marker != null) break;
  }
  final flat = _plain(parts.join(' '));
  if (!_hasWord(flat)) return null;

  final sentence = _lastOf(flat).trim();
  if (!_hasWord(sentence)) return null;
  return ellipsize(sentence, intentCharLimit);
}

final _lineBreak = RegExp(r'\r\n|\r|\n|\u2028|\u2029');
final _blockMarker = RegExp(r'^\s*(?:[-*+\u2022]\s+|\d{1,3}[.)]\s+|#{1,6}\s+|>\s*)');
final _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);
final _link = RegExp(r'\[([^\]]*)\]\([^)]*\)');

bool _hasWord(String s) => _wordChar.hasMatch(s);

/// Closed fenced blocks removed, and an unclosed one (the agent is still
/// writing it, or the tail started inside it) cut off.
String _dropFences(String t) {
  if (!t.contains('```')) return t;
  final closed = t.replaceAll(RegExp(r'```[\s\S]*?```'), '\n');
  final open = closed.indexOf('```');
  return open < 0 ? closed : closed.substring(0, open);
}

/// One line of prose: Markdown emphasis, code ticks and links reduced to
/// their text, hidden characters dropped.
String _plain(String s) {
  var t = s.replaceAllMapped(_link, (m) => m[1] ?? '');
  t = t.replaceAll('**', '').replaceAll('__', '').replaceAll('`', '');
  return plainLine(t);
}

bool _isLatinEnd(int c) => c == 0x2E || c == 0x21 || c == 0x3F || c == 0x2026;

/// Sentence ends that need no space after them: CJK, fullwidth, Arabic
/// question mark, Devanagari danda.
bool _isWideEnd(int c) =>
    c == 0x3002 || c == 0xFF01 || c == 0xFF1F || c == 0xFF0E || c == 0xFF61 || c == 0x061F || c == 0x0964 || c == 0x203C;

bool _isCloser(int c) =>
    c == 0x29 || c == 0x5D || c == 0x22 || c == 0x27 || c == 0x201D || c == 0x2019 || c == 0xBB || c == 0x300D || c == 0x300F || c == 0xFF09;

const _abbreviations = {'e.g', 'i.e', 'vs', 'cf', 'dr', 'mr', 'mrs', 'ms', 'prof', 'no', 'approx', 'fig', 'st'};

/// The last sentence of one line of prose.
String _lastOf(String s) {
  var start = 0;
  String? lastDone;
  final n = s.length;
  var i = 0;
  while (i < n) {
    final c = s.codeUnitAt(i);
    if (_isWideEnd(c)) {
      var k = i + 1;
      while (k < n && (_isWideEnd(s.codeUnitAt(k)) || _isCloser(s.codeUnitAt(k)))) {
        k++;
      }
      final sentence = s.substring(start, k);
      if (_hasWord(sentence)) lastDone = sentence;
      start = k;
      i = k;
    } else if (_isLatinEnd(c)) {
      var j = i;
      while (j + 1 < n && (_isLatinEnd(s.codeUnitAt(j + 1)) || _isWideEnd(s.codeUnitAt(j + 1)))) {
        j++;
      }
      var k = j + 1;
      while (k < n && _isCloser(s.codeUnitAt(k))) {
        k++;
      }
      final atBoundary = k >= n || s.codeUnitAt(k) == 0x20;
      if (atBoundary && !(c == 0x2E && j == i && _notAnEnd(s, start, i))) {
        final sentence = s.substring(start, k);
        if (_hasWord(sentence)) lastDone = sentence;
        start = k;
      }
      i = k;
    } else {
      i++;
    }
  }
  final rest = s.substring(start);
  if (_hasWord(rest)) return rest;
  return lastDone ?? s;
}

/// Whether the `.` at [dot] belongs to an abbreviation or a list number, not
/// to the end of a sentence that began at [start].
bool _notAnEnd(String s, int start, int dot) {
  var w = dot;
  while (w > start && s.codeUnitAt(w - 1) != 0x20) {
    w--;
  }
  final word = s.substring(w, dot).toLowerCase();
  if (_abbreviations.contains(word)) return true;
  // "1." opening the sentence.
  return word.isNotEmpty && w == _skipSpaces(s, start) && word.codeUnits.every((u) => u >= 0x30 && u <= 0x39);
}

int _skipSpaces(String s, int from) {
  var i = from;
  while (i < s.length && s.codeUnitAt(i) == 0x20) {
    i++;
  }
  return i;
}
