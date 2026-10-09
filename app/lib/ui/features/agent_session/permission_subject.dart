import 'dart:convert';

import '../../../data/acp/acp_models.dart';
import '../../../data/repositories/command_risk.dart';
import '../../../data/repositories/prompt_detector.dart' show longCommand;
import 'visible_text.dart';

/// Most characters of a command, input or path list that are drawn. What is
/// cut is counted and named in the text itself, never dropped silently.
const subjectCharLimit = 20000;

/// Most characters the risk rules read in one piece. A command longer than
/// this is read by its first and its last [_riskCharLimit] characters and,
/// when neither names a reason, is [longCommand]: the request asks for the
/// hold a command nobody can read in full deserves. The rules run on the UI
/// isolate and a few of them are quadratic in the text, so the cap is a few
/// screens, not the size of the longest command.
const _riskCharLimit = 3000;

/// What a permission request asks to run or touch, ready to draw.
class PermissionInfo {
  const PermissionInfo({
    required this.title,
    required this.subject,
    required this.hidden,
    required this.paths,
    required this.risk,
  });

  /// The tool's words for it, hidden characters made visible.
  final String title;

  /// The command, else the tool's input, else the title: hidden characters
  /// made visible, runs of blank lines folded into one marker row, and at most
  /// [subjectCharLimit] characters, ending in a row that names what is cut.
  final String subject;

  /// Characters cut from [subject] (0 when it is whole).
  final int hidden;

  /// The files the call names (its locations and the files of its diffs),
  /// `path` or `path:line`.
  final List<String> paths;

  /// Why the request deserves a second look, or null. Read from everything
  /// the call carries, not from the one field that is drawn.
  final String? risk;
}

/// The tool's title, else the request's own, else a plain name.
String permissionTitle(PermissionRequest request) {
  final t = request.toolCall.title;
  if (t != null && t.trim().isNotEmpty) return t.trim();
  final own = request.title;
  if (own != null && own.trim().isNotEmpty) return own.trim();
  return 'Permission request';
}

/// What the request shows as its subject (see [PermissionInfo.subject]).
String permissionSubject(PermissionRequest request) => describePermission(request).subject;

/// [dropPlan]: the request carries its plan as Markdown of its own (see
/// `permissionEvidence`), so the drawn subject leaves the `plan` field out
/// (the mono copy of a plan would say it twice). What is judged is not
/// touched: the risk rules still read the plan and every other field.
PermissionInfo describePermission(PermissionRequest request, {bool dropPlan = false}) {
  final call = request.toolCall.applyTo(null);
  final input = call.rawInput;
  final title = visibleText(permissionTitle(request));

  // -- what is drawn -------------------------------------------------------
  final commands = _commandTexts(input, request.command);
  final single = _stringCommand(input) ?? _nonBlank(request.command);
  final String raw;
  if (single != null) {
    raw = single;
  } else {
    final Object? drawn;
    if (dropPlan && input is Map) {
      drawn = Map<Object?, Object?>.of(input)..remove('plan');
    } else {
      drawn = input;
    }
    final compact = _compactInput(drawn);
    raw = compact.isEmpty ? permissionTitle(request) : compact;
  }
  final shown = _cap(_foldBlankRuns(visibleText(raw)));

  // -- what is judged ------------------------------------------------------
  final paths = <String>[];
  void addPath(String path, int? line) {
    final p = visibleText(path);
    if (p.trim().isEmpty) return;
    final entry = line == null ? p : '$p:$line';
    if (!paths.contains(entry)) paths.add(entry);
  }

  for (final l in call.locations) {
    addPath(l.path, l.line);
  }
  for (final c in call.content) {
    if (c is ToolDiff) addPath(c.path, null);
  }

  String? risk;
  for (final c in commands) {
    risk ??= _boundedRisk(visibleText(c), commandRisk);
  }
  risk ??= _boundedRisk(title, riskOf);
  final pathCandidates = [
    ..._inputPaths(input),
    for (final l in call.locations) l.path,
    for (final c in call.content)
      if (c is ToolDiff) c.path,
    ...title.split(RegExp(r'\s+')),
  ];
  for (final p in pathCandidates) {
    risk ??= pathRisk(visibleText(p));
  }

  return PermissionInfo(title: title, subject: shown.$1, hidden: shown.$2, paths: paths, risk: risk);
}

String? _nonBlank(String? s) => s == null || s.trim().isEmpty ? null : s;

String? _stringCommand(Object? input) {
  if (input is Map && input['command'] is String) return _nonBlank(input['command'] as String);
  return null;
}

/// Keys whose value is something to run.
const _commandKeys = {
  'command', 'cmd', 'script', 'shell', 'code', 'run', 'exec', 'executable', 'program', 'argv', 'args', 'arguments', //
  'sql', 'query', 'input',
};

/// Keys whose value is a file body: not a command, and often long and quoting
/// other people's commands, so it is not judged as one.
const _bodyKeys = {
  'content', 'contents', 'text', 'new_string', 'old_string', 'new_str', 'old_str', 'newText', 'oldText', //
  'file_text', 'body', 'data', 'patch', 'diff',
};

/// Keys whose value is a path.
const _pathKeys = {
  'path', 'file_path', 'filePath', 'filepath', 'file', 'filename', 'target', 'destination', 'dest', 'to', 'from', //
  'source', 'src', 'directory', 'dir', 'notebook_path', 'paths', 'files',
};

/// A value as one line of words: a string, a number, a flag, or a list of
/// those. Anything else (a nested object) has no flat reading.
String? _flat(Object? v) {
  if (v is String) return v;
  if (v is num || v is bool) return '$v';
  if (v is List) {
    final parts = <String>[];
    for (final e in v) {
      final s = e is List ? null : _flat(e);
      if (s != null) parts.add(s);
    }
    return parts.isEmpty ? null : parts.join(' ');
  }
  return null;
}

/// Every reading of the call as a command: the v2 draft's command, a bare
/// string input, each command-like field, and all the fields (but file
/// bodies) joined, so `{executable: rm, args: [-rf, /]}` reads as `rm -rf /`.
List<String> _commandTexts(Object? input, String? v2) {
  final out = <String>[?_nonBlank(v2)];
  if (input is String) out.add(input);
  if (input is Map) {
    final parts = <String>[];
    input.forEach((k, v) {
      if (k is! String || _bodyKeys.contains(k)) return;
      final s = _flat(v);
      if (s == null) return;
      parts.add(s);
      if (_commandKeys.contains(k)) out.add(s);
    });
    if (parts.length > 1) out.add(parts.join(' '));
  }
  return out;
}

List<String> _inputPaths(Object? input) {
  final out = <String>[];
  if (input is Map) {
    input.forEach((k, v) {
      if (k is! String || !_pathKeys.contains(k)) return;
      if (v is List) {
        for (final e in v) {
          if (e is String) out.add(e);
        }
      } else if (v is String) {
        out.add(v);
      }
    });
  }
  return out;
}

/// [judge] over [s], or over its two ends and [longCommand] when [s] is longer
/// than [_riskCharLimit] (see there).
String? _boundedRisk(String s, String? Function(String) judge) {
  if (s.length <= _riskCharLimit) return judge(s);
  return judge(s.substring(0, _riskCharLimit)) ??
      judge(s.substring(s.length - _riskCharLimit)) ??
      longCommand;
}

/// The input as lines of `key: value`, the shortest first, so a long file body
/// does not push the path above it out of the box.
String _compactInput(Object? input) {
  if (input == null) return '';
  if (input is String) return input;
  if (input is Map) {
    final lines = <String>[];
    input.forEach((k, v) => lines.add('$k: ${_oneValue(v)}'));
    final indexed = lines.indexed.toList()
      ..sort((a, b) {
        final byLength = a.$2.length - b.$2.length;
        return byLength != 0 ? byLength : a.$1 - b.$1;
      });
    return [for (final (_, line) in indexed) line].join('\n');
  }
  return _oneValue(input);
}

String _oneValue(Object? v) {
  if (v is String) return v;
  try {
    return jsonEncode(v);
  } on Object {
    return '$v';
  }
}

/// Runs of three or more blank lines (empty, or only spaces) become one row,
/// `↵ 8 blank lines`: eight newlines must not scroll a command out of sight
/// and leave blank paper in its place.
String _foldBlankRuns(String text) {
  if (!text.contains('\n\n')) return text;
  final lines = text.split('\n');
  final out = <String>[];
  var i = 0;
  while (i < lines.length) {
    var j = i;
    while (j < lines.length && lines[j].trim().isEmpty) {
      j++;
    }
    final run = j - i;
    if (run >= 3) {
      out.add('\u21b5 $run blank lines');
      i = j;
    } else {
      out.add(lines[i]);
      i++;
    }
  }
  return out.join('\n');
}

(String, int) _cap(String s) {
  if (s.length <= subjectCharLimit) return (s, 0);
  var cut = subjectCharLimit;
  // Never end on half of a surrogate pair.
  final unit = s.codeUnitAt(cut - 1);
  if (unit >= 0xD800 && unit <= 0xDBFF) cut--;
  final hidden = s.length - cut;
  return ('${s.substring(0, cut)}\n\u2026 $hidden more characters', hidden);
}
