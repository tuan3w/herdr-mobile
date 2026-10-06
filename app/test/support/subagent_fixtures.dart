// States with subagents for the UI tests, built through the real reducer from
// updates shaped as the adapters send them (Claude: `_meta.claudeCode`
// tags, from the recorded `claude/subagent` trace and claude-agent-acp's own
// scenarios; omp's `task` progress/results and codex's `collabAgentToolCall`
// from their sources, UNVERIFIED against a session, as in
// `test/acp/subagents_test.dart`).
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';

import 'fake_agent_session.dart' show permissionRequest, stateWith;
import 'turn_fixtures.dart' show richTurn, t0;

SessionUpdate parse(Json json) => SessionUpdate.parse(json);

Json cmeta(String toolName, {String? parent, Json? response}) => {
  'claudeCode': {'toolName': toolName, 'parentToolUseId': ?parent, 'toolResponse': ?response},
};

/// The `Task`/`Agent` call that starts a Claude subagent.
Json launch(
  String id, {
  String description = 'Explore the parser',
  String prompt = 'Find where the locale is lowercased.',
  String? type,
  String status = 'pending',
  String? parent,
  Json? response,
}) => {
  'sessionUpdate': 'tool_call',
  'toolCallId': id,
  'title': 'Task',
  'kind': 'think',
  'status': status,
  'rawInput': {'description': description, 'prompt': prompt, 'subagent_type': ?type},
  '_meta': cmeta('Agent', parent: parent, response: response),
};

Json toolUpdate(String id, {String? parent, String? status, String tool = 'Agent', Json? response}) => {
  'sessionUpdate': 'tool_call_update',
  'toolCallId': id,
  'status': ?status,
  '_meta': cmeta(tool, parent: parent, response: response),
};

/// A call a subagent made.
Json childTool(String id, String parent, {String tool = 'Grep', String title = 'Grep locale', String kind = 'search', String status = 'in_progress'}) => {
  'sessionUpdate': 'tool_call',
  'toolCallId': id,
  'title': title,
  'kind': kind,
  'status': status,
  'rawInput': {'pattern': 'locale'},
  '_meta': cmeta(tool, parent: parent),
};

Json childText(String parent, String text, {String id = 'child-msg'}) => {
  'sessionUpdate': 'agent_message_chunk',
  'messageId': id,
  'content': {'type': 'text', 'text': text},
  '_meta': {
    'claudeCode': {'parentToolUseId': parent},
  },
};

Json mainText(String text, {String id = 'main-msg'}) => {
  'sessionUpdate': 'agent_message_chunk',
  'messageId': id,
  'content': {'type': 'text', 'text': text},
};

/// The end of a Claude subagent call: what `toolResponse` carries.
Json finished(String id, {String text = 'Found it in parse.dart.', int seconds = 31, int tools = 12, String type = 'Explore'}) =>
    toolUpdate(
      id,
      status: 'completed',
      response: {
        'status': 'completed',
        'agentType': type,
        'totalDurationMs': seconds * 1000,
        'totalToolUseCount': tools,
        'totalTokens': 52000,
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
    );

/// A session after the person asked [goal], with [updates] applied one second
/// apart from [start] seconds after [t0]. The turn runs unless [active] is false.
AgentSessionState play(
  Iterable<Json> updates, {
  String goal = 'Fix the Hà Nội locale bug in the parser',
  int start = 1,
  bool active = true,
  AgentSessionState? from,
}) {
  var s = (from ?? const AgentSessionState('s1')).withUserMessage([TextBlock(goal)], at: t0).withTurnStarted();
  var i = start;
  for (final j in updates) {
    s = s.apply(parse(j), at: t0.add(Duration(seconds: i++)));
  }
  return active ? s : s.withTurnEnded(StopReason.endTurn, at: t0.add(Duration(seconds: i + 1)));
}

/// The permission request of the call [toolId].
PermissionRequest askFor(String toolId, {String title = 'rtk ls -1 /tmp/scratch', String kind = 'execute'}) => PermissionRequest(
  sessionId: 's1',
  toolCall: ToolCallPatch(toolId, {
    'toolCallId': toolId,
    'title': title,
    'kind': kind,
    'rawInput': {'command': title},
  }),
  options: const [
    PermissionOption(optionId: 'allow-once', name: 'Yes', kind: PermissionOptionKind.allowOnce),
    PermissionOption(optionId: 'reject', name: 'No', kind: PermissionOptionKind.rejectOnce),
  ],
);

// -- omp ------------------------------------------------------------------------

Json ompProgress(int i, String id, String status, {Json? extra}) => {
  'index': i,
  'id': id,
  'agent': 'explore',
  'status': status,
  'task': 'Find $id',
  'assignment': 'Assignment for $id: read the files and report what you find.',
  'description': 'Look into $id',
  'currentTool': 'grep',
  'currentToolArgs': 'parser src/',
  'recentTools': [
    {'tool': 'read', 'args': 'a.ts', 'endMs': 1},
    {'tool': 'grep', 'args': 'x', 'endMs': 2},
  ],
  'recentOutput': ['line one of the output', 'line two of the output'],
  'toolCount': 4,
  'requests': 2,
  'tokens': 12340,
  'cost': 0.0512,
  'durationMs': 42000,
  'resolvedModel': 'anthropic/claude-sonnet',
  'completionPercent': 60,
  ...?extra,
};

/// An omp `task` call with progress for [progress] and, when given, results.
List<Json> ompTask(String callId, List<Json> progress, {List<Json>? results, String status = 'in_progress'}) => [
  {
    'sessionUpdate': 'tool_call',
    'toolCallId': callId,
    'title': 'task',
    'kind': 'other',
    'status': 'pending',
    'rawInput': {
      'tasks': [
        for (final p in progress) {'name': p['id'], 'agent': 'explore', 'task': p['task']},
      ],
    },
  },
  {
    'sessionUpdate': 'tool_call_update',
    'toolCallId': callId,
    'status': status,
    'rawOutput': {
      'content': [],
      'details': {'progress': progress, 'results': results ?? [], 'totalDurationMs': 0},
    },
  },
];

// -- codex ----------------------------------------------------------------------

Json codexSpawn(String thread, String childStatus, {String status = 'inProgress', String? message, String prompt = 'Find the current weather in Paris.\nBe brief.'}) => {
  'sessionUpdate': 'tool_call',
  'toolCallId': 'spawn-$thread',
  'title': 'spawnAgent',
  'kind': 'other',
  'status': status == 'inProgress' ? 'in_progress' : 'completed',
  'rawInput': {
    'prompt': prompt,
    'senderThreadId': 'thread-main',
    'receiverThreadIds': [thread],
    'agentsStates': {
      thread: {'status': childStatus, 'message': message},
    },
    'status': status,
  },
};

/// A session with everything the overview can show: a first goal, a plan,
/// changed files and commands (one failed), subagents, a dangerous mode, a
/// nearly full context with a cost, the last turn's tokens and a request.
AgentSessionState overviewState() {
  var s = play(
    [launch('a', status: 'in_progress'), launch('b', status: 'in_progress'), finished('b')],
    from: stateWith(
      items: richTurn(),
      plan: const [
        PlanEntry(content: 'Read the parser', status: PlanStatus.completed),
        PlanEntry(content: 'Fix the Hà Nội locale bug in the parser module and add a test', status: PlanStatus.inProgress),
        PlanEntry(content: 'Run the tests'),
      ],
      modes: const ModeState(
        currentModeId: 'bypassPermissions',
        availableModes: [SessionMode(id: 'bypassPermissions', name: 'Bypass Permissions')],
      ),
    ),
  );
  s = s.withPending(PendingPermission(1, permissionRequest(title: 'Run flutter test')));
  s = s.apply(parse({'sessionUpdate': 'usage_update', 'used': 182000, 'size': 200000, 'cost': {'amount': 1.2345, 'currency': 'USD'}}));
  return s.withTurnEnded(
    StopReason.endTurn,
    usage: const TurnUsage(totalTokens: 12000, inputTokens: 9000, outputTokens: 3000),
    at: t0.add(const Duration(seconds: 100)),
  );
}
