import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';

SessionUpdate _u(Json json) => SessionUpdate.parse(json);

SessionUpdate _chunk(String type, String text, {String? id}) => _u({
  'sessionUpdate': type,
  'content': {'type': 'text', 'text': text},
  'messageId': ?id,
});

AgentSessionState _fold(Iterable<SessionUpdate> updates, [AgentSessionState? from]) =>
    updates.fold(from ?? const AgentSessionState('s'), (s, u) => s.apply(u));

List<TranscriptMessage> _messages(AgentSessionState s) => s.items.whereType<TranscriptMessage>().toList();

void main() {
  group('messages', () {
    test('chunks with one messageId append into one message, adjacent text merges', () {
      final s = _fold([
        _chunk('agent_message_chunk', 'Hel', id: 'a'),
        _chunk('agent_message_chunk', 'lo ', id: 'a'),
        _chunk('agent_message_chunk', 'world', id: 'a'),
      ]);
      final m = _messages(s).single;
      expect(m.text, 'Hello world');
      expect(m.blocks, hasLength(1));
      expect(m.messageId, 'a');
    });

    test('a new messageId is a new message, even for the same role in a row', () {
      final s = _fold([
        _chunk('agent_message_chunk', 'one', id: 'a'),
        _chunk('agent_message_chunk', 'two', id: 'b'),
      ]);
      expect(_messages(s).map((m) => m.text), ['one', 'two']);
      expect(_messages(s).map((m) => m.key).toSet(), hasLength(2));
    });

    test('a thought and an answer sharing one messageId stay two messages', () {
      // omp replays both with a single id.
      final s = _fold([
        _chunk('agent_thought_chunk', 'hmm', id: 'x'),
        _chunk('agent_message_chunk', 'answer', id: 'x'),
        _chunk('agent_thought_chunk', ' more', id: 'x'),
      ]);
      final ms = _messages(s);
      expect(ms, hasLength(2));
      expect(ms[0].role, MessageRole.thought);
      expect(ms[0].text, 'hmm more');
      expect(ms[1].text, 'answer');
    });

    test('chunks without an id continue the last message of their role', () {
      final s = _fold([
        _chunk('agent_message_chunk', 'a'),
        _chunk('agent_message_chunk', 'b'),
        _chunk('agent_thought_chunk', 't'),
        _chunk('agent_message_chunk', 'c'),
      ]);
      expect(_messages(s).map((m) => m.text), ['ab', 't', 'c']);
    });

    test('a tool call between chunks of the same role ends the message', () {
      final s = _fold([
        _chunk('agent_message_chunk', 'before'),
        _u({'sessionUpdate': 'tool_call', 'toolCallId': 't1', 'title': 'ls'}),
        _chunk('agent_message_chunk', 'after'),
      ]);
      expect(s.items.map((i) => i.runtimeType), [TranscriptMessage, TranscriptTool, TranscriptMessage]);
    });

    test('an old id arriving late appends to that message, not the last one', () {
      final s = _fold([
        _chunk('agent_message_chunk', 'A1', id: 'a'),
        _chunk('agent_message_chunk', 'B1', id: 'b'),
        _chunk('agent_message_chunk', 'A2', id: 'a'),
      ]);
      expect(_messages(s).map((m) => m.text), ['A1A2', 'B1']);
    });

    test('non-text blocks are kept as their own blocks between merged text', () {
      final s = _fold([
        _chunk('agent_message_chunk', 'see ', id: 'a'),
        _u({
          'sessionUpdate': 'agent_message_chunk',
          'messageId': 'a',
          'content': {'type': 'image', 'data': 'AAAA', 'mimeType': 'image/png'},
        }),
        _chunk('agent_message_chunk', 'this', id: 'a'),
        _chunk('agent_message_chunk', '!', id: 'a'),
      ]);
      final blocks = _messages(s).single.blocks;
      expect(blocks.map((b) => b.runtimeType), [TextBlock, ImageBlock, TextBlock]);
      expect((blocks.last as TextBlock).text, 'this!');
    });

    test('a replay opened with content [] then chunks fills the same message', () {
      final s = _fold([
        _u({'sessionUpdate': 'agent_message', 'messageId': 'm1', 'content': <Object>[]}),
        _chunk('agent_message_chunk', 'stream', id: 'm1'),
        _chunk('agent_message_chunk', 'ed', id: 'm1'),
      ]);
      final m = _messages(s).single;
      expect(m.text, 'streamed');
      expect(m.messageId, 'm1');
    });

    test('a full update replaces the blocks; omitted content keeps; null clears', () {
      var s = _fold([_chunk('agent_message_chunk', 'draft', id: 'm1')]);
      s = s.apply(
        _u({
          'sessionUpdate': 'agent_message',
          'messageId': 'm1',
          'content': [
            {'type': 'text', 'text': 'final'},
          ],
        }),
      );
      expect(_messages(s).single.text, 'final');
      s = s.apply(_u({'sessionUpdate': 'agent_message', 'messageId': 'm1', '_meta': {'k': 1}}));
      expect(_messages(s).single.text, 'final', reason: 'no content key: unchanged');
      s = s.apply(_u({'sessionUpdate': 'agent_message', 'messageId': 'm1', 'content': null}));
      expect(_messages(s).single.blocks, isEmpty);
      expect(_messages(s), hasLength(1), reason: 'same message throughout');
    });

    test('user messages replayed from session/load come in as user messages', () {
      final s = _fold([
        _chunk('user_message_chunk', 'fix the bug', id: 'u1'),
        _chunk('agent_message_chunk', 'done', id: 'a1'),
      ]);
      expect(_messages(s).map((m) => (m.role, m.text)), [(MessageRole.user, 'fix the bug'), (MessageRole.agent, 'done')]);
    });
  });

  group('echo of the local prompt', () {
    test('an agent that echoes the prompt does not show it twice, in any chunking', () {
      for (final pieces in [
        ['hello world'],
        ['hello', ' ', 'world'],
        ['h', 'ello world'],
      ]) {
        var s = const AgentSessionState('s').withUserMessage([const TextBlock('hello world')]).withTurnStarted();
        for (final p in pieces) {
          s = s.apply(_chunk('user_message_chunk', p, id: 'u1'));
        }
        final users = _messages(s).where((m) => m.role == MessageRole.user).toList();
        expect(users, hasLength(1), reason: '$pieces');
        expect(users.single.messageId, 'u1', reason: 'adopts the agent id');
        expect(users.single.local, isFalse);
      }
    });

    test('a user chunk that is not the echo is a message of its own', () {
      var s = const AgentSessionState('s').withUserMessage([const TextBlock('hello')]);
      s = s.apply(_chunk('user_message_chunk', 'something else', id: 'u2'));
      expect(_messages(s).map((m) => m.text), ['hello', 'something else']);
    });

    test('the agent answering without an echo leaves the local message alone', () {
      final s = const AgentSessionState('s')
          .withUserMessage([const TextBlock('hi')])
          .apply(_chunk('agent_message_chunk', 'hello'));
      expect(_messages(s).map((m) => (m.role, m.text)), [(MessageRole.user, 'hi'), (MessageRole.agent, 'hello')]);
    });
  });

  group('tool calls', () {
    SessionUpdate start() => _u({
      'sessionUpdate': 'tool_call',
      'toolCallId': 't1',
      'name': 'Bash',
      'title': 'Run tests',
      'kind': 'execute',
      'status': 'pending',
      'rawInput': {'command': 'dart test'},
      'content': [
        {
          'type': 'content',
          'content': {'type': 'text', 'text': r'$ dart test'},
        },
      ],
      'locations': [
        {'path': '/repo/a.dart', 'line': 3},
      ],
    });

    test('an update patches: omitted fields keep, null clears, present replaces', () {
      var s = _fold([start()]);
      s = s.apply(_u({'sessionUpdate': 'tool_call_update', 'toolCallId': 't1', 'status': 'in_progress'}));
      var c = s.toolCall('t1')!;
      expect(c.status, ToolStatus.inProgress);
      expect(c.title, 'Run tests');
      expect(c.name, 'Bash');
      expect(c.kind, ToolKind.execute);
      expect(c.rawInput, {'command': 'dart test'});
      expect(c.content, hasLength(1));
      expect(c.locations.single.line, 3);

      s = s.apply(
        _u({'sessionUpdate': 'tool_call_update', 'toolCallId': 't1', 'status': 'completed', 'rawOutput': {'exit': 0}, 'content': null, 'locations': []}),
      );
      c = s.toolCall('t1')!;
      expect(c.status, ToolStatus.completed);
      expect(c.rawOutput, {'exit': 0});
      expect(c.content, isEmpty, reason: 'null clears');
      expect(c.locations, isEmpty, reason: 'empty list replaces');
      expect(c.rawInput, {'command': 'dart test'}, reason: 'untouched');

      s = s.apply(_u({'sessionUpdate': 'tool_call_update', 'toolCallId': 't1', 'title': null, 'name': null, 'rawInput': null}));
      c = s.toolCall('t1')!;
      expect(c.title, '');
      expect(c.name, isNull);
      expect(c.rawInput, isNull);
      expect(c.status, ToolStatus.completed);
    });

    test('an update for a call that never started creates it, in place of the missing start', () {
      final s = _fold([_u({'sessionUpdate': 'tool_call_update', 'toolCallId': 'late', 'status': 'completed', 'title': 'Read'})]);
      expect(s.toolCall('late')!.title, 'Read');
      expect(s.toolCalls, hasLength(1));
    });

    test('calls keep the transcript position of their start, and a repeated start replaces', () {
      var s = _fold([
        start(),
        _chunk('agent_message_chunk', 'between'),
        _u({'sessionUpdate': 'tool_call', 'toolCallId': 't2', 'title': 'second'}),
      ]);
      s = s.apply(_u({'sessionUpdate': 'tool_call_update', 'toolCallId': 't1', 'status': 'completed'}));
      expect(s.items.map((i) => i.key), ['tool:t1', 'm0', 'tool:t2']);
      s = s.apply(_u({'sessionUpdate': 'tool_call', 'toolCallId': 't1', 'title': 'replayed'}));
      expect(s.toolCalls.map((c) => c.title), ['replayed', 'second']);
      expect(s.toolCall('t1')!.status, ToolStatus.pending, reason: 'a start is whole, not a patch');
    });

    test('v2 content chunks append to the call', () {
      final s = _fold([
        start(),
        _u({
          'sessionUpdate': 'tool_call_content_chunk',
          'toolCallId': 't1',
          'content': {'type': 'diff', 'path': '/a', 'oldText': 'x', 'newText': 'y'},
        }),
      ]);
      expect(s.toolCall('t1')!.content.last, isA<ToolDiff>());
      expect(s.toolCall('t1')!.content, hasLength(2));
    });

    test('unknown kind and status fall back to other and pending', () {
      final s = _fold([_u({'sessionUpdate': 'tool_call', 'toolCallId': 't', 'title': 'x', 'kind': 'teleport', 'status': 'levitating'})]);
      expect(s.toolCall('t')!.kind, ToolKind.other);
      expect(s.toolCall('t')!.status, ToolStatus.pending);
    });

    test('cancelling marks unfinished calls cancelled and leaves finished ones', () {
      var s = _fold([
        _u({'sessionUpdate': 'tool_call', 'toolCallId': 'a', 'title': 'a', 'status': 'in_progress'}),
        _u({'sessionUpdate': 'tool_call', 'toolCallId': 'b', 'title': 'b', 'status': 'completed'}),
        _u({'sessionUpdate': 'tool_call', 'toolCallId': 'c', 'title': 'c', 'status': 'failed'}),
        _u({'sessionUpdate': 'tool_call', 'toolCallId': 'd', 'title': 'd'}),
      ]).withTurnStarted();
      s = s.withCancelRequested();
      expect(s.cancelRequested, isTrue);
      expect(s.toolCalls.map((c) => c.status), [ToolStatus.cancelled, ToolStatus.completed, ToolStatus.failed, ToolStatus.cancelled]);
      s = s.withTurnEnded(StopReason.cancelled);
      expect(s.cancelRequested, isFalse);
      expect(s.turnActive, isFalse);
      expect(s.lastStopReason, StopReason.cancelled);
    });

    test('a turn that ends normally leaves unfinished calls as they are', () {
      final s = _fold([_u({'sessionUpdate': 'tool_call', 'toolCallId': 'a', 'title': 'a', 'status': 'in_progress'})])
          .withTurnStarted()
          .withTurnEnded(StopReason.endTurn);
      expect(s.toolCall('a')!.status, ToolStatus.inProgress);
    });
  });

  group('whole-list updates and session facts', () {
    test('every plan, command and config update replaces the list', () {
      var s = _fold([
        _u({
          'sessionUpdate': 'plan',
          'entries': [
            {'content': 'a', 'priority': 'high', 'status': 'in_progress'},
            {'content': 'b', 'priority': 'low', 'status': 'pending'},
          ],
        }),
        _u({
          'sessionUpdate': 'available_commands_update',
          'availableCommands': [
            {'name': 'compact', 'description': 'Compact', 'input': {'hint': 'focus'}},
            {'name': 'skill:review', 'description': 'Review'},
          ],
        }),
      ]);
      expect(s.plan.map((p) => (p.content, p.status, p.priority)), [
        ('a', PlanStatus.inProgress, PlanPriority.high),
        ('b', PlanStatus.pending, PlanPriority.low),
      ]);
      expect(s.commands.map((c) => (c.name, c.inputHint)), [('compact', 'focus'), ('skill:review', null)]);

      s = s.apply(_u({'sessionUpdate': 'plan', 'entries': <Object>[]}));
      s = s.apply(
        _u({
          'sessionUpdate': 'available_commands_update',
          'availableCommands': [
            {'name': 'only', 'description': ''},
          ],
        }),
      );
      expect(s.plan, isEmpty);
      expect(s.commands.map((c) => c.name), ['only']);
    });

    test('session info patches: absent keeps, null clears', () {
      var s = _fold([_u({'sessionUpdate': 'session_info_update', 'title': 'Fix login', 'updatedAt': '2026-10-04T10:00:00Z'})]);
      expect(s.title, 'Fix login');
      expect(s.updatedAt, DateTime.utc(2026, 10, 4, 10));
      s = s.apply(_u({'sessionUpdate': 'session_info_update', 'updatedAt': '2026-10-04T11:00:00Z'}));
      expect(s.title, 'Fix login');
      expect(s.updatedAt, DateTime.utc(2026, 10, 4, 11));
      s = s.apply(_u({'sessionUpdate': 'session_info_update', 'title': null}));
      expect(s.title, isNull);
      expect(s.updatedAt, DateTime.utc(2026, 10, 4, 11));
    });

    test('usage is replaced', () {
      final s = _fold([
        _u({'sessionUpdate': 'usage_update', 'used': 100, 'size': 1000}),
        _u({'sessionUpdate': 'usage_update', 'used': 250, 'size': 1000, 'cost': {'amount': 0.5, 'currency': 'USD'}}),
      ]);
      expect(s.usage!.used, 250);
      expect(s.usage!.fraction, 0.25);
      expect(s.usage!.costCurrency, 'USD');
    });

    test('mode updates move both the modes and the mode config option', () {
      final setup = AcpSessionSetup.parse({
        'sessionId': 's',
        'modes': {
          'currentModeId': 'default',
          'availableModes': [
            {'id': 'default', 'name': 'Default'},
            {'id': 'plan', 'name': 'Plan'},
          ],
        },
        'configOptions': [
          {
            'id': 'mode',
            'name': 'Mode',
            'category': 'mode',
            'type': 'select',
            'currentValue': 'default',
            'options': [
              {'value': 'default', 'name': 'Default'},
              {'value': 'plan', 'name': 'Plan'},
            ],
          },
          {'id': 'think', 'name': 'Think', 'type': 'boolean', 'currentValue': false},
        ],
      });
      var s = const AgentSessionState('s').withSetup(setup);
      expect(s.currentModeId, 'default');
      s = s.apply(_u({'sessionUpdate': 'current_mode_update', 'currentModeId': 'plan'}));
      expect(s.currentModeId, 'plan');
      expect(s.modes!.currentModeId, 'plan');
      expect((s.configOptions.first as SelectConfigOption).value, 'plan');
      expect(s.configOptions.last, isA<BooleanConfigOption>());

      // A config update that changes the mode option moves `modes` too.
      s = s.apply(
        _u({
          'sessionUpdate': 'config_option_update',
          'configOptions': [
            {
              'id': 'mode',
              'name': 'Mode',
              'category': 'mode',
              'type': 'select',
              'currentValue': 'default',
              'options': [
                {'value': 'default', 'name': 'Default'},
              ],
            },
          ],
        }),
      );
      expect(s.modes!.currentModeId, 'default');
      expect(s.configOptions, hasLength(1));
    });

    test('unknown updates and unknown variants change nothing and are not fatal', () {
      final s = _fold([_chunk('agent_message_chunk', 'x', id: 'a')]);
      for (final raw in <Object?>[
        {'sessionUpdate': 'telepathy_update', 'x': 1},
        {'sessionUpdate': '_vendor_thing'},
        {'noType': true},
        'a string',
        null,
        {'sessionUpdate': 'tool_call_update', 'toolCallId': 5},
        {'sessionUpdate': 'agent_message_chunk', 'content': 'oops'},
      ]) {
        final u = SessionUpdate.parse(raw);
        expect(() => s.apply(u), returnsNormally, reason: '$raw');
      }
      final unknown = SessionUpdate.parse({'sessionUpdate': 'telepathy_update', 'x': 1});
      expect(unknown, isA<UnknownUpdate>().having((u) => u.type, 'type', 'telepathy_update').having((u) => u.raw['x'], 'raw', 1));
      expect(identical(s.apply(unknown), s), isTrue);
    });
  });

  group('phase', () {
    final permission = PermissionRequest.parse({
      'sessionId': 's',
      'toolCall': {'toolCallId': 't', 'title': 'rm'},
      'options': [
        {'optionId': 'y', 'name': 'Yes', 'kind': 'allow_once'},
      ],
    });
    final question = ElicitationRequest.parse({'mode': 'form', 'message': 'Which?', 'sessionId': 's', 'requestedSchema': {'type': 'object'}});

    test('idle, working, blocked on permission, blocked on question', () {
      var s = const AgentSessionState('s');
      expect(s.phase, AgentPhase.idle);
      s = s.withTurnStarted();
      expect(s.phase, AgentPhase.working);
      s = s.withPending(PendingQuestion(2, question));
      expect(s.phase, AgentPhase.blockedOnQuestion);
      s = s.withPending(PendingPermission(1, permission));
      expect(s.phase, AgentPhase.blockedOnPermission, reason: 'a permission outranks a question');
      expect(s.pending.map((p) => p.id), [2, 1], reason: 'oldest first');
      s = s.withoutPending(1);
      expect(s.phase, AgentPhase.blockedOnQuestion);
      s = s.withoutPending(2);
      expect(s.phase, AgentPhase.working);
      s = s.withTurnEnded(StopReason.endTurn);
      expect(s.phase, AgentPhase.idle);
    });

    test('answering an id that is not pending changes nothing', () {
      final s = const AgentSessionState('s').withPending(PendingPermission(1, permission));
      expect(identical(s.withoutPending(99), s), isTrue);
    });

    test('v2 state updates drive the phase', () {
      var s = _fold([_u({'sessionUpdate': 'state_update', 'state': 'running'})]);
      expect(s.phase, AgentPhase.working);
      s = s.apply(_u({'sessionUpdate': 'state_update', 'state': 'requires_action'}));
      expect(s.phase, AgentPhase.blockedOnQuestion);
      s = s.apply(_u({'sessionUpdate': 'state_update', 'state': 'idle', 'stopReason': 'end_turn'}));
      expect(s.phase, AgentPhase.idle);
      expect(s.lastStopReason, StopReason.endTurn);
    });

    test('losing the connection clears pending requests and the running turn', () {
      final s = const AgentSessionState('s')
          .withTurnStarted()
          .withPending(PendingPermission(1, permission))
          .withDisconnected();
      expect(s.pending, isEmpty);
      expect(s.phase, AgentPhase.idle);
      expect(s.disconnected, isTrue);
    });
  });

  test('the reducer is deterministic and does not mutate earlier states', () {
    final updates = [
      _chunk('agent_message_chunk', 'a', id: 'x'),
      _u({'sessionUpdate': 'tool_call', 'toolCallId': 't', 'title': 'T'}),
      _chunk('agent_message_chunk', 'b', id: 'x'),
    ];
    final first = _fold(updates);
    final second = _fold(updates);
    expect(first.items.map((i) => i.key), second.items.map((i) => i.key));
    expect(_messages(first).map((m) => m.text), _messages(second).map((m) => m.text));

    // A settled message never changes under an earlier state.
    final before = _fold(updates.take(2));
    final textBefore = _messages(before).single.text;
    before.apply(updates.last);
    expect(_messages(before).single.text, textBefore, reason: 'applying returned a new state');
  });

  test('the one exception: the message streaming right now grows in place, in every state that shares it', () {
    final before = _fold([_chunk('agent_message_chunk', 'a', id: 'x')]);
    final after = before.apply(_chunk('agent_message_chunk', 'b', id: 'x'));
    expect(identical(before.items, after.items), isTrue, reason: 'the list is not copied per chunk');
    expect(_messages(before).single.text, 'ab', reason: 'the live text is shared (see AgentSessionState)');
    expect(_messages(after).single.text, 'ab');
  });
}
