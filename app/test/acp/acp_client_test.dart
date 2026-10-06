import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_client.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/json_rpc.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';

import 'support/fake_agent.dart';

const _sid = 's1';

class _PermissionCall {
  _PermissionCall(this.request, this.cancelled) {
    cancelled.then((_) => cancelledFired = true);
  }

  final PermissionRequest request;
  final Future<void> cancelled;
  final answer = Completer<PermissionOutcome>();
  var cancelledFired = false;
}

class _QuestionCall {
  _QuestionCall(this.request, this.cancelled) {
    cancelled.then((_) => cancelledFired = true);
  }

  final ElicitationRequest request;
  final Future<void> cancelled;
  final answer = Completer<ElicitationResponse>();
  var cancelledFired = false;
}

/// The app's side: records what the agent asked and lets the test answer.
class _Handler implements AcpClientHandler {
  final permissions = <_PermissionCall>[];
  final questions = <_QuestionCall>[];

  @override
  Future<PermissionOutcome> requestPermission(PermissionRequest request, Future<void> cancelled) {
    final call = _PermissionCall(request, cancelled);
    permissions.add(call);
    return call.answer.future;
  }

  @override
  Future<ElicitationResponse> elicit(ElicitationRequest request, Future<void> cancelled) {
    final call = _QuestionCall(request, cancelled);
    questions.add(call);
    return call.answer.future;
  }
}

class _Harness {
  _Harness({
    Map<String, AgentMethod> methods = const {},
    Duration timeout = const Duration(seconds: 5),
    Json? initialize,
    DateTime Function()? clock,
  }) {
    link = MemoryLink();
    agent = FakeAgent(link.agent, {'initialize': (_) => initialize ?? ompInitialize(), ...methods});
    client = AcpClient(
      link.client,
      handler: handler,
      requestTimeout: timeout,
      onProblem: problems.add,
      clock: clock ?? DateTime.now,
    );
  }

  late final MemoryLink link;
  late final FakeAgent agent;
  late final AcpClient client;
  final handler = _Handler();
  final problems = <String>[];

  AgentSessionState get state => client.state(_sid);

  /// What the agent last received for [method], decoded.
  Object? sentFor(String method) => agent.paramsOf(method).last;

  /// Ready for prompts: initialized, with a prompt method the test controls.
  Future<Completer<Object?>> readyToPrompt() async {
    final turn = Completer<Object?>();
    agent.methods['session/prompt'] = (_) => turn.future;
    await client.initialize();
    return turn;
  }

  Future<void> dispose() => client.close();
}

Json _permissionParams({String sid = _sid}) => {
  'sessionId': sid,
  'toolCall': {
    'toolCallId': 't1',
    'title': 'Run rm -rf build',
    'kind': 'execute',
    'rawInput': {'command': 'rm -rf build'},
  },
  'options': [
    {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
    {'optionId': 'always', 'name': 'Always allow', 'kind': 'allow_always'},
    {'optionId': 'deny', 'name': 'Deny', 'kind': 'reject_once'},
  ],
};

Json _formParams({String mode = 'form'}) => {
  'sessionId': _sid,
  'mode': mode,
  'message': 'Which approach?',
  'requestedSchema': {
    'type': 'object',
    'properties': {
      'approach': {'type': 'string', 'enum': ['safe', 'fast']},
      'notes': {'type': 'string'},
    },
    'required': ['approach'],
  },
};

void main() {
  group('handshake', () {
    test('initialize sends version 1 and the phone capabilities, and keeps the answer', () async {
      final h = _Harness();
      final result = await h.client.initialize();
      expect(result.agentInfo!.name, 'omp');
      expect(h.client.agent, same(result));
      expect(h.sentFor('initialize'), {
        'protocolVersion': 1,
        'clientCapabilities': {
          'fs': {'readTextFile': false, 'writeTextFile': false},
          'terminal': false,
          'elicitation': {'form': <String, Object?>{}},
          'session': {
            'configOptions': {'boolean': <String, Object?>{}},
          },
        },
        'clientInfo': {'name': 'herdr-mobile', 'title': 'herdr mobile', 'version': '0'},
      });
      await h.dispose();
    });

    test('an agent that answers another protocol version is refused', () async {
      final h = _Harness(initialize: {...ompInitialize(), 'protocolVersion': 2});
      await expectLater(h.client.initialize(), throwsA(isA<AcpProtocolException>()));
      await h.dispose();
    });

    test('session/new: options and modes from the answer, commands from the updates after it', () async {
      final commands = [
        for (var i = 0; i < 98; i++) {'name': i < 90 ? 'cmd$i' : 'skill:s$i', 'description': 'd$i', if (i == 3) 'input': {'hint': 'arg'}},
      ];
      final h = _Harness(
        methods: {
          'session/new': (_) {
            Future(() {
              pushUpdate(_sid, {'sessionUpdate': 'available_commands_update', 'availableCommands': commands});
              pushUpdate(_sid, {'sessionUpdate': 'session_info_update', 'updatedAt': '2026-10-04T10:00:00Z'});
            });
            return ompSessionNew(id: _sid);
          },
        },
      );
      pushUpdate = h.agent.update;
      await h.client.initialize();
      final s = await h.client.newSession(cwd: '/tmp/proj');
      expect(s.sessionId, _sid);
      expect(s.configOptions.map((o) => o.id), ['mode', 'model']);
      expect(s.currentModeId, 'default');
      expect(h.sentFor('session/new'), {'cwd': '/tmp/proj', 'mcpServers': <Object>[]});
      await settle();
      expect(h.state.commands, hasLength(98));
      expect(h.state.commands[3].inputHint, 'arg');
      expect(h.state.updatedAt, DateTime.utc(2026, 10, 4, 10));
      expect(h.state.configOptions, hasLength(2), reason: 'the later updates did not lose the setup');
      await h.dispose();
    });

    test('an update delivered in the same read as the response is not lost', () async {
      final h = _Harness(methods: {'session/new': (_) => Completer<Object?>().future});
      await h.client.initialize();
      final f = h.client.newSession(cwd: '/x');
      final id = (jsonDecode(h.link.client.sent.last) as Map)['id'];
      h.link.agent.send(line({'jsonrpc': '2.0', 'id': id, 'result': ompSessionNew(id: _sid)}));
      h.agent.update(_sid, {
        'sessionUpdate': 'available_commands_update',
        'availableCommands': [
          {'name': 'compact', 'description': 'c'},
        ],
      });
      await f;
      expect(h.state.commands.map((c) => c.name), ['compact']);
      expect(h.state.configOptions, hasLength(2));
      await h.dispose();
    });

    test('an answer without a sessionId is a protocol error', () async {
      final h = _Harness(methods: {'session/new': (_) => {'configOptions': <Object>[]}});
      await h.client.initialize();
      await expectLater(h.client.newSession(cwd: '/x'), throwsA(isA<AcpProtocolException>()));
      await h.dispose();
    });
  });

  group('capabilities are checked before the call', () {
    test('load, resume, list and close need the matching capability, and nothing is sent without it', () async {
      final bare = {
        'protocolVersion': 1,
        'agentCapabilities': <String, Object?>{},
      };
      final h = _Harness(initialize: bare);
      await h.client.initialize();
      final before = h.agent.requests.length;
      await expectLater(h.client.loadSession('x', cwd: '/'), throwsA(isA<AcpProtocolException>()));
      await expectLater(h.client.resumeSession('x', cwd: '/'), throwsA(isA<AcpProtocolException>()));
      await expectLater(h.client.listSessions(), throwsA(isA<AcpProtocolException>()));
      await expectLater(h.client.closeSession('x'), throwsA(isA<AcpProtocolException>()));
      expect(h.agent.requests.length, before);
      await h.dispose();
    });

    test('images, audio and embedded context need the prompt capability', () async {
      final h = _Harness(initialize: {
        'protocolVersion': 1,
        'agentCapabilities': {'promptCapabilities': <String, Object?>{}},
      });
      await h.client.initialize();
      for (final block in <ContentBlock>[
        const ImageBlock(data: 'AAAA', mimeType: 'image/png'),
        const AudioBlock(data: 'AAAA', mimeType: 'audio/wav'),
        const EmbeddedResourceBlock(uri: 'file:///a', text: 'x'),
      ]) {
        await expectLater(h.client.prompt(_sid, [block]), throwsA(isA<AcpProtocolException>()), reason: '${block.runtimeType}');
      }
      expect(h.agent.paramsOf('session/prompt'), isEmpty);
      expect(h.state.items, isEmpty, reason: 'a refused prompt leaves no trace');
      await h.dispose();
    });
  });

  group('sessions', () {
    test('session/list, resume and close', () async {
      final h = _Harness(
        methods: {
          'session/list': (r) => {
            'sessions': [
              {'sessionId': 'a', 'cwd': '/p', 'title': 'T', 'updatedAt': '2026-10-04T10:00:00Z', '_meta': {'messageCount': 3, 'size': 10}},
            ],
          },
          'session/resume': (_) => ompSessionNew(id: 'a')..remove('sessionId'),
          'session/close': (_) => <String, Object?>{},
        },
      );
      await h.client.initialize();
      final page = await h.client.listSessions(cwd: '/p');
      expect(page.sessions.single.meta!['messageCount'], 3);
      expect(h.sentFor('session/list'), {'cwd': '/p'});
      final resumed = await h.client.resumeSession('a', cwd: '/p');
      expect(resumed.items, isEmpty, reason: 'resume does not replay');
      expect(resumed.configOptions, isNotEmpty);
      await h.client.closeSession('a');
      expect(h.client.state('a').configOptions, isEmpty, reason: 'forgotten');
      await h.dispose();
    });

    test('session/load starts from an empty state and rebuilds it from the replay', () async {
      final h = _Harness(
        methods: {
          'session/load': (_) {
            pushUpdate(_sid, {
              'sessionUpdate': 'user_message_chunk',
              'messageId': 'u1',
              'content': {'type': 'text', 'text': 'fix it'},
            });
            pushUpdate(_sid, {
              'sessionUpdate': 'agent_message_chunk',
              'messageId': 'a1',
              'content': {'type': 'text', 'text': 'fixed'},
            });
            pushUpdate(_sid, {'sessionUpdate': 'tool_call', 'toolCallId': 'c1', 'title': 'edit', 'status': 'completed'});
            return <String, Object?>{};
          },
        },
      );
      pushUpdate = h.agent.update;
      await h.client.initialize();
      h.agent.update(_sid, {
        'sessionUpdate': 'agent_message_chunk',
        'messageId': 'stale',
        'content': {'type': 'text', 'text': 'from an earlier open'},
      });
      expect(h.state.items, hasLength(1));
      final s = await h.client.loadSession(_sid, cwd: '/p');
      expect(s.items.map((i) => i.key), ['m0', 'm1', 'tool:c1']);
      expect((s.items[0] as TranscriptMessage).role, MessageRole.user);
      expect((s.items[1] as TranscriptMessage).text, 'fixed');
      await h.dispose();
    });

    test('setMode and setConfigOption update the state from the answer', () async {
      final h = _Harness(
        methods: {
          'session/set_mode': (_) => <String, Object?>{},
          'session/set_config_option': (r) {
            final p = (r.params as Map).cast<String, Object?>();
            return {
              'configOptions': [
                {
                  'id': 'model',
                  'name': 'Model',
                  'category': 'model',
                  'type': 'select',
                  'currentValue': p['value'],
                  'options': [
                    {'value': 'openai/gpt-5', 'name': 'GPT-5'},
                  ],
                },
              ],
            };
          },
        },
      );
      await h.client.initialize();
      h.agent.update(_sid, {'sessionUpdate': 'config_option_update', 'configOptions': ompSessionNew()['configOptions']});
      await h.client.setMode(_sid, 'plan');
      expect(h.sentFor('session/set_mode'), {'sessionId': _sid, 'modeId': 'plan'});
      expect(h.state.currentModeId, 'plan');
      await h.client.setConfigOption(_sid, 'model', 'openai/gpt-5');
      expect(h.sentFor('session/set_config_option'), {'sessionId': _sid, 'configId': 'model', 'value': 'openai/gpt-5'});
      expect(h.state.configOptions.single.currentValue, 'openai/gpt-5');
      await h.dispose();
    });

    test('a boolean option is sent with its type; an answer without options sets the value locally', () async {
      final h = _Harness(methods: {'session/set_config_option': (_) => <String, Object?>{}});
      await h.client.initialize();
      h.agent.update(_sid, {
        'sessionUpdate': 'config_option_update',
        'configOptions': [
          {'id': 'think', 'name': 'Think', 'type': 'boolean', 'currentValue': false},
        ],
      });
      await h.client.setConfigOption(_sid, 'think', true);
      expect(h.sentFor('session/set_config_option'), {'sessionId': _sid, 'configId': 'think', 'value': true, 'type': 'boolean'});
      expect(h.state.configOptions.single.currentValue, true);
      await h.dispose();
    });
  });

  group('prompt', () {
    test('streams into the state, then completes with the stop reason', () async {
      final h = _Harness();
      final turn = await h.readyToPrompt();
      final changes = <AgentPhase>[];
      h.client.changes.listen((c) => changes.add(c.state.phase));

      final f = h.client.prompt(_sid, [const TextBlock('refactor it')]);
      expect(h.sentFor('session/prompt'), {
        'sessionId': _sid,
        'prompt': [
          {'type': 'text', 'text': 'refactor it'},
        ],
      });
      expect(h.state.phase, AgentPhase.working);
      expect((h.state.items.single as TranscriptMessage).local, isTrue);

      h.agent.update(_sid, {'sessionUpdate': 'agent_thought_chunk', 'messageId': 'a', 'content': {'type': 'text', 'text': 'think'}});
      h.agent.update(_sid, {'sessionUpdate': 'agent_message_chunk', 'messageId': 'b', 'content': {'type': 'text', 'text': 'On it'}});
      h.agent.update(_sid, {'sessionUpdate': 'tool_call', 'toolCallId': 'c', 'title': 'Edit', 'kind': 'edit', 'status': 'in_progress'});
      h.agent.update(_sid, {'sessionUpdate': 'tool_call_update', 'toolCallId': 'c', 'status': 'completed'});
      expect(h.state.items.map((i) => i.runtimeType), [TranscriptMessage, TranscriptMessage, TranscriptMessage, TranscriptTool]);
      expect(h.state.phase, AgentPhase.working);

      turn.complete({'stopReason': 'end_turn'});
      final result = await f;
      expect(result.stopReason, StopReason.endTurn);
      expect(h.state.phase, AgentPhase.idle);
      expect(h.state.lastStopReason, StopReason.endTurn);
      await settle(); // the changes stream delivers in a later microtask
      expect(changes, contains(AgentPhase.working));
      expect(changes.last, AgentPhase.idle);
      await h.dispose();
    });

    test('a second prompt while one runs is refused and does not touch the transcript', () async {
      final h = _Harness();
      final turn = await h.readyToPrompt();
      final f = h.client.prompt(_sid, [const TextBlock('one')]);
      await expectLater(h.client.prompt(_sid, [const TextBlock('two')]), throwsA(isA<AcpProtocolException>()));
      expect(h.state.items, hasLength(1));
      turn.complete({'stopReason': 'end_turn'});
      await f;
      await h.dispose();
    });

    test('an agent error fails the prompt and ends the turn as an error', () async {
      final h = _Harness();
      await h.client.initialize();
      h.agent.methods['session/prompt'] = (_) => throw const JsonRpcException(-32000, 'model overloaded');
      await expectLater(h.client.prompt(_sid, [const TextBlock('hi')]), throwsA(isA<JsonRpcException>()));
      expect(h.state.phase, AgentPhase.idle);
      expect(h.state.lastStopReason, StopReason.error);
      // And the session takes the next prompt.
      h.agent.methods['session/prompt'] = (_) => {'stopReason': 'end_turn'};
      expect((await h.client.prompt(_sid, [const TextBlock('again')])).stopReason, StopReason.endTurn);
      await h.dispose();
    });

    test('an agent that echoes the user message does not double it', () async {
      final h = _Harness();
      await h.client.initialize();
      h.agent.methods['session/prompt'] = (_) {
        h.agent.update(_sid, {'sessionUpdate': 'user_message_chunk', 'messageId': 'u', 'content': {'type': 'text', 'text': 'hello'}});
        h.agent.update(_sid, {'sessionUpdate': 'agent_message_chunk', 'messageId': 'a', 'content': {'type': 'text', 'text': 'hi'}});
        return {'stopReason': 'end_turn'};
      };
      await h.client.prompt(_sid, [const TextBlock('hello')]);
      expect(h.state.items.whereType<TranscriptMessage>().map((m) => (m.role, m.text)), [
        (MessageRole.user, 'hello'),
        (MessageRole.agent, 'hi'),
      ]);
      await h.dispose();
    });

    test('there is no timeout on a turn', () async {
      final h = _Harness(timeout: const Duration(milliseconds: 20));
      final turn = await h.readyToPrompt();
      final f = h.client.prompt(_sid, [const TextBlock('long task')]);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      turn.complete({'stopReason': 'end_turn'});
      expect((await f).stopReason, StopReason.endTurn);
      await h.dispose();
    });
  });

  group('permission requests', () {
    test('round trip: the chosen option goes back, the state shows the block while it waits', () async {
      final h = _Harness();
      final turn = await h.readyToPrompt();
      final f = h.client.prompt(_sid, [const TextBlock('clean')]);

      final call = h.agent.ask('session/request_permission', _permissionParams());
      expect(h.handler.permissions, hasLength(1));
      final asked = h.handler.permissions.single.request;
      expect(asked.toolCall.rawInput, {'command': 'rm -rf build'});
      expect(h.state.phase, AgentPhase.blockedOnPermission);
      expect(h.state.pending.single, isA<PendingPermission>());

      h.handler.permissions.single.answer.complete(const PermissionSelected('allow'));
      expect(await call.response, {
        'outcome': {'outcome': 'selected', 'optionId': 'allow'},
      });
      expect(h.state.pending, isEmpty);
      expect(h.state.phase, AgentPhase.working);
      expect(h.handler.permissions.single.cancelledFired, isFalse);

      turn.complete({'stopReason': 'end_turn'});
      await f;
      await h.dispose();
    });

    test('cancelling the prompt answers the waiting request as cancelled and tells the agent', () async {
      final h = _Harness();
      final turn = await h.readyToPrompt();
      final f = h.client.prompt(_sid, [const TextBlock('clean')]);
      h.agent.update(_sid, {'sessionUpdate': 'tool_call', 'toolCallId': 'c', 'title': 'rm', 'status': 'pending'});
      final call = h.agent.ask('session/request_permission', _permissionParams());

      h.client.cancel(_sid);

      expect(h.agent.notifications.last.$1, 'session/cancel');
      expect(h.agent.notifications.last.$2, {'sessionId': _sid});
      expect(await call.response, {
        'outcome': {'outcome': 'cancelled'},
      });
      expect(h.handler.permissions.single.cancelledFired, isTrue, reason: 'the UI is told to dismiss it');
      expect(h.state.pending, isEmpty);
      expect(h.state.cancelRequested, isTrue);
      expect(h.state.toolCall('c')!.status, ToolStatus.cancelled);

      // A late answer from the UI changes nothing: the agent got one reply.
      h.handler.permissions.single.answer.complete(const PermissionSelected('allow'));
      await settle();
      expect(h.link.client.sent.where((l) => (jsonDecode(l) as Map).containsKey('result') && (jsonDecode(l) as Map)['id'] == 1), hasLength(1));

      turn.complete({'stopReason': 'cancelled'});
      expect((await f).stopReason, StopReason.cancelled);
      expect(h.state.phase, AgentPhase.idle);
      expect(h.state.cancelRequested, isFalse);
      await h.dispose();
    });

    test('a prompt the agent fails with an error after cancel still completes as cancelled', () async {
      final h = _Harness();
      await h.client.initialize();
      final turn = Completer<Object?>();
      h.agent.methods['session/prompt'] = (_) => turn.future;
      final f = h.client.prompt(_sid, [const TextBlock('x')]);
      h.client.cancel(_sid);
      turn.completeError(const JsonRpcException(-32800, 'Request cancelled'));
      expect((await f).stopReason, StopReason.cancelled);
      expect(h.state.lastStopReason, StopReason.cancelled);
      await h.dispose();
    });

    test(r'the agent withdrawing the request ($/cancel_request) cancels it and clears the block', () async {
      final h = _Harness();
      await h.client.initialize();
      final call = h.agent.ask('session/request_permission', _permissionParams());
      expect(h.state.pending, hasLength(1));
      call.cancel();
      await expectLater(call.response, throwsA(isA<JsonRpcException>().having((e) => e.isCancelled, 'isCancelled', isTrue)));
      await settle();
      expect(h.handler.permissions.single.cancelledFired, isTrue);
      expect(h.state.pending, isEmpty);
      await h.dispose();
    });

    test('a handler that picks an option the request never offered cancels instead of allowing', () async {
      final h = _Harness();
      await h.client.initialize();
      final call = h.agent.ask('session/request_permission', _permissionParams());
      h.handler.permissions.single.answer.complete(const PermissionSelected('allow-everything'));
      expect(await call.response, {
        'outcome': {'outcome': 'cancelled'},
      });
      expect(h.problems.single, contains('allow-everything'));
      await h.dispose();
    });

    test('a throwing handler gives the agent an error, never an allow', () async {
      final h = _Harness();
      await h.client.initialize();
      final call = h.agent.ask('session/request_permission', _permissionParams());
      h.handler.permissions.single.answer.completeError(StateError('ui crashed'));
      await expectLater(call.response, throwsA(isA<JsonRpcException>().having((e) => e.code, 'code', JsonRpcCode.internalError)));
      expect(h.state.pending, isEmpty);
      await h.dispose();
    });

    test('a request without options or a session is invalid params', () async {
      final h = _Harness();
      await h.client.initialize();
      final noOptions = h.agent.ask('session/request_permission', {'sessionId': _sid, 'toolCall': {'toolCallId': 't'}, 'options': <Object>[]});
      await expectLater(noOptions.response, throwsA(isA<JsonRpcException>().having((e) => e.code, 'code', JsonRpcCode.invalidParams)));
      expect(h.handler.permissions, isEmpty);
      await h.dispose();
    });

    test('two requests wait side by side; each is answered on its own id', () async {
      final h = _Harness();
      await h.client.initialize();
      final a = h.agent.ask('session/request_permission', _permissionParams());
      final b = h.agent.ask('session/request_permission', _permissionParams());
      expect(h.state.pending, hasLength(2));
      h.handler.permissions[1].answer.complete(const PermissionSelected('deny'));
      expect((await b.response), {
        'outcome': {'outcome': 'selected', 'optionId': 'deny'},
      });
      expect(h.state.pending.single.id, a.id);
      h.handler.permissions[0].answer.complete(const PermissionSelected('allow'));
      expect((await a.response), {
        'outcome': {'outcome': 'selected', 'optionId': 'allow'},
      });
      await h.dispose();
    });
  });

  group('elicitation', () {
    test('accept sends the content; the state shows a question while it waits', () async {
      final h = _Harness();
      await h.client.initialize();
      final call = h.agent.ask('elicitation/create', _formParams());
      expect(h.state.phase, AgentPhase.blockedOnQuestion);
      final asked = h.handler.questions.single.request;
      expect(asked.message, 'Which approach?');
      expect(asked.schema!.fields.first, isA<EnumField>());
      h.handler.questions.single.answer.complete(const ElicitationAccept({'approach': 'safe'}));
      expect(await call.response, {
        'action': 'accept',
        'content': {'approach': 'safe'},
      });
      expect(h.state.phase, AgentPhase.idle);
      await h.dispose();
    });

    test('decline and cancel are sent as such', () async {
      final h = _Harness();
      await h.client.initialize();
      final declined = h.agent.ask('elicitation/create', _formParams());
      h.handler.questions[0].answer.complete(const ElicitationDecline());
      expect(await declined.response, {'action': 'decline'});
      final cancelled = h.agent.ask('elicitation/create', _formParams());
      h.handler.questions[1].answer.complete(const ElicitationCancel());
      expect(await cancelled.response, {'action': 'cancel'});
      await h.dispose();
    });

    test('cancelling the prompt cancels a waiting question', () async {
      final h = _Harness();
      final turn = await h.readyToPrompt();
      final f = h.client.prompt(_sid, [const TextBlock('x')]);
      final call = h.agent.ask('elicitation/create', _formParams());
      h.client.cancel(_sid);
      expect(await call.response, {'action': 'cancel'});
      await settle();
      expect(h.handler.questions.single.cancelledFired, isTrue);
      expect(h.state.pending, isEmpty);
      turn.complete({'stopReason': 'cancelled'});
      await f;
      await h.dispose();
    });

    test('a mode the client did not advertise gets invalid params and never reaches the app', () async {
      final h = _Harness();
      await h.client.initialize();
      for (final mode in ['url', 'hologram']) {
        final call = h.agent.ask('elicitation/create', {'sessionId': _sid, 'mode': mode, 'message': 'Sign in', 'url': 'https://example.com'});
        await expectLater(call.response, throwsA(isA<JsonRpcException>().having((e) => e.code, 'code', JsonRpcCode.invalidParams)));
      }
      expect(h.handler.questions, isEmpty);
      await h.dispose();
    });

    test('a form without a session is still answered (request-scoped)', () async {
      final h = _Harness();
      await h.client.initialize();
      final call = h.agent.ask('elicitation/create', {
        'mode': 'form',
        'requestId': 4,
        'message': 'Proceed?',
        'requestedSchema': {
          'type': 'object',
          'properties': {'value': {'type': 'boolean'}},
        },
      });
      h.handler.questions.single.answer.complete(const ElicitationAccept({'value': true}));
      expect(await call.response, {
        'action': 'accept',
        'content': {'value': true},
      });
      await h.dispose();
    });
  });

  group('robustness', () {
    test('a request for an unsupported method gets method-not-found, and so does anything newer', () async {
      final h = _Harness();
      await h.client.initialize();
      for (final method in ['fs/read_text_file', 'fs/write_text_file', 'terminal/create', 'terminal/output', 'future/thing']) {
        final call = h.agent.ask(method, {'sessionId': _sid, 'path': '/etc/passwd'});
        await expectLater(call.response, throwsA(isA<JsonRpcException>().having((e) => e.code, 'code', JsonRpcCode.methodNotFound)), reason: method);
      }
      await h.dispose();
    });

    test('malformed lines and unknown messages are reported; the session carries on', () async {
      final h = _Harness();
      await h.client.initialize();
      h.link.agent.send('{broken');
      h.link.agent.send('[]');
      h.agent.rpc.notify('session/update', {'update': {'sessionUpdate': 'agent_message_chunk'}}); // no sessionId
      h.agent.rpc.notify('session/update', 'not an object');
      h.agent.rpc.notify('_vendor/ping', {'x': 1});
      h.agent.rpc.notify('elicitation/complete', {'elicitationId': 'e'});
      h.agent.update(_sid, {'sessionUpdate': 'telepathy_update', 'secret': true});
      h.agent.update(_sid, {'sessionUpdate': 'agent_message_chunk', 'messageId': 'a', 'content': {'type': 'text', 'text': 'still here'}});
      expect((h.state.items.single as TranscriptMessage).text, 'still here');
      expect(h.problems.where((p) => p.contains('not JSON')), hasLength(1));
      expect(h.problems.where((p) => p.contains('sessionId')), hasLength(2));
      await h.dispose();
    });

    test('a request that gets no answer times out, and the client stays usable', () async {
      final h = _Harness(
        timeout: const Duration(milliseconds: 30),
        methods: {'session/list': (_) => Completer<Object?>().future, 'session/set_mode': (_) => <String, Object?>{}},
      );
      await h.client.initialize();
      await expectLater(h.client.listSessions(), throwsA(isA<TimeoutException>()));
      await h.client.setMode(_sid, 'plan');
      await h.dispose();
    });

    test('the agent exiting mid-prompt fails the prompt, drops what was pending and ends the turn', () async {
      final h = _Harness();
      final turn = await h.readyToPrompt();
      final f = h.client.prompt(_sid, [const TextBlock('x')]);
      final failed = expectLater(f, throwsA(isA<JsonRpcClosedException>()));
      h.agent.ask('session/request_permission', _permissionParams()).response.then<void>((_) {}, onError: (Object _) {});
      expect(h.state.phase, AgentPhase.blockedOnPermission);

      var closed = false;
      unawaited(h.client.closed.then((_) => closed = true));
      await h.link.agent.close(); // the process died: EOF on the client's reader
      await failed;
      await settle();

      expect(closed, isTrue);
      expect(h.state.disconnected, isTrue);
      expect(h.state.pending, isEmpty);
      expect(h.state.phase, AgentPhase.idle);
      expect(h.handler.permissions.single.cancelledFired, isTrue);
      expect(turn.isCompleted, isFalse);
      await h.dispose();
    });

    test('cancel on a dead connection does nothing and does not throw', () async {
      final h = _Harness();
      await h.client.initialize();
      await h.link.agent.close();
      await settle();
      expect(() => h.client.cancel(_sid), returnsNormally);
      await h.dispose();
    });

    test('closing the client hangs up on the agent', () async {
      final h = _Harness();
      h.agent.update(_sid, {'sessionUpdate': 'agent_message_chunk', 'messageId': 'a', 'content': {'type': 'text', 'text': 'x'}});
      await h.client.initialize();
      var agentSawEof = false;
      unawaited(h.agent.rpc.done.then((_) => agentSawEof = true));
      await h.client.close();
      expect(agentSawEof, isTrue);
      expect(h.state.disconnected, isTrue);
    });

    test('notifications the client does not handle go to onExtension; session updates do not', () async {
      final link = MemoryLink();
      final agent = FakeAgent(link.agent, {});
      final heard = <String>[];
      final client = AcpClient(link.client, handler: _Handler(), onExtension: (m, p) => heard.add('$m ${jsonEncode(p)}'));

      agent.rpc.notify('_herdr/evicted', {'reason': 'another device'});
      agent.update(_sid, {'sessionUpdate': 'agent_message_chunk', 'messageId': 'a', 'content': {'type': 'text', 'text': 'x'}});
      await settle();

      expect(heard, ['_herdr/evicted {"reason":"another device"}']);
      expect(client.state(_sid).items, hasLength(1));
      await client.close();
    });
  });

  group('chat data (step 1 of the chat plan)', () {
    test('the response usage and _meta reach the state; a refusal leaves one stop row', () async {
      final h = _Harness();
      await h.client.initialize();
      h.agent.methods['session/prompt'] = (_) => {
        'stopReason': 'refusal',
        '_meta': {'quota': {'token_count': 9}},
        'usage': {'totalTokens': 30, 'inputTokens': 10, 'outputTokens': 20},
      };
      final result = await h.client.prompt(_sid, [const TextBlock('do it')]);
      expect(result.stopReason, StopReason.refusal);
      expect(result.usage!.totalTokens, 30);
      expect(h.state.turnUsage!.outputTokens, 20);
      expect(h.state.turnMeta, {'quota': {'token_count': 9}});
      expect(h.state.items.last, isA<TranscriptStop>().having((i) => i.reason, 'reason', StopReason.refusal));
      expect(h.state.phase, AgentPhase.idle);

      // The next turn ends normally: no row, and the usage is its own.
      h.agent.methods['session/prompt'] = (_) => {'stopReason': 'end_turn'};
      await h.client.prompt(_sid, [const TextBlock('again')]);
      expect(h.state.items.whereType<TranscriptStop>(), hasLength(1));
      expect(h.state.turnUsage, isNull);
      await h.dispose();
    });

    test('a cancelled turn and an error turn leave no stop row', () async {
      final h = _Harness();
      await h.client.initialize();
      h.agent.methods['session/prompt'] = (_) => throw const JsonRpcException(-32000, 'model overloaded');
      await expectLater(h.client.prompt(_sid, [const TextBlock('hi')]), throwsA(isA<JsonRpcException>()));
      expect(h.state.items.whereType<TranscriptStop>(), isEmpty);
      await h.dispose();
    });

    test('every update from the agent is stamped by the client clock; a question remembers its arrival', () async {
      var now = DateTime.utc(2026, 10, 5, 9);
      final h = _Harness(clock: () => now);
      await h.client.initialize();
      expect(h.state.lastActivityAt, isNull);

      now = DateTime.utc(2026, 10, 5, 9, 0, 5);
      h.agent.update(_sid, {'sessionUpdate': 'agent_message_chunk', 'messageId': 'a', 'content': {'type': 'text', 'text': 'x'}});
      expect(h.state.lastActivityAt, now);

      now = DateTime.utc(2026, 10, 5, 9, 0, 9);
      h.agent.update(_sid, {'sessionUpdate': 'telepathy_update'});
      expect(h.state.lastActivityAt, now, reason: 'an update the client does not model is still activity');

      now = DateTime.utc(2026, 10, 5, 9, 1);
      final call = h.agent.ask('elicitation/create', {
        ..._formParams(),
        '_meta': {'codex': {'autoResolutionMs': 60000}},
      });
      final pending = h.state.pending.single as PendingQuestion;
      expect(pending.receivedAt, now);
      expect(pending.request.autoResolution, const Duration(minutes: 1));
      h.handler.questions.single.answer.complete(const ElicitationDecline());
      await call.response;
      expect(h.state.lastActivityAt, DateTime.utc(2026, 10, 5, 9, 0, 9), reason: 'answering is the person, not the agent');
      await h.dispose();
    });
  });
}

/// Set by tests whose agent methods push updates from inside a handler.
void Function(String sessionId, Json update) pushUpdate = (_, _) {};
