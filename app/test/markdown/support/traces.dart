/// Real agent text from `app/test/fixtures/traces/**/*.jsonl` (captured by
/// `tool/capture-trace.sh`): every `agent_message_chunk` / `agent_thought_chunk`
/// run, in the chunking the agent really used.
///
/// Pure Dart (dart:io, dart:convert); the bench uses it too.
library;

import 'dart:convert';
import 'dart:io';

typedef TraceMessage = ({String name, List<String> chunks});

/// One message per run of consecutive chunks of the same update type and id.
List<TraceMessage> loadTraceMessages(String dir) {
  final root = Directory(dir);
  if (!root.existsSync()) return const [];
  final files = root
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.jsonl'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final out = <TraceMessage>[];
  for (final f in files) {
    final segments = f.uri.pathSegments;
    final label = '${segments[segments.length - 2]}/${segments.last}';
    String? key;
    var chunks = <String>[];
    var n = 0;
    void flush() {
      if (chunks.length > 1 && chunks.join().trim().isNotEmpty) {
        out.add((name: '$label#${n++}', chunks: chunks));
      }
      chunks = <String>[];
    }

    for (final line in const LineSplitter().convert(f.readAsStringSync())) {
      Map<String, dynamic> j;
      try {
        j = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final msg = j['msg'];
      if (j['dir'] != 'recv' || msg is! Map || msg['method'] != 'session/update') {
        continue;
      }
      final update = (msg['params'] as Map?)?['update'];
      if (update is! Map) continue;
      final kind = update['sessionUpdate'];
      if (kind != 'agent_message_chunk' && kind != 'agent_thought_chunk') {
        if (kind != 'usage_update') flush();
        key = null;
        continue;
      }
      final text = (update['content'] as Map?)?['text'];
      if (text is! String) continue;
      final k = '$kind/${update['messageId']}';
      if (k != key) flush();
      key = k;
      chunks.add(text);
    }
    flush();
  }
  return out;
}
