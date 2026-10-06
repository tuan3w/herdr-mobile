import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';

// Data the chat used to drop: command output from `_meta`, stop reasons, kept
// `_meta` and turn usage, the activity stamp and the auto-resolution time of a
// question (model side).

SessionUpdate _u(Json json) => SessionUpdate.parse(json);

AgentSessionState _fold(Iterable<Json> updates, [AgentSessionState? from]) =>
    updates.fold(from ?? const AgentSessionState('s'), (s, json) => s.apply(_u(json)));

/// codex-acp / pi-acp announce a command like this: output only in `_meta`.
Json _start(String id, {String cwd = '/w', String status = 'in_progress'}) => {
  'sessionUpdate': 'tool_call',
  'toolCallId': id,
  'title': 'ls',
  'kind': 'execute',
  'status': status,
  'rawInput': {'command': 'ls'},
  'content': [
    {'type': 'terminal', 'terminalId': id},
  ],
  '_meta': {
    'terminal_info': {'cwd': cwd, 'terminal_id': id},
  },
};

Json _delta(String id, String data, {String key = 'terminal_output_delta'}) => {
  'sessionUpdate': 'tool_call_update',
  'toolCallId': id,
  '_meta': {
    key: {'terminal_id': id, 'data': data},
  },
};

Json _exit(String id, {int? code = 0, String? signal, String? status = 'completed'}) => {
  'sessionUpdate': 'tool_call_update',
  'toolCallId': id,
  'status': ?status,
  '_meta': {
    'terminal_exit': {'terminal_id': id, 'exit_code': code, 'signal': signal},
  },
};

ToolOutput _out(AgentSessionState s, String id) => s.toolCall(id)!.output!;

void main() {
  group('command output from _meta', () {
    test('codex-acp: deltas append in arrival order, the exit and cwd are kept', () {
      final s = _fold([
        _start('c1'),
        _delta('c1', 'a.txt\n'),
        _delta('c1', 'b.txt\n'),
        _exit('c1', code: 0),
      ]);
      final call = s.toolCall('c1')!;
      expect(call.output!.text, 'a.txt\nb.txt\n');
      expect(call.output!.exited, isTrue);
      expect(call.output!.exitCode, 0);
      expect(call.output!.failed, isFalse);
      expect(call.status, ToolStatus.completed);
      expect(call.cwd, '/w');
      expect(call.content.single, isA<ToolTerminal>(), reason: 'the content is untouched');
      expect(call.meta, {
        'terminal_info': {'cwd': '/w', 'terminal_id': 'c1'},
      }, reason: 'the chunks are consumed, not kept a second time');
    });

    test('pi-acp: terminal_output deltas and a failing exit', () {
      final s = _fold([
        _start('p1'),
        _delta('p1', 'FAIL test/a_test.dart\n', key: 'terminal_output'),
        _delta('p1', '1 failed\n', key: 'terminal_output'),
        _exit('p1', code: 1, status: 'failed'),
      ]);
      final out = _out(s, 'p1');
      expect(out.text, 'FAIL test/a_test.dart\n1 failed\n');
      expect(out.exitCode, 1);
      expect(out.failed, isTrue);
      expect(s.toolCall('p1')!.status, ToolStatus.failed);
    });

    test('output and exit in one update (codex-acp sends the whole output at the end when nothing streamed)', () {
      final s = _fold([
        _start('c2'),
        {
          'sessionUpdate': 'tool_call_update',
          'toolCallId': 'c2',
          'status': 'completed',
          '_meta': {
            'terminal_output_delta': {'terminal_id': 'c2', 'data': 'a.txt\nb.txt\n'},
            'terminal_exit': {'terminal_id': 'c2', 'exit_code': 0, 'signal': null},
          },
        },
      ]);
      expect(_out(s, 'c2').text, 'a.txt\nb.txt\n');
      expect(_out(s, 'c2').exited, isTrue);
    });

    test('a signal ends the command as a failure; an unknown exit code is not one', () {
      var s = _fold([_start('k'), _exit('k', code: null, signal: 'SIGTERM', status: 'failed')]);
      expect(_out(s, 'k').signal, 'SIGTERM');
      expect(_out(s, 'k').failed, isTrue);

      s = _fold([_start('u'), _exit('u', code: null)]);
      expect(_out(s, 'u').exited, isTrue);
      expect(_out(s, 'u').exitCode, isNull);
      expect(_out(s, 'u').failed, isFalse, reason: 'codex sends exit_code null when it cannot tell');
    });

    test('an update that arrives before its start creates the call; the start keeps what was printed', () {
      var s = _fold([_delta('c', 'early\n')]);
      expect(s.toolCall('c')!.output!.text, 'early\n');
      expect(s.toolCalls, hasLength(1));

      s = s.apply(_u(_start('c')));
      expect(s.toolCall('c')!.title, 'ls', reason: 'the start still replaces the fields');
      expect(s.toolCall('c')!.output!.text, 'early\n');

      s = s.apply(_u(_delta('c', 'late\n')));
      expect(s.toolCall('c')!.output!.text, 'early\nlate\n');
      expect(s.items, hasLength(1), reason: 'one row, where the first update put it');
    });

    test('a repeated start, a repeated exit and updates without deltas do not duplicate or lose output', () {
      var s = _fold([_start('c'), _delta('c', 'once\n'), _exit('c', code: 2, status: 'failed')]);
      s = s.apply(_u(_start('c', status: 'completed')));
      expect(_out(s, 'c').text, 'once\n', reason: 'a repeated start adds nothing');
      expect(_out(s, 'c').exitCode, 2, reason: 'and forgets nothing');

      s = s.apply(_u(_exit('c', code: 3, status: null)));
      expect(_out(s, 'c').exitCode, 3, reason: 'the last exit wins');
      expect(_out(s, 'c').text, 'once\n');

      s = s.apply(_u({'sessionUpdate': 'tool_call_update', 'toolCallId': 'c', 'status': 'failed', 'title': 'again'}));
      s = s.apply(_u({'sessionUpdate': 'tool_call_update', 'toolCallId': 'c', '_meta': null}));
      expect(_out(s, 'c').text, 'once\n');
      expect(s.toolCall('c')!.meta, isNull, reason: '_meta: null clears the meta, not what was printed');
    });

    test('a start that carries output of its own appends it to what came before', () {
      final withOutput = _start('c')
        ..['_meta'] = {
          'terminal_output_delta': {'terminal_id': 'c', 'data': 'in the start\n'},
        };
      final s = _fold([_delta('c', 'before\n'), withOutput]);
      expect(_out(s, 'c').text, 'before\nin the start\n');
    });

    test('other meta keys merge key by key across updates', () {
      final s = _fold([
        _start('c'),
        {
          'sessionUpdate': 'tool_call_update',
          'toolCallId': 'c',
          '_meta': {
            'codex': {'tool': 'exec'},
          },
        },
        {
          'sessionUpdate': 'tool_call_update',
          'toolCallId': 'c',
          '_meta': {
            'codex': {'tool': 'exec2'},
            'is_mcp_tool_call': false,
          },
        },
      ]);
      expect(s.toolCall('c')!.meta, {
        'terminal_info': {'cwd': '/w', 'terminal_id': 'c'},
        'codex': {'tool': 'exec2'},
        'is_mcp_tool_call': false,
      });
      expect(s.toolCall('c')!.output, isNull, reason: 'nothing was printed');
    });

    test('terminal_input is not output; MCP progress is collected apart from the terminal text', () {
      var s = _fold([
        _start('c'),
        {
          'sessionUpdate': 'tool_call_update',
          'toolCallId': 'c',
          '_meta': {
            'terminal_input': {'terminal_id': 'c', 'data': 'y'},
          },
        },
      ]);
      expect(s.toolCall('c')!.output, isNull);
      expect(s.toolCall('c')!.meta!.containsKey('terminal_input'), isFalse);

      s = _fold([
        {'sessionUpdate': 'tool_call', 'toolCallId': 'm', 'title': 'mcp.docs.search', 'kind': 'execute', '_meta': {'is_mcp_tool_call': true}},
        {
          'sessionUpdate': 'tool_call_update',
          'toolCallId': 'm',
          '_meta': {
            'mcp_output_delta': {'data': 'fetching page 1'},
          },
        },
        {
          'sessionUpdate': 'tool_call_update',
          'toolCallId': 'm',
          '_meta': {
            'mcp_output_delta': {'data': 'fetching page 2'},
          },
        },
      ]);
      expect(_out(s, 'm').progress, 'fetching page 1\nfetching page 2\n');
      expect(_out(s, 'm').text, isEmpty);
      expect(s.toolCall('m')!.meta, {'is_mcp_tool_call': true});
    });

    test('the cap keeps the end, starts at a line, and says how much was cut', () {
      var s = _fold([_start('big')]);
      var total = 0;
      for (var i = 0; i < 1000; i++) {
        final chunk = '$i:${'x' * 99}\n';
        total += chunk.length;
        s = s.apply(_u(_delta('big', chunk)));
        expect(_out(s, 'big').text.length, lessThanOrEqualTo(ToolOutput.outputKeep + ToolOutput.outputKeep ~/ 4));
      }
      final out = _out(s, 'big');
      expect(out.text, endsWith('999:${'x' * 99}\n'));
      expect(out.cutChars, greaterThan(0));
      expect(out.cutChars + out.text.length, total, reason: 'every character is either kept or counted as cut');
      expect(RegExp(r'^\d+:x{99}\n').hasMatch(out.text), isTrue, reason: 'the cut falls on a line start');
    });

    test('one huge chunk is cut to the cap, never inside a surrogate pair', () {
      final s = _fold([_start('e'), _delta('e', 'a${'😀' * 100000}b')]);
      final out = _out(s, 'e');
      expect(out.text.runes.first, 0x1F600);
      expect(out.text.length, lessThanOrEqualTo(ToolOutput.outputKeep));
      expect(out.text, endsWith('😀b'));
    });

    test('v2 content chunks and a cancelled turn keep the output', () {
      var s = _fold([
        _start('c'),
        _delta('c', 'partial\n'),
        {
          'sessionUpdate': 'tool_call_content_chunk',
          'toolCallId': 'c',
          'content': {'type': 'diff', 'path': '/a', 'newText': 'n'},
        },
      ]).withTurnStarted();
      expect(_out(s, 'c').text, 'partial\n');
      s = s.withCancelRequested().withTurnEnded(StopReason.cancelled);
      expect(s.toolCall('c')!.status, ToolStatus.cancelled);
      expect(_out(s, 'c').text, 'partial\n');
    });

    test('a permission request names its call without output', () {
      final p = PermissionRequest.parse({
        'sessionId': 's',
        'toolCall': {'toolCallId': 'c', 'title': 'rm'},
        'options': [
          {'optionId': 'y', 'name': 'Yes', 'kind': 'allow_once'},
        ],
      });
      expect(p.toolCall.applyTo(null).output, isNull);
    });
  });

  group('stop reasons', () {
    AgentSessionState turn() => const AgentSessionState('s').withUserMessage([const TextBlock('go')]).withTurnStarted();

    test('a refusal, the length limit and the step limit each leave one stop row', () {
      for (final reason in [StopReason.refusal, StopReason.maxTokens, StopReason.maxTurnRequests]) {
        final s = turn().withTurnEnded(reason);
        expect(s.items.last, isA<TranscriptStop>().having((i) => i.reason, 'reason', reason), reason: '$reason');
        expect(s.items.whereType<TranscriptStop>(), hasLength(1));
        expect(s.phase, AgentPhase.idle);
        expect(s.lastStopReason, reason);
      }
    });

    test('the row sits after what the agent did, with a stable key of its own', () {
      final s = turn()
          .apply(_u({'sessionUpdate': 'agent_message_chunk', 'messageId': 'a', 'content': {'type': 'text', 'text': 'cut o'}}))
          .withTurnEnded(StopReason.maxTokens);
      expect(s.items.map((i) => i.runtimeType), [TranscriptMessage, TranscriptMessage, TranscriptStop]);
      final keys = s.items.map((i) => i.key).toList();
      expect(keys.toSet(), hasLength(3));
      // Later updates do not rename it.
      final later = s.apply(_u({'sessionUpdate': 'session_info_update', 'title': 'T'}));
      expect(later.items.map((i) => i.key), keys);
    });

    test('end of turn, a cancelled turn and an error leave no row', () {
      for (final reason in [StopReason.endTurn, StopReason.cancelled, StopReason.error, StopReason.unknown]) {
        expect(turn().withTurnEnded(reason).items.whereType<TranscriptStop>(), isEmpty, reason: '$reason');
      }
    });

    test('the v2 state_update and the response that both report the end make one row', () {
      var s = turn().apply(_u({'sessionUpdate': 'state_update', 'state': 'idle', 'stopReason': 'refusal'}));
      expect(s.items.whereType<TranscriptStop>(), hasLength(1));
      s = s.withTurnEnded(StopReason.refusal);
      expect(s.items.whereType<TranscriptStop>(), hasLength(1));
    });

    test('a second refusal in a later turn is a second row', () {
      var s = turn().withTurnEnded(StopReason.refusal);
      s = s.withUserMessage([const TextBlock('again')]).withTurnStarted().withTurnEnded(StopReason.refusal);
      final stops = s.items.whereType<TranscriptStop>().toList();
      expect(stops, hasLength(2));
      expect(stops[0].key, isNot(stops[1].key));
    });
  });

  group('kept _meta and turn usage', () {
    test('chunks, upserts and session_info_update keep their _meta', () {
      final chunk = _u({
        'sessionUpdate': 'agent_message_chunk',
        'messageId': 'a',
        'content': {'type': 'text', 'text': 'x'},
        '_meta': {'claudeCode': {'parentToolUseId': 'tu1'}},
      }) as MessageChunk;
      expect(chunk.meta, {'claudeCode': {'parentToolUseId': 'tu1'}});

      final upsert = _u({
        'sessionUpdate': 'agent_message',
        'messageId': 'a',
        'content': [],
        '_meta': {'k': 1},
      }) as MessageUpsert;
      expect(upsert.meta, {'k': 1});

      final info = _u({
        'sessionUpdate': 'session_info_update',
        'title': 'T',
        '_meta': {'piAcp': {'queueDepth': 0, 'running': true}},
      }) as SessionInfoUpdate;
      expect(info.meta, {'piAcp': {'queueDepth': 0, 'running': true}});
      expect(info.title, 'T');

      expect(_u({'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'x'}}), isA<MessageChunk>().having((c) => c.meta, 'meta', isNull));
    });

    test('the state keeps the last session_info _meta, and keeps it through updates without one', () {
      var s = _fold([
        {
          'sessionUpdate': 'session_info_update',
          'title': 'T',
          '_meta': {'piAcp': {'running': true}},
        },
      ]);
      expect(s.infoMeta, {'piAcp': {'running': true}});
      s = s.apply(_u({'sessionUpdate': 'session_info_update', 'title': 'U'}));
      expect(s.title, 'U');
      expect(s.infoMeta, {'piAcp': {'running': true}});
      s = s.apply(_u({'sessionUpdate': 'session_info_update', '_meta': {'piAcp': {'running': false}}}));
      expect(s.infoMeta, {'piAcp': {'running': false}});
      expect(s.title, 'U');
    });

    test('usage_update is read, with its meta, and every old field stays', () {
      final s = _fold([
        {
          'sessionUpdate': 'usage_update',
          'used': 1200,
          'size': 200000,
          'cost': {'amount': 0.25, 'currency': 'USD'},
          '_meta': {'k': 'v'},
        },
      ]);
      expect(s.usage!.used, 1200);
      expect(s.usage!.size, 200000);
      expect(s.usage!.costAmount, 0.25);
      expect(s.usage!.costCurrency, 'USD');
      expect(s.usage!.meta, {'k': 'v'});
    });

    test('PromptResponse.usage and _meta are parsed, null counts stay null', () {
      final r = PromptResult.parse({
        'stopReason': 'end_turn',
        '_meta': {'quota': {'token_count': null}},
        'usage': {
          'totalTokens': 53000,
          'inputTokens': 35000,
          'outputTokens': 12000,
          'thoughtTokens': 5000,
          'cachedReadTokens': null,
        },
      });
      expect(r.stopReason, StopReason.endTurn);
      expect(r.meta, {'quota': {'token_count': null}});
      expect(r.usage!.totalTokens, 53000);
      expect(r.usage!.inputTokens, 35000);
      expect(r.usage!.outputTokens, 12000);
      expect(r.usage!.thoughtTokens, 5000);
      expect(r.usage!.cachedReadTokens, isNull);
      expect(r.usage!.cachedWriteTokens, isNull);

      expect(PromptResult.parse({'stopReason': 'end_turn', 'usage': null}).usage, isNull);
      expect(PromptResult.parse({'stopReason': 'end_turn'}).usage, isNull);
      expect(PromptResult.parse({'stopReason': 'end_turn', 'usage': 'junk'}).usage, isNull);
    });

    test('the turn that ended puts its usage and meta in the state; the next turn replaces them', () {
      var s = const AgentSessionState('s').withTurnStarted();
      s = s.withTurnEnded(
        StopReason.endTurn,
        usage: const TurnUsage(totalTokens: 3, inputTokens: 1, outputTokens: 2),
        meta: {'quota': 1},
      );
      expect(s.turnUsage!.totalTokens, 3);
      expect(s.turnMeta, {'quota': 1});
      s = s.withTurnStarted().withTurnEnded(StopReason.endTurn);
      expect(s.turnUsage, isNull, reason: 'a turn that reports none does not inherit the last one');
      expect(s.turnMeta, isNull);
    });
  });

  group('activity stamp', () {
    final t0 = DateTime.utc(2026, 10, 5, 10);
    final t1 = t0.add(const Duration(seconds: 7));

    test('every update stamps lastActivityAt, modelled or not', () {
      var s = const AgentSessionState('s');
      expect(s.lastActivityAt, isNull);
      final updates = <Json>[
        {'sessionUpdate': 'agent_message_chunk', 'messageId': 'a', 'content': {'type': 'text', 'text': 'x'}},
        {'sessionUpdate': 'agent_thought_chunk', 'content': {'type': 'text', 'text': 'x'}},
        _start('c'),
        _delta('c', 'x'),
        {'sessionUpdate': 'plan', 'entries': []},
        {'sessionUpdate': 'usage_update', 'used': 1, 'size': 2},
        {'sessionUpdate': 'session_info_update', 'title': 'T'},
        {'sessionUpdate': 'state_update', 'state': 'running'},
        {'sessionUpdate': 'telepathy_update'},
      ];
      var at = t0;
      for (final json in updates) {
        at = at.add(const Duration(seconds: 1));
        s = s.apply(_u(json), at: at);
        expect(s.lastActivityAt, at, reason: '${json['sessionUpdate']}');
      }
    });

    test('without a time the reducer reads no clock and an unknown update is still the same instance', () {
      final s = const AgentSessionState('s').apply(_u({'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'x'}}), at: t0);
      final unknown = _u({'sessionUpdate': 'telepathy_update'});
      expect(identical(s.apply(unknown), s), isTrue);
      expect(s.apply(unknown).lastActivityAt, t0);
      final later = s.apply(unknown, at: t1);
      expect(later.lastActivityAt, t1);
      expect(later.items, same(s.items));
    });

    test('what the client does is not agent activity, and the phase ignores the stamp', () {
      var s = const AgentSessionState('s').apply(_u({'sessionUpdate': 'telepathy_update'}), at: t0);
      s = s.withUserMessage([const TextBlock('hi')]).withTurnStarted().withTurnEnded(StopReason.endTurn);
      expect(s.lastActivityAt, t0);
      expect(s.phase, AgentPhase.idle, reason: 'the UI decides what a recent stamp means (wave 3)');
    });
  });

  group('auto-resolution of a question (model)', () {
    ElicitationRequest ask(Object? meta) => ElicitationRequest.parse({
      'mode': 'form',
      'message': 'Which?',
      'requestedSchema': {'type': 'object'},
      '_meta': ?(meta is Map<String, Object?> ? meta : null),
    });

    test('codex autoResolutionMs becomes a Duration; null, missing and nonsense mean never', () {
      expect(ask({'codex': {'autoResolutionMs': 60000}}).autoResolution, const Duration(minutes: 1));
      expect(ask({'codex': {'autoResolutionMs': 1500.0}}).autoResolution, const Duration(milliseconds: 1500));
      expect(ask({'codex': {'autoResolutionMs': 0}}).autoResolution, Duration.zero);
      expect(ask({'codex': {'autoResolutionMs': null}}).autoResolution, isNull);
      expect(ask({'codex': {}}).autoResolution, isNull);
      expect(ask({'codex': 'x'}).autoResolution, isNull);
      expect(ask({'codex': {'autoResolutionMs': '60000'}}).autoResolution, isNull);
      expect(ask({'codex': {'autoResolutionMs': -5}}).autoResolution, isNull);
      expect(ask(null).autoResolution, isNull);
    });

    test('a pending question remembers when it arrived', () {
      final at = DateTime.utc(2026, 10, 5);
      final q = PendingQuestion(4, ask(null), receivedAt: at);
      final s = const AgentSessionState('s').withPending(q);
      expect((s.pending.single as PendingQuestion).receivedAt, at);
      expect(PendingQuestion(5, ask(null)).receivedAt, isNull);
    });
  });
}
