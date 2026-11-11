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

Json _oc(String child, {String parent = 'root', int depth = 1}) => {
  'opencode/child-session': {'id': child, 'parentID': parent, 'depth': depth, 'title': 'child $child'},
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

  group('opencode shapes (UNVERIFIED beyond the recorded one)', () {
    Json launcher(String id, {String status = 'in_progress'}) => _patch(
      id,
      status: status,
      title: 'subagent',
      input: {'agent': 'explore', 'description': 'Look at $id', 'prompt': 'Do $id'},
    );

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
      var s = _fold([_chunk('early', id: 'x', meta: _oc('ses_1'))]);
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

  group('copilot (shape from github/copilot-cli#4106 and the t3code adapter; UNVERIFIED against a session)', () {
    Json task(String id, {String status = 'in_progress', String mode = 'sync'}) => _call(
      id,
      title: 'task',
      status: status,
      input: {
        'name': 'alpha',
        'agent_type': 'explore',
        'description': 'Find the parser',
        'prompt': 'Where is the parser?',
        'mode': mode,
      },
    );

    test('the child\'s text and calls are tagged with the launching call\'s id and go to its run', () {
      final s = _fold([
        task('t1'),
        _chunk('thinking', id: 'c', meta: _copilot('t1'), kind: 'agent_thought_chunk'),
        _call('child1', title: 'grep parser', kind: 'search', meta: _copilot('t1')),
        _patch('child1', status: 'completed', meta: _copilot('t1')),
        _chunk('found it', id: 'c2', meta: _copilot('t1')),
        _patch('t1', status: 'completed', output: {'content': 'The parser is in src/parser.ts'}),
        _chunk('Done: src/parser.ts', id: 'main'),
      ]);
      final run = s.subagents.single;
      expect(run.route, SubagentRoute.copilot);
      expect(run.id, 't1');
      expect(run.name, 'alpha');
      expect(run.title, 'Find the parser');
      expect(run.agentType, 'explore');
      expect(run.status, SubagentStatus.finished);
      expect(run.result, 'The parser is in src/parser.ts');
      expect(run.items.whereType<TranscriptTool>().single.call.toolCallId, 'child1');
      expect(run.items.whereType<TranscriptMessage>().map((m) => m.text), contains('found it'));
      expect(s.toolCalls.map((c) => c.toolCallId), ['t1']);
      expect(
        [
          for (final i in s.items)
            if (i is TranscriptMessage) i.text,
        ],
        ['Done: src/parser.ts'],
        reason: 'the child\'s text is not the main agent\'s',
      );
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

    test('tagged updates whose launcher has another shape still reach a run, made from the call', () {
      final s = _fold([
        _chunk('child words', id: 'c', meta: _copilot('odd')),
        _call('odd', title: 'whatever it is called', kind: 'think'),
      ]);
      expect(s.subagents.single.id, 'odd');
      expect(s.subagents.single.items.whereType<TranscriptMessage>().single.text, 'child words');
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
