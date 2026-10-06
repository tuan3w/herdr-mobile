// Pure Dart (no Flutter): reads the ACP traces of `app/test/fixtures/traces`
// (written by `tool/capture-trace.sh`) and extracts the cadence the stream
// bench replays. `test/traces_test.dart` validates the fixtures with the same
// reader.
import 'dart:convert';

/// One recorded JSON-RPC line. [tMs] is milliseconds on the monotonic clock
/// since the agent process was spawned; [received] is a line the agent wrote.
class TraceLine {
  const TraceLine(this.tMs, this.received, this.msg);

  final double tMs;
  final bool received;
  final Map<String, Object?> msg;

  String? get method => msg['method'] as String?;
}

/// A text chunk the agent streamed (`agent_message_chunk` or
/// `agent_thought_chunk`): when it arrived and how many characters it held.
typedef TraceChunk = ({double tMs, int chars});

/// Parses a trace file. Throws a [FormatException] naming the line when a
/// line is not `{t, dir, msg}` with `msg` a JSON-RPC 2.0 message, or when the
/// timestamps go backwards.
List<TraceLine> parseTrace(String jsonl) {
  final out = <TraceLine>[];
  var previous = -1.0;
  final lines = const LineSplitter().convert(jsonl);
  for (var i = 0; i < lines.length; i++) {
    final n = i + 1;
    if (lines[i].trim().isEmpty) continue;
    Object? row;
    try {
      row = jsonDecode(lines[i]);
    } on FormatException catch (e) {
      throw FormatException('line $n: not JSON (${e.message})');
    }
    if (row is! Map<String, Object?>) throw FormatException('line $n: not an object');
    final t = row['t'];
    final dir = row['dir'];
    final msg = row['msg'];
    if (t is! num || t < 0) throw FormatException('line $n: "t" must be a non-negative number');
    if (dir != 'recv' && dir != 'send') throw FormatException('line $n: "dir" must be recv or send');
    if (msg is! Map<String, Object?>) throw FormatException('line $n: "msg" must be an object');
    if (msg['jsonrpc'] != '2.0') throw FormatException('line $n: not JSON-RPC 2.0');
    final hasMethod = msg['method'] is String;
    final hasId = msg.containsKey('id');
    final isResponse = !hasMethod && hasId && (msg.containsKey('result') || msg.containsKey('error'));
    if (!hasMethod && !isResponse) throw FormatException('line $n: neither a request, a notification nor a response');
    if (hasMethod && msg['params'] != null && msg['params'] is! Map && msg['params'] is! List) {
      throw FormatException('line $n: params must be an object or an array');
    }
    if (t < previous) throw FormatException('line $n: timestamp $t goes back from $previous');
    previous = t.toDouble();
    out.add(TraceLine(t.toDouble(), dir == 'recv', msg));
  }
  return out;
}

const _textUpdates = {'agent_message_chunk', 'agent_thought_chunk'};

/// The `params.update` object of a `session/update` the agent sent, else null.
Map<String, Object?>? updateOf(TraceLine line) {
  if (!line.received || line.method != 'session/update') return null;
  final params = line.msg['params'];
  final update = params is Map ? params['update'] : null;
  return update is Map<String, Object?> ? update : null;
}

/// Every text chunk of the trace, in order.
List<TraceChunk> textChunks(List<TraceLine> lines) {
  final out = <TraceChunk>[];
  for (final line in lines) {
    final u = updateOf(line);
    if (u == null || !_textUpdates.contains(u['sessionUpdate'])) continue;
    final content = u['content'];
    if (content is Map && content['type'] == 'text' && content['text'] is String) {
      out.add((tMs: line.tMs, chars: (content['text'] as String).length));
    }
  }
  return out;
}

/// The cadence of [streams] as a flat list `[gap, chars, gap, chars, ...]`:
/// the time since the previous chunk in tenths of a millisecond (0 for the
/// chunk that starts a stream or follows a pause of [pauseMs] or more: a
/// replay does not wait for a tool that ran in the recording) and the
/// chunk's size. Chunks with no characters are dropped.
List<int> cadenceOf(Iterable<List<TraceChunk>> streams, {double pauseMs = 1000}) {
  final out = <int>[];
  for (final stream in streams) {
    TraceChunk? previous;
    for (final c in stream) {
      if (c.chars == 0) continue;
      final gap = previous == null || c.tMs - previous.tMs >= pauseMs ? 0.0 : c.tMs - previous.tMs;
      out
        ..add((gap * 10).round())
        ..add(c.chars);
      previous = c;
    }
  }
  return out;
}
