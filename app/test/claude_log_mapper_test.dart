import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/background/background_work.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/observed/claude_log_mapper.dart';

// What these tests rely on, as observed on real Claude Code 2.1.293 / 2.1.295
// (see test/fixtures/claude_logs/):
//  * While a permission prompt is on screen, the pending tool_use line (Bash,
//    Write, Edit, ExitPlanMode, AskUserQuestion) IS already in the log and is
//    its last line. Nothing marks "waiting for permission".
//  * `thinking` blocks carry no text, only a signature.
//  * Esc during a tool or during streamed text writes `[Request interrupted by
//    user ...]` and NO `turn_duration`; refusing a tool with No writes the
//    same two lines and then `turn_duration`.
//  * A subagent's own transcript has `isSidechain: true` on every line; the
//    main file has none of those lines.
//  * A background job's end arrives as a `<task-notification>` (a user line, or
//    an attachment when the person stopped it); a job the model stopped with
//    TaskStop has no notice.

const _dir = 'test/fixtures/claude_logs';

List<String> _lines(String name) {
  final lines = File('$_dir/$name.jsonl').readAsLinesSync();
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines;
}

AgentSessionState _feed(ClaudeLogMapper mapper, Iterable<String> lines, [AgentSessionState? from]) {
  var s = from ?? const AgentSessionState('s');
  for (final line in lines) {
    for (final u in mapper.map(line)) {
      s = s.apply(u);
    }
  }
  return s;
}

(AgentSessionState, ClaudeLogMapper) _run(String name) {
  final mapper = ClaudeLogMapper();
  return (_feed(mapper, _lines(name)), mapper);
}

List<TranscriptMessage> _messages(AgentSessionState s, [MessageRole? role]) => [
  for (final i in s.items)
    if (i is TranscriptMessage && (role == null || i.role == role)) i,
];

List<String> _texts(AgentSessionState s, MessageRole role) => [for (final m in _messages(s, role)) m.text];

List<ToolCall> _tools(AgentSessionState s) => s.toolCalls.toList();

ToolCall _toolNamed(AgentSessionState s, String name) => _tools(s).firstWhere((c) => c.name == name);

String _text(ToolCall c) => [
  for (final x in c.content)
    if (x is ToolContentBlock && x.block is TextBlock) (x.block as TextBlock).text,
].join('\n');

/// The lines up to and including the line that calls [tool].
List<String> _through(String name, String tool) {
  final all = _lines(name);
  final at = all.indexWhere((l) => l.contains('"type":"tool_use"') && l.contains('"name":"$tool"'));
  expect(at, isNonNegative, reason: '$name calls $tool');
  return all.sublist(0, at + 1);
}

void main() {
  test('every captured log maps without throwing, leaves nothing running, and a second pass changes nothing', () {
    final files = [
      for (final f in Directory(_dir).listSync().whereType<File>())
        if (f.path.endsWith('.jsonl')) f.uri.pathSegments.last.replaceAll('.jsonl', ''),
    ];
    expect(files, isNotEmpty);
    for (final name in files) {
      final lines = _lines(name);
      final mapper = ClaudeLogMapper();
      final once = _feed(mapper, lines);
      final twice = _feed(mapper, lines, once);
      expect(twice.items.length, once.items.length, reason: name);
      expect([for (final c in _tools(twice)) (c.toolCallId, c.status)], [for (final c in _tools(once)) (c.toolCallId, c.status)], reason: name);
    }
  });

  group('a turn', () {
    test('has the person\'s prompts, Claude\'s replies, the title, and no empty thinking', () {
      final (s, m) = _run('plain');

      expect(_texts(s, MessageRole.user), ['say hi in 5 words', 'now say bye in 3 words']);
      expect(_texts(s, MessageRole.agent), hasLength(2));
      expect(_messages(s, MessageRole.thought), isEmpty);
      expect(s.title, 'Greeting in five words');
      expect(m.turnEnded, isTrue);
    });

    test('a tool call written before it finishes is a running row; its result completes it', () {
      final m = ClaudeLogMapper();
      final s = _feed(m, _through('bash-approve', 'Bash'));

      final call = _tools(s).single;
      expect((call.status, call.kind, call.name), (ToolStatus.inProgress, ToolKind.execute, 'Bash'));
      expect((call.rawInput as Map)['command'], 'touch /tmp/hm-capture-claude/x.txt', reason: 'the approval card compares with it');
      expect(m.openToolCalls, {call.toolCallId});
      expect(m.turnEnded, isFalse);

      final done = _feed(m, _lines('bash-approve'), s);
      expect(_tools(done).single.status, ToolStatus.completed);
      expect(m.openToolCalls, isEmpty);
    });

    test('a command shows its output, and a failing one is failed', () {
      final (ok, _) = _run('queued-tool');
      final (bad, _) = _run('bash-fail');

      expect(_text(_toolNamed(ok, 'Bash')), contains('12 packets transmitted'));
      final failed = _toolNamed(bad, 'Bash');
      expect(failed.status, ToolStatus.failed);
      expect(_text(failed), contains('Exit code 1'));
    });

    test('Write and Edit show the change; a tool a hook blocked is failed, not cancelled', () {
      final (s, _) = _run('edit-write');

      final write = _toolNamed(s, 'Write').content.whereType<ToolDiff>().single;
      expect((write.path, write.oldText, write.newText), ('/tmp/hm-capture-claude/note.txt', null, 'hello world'));
      final edit = _toolNamed(s, 'Edit').content.whereType<ToolDiff>().single;
      expect((edit.oldText, edit.newText), ('world', 'there'));
      expect(_toolNamed(s, 'Edit').locations.single.path, '/tmp/hm-capture-claude/note.txt');
      expect(_toolNamed(s, 'Read').status, ToolStatus.failed);
    });

    test('a prompt typed while a tool ran shows once', () {
      final (s, _) = _run('queued-tool');
      expect(_texts(s, MessageRole.user).where((t) => t.contains('PINEAPPLE')), hasLength(1));
    });

    test('a slash command shows as typed, once; a compaction is a quiet note', () {
      final (s, _) = _run('compact');

      expect(_texts(s, MessageRole.user).where((t) => t == '/compact'), hasLength(1));
      expect(_texts(s, MessageRole.agent), contains('Earlier messages were summarised'));
    });

    test('/clear is not a message of the chat: every captured fresh session file opens with it', () {
      final names = [
        for (final f in Directory(_dir).listSync().whereType<File>())
          if (f.path.endsWith('.jsonl') && f.readAsStringSync().contains('<command-name>/clear</command-name>'))
            f.uri.pathSegments.last.replaceAll('.jsonl', ''),
      ];
      expect(names, isNotEmpty);
      for (final name in names) {
        final (s, _) = _run(name);
        expect(_texts(s, MessageRole.user), isNot(contains('/clear')), reason: name);
      }
    });

    test('/rename sets the title, beats the AI title however often it is rewritten, and is not a message', () {
      String user(String id, String content) => jsonEncode({
        'type': 'user',
        'uuid': id,
        'message': {'role': 'user', 'content': content},
      });
      final m = ClaudeLogMapper();
      var s = _feed(m, [
        jsonEncode({'type': 'ai-title', 'aiTitle': 'Auto title', 'sessionId': 'x'}),
        user('a', '<command-name>/rename</command-name>\n<command-message>rename</command-message>\n<command-args>My name</command-args>'),
        user('b', '<local-command-stdout>Session renamed to: My name</local-command-stdout>'),
        jsonEncode({'type': 'custom-title', 'customTitle': 'My name', 'sessionId': 'x'}),
        // Claude appends both titles again later, the AI one last.
        jsonEncode({'type': 'custom-title', 'customTitle': 'My name', 'sessionId': 'x'}),
        jsonEncode({'type': 'ai-title', 'aiTitle': 'Auto title', 'sessionId': 'x'}),
      ]);

      expect(s.title, 'My name');
      expect(_texts(s, MessageRole.user), isEmpty);
      expect(_texts(s, MessageRole.agent), ['Session renamed to: My name']);

      // Renamed back to an earlier name: the same line as before must still count.
      s = _feed(m, [
        jsonEncode({'type': 'custom-title', 'customTitle': 'Other', 'sessionId': 'x'}),
        jsonEncode({'type': 'custom-title', 'customTitle': 'My name', 'sessionId': 'x'}),
      ], s);
      expect(s.title, 'My name');
    });

    test('a skill or custom command (command-message first) shows as typed, not as raw tags', () {
      final s = _feed(ClaudeLogMapper(), [
        jsonEncode({
          'type': 'user',
          'uuid': 'u1',
          'message': {
            'role': 'user',
            'content':
                '<command-message>review is running…</command-message>\n<command-name>/review</command-name>\n<command-args>the diff</command-args>',
          },
        }),
      ]);

      expect(_texts(s, MessageRole.user), ['/review the diff']);
    });

    test('bash mode, memory notes, stderr and teammates show as what they are, never as raw tags', () {
      String user(String id, Object content) => jsonEncode({
        'type': 'user',
        'uuid': id,
        'message': {'role': 'user', 'content': content},
      });
      final s = _feed(ClaudeLogMapper(), [
        user('a', '<bash-input>ls /tmp</bash-input>'),
        user('b', '<bash-stdout>one\ntwo</bash-stdout><bash-stderr></bash-stderr>'),
        user('c', '<bash-stdout></bash-stdout><bash-stderr>nope</bash-stderr>'),
        user('d', '<user-memory-input>use tabs</user-memory-input>'),
        user('e', '<local-command-stderr>boom</local-command-stderr>'),
        user('f', [
          {'type': 'text', 'text': '<system-reminder>context</system-reminder>'},
          {'type': 'text', 'text': 'fix the build'},
        ]),
        user('g', '<teammate-message teammate_id="reviewer" color="blue" summary="Found 2 issues">long body</teammate-message>'),
      ]);

      expect(_texts(s, MessageRole.user), ['!ls /tmp', '# use tabs', 'fix the build']);
      expect(_texts(s, MessageRole.agent), ['one\ntwo', 'stderr:\nnope', 'boom', 'reviewer: Found 2 issues']);
    });

    test('a prompt typed during a turn shows when it was typed, once', () {
      final (s, _) = _run('queued-tool');
      expect(_messages(s, MessageRole.user).where((m) => m.text.contains('PINEAPPLE')), hasLength(1));
      // Shown when typed (before the agent's reply), not seconds later.
      final typed = s.items.indexWhere((i) => i is TranscriptMessage && i.role == MessageRole.user && i.text.contains('PINEAPPLE'));
      final reply = s.items.indexWhere((i) => i is TranscriptMessage && i.role == MessageRole.agent && i.text.contains('PINEAPPLE'));
      expect(typed, lessThan(reply));
    });

    test('loading a deferred tool is not a row, and /compact shows its first line, not a hook report', () {
      final (plan, _) = _run('plan-mode');
      expect(_tools(plan).where((c) => c.name == 'ToolSearch'), isEmpty);
      final (compact, _) = _run('compact');
      for (final t in _texts(compact, MessageRole.agent)) {
        expect(t, isNot(contains('systemMessage')));
        expect(t, isNot(contains('\n')));
      }
    });

    test('housekeeping never shows: caveats, reminders, hook output', () {
      for (final name in ['clear-new', 'bash-approve']) {
        final (s, _) = _run(name);
        for (final t in _texts(s, MessageRole.user) + _texts(s, MessageRole.agent)) {
          expect(t, isNot(contains('local-command-caveat')), reason: name);
          expect(t, isNot(contains('system-reminder')), reason: name);
        }
      }
    });

    test('a failed API call says so', () {
      final m = ClaudeLogMapper();
      final line = jsonEncode({
        'type': 'assistant',
        'uuid': 'u1',
        'isSidechain': false,
        'isApiErrorMessage': true,
        'message': {'model': '<synthetic>', 'id': 'x', 'content': [{'type': 'text', 'text': 'API Error: 529 overloaded'}]},
      });
      final s = _feed(m, [line]);

      expect(_texts(s, MessageRole.agent), ['The turn failed: API Error: 529 overloaded']);
      expect(m.turnEnded, isTrue);
    });
  });

  group('stopping', () {
    test('Esc during a tool: the call is cancelled, it says so, and the turn is over without a turn_duration', () {
      final (s, m) = _run('interrupt-tool');

      expect(_toolNamed(s, 'Bash').status, ToolStatus.cancelled);
      expect(_texts(s, MessageRole.agent), contains('Interrupted'));
      expect(m.turnEnded, isTrue);
      expect(m.openToolCalls, isEmpty);
    });

    test('Esc during streamed text keeps the text and ends the turn', () {
      final (s, m) = _run('interrupt-text');

      expect(_texts(s, MessageRole.agent).first, startsWith('**The Keeper of Halvard Point**'));
      expect(m.turnEnded, isTrue);
    });

    test('a tool the person refused is cancelled, not failed', () {
      for (final name in ['bash-deny', 'bash-esc']) {
        final (s, m) = _run(name);
        expect(_toolNamed(s, 'Bash').status, ToolStatus.cancelled, reason: name);
        expect(m.openToolCalls, isEmpty, reason: name);
      }
    });

    test('turn_duration is what ends a turn that finished by itself', () {
      final lines = _lines('plain');
      final end = lines.indexWhere((l) => l.contains('"turn_duration"'));
      final m = ClaudeLogMapper();
      _feed(m, lines.sublist(0, end));
      expect(m.turnEnded, isTrue, reason: 'the final answer says end_turn already');

      final c = ClaudeLogMapper();
      _feed(c, _through('bash-approve', 'Bash'));
      expect(c.turnEnded, isFalse);
    });
  });

  group('questions and plans', () {
    test('an AskUserQuestion that waits is a pending question with its options; its answer clears it', () {
      final m = ClaudeLogMapper();
      final waiting = _feed(m, _through('ask-single', 'AskUserQuestion'));

      final ask = m.pendingAsk!;
      expect(ask.questions.single.id, 'Color');
      expect(ask.questions.single.question, 'Which color do you prefer?');
      expect(ask.questions.single.options.map((o) => o.label), ['Red', 'Green', 'Blue'], reason: 'Claude adds its own Other row');
      expect(ask.questions.single.multi, isFalse);

      final s = _feed(m, _lines('ask-single'), waiting);
      expect(m.pendingAsk, isNull);
      expect(_toolNamed(s, 'AskUserQuestion').rawOutput, contains('Your questions have been answered'));
    });

    test('a multi-select and a two-question form keep their shape', () {
      final m = ClaudeLogMapper();
      _feed(m, _through('ask-two', 'AskUserQuestion'));

      expect(m.pendingAsk!.questions.map((q) => (q.id, q.multi)), [('Lang', false), ('Extras', true)]);
    });

    test('a declined question is cancelled and no longer pending', () {
      final (s, m) = _run('ask-declined');
      expect(_toolNamed(s, 'AskUserQuestion').status, ToolStatus.cancelled);
      expect(m.pendingAsk, isNull);
    });

    test('a question the person answered in the terminal by typing is dropped when they send a prompt', () {
      final m = ClaudeLogMapper();
      final lines = _through('ask-single', 'AskUserQuestion');
      final s = _feed(m, lines);
      final typed = jsonEncode({
        'type': 'user',
        'uuid': 'typed-1',
        'isSidechain': false,
        'origin': {'kind': 'human'},
        'message': {'role': 'user', 'content': 'never mind'},
      });

      final after = _feed(m, [typed], s);

      expect(m.pendingAsk, isNull);
      expect(_toolNamed(after, 'AskUserQuestion').status, ToolStatus.cancelled);
    });

    test('ExitPlanMode keeps the plan so the approval card can show it', () {
      final m = ClaudeLogMapper();
      final s = _feed(m, _through('plan-mode', 'ExitPlanMode'));

      final call = _toolNamed(s, 'ExitPlanMode');
      expect(call.status, ToolStatus.inProgress);
      expect((call.rawInput as Map)['plan'], startsWith('# Plan: create hello.txt'));
      expect(call.kind, ToolKind.switchMode);
    });

    test('TaskCreate and TaskUpdate build the task list; TodoWrite replaces it', () {
      final (tasks, _) = _run('tasks');
      final (todos, _) = _run('todowrite');

      expect([for (final e in tasks.plan) (e.content, e.status)], [
        ('Research', PlanStatus.completed),
        ('Build', PlanStatus.completed),
        ('Test', PlanStatus.completed),
      ]);
      expect(todos.plan.map((e) => e.status), everyElement(PlanStatus.completed));
    });
  });

  group('subagents', () {
    test('the parent lists the subagent with the id its transcript is named by', () {
      final (s, m) = _run('subagent');

      final sub = m.subagents.single;
      expect(sub.name, 'List files in hm-capture-claude');
      expect((sub.agent, sub.status, sub.logId), ('general-purpose', 'completed', 'a6c798c858e96e728'));
      expect(sub.callId, _toolNamed(s, 'Agent').toolCallId);
      expect(sub.assignment, startsWith('Use the Bash tool to run `ls`'));
    });

    test('a subagent still running is running, and is a background task the person can stop', () {
      final m = ClaudeLogMapper();
      final lines = _lines('subagent');
      _feed(m, lines.sublist(0, lines.indexWhere((l) => l.contains('<task-notification>'))));

      expect(m.subagents.single.status, 'running');
      expect(m.backgroundTasks.single.kind, BackgroundKind.agent);
      expect(m.backgroundTasks.single.id, 'a6c798c858e96e728');
      expect(m.backgroundTasks.single.stop, StopRoute.message);
    });

    test('the transcript of a subagent is mapped by a sidechain mapper only', () {
      final lines = _lines('subagents/agent-a6c798c858e96e728');

      final main = _feed(ClaudeLogMapper(), lines);
      final side = _feed(ClaudeLogMapper(sidechain: true), lines);

      expect(main.items, isEmpty);
      expect(_tools(side).single.title, 'List contents of hm-capture-claude temp directory');
      expect(_texts(side, MessageRole.agent).single, contains('no entries'));
      expect(_texts(side, MessageRole.user).single, startsWith('Use the Bash tool to run `ls`'));
    });
  });

  group('background work', () {
    test('a background command is a running task until its notice; the notice is not a message from the person', () {
      final m = ClaudeLogMapper();
      final lines = _lines('background-bash-finished');
      final notice = lines.indexWhere((l) => l.contains('<task-notification>') && l.contains('"type":"user"'));
      _feed(m, lines.sublist(0, notice));

      final t = m.backgroundTasks.single;
      expect((t.id, t.kind, t.status, t.stop), ('bwn5dp2o7', BackgroundKind.shell, BackgroundStatus.running, StopRoute.message));
      expect(t.title, 'sleep 25 && echo finished');
      expect(m.turnEnded, isTrue, reason: 'the turn is over; only the job runs');

      final s = _feed(m, lines.sublist(notice));
      expect(m.backgroundTasks.single.status, BackgroundStatus.finished);
      expect(_texts(s, MessageRole.user).where((t) => t.contains('task-notification')), isEmpty);
    });

    test('failed, killed by the model, and stopped by the person end as what they were', () {
      expect(_run('background-bash-failed').$2.backgroundTasks.single.status, BackgroundStatus.failed);
      expect(_run('background-bash-killed').$2.backgroundTasks.single.status, BackgroundStatus.stopped);
      final (s, m) = _run('background-bash-user-stopped');
      expect(m.backgroundTasks.single.status, BackgroundStatus.stopped);
      expect(_texts(s, MessageRole.user).where((t) => t.contains('task-notification')), isEmpty);
    });

    // Hand-written from the official tool schema (WorkflowOutput, MonitorOutput) of
    // @anthropic-ai/claude-agent-sdk: this Claude Code could not be made to run
    // either tool in the capture.
    test('a workflow and a monitor are background tasks of their kinds, ended by their notice', () {
      String call(String id, String name, Map<String, Object?> input) => jsonEncode({
        'type': 'assistant', 'uuid': 'a-$id', 'isSidechain': false,
        'message': {'id': 'm-$id', 'model': 'x', 'content': [{'type': 'tool_use', 'id': id, 'name': name, 'input': input}]},
      });
      String result(String id, Map<String, Object?> out) => jsonEncode({
        'type': 'user', 'uuid': 'r-$id', 'isSidechain': false,
        'message': {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': id, 'content': 'launched'}]},
        'toolUseResult': out,
      });
      final m = ClaudeLogMapper();
      _feed(m, [
        call('t1', 'Workflow', {'name': 'release-check'}),
        result('t1', {'status': 'async_launched', 'taskId': 'wf1abc', 'workflowName': 'release-check'}),
        call('t2', 'Monitor', {'description': 'Watch the deploy log', 'timeout_ms': 300000, 'command': 'tail -f x'}),
        result('t2', {'taskId': 'mon9xyz', 'timeoutMs': 300000}),
      ]);

      expect([for (final t in m.backgroundTasks) (t.id, t.kind, t.title, t.status)], [
        ('wf1abc', BackgroundKind.workflow, 'release-check', BackgroundStatus.running),
        ('mon9xyz', BackgroundKind.monitor, 'Watch the deploy log', BackgroundStatus.running),
      ]);

      _feed(m, [
        jsonEncode({
          'type': 'user', 'uuid': 'n1', 'isSidechain': false, 'origin': {'kind': 'task-notification'},
          'message': {'role': 'user', 'content': '<task-notification>\n<task-id>wf1abc</task-id>\n<status>completed</status>\n</task-notification>'},
        }),
      ]);
      expect(m.backgroundTasks.map((t) => t.status), [BackgroundStatus.finished, BackgroundStatus.running]);
    });

    test('only plain task ids can be put in a message to Claude', () {
      final m = ClaudeLogMapper();
      final line = jsonEncode({
        'type': 'user',
        'uuid': 'r1',
        'isSidechain': false,
        'message': {
          'role': 'user',
          'content': [{'type': 'tool_result', 'tool_use_id': 't1', 'content': 'x'}],
        },
        'toolUseResult': {'backgroundTaskId': 'a b; rm -rf /'},
      });
      final start = jsonEncode({
        'type': 'assistant',
        'uuid': 'a1',
        'isSidechain': false,
        'message': {'id': 'm1', 'model': 'x', 'content': [{'type': 'tool_use', 'id': 't1', 'name': 'Bash', 'input': {'command': 'x'}}]},
      });
      _feed(m, [start, line]);
      expect(m.backgroundTasks, isEmpty);
    });
  });

  group('robustness', () {
    test('garbage and unknown shapes map to nothing', () {
      final m = ClaudeLogMapper();
      for (final l in ['', 'not json', '[]', '{}', '{"type":"assistant"}', '{"type":"user","message":5}', '{"type":"mystery","uuid":"x"}']) {
        expect(m.map(l), isEmpty, reason: l);
      }
    });

    test('reset forgets everything, so the same file maps again', () {
      final m = ClaudeLogMapper();
      final lines = _lines('plain');
      final first = _feed(m, lines);
      m.reset();
      final second = _feed(m, lines);

      expect(second.items.length, first.items.length);
      expect(m.openToolCalls, isEmpty);
    });
  });
}
