import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/background/background_work.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/observed/codex_log_mapper.dart';

// What these tests rely on, as observed on a real Codex 0.153.4 (see
// test/fixtures/codex_logs/ and the capture notes in the change that added
// them):
//  * While Codex waits for an approval, the `custom_tool_call` line of the
//    command is already on disk and is the last line but one (a
//    `token_usage_record` follows). No `CommandExecution` exists yet.
//  * `CommandExecution` and `FileChange` items carry no call id and can land
//    before the output of their call, after a "Script running" output, inside
//    a later call, or after `task_complete`.
//  * A declined approval interrupts the whole turn (`turn_aborted`).
//  * The legacy dialect (no `history_mode`) and `update_plan` were NOT
//    producible on this Codex: their tests use hand-written lines that follow
//    the documented shape and are marked as such.

const _dir = 'test/fixtures/codex_logs';

List<String> _lines(String name) {
  final lines = File('$_dir/$name.jsonl').readAsLinesSync();
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines;
}

AgentSessionState _feed(CodexLogMapper mapper, Iterable<String> lines, [AgentSessionState? from]) {
  var s = from ?? const AgentSessionState('s');
  for (final line in lines) {
    for (final u in mapper.map(line)) {
      s = s.apply(u);
    }
  }
  return s;
}

(AgentSessionState, CodexLogMapper) _run(String name) {
  final mapper = CodexLogMapper();
  return (_feed(mapper, _lines(name)), mapper);
}

List<TranscriptMessage> _messages(AgentSessionState s, [MessageRole? role]) => [
  for (final i in s.items)
    if (i is TranscriptMessage && (role == null || i.role == role)) i,
];

List<String> _texts(AgentSessionState s, MessageRole role) => [for (final m in _messages(s, role)) m.text];

List<ToolCall> _tools(AgentSessionState s) => s.toolCalls.toList();

ToolCall _tool(AgentSessionState s, String endsWith) => _tools(s).singleWhere((c) => c.toolCallId.endsWith(endsWith));

String _text(ToolCall c) => [
  for (final x in c.content)
    if (x is ToolContentBlock && x.block is TextBlock) (x.block as TextBlock).text,
].join('\n');

/// The lines up to and including the first one that holds [marker].
List<String> _through(String name, String marker) {
  final all = _lines(name);
  return all.sublist(0, all.indexWhere((l) => l.contains(marker)) + 1);
}

void main() {
  test('every captured log maps without throwing and a second pass changes nothing', () {
    for (final f in Directory(_dir).listSync().whereType<File>().where((f) => f.path.endsWith('.jsonl'))) {
      final name = f.uri.pathSegments.last.replaceAll('.jsonl', '');
      final lines = _lines(name);
      final mapper = CodexLogMapper();
      final once = _feed(mapper, lines);
      final twice = _feed(mapper, lines, once);
      expect(twice.items.length, once.items.length, reason: name);
      expect([for (final c in _tools(twice)) (c.toolCallId, c.status)], [for (final c in _tools(once)) (c.toolCallId, c.status)], reason: name);
      expect(mapper.openToolCalls, isEmpty, reason: '$name leaves nothing running');
    }
  });

  group('a turn', () {
    test('has the person\'s message, Codex\'s replies once, and the first message as the title', () {
      final (s, m) = _run('plain');

      expect(_texts(s, MessageRole.user), ['say hi in 5 words', 'now say bye in 3 words']);
      expect(_texts(s, MessageRole.agent), hasLength(2));
      expect(s.title, 'say hi in 5 words');
      expect(m.turnEnded, isTrue);
    });

    test('a command shows as its real command, with its output and exit status', () {
      final (s, _) = _run('command-fail');

      final failed = _tools(s).firstWhere((c) => c.title == 'ls /hm-no-such-dir');
      final ok = _tools(s).firstWhere((c) => c.title == 'cat hello.txt');
      expect((failed.kind, failed.status), (ToolKind.execute, ToolStatus.failed));
      expect(_text(failed), contains('No such file or directory'));
      expect(ok.status, ToolStatus.completed);
      expect(_text(ok), contains('there'));
      expect((ok.rawInput as Map)['command'], 'cat hello.txt');
      expect(_tools(s), hasLength(2), reason: 'the items did not add rows of their own');
    });

    test('an apply_patch shows each file change as its old and new text', () {
      final (s, _) = _run('patch');

      final rows = _tools(s);
      expect(rows.map((c) => c.kind), everyElement(ToolKind.edit));
      expect(rows, hasLength(2), reason: 'one script, two patches: one row each');
      final first = rows[0].content.whereType<ToolDiff>().single;
      final second = rows[1].content.whereType<ToolDiff>().single;
      expect((first.oldText, first.newText), (null, 'hello\nworld\n'));
      expect((second.oldText, second.newText), ('hello\nworld', 'hello\nthere'));
      expect(rows[0].title, 'Edited hello.txt');
    });

    test('the response_item copy of a message is not shown twice', () {
      final (s, _) = _run('command-sandboxed');
      expect(_texts(s, MessageRole.user), hasLength(1));
      expect(_texts(s, MessageRole.agent), hasLength(2));
    });

    test('a request_user_input call shows its question and stays a terminal matter', () {
      final (s, m) = _run('ask-two');

      expect(_tools(s).single.title, 'Which room is the desk in?');
      expect(m.pendingAsk, isNull, reason: 'Codex answers its questions in the terminal');
    });

    test('a plan shows as a message', () {
      final (s, _) = _run('plan');
      expect(_texts(s, MessageRole.agent).single, startsWith('# Desk Organization Plan'));
    });

    test('a compaction is one quiet note', () {
      final (s, _) = _run('compact');
      expect(_texts(s, MessageRole.agent), contains('Earlier messages were summarised'));
    });

    test('a message typed while a command runs shows once, inside the turn', () {
      final (s, m) = _run('steer');
      expect(_texts(s, MessageRole.user), hasLength(2));
      expect(_texts(s, MessageRole.agent).last, 'done banana');
      expect(m.turnEnded, isTrue);
    });
  });

  group('while it waits and when it is stopped', () {
    test('a command that waits for approval is on the screen as a running row', () {
      final m = CodexLogMapper();
      final s = _feed(m, _through('command-approve', '"custom_tool_call"'));

      final call = _tools(s).single;
      expect(call.status, ToolStatus.inProgress);
      expect(call.title, 'curl -sI https://example.com | head -1');
      expect((call.rawInput as Map)['command'], 'curl -sI https://example.com | head -1', reason: 'the approval card compares with it');
      expect(m.openToolCalls, {call.toolCallId});
      expect(m.turnEnded, isFalse);
    });

    test('the approved command finishes: output, completed, and the cell it waited in ends', () {
      final (s, m) = _run('command-approve');

      expect(_tools(s).single.status, ToolStatus.completed);
      expect(_text(_tools(s).single), contains('HTTP/2 200'));
      expect(m.backgroundTasks.map((t) => (t.id, t.status)), [('cell1', BackgroundStatus.finished)]);
    });

    test('Esc: the open command is cancelled, the turn is over, and it says so', () {
      for (final name in ['interrupt', 'command-decline']) {
        final (s, m) = _run(name);

        expect(_tools(s).single.status, name == 'interrupt' ? ToolStatus.completed : ToolStatus.cancelled, reason: name);
        expect(_texts(s, MessageRole.agent), contains('Interrupted'), reason: name);
        expect(m.turnEnded, isTrue, reason: name);
      }
    });

    test('a declined patch is cancelled and leaves no failed row behind', () {
      final (s, _) = _run('patch-decline');
      expect(_tools(s).map((c) => c.status), [ToolStatus.cancelled]);
    });
  });

  group('background work', () {
    test('a command that outlived its script is a running task until its item arrives', () {
      final m = CodexLogMapper();
      final lines = _lines('yield');
      final firstOutput = lines.indexWhere((l) => l.contains('custom_tool_call_output'));
      _feed(m, lines.sublist(0, firstOutput + 1));

      expect(m.backgroundTasks.single.id, 'proc27850');
      expect(m.backgroundTasks.single.status, BackgroundStatus.running);
      expect(m.backgroundTasks.single.title, 'sleep 40 && echo finished');
      expect(m.backgroundTasks.single.stop, StopRoute.none, reason: 'no model tool stops a unified-exec process');

      final s = _feed(CodexLogMapper(), lines);
      expect(_tools(s).first.title, 'sleep 40 && echo finished', reason: 'its late item went to the call that started it, not to a later poll');
      expect(_text(_tools(s).first), contains('finished'));
    });

    test('a script that outlived its wait is a cell the model can stop; terminating ends it', () {
      final lines = _lines('yield-cell');
      final running = CodexLogMapper();
      _feed(running, lines.sublist(0, lines.indexWhere((l) => l.contains('Script running with cell ID 1')) + 1));

      expect(running.backgroundTasks.single.id, 'cell1');
      expect(running.backgroundTasks.single.status, BackgroundStatus.running);
      expect(running.backgroundTasks.single.stop, StopRoute.message);
      expect(_tools(_feed(CodexLogMapper(), lines.sublist(0, lines.indexWhere((l) => l.contains('Script running with cell ID 1')) + 1))).single.status, ToolStatus.inProgress, reason: 'the call stays open while its cell runs');
      expect(running.openToolCalls, isEmpty, reason: 'a cell is a task, not what an approval asks about');

      final (s, m) = _run('yield-cell');
      expect(m.backgroundTasks.single.status, BackgroundStatus.stopped);
      expect(_tools(s).first.status, ToolStatus.cancelled);
      expect(m.openToolCalls, isEmpty);
    });
  });

  group('subagents', () {
    test('the parent lists the subagent with the thread id its transcript is named by', () {
      final (_, m) = _run('subagent');

      expect(m.subagents.single.name, 'list_files');
      expect(m.subagents.single.status, 'completed');
      expect(m.subagents.single.logId, '01a120bb-b7c6-7d22-9a8c-9aa1031d513f');
    });

    test('a subagent\'s own log starts after the replay of its parent', () {
      final (s, _) = _run('subagent-child');

      expect(_texts(s, MessageRole.user), isEmpty, reason: 'the parent\'s prompt is replayed history, not its own');
      expect(_texts(s, MessageRole.agent).last, contains('hello.txt'));
      expect(_tools(s).map((c) => c.title), contains('ls -la'));
    });
  });

  group('the script of an exec call', () {
    String call(String js, {int ordinal = 12}) => jsonEncode({
      'timestamp': '2026-10-09T12:45:26.465Z',
      'ordinal': ordinal,
      'type': 'response_item',
      'payload': {'type': 'custom_tool_call', 'status': 'completed', 'call_id': 'c$ordinal', 'name': 'exec', 'input': js},
    });

    test('a command is named by its real text whether the model quoted the keys of its object or not', () {
      // The first is a capture (a script of three awaited commands: the first names the row); the others
      // are the other spellings of the same JavaScript object.
      final cases = {
        'const a = await tools.exec_command({cmd:"sleep 25",yield_time_ms:30000});': 'sleep 25',
        'const r = await tools.exec_command({"cmd":"ls -la","workdir":"/w"});': 'ls -la',
        "const r = await tools.exec_command({ cmd: 'echo \"hi\" && ls', workdir: '/w' });": 'echo "hi" && ls',
      };
      var at = 12;
      for (final MapEntry(key: js, value: want) in cases.entries) {
        final s = _feed(CodexLogMapper(), [call(js, ordinal: at++)]);
        final row = _tools(s).single;
        expect(row.title, want, reason: js);
        expect((row.rawInput as Map)['command'], want, reason: js);
        expect(row.kind, ToolKind.execute, reason: js);
      }
    });

    test('a script that is none of these is "Running a script", never an error', () {
      final s = _feed(CodexLogMapper(), [call('const x = 1 + 1; text(String(x));')]);
      expect(_tools(s).single.title, 'Running a script');
    });
  });

  group('an item kind nobody has mapped yet', () {
    String item(Map<String, Object?> it, int ordinal) => jsonEncode({
      'timestamp': '2026-10-09T12:45:26.465Z',
      'ordinal': ordinal,
      'type': 'event_msg',
      'payload': {'type': 'item_completed', 'item': it},
    });

    test('is shown as a row that says what it is, never dropped', () {
      final s = _feed(CodexLogMapper(), [item({'type': 'BrandNewThing', 'id': 'x1', 'detail': 'd'}, 5)]);
      expect(_tools(s).single.title, 'BrandNewThing');
    });

    test('an item the table marks as ignored stays out', () {
      final s = _feed(CodexLogMapper(), [item({'type': 'Reasoning', 'id': 'r', 'summary_text': []}, 5), item({'type': 'Sleep', 'id': 's'}, 6)]);
      expect(s.items, isEmpty);
    });
  });

  group('what a command item says is not overwritten by its script', () {
    test('a failed command stays failed when the script printed nothing about its exit', () {
      String l(int o, String type, Map<String, Object?> p) =>
          jsonEncode({'timestamp': 't', 'ordinal': o, 'type': type, 'payload': p});
      final s = _feed(CodexLogMapper(), [
        l(1, 'response_item', {'type': 'custom_tool_call', 'call_id': 'c1', 'name': 'exec', 'input': 'const r = await tools.exec_command({cmd:"ls /nope"});\ntext("done");'}),
        l(2, 'event_msg', {'type': 'item_completed', 'item': {'type': 'CommandExecution', 'id': 'e1', 'command': ['/bin/zsh', '-lc', 'ls /nope'], 'status': 'failed', 'exit_code': 1, 'aggregated_output': 'ls: /nope: No such file'}}),
        l(3, 'response_item', {'type': 'custom_tool_call_output', 'call_id': 'c1', 'output': [{'type': 'input_text', 'text': 'Script completed\nWall time 0.1 seconds\nOutput:\n'}, {'type': 'input_text', 'text': 'done'}]}),
      ]);
      expect(_tools(s).single.status, ToolStatus.failed);
    });

    test('the item of a process that ended after the final answer adds no stray row', () {
      final (s, _) = _run('yield-cell');
      expect(_tools(s), hasLength(1));
    });

    test('a removed line that starts with -- and an added ++i stay in the diff', () {
      final s = _feed(CodexLogMapper(), [
        jsonEncode({
          'timestamp': 't',
          'ordinal': 1,
          'type': 'event_msg',
          'payload': {
            'type': 'item_completed',
            'item': {
              'type': 'FileChange',
              'id': 'f1',
              'status': 'completed',
              'changes': {'/w/a.sql': {'type': 'update', 'unified_diff': '@@ -1,2 +1,2 @@\n keep\n--- a comment\n+++i\n'}},
            },
          },
        }),
      ]);
      final diff = _tools(s).single.content.whereType<ToolDiff>().single;
      expect((diff.oldText, diff.newText), ('keep\n-- a comment', 'keep\n++i'));
    });
  });

  group('robustness', () {
    test('a compacted line is skipped from its first characters, without decoding it', () {
      // Decoded, this line would be a user message (the later duplicate keys win): it maps to nothing
      // only because the first 160 characters said `compacted`.
      final trap = '{"ordinal":1,"type":"compacted","payload":{"type":"x"},"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"u","content":[{"type":"text","text":"hi"}]}}}';
      expect(jsonDecode(trap)['type'], 'event_msg');
      expect(CodexLogMapper().map(trap), isEmpty);

      final big = '{"timestamp":"2026-10-09T12:43:35.249Z","ordinal":23,"type":"compacted","payload":{"message":"","replacement_history":[{"type":"message","text":"${'x' * 1200000}"}]}}';
      expect(CodexLogMapper().map(big), isEmpty);
    });

    test('garbage and unknown shapes map to nothing', () {
      final m = CodexLogMapper();
      for (final l in ['', 'not json', '[]', '{"type":"event_msg"}']) {
        expect(m.map(l), isEmpty, reason: l);
      }
    });

    test('reset forgets everything', () {
      final (_, m) = _run('yield');
      m.reset();
      expect(m.backgroundTasks, isEmpty);
      expect(m.openToolCalls, isEmpty);
      expect(m.subagents, isEmpty);
      expect(m.turnEnded, isFalse);
    });
  });

  // Hand-written: this Codex writes only the paginated dialect, so these lines
  // follow the documented legacy shape, not a capture.
  group('the legacy dialect (hand-written lines)', () {
    String line(Map<String, Object?> payload, String type, int ordinal) =>
        jsonEncode({'timestamp': '2026-01-01T00:00:00Z', 'ordinal': ordinal, 'type': type, 'payload': payload});

    test('a turn maps like the paginated one: messages, a command joined by call_id, a patch', () {
      final lines = [
        line({'id': 't', 'cwd': '/w'}, 'session_meta', 0),
        line({'type': 'user_message', 'message': 'list files'}, 'event_msg', 1),
        line({'type': 'agent_message', 'message': 'on it', 'phase': 'commentary'}, 'event_msg', 2),
        line({'type': 'function_call', 'name': 'exec_command', 'arguments': jsonEncode({'cmd': 'ls -la', 'workdir': '/w'}), 'call_id': 'c1'}, 'response_item', 3),
        line({'type': 'exec_command_end', 'call_id': 'c1', 'command': ['ls'], 'aggregated_output': 'a\nb\n', 'exit_code': 0, 'status': 'completed'}, 'event_msg', 4),
        line({'type': 'custom_tool_call', 'name': 'apply_patch', 'input': '*** Begin Patch\n*** End Patch', 'call_id': 'c2'}, 'response_item', 5),
        line({'type': 'patch_apply_end', 'call_id': 'c2', 'success': false, 'stdout': '', 'changes': {}}, 'event_msg', 6),
      ];
      final m = CodexLogMapper();
      final s = _feed(m, lines);

      expect(_texts(s, MessageRole.user), ['list files']);
      expect(_texts(s, MessageRole.agent), ['on it']);
      final ls = _tool(s, 'c1');
      expect((ls.title, ls.status, _text(ls)), ('ls -la', ToolStatus.completed, 'a\nb\n'));
      final patch = _tool(s, 'c2');
      expect((patch.kind, patch.status), (ToolKind.edit, ToolStatus.failed));
      expect(m.openToolCalls, isEmpty);
    });

    test('update_plan becomes the plan', () {
      final m = CodexLogMapper();
      final s = _feed(m, [
        line({'type': 'function_call', 'name': 'update_plan', 'arguments': jsonEncode({'plan': [{'step': 'one', 'status': 'completed'}, {'step': 'two', 'status': 'in_progress'}]}), 'call_id': 'p'}, 'response_item', 1),
      ]);

      expect([for (final e in s.plan) (e.content, e.status)], [('one', PlanStatus.completed), ('two', PlanStatus.inProgress)]);
    });
  });

  group('a message with a picture', () {
    test('the captured paste shows once per turn, with Codex\'s own placeholder', () {
      final s = _feed(CodexLogMapper(), _lines('image-paste'));
      final texts = [for (final m in s.items.whereType<TranscriptMessage>()) if (m.role == MessageRole.user) m.text];
      expect(texts, isNotEmpty);
      expect(texts, everyElement('[Image #1]  what colour is this picture?'));
      expect(texts.where((t) => t.contains('[image]')), isEmpty);
    });

    test('a picture the text does not mark gets an [image] line; a picture alone is not an empty message', () {
      String item(String id, List<Object> content) => jsonEncode({
        'type': 'event_msg',
        'payload': {
          'type': 'item_completed',
          'item': {'type': 'UserMessage', 'id': id, 'content': content},
        },
      });
      final s = _feed(CodexLogMapper(), [
        item('a', [
          {'type': 'text', 'text': 'what is this?'},
          {'type': 'local_image', 'path': '/h/x.jpg'},
        ]),
        item('b', [
          {'type': 'image', 'image_url': 'data:image/png;base64,<trimmed>'},
        ]),
      ]);
      final texts = [for (final m in s.items.whereType<TranscriptMessage>()) if (m.role == MessageRole.user) m.text];
      expect(texts, ['what is this?\n[image]', '[image]']);
    });
  });
}
