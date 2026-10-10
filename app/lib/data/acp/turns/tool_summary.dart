import '../acp_models.dart';
import '../session_state.dart';
import 'changes.dart';
import 'plain_text.dart';

/// One line about a tool call, as parts a UI lays out (the kind's icon, a
/// state shape for a call that did not succeed and the text styles are the
/// UI's). Plain strings, computed only from what the agent sent: never raw
/// JSON, never written by a model.
///
/// | kind | [text] | other parts |
/// | --- | --- | --- |
/// | read, delete | file name | [hint]: its directory |
/// | edit | file name | [hint], [added], [removed], [fileCount] |
/// | execute | the command, first line | [extraLines]; when it failed: [failure], [exitCode], [signal] |
/// | search | the pattern | [hits] when the output says |
/// | fetch | host | |
/// | think, move, switch mode, other | title | |
class ToolSummary {
  const ToolSummary({
    required this.kind,
    required this.text,
    this.hint,
    this.added,
    this.removed,
    this.fileCount = 1,
    this.hits,
    this.extraLines = 0,
    this.failure,
    this.exitCode,
    this.signal,
  });

  final ToolKind kind;

  /// The main words: see the table. Never empty.
  final String text;

  /// The directory of a file, shortened (`lib/locale`); null for a bare name.
  final String? hint;

  /// Lines added and removed by an edit; null when the call carries no diff
  /// (yet), and both null for a diff that changed no line.
  final int? added;
  final int? removed;

  /// How many files an edit touches (the text names the first).
  final int fileCount;

  /// Matches a search found, when its output says so.
  final int? hits;

  /// Lines of a command beyond the first (it is a script).
  final int extraLines;

  /// The last meaningful line of a failed command's output.
  final String? failure;

  /// The exit code of a failed command, when the agent said one.
  final int? exitCode;

  /// The signal that stopped a failed command, when it was one.
  final String? signal;

  /// The summary as one plain line: parts joined with ` · `. For labels for
  /// accessibility and for tests; a UI lays the parts out itself.
  String get plain {
    final b = <String>[
      if (hint != null && (kind == ToolKind.read || kind == ToolKind.delete)) '$text ($hint)' else text,
      if (kind == ToolKind.edit && fileCount > 1) '+${fileCount - 1} more',
      if (kind == ToolKind.edit && (added ?? 0) + (removed ?? 0) > 0) _counts(added ?? 0, removed ?? 0),
      if (hits != null) hits == 1 ? '1 match' : '$hits matches',
      if (signal != null) 'signal $signal' else if (exitCode != null) 'exit $exitCode',
      ?failure,
    ];
    return b.join(' · ');
  }

  /// `+3 −1`; a side that is zero is left out.
  static String _counts(int added, int removed) =>
      [if (added > 0) '+$added', if (removed > 0) '\u2212$removed'].join(' ');

  @override
  String toString() => 'ToolSummary(${kind.name}: $plain)';
}

final _summaries = Expando<ToolSummary>('ToolSummary');

/// The summary of [call]. Memoized per call object (a call is immutable; an
/// update makes a new one).
ToolSummary toolSummary(ToolCall call) => _summaries[call] ??= _summarize(call);

/// Whether the call did not succeed on its own terms: the agent said
/// `failed`, or the command ended with a non-zero code or a signal.
bool toolFailed(ToolCall call) => call.status == ToolStatus.failed || (call.output?.failed ?? false);

ToolSummary _summarize(ToolCall call) {
  switch (call.kind) {
    case ToolKind.read || ToolKind.delete:
      final path = pathOfCall(call);
      if (path == null) return _titled(call);
      return ToolSummary(kind: call.kind, text: basenameOf(path), hint: dirHintOf(path));
    case ToolKind.edit:
      return _edit(call);
    case ToolKind.execute:
      return _execute(call);
    case ToolKind.search:
      return _search(call);
    case ToolKind.fetch:
      final host = _host(call.rawInput);
      return host == null ? _titled(call) : ToolSummary(kind: call.kind, text: host);
    case ToolKind.think || ToolKind.move || ToolKind.switchMode || ToolKind.other:
      return _titled(call);
  }
}

ToolSummary _edit(ToolCall call) {
  final files = changedFilesOf([call]);
  if (files.isNotEmpty) {
    final first = files.first;
    var added = 0, removed = 0;
    for (final f in files) {
      added += f.added;
      removed += f.removed;
    }
    final changed = added + removed > 0;
    return ToolSummary(
      kind: call.kind,
      text: basenameOf(first.path),
      hint: dirHintOf(first.path),
      added: changed ? added : null,
      removed: changed ? removed : null,
      fileCount: files.length,
    );
  }
  final path = pathOfCall(call);
  if (path == null) return _titled(call);
  return ToolSummary(kind: call.kind, text: basenameOf(path), hint: dirHintOf(path));
}

// `/usr/bin/zsh -lc 'cat notes.txt'`: what codex runs is a shell wrapped
// around the command; the command is what the person wants to see.
final _shellWrap = RegExp(r'''^(?:\S*/)?(?:ba|z|da|k|fi)?sh\s+-[a-z]*c\s+(['"])([\s\S]*)\1$''');

final _exitLine = RegExp(r'^\s*exit code:?\s+(-?\d+)', caseSensitive: false);

ToolSummary _execute(ToolCall call) {
  var command = _commandOf(call) ?? _titleText(call);
  final wrapped = _shellWrap.firstMatch(command.trim());
  if (wrapped != null) command = wrapped.group(2)!;
  final lines = command.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  final first = lines.isEmpty ? _titleText(call) : lines.first;

  String? failure;
  int? exitCode;
  String? signal;
  if (toolFailed(call)) {
    final out = call.output;
    final text = outputTextOf(call);
    failure = text == null ? null : lastMeaningfulLine(stripTerminalEscapes(text));
    exitCode = out?.exitCode;
    final sig = out?.signal;
    if (sig != null && sig.isNotEmpty) signal = sig;
    if (exitCode == null && signal == null && text != null) {
      final m = _exitLine.firstMatch(stripTerminalEscapes(text));
      if (m != null) exitCode = int.tryParse(m.group(1)!);
    }
    // "Exit code 1" as the whole output: it is the code, not a message.
    if (failure != null && _exitLine.hasMatch(failure) && failure.split(RegExp(r'\s+')).length <= 3) failure = null;
  }
  return ToolSummary(
    kind: call.kind,
    text: clip(first, _maxText),
    extraLines: lines.length > 1 ? lines.length - 1 : 0,
    failure: failure == null ? null : clip(failure, 200),
    exitCode: exitCode,
    signal: signal,
  );
}

/// The command a call runs: `rawInput.command` (a string, or an argv list),
/// or `rawInput` when it is a bare string; null when the input has none. Raw,
/// as the agent sent it: a `\r` or an ESC in it is part of what the shell
/// reads, so it is not stripped here (the UI shows control characters, see
/// `visibleText`); `stripTerminalEscapes` is for output, which a terminal
/// would have drawn.
String? _commandOf(ToolCall call) {
  final input = call.rawInput;
  Object? c = input is Map ? (input['command'] ?? input['cmd']) : input;
  if (c is List) c = c.map((e) => '$e').join(' ');
  if (c is String && c.trim().isNotEmpty) return c;
  return null;
}

/// The command of an execute call as the transcript says it (unwrapped,
/// whole). Null when the call names none.
String? commandOf(ToolCall call) {
  final c = _commandOf(call);
  if (c == null) return null;
  final wrapped = _shellWrap.firstMatch(c.trim());
  return wrapped == null ? c : wrapped.group(2)!;
}

/// What a command printed, as text: the `_meta` terminal output (codex, pi),
/// else `rawOutput` (a string, or the text parts of a `content` list: Claude,
/// omp), else the text blocks of the call's content. Null when there is none.
/// Escape sequences are untouched.
String? outputTextOf(ToolCall call) {
  final printed = call.output?.text;
  if (printed != null && printed.isNotEmpty) return printed;
  final raw = rawOutputText(call.rawOutput);
  if (raw != null && raw.trim().isNotEmpty) return raw;
  final b = StringBuffer();
  for (final c in call.content) {
    if (c is ToolContentBlock && c.block is TextBlock) {
      if (b.isNotEmpty) b.write('\n');
      b.write((c.block as TextBlock).text);
    }
  }
  return b.isEmpty ? null : b.toString();
}

/// The text of a tool's `rawOutput` when it has a shape that carries text: a
/// string, a list of content parts (omp's `{content: [{type: text, text}],
/// details}` envelope, Claude's parts), or a map with `content`, `output` or
/// `stdout`. An empty string when the shape is known and holds no text yet
/// (an omp `wait` still running); null for a shape that carries no text,
/// which a row may show as data.
String? rawOutputText(Object? raw) {
  if (raw is String) return raw;
  if (raw is Map) return rawOutputText(raw['content']) ?? rawOutputText(raw['output']) ?? rawOutputText(raw['stdout']);
  if (raw is List) {
    final parts = <String>[];
    for (final e in raw) {
      if (e is String) {
        parts.add(e);
      } else if (e is Map && e['text'] is String) {
        parts.add(e['text'] as String);
      }
    }
    return parts.join('\n');
  }
  return null;
}

const _patternKeys = ['pattern', 'query', 'regex', 'search', 'q', 'glob', 'text'];

ToolSummary _search(ToolCall call) {
  final input = call.rawInput;
  String? pattern;
  if (input is Map) {
    for (final key in _patternKeys) {
      final v = input[key];
      if (v is String && v.trim().isNotEmpty) {
        pattern = v;
        break;
      }
    }
  } else if (input is String && input.trim().isNotEmpty) {
    pattern = input;
  }
  if (pattern == null) {
    final t = _titled(call);
    return ToolSummary(kind: call.kind, text: t.text, hits: _hits(call));
  }
  return ToolSummary(kind: call.kind, text: clip(firstLine(stripTerminalEscapes(pattern)) ?? pattern, _maxText), hits: _hits(call));
}

const _countKeys = ['totalMatches', 'total_matches', 'matchCount', 'numMatches', 'numFiles', 'count', 'total'];
const _listKeys = ['matches', 'results', 'files', 'items'];
final _foundCount = RegExp(r'\b(?:found|matched)\s+(\d+)\s+(?:matches|match|files?|results?|lines?|occurrences?)\b', caseSensitive: false);
final _noMatches = RegExp(r'^\s*no (?:matches|files|results)(?: found)?\b', caseSensitive: false);

/// The number of matches a search reports in its output: a count field, a
/// list, or "Found N files". Null when the output says none (a number is
/// never guessed from the size of the text).
int? _hits(ToolCall call) {
  final raw = call.rawOutput;
  if (raw is Map) {
    for (final key in _countKeys) {
      final v = raw[key];
      if (v is int) return v;
    }
    for (final key in _listKeys) {
      final v = raw[key];
      if (v is List) return v.length;
    }
    final details = raw['details'];
    if (details is Map) {
      for (final key in _countKeys) {
        final v = details[key];
        if (v is int) return v;
      }
      for (final key in _listKeys) {
        final v = details[key];
        if (v is List) return v.length;
      }
    }
  } else if (raw is List && raw.every((e) => e is Map && e['type'] != 'text')) {
    return raw.length;
  }
  final text = outputTextOf(call);
  if (text == null) return null;
  final found = _foundCount.firstMatch(text);
  if (found != null) return int.tryParse(found.group(1)!);
  if (_noMatches.hasMatch(text)) return 0;
  return null;
}

/// The host of the first URL in [input] (`url`, `uri`, `href`, `link`, or a
/// `urls` list, or a bare string); null when there is none.
String? _host(Object? input) {
  String? url;
  if (input is String) {
    url = input;
  } else if (input is Map) {
    for (final key in const ['url', 'uri', 'href', 'link']) {
      final v = input[key];
      if (v is String && v.trim().isNotEmpty) {
        url = v;
        break;
      }
    }
    if (url == null && input['urls'] is List) {
      for (final v in input['urls'] as List) {
        if (v is String && v.trim().isNotEmpty) {
          url = v;
          break;
        }
      }
    }
  }
  if (url == null) return null;
  final trimmed = url.trim();
  var uri = Uri.tryParse(trimmed);
  if (uri != null && !uri.hasScheme) uri = Uri.tryParse('https://$trimmed');
  final host = uri?.host ?? '';
  return host.isEmpty ? null : host;
}

const _maxText = 240;

ToolSummary _titled(ToolCall call) => ToolSummary(kind: call.kind, text: _titleText(call));

/// The title of a call as a line of plain text: not JSON, not empty; the
/// tool's name, else the kind's word, when the title says nothing.
String _titleText(ToolCall call) {
  var title = firstLine(stripTerminalEscapes(call.title)) ?? '';
  if (title.startsWith(r'$ ')) title = title.substring(2).trim();
  if (title.isEmpty || _looksLikeJson(title)) {
    final name = call.name?.trim() ?? '';
    return name.isNotEmpty && !_looksLikeJson(name) ? clip(name, _maxText) : kindWord(call.kind);
  }
  return clip(title, _maxText);
}

bool _looksLikeJson(String s) {
  final c = s.isEmpty ? '' : s[0];
  return (c == '{' && s.endsWith('}')) || (c == '[' && s.endsWith(']'));
}

/// A word for a kind of call, for a call that has nothing better to say.
String kindWord(ToolKind kind) => switch (kind) {
  ToolKind.read => 'Read',
  ToolKind.edit => 'Edit',
  ToolKind.delete => 'Delete',
  ToolKind.move => 'Move',
  ToolKind.search => 'Search',
  ToolKind.execute => 'Run',
  ToolKind.think => 'Think',
  ToolKind.fetch => 'Fetch',
  ToolKind.switchMode => 'Switch mode',
  ToolKind.other => 'Tool call',
};

// -- grouping ---------------------------------------------------------------

/// A run of tool calls shown as one row, or one call shown as itself.
///
/// Adjacent calls that were read or search and **completed** collapse into one
/// group (`Read 3 files · searched 2×`). A call that is pending, running,
/// failed, cancelled or waiting for the person never joins a group, and
/// never sits inside one: it ends the run before it and starts nothing.
class ToolGroup {
  const ToolGroup(this.tools, {this.reads = 0, this.searches = 0});

  /// The calls, in order; one when this is no group.
  final List<TranscriptTool> tools;

  /// For a group: how many different files were read (a read whose file is
  /// unknown counts as its own) and how many searches ran.
  final int reads;
  final int searches;

  /// Several calls shown as one row.
  bool get isGroup => tools.length > 1;

  /// A list key: the key of the first call.
  String get key => tools.first.key;

  /// `Read 3 files · searched 2×` for a group, null for a single call.
  String? get label => isGroup ? groupLabel(reads: reads, searches: searches) : null;
}

/// `Read 3 files · searched 2×`; the part that is zero is left out. The words
/// of the first part start with a capital.
String groupLabel({required int reads, required int searches}) {
  final read = reads == 0 ? null : 'read $reads ${reads == 1 ? 'file' : 'files'}';
  final search = searches == 0 ? null : (searches == 1 ? 'searched once' : 'searched $searches\u00d7');
  final text = [?read, ?search].join(' \u00b7 ');
  return text.isEmpty ? '' : '${text[0].toUpperCase()}${text.substring(1)}';
}

bool _groupable(TranscriptTool t) =>
    t.call.status == ToolStatus.completed && (t.call.kind == ToolKind.read || t.call.kind == ToolKind.search);

/// [tools] in the same order as groups: every maximal run of two or more
/// groupable calls is one [ToolGroup]; every other call is a group of one.
List<ToolGroup> groupTools(List<TranscriptTool> tools) {
  final out = <ToolGroup>[];
  var i = 0;
  while (i < tools.length) {
    if (!_groupable(tools[i])) {
      out.add(ToolGroup([tools[i]]));
      i++;
      continue;
    }
    var j = i + 1;
    while (j < tools.length && _groupable(tools[j])) {
      j++;
    }
    final run = tools.sublist(i, j);
    if (run.length == 1) {
      out.add(ToolGroup(run));
    } else {
      final files = <String>{};
      var unknown = 0, searches = 0;
      for (final t in run) {
        if (t.call.kind == ToolKind.search) {
          searches++;
        } else {
          final path = pathOfCall(t.call);
          if (path == null) {
            unknown++;
          } else {
            files.add(path);
          }
        }
      }
      out.add(ToolGroup(List.unmodifiable(run), reads: files.length + unknown, searches: searches));
    }
    i = j;
  }
  return out;
}
