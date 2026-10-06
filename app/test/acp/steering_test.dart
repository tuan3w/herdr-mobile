// Input while the agent works, at the client: `_session/steering` (shape and
// outcomes read from claude-agent-acp and codex-acp), the capability gate, a
// prompt the agent refuses as busy (omp's -32003), and images.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_client.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/json_rpc.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';

import 'support/fake_agent.dart';

const _sid = 's1';

class _Handler implements AcpClientHandler {
  @override
  Future<PermissionOutcome> requestPermission(PermissionRequest request, Future<void> cancelled) =>
      Completer<PermissionOutcome>().future;

  @override
  Future<ElicitationResponse> elicit(ElicitationRequest request, Future<void> cancelled) =>
      Completer<ElicitationResponse>().future;
}

class _Rig {
  _Rig(Json initialize, [Map<String, AgentMethod> methods = const {}]) {
    link = MemoryLink();
    agent = FakeAgent(link.agent, {'initialize': (_) => initialize, ...methods});
    client = AcpClient(link.client, handler: _Handler());
  }

  late final MemoryLink link;
  late final FakeAgent agent;
  late final AcpClient client;

  AgentSessionState get state => client.state(_sid);

  List<String> get userRows => [
    for (final i in state.items.whereType<TranscriptMessage>())
      if (i.role == MessageRole.user) i.text,
  ];

  /// A turn is running: the prompt waits for [turn].
  Future<Completer<Object?>> running() async {
    final turn = Completer<Object?>();
    agent.methods['session/prompt'] = (_) => turn.future;
    await client.initialize();
    // The first turn is still in flight when a test ends: its failure at
    // teardown is not what is under test.
    unawaited(client.prompt(_sid, [const TextBlock('first')]).then<void>((_) {}, onError: (Object _) {}));
    await settle();
    expect(state.turnActive, isTrue);
    return turn;
  }

  Future<void> dispose() async {
    try {
      await client.close();
    } on JsonRpcClosedException {
      // A turn was in flight.
    }
  }
}

void main() {
  group('capability', () {
    test('omp and pi do not steer: nothing is sent', () async {
      final r = _Rig(ompInitialize());
      await r.client.initialize();
      expect(r.client.canSteer, isFalse);
      await expectLater(r.client.steer(_sid, [const TextBlock('x')]), throwsA(isA<AcpProtocolException>()));
      expect(r.agent.paramsOf('_session/steering'), isEmpty);
      await r.dispose();
    });

    test('Claude Code and Codex advertise it in the top-level _meta', () async {
      final claude = _Rig(claudeInitialize());
      await claude.client.initialize();
      expect(claude.client.canSteer, isTrue);
      final codex = _Rig(codexInitialize());
      await codex.client.initialize();
      expect(codex.client.canSteer, isTrue);
      // `steering: {supported: false}` and a missing key both mean no.
      final no = _Rig({
        ...ompInitialize(),
        '_meta': {
          'steering': {'supported': false},
        },
      });
      await no.client.initialize();
      expect(no.client.canSteer, isFalse);
      await claude.dispose();
      await codex.dispose();
      await no.dispose();
    });
  });

  group('_session/steering', () {
    test('Claude Code: the params, and promptRequired asked for when no turn runs', () async {
      final r = _Rig(claudeInitialize(), {
        '_session/steering': (_) => {'outcome': 'injected'},
      });
      final turn = await r.running();

      final outcome = await r.client.steer(_sid, [const TextBlock('use the other table')]);

      expect(outcome, SteerOutcome.injected);
      expect(r.agent.paramsOf('_session/steering').single, {
        'sessionId': _sid,
        'prompt': [
          {'type': 'text', 'text': 'use the other table'},
        ],
        '_meta': {
          'steering': {'idleBehavior': 'promptRequired'},
        },
      });
      expect(r.userRows, ['first', 'use the other table'], reason: 'the steered message shows, after the first');
      expect(r.state.turnActive, isTrue, reason: 'the running turn is the same turn');
      turn.complete({'stopReason': 'end_turn'});
      await settle();
      expect(r.state.turnActive, isFalse);
      await r.dispose();
    });

    test('Codex: no _meta (its parser reads sessionId and prompt only)', () async {
      final r = _Rig(codexInitialize(), {
        '_session/steering': (_) => {'outcome': 'injected'},
      });
      await r.running();

      await r.client.steer(_sid, [const TextBlock('stop early')]);

      final sent = r.agent.paramsOf('_session/steering').single as Map;
      expect(sent.keys, unorderedEquals(['sessionId', 'prompt']));
      await r.dispose();
    });

    test('startedNewTurn: the message shows; no turn is claimed that nothing could end', () async {
      final r = _Rig(codexInitialize(), {
        '_session/steering': (_) => {'outcome': 'startedNewTurn'},
      });
      final turn = await r.running();
      turn.complete({'stopReason': 'end_turn'});
      await settle();

      final outcome = await r.client.steer(_sid, [const TextBlock('one more thing')]);

      expect(outcome, SteerOutcome.startedNewTurn);
      expect(r.userRows, ['first', 'one more thing']);
      expect(r.state.turnActive, isFalse, reason: 'a detached turn has no prompt whose answer would end it');
      await r.dispose();
    });

    test('promptRequired and failed add no row: the caller decides', () async {
      var answer = 'promptRequired';
      final r = _Rig(claudeInitialize(), {
        '_session/steering': (_) => {'outcome': answer},
      });
      await r.running();

      expect(await r.client.steer(_sid, [const TextBlock('a')]), SteerOutcome.promptRequired);
      answer = 'failed';
      expect(await r.client.steer(_sid, [const TextBlock('b')]), SteerOutcome.failed);
      answer = 'something-newer';
      expect(await r.client.steer(_sid, [const TextBlock('c')]), SteerOutcome.failed, reason: 'unknown is failed');
      expect(r.userRows, ['first']);
      await r.dispose();
    });

    test('a refusal is thrown and adds no row (Codex on a text-only model)', () async {
      final r = _Rig(codexInitialize(), {
        '_session/steering': (_) => throw const JsonRpcException(-32600, 'The current model does not support image input'),
      });
      await r.running();

      await expectLater(
        r.client.steer(_sid, [const ImageBlock(data: 'AAAA', mimeType: 'image/jpeg')]),
        throwsA(isA<JsonRpcException>().having((e) => e.message, 'message', contains('does not support image input'))),
      );
      expect(r.userRows, ['first']);
      await r.dispose();
    });

    test('a lost answer (the link died) shows the message, since it may have arrived, and throws', () async {
      final r = _Rig(codexInitialize(), {
        '_session/steering': (_) => Completer<Object?>().future,
      });
      await r.running();

      final f = r.client.steer(_sid, [const TextBlock('did this arrive?')]);
      final outcome = expectLater(f, throwsA(isA<JsonRpcClosedException>()));
      await settle();
      await r.link.agent.close();
      await outcome;
      expect(r.userRows, ['first', 'did this arrive?']);
      await r.dispose();
    });

    test('images are checked against promptCapabilities.image, as for a prompt', () async {
      final init = claudeInitialize();
      ((init['agentCapabilities'] as Map)['promptCapabilities'] as Map)['image'] = false;
      final r = _Rig(init);
      await r.client.initialize();

      await expectLater(
        r.client.steer(_sid, [const ImageBlock(data: 'AAAA', mimeType: 'image/jpeg')]),
        throwsA(isA<AcpProtocolException>()),
      );
      await expectLater(
        r.client.prompt(_sid, [const ImageBlock(data: 'AAAA', mimeType: 'image/jpeg')]),
        throwsA(isA<AcpProtocolException>()),
      );
      expect(r.agent.requests.where((q) => q.$1 != 'initialize'), isEmpty);
      await r.dispose();
    });
  });

  group('a prompt while the agent is busy with its own work (omp -32003)', () {
    test('nothing else happened: the message is taken back out of the state', () async {
      final r = _Rig(ompInitialize(), {
        'session/prompt': (_) => throw const JsonRpcException(acpSessionBusy, 'session busy'),
      });
      await r.client.initialize();

      await expectLater(r.client.prompt(_sid, [const TextBlock('hello')]), throwsA(isA<AcpSessionBusyException>()));

      expect(r.userRows, isEmpty, reason: 'it was not delivered, so it is not in the transcript');
      expect(r.state.turnActive, isFalse);
      await r.dispose();
    });

    test('the agent streamed meanwhile (its own turn): only the message goes, what it streamed stays', () async {
      late final _Rig r;
      r = _Rig(ompInitialize(), {
        'session/prompt': (_) async {
          r.agent.update(_sid, {
            'sessionUpdate': 'agent_message_chunk',
            'content': {'type': 'text', 'text': 'its own work'},
            'messageId': 'a1',
          });
          await settle();
          throw const JsonRpcException(acpSessionBusy, 'session busy');
        },
      });
      await r.client.initialize();

      await expectLater(r.client.prompt(_sid, [const TextBlock('hello')]), throwsA(isA<AcpSessionBusyException>()));

      expect(r.userRows, isEmpty, reason: 'refused, so it is not in the transcript, streamed or not');
      expect(
        [for (final i in r.state.items) if (i is TranscriptMessage) i.text],
        ['its own work'],
        reason: 'the agent\'s own output keeps its place',
      );
      expect(r.state.turnActive, isFalse);
      expect(r.state.lastStopReason, isNull, reason: 'the refusal is not a failed turn');
      await r.dispose();
    });

    test('every refused attempt leaves nothing: five in a row, still no user row', () async {
      late final _Rig r;
      r = _Rig(ompInitialize(), {
        'session/prompt': (_) async {
          r.agent.update(_sid, {
            'sessionUpdate': 'agent_message_chunk',
            'content': {'type': 'text', 'text': 'own'},
            'messageId': 'a1',
          });
          await settle();
          throw const JsonRpcException(acpSessionBusy, 'session busy');
        },
      });
      await r.client.initialize();

      for (var i = 0; i < 5; i++) {
        await expectLater(r.client.prompt(_sid, [const TextBlock('hello')]), throwsA(isA<AcpSessionBusyException>()));
      }

      expect(r.userRows, isEmpty);
      await r.dispose();
    });
  });
}
