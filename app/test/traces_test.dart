import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';

import '../benchmark/support/gen_trace_cadence.dart' show cadenceByAgent, render;
import '../benchmark/support/trace_replay.dart';

/// `tool/capture-trace.sh` writes these.
final _root = Directory('test/fixtures/traces');

List<File> _traces() =>
    _root.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.jsonl')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));

String _name(File f) => f.uri.pathSegments.sublist(f.uri.pathSegments.length - 2).join('/');

void main() {
  final traces = _traces();

  test('every agent has the recorded scenarios', () {
    final names = {for (final f in traces) _name(f)};
    for (final agent in ['omp', 'claude', 'codex']) {
      for (final scenario in ['markdown', 'tools', 'plan', 'thinking']) {
        expect(names, contains('$agent/$scenario.jsonl'));
      }
    }
    expect(names, containsAll(['omp/ask.jsonl', 'omp/permission.jsonl', 'claude/subagent.jsonl', 'claude/permission.jsonl']));
  });

  for (final file in traces) {
    group(_name(file), () {
      late final String text;
      late final List<TraceLine> lines;
      setUpAll(() {
        text = file.readAsStringSync();
        lines = parseTrace(text);
      });

      test('is JSON-RPC with monotonic timestamps, under 200 KB', () {
        expect(file.lengthSync(), lessThan(200 * 1024));
        expect(lines.first.msg['method'], 'initialize');
        expect(lines.first.received, isFalse);
        expect(lines.first.tMs, greaterThanOrEqualTo(0));
      });

      test('ends a prompt turn the client started', () {
        final prompt = lines.firstWhere((l) => !l.received && l.method == 'session/prompt');
        final answer = lines.where((l) => l.received && l.msg['id'] == prompt.msg['id'] && l.method == null);
        expect(answer, hasLength(1));
        final result = answer.single.msg['result'];
        expect(result is Map && result['stopReason'] is String, isTrue, reason: 'prompt answered with a stop reason');
        expect(answer.single.tMs, greaterThan(prompt.tMs));
      });

      test('carries no home directory, host or token', () {
        expect(text, isNot(contains('/home/')));
        expect(text, isNot(contains('/media/')));
        expect(text, isNot(matches(RegExp(r'eyJ[A-Za-z0-9_-]{10,}\.|Bearer [A-Za-z0-9._~+/=-]{12,}|sk-[A-Za-z0-9_-]{16,}'))));
      });

      test('its updates parse and fold into a transcript', () {
        var state = const AgentSessionState('s');
        var unknown = 0;
        var chars = 0;
        for (final line in lines) {
          final u = updateOf(line);
          if (u == null) continue;
          final update = SessionUpdate.parse(u);
          if (update is UnknownUpdate) unknown++;
          state = state.apply(update);
          final content = u['content'];
          if (u['sessionUpdate'] == 'agent_message_chunk' && content is Map) chars += (content['text'] as String? ?? '').length;
        }
        expect(unknown, 0, reason: 'a variant the app does not know');
        if (chars > 0) {
          final agentChars = [
            for (final item in state.items)
              if (item is TranscriptMessage && item.role == MessageRole.agent)
                for (final b in item.blocks)
                  if (b is TextBlock) b.text.length,
          ].fold<int>(0, (a, b) => a + b);
          expect(agentChars, chars, reason: 'the reducer keeps every streamed character');
        }
      });
    });
  }

  test('the stream bench replays the cadence the fixtures give', () {
    final fresh = render(cadenceByAgent(_root));
    final checkedIn = File('benchmark/support/trace_cadence.dart').readAsStringSync();
    expect(checkedIn, fresh, reason: 'run: cd app && dart run benchmark/support/gen_trace_cadence.dart');
  });

  test('the cadence reader cuts pauses and counts tenths of a millisecond', () {
    final cadence = cadenceOf([
      [(tMs: 10.0, chars: 5), (tMs: 12.5, chars: 3), (tMs: 2000.0, chars: 4), (tMs: 2000.0, chars: 0)],
      [(tMs: 5.0, chars: 2)],
    ]);
    expect(cadence, [0, 5, 25, 3, 0, 4, 0, 2]);
  });

  test('the reader names the line that breaks the format', () {
    String row(num t, String dir, Object msg) => jsonEncode({'t': t, 'dir': dir, 'msg': msg});
    const ok = {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'};
    expect(
      () => parseTrace('${row(5, 'send', ok)}\n${row(4, 'recv', ok)}\n'),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('line 2'))),
    );
    expect(() => parseTrace('{"t":1,"dir":"up","msg":{}}'), throwsFormatException);
    expect(() => parseTrace(row(1, 'recv', {'id': 1})), throwsFormatException);
    expect(() => parseTrace('not json'), throwsFormatException);
  });
}
