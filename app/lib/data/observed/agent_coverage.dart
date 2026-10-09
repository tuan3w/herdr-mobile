/// What each agent's log can hold, and what the app does with each kind of it.
///
/// This is the one place that says which kinds of tool call, item and event the
/// mappers know. It exists so that an agent update that adds a kind cannot be
/// missed: `tool/sync-agent-schemas.sh` writes the kinds the INSTALLED agent
/// ships a schema for (Codex: `codex app-server generate-json-schema`; Claude
/// Code: the tool schemas of `@anthropic-ai/claude-agent-sdk`) into
/// `test/fixtures/schemas/`, and `test/agent_coverage_test.dart` fails when a
/// kind there is not in these tables. Adding a row is the decision: map it, show
/// it generically, or say why it is ignored.
///
/// Values: `shown: <how>` (the app has its own rendering or state for it),
/// `generic` (a plain row with the tool's name and title), `ignored: <why>`
/// (nothing to show). A kind the tables do not list is still shown generically
/// (Claude: any tool call; Codex: any item), never dropped.
library;

/// Claude Code tool names (`tool_use.name`), by the name of the tool's input type
/// in the official SDK schema where they differ (`FileEdit` is `Edit`).
const claudeToolCoverage = <String, String>{
  'Agent': 'shown: subagent roster, background task, transcript',
  'Bash': 'shown: command row, background task',
  'ExitPlanMode': 'shown: plan on the approval card',
  'EnterPlanMode': 'generic',
  'Edit': 'shown: diff',
  'Write': 'shown: diff',
  'Read': 'generic',
  'NotebookEdit': 'generic',
  'Glob': 'generic',
  'Grep': 'generic',
  'TaskStop': 'shown: ends a background task',
  'TodoWrite': 'shown: plan',
  'TaskCreate': 'shown: plan',
  'TaskUpdate': 'shown: plan',
  'TaskGet': 'generic',
  'TaskList': 'generic',
  'AskUserQuestion': 'shown: question form',
  'Workflow': 'shown: background task (workflow)',
  'Monitor': 'shown: background task (monitor)',
  'WebFetch': 'generic',
  'WebSearch': 'generic',
  'Mcp': 'generic',
  'ListMcpResources': 'generic',
  'ReadMcpResource': 'generic',
  'ReadMcpResourceDir': 'generic',
  'RefreshMcpTools': 'generic',
  'ReportFindings': 'generic',
  'SendFeedback': 'generic',
  'ClaudeDesign': 'generic',
  'Projects': 'generic',
  'CronCreate': 'generic',
  'CronDelete': 'generic',
  'CronList': 'generic',
  'ScheduleWakeup': 'generic',
  'RemoteTrigger': 'generic',
  'ShowOnboardingRolePicker': 'generic',
  'OfferChromeSetup': 'generic',
  'ReadNotifications': 'generic',
  'ProposeSkills': 'generic',
  'ProposeGoal': 'generic',
  'Artifact': 'generic',
  'PushNotification': 'generic',
  'EnterWorktree': 'generic',
  'ExitWorktree': 'generic',
  // Tools of the build that the SDK's tool schema does not list.
  'Skill': 'generic',
  'ToolSearch': 'generic',
  'SendMessage': 'generic',
  'ListAgents': 'generic',
  'KillShell': 'shown: ends a background task',
  'BashOutput': 'generic',
};

/// The `ThreadItem` kinds of Codex's protocol (the rollout writes them
/// PascalCase: `CommandExecution`).
const codexItemCoverage = <String, String>{
  'UserMessage': 'shown: message',
  'AgentMessage': 'shown: message',
  'Plan': 'shown: message',
  'CommandExecution': 'shown: command row, ends a background process',
  'FileChange': 'shown: diff',
  'McpToolCall': 'shown: row',
  'WebSearch': 'shown: row (shape from the schema, not captured)',
  'DynamicToolCall': 'shown: row (shape from the schema, not captured)',
  'ImageView': 'shown: row',
  'ImageGeneration': 'shown: row (shape from the schema, not captured)',
  'SubAgentActivity': 'shown: subagent roster',
  'ContextCompaction': 'shown: note',
  'EnteredReviewMode': 'shown: note (not captured)',
  'ExitedReviewMode': 'shown: note (not captured)',
  'Reasoning': 'ignored: always empty in the log',
  'HookPrompt': 'ignored: text for the model',
  'FunctionCallOutput': 'ignored: the call\'s output is read from its response_item',
  'CollabAgentToolCall': 'ignored: spawn_agent and wait calls are their own rows',
  'Sleep': 'ignored: a wait, nothing to read',
};

/// The model's own function calls (`response_item.function_call.name`) of Codex
/// that are not an `exec` script.
const codexFunctionCoverage = <String, String>{
  'wait': 'shown: ends a cell',
  'wait_agent': 'ignored: a wait',
  'request_user_input_async': 'ignored: shows through its question',
  'request_user_input': 'shown: row with its question',
  'update_plan': 'shown: plan (shape not captured)',
  'exec_command': 'shown: command row (legacy)',
  'shell': 'shown: command row (legacy)',
  'spawn_agent': 'shown: row, subagent roster',
};
