// Subagents in the reducer: the real Claude
// trace (`traces/claude/subagent`) and, for what no recorded session has, the
// shapes the adapters' own sources define, written as literals below and
// marked UNVERIFIED (omp's `task`, codex's `collabAgentToolCall`, Claude's
// nested and background subagents come from claude-agent-acp's scenario
// snapshots, not from a session this project recorded).
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/acp/subagents/subagent_run.dart';

import 'support/trace_state.dart';

SessionUpdate _u(Json json) => SessionUpdate.parse(json);

AgentSessionState _fold(Iterable<Json> updates, [AgentSessionState? from, DateTime? at]) =>
    updates.fold(from ?? const AgentSessionState('s'), (s, j) => s.apply(_u(j), at: at));

Json _meta(String toolName, {String? parent, Json? response, bool? subagent}) => {
  'claudeCode': {'toolName': toolName, 'parentToolUseId': ?parent, 'toolResponse': ?response, 'subagent': ?subagent},
};

Json _launch(String id, {String? parent, String status = 'pending', Json? input, String title = 'Task', Json? response}) => {
  'sessionUpdate': 'tool_call',
  'toolCallId': id,
  'title': title,
  'kind': 'think',
  'status': status,
  'rawInput': input ?? {},
  '_meta': _meta('Agent', parent: parent, response: response),
};

Json _toolUpdate(String id, {String? parent, String? status, String? tool, Json? response, Json? input, String? title}) => {
  'sessionUpdate': 'tool_call_update',
  'toolCallId': id,
  'status': ?status,
  'rawInput': ?input,
  'title': ?title,
  '_meta': _meta(tool ?? 'Agent', parent: parent, response: response),
};

Json _childTool(String id, String parent, {String tool = 'Read', String title = 'Read /x.ts', String? status}) => {
  'sessionUpdate': 'tool_call',
  'toolCallId': id,
  'title': title,
  'kind': 'read',
  'status': status ?? 'pending',
  '_meta': _meta(tool, parent: parent),
};

Json _childText(String parent, String text, {String id = 'msg1', String type = 'agent_message_chunk'}) => {
  'sessionUpdate': type,
  'messageId': id,
  'content': {'type': 'text', 'text': text},
  '_meta': {
    'claudeCode': {'parentToolUseId': parent},
  },
};

Json _text(String text, {String id = 'main'}) => {
  'sessionUpdate': 'agent_message_chunk',
  'messageId': id,
  'content': {'type': 'text', 'text': text},
};

/// What of a run must be the same live and replayed (everything but times).
Map<String, Object?> _facts(SubagentRun r) => {
  'id': r.id,
  'title': r.title,
  'agentType': r.agentType,
  'assignment': r.assignment,
  'status': r.status,
  'toolCount': r.toolCount,
  'tokens': r.tokens,
  'totalElapsed': r.totalElapsed,
  'model': r.model,
  'result': r.result,
  'lastTool': r.lastTool,
  'lastToolLine': r.lastToolLine,
  'recentTools': r.recentTools,
  'hasTranscript': r.hasTranscript,
  'items': [
    for (final i in r.items)
      switch (i) {
        TranscriptTool() => 'tool ${i.call.toolCallId} ${i.call.status.name}',
        TranscriptMessage() => '${i.role.name} ${i.text}',
        _ => i.runtimeType.toString(),
      },
  ],
};

const _parentId = 'toolu_01UpSboUH5eb4ev4tE2qvDiZ';
const _childId = 'toolu_017D7HirSHLxzZANZWSvpC1c';

void main() {
  group('claude/subagent (recorded)', () {
    test('the child\'s calls stay out of the main transcript; the Agent row stays', () {
      final s = stateOfTrace('claude', 'subagent');
      final main = s.toolCalls.map((c) => c.toolCallId).toList();
      expect(main, contains(_parentId));
      expect(main, isNot(contains(_childId)));
      expect(s.items.whereType<TranscriptTool>().map((t) => t.call.toolCallId), [startsWith('toolu_01P8'), _parentId]);
      expect(s.toolCall(_parentId)!.title, 'Run ls command and report filenames');
    });

    test('the run: fields of the launch and of the end', () {
      final s = stateOfTrace('claude', 'subagent');
      final run = s.subagents.single;
      expect(s.subagentRun(_parentId), same(run));
      expect(s.subagentsOfToolCall(_parentId), [run]);
      expect(run.id, _parentId);
      expect(run.parentToolCallId, _parentId);
      expect(run.parentRunId, isNull);
      expect(run.route, SubagentRoute.claude);
      expect(run.title, 'Run ls command and report filenames');
      expect(run.agentType, 'general-purpose', reason: 'from the end-of-call toolResponse');
      expect(run.assignment, startsWith('Run the `ls` command'));
      expect(run.status, SubagentStatus.finished);
      expect(run.toolCount, 1);
      expect(run.tokens, 13651);
      expect(run.totalElapsed, const Duration(milliseconds: 6086));
      expect(run.elapsed, const Duration(milliseconds: 6086));
      expect(run.model, 'claude-haiku-4-5-20251001');
      expect(run.result, 'src/\nREADME.md\nnotes.txt', reason: 'without the agentId trailer');
      expect(run.failure, isNull);
      expect(run.lastTool, 'Bash');
      expect(run.lastToolLine, 'ls -1 /tmp/scratch');
      expect(run.recentTools, ['Bash']);
      expect(run.hasTranscript, isTrue);
      expect(run.droppedItems, 0);
      expect(run.startedAt, traceTime(11154.97), reason: 'when the Agent call first appeared');
      expect(run.finishedAt, traceTime(17262.446), reason: 'the update that finished the call');
      expect(s.subagentSummary.finished, 1);
      expect(s.subagentSummary.total, 1);
    });

    test('the child\'s transcript holds its Bash call, finished, timed', () {
      final run = stateOfTrace('claude', 'subagent').subagents.single;
      final tool = run.items.single as TranscriptTool;
      expect(tool.call.toolCallId, _childId);
      expect(tool.call.status, ToolStatus.completed);
      expect(tool.call.rawOutput, 'src/\nREADME.md  39B\nnotes.txt  40B');
      expect(tool.at, traceTime(15456.834));
      expect(tool.finishedAt, traceTime(15634.699));
    });

    test('replay (session/load) builds the same run, with no times', () {
      final live = stateOfTrace('claude', 'subagent');
      final replay = replayOfTrace('claude', 'subagent');
      expect(replay.subagents.map(_facts), live.subagents.map(_facts));
      final run = replay.subagents.single;
      expect(run.startedAt, isNull);
      expect(run.finishedAt, isNull);
      expect((run.items.single as TranscriptTool).at, isNull);
      expect(replay.toolCalls.map((c) => c.toolCallId), live.toolCalls.map((c) => c.toolCallId));
    });

    test('a permission from the child names its run (found by the call it is about)', () {
      final s = stateOfTrace('claude', 'subagent', stopAtPermission: true);
      final pending = s.pending.single as PendingPermission;
      expect(pending.request.toolCall.toolCallId, _childId);
      expect(pending.origin, isNotNull);
      expect(pending.origin!.id, _parentId);
      expect(pending.origin!.title, 'Run ls command and report filenames');
      expect(pending.origin!.label, 'Run ls command and report filenames', reason: 'no agent type yet');
      expect(s.phase, AgentPhase.blockedOnPermission, reason: 'a child\'s request blocks like any');
      expect(s.subagents.single.status, SubagentStatus.running);
      expect(s.subagents.single.items.single, isA<TranscriptTool>());
      expect(s.items.whereType<TranscriptTool>().map((t) => t.call.toolCallId), isNot(contains(_childId)));
      expect(s.withoutPending(pending.id).pending, isEmpty);
    });

    test('an Agent call that waits for approval is waiting until it is answered', () {
      var s = _fold([_launch('a', input: {'description': 'd', 'prompt': 'p'}, status: 'in_progress')]);
      expect(s.subagents.single.status, SubagentStatus.running);
      final request = PermissionRequest.parse({
        'sessionId': 's',
        'toolCall': {'toolCallId': 'a', 'title': 'Agent'},
        'options': [
          {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
        ],
      });
      s = s.withPending(PendingPermission(1, request));
      expect(s.pending.single.origin, isNull, reason: 'it is the main agent asking to start one');
      expect(s.subagents.single.status, SubagentStatus.waiting);
      s = s.withoutPending(1);
      expect(s.subagents.single.status, SubagentStatus.running);
    });
  });

  group('claude, shapes from claude-agent-acp\'s scenario snapshots (UNVERIFIED as a session)', () {
    test('a subagent that talks: text and calls go to its run, the answer to the main transcript', () {
      final s = _fold([
        _text('Starting. '),
        _launch('toolu_task', input: {'description': 'Explore code', 'prompt': 'Find the parser', 'subagent_type': 'Explore'}),
        _childText('toolu_task', 'Looking for', id: 'msg_sub_1'),
        _childText('toolu_task', ' the parser.', id: 'msg_sub_1'),
        _childTool('toolu_sub_read', 'toolu_task'),
        _toolUpdate('toolu_task', status: 'in_progress', response: {'elapsedTimeSeconds': 3, 'subagentType': 'Explore'}),
        // Later updates of the child's call carry no tag.
        _toolUpdate('toolu_sub_read', status: 'completed', tool: 'Read'),
        _childText('toolu_task', 'Foun', id: 'msg_sub_2'),
        _childText('toolu_task', 'd it.', id: 'msg_sub_2'),
        _toolUpdate('toolu_task', status: 'completed', response: {
          'agentId': 'a1',
          'prompt': 'Find the parser',
          'status': 'completed',
          'totalDurationMs': 10,
          'totalTokens': 5,
          'totalToolUseCount': 1,
          'content': [
            {'type': 'text', 'text': 'The parser is in x.ts.'},
          ],
        }),
        _text('It is in x.ts.', id: 'main2'),
      ]);
      final mainText = [for (final m in s.items.whereType<TranscriptMessage>()) m.text];
      expect(mainText, ['Starting. ', 'It is in x.ts.'], reason: 'child text never in the main transcript');
      expect(s.items.whereType<TranscriptTool>().map((t) => t.call.toolCallId), ['toolu_task']);
      final run = s.subagents.single;
      expect(run.agentType, 'Explore');
      expect(run.title, 'Explore code');
      expect(run.status, SubagentStatus.finished);
      expect([for (final m in run.items.whereType<TranscriptMessage>()) m.text], ['Looking for the parser.', 'Found it.']);
      expect(run.items.whereType<TranscriptTool>().single.call.status, ToolStatus.completed, reason: 'untagged update routed by call id');
      expect(run.toolCount, 1);
      expect(run.result, 'The parser is in x.ts.');
      expect(run.totalElapsed, const Duration(milliseconds: 10));
    });

    test('child text streams in the live slot: the item list and the run list stay the same instances', () {
      var s = _fold([
        _launch('t', input: {'description': 'd', 'prompt': 'p'}),
        _childText('t', 'one '),
      ]);
      final run = s.subagents.single;
      final liveKey = run.liveMessage!.key;
      final live = run.liveTextOf(liveKey)!;
      final items = run.items;
      final runs = s.subagents;
      final summary = s.subagentSummary;
      s = s.apply(_u(_childText('t', 'two ')));
      s = s.apply(_u(_childText('t', 'three')));
      expect(identical(s.subagents, runs), isTrue, reason: 'memoizable by identity while only text grows');
      expect(identical(s.subagents.single.items, items), isTrue);
      expect(identical(s.subagentSummary, summary), isTrue);
      expect(s.subagents.single.liveTextOf(liveKey), same(live));
      expect(live.text, 'one two three');
      expect(s.subagents.single.items.whereType<TranscriptMessage>().single.text, 'one two three');
      expect(s.items.whereType<TranscriptMessage>(), isEmpty, reason: 'only the Agent row is in the main transcript');
      // flushSubagentLive tells the listeners of the text once.
      var told = 0;
      live.addListener(() => told++);
      s.flushSubagentLive();
      s.flushSubagentLive();
      expect(told, 1);
    });

    test('an update before its parent call is held and applied when the call arrives', () {
      var s = _fold([
        _childText('late', 'early words'),
        _childTool('late_read', 'late'),
        _toolUpdate('late_read', status: 'completed', tool: 'Read'),
      ]);
      expect(s.items, isEmpty, reason: 'held, not shown in the main transcript');
      expect(s.subagents, isEmpty);
      expect(s.subagentBook.held, hasLength(3));
      s = _fold([
        _launch('late', input: {'description': 'Check the logs', 'prompt': 'Check logs', 'subagent_type': 'general-purpose'}),
      ], s);
      expect(s.subagentBook.held, isEmpty);
      final run = s.subagents.single;
      expect(run.title, 'Check the logs');
      expect(run.items.length, 2);
      expect((run.items.first as TranscriptMessage).text, 'early words');
      expect((run.items.last as TranscriptTool).call.status, ToolStatus.completed);
      expect(run.toolCount, 1);
      expect(s.items.whereType<TranscriptTool>().single.call.toolCallId, 'late');
    });

    test('a call first seen without its tag moves into the run when the tag arrives', () {
      var s = _fold([
        _launch('t', input: {'description': 'd', 'prompt': 'p'}),
        {'sessionUpdate': 'tool_call', 'toolCallId': 'eager', 'title': 'rg x', 'kind': 'execute'},
      ]);
      expect(s.items.whereType<TranscriptTool>().map((t) => t.call.toolCallId), ['t', 'eager']);
      s = s.apply(_u(_toolUpdate('eager', parent: 't', tool: 'Bash', status: 'in_progress')));
      expect(s.items.whereType<TranscriptTool>().map((t) => t.call.toolCallId), ['t']);
      final tool = s.subagents.single.items.single as TranscriptTool;
      expect(tool.call.toolCallId, 'eager');
      expect(tool.call.title, 'rg x', reason: 'what the call had before the tag');
      expect(tool.call.status, ToolStatus.inProgress);
      expect(s.subagents.single.toolCount, 1);
    });

    test('a subagent that starts a subagent: runs are flat, nested ones say whose they are', () {
      final s = _fold([
        _launch('outer', input: {'description': 'Plan the work', 'prompt': 'Plan it', 'subagent_type': 'Plan'}),
        _launch('inner', parent: 'outer', input: {'description': 'Read the spec', 'prompt': 'Read spec.md', 'subagent_type': 'Explore'}),
        _childTool('grand', 'inner', title: 'Read /spec.md'),
        _toolUpdate('inner', parent: 'outer', status: 'completed'),
        _childText('outer', 'Plan: do X.', id: 'm'),
        _toolUpdate('outer', status: 'completed'),
      ]);
      expect(s.subagents.map((r) => r.id), ['outer', 'inner'], reason: 'in order of first appearance');
      final outer = s.subagentRun('outer')!, inner = s.subagentRun('inner')!;
      expect(outer.parentRunId, isNull);
      expect(inner.parentRunId, 'outer');
      expect(inner.parentToolCallId, 'inner');
      expect(inner.agentType, 'Explore');
      expect(inner.status, SubagentStatus.finished);
      expect(inner.items.whereType<TranscriptTool>().map((t) => t.call.toolCallId), ['grand']);
      expect(outer.items.whereType<TranscriptTool>().map((t) => t.call.toolCallId), ['inner'], reason: 'the inner Agent row is in the outer transcript');
      expect(outer.items.whereType<TranscriptMessage>().single.text, 'Plan: do X.');
      expect(s.items.whereType<TranscriptTool>().map((t) => t.call.toolCallId), ['outer']);
      expect(s.subagentSummary.total, 2);
    });

    test('a request names the innermost run, from its tag or from the call it is about', () {
      var s = _fold([
        _launch('outer', input: {'description': 'Outer', 'prompt': 'p'}),
        _launch('inner', parent: 'outer', input: {'description': 'Inner', 'prompt': 'p', 'subagent_type': 'Explore'}),
        _childTool('grand', 'inner', tool: 'Bash', title: 'rg parser'),
      ]);
      final request = PermissionRequest.parse({
        'sessionId': 's',
        'toolCall': {'toolCallId': 'grand', 'title': 'rg parser'},
        'options': [
          {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
        ],
      });
      s = s.withPending(PendingPermission(1, request));
      expect(s.pending.single.origin!.id, 'inner');
      expect(s.pending.single.origin!.label, 'Explore');
      // Tagged request for a call this client never saw.
      final tagged = PermissionRequest.parse({
        'sessionId': 's',
        'toolCall': {
          'toolCallId': 'never_seen',
          '_meta': _meta('Edit', parent: 'outer'),
        },
        'options': [
          {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
        ],
      });
      s = s.withPending(PendingPermission(2, tagged));
      expect(s.pending.last.origin!.id, 'outer');
      // An ordinary request has none.
      final plain = PermissionRequest.parse({
        'sessionId': 's',
        'toolCall': {'toolCallId': 'main_tool'},
        'options': [
          {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
        ],
      });
      s = s.withPending(PendingPermission(3, plain));
      expect(s.pendingById(3)!.origin, isNull);
      // A question about a child's call.
      final ask = ElicitationRequest.parse({
        'mode': 'form',
        'message': 'Which?',
        'sessionId': 's',
        'toolCallId': 'grand',
        'requestedSchema': {'type': 'object', 'properties': <String, Object?>{}},
      });
      s = s.withPending(PendingQuestion(4, ask));
      expect(s.pendingById(4)!.origin!.id, 'inner');
      expect(s.phase, AgentPhase.blockedOnPermission);
    });

    test('the plan a subagent writes is its own, not the session\'s', () {
      final s = _fold([
        {
          'sessionUpdate': 'plan',
          'entries': [
            {'content': 'main step', 'status': 'pending', 'priority': 'medium'},
          ],
        },
        _launch('t', input: {'description': 'd', 'prompt': 'p'}),
        {
          'sessionUpdate': 'plan',
          'entries': [
            {'content': 'child step', 'status': 'in_progress', 'priority': 'medium'},
          ],
          '_meta': {
            'claudeCode': {'parentToolUseId': 't'},
          },
        },
      ]);
      expect(s.plan.single.content, 'main step');
      expect(s.subagents.single.plan.single.content, 'child step');
    });

    test('background: the call finishes at once and the run keeps running until a response ends it', () {
      var s = _fold([
        _launch('bg', input: {'description': 'Background review', 'prompt': 'Review', 'run_in_background': true}),
        _toolUpdate('bg', status: 'completed'),
        _toolUpdate('bg', response: {'agentId': 'a2', 'isAsync': true, 'status': 'async_launched', 'prompt': 'Review'}),
        _childText('bg', 'Reviewing now.'),
      ]);
      var run = s.subagents.single;
      expect(run.background, isTrue);
      expect(run.status, SubagentStatus.running);
      expect(s.toolCall('bg')!.status, ToolStatus.completed);
      expect(run.items.whereType<TranscriptMessage>().single.text, 'Reviewing now.');
      s = s.apply(_u(_toolUpdate('bg', response: {'status': 'completed', 'totalDurationMs': 1000, 'totalToolUseCount': 0})));
      run = s.subagents.single;
      expect(run.status, SubagentStatus.finished);
      expect(run.background, isFalse);
    });

    test('a failed Agent call fails its run and says why', () {
      final s = _fold([
        _launch('t', input: {'description': 'd', 'prompt': 'p'}),
        {
          ..._toolUpdate('t', status: 'failed'),
          'content': [
            {
              'type': 'content',
              'content': {'type': 'text', 'text': 'Agent type not found'},
            },
          ],
        },
      ]);
      final run = s.subagents.single;
      expect(run.status, SubagentStatus.failed);
      expect(run.failure, 'Agent type not found');
      expect(s.subagentSummary.failed, 1);
    });

    test('cancelling the turn cancels running subagents, their calls and the subagents they started', () {
      final at = DateTime.utc(2026, 1, 1, 12);
      var s = _fold([
        _launch('outer', input: {'description': 'Outer', 'prompt': 'p'}),
        _launch('inner', parent: 'outer', input: {'description': 'Inner', 'prompt': 'p'}),
        _childTool('grand', 'inner'),
        _childTool('child', 'outer', tool: 'Bash'),
        _launch('done', input: {'description': 'Done', 'prompt': 'p'}),
        _toolUpdate('done', status: 'completed'),
        _childText('outer', 'thinking...'),
      ], null, at);
      expect(s.subagentSummary.running, 2);
      s = s.withCancelRequested(at: at.add(const Duration(seconds: 5)));
      expect(s.subagentRun('outer')!.status, SubagentStatus.cancelled);
      expect(s.subagentRun('inner')!.status, SubagentStatus.cancelled);
      expect(s.subagentRun('done')!.status, SubagentStatus.finished, reason: 'what ended stays ended');
      expect(s.subagentRun('outer')!.finishedAt, at.add(const Duration(seconds: 5)));
      expect(s.subagentRun('outer')!.liveMessage, isNull, reason: 'its text stopped');
      for (final id in ['outer', 'inner']) {
        final tools = s.subagentRun(id)!.items.whereType<TranscriptTool>();
        expect(tools.every((t) => t.call.status == ToolStatus.cancelled || t.call.toolCallId == 'inner'), isTrue, reason: id);
      }
      expect(s.subagentRun('inner')!.items.whereType<TranscriptTool>().single.call.status, ToolStatus.cancelled);
      expect(s.toolCall('outer')!.status, ToolStatus.cancelled);
      final ended = s.withTurnEnded(StopReason.cancelled);
      expect(ended.subagentSummary.cancelled, 2);
    });

    test('a cancelled Agent call (the agent says so) cancels the run and what it started', () {
      final s = _fold([
        _launch('outer', input: {'description': 'Outer', 'prompt': 'p'}),
        _launch('inner', parent: 'outer', input: {'description': 'Inner', 'prompt': 'p'}),
        _childTool('grand', 'inner'),
        _toolUpdate('outer', status: 'cancelled'),
      ]);
      expect(s.subagentRun('outer')!.status, SubagentStatus.cancelled);
      expect(s.subagentRun('inner')!.status, SubagentStatus.cancelled);
      expect(s.subagentRun('inner')!.items.whereType<TranscriptTool>().single.call.status, ToolStatus.cancelled);
    });

    test('a long run keeps the newest items and counts what it dropped', () {
      const n = 2250;
      var s = _fold([_launch('t', input: {'description': 'd', 'prompt': 'p'})]);
      for (var i = 0; i < n; i++) {
        s = s.apply(_u(_childTool('c$i', 't', title: 'Read $i')));
      }
      final run = s.subagents.single;
      expect(run.items.length + run.droppedItems, n);
      expect(run.droppedItems, greaterThan(0));
      expect(run.items.length, lessThanOrEqualTo(SubagentRun.maxItems + SubagentRun.itemsSlack));
      expect(run.items.length, greaterThanOrEqualTo(SubagentRun.maxItems));
      expect((run.items.last as TranscriptTool).call.toolCallId, 'c${n - 1}');
      expect(run.toolCount, n, reason: 'counted, not measured from the kept items');
      expect(run.recentTools, hasLength(SubagentRun.maxRecent));
    });

    test('held updates are capped', () {
      var s = const AgentSessionState('s');
      for (var i = 0; i < 700; i++) {
        s = s.apply(_u(_childText('nobody', 'x$i', id: 'm$i')));
      }
      expect(s.subagentBook.held, hasLength(500));
      expect(s.items, isEmpty);
    });

    test('summary: counts by state, memoized by the runs list, ordering stable', () {
      var s = _fold([
        _launch('a', input: {'description': 'A', 'prompt': 'p'}),
        _launch('b'),
        _launch('c', input: {'description': 'C', 'prompt': 'p'}),
        _launch('d', input: {'description': 'D', 'prompt': 'p'}),
        _toolUpdate('a', status: 'completed'),
        _toolUpdate('d', status: 'failed'),
      ]);
      final sum = s.subagentSummary;
      expect((sum.total, sum.waiting, sum.running, sum.finished, sum.failed, sum.cancelled), (4, 1, 1, 1, 1, 0));
      expect(sum.active, 2);
      expect(identical(s.subagentSummary, sum), isTrue);
      expect(s.subagents.map((r) => r.id), ['a', 'b', 'c', 'd']);
      s = s.apply(_u(_toolUpdate('b', input: {'description': 'B', 'prompt': 'now'})));
      expect(s.subagentRun('b')!.status, SubagentStatus.running, reason: 'its input arrived: it started');
      expect(s.subagentSummary, isNot(sum));
      expect(s.subagentSummary.waiting, 0);
      expect(s.subagents.map((r) => r.id), ['a', 'b', 'c', 'd'], reason: 'never reordered');
      expect(s.subagentSummary.running, 2);
      expect(SubagentSummary.of(const []), SubagentSummary.none);
    });

    test('a session without subagents has none, and an ordinary call starts none', () {
      final s = _fold([
        {'sessionUpdate': 'tool_call', 'toolCallId': 'x', 'title': 'ls', 'kind': 'execute', 'rawInput': {'command': 'ls'}},
        {'sessionUpdate': 'tool_call', 'toolCallId': 'todo', 'title': 'Marking step done', 'kind': 'think', 'rawInput': {'op': 'done', 'task': 'step'}},
        _toolUpdate('x', status: 'completed', tool: 'Bash'),
      ]);
      expect(s.subagents, isEmpty);
      expect(s.subagentSummary, SubagentSummary.none);
      expect(s.subagentBook.isEmpty, isTrue);
    });
  });

  group('omp `task` (shapes from oh-my-pi\'s AgentProgress / SingleResult; UNVERIFIED against a session)', () {
    Json progress(int i, String id, String status, {Json? extra}) => {
      'index': i,
      'id': id,
      'agent': 'explore',
      'status': status,
      'task': 'Find $id',
      'assignment': 'Assignment for $id',
      'description': 'Look into $id',
      'currentTool': 'grep',
      'currentToolArgs': 'parser src/',
      'recentTools': [
        {'tool': 'read', 'args': 'a.ts', 'endMs': 1},
        {'tool': 'grep', 'args': 'x', 'endMs': 2},
      ],
      'recentOutput': ['line one', 'line two'],
      'toolCount': 4,
      'requests': 2,
      'tokens': 1234,
      'cost': 0.5,
      'durationMs': 42000,
      'resolvedModel': 'anthropic/claude-sonnet',
      'completionPercent': 60,
      ...?extra,
    };

    test('input only: waiting runs from tasks[]; progress then fills them; results end them; no transcript', () {
      var s = _fold([
        {
          'sessionUpdate': 'tool_call',
          'toolCallId': 'call_task',
          'title': 'task',
          'kind': 'other',
          'status': 'pending',
          'rawInput': {
            'context': 'shared',
            'tasks': [
              {'name': 'Alpha', 'agent': 'explore', 'task': 'Find alpha'},
              {'name': 'Beta', 'agent': 'scout', 'task': 'Find beta'},
            ],
          },
        },
      ]);
      expect(s.subagents.map((r) => r.id), ['call_task#0', 'call_task#1']);
      expect(s.subagents.map((r) => r.status), [SubagentStatus.waiting, SubagentStatus.waiting]);
      expect(s.subagents.first.name, 'Alpha');
      expect(s.subagents.first.agentType, 'explore');
      expect(s.subagents.every((r) => !r.hasTranscript && r.items.isEmpty), isTrue);
      expect(s.subagents.first.route, SubagentRoute.omp);

      s = s.apply(_u({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'call_task',
        'status': 'in_progress',
        'rawOutput': {
          'content': [],
          'details': {
            'results': [],
            'totalDurationMs': 0,
            'progress': [progress(0, 'Alpha', 'running'), progress(1, 'Beta', 'pending', extra: {'retryState': {'attempt': 2, 'maxAttempts': 5, 'delayMs': 8000, 'errorMessage': '429 rate limited', 'startedAtMs': 1}})],
          },
        },
      }));
      final alpha = s.subagentRun('call_task#0')!, beta = s.subagentRun('call_task#1')!;
      expect(alpha.status, SubagentStatus.running);
      expect(alpha.name, 'Alpha');
      expect(alpha.title, 'Look into Alpha');
      expect(alpha.assignment, 'Assignment for Alpha');
      expect(alpha.toolCount, 4);
      expect(alpha.tokens, 1234);
      expect(alpha.cost, 0.5);
      expect(alpha.percent, 60);
      expect(alpha.model, 'anthropic/claude-sonnet');
      expect(alpha.lastTool, 'grep');
      expect(alpha.lastToolLine, 'grep parser src/');
      expect(alpha.recentTools, ['read', 'grep']);
      expect(alpha.recentOutput, ['line one', 'line two']);
      expect(alpha.reportedElapsed, const Duration(seconds: 42));
      expect(alpha.totalElapsed, isNull);
      expect(alpha.hasTranscript, isFalse);
      expect(beta.status, SubagentStatus.waiting);
      expect(beta.retry!.attempt, 2);
      expect(beta.retry!.maxAttempts, 5);
      expect(beta.retry!.delay, const Duration(seconds: 8));
      expect(beta.retry!.message, '429 rate limited');
      expect(s.subagentSummary.running, 1);

      s = s.apply(_u({
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'call_task',
        'status': 'completed',
        'rawOutput': {
          'content': [],
          'details': {
            'totalDurationMs': 50000,
            'progress': [progress(0, 'Alpha', 'completed'), progress(1, 'Beta', 'failed')],
            'results': [
              {'index': 0, 'id': 'Alpha', 'agent': 'explore', 'exitCode': 0, 'output': 'Alpha found.', 'stderr': '', 'durationMs': 41000, 'tokens': 2000},
              {'index': 1, 'id': 'Beta', 'agent': 'scout', 'exitCode': 1, 'output': '', 'stderr': 'boom', 'error': 'Provider quota exhausted', 'durationMs': 9000, 'tokens': 10},
            ],
          },
        },
      }));
      final a2 = s.subagentRun('call_task#0')!, b2 = s.subagentRun('call_task#1')!;
      expect(a2.status, SubagentStatus.finished);
      expect(a2.result, 'Alpha found.');
      expect(a2.totalElapsed, const Duration(seconds: 41));
      expect(a2.tokens, 1234, reason: 'progress first, as in the observed roster');
      expect(a2.retry, isNull);
      expect(b2.status, SubagentStatus.failed);
      expect(b2.failure, 'Provider quota exhausted');
      expect(b2.retry, isNull, reason: 'it ended: no retry pending');
      expect(s.subagentSummary.finished, 1);
      expect(s.subagentSummary.failed, 1);
      expect(s.items.whereType<TranscriptTool>().single.call.toolCallId, 'call_task');
    });

    test('an aborted subagent is cancelled; a cancelled call cancels the ones still running', () {
      final progressUpdate = {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'c',
        'status': 'in_progress',
        'rawOutput': {
          'details': {
            'results': [],
            'progress': [progress(0, 'A', 'aborted'), progress(1, 'B', 'running')],
          },
        },
      };
      var s = _fold([
        {'sessionUpdate': 'tool_call', 'toolCallId': 'c', 'title': 'Spawning', 'kind': 'other', 'rawInput': {'tasks': []}},
        progressUpdate,
      ]);
      expect(s.subagentRun('c#0')!.status, SubagentStatus.cancelled);
      expect(s.subagentRun('c#1')!.status, SubagentStatus.running);
      final byPerson = s.withCancelRequested();
      expect(byPerson.subagentRun('c#1')!.status, SubagentStatus.cancelled, reason: 'the person cancelling takes it');
      s = s.apply(_u({'sessionUpdate': 'tool_call_update', 'toolCallId': 'c', 'status': 'cancelled'}));
      expect(s.subagentRun('c#1')!.status, SubagentStatus.cancelled, reason: 'the call that started it was cancelled');
    });

    test('the todo tool (a `task` string and an `op`) is not a subagent', () {
      final s = _fold([
        {'sessionUpdate': 'tool_call', 'toolCallId': 't', 'title': 'task', 'kind': 'think', 'rawInput': {'op': 'done', 'task': 'step'}},
      ]);
      expect(s.subagents, isEmpty);
    });
  });

  group('codex (shapes from codex-acp\'s CollabAgentReporter; UNVERIFIED against a session)', () {
    Json spawn(String status, String childStatus, {String? message}) => {
      'sessionUpdate': 'tool_call',
      'toolCallId': 'call-spawn',
      'title': 'spawnAgent',
      'kind': 'other',
      'status': status == 'inProgress' ? 'in_progress' : 'completed',
      'rawInput': {
        'prompt': 'Find the current weather in Paris.\nBe brief.',
        'senderThreadId': 'thread-main',
        'receiverThreadIds': ['thread-paris'],
        'agentsStates': {
          'thread-paris': {'status': childStatus, 'message': message},
        },
        'model': null,
        'reasoningEffort': null,
        'status': status,
      },
    };

    test('a spawn is one run keyed by the child thread; status from agentsStates; no transcript', () {
      var s = _fold([spawn('inProgress', 'running', message: 'Checking weather')]);
      var run = s.subagents.single;
      expect(run.id, 'thread-paris');
      expect(run.parentToolCallId, 'call-spawn');
      expect(run.route, SubagentRoute.codex);
      expect(run.title, 'Find the current weather in Paris.');
      expect(run.assignment, startsWith('Find the current weather'));
      expect(run.status, SubagentStatus.running);
      expect(run.note, 'Checking weather');
      expect(run.hasTranscript, isFalse);
      expect(s.subagentsOfToolCall('call-spawn'), [run]);
      s = s.apply(_u(spawn('completed', 'completed')));
      run = s.subagents.single;
      expect(run.status, SubagentStatus.finished);
      expect(run.note, 'Checking weather', reason: 'null message says nothing, it does not erase');
    });

    test('errored and interrupted children', () {
      var s = _fold([spawn('completed', 'errored', message: 'The agent crashed')]);
      expect(s.subagents.single.status, SubagentStatus.failed);
      expect(s.subagents.single.failure, 'The agent crashed');
      s = _fold([spawn('completed', 'interrupted')]);
      expect(s.subagents.single.status, SubagentStatus.cancelled);
    });

    test('subAgentActivity rows of the same child update the same run', () {
      final s = _fold([
        spawn('inProgress', 'running'),
        {
          'sessionUpdate': 'tool_call',
          'toolCallId': 'act-1',
          'title': 'Complete subagent paris',
          'kind': 'other',
          'status': 'completed',
          'rawInput': {'agentThreadId': 'thread-paris', 'agentPath': 'root/paris', 'activityKind': 'completed'},
        },
      ]);
      expect(s.subagents, hasLength(1));
      expect(s.subagents.single.status, SubagentStatus.finished);
      expect(s.subagents.single.name, 'paris');
      expect(s.items.whereType<TranscriptTool>(), hasLength(2), reason: 'both stay as ordinary rows');
    });

    test('a wait on existing subagents starts none (title is not spawnAgent)', () {
      final j = spawn('inProgress', 'running');
      final s = _fold([
        {...j, 'title': 'wait'},
      ]);
      expect(s.subagents, isEmpty);
    });
  });
}
