import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/background/background_work.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/observed/omp_log_mapper.dart';

const _dir = 'test/fixtures/omp_logs';

/// The lines of a fixture log (the last empty one dropped).
List<String> _lines(String name) {
  final lines = File('$_dir/$name.jsonl').readAsLinesSync();
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines;
}

AgentSessionState _feed(OmpLogMapper mapper, Iterable<String> lines, [AgentSessionState? from]) {
  var s = from ?? const AgentSessionState('s');
  for (final line in lines) {
    for (final u in mapper.map(line)) {
      s = s.apply(u);
    }
  }
  return s;
}

(AgentSessionState, OmpLogMapper) _run(String name) {
  final mapper = OmpLogMapper();
  return (_feed(mapper, _lines(name)), mapper);
}

List<TranscriptMessage> _messages(AgentSessionState s, [MessageRole? role]) => [
  for (final i in s.items)
    if (i is TranscriptMessage && (role == null || i.role == role)) i,
];

List<ToolCall> _tools(AgentSessionState s) => s.toolCalls.toList();

List<String> _texts(AgentSessionState s, MessageRole role) => [for (final m in _messages(s, role)) m.text];

String _toolText(ToolCall c) => [
  for (final x in c.content)
    if (x is ToolContentBlock && x.block is TextBlock) (x.block as TextBlock).text,
].join('\n');

List<ToolDiff> _diffs(ToolCall c) => c.content.whereType<ToolDiff>().toList();

/// Everything the transcript shows, as one comparable string.
String _fingerprint(AgentSessionState s) {
  final b = StringBuffer();
  for (final i in s.items) {
    switch (i) {
      case TranscriptMessage():
        b.writeln('m ${i.key} ${i.role.name} ${i.messageId} ${jsonEncode(i.text)}');
      case TranscriptTool(:final call):
        b.writeln(
          't ${call.toolCallId} ${call.name} ${call.kind.name} ${call.status.name} ${jsonEncode(call.title)} '
          '${jsonEncode(call.rawInput)} ${jsonEncode(call.rawOutput)} '
          '${jsonEncode([for (final c in call.content) c.toJson()])} '
          '${[for (final l in call.locations) '${l.path}:${l.line}']}',
        );
      case TranscriptStop():
        b.writeln('s ${i.key} ${i.reason.name}');
      case TranscriptNote():
        b.writeln('n ${i.key} ${jsonEncode(i.text)}');
    }
  }
  b.writeln('plan ${[for (final p in s.plan) '${p.status.name}:${p.content}']}');
  b.writeln('title ${s.title}');
  return b.toString();
}

const _fixtures = [
  'bash_turn',
  'file_tools_turn',
  'failing_tools',
  'todo_plan',
  'subagent_task',
  'subagent_log',
  'subagent_artifact_acp',
  'ask_pending',
  'ask_answered',
  'compaction_branch',
  'turn_error',
  'odd_entries',
  'edit_modes',
  'subagents_irc',
  'background_jobs',
];

String _entry(Json e) => jsonEncode(e);

String _user(String id, String text) => _entry({
  'type': 'message',
  'id': id,
  'message': {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
});

String _assistant(String id, List<Json> content, {String stop = 'stop'}) => _entry({
  'type': 'message',
  'id': id,
  'message': {'role': 'assistant', 'content': content, 'stopReason': stop},
});

String _result(String id, String callId, String name, String text, {Json? details, bool error = false}) => _entry({
  'type': 'message',
  'id': id,
  'message': {
    'role': 'toolResult',
    'toolCallId': callId,
    'toolName': name,
    'content': [
      {'type': 'text', 'text': text},
    ],
    'details': details ?? {},
    'isError': error,
  },
});

Json _call(String id, String name, Json args, {String? intent}) => {
  'type': 'toolCall',
  'id': id,
  'name': name,
  'arguments': args,
  'intent': ?intent,
};

void main() {
  group('a real generated omp turn reads like an ACP session', () {
    test('bash: user, thought, tool row with command and output, thought, answer', () {
      final (s, m) = _run('bash_turn');
      expect(s.items.map((i) => i is TranscriptMessage ? i.role.name : 'tool').toList(), [
        'user',
        'thought',
        'tool',
        'thought',
        'agent',
      ]);
      final user = _messages(s, MessageRole.user).single;
      expect(user.messageId, '1c589c9d');
      expect(user.text, startsWith('Use the bash tool to run: echo hello-from-bash'));
      expect(_texts(s, MessageRole.agent), ['done']);
      expect(_messages(s, MessageRole.agent).single.messageId, '6ed8343d:1');

      final call = s.toolCall('toolu_01LEm16gKtt3ptpZtB1VHMHU')!;
      expect(call.name, 'bash');
      expect(call.kind, ToolKind.execute);
      expect(call.status, ToolStatus.completed);
      expect(call.title, 'Running echo command');
      expect((call.rawInput as Map)['command'], 'echo hello-from-bash');
      expect(_toolText(call), startsWith('hello-from-bash'));
      expect(call.rawOutput, startsWith('hello-from-bash'));
      expect(m.openToolCalls, isEmpty);
      expect(m.pendingAsk, isNull);
      expect(s.plan, isEmpty);
    });

    test('files: read, write with diff, edit with the result diff, grep, glob', () {
      final (s, m) = _run('file_tools_turn');
      final calls = _tools(s);
      expect(calls.map((c) => c.kind), [ToolKind.read, ToolKind.edit, ToolKind.edit, ToolKind.search, ToolKind.search]);
      expect(calls.map((c) => c.status), everyElement(ToolStatus.completed));
      expect(m.openToolCalls, isEmpty);

      final read = calls[0];
      expect(read.title, 'Reading hello.txt');
      expect(read.locations.single.path, '/tmp/work/hello.txt');
      expect(_toolText(read), contains('2:beta'));

      final write = calls[1];
      expect(write.name, 'write');
      final wd = _diffs(write).single;
      expect(wd.path, '/tmp/work/notes.txt');
      expect(wd.oldText, isNull);
      expect(wd.newText, 'one\ntwo\nthree');
      expect(_toolText(write), contains('Successfully wrote 13 bytes'));
      expect(write.locations.single.path, '/tmp/work/notes.txt');

      final edit = calls[2];
      expect(edit.name, 'edit');
      expect(edit.title, 'Changing two to TWO');
      final ed = _diffs(edit).single;
      expect(ed.path, '/tmp/work/notes.txt');
      expect(ed.oldText, 'one\ntwo\nthree');
      expect(ed.newText, 'one\nTWO\nthree');
      expect(edit.content.first, isA<ToolDiff>(), reason: 'the diff comes before the text, as in ACP');
      expect(edit.locations.map((l) => l.path), ['/tmp/work/notes.txt']);

      expect(calls[3].title, 'Grepping for beta in hello.txt');
      expect(_toolText(calls[3]), contains('beta'));
      expect(_toolText(calls[4]), 'notes.txt\nhello.txt');
      expect(_texts(s, MessageRole.agent).single, startsWith('All tasks completed'));
    });

    test('an edit that has only its arguments so far has no diff yet; the result adds it', () {
      final lines = _lines('file_tools_turn');
      final m = OmpLogMapper();
      final i = lines.indexWhere((l) => l.contains('"name":"edit"'));
      var s = _feed(m, lines.take(i + 1));
      final pending = s.toolCall('toolu_01JeAoNKUa4zg9pdn3hZWDKV')!;
      expect(pending.status, ToolStatus.inProgress);
      expect(_diffs(pending), isEmpty);
      expect(pending.locations.single.path, '/tmp/work/notes.txt', reason: 'from the hashline header');
      expect(m.openToolCalls, {'toolu_01JeAoNKUa4zg9pdn3hZWDKV'});
      s = _feed(m, lines.skip(i + 1).take(3), s);
      expect(_diffs(s.toolCall('toolu_01JeAoNKUa4zg9pdn3hZWDKV')!), hasLength(1));
    });

    test('failures: a failing command and a missing file fail their rows and keep the error text', () {
      final (s, m) = _run('failing_tools');
      final bash = s.toolCall('toolu_01UHzMPA6jqbGCZ9Do4XqQN2')!;
      final read = s.toolCall('toolu_01GoEXLcHsYBtL5CiaZaKsoL')!;
      expect(bash.status, ToolStatus.failed);
      expect(_toolText(bash), contains('Command exited with code 2'));
      expect(read.status, ToolStatus.failed);
      expect(_toolText(read), "Path 'missing_file.txt' not found");
      expect(m.openToolCalls, isEmpty);
      expect(_texts(s, MessageRole.agent).single, contains('Both operations failed'));
    });

    test('todo: parallel calls and results end in the final plan; the reminder stays hidden', () {
      final (s, m) = _run('todo_plan');
      expect(s.plan.map((p) => (p.content, p.status)), [
        ('write code', PlanStatus.completed),
        ('run tests', PlanStatus.inProgress),
      ]);
      final todos = _tools(s);
      expect(todos, hasLength(3));
      expect(todos.map((t) => t.kind), everyElement(ToolKind.think));
      expect(todos.map((t) => t.status), everyElement(ToolStatus.completed));
      expect(todos.map((t) => t.title), ['Initialize plan with Work phase', 'Mark write code completed', 'Mark run tests in progress']);
      expect(_messages(s).any((x) => x.text.contains('system-reminder')), isFalse);
      expect(m.openToolCalls, isEmpty);
    });

    test('a todo whose abandoned and blocked tasks map to cancelled and pending', () {
      final m = OmpLogMapper();
      final s = _feed(m, [
        _result('r1', 'c1', 'todo', 'ok', details: {
          'phases': [
            {
              'name': 'A',
              'tasks': [
                {'content': 'x', 'status': 'abandoned'},
                {'content': 'y', 'status': 'blocked'},
                {'content': '', 'status': 'pending'},
              ],
            },
            {
              'name': 'B',
              'tasks': [
                {'content': 'z'},
              ],
            },
          ],
        }),
      ]);
      expect(s.plan.map((p) => (p.content, p.status)), [
        ('x', PlanStatus.cancelled),
        ('y', PlanStatus.pending),
        ('z', PlanStatus.pending),
      ]);
    });

    test('a todo result that failed leaves the plan alone', () {
      final m = OmpLogMapper();
      final s = _feed(m, [
        _result('r1', 'c1', 'todo', 'nope', error: true, details: {
          'phases': [
            {
              'name': 'A',
              'tasks': [
                {'content': 'x', 'status': 'pending'},
              ],
            },
          ],
        }),
      ]);
      expect(s.plan, isEmpty);
    });

    test('the log of a subagent maps unchanged: its assignment is the first message', () {
      final (s, m) = _run('subagent_log');
      expect(_texts(s, MessageRole.user).single, startsWith('Complete assignment thoroughly:'));
      final y = s.toolCall('toolu_01FeqsnBBfx5vbXJo39dDV5u')!;
      expect(y.name, 'yield');
      expect(y.status, ToolStatus.completed);
      expect(_toolText(y), 'Result submitted.');
      expect(m.openToolCalls, isEmpty);
    });
  });

  group('subagents and messages between agents', () {
    test('a generated task run: the row is a roster, the subagent ends completed', () {
      final (s, m) = _run('subagent_task');
      final task = s.toolCall('toolu_01PoKGLPkNkhnrYM4RyfuQbq')!;
      expect(task.kind, ToolKind.other);
      expect(task.status, ToolStatus.completed);
      expect(task.title, 'Subagents: PongReply');
      expect(_toolText(task), startsWith('PongReply (task): pending - Reply with the word pong'));
      expect(_toolText(task), isNot(contains('NEVER poll')));
      final info = m.subagents.single;
      expect(info.name, 'PongReply');
      expect(info.agent, 'task');
      expect(info.status, 'completed', reason: 'the wait result said so');
      expect(info.assignment, 'Reply with the word pong and do nothing else.');
      expect(info.toolCount, 0);
      expect(s.toolCall('toolu_01R4gZaVVy2GQhjUPAWr6EgF')!.name, 'wait');
    });

    test('two subagents, a message each way, a finished and a failed job', () {
      final lines = _lines('subagents_irc');
      final m = OmpLogMapper();
      final s = _feed(m, lines);
      final task = s.toolCall('call_task')!;
      expect(task.title, 'Subagents: Alpha, Beta');
      expect(_toolText(task).split('\n'), [
        'Alpha (task): running - Write the parser.',
        'Beta (explore): pending - Find the callers.',
      ]);
      expect(m.subagents.map((x) => x.name), ['Alpha', 'Beta']);
      final alpha = m.subagents[0];
      expect(alpha.status, 'completed', reason: 'async-result');
      expect(alpha.toolCount, 2);
      expect(alpha.recentTools, ['read', 'grep']);
      expect(alpha.assignment, 'Write the parser.\nUse records.');
      final beta = m.subagents[1];
      expect((beta.agent, beta.status), ('explore', 'failed'));

      expect(_texts(s, MessageRole.agent), [
        'this agent → Alpha: Please also add a unit test.',
        'Alpha → this agent: Parser is done, tests added.',
      ]);
      expect(s.toolCall('call_irc'), isNull, reason: 'a message to an agent is a note, not a tool row');
      expect(m.openToolCalls, isEmpty);
      expect(m.subagents.any((x) => x.name == 'bg_1'), isFalse);
    });

    test('a long assignment is cut to about 400 characters', () {
      final m = OmpLogMapper();
      m.map(
        _assistant('a1', [
          _call('c1', 'task', {
            'tasks': [
              {'name': 'Long', 'task': 'x' * 5000},
            ],
          }),
        ]),
      );
      expect(m.subagents.single.assignment.length, lessThanOrEqualTo(400));
      expect(m.subagents.single.assignment, endsWith('…'));
    });
  });

  group('the question tool', () {
    test('pending: questions, options, multi and the recommended index', () {
      final (s, m) = _run('ask_pending');
      final ask = m.pendingAsk!;
      expect(ask.toolCallId, 'toolu_ask_0001');
      expect(ask.questions, hasLength(2));
      final q1 = ask.questions[0];
      expect(q1.id, 'lang');
      expect(q1.question, 'Which language should the project use?');
      expect(q1.multi, isFalse);
      expect(q1.recommended, 0);
      expect(q1.options.map((o) => o.label), ['Dart', 'Rust', 'Go']);
      expect(q1.options.map((o) => o.description), ['Flutter app, shares code with the phone', 'Fast, more setup', '']);
      final q2 = ask.questions[1];
      expect((q2.id, q2.multi, q2.recommended), ('extras', true, 2));
      expect(m.openToolCalls, {'toolu_ask_0001'});

      final row = s.toolCall('toolu_ask_0001')!;
      expect(row.kind, ToolKind.other);
      expect(row.status, ToolStatus.inProgress);
      expect(row.title, 'Asking about the setup');
      expect((row.rawInput as Map)['questions'], hasLength(2));
    });

    test('the result clears it and completes the row', () {
      final lines = _lines('ask_answered');
      final m = OmpLogMapper();
      var s = _feed(m, lines.take(3));
      expect(m.pendingAsk, isNotNull);
      expect(m.pendingAsk!.questions.map((q) => q.options.length), [2, 2]);
      expect(m.pendingAsk!.questions[1].recommended, isNull);
      s = _feed(m, lines.skip(3), s);
      expect(m.pendingAsk, isNull);
      expect(m.openToolCalls, isEmpty);
      final row = s.toolCall('toolu_ask_0002')!;
      expect(row.status, ToolStatus.completed);
      expect(row.rawOutput, contains('lang: Dart'));
      expect(_texts(s, MessageRole.agent), ['Setting up my-project in Dart.']);
    });

    test('a failed result (cancelled dialog) clears it too', () {
      final m = OmpLogMapper();
      m.map(
        _assistant('a1', [
          _call('c1', 'ask', {
            'questions': [
              {
                'id': 'q',
                'question': 'Sure?',
                'options': [
                  {'label': 'Yes'},
                ],
              },
            ],
          }),
        ]),
      );
      expect(m.pendingAsk, isNotNull);
      final u = m.map(_result('r1', 'c1', 'ask', 'cancelled', error: true));
      expect(m.pendingAsk, isNull);
      expect(((u.single as ToolCallPatchUpdate).patch.fields['status']), 'failed');
    });

    test('a later user message clears it and cancels the row', () {
      final lines = _lines('ask_pending');
      final m = OmpLogMapper();
      var s = _feed(m, lines);
      expect(m.pendingAsk, isNotNull);
      s = _feed(m, [_user('typed', 'I answered in the terminal')], s);
      expect(m.pendingAsk, isNull);
      expect(m.openToolCalls, isEmpty);
      expect(s.toolCall('toolu_ask_0001')!.status, ToolStatus.cancelled);
    });

    test('hostile shapes: options as strings, out-of-range recommended, no id, no questions', () {
      final m = OmpLogMapper();
      m.map(
        _assistant('a1', [
          _call('c1', 'ask', {
            'questions': [
              {
                'question': 'Pick',
                'options': ['A', 'B', 7, {'nolabel': true}],
                'recommended': 9,
              },
              {
                'id': 'neg',
                'question': 'Neg',
                'options': ['A'],
                'recommended': -1,
              },
              'garbage',
            ],
          }),
        ]),
      );
      final ask = m.pendingAsk!;
      expect(ask.questions.map((q) => q.id), ['q0', 'neg']);
      expect(ask.questions[0].options.map((o) => o.label), ['A', 'B']);
      expect(ask.questions.map((q) => q.recommended), [null, null]);

      final empty = OmpLogMapper();
      empty.map(_assistant('a2', [_call('c2', 'ask', {'questions': []})]));
      expect(empty.pendingAsk, isNull);
      expect(empty.openToolCalls, {'c2'}, reason: 'the row still runs');
    });

    test('an assistant error or abort cancels the question', () {
      final m = OmpLogMapper();
      m.map(
        _assistant('a1', [
          _call('c1', 'ask', {
            'questions': [
              {
                'id': 'q',
                'question': 'Sure?',
                'options': ['Yes'],
              },
            ],
          }),
        ]),
      );
      m.map(_assistant('a2', [], stop: 'aborted'));
      expect(m.pendingAsk, isNull);
      expect(m.openToolCalls, isEmpty);
    });
  });

  group('housekeeping, errors, odd input', () {
    test('compaction, branch summary and a clear are quiet notes; the header title shows', () {
      final (s, _) = _run('compaction_branch');
      expect(s.title, 'Long running work');
      expect(_texts(s, MessageRole.user), ['First question', 'Second question', 'After the clear']);
      expect(_texts(s, MessageRole.agent), [
        'First answer',
        'Earlier messages were summarised',
        'Earlier messages were summarised',
        'The conversation was cleared on the host',
      ]);
      expect(s.items.map((i) => i is TranscriptMessage ? i.role.name : 't').toList(), [
        'user',
        'agent',
        'agent',
        'agent',
        'user',
        'agent',
        'user',
      ], reason: 'notes sit where they happened');
    });

    test('a failed turn says so with the error text; interrupted calls are cancelled', () {
      final (s, m) = _run('turn_error');
      final agent = _texts(s, MessageRole.agent);
      expect(agent, [
        'Starting the build.',
        'The turn failed: 529 overloaded_error: the model is overloaded, try again later',
      ]);
      expect(s.toolCall('toolu_build_0001')!.status, ToolStatus.cancelled);
      expect(s.toolCall('toolu_build_0002')!.status, ToolStatus.cancelled, reason: 'aborted');
      expect(m.openToolCalls, isEmpty);
    });

    test('an error without a message still says the turn failed', () {
      final m = OmpLogMapper();
      final u = m.map(_assistant('a1', [], stop: 'error'));
      final s = u.fold(const AgentSessionState('s'), (a, x) => a.apply(x));
      expect(_texts(s, MessageRole.agent), ['The turn failed.']);
    });

    test('odd entries: hidden ones stay hidden, shown ones show, nothing breaks', () {
      final (s, m) = _run('odd_entries');
      expect(_texts(s, MessageRole.user), [
        'A plain string user message',
        '/skill:tdd the parser',
        'Look at this screenshot\n[image: image/png]',
      ]);
      expect(_texts(s, MessageRole.agent), ['Visible answer'], reason: 'blank and redacted thinking are dropped');
      expect(_messages(s, MessageRole.thought), isEmpty);
      expect(s.title, 'Odd entries session');

      final runs = _tools(s).where((c) => c.toolCallId.startsWith('run:')).toList();
      expect(runs.map((c) => (c.title, c.status, c.kind)), [
        ('git status --short', ToolStatus.completed, ToolKind.execute),
        ('false', ToolStatus.failed, ToolKind.execute),
      ]);
      expect(_toolText(runs.first), ' M lib/a.dart\n');

      final orphan = s.toolCall('toolu_orphan_0001')!;
      expect((orphan.name, orphan.kind, orphan.status), ('read', ToolKind.read, ToolStatus.completed));
      expect(orphan.title, 'read');
      expect(_toolText(orphan), 'a result whose call this log never showed');

      final grep = s.toolCall('toolu_str_args')!;
      expect(grep.title, 'grep: src');
      expect((grep.rawInput as Map)['pattern'], 'needle', reason: 'arguments sent as a JSON string');
      expect(m.openToolCalls, {'toolu_str_args'});

      // The call with no id and the result with no call id are dropped.
      expect(_tools(s).map((c) => c.toolCallId), isNot(contains('')));
      expect(_tools(s), hasLength(runs.length + 2));
    });

    test('a line fed twice in a row (the duplicate in the log) shows once', () {
      final (s, _) = _run('odd_entries');
      expect(_texts(s, MessageRole.agent), ['Visible answer']);
    });

    test('unknown and malformed lines give nothing and never throw', () {
      final m = OmpLogMapper();
      final bad = [
        '',
        '   ',
        'not json',
        '{',
        '{"type":',
        '[1,2]',
        'null',
        '"s"',
        '42',
        '{}',
        '{"type":null}',
        '{"type":"message"}',
        '{"type":"message","message":[]}',
        '{"type":"message","message":{"role":5}}',
        '{"type":"message","message":{"role":"assistant","content":7}}',
        '{"type":"message","message":{"role":"assistant","content":[1,"x",null,{"type":"toolCall","id":5,"name":{}}]}}',
        '{"type":"message","message":{"role":"toolResult","toolCallId":3}}',
        '{"type":"message","message":{"role":"user","content":[{"type":"text","text":5}]}}',
        '{"type":"custom_message","attribution":"user","display":true,"content":{}}',
        '{"type":"custom","customType":"user_todo_edit","data":"x"}',
        '{"type":"compaction"}',
        '{"type":"title_change","title":5}',
        '{"type":"future","id":"zz","x":[1,2,3]}',
        '{"type":"message","message":{"role":"assistant","content":[]}}${'[' * 100000}',
        '{"type":"message","message":${'[' * 100000}',
      ];
      for (final line in bad) {
        expect(() => m.map(line), returnsNormally, reason: line.length > 80 ? 'long line' : line);
      }
      expect(m.openToolCalls, isEmpty);
      expect(m.pendingAsk, isNull);
    });

    test('0 and 1 entries', () {
      expect(_feed(OmpLogMapper(), const []).items, isEmpty);
      final s = _feed(OmpLogMapper(), [_user('only', 'hi')]);
      expect(_texts(s, MessageRole.user), ['hi']);
    });
  });

  group('edit modes, paths and kinds', () {
    test('replace-mode edit, multi-file result, failed write, read selector, other kinds', () {
      final (s, m) = _run('edit_modes');
      expect(m.openToolCalls, isEmpty);

      final read = s.toolCall('call_rd')!;
      expect(read.locations.single.path, '/work/proj/src/a.dart');
      expect(read.locations.single.line, 10);

      final rep = s.toolCall('call_rep')!;
      final rd = _diffs(rep).single;
      expect((rd.path, rd.oldText, rd.newText), ('/work/proj/src/b.dart', 'int x = 1;\nint y = 0;', 'int x = 2;\nint y = 0;'));
      expect(rep.locations.single.path, '/work/proj/src/b.dart');

      final multi = s.toolCall('call_multi')!;
      expect(multi.title, 'Editing two files');
      final md = _diffs(multi);
      expect(md.map((d) => (d.path, d.oldText, d.newText)), [
        ('/work/proj/src/c.dart', 'zero\n', 'one\n'),
        ('/work/proj/src/e.dart', null, 'brand new\n'),
      ], reason: 'the pruned file has no snapshot, so no diff');
      expect(multi.locations.map((l) => l.path), containsAll(['/work/proj/src/c.dart', '/work/proj/src/d.dart', '/work/proj/src/e.dart']));

      final wr = s.toolCall('call_wr')!;
      expect(wr.status, ToolStatus.failed);
      expect(_diffs(wr), isEmpty, reason: 'a failed write changed nothing');
      expect(_toolText(wr), startsWith('Error: permission denied'));

      final web = s.toolCall('call_web')!;
      expect((web.kind, web.title, web.status), (ToolKind.fetch, 'web_search: dart records', ToolStatus.completed));

      final py = _tools(s).singleWhere((c) => c.name == 'python');
      expect((py.name, py.title, py.kind, py.status), ('python', 'print(1+1)', ToolKind.execute, ToolStatus.completed));
      expect((py.rawInput as Map)['code'], 'print(1+1)\nprint(\'x\')');
    });

    test('the arguments of a replace edit already show the change while it runs', () {
      final lines = _lines('edit_modes');
      final m = OmpLogMapper();
      final s = _feed(m, lines.take(3));
      final rep = s.toolCall('call_rep')!;
      expect(rep.status, ToolStatus.inProgress);
      final d = _diffs(rep).single;
      expect((d.oldText, d.newText), ('int x = 1;', 'int x = 2;'));
      expect(m.openToolCalls, {'call_rd', 'call_rep', 'call_multi', 'call_wr', 'call_web'});
    });

    test('a path outside any cwd stays as it is; internal URLs give no location', () {
      final m = OmpLogMapper();
      final s = _feed(m, [
        _assistant('a1', [
          _call('c1', 'read', {'path': 'skill://tdd'}),
          _call('c2', 'read', {'path': 'rel/x.dart'}),
        ]),
      ]);
      expect(s.toolCall('c1')!.locations, isEmpty);
      expect(s.toolCall('c2')!.locations.single.path, 'rel/x.dart', reason: 'no session header, no cwd');
    });

    test('titles: the call\'s own words first, then what it works on', () {
      final m = OmpLogMapper();
      final s = _feed(m, [
        _assistant('a1', [
          _call('c1', 'bash', {'command': 'ls -la\necho second line'}),
          _call('c2', 'bash', {'command': 'x', 'i': 'Listing files'}),
          _call('c3', 'grep', {'pattern': 'foo'}),
          _call('c4', 'mystery', {}),
          _call('c5', 'bash', {'command': 'y' * 500}),
          _call('c6', 'edit', {'i': 'Multi\nline intent'}, intent: 'Multi\nline intent'),
        ]),
      ]);
      expect(s.toolCall('c1')!.title, 'ls -la');
      expect(s.toolCall('c2')!.title, 'Listing files');
      expect(s.toolCall('c3')!.title, 'grep: foo');
      expect(s.toolCall('c4')!.title, 'mystery');
      expect(s.toolCall('c5')!.title.length, 120);
      expect(s.toolCall('c5')!.title, endsWith('…'));
      expect(s.toolCall('c6')!.title, 'Multi');
    });
  });

  group('idempotence and reset', () {
    for (final name in _fixtures) {
      test('$name: the whole log fed twice, line by line twice, or overlapped, changes nothing', () {
        final lines = _lines(name);
        final once = _fingerprint(_feed(OmpLogMapper(), lines));

        final twiceSameMapper = OmpLogMapper();
        expect(_fingerprint(_feed(twiceSameMapper, [...lines, ...lines])), once, reason: 'replayed log, same mapper');

        final freshMapper = _feed(OmpLogMapper(), lines);
        expect(_fingerprint(_feed(OmpLogMapper(), lines, freshMapper)), once, reason: 'replayed log, new mapper');

        final doubled = _feed(OmpLogMapper(), [for (final l in lines) ...[l, l]]);
        expect(_fingerprint(doubled), once, reason: 'every line twice');

        // A resume that overlaps: the last few lines come again.
        final m = OmpLogMapper();
        var s = _feed(m, lines);
        s = _feed(m, lines.skip(lines.length > 4 ? lines.length - 4 : 0), s);
        expect(_fingerprint(s), once, reason: 'overlapping tail');
      });
    }

    test('a replayed older title, plan edit or exit does not undo the newer one', () {
      final lines = [
        _entry({'type': 'session', 'id': 'sess', 'cwd': '/w', 'title': 'First'}),
        _entry({'type': 'title_change', 'id': 't1', 'title': 'Second'}),
        _entry({
          'type': 'custom',
          'customType': 'user_todo_edit',
          'id': 'p1',
          'data': {
            'phases': [
              {
                'name': 'A',
                'tasks': [
                  {'content': 'old', 'status': 'pending'},
                ],
              },
            ],
          },
        }),
        _entry({
          'type': 'custom',
          'customType': 'user_todo_edit',
          'id': 'p2',
          'data': {
            'phases': [
              {
                'name': 'A',
                'tasks': [
                  {'content': 'new', 'status': 'completed'},
                ],
              },
            ],
          },
        }),
      ];
      final m = OmpLogMapper();
      var s = _feed(m, lines);
      s = _feed(m, lines, s);
      expect(s.title, 'Second');
      expect(s.plan.map((p) => p.content), ['new']);
    });

    test('the same mapper reports the same pending question and open calls after a replay', () {
      final m = OmpLogMapper();
      final lines = _lines('ask_pending');
      _feed(m, lines);
      _feed(m, lines);
      expect(m.pendingAsk!.toolCallId, 'toolu_ask_0001');
      expect(m.openToolCalls, {'toolu_ask_0001'});
    });

    test('reset forgets everything, and the log can be mapped again from the start', () {
      final m = OmpLogMapper();
      final lines = _lines('subagents_irc');
      final first = _fingerprint(_feed(m, lines));
      _feed(m, _lines('ask_pending'));
      expect(m.pendingAsk, isNotNull);
      m.reset();
      expect(m.pendingAsk, isNull);
      expect(m.openToolCalls, isEmpty);
      expect(m.subagents, isEmpty);
      expect(_fingerprint(_feed(m, lines)), first, reason: 'not suppressed as a duplicate');
      // The cwd is forgotten too: a relative path stays relative.
      m.reset();
      final s = _feed(m, [
        _assistant('a1', [
          _call('c1', 'read', {'path': 'x.dart'}),
        ]),
      ]);
      expect(s.toolCall('c1')!.locations.single.path, 'x.dart');
    });

    test('a result for a call whose start was missed names the call itself', () {
      final m = OmpLogMapper();
      final s = _feed(m, [_result('r1', 'c9', 'bash', 'out')]);
      final c = s.toolCall('c9')!;
      expect((c.name, c.kind, c.status), ('bash', ToolKind.execute, ToolStatus.completed));
    });
  });

  group('heavy data', () {
    test('5000 entries map in well under a second', () {
      final lines = <String>[];
      var n = 0;
      while (lines.length < 5000) {
        lines.add(_user('u$n', 'question $n'));
        lines.add(_assistant('a$n', [
          {'type': 'thinking', 'thinking': 'thinking about $n'},
          _call('call$n', 'bash', {'command': 'echo $n', 'i': 'Echoing $n'}),
        ], stop: 'toolUse'));
        lines.add(_result('r$n', 'call$n', 'bash', 'output $n\n${'line\n' * 20}'));
        lines.add(_assistant('b$n', [
          {'type': 'text', 'text': 'answer $n'},
        ]));
        n++;
      }
      final m = OmpLogMapper();
      final updates = <SessionUpdate>[];
      final sw = Stopwatch()..start();
      for (final l in lines) {
        updates.addAll(m.map(l));
      }
      sw.stop();
      // ignore: avoid_print
      print('mapped ${lines.length} entries into ${updates.length} updates in ${sw.elapsedMilliseconds} ms');
      expect(sw.elapsedMilliseconds, lessThan(1000));

      var s = const AgentSessionState('s');
      final reduce = Stopwatch()..start();
      for (final u in updates) {
        s = s.apply(u);
      }
      reduce.stop();
      // ignore: avoid_print
      print('the reducer folded them in ${reduce.elapsedMilliseconds} ms');
      expect(s.toolCalls.length, n);
      expect(_messages(s, MessageRole.user), hasLength(n));
      expect(m.openToolCalls, isEmpty);
      expect(s.toolCalls.every((c) => c.status == ToolStatus.completed), isTrue);
    });

    test('2 MB fields are cut with a visible marker and never blow up', () {
      final big = 'x' * (2 * 1024 * 1024);
      final lines = [
        _user('u1', big),
        _assistant('a1', [
          {'type': 'text', 'text': big},
          {'type': 'thinking', 'thinking': big},
          _call('w', 'write', {'path': 'big.txt', 'content': big, 'i': big}),
          _call('b', 'bash', {'command': big}),
          _call('e', 'edit', {'path': 'big.txt', 'old_string': big, 'new_string': big}),
        ], stop: 'toolUse'),
        _result('r1', 'w', 'write', big),
        _result('r2', 'b', 'bash', big, error: true),
        _result('r3', 'e', 'edit', 'ok', details: {'path': 'big.txt', 'oldText': big, 'newText': big}),
        _assistant('a2', [], stop: 'error').replaceFirst('"stopReason":"error"', '"stopReason":"error","errorMessage":"${'e' * 2000000}"'),
      ];
      final m = OmpLogMapper();
      final sw = Stopwatch()..start();
      final s = _feed(m, lines);
      sw.stop();
      // ignore: avoid_print
      print('2 MB fields: ${lines.length} lines mapped and reduced in ${sw.elapsedMilliseconds} ms');
      expect(sw.elapsedMilliseconds, lessThan(2000));

      const cap = OmpLogMapper.maxFieldChars;
      const mark = '\n... [cut]';
      for (final msg in _messages(s)) {
        expect(msg.text.length, lessThanOrEqualTo(cap + 300), reason: msg.role.name);
      }
      expect(_messages(s, MessageRole.user).single.text, endsWith(mark));
      expect(_messages(s, MessageRole.agent).first.text, endsWith(mark));
      final w = s.toolCall('w')!;
      expect(_diffs(w).single.newText.length, cap + mark.length);
      expect(_diffs(w).single.newText, endsWith(mark));
      expect(((w.rawInput as Map)['content'] as String).length, cap + mark.length);
      expect(_toolText(w), endsWith(mark));
      expect(_toolText(s.toolCall('b')!), endsWith(mark));
      expect(s.toolCall('b')!.status, ToolStatus.failed);
      final e = _diffs(s.toolCall('e')!).single;
      expect((e.oldText!.length, e.newText.length), (cap + mark.length, cap + mark.length));
      expect(s.toolCall('b')!.title.length, lessThanOrEqualTo(120));
    });

    test('a text shorter than the cap is left untouched (the host\'s own cut stays as it was)', () {
      final text = '${'y' * 16000}\n... [cut by host]';
      final s = _feed(OmpLogMapper(), [_user('u1', text)]);
      expect(_texts(s, MessageRole.user).single, text);
    });

    test('a cut never splits a surrogate pair', () {
      final text = 'a${'😀' * 30000}';
      final s = _feed(OmpLogMapper(), [_user('u1', text)]);
      final shown = _texts(s, MessageRole.user).single;
      expect(shown, endsWith('\n... [cut]'));
      final body = shown.substring(0, shown.length - '\n... [cut]'.length);
      expect(body.runes.every((r) => r < 0xD800 || r > 0xDFFF), isTrue);
      expect(body.runes.length, greaterThan(9000));
    });

    test('unicode survives: RTL, combining marks, zero-width, emoji', () {
      const text = 'שלום עולם \u0301e\u200b👩‍👩‍👧 日本語';
      final s = _feed(OmpLogMapper(), [_user('u1', text)]);
      expect(_texts(s, MessageRole.user).single, text);
    });
  });

  group('background work (OmpLogMapper.backgroundTasks, turnEnded)', () {
    BackgroundTask task(OmpLogMapper m, String key) => m.backgroundTasks.firstWhere((t) => t.key == key);
    Map<String, BackgroundStatus> statuses(OmpLogMapper m) => {for (final t in m.backgroundTasks) t.key: t.status};

    // A real excerpt (test/fixtures/omp_logs/background_jobs.jsonl, trimmed):
    // 0 call, 1 start, 2 async-result: bg_1 (bash, 300 s limit);
    // 3 call, 4 start: a `task` with three subagents, 5 and 6 `wait` results
    // that settle two of them; 7 session_exit; 8 call, 9 start, 10 async-result
    // that says it timed out (bg_4, new process); 11 call, 12 start, 13 `wait`,
    // 14 assistant `stop`: bg_6 (no limit) runs on while the turn is over.
    group('real excerpt', () {
      final lines = _lines('background_jobs');

      test('a bash job starts at the result, with the command of its call, and ends at its async-result', () {
        final m = OmpLogMapper();
        _feed(m, lines.take(2));
        final t = m.backgroundTasks.single;
        expect((t.key, t.kind, t.status, t.stop), ('0/bg_1', BackgroundKind.shell, BackgroundStatus.running, StopRoute.message));
        expect(t.title, startsWith('export RSRCH_MODEL=claude-opus-5-5 RSRCH_AGENT=claude-code; ./rsrch paper'));
        expect(t.title.length, lessThanOrEqualTo(120));
        expect(t.detail, contains('nvidia-smi'));
        expect(t.deadline, const Duration(seconds: 300));
        expect(t.startedAt, DateTime.utc(2026, 10, 2, 23, 35, 23, 245));
        expect(t.toolCallId, 'toolu_014V3g1teZCXYtqDDQB8pPjU');
        expect(m.turnEnded, isFalse);

        _feed(m, lines.skip(2).take(1));
        final done = m.backgroundTasks.single;
        expect(done.status, BackgroundStatus.finished);
        expect(done.endedAt, isNotNull);
        expect(done.isActive, isFalse);
        expect(done.stop, StopRoute.none);
        expect(m.turnEnded, isFalse, reason: 'an async-result starts a turn');
      });

      test('a task call adds every subagent of its progress; the wait results settle them one by one', () {
        final m = OmpLogMapper();
        _feed(m, lines.take(5));
        expect(statuses(m), {
          '0/bg_1': BackgroundStatus.finished,
          '0/RLFrameworks': BackgroundStatus.running,
          '0/SFTStacks': BackgroundStatus.running,
          '0/PapersUse': BackgroundStatus.running,
        });
        final rl = task(m, '0/RLFrameworks');
        expect((rl.kind, rl.title, rl.stop), (BackgroundKind.agent, 'RLFrameworks', StopRoute.message));
        expect(rl.detail, startsWith('# Target'));
        expect(rl.detail!.length, lessThanOrEqualTo(400));
        expect(m.subagents.map((s) => s.name), ['RLFrameworks', 'SFTStacks', 'PapersUse'], reason: 'still a subagent too');

        _feed(m, lines.skip(5).take(1));
        expect(statuses(m)['0/PapersUse'], BackgroundStatus.finished);
        expect(statuses(m)['0/RLFrameworks'], BackgroundStatus.running, reason: 'a running job stays');
        _feed(m, lines.skip(6).take(1));
        expect(statuses(m)['0/SFTStacks'], BackgroundStatus.finished);
        expect(statuses(m)['0/RLFrameworks'], BackgroundStatus.running);
      });

      test('session_exit stops what ran and the next process starts a new epoch (bg_4 may be reused)', () {
        final m = OmpLogMapper();
        _feed(m, lines.take(8));
        final rl = task(m, '0/RLFrameworks');
        expect(rl.status, BackgroundStatus.stopped);
        expect(rl.endedAt, DateTime.utc(2026, 10, 3, 15, 25, 24, 570));
        expect(m.backgroundTasks.where((t) => t.isActive), isEmpty);

        _feed(m, lines.skip(8).take(3));
        expect(task(m, '1/bg_4').status, BackgroundStatus.failed, reason: '"Command timed out after 3000 seconds"');
        expect(task(m, '1/bg_4').deadline, const Duration(seconds: 3000));
      });

      test('the whole log: bg_6 outlives the turn that ended with stop', () {
        final m = OmpLogMapper();
        _feed(m, lines.take(14));
        expect(m.turnEnded, isFalse, reason: 'the wait result came last');
        expect(m.backgroundTasks.where((t) => t.isActive).map((t) => t.key), ['1/bg_6']);
        _feed(m, lines.skip(14));
        expect(m.turnEnded, isTrue);
        final running = m.backgroundTasks.where((t) => t.isActive).toList();
        expect(running.map((t) => t.key), ['1/bg_6']);
        expect(running.single.deadline, isNull, reason: 'timeoutDisabled');
        expect(running.single.title, startsWith('F=data/coder2b/'));
        expect(running.single.startedAt, DateTime.utc(2026, 10, 5, 6, 26, 42, 445));
        expect(m.backgroundTasks.length, 6, reason: 'bg_1, three subagents, bg_4, bg_6');
        expect(identical(m.backgroundTasks, m.backgroundTasks), isTrue, reason: 'cached until a change');
      });

      test('replayed and overlapped lines change nothing, reset forgets all', () {
        final m = OmpLogMapper();
        _feed(m, lines);
        final once = m.backgroundTasks;
        _feed(m, lines);
        expect(m.backgroundTasks, once);
        _feed(m, lines.skip(lines.length - 4));
        expect(m.backgroundTasks, once);
        expect(m.turnEnded, isTrue);
        m.reset();
        expect(m.backgroundTasks, isEmpty);
        expect(m.turnEnded, isFalse);
        _feed(m, lines);
        expect(m.backgroundTasks, once, reason: 'the same epochs and statuses after a rebuild');
      });
    });

    // Hand-written entries in the shapes the real log has.
    const t0 = '2026-10-05T10:00:00.000Z';

    String call(String id, String callId, String name, Json args) => _assistant(id, [_call(callId, name, args)], stop: 'toolUse');

    String start(String id, String callId, String job, {String tool = 'bash', String type = 'bash', Object? timeout, String? at = t0, List<String>? agents}) =>
        _entry({
          'type': 'message',
          'id': id,
          'timestamp': ?at,
          'message': {
            'role': 'toolResult',
            'toolCallId': callId,
            'toolName': tool,
            'content': [
              {'type': 'text', 'text': 'Backgrounded as job $job'},
            ],
            'details': {
              'async': {'state': 'running', 'jobId': job, 'type': type},
              'timeoutSeconds': ?timeout,
              if (agents != null) 'progress': [for (final a in agents) {'id': a, 'status': 'pending'}],
            },
            'isError': false,
          },
        });

    String finished(String id, List<String> jobs, {String text = 'done', String? at, Map<String, String> status = const {}}) => _entry({
      'type': 'custom_message',
      'id': id,
      'customType': 'async-result',
      'content': '<system-notice>\n${jobs.length == 1 ? 'Background job ${jobs.single} has completed.' : '${jobs.length} background jobs have completed.'}\n$text\n</system-notice>',
      'details': {
        'jobs': [
          for (final j in jobs) {'jobId': j, 'type': 'bash', 'label': j, 'durationMs': 5, 'status': ?status[j]},
        ],
      },
      'timestamp': ?at,
    });

    String wait(String id, Map<String, String> jobs, {String tool = 'wait'}) => _result(
      id,
      'w$id',
      tool,
      '## Completed',
      details: {
        'op': 'wait',
        'jobs': [for (final e in jobs.entries) {'id': e.key, 'type': 'bash', 'status': e.value}],
      },
    );

    test('eval jobs take the title from the code; no timestamp means no start; a limit of 0 or less is none', () {
      final m = OmpLogMapper();
      _feed(m, [
        call('a1', 'c1', 'eval', {'code': '\n  import time\ntime.sleep(900)'}),
        start('r1', 'c1', 'bg_1', tool: 'eval', type: 'eval', at: null, timeout: 0),
      ]);
      final t = m.backgroundTasks.single;
      expect((t.kind, t.title, t.startedAt, t.deadline), (BackgroundKind.eval, 'import time', null, null));
      expect(t.detail, contains('time.sleep(900)'));
      expect(t.pastDeadline(DateTime.utc(2030)), isFalse);
    });

    test('a job whose call was not seen (a log followed from the middle) is titled by its id', () {
      final m = OmpLogMapper();
      _feed(m, [start('r1', 'c1', 'bg_9')]);
      final t = m.backgroundTasks.single;
      expect((t.title, t.detail), ('bg_9', null));
    });

    test('a deadline: the timeout from the result plus the grace expires a stale task, never a fresh one', () {
      final m = OmpLogMapper();
      _feed(m, [
        call('a1', 'c1', 'bash', {'command': 'sleep 99'}),
        start('r1', 'c1', 'bg_1', timeout: 120),
      ]);
      final t = m.backgroundTasks.single;
      final started = DateTime.utc(2026, 10, 5, 10);
      expect(t.startedAt, started);
      expect(t.pastDeadline(started.add(const Duration(seconds: 179))), isFalse);
      expect(t.pastDeadline(started.add(const Duration(seconds: 181))), isTrue);
      expect(t.copyWith(status: BackgroundStatus.finished).pastDeadline(started.add(const Duration(days: 1))), isFalse);
    });

    test('ids restart with the process: bg_1 before and after session_exit are two tasks', () {
      final m = OmpLogMapper();
      _feed(m, [
        call('a1', 'c1', 'bash', {'command': 'first'}),
        start('r1', 'c1', 'bg_1'),
        _entry({'type': 'custom', 'customType': 'session_exit', 'id': 'x1', 'timestamp': t0, 'data': {'reason': 'sighup'}}),
        call('a2', 'c2', 'bash', {'command': 'second'}),
        start('r2', 'c2', 'bg_1'),
      ]);
      expect(m.backgroundTasks.map((t) => (t.key, t.title, t.status)), [
        ('0/bg_1', 'first', BackgroundStatus.stopped),
        ('1/bg_1', 'second', BackgroundStatus.running),
      ]);
      _feed(m, [finished('f1', ['bg_1'])]);
      expect(statuses(m), {'0/bg_1': BackgroundStatus.stopped, '1/bg_1': BackgroundStatus.finished}, reason: 'the notice is for the new process');
    });

    test('a kill the model issued: details.proc.cancelled, and the text when the details are missing', () {
      final m = OmpLogMapper();
      _feed(m, [
        start('r1', 'c1', 'bg_1'),
        start('r2', 'c2', 'bg_2'),
        start('r3', 'c3', 'bg_3'),
        _result(
          'k1',
          'k1c',
          'write',
          '## Cancelled (1)\n\n- Cancelled background job bg_1.',
          details: {
            'proc': {
              'op': 'cancel',
              'jobs': [
                {'id': 'bg_1', 'type': 'bash', 'status': 'cancelled'},
              ],
              'cancelled': [
                {'id': 'bg_1', 'status': 'cancelled'},
              ],
            },
          },
        ),
        _result('k2', 'k2c', 'write', 'Cancelled background job bg_2.\n'),
        _result('k3', 'k3c', 'write', 'Cancelled background job bg_3 later'),
      ]);
      expect(statuses(m), {
        '0/bg_1': BackgroundStatus.stopped,
        '0/bg_2': BackgroundStatus.stopped,
        '0/bg_3': BackgroundStatus.running,
      }, reason: 'only a full "Cancelled background job <id>." sentence counts');
      expect(m.backgroundTasks.first.stop, StopRoute.none);
    });

    test('a stop that found the job done is finished, not stopped; a read of proc:// does not settle a running one', () {
      final m = OmpLogMapper();
      _feed(m, [
        start('r1', 'c1', 'bg_1'),
        start('r2', 'c2', 'bg_2'),
        _result('k1', 'k1c', 'write', 'x', details: {
          'proc': {
            'cancelled': [
              {'id': 'bg_1', 'status': 'already_completed'},
              {'id': 'bg_zzz', 'status': 'not_found'},
            ],
          },
        }),
        _result('p1', 'p1c', 'read', 'x', details: {
          'proc': {
            'job': {'id': 'bg_2', 'status': 'running'},
          },
        }),
      ]);
      expect(statuses(m), {'0/bg_1': BackgroundStatus.finished, '0/bg_2': BackgroundStatus.running});
    });

    test('wait results settle with the status they carry; running ones and unknown ids change nothing', () {
      final m = OmpLogMapper();
      _feed(m, [
        start('r1', 'c1', 'bg_1'),
        start('r2', 'c2', 'bg_2'),
        start('r3', 'c3', 'bg_3'),
        start('r4', 'c4', 'bg_4'),
        wait('w1', {'bg_1': 'failed', 'bg_2': 'cancelled', 'bg_3': 'running', 'bg_99': 'completed'}),
      ]);
      expect(statuses(m), {
        '0/bg_1': BackgroundStatus.failed,
        '0/bg_2': BackgroundStatus.stopped,
        '0/bg_3': BackgroundStatus.running,
        '0/bg_4': BackgroundStatus.running,
      });
      _feed(m, [wait('w2', {'bg_3': 'completed'}, tool: 'read')]);
      expect(statuses(m)['0/bg_3'], BackgroundStatus.finished);
    });

    test('an async-result without a status: the text decides failed, one notice with several jobs by section', () {
      final m = OmpLogMapper();
      _feed(m, [
        for (var i = 1; i <= 5; i++) start('r$i', 'c$i', 'bg_$i'),
        finished('f1', ['bg_1'], text: 'tests failed: 3\n'),
        finished('f2', ['bg_2'], text: '[Command timed out after 180 seconds]'),
        finished('f3', ['bg_3'], text: 'exit\nCommand exited with code 2'),
        _entry({
          'type': 'custom_message',
          'id': 'f4',
          'customType': 'async-result',
          'content':
              '<system-notice>\n2 background jobs have completed.\n\n── Job bg_4 (ok) ──\nall good\n── Job bg_5 (bad) ──\nCommand exited with code 1\n</system-notice>',
          'details': {
            'jobs': [
              {'jobId': 'bg_4', 'type': 'bash'},
              {'jobId': 'bg_5', 'type': 'bash'},
            ],
          },
        }),
      ]);
      expect(statuses(m), {
        '0/bg_1': BackgroundStatus.finished,
        '0/bg_2': BackgroundStatus.failed,
        '0/bg_3': BackgroundStatus.failed,
        '0/bg_4': BackgroundStatus.finished,
        '0/bg_5': BackgroundStatus.failed,
      });
    });

    test('an async-result that carries a status (a subagent) uses it; "running" is not an end', () {
      final m = OmpLogMapper();
      _feed(m, [
        start('r1', 'c1', 'A', tool: 'task', type: 'task', agents: ['A', 'B', 'C']),
        _entry({
          'type': 'custom_message',
          'id': 'f1',
          'customType': 'async-result',
          'content': 'x',
          'details': {
            'jobs': [
              {'jobId': 'A', 'type': 'task', 'status': 'failed'},
              {'jobId': 'B', 'type': 'task', 'status': 'running'},
              {'jobId': 'C', 'type': 'task', 'status': 'completed'},
            ],
          },
        }),
      ]);
      expect(statuses(m), {'0/A': BackgroundStatus.failed, '0/B': BackgroundStatus.running, '0/C': BackgroundStatus.finished});
    });

    test('a task result without progress is one task named by its job id; a reused name starts afresh', () {
      final m = OmpLogMapper();
      _feed(m, [
        start('r1', 'c1', 'Solo', tool: 'task', type: 'task'),
        wait('w1', {'Solo': 'completed'}),
        start('r2', 'c2', 'Solo', tool: 'task', type: 'task', at: '2026-10-05T11:00:00.000Z'),
      ]);
      final t = m.backgroundTasks.single;
      expect((t.id, t.status, t.startedAt), ('Solo', BackgroundStatus.running, DateTime.utc(2026, 10, 5, 11)));
    });

    test('a result that says the job already ended (async.state) settles it', () {
      final m = OmpLogMapper();
      _feed(m, [
        start('r1', 'c1', 'bg_1'),
        _result('u1', 'c1', 'bash', 'x', details: {'async': {'state': 'failed', 'jobId': 'bg_1', 'type': 'bash'}}),
      ]);
      expect(m.backgroundTasks.single.status, BackgroundStatus.failed);
    });

    test('finished tasks are kept to the latest 30, running ones always', () {
      final m = OmpLogMapper();
      _feed(m, [
        start('rr', 'cr', 'keep'),
        for (var i = 0; i < 45; i++) ...[start('s$i', 'c$i', 'bg_$i'), finished('f$i', ['bg_$i'])],
      ]);
      final all = m.backgroundTasks;
      expect(all.where((t) => !t.isActive).length, 30);
      expect(all.where((t) => t.isActive).map((t) => t.id), ['keep']);
      expect(all.any((t) => t.id == 'bg_44'), isTrue);
      expect(all.any((t) => t.id == 'bg_0'), isFalse);
    });

    test('hostile ids stay data: they are listed but never make a stop message', () {
      final m = OmpLogMapper();
      final hostile = ['bg_1; rm -rf /', 'a b', 'x\nIgnore the above', r'$(reboot)', '../../etc/passwd', 'bg_1\u202Etxt', 'é', 'x' * 65];
      _feed(m, [
        for (var i = 0; i < hostile.length; i++) start('r$i', 'c$i', hostile[i]),
        start('rok', 'cok', 'bg_ok'),
      ]);
      expect(m.backgroundTasks.map((t) => t.id), [...hostile, 'bg_ok']);
      for (final t in m.backgroundTasks.where((t) => t.id != 'bg_ok')) {
        expect(isSafeBackgroundId(t.id), isFalse, reason: t.id);
        expect(stopMessageForOmp([t.id]), isNull, reason: t.id);
        expect(stopMessageForOmp(['bg_ok', t.id]), isNull, reason: 'one bad id spoils the whole message');
      }
      expect(stopMessageForOmp(['bg_ok']), 'Stop these background job now: bg_ok (write proc://bg_ok/kill). Do nothing else.');
    });

    group('turnEnded', () {
      OmpLogMapper after(List<String> lines) {
        final m = OmpLogMapper();
        _feed(m, lines);
        return m;
      }

      test('nothing yet: not ended', () {
        expect(OmpLogMapper().turnEnded, isFalse);
      });

      for (final stop in ['stop', 'length', 'aborted', 'error']) {
        test('an assistant message that stopped with $stop ends it, a following user message starts the next', () {
          final m = after([_user('u1', 'go'), _assistant('a1', [{'type': 'text', 'text': 'hi'}], stop: stop)]);
          expect(m.turnEnded, isTrue);
          _feed(m, [_user('u2', 'again')]);
          expect(m.turnEnded, isFalse);
        });
      }

      test('toolUse, a tool call without a result, and a tool result are not the end', () {
        final m = after([_user('u1', 'go'), _assistant('a1', [_call('c1', 'bash', {'command': 'ls'})], stop: 'toolUse')]);
        expect(m.turnEnded, isFalse);
        _feed(m, [_result('r1', 'c1', 'bash', 'out')]);
        expect(m.turnEnded, isFalse);
        _feed(m, [_assistant('a2', [{'type': 'text', 'text': 'done'}])]);
        expect(m.turnEnded, isTrue);
      });

      test('a stop with a call still open is not the end; an abort cancels the call and is', () {
        final open = after([_assistant('a1', [_call('c1', 'bash', {'command': 'ls'})])]);
        expect(open.openToolCalls, {'c1'});
        expect(open.turnEnded, isFalse);
        final aborted = after([_assistant('a1', [_call('c1', 'bash', {'command': 'ls'})], stop: 'aborted')]);
        expect(aborted.openToolCalls, isEmpty);
        expect(aborted.turnEnded, isTrue);
      });

      test('an async-result starts a turn; the assistant message after it ends that one', () {
        final m = after([
          start('r1', 'c1', 'bg_1'),
          _assistant('a1', [{'type': 'text', 'text': 'waiting for bg_1'}]),
        ]);
        expect(m.turnEnded, isTrue);
        _feed(m, [finished('f1', ['bg_1'])]);
        expect(m.turnEnded, isFalse);
        _feed(m, [_assistant('a2', [{'type': 'text', 'text': 'it finished'}])]);
        expect(m.turnEnded, isTrue);
      });

      test('a skill prompt the person started begins a turn; a nudge for the model does not', () {
        final m = after([_assistant('a1', [{'type': 'text', 'text': 'ok'}])]);
        _feed(m, [
          _entry({'type': 'custom_message', 'id': 'n1', 'customType': 'mid-run-todo-nudge', 'content': 'x', 'display': false}),
        ]);
        expect(m.turnEnded, isTrue);
        _feed(m, [
          _entry({'type': 'custom_message', 'id': 'n2', 'customType': 'skill-prompt', 'content': 'go', 'display': true, 'attribution': 'user', 'details': {'name': 'tdd'}}),
        ]);
        expect(m.turnEnded, isFalse);
      });

      test('a replayed older line does not flip it back', () {
        final lines = [_user('u1', 'go'), _assistant('a1', [{'type': 'text', 'text': 'hi'}])];
        final m = after(lines);
        _feed(m, [lines.first]);
        expect(m.turnEnded, isTrue);
      });
    });
  });
}
