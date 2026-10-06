/// Typed, tolerant models for the part of ACP (Agent Client Protocol) v1 the
/// phone needs, plus the v2 draft fields that are cheap to accept.
///
/// Parsing never throws: a missing or mistyped field takes a neutral value,
/// an unknown variant becomes an `Unknown*` model carrying the raw JSON, and
/// `_meta` is kept as [meta]. Models are immutable; the JSON maps they carry
/// are shared with the decoded message and must be treated as read-only.
library;

/// A decoded JSON object.
typedef Json = Map<String, Object?>;

String? _s(Object? v) => v is String ? v : null;

/// A count: never negative, 0 when absent.
int _count(Object? v) => v is num && v > 0 ? v.toInt() : 0;
bool _b(Object? v, [bool otherwise = false]) => v is bool ? v : otherwise;
int? _i(Object? v) => v is num ? v.toInt() : null;
double? _d(Object? v) => v is num ? v.toDouble() : null;
num? _n(Object? v) => v is num ? v : null;
Json? _m(Object? v) => v is Map ? v.cast<String, Object?>() : null;
List<Object?> _l(Object? v) => v is List ? v : const [];

/// Parses each object element of [v] with [parse], dropping what is not an
/// object or does not parse.
List<T> _parseList<T>(Object? v, T? Function(Json json) parse) {
  final out = <T>[];
  for (final e in _l(v)) {
    final m = _m(e);
    if (m == null) continue;
    final parsed = parse(m);
    if (parsed != null) out.add(parsed);
  }
  return out;
}

/// The protocol version this client implements.
const acpProtocolVersion = 1;

// ---------------------------------------------------------------------------
// initialize

class AcpImplementation {
  const AcpImplementation({required this.name, this.title, this.version = '', this.meta});

  factory AcpImplementation.parse(Json j) =>
      AcpImplementation(name: _s(j['name']) ?? '', title: _s(j['title']), version: _s(j['version']) ?? '', meta: _m(j['_meta']));

  final String name;
  final String? title;
  final String version;
  final Json? meta;

  /// What to show: the title when the agent gave one.
  String get label => title == null || title!.isEmpty ? name : title!;

  Json toJson() => {'name': name, 'title': ?title, 'version': version};
}

/// What this client offers the agent. ACP's `fs/*` and `terminal/*` are
/// opt-in; the phone offers neither, so an agent that needs them falls back
/// to its own tools.
class AcpClientCapabilities {
  const AcpClientCapabilities({
    this.readTextFile = false,
    this.writeTextFile = false,
    this.terminal = false,
    this.elicitationForm = true,
    this.booleanConfigOptions = true,
  });

  final bool readTextFile;
  final bool writeTextFile;
  final bool terminal;

  /// Form-mode elicitation (the agent's question tools). URL mode is never
  /// offered: it needs a browser hand-off the app does not have.
  final bool elicitationForm;

  /// `session.configOptions.boolean`: the session bar draws a switch for a
  /// `type: "boolean"` option and sends `session/set_config_option` with a
  /// boolean value. Without it Claude Code and Codex send `fast` as a select.
  final bool booleanConfigOptions;

  Json toJson() => {
    'fs': {'readTextFile': readTextFile, 'writeTextFile': writeTextFile},
    'terminal': terminal,
    if (elicitationForm) 'elicitation': {'form': <String, Object?>{}},
    if (booleanConfigOptions)
      'session': {
        'configOptions': {'boolean': <String, Object?>{}},
      },
  };
}

class AcpAgentCapabilities {
  const AcpAgentCapabilities({
    this.loadSession = false,
    this.image = false,
    this.audio = false,
    this.embeddedContext = false,
    this.mcpHttp = false,
    this.mcpSse = false,
    this.canList = false,
    this.canResume = false,
    this.canClose = false,
    this.canFork = false,
    this.canDelete = false,
    this.raw = const {},
  });

  factory AcpAgentCapabilities.parse(Json? j) {
    if (j == null) return const AcpAgentCapabilities();
    final prompt = _m(j['promptCapabilities']) ?? const {};
    final mcp = _m(j['mcpCapabilities']) ?? const {};
    final session = _m(j['sessionCapabilities']) ?? const {};
    // A capability object is "supported" when present and not null (`{}` counts).
    bool has(String key) => _m(session[key]) != null;
    return AcpAgentCapabilities(
      loadSession: _b(j['loadSession']),
      image: _b(prompt['image']),
      audio: _b(prompt['audio']),
      embeddedContext: _b(prompt['embeddedContext']),
      mcpHttp: _b(mcp['http']),
      mcpSse: _b(mcp['sse']),
      canList: has('list'),
      canResume: has('resume'),
      canClose: has('close'),
      canFork: has('fork'),
      canDelete: has('delete'),
      raw: j,
    );
  }

  final bool loadSession;
  final bool image;
  final bool audio;
  final bool embeddedContext;
  final bool mcpHttp;
  final bool mcpSse;
  final bool canList;
  final bool canResume;
  final bool canClose;
  final bool canFork;
  final bool canDelete;

  /// The capabilities object as received, for what is not modelled.
  final Json raw;
}

class AcpAuthMethod {
  const AcpAuthMethod({required this.id, required this.name, this.description, this.type});

  factory AcpAuthMethod.parse(Json j) =>
      AcpAuthMethod(id: _s(j['id']) ?? '', name: _s(j['name']) ?? '', description: _s(j['description']), type: _s(j['type']));

  final String id;
  final String name;
  final String? description;

  /// `terminal` for methods the client runs as a separate program; null for
  /// the agent-handled kind.
  final String? type;
}

class AcpInitializeResult {
  const AcpInitializeResult({
    required this.protocolVersion,
    this.agentInfo,
    this.capabilities = const AcpAgentCapabilities(),
    this.authMethods = const [],
    this.raw = const {},
  });

  factory AcpInitializeResult.parse(Object? json) {
    final j = _m(json) ?? const {};
    final info = _m(j['agentInfo']);
    return AcpInitializeResult(
      protocolVersion: _i(j['protocolVersion']) ?? 0,
      agentInfo: info == null ? null : AcpImplementation.parse(info),
      capabilities: AcpAgentCapabilities.parse(_m(j['agentCapabilities'])),
      authMethods: _parseList(j['authMethods'], AcpAuthMethod.parse),
      raw: j,
    );
  }

  final int protocolVersion;
  final AcpImplementation? agentInfo;
  final AcpAgentCapabilities capabilities;
  final List<AcpAuthMethod> authMethods;
  final Json raw;
}

// ---------------------------------------------------------------------------
// content

/// One piece of message or tool content.
sealed class ContentBlock {
  const ContentBlock({this.meta});

  /// Reads a block; anything that is not a known block is an [UnknownBlock].
  factory ContentBlock.parse(Object? json) {
    final j = _m(json);
    if (j == null) return const UnknownBlock('', {});
    final meta = _m(j['_meta']);
    final type = _s(j['type']) ?? '';
    switch (type) {
      case 'text':
        return TextBlock(_s(j['text']) ?? '', meta: meta);
      case 'image':
        return ImageBlock(data: _s(j['data']) ?? '', mimeType: _s(j['mimeType']) ?? '', uri: _s(j['uri']), meta: meta);
      case 'audio':
        return AudioBlock(data: _s(j['data']) ?? '', mimeType: _s(j['mimeType']) ?? '', meta: meta);
      case 'resource_link':
        return ResourceLinkBlock(
          uri: _s(j['uri']) ?? '',
          name: _s(j['name']) ?? '',
          title: _s(j['title']),
          description: _s(j['description']),
          mimeType: _s(j['mimeType']),
          size: _i(j['size']),
          meta: meta,
        );
      case 'resource':
        final r = _m(j['resource']);
        if (r == null) return UnknownBlock(type, j);
        return EmbeddedResourceBlock(
          uri: _s(r['uri']) ?? '',
          mimeType: _s(r['mimeType']),
          text: _s(r['text']),
          blob: _s(r['blob']),
          meta: meta,
        );
      default:
        return UnknownBlock(type, j);
    }
  }

  final Json? meta;

  Json toJson();
}

class TextBlock extends ContentBlock {
  const TextBlock(this.text, {super.meta});

  final String text;

  @override
  Json toJson() => {'type': 'text', 'text': text, '_meta': ?meta};
}

class ImageBlock extends ContentBlock {
  const ImageBlock({required this.data, required this.mimeType, this.uri, super.meta});

  /// Base64.
  final String data;
  final String mimeType;
  final String? uri;

  @override
  Json toJson() => {'type': 'image', 'data': data, 'mimeType': mimeType, 'uri': ?uri, '_meta': ?meta};
}

class AudioBlock extends ContentBlock {
  const AudioBlock({required this.data, required this.mimeType, super.meta});

  final String data;
  final String mimeType;

  @override
  Json toJson() => {'type': 'audio', 'data': data, 'mimeType': mimeType, '_meta': ?meta};
}

class ResourceLinkBlock extends ContentBlock {
  const ResourceLinkBlock({
    required this.uri,
    required this.name,
    this.title,
    this.description,
    this.mimeType,
    this.size,
    super.meta,
  });

  final String uri;
  final String name;
  final String? title;
  final String? description;
  final String? mimeType;
  final int? size;

  @override
  Json toJson() => {
    'type': 'resource_link',
    'uri': uri,
    'name': name,
    'title': ?title,
    'description': ?description,
    'mimeType': ?mimeType,
    'size': ?size,
    '_meta': ?meta,
  };
}

class EmbeddedResourceBlock extends ContentBlock {
  const EmbeddedResourceBlock({required this.uri, this.mimeType, this.text, this.blob, super.meta});

  final String uri;
  final String? mimeType;

  /// Set for a text resource; [blob] (base64) for a binary one.
  final String? text;
  final String? blob;

  @override
  Json toJson() => {
    'type': 'resource',
    'resource': {'uri': uri, 'mimeType': ?mimeType, 'text': ?text, 'blob': ?blob},
    '_meta': ?meta,
  };
}

class UnknownBlock extends ContentBlock {
  const UnknownBlock(this.type, this.raw) : super();

  final String type;
  final Json raw;

  @override
  Json toJson() => raw;
}

/// What a tool call produced.
sealed class ToolContent {
  const ToolContent();

  factory ToolContent.parse(Object? json) {
    final j = _m(json);
    if (j == null) return const UnknownToolContent('', {});
    final type = _s(j['type']) ?? '';
    switch (type) {
      case 'content':
        return ToolContentBlock(ContentBlock.parse(j['content']));
      case 'diff':
        return ToolDiff(path: _s(j['path']) ?? '', oldText: _s(j['oldText']), newText: _s(j['newText']) ?? '');
      case 'terminal':
        return ToolTerminal(_s(j['terminalId']) ?? '');
      default:
        return UnknownToolContent(type, j);
    }
  }

  Json toJson();
}

class ToolContentBlock extends ToolContent {
  const ToolContentBlock(this.block);

  final ContentBlock block;

  @override
  Json toJson() => {'type': 'content', 'content': block.toJson()};
}

/// A file change. [oldText] is null for a new file.
class ToolDiff extends ToolContent {
  const ToolDiff({required this.path, this.oldText, required this.newText});

  final String path;
  final String? oldText;
  final String newText;

  @override
  Json toJson() => {'type': 'diff', 'path': path, 'oldText': ?oldText, 'newText': newText};
}

/// A terminal the agent created through `terminal/create`. The phone does
/// not offer terminals, so this only appears from agents that ignore that.
class ToolTerminal extends ToolContent {
  const ToolTerminal(this.terminalId);

  final String terminalId;

  @override
  Json toJson() => {'type': 'terminal', 'terminalId': terminalId};
}

class UnknownToolContent extends ToolContent {
  const UnknownToolContent(this.type, this.raw);

  final String type;
  final Json raw;

  @override
  Json toJson() => raw;
}

List<ToolContent> _toolContents(Object? v) => [for (final e in _l(v)) ToolContent.parse(e)];

// ---------------------------------------------------------------------------
// tool calls

enum ToolKind {
  read,
  edit,
  delete,
  move,
  search,
  execute,
  think,
  fetch,
  switchMode,
  other;

  /// An unknown or missing kind is [other].
  static ToolKind parse(String? wire) => switch (wire) {
    'read' => read,
    'edit' => edit,
    'delete' => delete,
    'move' => move,
    'search' => search,
    'execute' => execute,
    'think' => think,
    'fetch' => fetch,
    'switch_mode' => switchMode,
    _ => other,
  };
}

enum ToolStatus {
  pending,
  inProgress,
  completed,
  failed,
  cancelled;

  /// An unknown or missing status is [pending]: not finished, as far as is
  /// known.
  static ToolStatus parse(String? wire) => switch (wire) {
    'in_progress' => inProgress,
    'completed' => completed,
    'failed' => failed,
    'cancelled' => cancelled,
    _ => pending,
  };

  bool get isFinished => this == completed || this == failed || this == cancelled;
}

class ToolLocation {
  const ToolLocation({required this.path, this.line});

  final String path;
  final int? line;
}

List<ToolLocation> _locations(Object? v) =>
    _parseList(v, (j) => ToolLocation(path: _s(j['path']) ?? '', line: _i(j['line'])));

/// What a tool call printed, collected from the `_meta` of its updates.
///
/// codex-acp and pi-acp announce a command with `content: [{type: terminal}]`
/// and send its output only in `_meta`, as deltas to append:
/// `terminal_output_delta {terminal_id, data}` (codex-acp, plain clients),
/// `terminal_output {terminal_id, data}` (pi-acp, and codex-acp for Zed),
/// `terminal_exit {terminal_id, exit_code, signal}` when it ends, and
/// `mcp_output_delta {data}` for the progress lines of an MCP call (codex-acp).
/// `terminal_input` (the stdin the agent typed, only for clients that ask) is
/// ignored: plain clients get stdin as an output chunk already.
///
/// A call holds one buffer: both adapters use the tool call id as the
/// terminal id, so deltas are never told apart by `terminal_id`. The text is
/// capped at [outputKeep] characters; the start is dropped first and
/// [cutChars] says how much.
class ToolOutput {
  const ToolOutput({this.text = '', this.cutChars = 0, this.progress = '', this.exited = false, this.exitCode, this.signal});

  /// What the command printed, in arrival order, escape sequences untouched.
  final String text;

  /// Characters dropped from the start of [text] to stay under the cap.
  final int cutChars;

  /// The progress lines of an MCP call, one per line.
  final String progress;

  /// `terminal_exit` arrived.
  final bool exited;

  /// The exit code; null while running, or when the agent could not tell.
  final int? exitCode;

  /// The signal that ended the command, when it was one.
  final String? signal;

  /// The command ended and did not succeed: a non-zero code or a signal.
  bool get failed => exited && ((exitCode != null && exitCode != 0) || signal != null);

  /// The most [text] and [progress] keep, each. The cap is applied with some
  /// slack ([outputKeep] / 4) so a long stream does not copy the buffer on
  /// every chunk.
  static const outputKeep = 64 * 1024;

  /// The output of [meta] added to [base]; [base] itself when [meta] names
  /// none of the keys above.
  static ToolOutput? fold(ToolOutput? base, Json meta) {
    var out = base;
    for (final key in const ['terminal_output_delta', 'terminal_output']) {
      final data = _s(_m(meta[key])?['data']);
      if (data != null && data.isNotEmpty) out = (out ?? const ToolOutput())._withText(data);
    }
    final line = _s(_m(meta['mcp_output_delta'])?['data']);
    if (line != null && line.isNotEmpty) out = (out ?? const ToolOutput())._withProgress(line);
    final exit = _m(meta['terminal_exit']);
    if (exit != null) out = (out ?? const ToolOutput())._withExit(_i(exit['exit_code']), _s(exit['signal']));
    return out;
  }

  /// [later] (the output a repeated `tool_call` brought) after [earlier].
  static ToolOutput? merge(ToolOutput? earlier, ToolOutput? later) {
    if (earlier == null) return later;
    if (later == null) return earlier;
    final text = _capped(earlier.text + later.text);
    return ToolOutput(
      text: text.$1,
      cutChars: earlier.cutChars + later.cutChars + text.$2,
      progress: _capped(earlier.progress + later.progress).$1,
      exited: earlier.exited || later.exited,
      exitCode: later.exited ? later.exitCode : earlier.exitCode,
      signal: later.exited ? later.signal : earlier.signal,
    );
  }

  ToolOutput _withText(String data) {
    final capped = _capped(text + data);
    return ToolOutput(
      text: capped.$1,
      cutChars: cutChars + capped.$2,
      progress: progress,
      exited: exited,
      exitCode: exitCode,
      signal: signal,
    );
  }

  ToolOutput _withProgress(String line) {
    final sep = progress.isEmpty || progress.endsWith('\n') ? '' : '\n';
    return ToolOutput(
      text: text,
      cutChars: cutChars,
      progress: _capped('$progress$sep$line\n').$1,
      exited: exited,
      exitCode: exitCode,
      signal: signal,
    );
  }

  /// A second `terminal_exit` replaces the first: the last word wins.
  ToolOutput _withExit(int? code, String? signal) =>
      ToolOutput(text: text, cutChars: cutChars, progress: progress, exited: true, exitCode: code, signal: signal);

  /// [all] cut to the last [outputKeep] characters once it is past the slack;
  /// the cut starts at a line when one is close and never inside a surrogate
  /// pair. The second value is how many characters were dropped.
  static (String, int) _capped(String all) {
    if (all.length <= outputKeep + outputKeep ~/ 4) return (all, 0);
    var cut = all.length - outputKeep;
    final nl = all.indexOf('\n', cut);
    if (nl >= 0 && nl - cut <= 200) {
      cut = nl + 1;
    } else if (cut < all.length && (all.codeUnitAt(cut) & 0xFC00) == 0xDC00) {
      cut++;
    }
    return (all.substring(cut), cut);
  }
}

/// The `_meta` keys [ToolOutput] reads. They are consumed into the call's
/// [ToolCall.output] and left out of [ToolCall.meta], which would otherwise
/// keep a second copy of every chunk.
const _outputMetaKeys = {
  'terminal_output_delta',
  'terminal_output',
  'terminal_input',
  'terminal_exit',
  'mcp_output_delta',
};

/// A tool call as the transcript shows it.
class ToolCall {
  const ToolCall({
    required this.toolCallId,
    this.name,
    this.title = '',
    this.kind = ToolKind.other,
    this.status = ToolStatus.pending,
    this.rawInput,
    this.rawOutput,
    this.content = const [],
    this.locations = const [],
    this.meta,
    this.output,
  });

  /// A full `tool_call`.
  factory ToolCall.parse(Json j) => ToolCallPatch.parse(j).applyTo(null);

  final String toolCallId;

  /// The programmatic tool name (`Bash`); agents that predate the field omit it.
  final String? name;
  final String title;
  final ToolKind kind;
  final ToolStatus status;
  final Object? rawInput;
  final Object? rawOutput;
  final List<ToolContent> content;
  final List<ToolLocation> locations;

  /// The `_meta` of the updates laid over each other, key by key (a key a
  /// later update names replaces the earlier one; `_meta: null` clears all),
  /// without the output keys [ToolOutput] consumes.
  final Json? meta;

  /// What the command printed and how it ended, from `_meta`; null when the
  /// agent sent none (output then lives in [content] or [rawOutput]).
  final ToolOutput? output;

  /// The working directory of a command (`_meta.terminal_info.cwd`).
  String? get cwd => _s(_m(meta?['terminal_info'])?['cwd']);

  ToolCall copyWith({ToolStatus? status, List<ToolContent>? content, ToolOutput? output}) => ToolCall(
    toolCallId: toolCallId,
    name: name,
    title: title,
    kind: kind,
    status: status ?? this.status,
    rawInput: rawInput,
    rawOutput: rawOutput,
    content: content ?? this.content,
    locations: locations,
    meta: meta,
    output: output ?? this.output,
  );

  /// The host cut this call's heavy parts (output, input, diff bodies) to
  /// keep its log small (`_meta.herdr.trimmed`); title, kind, status and
  /// locations are intact.
  bool get detailTrimmed => _m(meta?['herdr'])?['trimmed'] == true;

  /// This call, a `tool_call` that came after [earlier] for the same id:
  /// every field is the new one, but what [earlier] already printed stays.
  ToolCall afterEarlier(ToolCall earlier) => ToolCall(
    toolCallId: toolCallId,
    name: name,
    title: title,
    kind: kind,
    status: status,
    rawInput: rawInput,
    rawOutput: rawOutput,
    content: content,
    locations: locations,
    meta: meta,
    output: ToolOutput.merge(earlier.output, output),
  );
}

/// A `tool_call_update`, or the `toolCall` of a permission request: only the
/// fields that were present. Applying it keeps what is omitted and clears
/// what is `null`.
class ToolCallPatch {
  const ToolCallPatch(this.toolCallId, this.fields);

  /// Reads the update; [json] is kept as the field set.
  factory ToolCallPatch.parse(Json json) => ToolCallPatch(_s(json['toolCallId']) ?? '', json);

  final String toolCallId;

  /// The update as received (every key it named, even with a null value).
  final Json fields;

  bool has(String key) => fields.containsKey(key);

  String? get title => _s(fields['title']);
  ToolKind? get kind => has('kind') ? ToolKind.parse(_s(fields['kind'])) : null;
  Object? get rawInput => fields['rawInput'];

  /// The patch laid over [base] (or over an empty call when the call was
  /// never seen). Output deltas in `_meta` are appended to what [base] has,
  /// so an update for a call whose start was missed still collects them, and
  /// the start that arrives later keeps them ([ToolCall.afterEarlier]).
  ToolCall applyTo(ToolCall? base) {
    final c = base ?? ToolCall(toolCallId: toolCallId);
    final newMeta = has('_meta') ? _m(fields['_meta']) : null;
    var meta = c.meta;
    var output = c.output;
    if (has('_meta')) {
      if (newMeta == null) {
        meta = null;
      } else {
        output = ToolOutput.fold(output, newMeta);
        final kept = {
          for (final e in newMeta.entries)
            if (!_outputMetaKeys.contains(e.key)) e.key: e.value,
        };
        if (kept.isNotEmpty) meta = {...?meta, ...kept};
      }
    }
    return ToolCall(
      toolCallId: c.toolCallId,
      name: has('name') ? _s(fields['name']) : c.name,
      title: has('title') ? (_s(fields['title']) ?? '') : c.title,
      kind: has('kind') ? ToolKind.parse(_s(fields['kind'])) : c.kind,
      status: has('status') ? ToolStatus.parse(_s(fields['status'])) : c.status,
      rawInput: has('rawInput') ? fields['rawInput'] : c.rawInput,
      rawOutput: has('rawOutput') ? fields['rawOutput'] : c.rawOutput,
      content: has('content') ? _toolContents(fields['content']) : c.content,
      locations: has('locations') ? _locations(fields['locations']) : c.locations,
      meta: meta,
      output: output,
    );
  }
}

// ---------------------------------------------------------------------------
// plan, commands, usage

enum PlanStatus {
  pending,
  inProgress,
  completed,
  cancelled;

  static PlanStatus parse(String? wire) => switch (wire) {
    'in_progress' => inProgress,
    'completed' => completed,
    'cancelled' => cancelled,
    _ => pending,
  };
}

enum PlanPriority {
  high,
  medium,
  low;

  static PlanPriority parse(String? wire) => switch (wire) {
    'high' => high,
    'low' => low,
    _ => medium,
  };
}

class PlanEntry {
  const PlanEntry({required this.content, this.priority = PlanPriority.medium, this.status = PlanStatus.pending});

  final String content;
  final PlanPriority priority;
  final PlanStatus status;
}

List<PlanEntry> parsePlanEntries(Object? v) => _parseList(
  v,
  (j) => PlanEntry(
    content: _s(j['content']) ?? '',
    priority: PlanPriority.parse(_s(j['priority'])),
    status: PlanStatus.parse(_s(j['status'])),
  ),
);

/// A slash command from `available_commands_update`.
class AcpCommand {
  const AcpCommand({required this.name, this.description = '', this.inputHint, this.meta});

  /// Without the leading slash; may contain `:` (`skill:review`).
  final String name;
  final String description;

  /// The hint shown while the argument is empty; null when the command takes
  /// no input.
  final String? inputHint;
  final Json? meta;

  static AcpCommand? parse(Json j) {
    final name = _s(j['name']);
    if (name == null || name.isEmpty) return null;
    final input = _m(j['input']);
    return AcpCommand(
      name: name,
      description: _s(j['description']) ?? '',
      inputHint: input == null ? null : (_s(input['hint']) ?? ''),
      meta: _m(j['_meta']),
    );
  }
}

List<AcpCommand> parseCommands(Object? v) => _parseList(v, AcpCommand.parse);

/// A `usage_update`: the context window now, and the cost so far.
class AcpUsage {
  const AcpUsage({required this.used, required this.size, this.costAmount, this.costCurrency, this.meta});

  /// Tokens in the context window now.
  final int used;

  /// The window's size in tokens.
  final int size;
  final double? costAmount;
  final String? costCurrency;
  final Json? meta;

  /// 0..1, or null when the size is unknown.
  double? get fraction => size <= 0 ? null : (used / size).clamp(0.0, 1.0);

  static AcpUsage parse(Json j) {
    final cost = _m(j['cost']);
    return AcpUsage(
      used: _i(j['used']) ?? 0,
      size: _i(j['size']) ?? 0,
      costAmount: cost == null ? null : _d(cost['amount']),
      costCurrency: cost == null ? null : _s(cost['currency']),
      meta: _m(j['_meta']),
    );
  }
}

/// `PromptResponse.usage`: the tokens one turn used. Optional counts are null
/// when the agent does not report that category (omitted and `null` mean the
/// same).
class TurnUsage {
  const TurnUsage({
    required this.totalTokens,
    required this.inputTokens,
    required this.outputTokens,
    this.thoughtTokens,
    this.cachedReadTokens,
    this.cachedWriteTokens,
  });

  final int totalTokens;
  final int inputTokens;
  final int outputTokens;
  final int? thoughtTokens;
  final int? cachedReadTokens;
  final int? cachedWriteTokens;

  /// Null when [j] is not an object.
  static TurnUsage? parse(Json? j) => j == null
      ? null
      : TurnUsage(
          totalTokens: _i(j['totalTokens']) ?? 0,
          inputTokens: _i(j['inputTokens']) ?? 0,
          outputTokens: _i(j['outputTokens']) ?? 0,
          thoughtTokens: _i(j['thoughtTokens']),
          cachedReadTokens: _i(j['cachedReadTokens']),
          cachedWriteTokens: _i(j['cachedWriteTokens']),
        );
}

// ---------------------------------------------------------------------------
// modes and config options

class SessionMode {
  const SessionMode({required this.id, required this.name, this.description});

  final String id;
  final String name;
  final String? description;
}

class ModeState {
  const ModeState({required this.currentModeId, this.availableModes = const []});

  final String currentModeId;
  final List<SessionMode> availableModes;

  ModeState withCurrent(String id) => ModeState(currentModeId: id, availableModes: availableModes);

  static ModeState? parse(Object? v) {
    final j = _m(v);
    if (j == null) return null;
    return ModeState(
      currentModeId: _s(j['currentModeId']) ?? '',
      availableModes: _parseList(j['availableModes'], (m) {
        final id = _s(m['id']);
        return id == null ? null : SessionMode(id: id, name: _s(m['name']) ?? id, description: _s(m['description']));
      }),
    );
  }
}

/// One selectable value of a [SelectConfigOption].
class ConfigChoice {
  const ConfigChoice({required this.value, required this.name, this.description, this.group});

  final String value;
  final String name;
  final String? description;

  /// The header it was listed under, null for a flat list.
  final String? group;
}

/// A session setting the agent exposes: a select (model, mode, thinking
/// level) or a boolean. `category` (`mode`, `model`, `thought_level`,
/// `_custom`) is a UX hint only.
sealed class ConfigOption {
  const ConfigOption({required this.id, required this.name, this.description, this.category, this.meta});

  final String id;
  final String name;
  final String? description;
  final String? category;
  final Json? meta;

  /// The current value: a `String` (select) or `bool`.
  Object? get currentValue;

  /// A copy that holds [value]; one that does not fit the type is ignored.
  ConfigOption withValue(Object? value);

  static ConfigOption? parse(Json j) {
    final id = _s(j['id']);
    if (id == null) return null;
    final name = _s(j['name']) ?? id;
    final description = _s(j['description']);
    final category = _s(j['category']);
    final meta = _m(j['_meta']);
    switch (_s(j['type'])) {
      case 'select':
        return SelectConfigOption(
          id: id,
          name: name,
          description: description,
          category: category,
          meta: meta,
          value: _s(j['currentValue']) ?? '',
          choices: _choices(j['options']),
        );
      case 'boolean':
        return BooleanConfigOption(
          id: id,
          name: name,
          description: description,
          category: category,
          meta: meta,
          value: _b(j['currentValue']),
        );
      default:
        return UnknownConfigOption(id: id, name: name, description: description, category: category, meta: meta, raw: j);
    }
  }

  static List<ConfigChoice> _choices(Object? v) {
    final out = <ConfigChoice>[];
    ConfigChoice? one(Json j, String? group) {
      final value = _s(j['value']);
      if (value == null) return null;
      return ConfigChoice(value: value, name: _s(j['name']) ?? value, description: _s(j['description']), group: group);
    }

    for (final e in _l(v)) {
      final j = _m(e);
      if (j == null) continue;
      if (j.containsKey('group')) {
        final group = _s(j['name']) ?? _s(j['group']);
        for (final inner in _l(j['options'])) {
          final m = _m(inner);
          final choice = m == null ? null : one(m, group);
          if (choice != null) out.add(choice);
        }
      } else {
        final choice = one(j, null);
        if (choice != null) out.add(choice);
      }
    }
    return out;
  }
}

List<ConfigOption> parseConfigOptions(Object? v) => _parseList(v, ConfigOption.parse);

class SelectConfigOption extends ConfigOption {
  const SelectConfigOption({
    required super.id,
    required super.name,
    super.description,
    super.category,
    super.meta,
    required this.value,
    required this.choices,
  });

  final String value;
  final List<ConfigChoice> choices;

  @override
  String get currentValue => value;

  /// The display name of the current value (the value itself when it is not
  /// among the choices).
  String get currentName {
    for (final c in choices) {
      if (c.value == value) return c.name;
    }
    return value;
  }

  @override
  SelectConfigOption withValue(Object? v) => v is! String
      ? this
      : SelectConfigOption(
          id: id,
          name: name,
          description: description,
          category: category,
          meta: meta,
          value: v,
          choices: choices,
        );
}

class BooleanConfigOption extends ConfigOption {
  const BooleanConfigOption({
    required super.id,
    required super.name,
    super.description,
    super.category,
    super.meta,
    required this.value,
  });

  final bool value;

  @override
  bool get currentValue => value;

  @override
  BooleanConfigOption withValue(Object? v) => v is! bool
      ? this
      : BooleanConfigOption(id: id, name: name, description: description, category: category, meta: meta, value: v);
}

class UnknownConfigOption extends ConfigOption {
  const UnknownConfigOption({
    required super.id,
    required super.name,
    super.description,
    super.category,
    super.meta,
    required this.raw,
  });

  final Json raw;

  @override
  Object? get currentValue => raw['currentValue'];

  @override
  UnknownConfigOption withValue(Object? value) => this;
}

// ---------------------------------------------------------------------------
// sessions

/// What `session/new`, `session/load` and `session/resume` answer with.
class AcpSessionSetup {
  const AcpSessionSetup({
    this.sessionId,
    this.modes,
    this.configOptions = const [],
    this.commands = const [],
    this.meta,
    this.droppedTurns = 0,
    this.trimmedTurns = 0,
  });

  factory AcpSessionSetup.parse(Object? json) {
    final j = _m(json) ?? const {};
    final meta = _m(j['_meta']);
    // The keeper says what its log gave up (`docs/AGENT_SESSIONS.md`, "The
    // keeper"); any other agent sends nothing.
    final herdr = _m(meta?['herdr']);
    return AcpSessionSetup(
      sessionId: _s(j['sessionId']),
      modes: ModeState.parse(j['modes']),
      configOptions: parseConfigOptions(j['configOptions']),
      // v2 drafts return the commands in the response.
      commands: parseCommands(j['availableCommands']),
      meta: meta,
      droppedTurns: _count(herdr?['droppedTurns']),
      trimmedTurns: _count(herdr?['trimmedTurns']),
    );
  }

  /// Only `session/new` returns one.
  final String? sessionId;
  final ModeState? modes;
  final List<ConfigOption> configOptions;
  final List<AcpCommand> commands;
  final Json? meta;

  /// Whole turns the host no longer keeps (the keeper's `_meta.herdr`): the
  /// replay starts after them.
  final int droppedTurns;

  /// Turns whose tool detail the host cut to save room.
  final int trimmedTurns;
}

/// One row of `session/list`.
class AcpSessionInfo {
  const AcpSessionInfo({required this.sessionId, required this.cwd, this.title, this.updatedAt, this.meta});

  final String sessionId;
  final String cwd;
  final String? title;
  final DateTime? updatedAt;

  /// Agent extras (omp: `messageCount`, `size`).
  final Json? meta;

  static AcpSessionInfo? parse(Json j) {
    final id = _s(j['sessionId']);
    if (id == null) return null;
    final at = _s(j['updatedAt']);
    return AcpSessionInfo(
      sessionId: id,
      cwd: _s(j['cwd']) ?? '',
      title: _s(j['title']),
      updatedAt: at == null ? null : DateTime.tryParse(at),
      meta: _m(j['_meta']),
    );
  }
}

class AcpSessionPage {
  const AcpSessionPage({required this.sessions, this.nextCursor});

  factory AcpSessionPage.parse(Object? json) {
    final j = _m(json) ?? const {};
    return AcpSessionPage(sessions: _parseList(j['sessions'], AcpSessionInfo.parse), nextCursor: _s(j['nextCursor']));
  }

  final List<AcpSessionInfo> sessions;
  final String? nextCursor;
}

enum StopReason {
  endTurn,
  maxTokens,
  maxTurnRequests,
  refusal,
  cancelled,
  error,
  unknown;

  static StopReason parse(String? wire) => switch (wire) {
    'end_turn' => endTurn,
    'max_tokens' => maxTokens,
    'max_turn_requests' => maxTurnRequests,
    'refusal' => refusal,
    'cancelled' => cancelled,
    'error' => error,
    _ => unknown,
  };
}

class PromptResult {
  const PromptResult(this.stopReason, {this.rawStopReason, this.meta, this.usage});

  factory PromptResult.parse(Object? json) {
    final j = _m(json) ?? const {};
    final raw = _s(j['stopReason']);
    return PromptResult(
      StopReason.parse(raw),
      rawStopReason: raw,
      meta: _m(j['_meta']),
      usage: TurnUsage.parse(_m(j['usage'])),
    );
  }

  final StopReason stopReason;
  final String? rawStopReason;
  final Json? meta;

  /// Token accounting of the whole turn (`PromptResponse.usage`); null when
  /// the agent reports none.
  final TurnUsage? usage;
}

// ---------------------------------------------------------------------------
// permission requests

enum PermissionOptionKind {
  allowOnce,
  allowAlways,
  rejectOnce,
  rejectAlways,

  /// A kind this client does not know; never treated as an allow.
  other;

  static PermissionOptionKind parse(String? wire) => switch (wire) {
    'allow_once' => allowOnce,
    'allow_always' => allowAlways,
    'reject_once' => rejectOnce,
    'reject_always' => rejectAlways,
    _ => other,
  };

  bool get isAllow => this == allowOnce || this == allowAlways;

  /// A grant that outlives this one call ("don't ask again").
  bool get isStanding => this == allowAlways || this == rejectAlways;
}

class PermissionOption {
  const PermissionOption({required this.optionId, required this.name, required this.kind, this.rawKind});

  final String optionId;
  final String name;
  final PermissionOptionKind kind;

  /// The kind string as sent, for kinds this client does not know.
  final String? rawKind;
}

/// `session/request_permission`: the agent asks before running a tool.
class PermissionRequest {
  const PermissionRequest({
    required this.sessionId,
    required this.toolCall,
    required this.options,
    this.title,
    this.description,
    this.command,
    this.cwd,
    this.meta,
    this.raw = const {},
  });

  factory PermissionRequest.parse(Object? json) {
    final j = _m(json) ?? const {};
    final subject = _m(j['subject']);
    // v1 carries the call in `toolCall`; the v2 draft in `subject`, which can
    // also be a bare command.
    final call = _m(j['toolCall']) ?? (subject == null ? null : _m(subject['toolCall'])) ?? const {};
    return PermissionRequest(
      sessionId: _s(j['sessionId']) ?? '',
      toolCall: ToolCallPatch.parse(call),
      options: _parseList(j['options'], (o) {
        final id = _s(o['optionId']);
        if (id == null) return null;
        final kind = _s(o['kind']);
        return PermissionOption(optionId: id, name: _s(o['name']) ?? id, kind: PermissionOptionKind.parse(kind), rawKind: kind);
      }),
      title: _s(j['title']),
      description: _s(j['description']),
      command: subject == null ? null : _s(subject['command']),
      cwd: subject == null ? null : _s(subject['cwd']),
      meta: _m(j['_meta']),
      raw: j,
    );
  }

  final String sessionId;
  final ToolCallPatch toolCall;
  final List<PermissionOption> options;

  /// v2 draft: a title for the prompt itself.
  final String? title;
  final String? description;

  /// v2 draft: the command a `command` subject names.
  final String? command;
  final String? cwd;
  final Json? meta;
  final Json raw;

  /// The first option of [kind], if any.
  PermissionOption? optionOfKind(PermissionOptionKind kind) {
    for (final o in options) {
      if (o.kind == kind) return o;
    }
    return null;
  }

  bool hasOption(String optionId) => options.any((o) => o.optionId == optionId);
}

/// How a permission request ended.
sealed class PermissionOutcome {
  const PermissionOutcome();

  /// The `result` of `session/request_permission`.
  Json toJson();
}

class PermissionSelected extends PermissionOutcome {
  const PermissionSelected(this.optionId);

  final String optionId;

  @override
  Json toJson() => {
    'outcome': {'outcome': 'selected', 'optionId': optionId},
  };
}

/// Nothing was chosen: the turn was cancelled, or the user dismissed it.
class PermissionCancelled extends PermissionOutcome {
  const PermissionCancelled();

  @override
  Json toJson() => {
    'outcome': {'outcome': 'cancelled'},
  };
}

// ---------------------------------------------------------------------------
// elicitation

class EnumChoice {
  const EnumChoice(this.value, this.title);

  final String value;
  final String title;
}

/// A field of a form elicitation: ACP restricts forms to a flat object of
/// primitives, single enums and multi-select enums.
sealed class ElicitationField {
  const ElicitationField({required this.name, this.title, this.description, this.required = false});

  /// The key in the answer.
  final String name;
  final String? title;
  final String? description;
  final bool required;

  /// [title] or, failing that, [name].
  String get label => title == null || title!.isEmpty ? name : title!;
}

class StringField extends ElicitationField {
  const StringField({
    required super.name,
    super.title,
    super.description,
    super.required,
    this.minLength,
    this.maxLength,
    this.pattern,
    this.format,
    this.defaultValue,
  });

  final int? minLength;
  final int? maxLength;
  final String? pattern;

  /// `email`, `uri`, `date`, `date-time`.
  final String? format;
  final String? defaultValue;
}

/// A single choice out of [options] (`enum`, or titled `oneOf`).
class EnumField extends ElicitationField {
  const EnumField({
    required super.name,
    super.title,
    super.description,
    super.required,
    required this.options,
    this.defaultValue,
  });

  final List<EnumChoice> options;
  final String? defaultValue;
}

/// Several choices out of [options] (an `array` of an enum).
class MultiEnumField extends ElicitationField {
  const MultiEnumField({
    required super.name,
    super.title,
    super.description,
    super.required,
    required this.options,
    this.minItems,
    this.maxItems,
    this.defaultValues = const [],
  });

  final List<EnumChoice> options;
  final int? minItems;
  final int? maxItems;
  final List<String> defaultValues;
}

/// `number` or `integer`.
class NumberField extends ElicitationField {
  const NumberField({
    required super.name,
    super.title,
    super.description,
    super.required,
    this.integer = false,
    this.minimum,
    this.maximum,
    this.defaultValue,
  });

  final bool integer;
  final num? minimum;
  final num? maximum;
  final num? defaultValue;
}

class BooleanField extends ElicitationField {
  const BooleanField({required super.name, super.title, super.description, super.required, this.defaultValue});

  final bool? defaultValue;
}

class UnknownField extends ElicitationField {
  const UnknownField({required super.name, super.title, super.description, super.required, required this.type, required this.raw});

  final String type;
  final Json raw;
}

class ElicitationSchema {
  const ElicitationSchema({this.title, this.description, this.fields = const []});

  factory ElicitationSchema.parse(Object? json) {
    final j = _m(json) ?? const {};
    final required = {for (final r in _l(j['required'])) ?_s(r)};
    final fields = <ElicitationField>[];
    _m(j['properties'])?.forEach((name, value) {
      final p = _m(value);
      if (p != null) fields.add(_parseField(name, p, required.contains(name)));
    });
    return ElicitationSchema(title: _s(j['title']), description: _s(j['description']), fields: fields);
  }

  final String? title;
  final String? description;
  final List<ElicitationField> fields;

  static List<EnumChoice> _titled(Object? v) =>
      _parseList(v, (o) => _s(o['const']) == null ? null : EnumChoice(_s(o['const'])!, _s(o['title']) ?? _s(o['const'])!));

  static List<EnumChoice> _plain(Object? v) => [for (final e in _l(v)) if (e is String) EnumChoice(e, e)];

  static ElicitationField _parseField(String name, Json p, bool required) {
    final title = _s(p['title']);
    final description = _s(p['description']);
    final type = _s(p['type']) ?? '';
    switch (type) {
      case 'string':
        if (p['oneOf'] is List || p['enum'] is List) {
          final titled = _titled(p['oneOf']);
          return EnumField(
            name: name,
            title: title,
            description: description,
            required: required,
            options: titled.isNotEmpty ? titled : _plain(p['enum']),
            defaultValue: _s(p['default']),
          );
        }
        return StringField(
          name: name,
          title: title,
          description: description,
          required: required,
          minLength: _i(p['minLength']),
          maxLength: _i(p['maxLength']),
          pattern: _s(p['pattern']),
          format: _s(p['format']),
          defaultValue: _s(p['default']),
        );
      case 'number':
      case 'integer':
        return NumberField(
          name: name,
          title: title,
          description: description,
          required: required,
          integer: type == 'integer',
          minimum: _n(p['minimum']),
          maximum: _n(p['maximum']),
          defaultValue: _n(p['default']),
        );
      case 'boolean':
        return BooleanField(
          name: name,
          title: title,
          description: description,
          required: required,
          defaultValue: p['default'] is bool ? p['default'] as bool : null,
        );
      case 'array':
        final items = _m(p['items']) ?? const {};
        final titled = _titled(items['anyOf']);
        return MultiEnumField(
          name: name,
          title: title,
          description: description,
          required: required,
          options: titled.isNotEmpty ? titled : _plain(items['enum']),
          minItems: _i(p['minItems']),
          maxItems: _i(p['maxItems']),
          defaultValues: [for (final e in _l(p['default'])) ?_s(e)],
        );
      default:
        return UnknownField(name: name, title: title, description: description, required: required, type: type, raw: p);
    }
  }

  /// What the field values in [content] get wrong, by field name. Empty when
  /// the answer is acceptable. ACP says clients SHOULD validate before
  /// answering; the agent validates again.
  Map<String, String> validate(Map<String, Object?> content) {
    final errors = <String, String>{};
    for (final f in fields) {
      final v = content[f.name];
      if (v == null ||
          (v is String && v.isEmpty) ||
          (v is List && v.isEmpty)) {
        if (f.required) errors[f.name] = 'required';
        continue;
      }
      final error = switch (f) {
        StringField() => _checkString(f, v),
        EnumField() => v is String && f.options.any((o) => o.value == v) ? null : 'not one of the options',
        MultiEnumField() => _checkMulti(f, v),
        NumberField() => _checkNumber(f, v),
        BooleanField() => v is bool ? null : 'must be true or false',
        UnknownField() => null,
      };
      if (error != null) errors[f.name] = error;
    }
    return errors;
  }

  static String? _checkString(StringField f, Object v) {
    if (v is! String) return 'must be text';
    if (f.minLength != null && v.length < f.minLength!) return 'at least ${f.minLength} characters';
    if (f.maxLength != null && v.length > f.maxLength!) return 'at most ${f.maxLength} characters';
    final pattern = f.pattern;
    if (pattern != null) {
      try {
        if (!RegExp(pattern).hasMatch(v)) return 'does not match the expected pattern';
      } on FormatException {
        // A pattern this engine cannot read: leave it to the agent.
      }
    }
    return null;
  }

  static String? _checkMulti(MultiEnumField f, Object v) {
    if (v is! List || v.any((e) => e is! String)) return 'must be a list of options';
    if (v.any((e) => !f.options.any((o) => o.value == e))) return 'not one of the options';
    if (f.minItems != null && v.length < f.minItems!) return 'choose at least ${f.minItems}';
    if (f.maxItems != null && v.length > f.maxItems!) return 'choose at most ${f.maxItems}';
    return null;
  }

  static String? _checkNumber(NumberField f, Object v) {
    if (v is! num) return 'must be a number';
    if (f.integer && v != v.truncate()) return 'must be a whole number';
    if (f.minimum != null && v < f.minimum!) return 'at least ${f.minimum}';
    if (f.maximum != null && v > f.maximum!) return 'at most ${f.maximum}';
    return null;
  }
}

/// `elicitation/create`.
class ElicitationRequest {
  const ElicitationRequest({
    required this.mode,
    required this.message,
    this.sessionId,
    this.toolCallId,
    this.schema,
    this.url,
    this.elicitationId,
    this.meta,
    this.raw = const {},
  });

  factory ElicitationRequest.parse(Object? json) {
    final j = _m(json) ?? const {};
    final mode = _s(j['mode']) ?? 'form';
    return ElicitationRequest(
      mode: mode,
      message: _s(j['message']) ?? '',
      sessionId: _s(j['sessionId']),
      toolCallId: _s(j['toolCallId']),
      schema: mode == 'form' ? ElicitationSchema.parse(j['requestedSchema']) : null,
      url: _s(j['url']),
      elicitationId: _s(j['elicitationId']),
      meta: _m(j['_meta']),
      raw: j,
    );
  }

  /// `form`, `url`, or something newer. This client only answers `form`.
  final String mode;
  final String message;
  final String? sessionId;
  final String? toolCallId;
  final ElicitationSchema? schema;
  final String? url;
  final String? elicitationId;
  final Json? meta;
  final Json raw;

  /// How long Codex waits for an answer before it answers for the person
  /// (`_meta.codex.autoResolutionMs`); null when it never does. Counted from
  /// when codex-acp sent the request, which this app only knows as when it
  /// received it.
  Duration? get autoResolution {
    final ms = _n(_m(meta?['codex'])?['autoResolutionMs']);
    return ms == null || !ms.isFinite || ms < 0 ? null : Duration(milliseconds: ms.toInt());
  }
}

/// How the user answered an elicitation.
sealed class ElicitationResponse {
  const ElicitationResponse();

  /// The `result` of `elicitation/create`.
  Json toJson();
}

class ElicitationAccept extends ElicitationResponse {
  const ElicitationAccept(this.content);

  /// Field name to value: a `String`, a number, a `bool` or a `List<String>`.
  final Map<String, Object?> content;

  @override
  Json toJson() => {'action': 'accept', 'content': content};
}

class ElicitationDecline extends ElicitationResponse {
  const ElicitationDecline();

  @override
  Json toJson() => {'action': 'decline'};
}

class ElicitationCancel extends ElicitationResponse {
  const ElicitationCancel();

  @override
  Json toJson() => {'action': 'cancel'};
}

// ---------------------------------------------------------------------------
// session updates

enum MessageRole { user, agent, thought }

/// The v2 draft's `state_update`.
enum AgentRunState { running, idle, requiresAction, unknown }

/// One `session/update`, parsed.
sealed class SessionUpdate {
  const SessionUpdate();

  /// Reads `params.update`; never throws: what is not understood is an
  /// [UnknownUpdate] holding the raw object.
  factory SessionUpdate.parse(Object? json) {
    final j = _m(json);
    if (j == null) return const UnknownUpdate('', {});
    final type = _s(j['sessionUpdate']) ?? '';
    try {
      return _parse(type, j);
    } on Object {
      return UnknownUpdate(type, j);
    }
  }

  static SessionUpdate _parse(String type, Json j) {
    switch (type) {
      case 'user_message_chunk':
        return MessageChunk(MessageRole.user, _s(j['messageId']), ContentBlock.parse(j['content']), meta: _m(j['_meta']));
      case 'agent_message_chunk':
        return MessageChunk(MessageRole.agent, _s(j['messageId']), ContentBlock.parse(j['content']), meta: _m(j['_meta']));
      case 'agent_thought_chunk':
        return MessageChunk(MessageRole.thought, _s(j['messageId']), ContentBlock.parse(j['content']), meta: _m(j['_meta']));
      case 'user_message':
      case 'agent_message':
      case 'agent_thought':
        final id = _s(j['messageId']);
        if (id == null) return UnknownUpdate(type, j);
        final role = switch (type) {
          'user_message' => MessageRole.user,
          'agent_message' => MessageRole.agent,
          _ => MessageRole.thought,
        };
        return MessageUpsert(
          role,
          id,
          hasContent: j.containsKey('content'),
          content: j['content'] is List ? [for (final b in _l(j['content'])) ContentBlock.parse(b)] : null,
          meta: _m(j['_meta']),
        );
      case 'tool_call':
        return ToolCallStart(ToolCall.parse(j));
      case 'tool_call_update':
        return ToolCallPatchUpdate(ToolCallPatch.parse(j));
      case 'tool_call_content_chunk':
        return ToolCallContentChunk(_s(j['toolCallId']) ?? '', ToolContent.parse(j['content']));
      case 'plan':
        return PlanUpdate(parsePlanEntries(j['entries']), meta: _m(j['_meta']));
      case 'plan_update':
        final plan = _m(j['plan']);
        if (plan == null || _s(plan['type']) != 'items') return UnknownUpdate(type, j);
        return PlanUpdate(parsePlanEntries(plan['entries']), meta: _m(j['_meta']));
      case 'available_commands_update':
        return CommandsUpdate(parseCommands(j['availableCommands']));
      case 'current_mode_update':
        return ModeUpdate(_s(j['currentModeId']) ?? '');
      case 'config_option_update':
        return ConfigUpdate(parseConfigOptions(j['configOptions']));
      case 'session_info_update':
        return SessionInfoUpdate(
          hasTitle: j.containsKey('title'),
          title: _s(j['title']),
          hasUpdatedAt: j.containsKey('updatedAt'),
          updatedAt: DateTime.tryParse(_s(j['updatedAt']) ?? ''),
          meta: _m(j['_meta']),
        );
      case 'usage_update':
        return UsageUpdate(AcpUsage.parse(j));
      case 'state_update':
        return StateUpdate(switch (_s(j['state'])) {
          'running' => AgentRunState.running,
          'idle' => AgentRunState.idle,
          'requires_action' => AgentRunState.requiresAction,
          _ => AgentRunState.unknown,
        }, StopReason.parse(_s(j['stopReason'])));
      case 'async_task_spawned':
        final id = _s(j['asyncTaskId']);
        if (id == null || id.isEmpty) return UnknownUpdate(type, j);
        return AsyncTaskSpawned(
          asyncTaskId: id,
          name: _s(j['name']) ?? '',
          taskType: _s(j['taskType']) ?? '',
          description: _s(j['description']),
          showInTranscript: _b(j['showInTranscript'], true),
          canStop: _b(j['canStop']),
          outputFilePath: _s(j['outputFilePath']),
          toolCallId: _s(j['toolCallId']),
        );
      case 'async_task_progress':
        final id = _s(j['asyncTaskId']);
        if (id == null || id.isEmpty) return UnknownUpdate(type, j);
        return AsyncTaskProgress(
          asyncTaskId: id,
          description: _s(j['description']),
          summary: _s(j['summary']),
          lastToolName: _s(j['lastToolName']),
          outputFilePath: _s(j['outputFilePath']),
          toolCallId: _s(j['toolCallId']),
        );
      case 'async_task_state_update':
        final id = _s(j['asyncTaskId']);
        final state = AsyncTaskState.parse(_s(j['state']));
        if (id == null || id.isEmpty || state == null) return UnknownUpdate(type, j);
        return AsyncTaskStateUpdate(
          asyncTaskId: id,
          state: state,
          summary: _s(j['summary']),
          outputFilePath: _s(j['outputFilePath']),
          toolCallId: _s(j['toolCallId']),
        );
      default:
        return UnknownUpdate(type, j);
    }
  }

  /// What Claude Code's `_claude/sdkMessage` extension notification carries
  /// that the phone reads: `params` is `{sessionId, message}` and [message] an
  /// SDK `system` message. `background_tasks_changed` (the live background
  /// tasks, whole) and `task_notification` (one task ended). Null for anything
  /// else; never throws.
  static SessionUpdate? fromClaudeSdkMessage(Object? message) {
    final j = _m(message);
    if (j == null || _s(j['type']) != 'system') return null;
    try {
      switch (_s(j['subtype'])) {
        case 'background_tasks_changed':
          return SdkBackgroundTasks([
            for (final t in _parseList(j['tasks'], (t) {
              final id = _s(t['task_id']);
              if (id == null || id.isEmpty) return null;
              return SdkBackgroundTask(
                taskId: id,
                taskType: _s(t['task_type']) ?? '',
                description: _s(t['description']) ?? '',
                ambient: _b(t['ambient']),
              );
            }))
              t,
          ]);
        case 'task_notification':
          final id = _s(j['task_id']);
          final status = AsyncTaskState.parse(_s(j['status']));
          if (id == null || id.isEmpty || status == null) return null;
          return SdkTaskNotification(
            taskId: id,
            status: status,
            summary: _s(j['summary']),
            toolUseId: _s(j['tool_use_id']),
            ambient: _b(j['ambient']),
          );
      }
    } on Object {
      return null;
    }
    return null;
  }
}

/// A piece of a message. Chunks with the same [messageId] and [role] belong
/// to one message; without an id a chunk continues the last message of its
/// role.
class MessageChunk extends SessionUpdate {
  const MessageChunk(this.role, this.messageId, this.content, {this.meta});

  final MessageRole role;
  final String? messageId;
  final ContentBlock content;

  /// The update's own `_meta` (not the block's): Claude puts `parentToolUseId`
  /// here on everything a subagent says.
  final Json? meta;
}

/// The v2 draft's `user_message` / `agent_message` / `agent_thought`: a whole
/// message keyed by [messageId]. [content] replaces the message's blocks;
/// when the update has no `content` key ([hasContent] false) the blocks stay;
/// `content: null` ([hasContent] true, [content] null) clears them. A replay
/// may open a message with `content: []` and stream chunks into it.
class MessageUpsert extends SessionUpdate {
  const MessageUpsert(this.role, this.messageId, {required this.hasContent, this.content, this.meta});

  final MessageRole role;
  final String messageId;
  final bool hasContent;
  final List<ContentBlock>? content;
  final Json? meta;
}

class ToolCallStart extends SessionUpdate {
  const ToolCallStart(this.call);

  final ToolCall call;
}

class ToolCallPatchUpdate extends SessionUpdate {
  const ToolCallPatchUpdate(this.patch);

  final ToolCallPatch patch;
}

/// The v2 draft's `tool_call_content_chunk`: one more content item for a call.
class ToolCallContentChunk extends SessionUpdate {
  const ToolCallContentChunk(this.toolCallId, this.content);

  final String toolCallId;
  final ToolContent content;
}

/// The plan, whole: every update replaces the list.
class PlanUpdate extends SessionUpdate {
  const PlanUpdate(this.entries, {this.meta});

  final List<PlanEntry> entries;

  /// The update's `_meta`: Claude stamps `claudeCode.parentToolUseId` on the
  /// plan a subagent writes, which is not the session's plan.
  final Json? meta;
}

/// The command list, whole: every update replaces it.
class CommandsUpdate extends SessionUpdate {
  const CommandsUpdate(this.commands);

  final List<AcpCommand> commands;
}

class ModeUpdate extends SessionUpdate {
  const ModeUpdate(this.modeId);

  final String modeId;
}

/// The option list, whole.
class ConfigUpdate extends SessionUpdate {
  const ConfigUpdate(this.options);

  final List<ConfigOption> options;
}

/// Title and timestamp are patches: a key that is absent keeps the old value,
/// a `null` clears it.
class SessionInfoUpdate extends SessionUpdate {
  const SessionInfoUpdate({required this.hasTitle, this.title, required this.hasUpdatedAt, this.updatedAt, this.meta});

  final bool hasTitle;
  final String? title;
  final bool hasUpdatedAt;
  final DateTime? updatedAt;

  /// Agent extras (pi-acp: `piAcp {queueDepth, running}`).
  final Json? meta;
}

class UsageUpdate extends SessionUpdate {
  const UsageUpdate(this.usage);

  final AcpUsage usage;
}

/// The v2 draft's foreground-work state.
class StateUpdate extends SessionUpdate {
  const StateUpdate(this.state, this.stopReason);

  final AgentRunState state;

  /// Only meaningful with [AgentRunState.idle].
  final StopReason stopReason;
}

/// Where an AIR async task stands (`async_task_state_update.state`, and the
/// `status` of Claude Code's `task_notification`).
enum AsyncTaskState {
  running,
  paused,
  completed,
  failed,
  stopped;

  /// Null for a word this client does not know (SDK `killed` counts as stopped).
  static AsyncTaskState? parse(String? s) => switch (s) {
    'running' || 'pending' => running,
    'paused' => paused,
    'completed' => completed,
    'failed' => failed,
    'stopped' || 'killed' || 'cancelled' => stopped,
    _ => null,
  };

  bool get isTerminal => this == completed || this == failed || this == stopped;
}

/// AIR `async_task_spawned` (Claude Code, Codex): background work that is not
/// a subagent started. `claude-agent-acp/docs/air-extensions.md`, "Async tasks".
class AsyncTaskSpawned extends SessionUpdate {
  const AsyncTaskSpawned({
    required this.asyncTaskId,
    required this.name,
    required this.taskType,
    this.description,
    this.showInTranscript = true,
    this.canStop = false,
    this.outputFilePath,
    this.toolCallId,
  });

  final String asyncTaskId;
  final String name;

  /// `shell`, `workflow`, `monitor`, `task`, or whatever the SDK calls it.
  final String taskType;
  final String? description;
  final bool showInTranscript;
  final bool canStop;
  final String? outputFilePath;

  /// The tool call that started it.
  final String? toolCallId;
}

/// AIR `async_task_progress`: only the fields that changed.
class AsyncTaskProgress extends SessionUpdate {
  const AsyncTaskProgress({
    required this.asyncTaskId,
    this.description,
    this.summary,
    this.lastToolName,
    this.outputFilePath,
    this.toolCallId,
  });

  final String asyncTaskId;
  final String? description;
  final String? summary;
  final String? lastToolName;
  final String? outputFilePath;
  final String? toolCallId;
}

/// AIR `async_task_state_update`.
class AsyncTaskStateUpdate extends SessionUpdate {
  const AsyncTaskStateUpdate({
    required this.asyncTaskId,
    required this.state,
    this.summary,
    this.outputFilePath,
    this.toolCallId,
  });

  final String asyncTaskId;
  final AsyncTaskState state;
  final String? summary;
  final String? outputFilePath;
  final String? toolCallId;
}

/// One entry of Claude Code's `background_tasks_changed`.
class SdkBackgroundTask {
  const SdkBackgroundTask({required this.taskId, required this.taskType, required this.description, this.ambient = false});

  final String taskId;

  /// The SDK's word: `local_bash`, `local_workflow`, `local_monitor`,
  /// `local_agent`, `mcp_task`.
  final String taskType;
  final String description;

  /// Not activity (housekeeping, a live-update watcher): hosts leave it out.
  final bool ambient;
}

/// Claude Code's `background_tasks_changed` (an SDK `system` message that
/// `claude-agent-acp` forwards as `_claude/sdkMessage` when the session asked
/// for it with `_meta.claudeCode.emitRawSDKMessages`): every live background
/// task, replacing what was known.
class SdkBackgroundTasks extends SessionUpdate {
  const SdkBackgroundTasks(this.tasks);

  final List<SdkBackgroundTask> tasks;
}

/// Claude Code's `task_notification`: one task ended.
class SdkTaskNotification extends SessionUpdate {
  const SdkTaskNotification({
    required this.taskId,
    required this.status,
    this.summary,
    this.toolUseId,
    this.ambient = false,
  });

  final String taskId;
  final AsyncTaskState status;
  final String? summary;
  final String? toolUseId;
  final bool ambient;
}

/// An update this client does not model (newer protocol, agent extension).
class UnknownUpdate extends SessionUpdate {
  const UnknownUpdate(this.type, this.raw);

  final String type;
  final Json raw;
}
