// Subagents of OpenCode, Copilot, Cursor, Kimi, Hermes and DeepSeek in the
// reducer. OpenCode 2.2.7 is a real recorded session (`traces/opencode/subagent`);
// the rest are shapes from each agent's source or docs, written as literals and
// marked UNVERIFIED (no recorded session: not installed, not logged in, or the
// agent's ACP server is closed source). `docs/AGENT_SESSIONS.md`, "Subagents of
// the other routes", says where each shape comes from.
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/acp/subagents/run_facts.dart';
import 'package:herdr_mobile/data/acp/subagents/subagent_run.dart';

import 'support/trace_state.dart';

SessionUpdate _u(Json json) => SessionUpdate.parse(json);

AgentSessionState _fold(Iterable<Json> updates, [AgentSessionState? from]) =>
    updates.fold(from ?? const AgentSessionState('root'), (s, j) => s.apply(_u(j)));

Json _call(
  String id, {
  required String title,
  String kind = 'other',
  String status = 'pending',
  Object? input,
  String? name,
  Json? meta,
}) => {
  'sessionUpdate': 'tool_call',
  'toolCallId': id,
  'name': ?name,
  'title': title,
  'kind': kind,
  'status': status,
  'rawInput': input ?? <String, Object?>{},
  '_meta': ?meta,
};

Json _patch(String id, {String? status, String? title, Object? input, Object? output, String? text, Json? meta}) => {
  'sessionUpdate': 'tool_call_update',
  'toolCallId': id,
  'status': ?status,
  'title': ?title,
  'rawInput': ?input,
  'rawOutput': ?output,
  'content': ?(text == null
      ? null
      : [
          {
            'type': 'content',
            'content': {'type': 'text', 'text': text},
          },
        ]),
  '_meta': ?meta,
};

Json _chunk(String text, {String id = 'm', Json? meta, String kind = 'agent_message_chunk'}) => {
  'sessionUpdate': kind,
  'messageId': id,
  'content': {'type': 'text', 'text': text},
  '_meta': ?meta,
};

Json _oc(String child, {String parent = 'root', int depth = 1, String? title}) => {
  'opencode/child-session': {'id': child, 'parentID': parent, 'depth': depth, 'title': title ?? 'child $child'},
};

Json _copilot(String agentId) => {
  'github.com/copilot': {'agentId': agentId},
};

Map<String, Object?> _facts(SubagentRun r) => {
  'id': r.id,
  'title': r.title,
  'agentType': r.agentType,
  'assignment': r.assignment,
  'status': r.status,
  'result': r.result,
  'note': r.note,
  'toolCount': r.toolCount,
  'route': r.route,
};

PermissionRequest _permission(String toolCallId, {Json? meta}) => PermissionRequest.parse({
  'sessionId': 'root',
  'toolCall': {'toolCallId': toolCallId, 'title': 'ls', '_meta': ?meta},
  'options': [
    {'optionId': 'once', 'name': 'Allow once', 'kind': 'allow_once'},
  ],
});

/// What the agent said in [items] (thoughts and the user's messages left out).
List<String> _said(List<TranscriptItem> items) => [
  for (final i in items)
    if (i is TranscriptMessage && i.role == MessageRole.agent) i.text,
];

void main() {
  group('opencode/subagent (recorded, OpenCode 2.2.7)', () {
    test('the child\'s shell call and its text stay out of the main transcript', () {
      final s = stateOfTrace('opencode', 'subagent');
      expect(s.items.whereType<TranscriptTool>().map((t) => t.call.name), [
        'subagent',
      ], reason: 'the launcher row stays');
      final said = [
        for (final i in s.items)
          if (i is TranscriptMessage && i.role == MessageRole.agent) i.text,
      ];
      expect(said.join(), isNot(contains('Here are the exact file names')), reason: 'that is the child talking');
      expect(said.join(), contains('README.md, notes.txt, src'));
    });

    test('one run for the launching call, with its fields, its result without the wrapper and a transcript', () {
      final s = stateOfTrace('opencode', 'subagent');
      final run = s.subagents.single;
      expect(run.route, SubagentRoute.opencode);
      expect(run.id, s.items.whereType<TranscriptTool>().single.call.toolCallId);
      expect(run.title, 'List files with ls');
      expect(run.agentType, 'general');
      expect(run.assignment, isNotEmpty);
      expect(run.status, SubagentStatus.finished);
      expect(run.result, startsWith('Here are the exact file names listed by `ls`'));
      expect(run.result, isNot(contains('<subagent')));
      expect(run.result, contains('README.md\nnotes.txt\nsrc'));
      expect(run.hasTranscript, isTrue);
      final tool = run.items.whereType<TranscriptTool>().single.call;
      expect(tool.toolCallId, contains(':call_'), reason: 'child call ids are prefixed with the child session');
      expect(tool.status, ToolStatus.completed);
      expect(_said(run.items), hasLength(2), reason: 'the child spoke before and after its call');
      expect(_said(run.items).last, contains('README.md'));
      expect(run.toolCount, 1);
      expect(s.subagentsOfToolCall(run.id), [run]);
    });

    test('replay (session/load) builds the same run', () {
      final live = stateOfTrace('opencode', 'subagent');
      final replay = replayOfTrace('opencode', 'subagent');
      expect(replay.subagents.map(_facts), live.subagents.map(_facts));
      expect(replay.subagents.single.startedAt, isNull);
    });
  });

  group('kimi/subagent (recorded, kimi-code 2.5.3 on an OpenAI-compatible endpoint)', () {
    test('one run for the Agent call: its description, the type that ran, the summary as the result', () {
      final run = stateOfTrace('kimi', 'subagent').subagents.single;
      expect(run.route, SubagentRoute.kimi);
      expect(run.status, SubagentStatus.finished);
      expect(run.title, isNotEmpty);
      expect(run.agentType, 'explore');
      expect(run.result, contains('README.md'));
      expect(run.result, isNot(contains('agent_id:')), reason: 'the summary, without the header lines');
      expect(run.hasTranscript, isFalse);
    });

    test('the subagent\'s approval names it, though nothing in the request does', () {
      final s = stateOfTrace('kimi', 'subagent', stopAtPermission: true);
      final pending = s.pending.single as PendingPermission;
      expect(s.toolCall(pending.request.toolCall.toolCallId), isNull, reason: 'the child\'s call was never sent');
      expect(pending.origin, isNotNull);
      expect(pending.origin!.id, s.subagents.single.id);
    });

    test('with two running, an unknown call names neither; a call of the main agent never names one', () {
      var s = _fold([
        _call(
          'k1',
          title: 'Launching explore agent: a',
          input: {'prompt': 'p', 'description': 'a'},
          status: 'in_progress',
        ),
        _call(
          'k2',
          title: 'Launching explore agent: b',
          input: {'prompt': 'p', 'description': 'b'},
          status: 'in_progress',
        ),
        _call('main_call', title: 'Bash', kind: 'execute'),
      ]);
      s = s.withPending(PendingPermission(1, _permission('unknown_child_call')));
      expect(s.pendingById(1)!.origin, isNull, reason: 'ambiguous');
      s = s.withPending(PendingPermission(2, _permission('main_call')));
      expect(s.pendingById(2)!.origin, isNull);
    });

    test('replay builds the same run', () {
      expect(
        replayOfTrace('kimi', 'subagent').subagents.map(_facts),
        stateOfTrace('kimi', 'subagent').subagents.map(_facts),
      );
    });
  });

  group('hermes/subagent (recorded, Hermes 2026.9.24 on an OpenAI-compatible endpoint)', () {
    test('one run for the delegate_task call: a background dispatch, not a result, and what it was asked is kept', () {
      final s = stateOfTrace('hermes', 'subagent');
      final run = s.subagents.single;
      expect(run.route, SubagentRoute.hermes);
      expect(run.status, SubagentStatus.finished);
      expect(run.note, startedInBackgroundNote);
      expect(run.result, isNull, reason: 'the call ended with the dispatch JSON');
      expect(run.title, startsWith('Delegating'));
      expect(run.assignment, isNot(contains('dispatched')), reason: 'the dispatch JSON is not what was asked');
      expect(run.hasTranscript, isFalse);
    });

    test('what the subagent found comes back as the agent\'s own later message', () {
      final said = _said(stateOfTrace('hermes', 'subagent').items);
      expect(said.last, contains('README.md'));
    });

    test('replay builds the same run', () {
      expect(
        replayOfTrace('hermes', 'subagent').subagents.map(_facts),
        stateOfTrace('hermes', 'subagent').subagents.map(_facts),
      );
    });
  });

  group('opencode shapes (UNVERIFIED beyond the recorded one)', () {
    Json launcher(String id, {String status = 'in_progress'}) => _patch(
      id,
      status: status,
      title: 'subagent',
      input: {'agent': 'explore', 'description': 'Look at $id', 'prompt': 'Do $id'},
    );

    test('a launcher whose child never speaks has no conversation to open; it gets one when the child speaks', () {
      var s = _fold([
        _call('a', title: 'subagent', kind: 'think', name: 'subagent'),
        launcher('a'),
        _patch('a', status: 'completed', text: 'done'),
      ]);
      expect(s.subagentRun('a')!.hasTranscript, isFalse, reason: 'the summary is the thing to open');
      s = _fold([
        _call('b', title: 'subagent', kind: 'think', name: 'subagent'),
        launcher('b'),
        _chunk(
          'hello',
          id: 'x',
          meta: _oc('ses_1', title: 'Look at b'),
        ),
      ], s);
      expect(s.subagentRun('b')!.hasTranscript, isTrue);
    });

    test('1.x `task`: a launcher by its input, no tagged children, wrapped result', () {
      final s = _fold([
        _call('t1', title: 'task', kind: 'think'),
        _patch(
          't1',
          status: 'in_progress',
          title: 'List files',
          input: {'description': 'List files', 'prompt': 'Run ls', 'subagent_type': 'general'},
        ),
        _patch(
          't1',
          status: 'completed',
          text: '<task id="ses_a" state="completed">\n<task_result>\nREADME.md\n</task_result>\n</task>',
          output: {
            'metadata': {'sessionId': 'ses_a'},
          },
        ),
      ]);
      final run = s.subagents.single;
      expect(run.route, SubagentRoute.opencode);
      expect(run.title, 'List files');
      expect(run.agentType, 'general');
      expect(run.status, SubagentStatus.finished);
      expect(run.result, 'README.md');
      expect(s.subagentBook.aliases, {'ses_a': 't1'}, reason: 'the result names the child exactly');
    });

    test('two launchers: children bind to them in order, and each child\'s updates stay in its own run', () {
      final s = _fold([
        _call('a', title: 'subagent', kind: 'think', name: 'subagent'),
        launcher('a'),
        _call('b', title: 'subagent', kind: 'think', name: 'subagent'),
        launcher('b'),
        _chunk('one', id: 'x', meta: _oc('ses_1')),
        _chunk('two', id: 'y', meta: _oc('ses_2')),
        _chunk(' more', id: 'x', meta: _oc('ses_1')),
        _chunk('main talks', id: 'main'),
      ]);
      expect(s.subagentBook.aliases, {'ses_1': 'a', 'ses_2': 'b'});
      expect(s.subagentRun('a')!.items.whereType<TranscriptMessage>().single.text, 'one more');
      expect(s.subagentRun('b')!.items.whereType<TranscriptMessage>().single.text, 'two');
      expect(
        [
          for (final i in s.items)
            if (i is TranscriptMessage) i.text,
        ],
        ['main talks'],
      );
    });

    test('a child that speaks before any launcher is held, and joins the launcher when it arrives', () {
      var s = _fold([
        _chunk(
          'early',
          id: 'x',
          meta: _oc('ses_1', title: 'Look at a'),
        ),
      ]);
      expect(s.items.whereType<TranscriptMessage>(), isEmpty, reason: 'not the main agent\'s text');
      expect(s.subagentBook.held, hasLength(1));
      s = _fold([_call('a', title: 'subagent', kind: 'think', name: 'subagent'), launcher('a')], s);
      expect(s.subagentBook.held, isEmpty);
      expect(s.subagentRun('a')!.items.whereType<TranscriptMessage>().single.text, 'early');
    });

    test('a launcher\'s result that names its child binds it, so later updates reach the right run', () {
      final s = _fold([
        _call('a', title: 'subagent', kind: 'think', name: 'subagent'),
        launcher('a'),
        _patch(
          'a',
          status: 'completed',
          text: '<subagent sessionID="ses_9" state="completed">\ndone\n</subagent>',
          output: {
            'metadata': {'sessionID': 'ses_9'},
          },
        ),
        _chunk('late', id: 'z', meta: _oc('ses_9')),
      ]);
      expect(s.subagentRun('a')!.items.whereType<TranscriptMessage>().single.text, 'late');
      expect(s.subagentRun('a')!.result, 'done');
    });

    test('parallel launchers: a child binds to the launcher whose description is its title, whoever speaks first', () {
      final s = _fold([
        _call('a', title: 'subagent', kind: 'think', name: 'subagent'),
        launcher('a'),
        _call('b', title: 'subagent', kind: 'think', name: 'subagent'),
        launcher('b'),
        _chunk(
          'B words',
          id: 'y',
          meta: _oc('ses_B', title: 'Look at b'),
        ),
        _chunk(
          'A words',
          id: 'x',
          meta: _oc('ses_A', title: 'Look at a'),
        ),
      ]);
      expect(s.subagentBook.aliases, {'ses_B': 'b', 'ses_A': 'a'});
      expect(_said(s.subagentRun('a')!.items), ['A words']);
      expect(_said(s.subagentRun('b')!.items), ['B words']);
    });

    test('a child bound to the wrong launcher moves when a result names it', () {
      // The titles say nothing (both children are called the same), so the order bound them wrongly.
      final s = _fold([
        _call('a', title: 'subagent', kind: 'think', name: 'subagent'),
        launcher('a'),
        _call('b', title: 'subagent', kind: 'think', name: 'subagent'),
        launcher('b'),
        _chunk(
          'B words',
          id: 'y',
          meta: _oc('ses_B', title: 'same'),
        ),
        _chunk(
          'A words',
          id: 'x',
          meta: _oc('ses_A', title: 'same'),
        ),
        _patch(
          'a',
          status: 'completed',
          text: '<subagent sessionID="ses_A" state="completed">\nresA\n</subagent>',
          output: {
            'metadata': {'sessionID': 'ses_A'},
          },
        ),
        _patch(
          'b',
          status: 'completed',
          text: '<subagent sessionID="ses_B" state="completed">\nresB\n</subagent>',
          output: {
            'metadata': {'sessionID': 'ses_B'},
          },
        ),
        _chunk(
          ' more A',
          id: 'x',
          meta: _oc('ses_A', title: 'same'),
        ),
      ]);
      expect(s.subagentBook.aliases, {'ses_B': 'b', 'ses_A': 'a'});
      expect(_said(s.subagentRun('a')!.items), ['A words more A']);
      expect(_said(s.subagentRun('b')!.items), ['B words']);
      expect(s.subagentRun('a')!.result, 'resA');
    });

    test('a child with no launcher is not adopted by a later unrelated launcher', () {
      var s = _fold([
        _chunk(
          'ghost',
          id: 'g',
          meta: _oc('ses_G', title: 'Something else'),
        ),
      ]);
      s = _fold([
        _call('n', title: 'subagent', kind: 'think', name: 'subagent'),
        launcher('n'),
        _chunk(
          'real',
          id: 'r',
          meta: _oc('ses_N', title: 'Look at n'),
        ),
      ], s);
      expect(_said(s.subagentRun('n')!.items), ['real']);
      expect(s.subagentBook.held.map((h) => h.parentId), ['ses_G'], reason: 'the orphan keeps waiting');
    });

    test('a grandchild belongs to the run of the child that started it', () {
      final s = _fold([
        _call('a', title: 'subagent', kind: 'think', name: 'subagent'),
        launcher('a'),
        _chunk('child', id: 'x', meta: _oc('ses_1')),
        _call('ses_1:inner', title: 'subagent', kind: 'think', name: 'subagent', meta: _oc('ses_1')),
        _patch(
          'ses_1:inner',
          status: 'in_progress',
          title: 'subagent',
          input: {'agent': 'explore', 'description': 'Inner', 'prompt': 'p'},
          meta: _oc('ses_1'),
        ),
        _chunk(
          'grandchild',
          id: 'g',
          meta: _oc('ses_2', parent: 'ses_1', depth: 2),
        ),
      ]);
      expect(s.subagents.map((r) => r.id), ['a', 'ses_1:inner']);
      expect(s.subagentRun('ses_1:inner')!.parentRunId, 'a');
      expect(s.subagentRun('ses_1:inner')!.items.whereType<TranscriptMessage>().single.text, 'grandchild');
      expect(s.subagentRun('a')!.items.whereType<TranscriptMessage>().single.text, 'child');
    });

    test('a request from a child names its run (from the call it is about, or its own tag)', () {
      var s = _fold([
        _call('a', title: 'subagent', kind: 'think', name: 'subagent'),
        launcher('a'),
        _call('ses_1:c1', title: 'shell', kind: 'execute', meta: _oc('ses_1')),
      ]);
      s = s.withPending(PendingPermission(1, _permission('ses_1:c1')));
      expect(s.pending.single.origin!.id, 'a');
      s = s.withPending(PendingPermission(2, _permission('ses_1:never_seen', meta: _oc('ses_1'))));
      expect(s.pendingById(2)!.origin!.id, 'a');
      s = s.withPending(PendingPermission(3, _permission('main_call')));
      expect(s.pendingById(3)!.origin, isNull);
    });

    test('a background launch that returns at once says its end is not reported', () {
      final s = _fold([
        _call('a', title: 'subagent', kind: 'think', name: 'subagent'),
        _patch(
          'a',
          status: 'in_progress',
          title: 'subagent',
          input: {'agent': 'explore', 'description': 'Slow', 'prompt': 'p', 'background': true},
        ),
        _patch('a', status: 'completed', text: 'started'),
      ]);
      final run = s.subagents.single;
      expect(run.status, SubagentStatus.finished);
      expect(run.note, startedInBackgroundNote);
      expect(run.result, isNull, reason: 'the acknowledgement is not a result');
    });

    test('a think call that is not a launcher starts nothing', () {
      final s = _fold([
        _call('x', title: 'plan the work', kind: 'think'),
        _patch('x', status: 'completed', text: 'thought'),
        _call('y', title: 'subagent', kind: 'other', input: {'description': 'd'}),
      ]);
      expect(s.subagents, isEmpty);
    });
  });

  group('copilot/subagent (recorded, Copilot 1.0.109 in BYOK mode)', () {
    test('the child\'s thoughts, call and text go to its run; the parent\'s transcript holds only its own', () {
      final s = stateOfTrace('copilot', 'subagent');
      final run = s.subagents.single;
      expect(run.route, SubagentRoute.copilot);
      expect(run.id, s.items.whereType<TranscriptTool>().single.call.toolCallId, reason: 'the launching call');
      expect(run.agentType, 'explore');
      expect(run.status, SubagentStatus.finished);
      expect(run.result, contains('README.md'));
      expect(run.hasTranscript, isTrue);
      expect(run.items.whereType<TranscriptTool>(), hasLength(1), reason: 'the child ran one command');
      expect(_said(run.items), isNotEmpty);
      expect(s.toolCalls, hasLength(1), reason: 'the child\'s call is not in the main transcript');
      expect(_said(s.items), hasLength(1), reason: 'only the parent\'s final answer');
    });

    test('replay builds the same run', () {
      expect(
        replayOfTrace('copilot', 'subagent').subagents.map(_facts),
        stateOfTrace('copilot', 'subagent').subagents.map(_facts),
      );
    });
  });

  group('copilot shapes (UNVERIFIED beyond the recorded one)', () {
    Json task(String id, {String status = 'in_progress', String mode = 'sync', String name = 'alpha'}) => _call(
      id,
      title: 'Find the parser',
      status: status,
      input: {
        'name': name,
        'agent_type': 'explore',
        'description': 'Find the parser',
        'prompt': 'Where is the parser?',
        'mode': mode,
      },
    );

    test('the agent id is not the launching call\'s id: a child binds to the oldest unbound task', () {
      final s = _fold([
        task('t1'),
        task('t2', name: 'beta'),
        _chunk('first words', id: 'c', meta: _copilot('agent-uuid-1')),
        _chunk('second words', id: 'd', meta: _copilot('agent-uuid-2')),
        _patch('t1', status: 'completed', output: {'content': 'result one'}),
        _chunk('Done', id: 'main'),
      ]);
      expect(s.subagentBook.aliases, {'agent-uuid-1': 't1', 'agent-uuid-2': 't2'});
      expect(_said(s.subagentRun('t1')!.items), ['first words']);
      expect(_said(s.subagentRun('t2')!.items), ['second words']);
      expect(s.subagentRun('t1')!.result, 'result one');
      expect(_said(s.items), ['Done']);
    });

    test('a child with no task to bind to is held, not shown as the main agent\'s words', () {
      final s = _fold([_chunk('orphan words', id: 'c', meta: _copilot('agent-uuid-9'))]);
      expect(_said(s.items), isEmpty);
      expect(s.subagentBook.held, hasLength(1));
    });

    test('mode background: the call settles at launch and the run says its end is not reported', () {
      final s = _fold([task('t1', mode: 'background'), _patch('t1', status: 'completed', text: 'launched')]);
      final run = s.subagents.single;
      expect(run.status, SubagentStatus.finished);
      expect(run.note, startedInBackgroundNote);
      expect(run.background, isTrue);
    });

    test('a failed call fails the run', () {
      final s = _fold([
        task('t1'),
        _patch('t1', status: 'failed', output: {'content': 'boom'}),
      ]);
      expect(s.subagents.single.status, SubagentStatus.failed);
      expect(s.subagents.single.failure, 'boom');
    });
  });

  group('launchers without child updates', () {
    test('cursor: `Task:` call, the end from the call, duration and model from the keeper\'s cursor/task meta', () {
      final s = _fold([
        _call(
          'c1',
          title: 'Task: Explore codebase',
          input: {
            '_toolName': 'task',
            'prompt': 'find auth',
            'description': 'Explore codebase',
            'subagentType': 'explore',
          },
        ),
        _patch('c1', status: 'in_progress'),
        _patch('c1', status: 'completed', text: 'auth lives in src/auth'),
        _patch(
          'c1',
          meta: {
            'cursor': {
              'task': {'subagentType': 'explore', 'model': 'composer', 'agentId': 'ag-1', 'durationMs': 1234},
            },
          },
        ),
      ]);
      final run = s.subagents.single;
      expect(run.route, SubagentRoute.cursor);
      expect(run.hasTranscript, isFalse);
      expect(run.title, 'Explore codebase');
      expect(run.agentType, 'explore');
      expect(run.assignment, 'find auth');
      expect(run.status, SubagentStatus.finished);
      expect(run.result, 'auth lives in src/auth');
      expect(run.model, 'composer');
      expect(run.totalElapsed, const Duration(milliseconds: 1234));
    });

    test('cursor: a custom subagent type is its name', () {
      final s = _fold([
        _call(
          'c1',
          title: 'Task: x',
          input: {
            '_toolName': 'task',
            'prompt': 'p',
            'description': 'x',
            'subagentType': {'custom': 'reviewer'},
          },
        ),
      ]);
      expect(s.subagents.single.agentType, 'reviewer');
    });

    test('kimi: the summary is the result, the type is the one that ran', () {
      final s = _fold([
        _call('k1', title: 'Agent'),
        _patch(
          'k1',
          status: 'in_progress',
          title: 'Launching coder agent: trace parser loop',
          input: {
            'prompt': 'trace it',
            'description': 'trace parser loop',
            'subagent_type': 'coder',
            'run_in_background': false,
          },
        ),
        _patch(
          'k1',
          status: 'completed',
          text: 'agent_id: ag_x\nactual_subagent_type: coder\nstatus: completed\nstop_reason: end_turn\n\n[summary]\nThe loop is in parse().\n\nresume_hint: use ag_x',
        ),
      ]);
      final run = s.subagents.single;
      expect(run.route, SubagentRoute.kimi);
      expect(run.title, 'trace parser loop');
      expect(run.agentType, 'coder');
      expect(run.result, 'The loop is in parse().');
      expect(run.status, SubagentStatus.finished);
    });

    test('kimi: a background launch is not a result and says its end is not reported', () {
      final s = _fold([
        _call(
          'k1',
          title: 'Launching background coder agent: slow',
          input: {'prompt': 'p', 'description': 'slow', 'run_in_background': true},
        ),
        _patch('k1', status: 'completed', text: 'task_id: t1\nstatus: running\nagent_id: ag_x'),
      ]);
      final run = s.subagents.single;
      expect(run.result, isNull);
      expect(run.note, startedInBackgroundNote);
    });

    test('deepseek: the call answers at once, the end is not reported', () {
      final s = _fold([
        _call('d1', title: 'subagent', input: {'description': 'Check logs', 'prompt': 'look', 'name': 'agent-1'}),
        _patch('d1', status: 'completed', text: 'started subagent agent-1'),
      ]);
      final run = s.subagents.single;
      expect(run.name, 'agent-1');
      expect(run.title, 'Check logs');
      expect(run.status, SubagentStatus.finished);
      expect(run.note, startedInBackgroundNote);
      expect(run.result, isNull);
    });

    test('hermes: a dispatch is not a result; delegation results are', () {
      final dispatched = _fold([
        _call('h1', title: 'delegate_task: 2 tasks', kind: 'execute', status: 'in_progress'),
        _patch('h1', text: 'Delegating 2 tasks\n\n1. fix a\n2. fix b'),
        _patch('h1', status: 'completed'),
      ]);
      final d = dispatched.subagents.single;
      expect(d.title, 'Delegating 2 tasks');
      expect(d.assignment, contains('1. fix a'));
      expect(d.status, SubagentStatus.finished);
      expect(d.note, startedInBackgroundNote);
      expect(d.result, isNull);

      final done = _fold([
        _call('h2', title: 'delegate_task: one', kind: 'execute', status: 'in_progress'),
        _patch('h2', status: 'completed', text: 'Delegation results: 1 task in 12s\n\n✅ Task 1: completed\nfixed'),
      ]);
      expect(done.subagents.single.result, startsWith('Delegation results: 1 task'));
      expect(done.subagents.single.note, isNull);
    });

    test('hermes: the completion\'s dispatch JSON does not replace what it was asked', () {
      final s = _fold([
        _call('h1', title: 'delegate_task: 2 tasks', kind: 'execute', status: 'in_progress'),
        _patch('h1', text: 'Delegating 2 tasks\n\n1. fix a\n2. fix b'),
        _patch('h1', status: 'completed', text: '{"status": "dispatched", "mode": "background", "count": 2}'),
      ]);
      final run = s.subagents.single;
      expect(run.title, 'Delegating 2 tasks');
      expect(run.assignment, contains('1. fix a'));
      expect(run.note, startedInBackgroundNote);
    });

    test('hermes: a failed delegation says why once, and keeps what it was asked', () {
      final s = _fold([
        _call('h1', title: 'delegate_task: one', kind: 'execute', status: 'in_progress'),
        _patch('h1', text: 'Delegating task:\nfix the parser'),
        _patch('h1', status: 'failed', text: 'Delegation failed: no api key'),
      ]);
      final run = s.subagents.single;
      expect(run.failure, 'Delegation failed: no api key');
      expect(run.assignment, contains('fix the parser'));
      expect(run.title, isNot(contains('failed')));
    });

    test('kimi: a failed Agent call shows its error, not the header lines', () {
      final s = _fold([
        _call(
          'k1',
          title: 'Launching coder agent: trace',
          input: {'prompt': 'p', 'description': 'trace', 'subagent_type': 'coder'},
        ),
        _patch(
          'k1',
          status: 'failed',
          text: 'agent_id: ag_x\nactual_subagent_type: coder\nstatus: failed\nstop_reason: error\n\nsubagent error: Agent timed out after 60s\n\npartial output here',
        ),
      ]);
      final run = s.subagents.single;
      expect(run.status, SubagentStatus.failed);
      expect(run.failure, 'Agent timed out after 60s');
      expect(run.agentType, 'coder');
    });

    test('a failure text is cut like a result', () {
      final huge = 'x' * (SubagentRun.maxResult * 3);
      final copilot = _fold([
        _call('c1', title: 'task', input: {'agent_type': 'explore', 'prompt': 'p', 'description': 'd'}),
        _patch('c1', status: 'failed', output: {'content': huge}),
      ]);
      expect(copilot.subagents.single.failure!.length, lessThanOrEqualTo(SubagentRun.maxResult));
      final deepseek = _fold([
        _call('d1', title: 'subagent', input: {'description': 'd', 'prompt': 'p'}),
        _patch('d1', status: 'failed', text: huge),
      ]);
      expect(deepseek.subagents.single.failure!.length, lessThanOrEqualTo(SubagentRun.maxResult));
    });

    test('a terminal call and an ordinary tool start no run', () {
      final s = _fold([
        _call('t', title: 'delegate nothing', kind: 'execute'),
        _call('u', title: 'Task list', kind: 'other', input: {'prompt': 'x'}),
        _call('v', title: 'subagent', kind: 'think', input: {'description': 'd'}),
      ]);
      expect(s.subagents, isEmpty);
    });
  });
}
