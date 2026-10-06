// What a caller that keeps the log of a session (the transcript cache) is told
// by the client: every update line as it came, the answer to the load, and the
// user's own messages, which no update carries back, and their withdrawal.
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_client.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/json_rpc.dart';
import 'package:herdr_mobile/data/acp/transcript_log.dart';

import 'support/fake_agent.dart';

class _Handler implements AcpClientHandler {
  @override
  Future<PermissionOutcome> requestPermission(PermissionRequest request, Future<void> cancelled) =>
      throw UnimplementedError();

  @override
  Future<ElicitationResponse> elicit(ElicitationRequest request, Future<void> cancelled) => throw UnimplementedError();
}

void main() {
  test('a prompt, a steer and a prompt the agent refused as busy reach the recorder as they happened', () async {
    final link = MemoryLink();
    var busy = true;
    late final FakeAgent agent;
    agent = FakeAgent(link.agent, {
      'initialize': (_) => {
        ...ompInitialize(),
        'agentCapabilities': {
          'loadSession': true,
          'promptCapabilities': {'embeddedContext': true, 'image': true},
        },
        '_meta': {
          'steering': {'supported': true},
        },
      },
      'session/new': (_) => {'sessionId': 's'},
      'session/prompt': (_) {
        if (busy) throw const JsonRpcException(acpSessionBusy, 'session busy');
        agent.update('s', {
          'sessionUpdate': 'agent_message_chunk',
          'messageId': 'a1',
          'content': {'type': 'text', 'text': 'done'},
        });
        return {'stopReason': 'end_turn'};
      },
      '_session/steering': (_) => {'outcome': 'injected'},
    });
    final recorder = TranscriptRecorder();
    final client = AcpClient(
      link.client,
      handler: _Handler(),
      onUpdateLine: recorder.add,
      onSetup: (sid, result) => recorder.setup = result,
      onLocalUser: recorder.addLocalUser,
      onLocalUserTaken: (_) => recorder.takeBackLocalUser(),
    );
    await client.initialize();
    await client.newSession(cwd: '/x');
    expect(recorder.setup, {'sessionId': 's'});

    // The agent was busy: the message was never taken, and is not in the log.
    await expectLater(client.prompt('s', [const TextBlock('first')]), throwsA(isA<AcpSessionBusyException>()));
    expect(recorder.isEmpty, isTrue);

    busy = false;
    await client.prompt('s', [const TextBlock('second')]);
    final lines = recorder.lines;
    expect(lines, hasLength(2), reason: 'the user message, then the agent\'s update');
    expect(lines.first, contains('user_message_chunk'));
    expect(lines.first, contains('second'));
    expect(lines.last, contains('"done"'));

    await client.steer('s', [const TextBlock('also this')]);
    expect(recorder.lines, hasLength(3));
    expect(recorder.lines.last, contains('also this'));
    await client.close();
  });
}
