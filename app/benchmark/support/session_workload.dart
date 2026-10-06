// Pure Dart: builds the `session/update` stream of a long agent session out
// of the recorded traces (`test/fixtures/traces`), for the open-session
// benchmark (`benchmark/session_open_bench.dart`).
//
// Nothing here is random at run time: the same seed gives the same bytes. The
// SHAPES are the traces' (the agents' own `tool_call` / `tool_call_update` /
// chunk objects, re-identified and re-filled); the SIZES are not in the
// traces, which are tiny turns, so they are assumptions this file states:
//
//  * a turn is a user message, an optional thought, 1-5 tool calls (each maybe
//    preceded by a short narration) and an answer; the mix lands near 40%
//    tool calls, which is what the owner described;
//  * 6% of the tool calls carry 20-200 KB of output (a file read, a test log
//    or a diff), the rest 0.2-6 KB;
//  * answers are 1-4 recorded messages put together (the recorded ones are
//    one-liners; real answers run ~1-3 KB);
//  * a plan every few turns and a usage update at the end of each.
//
// Big outputs are tiled from the traces' own text (numbered like omp's and
// Claude's file reads) or, for logs, from a synthetic test-runner pattern, so
// what deflate makes of them is a property of THIS mix, not of every session.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'trace_replay.dart';

typedef Json = Map<String, Object?>;

/// One tool call as an agent sent it: every update with its `toolCallId`, in order.
class ToolTemplate {
  const ToolTemplate({required this.agent, required this.kind, required this.updates});

  final String agent;
  final String kind;
  final List<Json> updates;
}

/// What the generator draws from.
class TracePools {
  TracePools._(this.users, this.answers, this.thoughts, this.tools, this.plans, this.commands, this.corpus);

  final List<String> users;
  final List<({String agent, String text})> answers;
  final List<({String agent, String text})> thoughts;
  final List<ToolTemplate> tools;
  final List<List<Json>> plans;
  final Json? commands;

  /// Every line of recorded agent text: the stuff big outputs are tiled from.
  final List<String> corpus;

  static TracePools load([String root = 'test/fixtures/traces']) {
    final users = <String>[];
    final answers = <({String agent, String text})>[];
    final thoughts = <({String agent, String text})>[];
    final tools = <ToolTemplate>[];
    final plans = <List<Json>>[];
    Json? commands;
    final files = Directory(root).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.jsonl')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final agent = f.path.split('/').reversed.skip(1).first;
      final text = <String, StringBuffer>{};
      final kinds = <String, String>{};
      final groups = <String, List<Json>>{};
      for (final line in parseTrace(f.readAsStringSync())) {
        final msg = line.msg;
        if (!line.received && line.method == 'session/prompt') {
          final prompt = ((msg['params'] as Map)['prompt'] as List).map((b) => (b as Map)['text'] ?? '').join();
          if (prompt.isNotEmpty) users.add(prompt);
        }
        if (!line.received || line.method != 'session/update') continue;
        final u = ((msg['params'] as Map)['update'] as Map).cast<String, Object?>();
        final kind = u['sessionUpdate'] as String;
        switch (kind) {
          case 'agent_message_chunk' || 'agent_thought_chunk':
            final key = '$kind/${u['messageId']}';
            kinds[key] = kind;
            ((u['content'] as Map)['text'] as String?).let((t) => (text[key] ??= StringBuffer()).write(t));
          case 'tool_call' || 'tool_call_update':
            (groups[u['toolCallId'] as String] ??= []).add(u);
          case 'plan':
            plans.add([for (final e in (u['entries'] as List)) (e as Map).cast<String, Object?>()]);
          case 'available_commands_update':
            final listed = (u['availableCommands'] as List).length;
            if (listed > ((commands?['availableCommands'] as List?)?.length ?? 0)) commands = u;
        }
      }
      for (final e in text.entries) {
        final t = e.value.toString();
        if (t.trim().isEmpty) continue;
        (kinds[e.key] == 'agent_thought_chunk' ? thoughts : answers).add((agent: agent, text: t));
      }
      for (final g in groups.values) {
        final kind = g.map((u) => u['kind']).whereType<String>().firstOrNull ?? 'other';
        tools.add(ToolTemplate(agent: agent, kind: kind, updates: g));
      }
    }
    final corpus = <String>[
      for (final m in [...answers, ...thoughts])
        for (final l in m.text.split('\n'))
          if (l.trim().isNotEmpty) l,
    ];
    return TracePools._(users, answers, thoughts, tools, plans, commands, corpus);
  }
}

extension on String? {
  void let(void Function(String) f) {
    final v = this;
    if (v != null) f(v);
  }
}

Json _copy(Json j) => (jsonDecode(jsonEncode(j)) as Map).cast<String, Object?>();

/// The update objects of a session of about [items] transcript items.
///
/// [agent]: `mixed` (turns alternate between the shapes of omp, claude and
/// codex) or one of `omp|claude|codex`. [bigShare] is the share of tool calls
/// that carry 20-200 KB. [tail] appends heavy items after the last turn:
/// `read`, `execute` and `edit` tool calls and `answer` / `thought` messages
/// of about `bytes` (for the row-cost scenarios).
List<Json> buildSession(
  TracePools p,
  int items, {
  int seed = 20261005,
  String agent = 'mixed',
  double bigShare = .02,
  List<({String kind, int bytes})> tail = const [],
}) {
  final rng = math.Random(seed);
  final out = <Json>[];
  final styles = agent == 'mixed' ? const ['omp', 'omp', 'claude', 'codex'] : [agent];
  if (p.commands != null) out.add(_copy(p.commands!));
  out.add({'sessionUpdate': 'session_info_update', 'title': 'Fix the locale handling in the parser', 'updatedAt': '2026-10-05T01:39:08.429Z'});
  var count = 0;
  var serial = 0;
  var used = 12000;

  T pick<T>(List<T> l) => l[rng.nextInt(l.length)];
  double logUniform(double lo, double hi) => lo * math.pow(hi / lo, rng.nextDouble());
  String id(String prefix) => '$prefix-${(serial++).toRadixString(36)}-${rng.nextInt(1 << 30).toRadixString(36)}';

  void user(String text) {
    out.add({'sessionUpdate': 'user_message_chunk', 'messageId': id('u'), 'content': {'type': 'text', 'text': text}});
    count++;
  }

  void chunked(String kind, String text) {
    final mid = id(kind == 'agent_thought_chunk' ? 't' : 'a');
    // The keeper merges chunks of one message; a few are enough for the log
    // to look the same and keep seeding fast.
    final n = text.length < 400 ? 1 : 3;
    final step = (text.length / n).ceil();
    for (var i = 0; i < text.length; i += step) {
      out.add({
        'sessionUpdate': kind,
        'content': {'type': 'text', 'text': text.substring(i, math.min(text.length, i + step))},
        'messageId': mid,
      });
    }
    count++;
  }

  String answerText({bool short = false}) {
    if (short) {
      final shorts = p.answers.where((a) => a.text.length < 400).toList();
      return pick(shorts).text;
    }
    final k = 1 + rng.nextInt(4);
    return [for (var i = 0; i < k; i++) pick(p.answers).text].join('\n\n');
  }

  String thoughtText() {
    final k = 1 + rng.nextInt(3);
    return [for (var i = 0; i < k; i++) pick(p.thoughts).text].join('\n\n');
  }

  String fileText(int bytes) {
    final b = StringBuffer();
    var i = rng.nextInt(p.corpus.length);
    var n = 1;
    while (b.length < bytes) {
      b.writeln('${n++}:${p.corpus[i++ % p.corpus.length]}');
    }
    return b.toString();
  }

  String logText(int bytes) {
    final b = StringBuffer();
    var n = 0;
    var passed = 0;
    while (b.length < bytes) {
      passed += 1 + rng.nextInt(3);
      final s = 4 + n * 7 ~/ 5;
      b.writeln('${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')} +$passed: '
          'test/feature_${n % 41}/case_${n % 13}_test.dart: group ${n % 7} parses sample ${n++} ${n % 5 == 0 ? '[E]' : ''}');
    }
    return b.toString();
  }

  String outputText(int bytes, String kind) =>
      kind == 'execute' && rng.nextDouble() < .7 ? logText(bytes) : fileText(bytes);

  List<Json> instantiate(ToolTemplate t, String kind, String title, int outBytes) {
    final ids = {for (final u in t.updates) u['toolCallId'] as String: id('tc')};
    final out = outBytes == 0 ? null : outputText(outBytes, kind);
    return [
      for (final u in t.updates) _retarget(_copy(u), ids, out, kind, title),
    ];
  }

  void editTool(int bytes, {required bool created}) {
    final path = 'lib/feature_${rng.nextInt(40)}/${pick(const ['parse', 'view', 'model', 'store', 'client'])}.dart';
    final oldText = created ? null : fileText(bytes);
    final lines = (oldText ?? fileText(bytes)).split('\n');
    final newText = [for (final (i, l) in lines.indexed) if (i % 17 != 3) (i % 23 == 5 ? '$l // changed' : l)].join('\n');
    final tid = id('ed');
    out
      ..add({
        'sessionUpdate': 'tool_call',
        'toolCallId': tid,
        'title': 'Edit $path',
        'kind': 'edit',
        'status': 'pending',
        'locations': [
          {'path': '/work/$path'},
        ],
        'rawInput': {'file_path': '/work/$path', 'old_string': ?oldText, 'new_string': newText},
      })
      ..add({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': tid,
        'status': 'completed',
        'content': [
          {'type': 'diff', 'path': '/work/$path', 'oldText': ?oldText, 'newText': newText},
        ],
      });
    count++;
  }

  void tool(String style, {String? forceWant, int? forceBytes}) {
    final big = rng.nextDouble() < bigShare;
    final r = rng.nextDouble();
    if (forceWant == 'edit' || (forceWant == null && r < .15)) {
      final bytes = forceBytes ?? (big ? logUniform(20 * 1024, 200 * 1024).round() : logUniform(300, 3000).round());
      return editTool(bytes, created: forceWant != null || (big && rng.nextDouble() < .3));
    }
    final want = forceWant ?? (r < .45 ? 'read' : r < .75 ? 'execute' : r < .85 ? 'search' : 'other');
    final templateKind = want == 'search' ? 'read' : want;
    final pool = p.tools.where((t) => t.agent == style && t.kind == templateKind).toList();
    final any = pool.isEmpty ? p.tools.where((t) => t.kind == templateKind).toList() : pool;
    final t = pick(any.isEmpty ? p.tools : any);
    final bytes = forceBytes ?? (big ? logUniform(20 * 1024, 200 * 1024).round() : logUniform(200, 6000).round());
    final path = 'lib/feature_${rng.nextInt(40)}/parse.dart';
    final title = switch (want) {
      'read' => 'Read $path',
      'search' => 'Search "locale" in lib/',
      'execute' => pick(const ['flutter test', 'git diff --stat', 'dart analyze', 'ls -la lib']),
      _ => '',
    };
    // A template whose output is not a recognisable text (a plan op, a
    // question) keeps its own tiny output.
    final hasOutput = _outputOf(t.updates) != null && t.kind != 'think';
    out.addAll(instantiate(t, want == 'search' ? 'search' : t.kind, title, hasOutput ? bytes : 0));
    count++;
  }

  var turn = 0;
  while (count < items) {
    final style = styles[turn % styles.length];
    turn++;
    var prompt = pick(p.users);
    if (rng.nextDouble() < .1) prompt = '$prompt\n\n${logText(logUniform(800, 3000).round())}';
    user(prompt);
    if (count >= items) break;
    if (turn % 5 == 2 && p.plans.isNotEmpty) {
      out.add({'sessionUpdate': 'plan', 'entries': pick(p.plans)});
    }
    if (rng.nextDouble() < .55) {
      chunked('agent_thought_chunk', thoughtText());
      if (count >= items) break;
    }
    final tools = pick(const [1, 1, 1, 1, 2, 2, 2, 3, 3, 4, 5]);
    for (var i = 0; i < tools && count < items; i++) {
      if (rng.nextDouble() < .25 && count < items) chunked('agent_message_chunk', answerText(short: true));
      if (count < items) tool(style);
    }
    if (count < items) chunked('agent_message_chunk', answerText());
    used += 3000 + rng.nextInt(9000);
    out.add({'sessionUpdate': 'usage_update', 'used': used, 'size': 1000000, 'cost': {'amount': used / 1.2e6, 'currency': 'USD'}});
  }
  for (final h in tail) {
    switch (h.kind) {
      case 'read' || 'execute' || 'edit':
        tool(styles.first, forceWant: h.kind, forceBytes: h.bytes);
      case 'answer' || 'thought':
        final b = StringBuffer();
        while (b.length < h.bytes) {
          b.writeln(h.kind == 'answer' ? answerText() : thoughtText());
          b.writeln();
        }
        chunked(h.kind == 'answer' ? 'agent_message_chunk' : 'agent_thought_chunk', b.toString());
      default:
        throw ArgumentError('unknown heavy item ${h.kind}');
    }
  }
  return out;
}

/// The text a tool call's final update holds as its output, if it has one.
String? _outputOf(List<Json> updates) {
  for (final u in updates.reversed) {
    final raw = u['rawOutput'];
    if (raw is String && raw.isNotEmpty) return raw;
    if (raw is Map) {
      final c = raw['content'];
      if (c is List && c.isNotEmpty && (c.first as Map)['text'] is String) return (c.first as Map)['text'] as String;
    }
    final meta = u['_meta'];
    if (meta is Map && meta['terminal_output_delta'] is Map) return (meta['terminal_output_delta'] as Map)['data'] as String?;
  }
  return null;
}

/// Gives [u] new ids, a new title and a new output text, in every place the
/// agents repeat them (omp: `rawOutput` and `content`; Claude: `rawOutput`,
/// the fenced `content` and `_meta.claudeCode.toolResponse`; Codex: the
/// terminal delta).
Json _retarget(Json u, Map<String, String> ids, String? output, String kind, String title) {
  Object? walk(Object? v, List<String> path) {
    switch (v) {
      case final Map m:
        return {for (final e in m.entries) e.key: walk(e.value, [...path, '${e.key}'])};
      case final List l:
        return [for (final (i, e) in l.indexed) walk(e, [...path, '$i'])];
      case final String s:
        var r = s;
        for (final e in ids.entries) {
          if (r.contains(e.key)) r = r.replaceAll(e.key, e.value);
        }
        if (output == null) return r;
        final p = path.join('/');
        final isOutput = p == 'rawOutput' ||
            p == 'rawOutput/content/0/text' ||
            p.endsWith('toolResponse/stdout') ||
            p.endsWith('toolResponse/file/content') ||
            p.endsWith('terminal_output_delta/data') ||
            p.endsWith('displayContent/text') ||
            (RegExp(r'^content/[1-9]\d*/content/text$').hasMatch(p));
        if (isOutput && s.length > 3) return r.startsWith('```') ? '```\n$output```' : output;
        if (p == 'content/0/content/text' && s.startsWith('```')) return '```\n$output```';
        return r;
      default:
        return v;
    }
  }

  final r = (walk(u, const []) as Map).cast<String, Object?>();
  if (title.isNotEmpty && r.containsKey('title')) r['title'] = title;
  if (kind == 'search' && r.containsKey('kind')) r['kind'] = 'search';
  return r;
}
