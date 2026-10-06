// The data half of the turn model that lives in the reducer: when things
// happened (and the honesty about replayed history), and the one note the
// agent's own mode change writes.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_client.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';

import 'support/fake_agent.dart';
import 'support/trace_state.dart';

final _t0 = DateTime.utc(2026, 10, 5, 9);
DateTime _at(int seconds) => _t0.add(Duration(seconds: seconds));

SessionUpdate _u(Map<String, Object?> json) => SessionUpdate.parse(json);

Map<String, Object?> _agentText(String text, {String id = 'a'}) => {
  'sessionUpdate': 'agent_message_chunk',
  'messageId': id,
  'content': {'type': 'text', 'text': text},
};

Map<String, Object?> _tool(String id, String status, {String kind = 'execute', String title = 'tool'}) => {
  'sessionUpdate': 'tool_call',
  'toolCallId': id,
  'kind': kind,
  'title': title,
  'status': status,
};

Map<String, Object?> _toolDone(String id, String status) => {
  'sessionUpdate': 'tool_call_update',
  'toolCallId': id,
  'status': status,
};

AgentSessionState _omp() => AgentSessionState('s').withSetup(AcpSessionSetup.parse(ompSessionNew()));

int _notes(AgentSessionState s) => s.items.whereType<TranscriptNote>().length;

void main() {
  group('times', () {
    test('items and tool calls are stamped with the update time', () {
      var s = const AgentSessionState('s').withUserMessage([const TextBlock('go')], at: _at(0)).withTurnStarted();
      s = s.apply(_u(_agentText('Let me look')), at: _at(2));
      s = s.apply(_u(_tool('t1', 'in_progress')), at: _at(5));
      s = s.apply(_u(_toolDone('t1', 'completed')), at: _at(9));
      s = s.apply(_u(_agentText('Done', id: 'b')), at: _at(10));
      s = s.withTurnEnded(StopReason.endTurn, at: _at(14));

      final user = s.items[0] as TranscriptMessage;
      final narration = s.items[1] as TranscriptMessage;
      final tool = s.items[2] as TranscriptTool;
      final answer = s.items[3] as TranscriptMessage;
      expect(user.at, _at(0));
      expect(narration.at, _at(2));
      expect(narration.endedAt, _at(5), reason: 'settled by the next item');
      expect(tool.at, _at(5));
      expect(tool.startedAt, _at(5));
      expect(tool.finishedAt, _at(9));
      expect(tool.duration, const Duration(seconds: 4));
      expect(answer.at, _at(10));
      expect(answer.endedAt, _at(14), reason: 'settled by the end of the turn');
      expect(s.items.every((i) => i.timed), isTrue);
    });

    test('a tool call that starts finished has no duration; the finish time is set once', () {
      var s = const AgentSessionState('s');
      s = s.apply(_u(_tool('t1', 'completed')), at: _at(1));
      var tool = s.items.single as TranscriptTool;
      expect(tool.at, _at(1));
      expect(tool.finishedAt, _at(1));
      s = s.apply(_u(_toolDone('t1', 'completed')), at: _at(30));
      tool = s.items.single as TranscriptTool;
      expect(tool.finishedAt, _at(1), reason: 'a repeated completed keeps the first time');
    });

    test('a call that is reopened is unfinished again', () {
      var s = const AgentSessionState('s').apply(_u(_tool('t1', 'in_progress')), at: _at(1));
      s = s.apply(_u(_toolDone('t1', 'completed')), at: _at(2));
      s = s.apply(_u(_toolDone('t1', 'in_progress')), at: _at(3));
      expect((s.items.single as TranscriptTool).finishedAt, isNull);
      s = s.apply(_u(_toolDone('t1', 'failed')), at: _at(8));
      expect((s.items.single as TranscriptTool).duration, const Duration(seconds: 7));
    });

    test('cancelling stamps the calls it cancels', () {
      var s = const AgentSessionState('s').apply(_u(_tool('t1', 'in_progress')), at: _at(1));
      s = s.withCancelRequested(at: _at(6));
      final tool = s.items.single as TranscriptTool;
      expect(tool.call.status, ToolStatus.cancelled);
      expect(tool.at, _at(1));
      expect(tool.finishedAt, _at(6));
      expect(tool.duration, const Duration(seconds: 5));
    });

    test('a stop row carries the time of the end of the turn', () {
      final s = const AgentSessionState('s').withTurnEnded(StopReason.refusal, at: _at(3));
      expect((s.items.single as TranscriptStop).at, _at(3));
    });

    test('no clock, no time', () {
      var s = const AgentSessionState('s').withUserMessage([const TextBlock('go')]);
      s = s.apply(_u(_agentText('hi')));
      s = s.apply(_u(_tool('t1', 'completed')));
      expect(s.items.every((i) => !i.timed && i.at == null), isTrue);
      expect((s.items.last as TranscriptTool).duration, isNull);
    });

    test('the echo of the prompt keeps the time the client stamped', () {
      var s = const AgentSessionState('s').withUserMessage([const TextBlock('hello')], at: _at(0));
      s = s.apply(_u({'sessionUpdate': 'user_message_chunk', 'content': {'type': 'text', 'text': 'hello'}}), at: _at(1));
      final user = s.items.single as TranscriptMessage;
      expect(user.local, isFalse);
      expect(user.at, _at(0));
    });

    test('a message that goes live again keeps the time it first arrived', () {
      var s = const AgentSessionState('s');
      s = s.apply(_u(_agentText('one', id: 'a')), at: _at(1));
      s = s.apply(_u(_tool('t1', 'completed')), at: _at(2));
      s = s.apply(_u(_agentText(' two', id: 'a')), at: _at(9));
      final m = s.items.first as TranscriptMessage;
      expect(m.text, 'one two');
      expect(m.at, _at(1));
    });

    test('a chunk for the live message costs no new item list and no time', () {
      var s = const AgentSessionState('s').apply(_u(_agentText('a')), at: _at(1));
      final items = s.items;
      s = s.apply(_u(_agentText('b')), at: _at(2));
      expect(identical(s.items, items), isTrue);
      expect((s.items.single as TranscriptMessage).at, _at(1));
    });
  });

  group('replay', () {
    test('what arrives while the state replays is history: no times', () {
      var s = AgentSessionState('s', replaying: true);
      s = s.apply(_u({'sessionUpdate': 'user_message_chunk', 'content': {'type': 'text', 'text': 'fix it'}}), at: _at(1));
      s = s.apply(_u(_agentText('ok')), at: _at(2));
      s = s.apply(_u(_tool('t1', 'completed')), at: _at(3));
      s = s.apply(_u(_tool('t2', 'in_progress')), at: _at(4));
      expect(s.items.every((i) => !i.timed), isTrue);
      expect(s.lastActivityAt, _at(4), reason: 'activity is still when the client last heard anything');
      final tool = s.items[2] as TranscriptTool;
      expect(tool.finishedAt, isNull);
    });

    test('the answer to the load ends the replay; what comes after is timed', () {
      var s = AgentSessionState('s', replaying: true);
      s = s.apply(_u(_agentText('old')), at: _at(1));
      s = s.withSetup(AcpSessionSetup.parse(ompSessionNew()));
      expect(s.replaying, isFalse);
      s = s.apply(_u(_tool('t1', 'in_progress')), at: _at(10));
      expect((s.items[0] as TranscriptMessage).timed, isFalse);
      expect((s.items[1] as TranscriptTool).at, _at(10));
    });

    test('a call that started in the replay and finishes live has no duration', () {
      var s = AgentSessionState('s', replaying: true).apply(_u(_tool('t1', 'in_progress')), at: _at(1));
      s = s.withSetup(const AcpSessionSetup());
      s = s.apply(_u(_toolDone('t1', 'completed')), at: _at(50));
      final tool = s.items.single as TranscriptTool;
      expect(tool.at, isNull);
      expect(tool.finishedAt, _at(50));
      expect(tool.duration, isNull);
    });
  });

  group('mode note', () {
    test('an agent-initiated current_mode_update adds one note, keyed and timed', () {
      var s = _omp();
      s = s.apply(_u({'sessionUpdate': 'current_mode_update', 'currentModeId': 'plan'}), at: _at(5));
      final note = s.items.single as TranscriptNote;
      expect(note.text, 'Mode changed to Plan');
      expect(note.modeId, 'plan');
      expect(note.at, _at(5));
      expect(note.key, startsWith('n'));
      expect(s.currentModeId, 'plan');
      // The same mode again changes nothing.
      s = s.apply(_u({'sessionUpdate': 'current_mode_update', 'currentModeId': 'plan'}), at: _at(6));
      expect(_notes(s), 1);
    });

    test('a config_option_update that changes the mode option writes the note; the twin update does not repeat it', () {
      var s = _omp();
      final options = ompSessionNew()['configOptions']! as List;
      final changed = [
        for (final o in options)
          (o as Map<String, Object?>)['id'] == 'mode' ? {...o, 'currentValue': 'plan'} : o,
      ];
      s = s.apply(_u({'sessionUpdate': 'config_option_update', 'configOptions': changed}), at: _at(1));
      expect(_notes(s), 1);
      expect((s.items.single as TranscriptNote).text, 'Mode changed to Plan');
      s = s.apply(_u({'sessionUpdate': 'current_mode_update', 'currentModeId': 'plan'}), at: _at(1));
      expect(_notes(s), 1, reason: 'omp sends both for one change');
    });

    test('an update that leaves the mode alone writes none', () {
      var s = _omp();
      final options = ompSessionNew()['configOptions']! as List;
      final model = [
        for (final o in options)
          (o as Map<String, Object?>)['id'] == 'model' ? {...o, 'currentValue': 'openai/gpt-5'} : o,
      ];
      s = s.apply(_u({'sessionUpdate': 'config_option_update', 'configOptions': model}), at: _at(1));
      expect(_notes(s), 0);
      s = s.apply(_u({'sessionUpdate': 'current_mode_update', 'currentModeId': 'default'}), at: _at(2));
      expect(_notes(s), 0);
    });

    test('the first sight of a mode is not a change', () {
      var s = const AgentSessionState('s');
      s = s.apply(_u({'sessionUpdate': 'current_mode_update', 'currentModeId': 'plan'}), at: _at(1));
      expect(_notes(s), 0);
      expect(s.currentModeId, 'plan');
      var c = const AgentSessionState('s');
      c = c.apply(_u({'sessionUpdate': 'config_option_update', 'configOptions': ompSessionNew()['configOptions']}));
      expect(_notes(c), 0);
    });

    test('a replayed history writes none', () {
      var s = _omp().withSetup(const AcpSessionSetup());
      s = AgentSessionState('s', replaying: true, modes: s.modes, configOptions: s.configOptions);
      s = s.apply(_u({'sessionUpdate': 'current_mode_update', 'currentModeId': 'plan'}), at: _at(1));
      expect(_notes(s), 0);
      expect(s.currentModeId, 'plan');
    });

    test('a change the person asked for writes none, whichever of the answer and the report comes first', () {
      var s = _omp().withExpectedMode('plan');
      s = s.apply(_u({'sessionUpdate': 'current_mode_update', 'currentModeId': 'plan'}), at: _at(1));
      expect(_notes(s), 0);
      expect(s.expectedMode, isNull, reason: 'consumed when the mode arrives');
      // After that an agent change to the same mode is news again.
      s = s.apply(_u({'sessionUpdate': 'current_mode_update', 'currentModeId': 'default'}), at: _at(2));
      expect(_notes(s), 1);

      var t = _omp().withExpectedMode('plan');
      t = t.apply(const ModeUpdate('plan'));
      expect(_notes(t), 0);
      expect(t.expectedMode, isNull);
    });

    test('only the mode the person asked for is silent', () {
      var s = _omp().withExpectedMode('default');
      s = s.apply(_u({'sessionUpdate': 'current_mode_update', 'currentModeId': 'plan'}), at: _at(1));
      expect(_notes(s), 1);
      expect(s.expectedMode, 'default');
    });

    test('withExpectedConfig expects a mode only for a select of the mode category', () {
      final s = _omp();
      expect(s.withExpectedConfig('mode', 'plan').expectedMode, 'plan');
      expect(s.withExpectedConfig('model', 'openai/gpt-5').expectedMode, isNull);
      expect(s.withExpectedConfig('mode', true).expectedMode, isNull);
      expect(s.withExpectedMode(null), same(s));
    });

    test('the answer to set_config_option never writes a note', () {
      final s = _omp();
      final options = ompSessionNew()['configOptions']! as List;
      final changed = parseConfigOptions([
        for (final o in options)
          (o as Map<String, Object?>)['id'] == 'mode' ? {...o, 'currentValue': 'plan'} : o,
      ]);
      expect(_notes(s.withConfigOptions(changed)), 0);
    });

    test('a note splits the agent message after it: the next text is a new message', () {
      var s = _omp();
      s = s.apply(_u(_agentText('before', id: 'a')), at: _at(1));
      s = s.apply(_u({'sessionUpdate': 'current_mode_update', 'currentModeId': 'plan'}), at: _at(2));
      s = s.apply(_u(_agentText('after', id: 'b')), at: _at(3));
      expect(s.items.map((i) => i.runtimeType), [TranscriptMessage, TranscriptNote, TranscriptMessage]);
      expect(s.items.map((i) => i.key).toSet(), hasLength(3), reason: 'keys stay unique and stable');
    });
  });

  group('client', () {
    late MemoryLink link;
    late FakeAgent agent;
    late AcpClient client;
    var tick = 0;
    DateTime clock() => _at(tick++);

    Future<void> start(Map<String, AgentMethod> methods) async {
      link = MemoryLink();
      agent = FakeAgent(link.agent, {'initialize': (_) => ompInitialize(), ...methods});
      client = AcpClient(link.client, handler: _NoHandler(), clock: clock);
      await client.initialize();
      agent.update('s', {'sessionUpdate': 'config_option_update', 'configOptions': ompSessionNew()['configOptions']});
    }

    setUp(() => tick = 0);
    tearDown(() => client.close());

    test('the person\'s setMode writes no note, even when the agent reports before it answers', () async {
      await start({
        'session/set_mode': (r) {
          agent.update('s', {'sessionUpdate': 'current_mode_update', 'currentModeId': 'plan'});
          return <String, Object?>{};
        },
      });
      await client.setMode('s', 'plan');
      final s = client.state('s');
      expect(s.currentModeId, 'plan');
      expect(_notes(s), 0);
      expect(s.expectedMode, isNull);
    });

    test('a failed setMode forgets what it expected', () async {
      await start({'session/set_mode': (_) => throw JsonRpcErrorStub()});
      await expectLater(client.setMode('s', 'plan'), throwsA(anything));
      expect(client.state('s').expectedMode, isNull);
    });

    test('the person\'s mode through set_config_option writes no note', () async {
      await start({
        'session/set_config_option': (r) {
          final options = ompSessionNew()['configOptions']! as List;
          final changed = [
            for (final o in options)
              (o as Map<String, Object?>)['id'] == 'mode' ? {...o, 'currentValue': 'plan'} : o,
          ];
          agent.update('s', {'sessionUpdate': 'config_option_update', 'configOptions': changed});
          return {'configOptions': changed};
        },
      });
      await client.setConfigOption('s', 'mode', 'plan');
      expect(client.state('s').currentModeId, 'plan');
      expect(_notes(client.state('s')), 0);
    });

    test('the agent switching the mode on its own is announced once', () async {
      await start({});
      agent.update('s', {'sessionUpdate': 'current_mode_update', 'currentModeId': 'plan'});
      expect(_notes(client.state('s')), 1);
      expect((client.state('s').items.single as TranscriptNote).text, 'Mode changed to Plan');
    });

    test('prompt and cancel stamp the user message, the end of the turn and cancelled calls', () async {
      final done = Completer<Object?>();
      await start({'session/prompt': (_) => done.future});
      final turn = client.prompt('s', [const TextBlock('go')]);
      final sent = (client.state('s').items.single as TranscriptMessage).at;
      expect(sent, isNotNull);
      agent.update('s', _tool('t1', 'in_progress'));
      client.cancel('s');
      final cancelled = client.state('s').items.last as TranscriptTool;
      expect(cancelled.finishedAt, isNotNull);
      expect(cancelled.finishedAt!.isAfter(cancelled.at!), isTrue);
      done.complete({'stopReason': 'cancelled'});
      await turn;
      expect(client.state('s').turnActive, isFalse);
    });

    test('session/load replays without times and ends the replay with its answer', () async {
      await start({
        'session/load': (r) {
          agent.update('s', {'sessionUpdate': 'user_message_chunk', 'content': {'type': 'text', 'text': 'old prompt'}});
          agent.update('s', _agentText('old answer'));
          agent.update('s', _tool('t1', 'completed'));
          agent.update('s', {'sessionUpdate': 'current_mode_update', 'currentModeId': 'default'});
          return ompSessionNew();
        },
      });
      final loaded = await client.loadSession('s', cwd: '/p');
      expect(loaded.replaying, isFalse);
      expect(loaded.items.every((i) => !i.timed), isTrue);
      agent.update('s', _agentText('new', id: 'n'));
      final live = client.state('s').items.last as TranscriptMessage;
      expect(live.timed, isTrue);
    });
  });

  group('trace fixtures', () {
    test('a live fold gives times for every item; a replay of the same trace gives none', () {
      for (final (agent, scenario) in const [('claude', 'tools'), ('omp', 'tools'), ('codex', 'tools')]) {
        final live = stateOfTrace(agent, scenario);
        final replay = replayOfTrace(agent, scenario);
        expect(live.items.every((i) => i.timed), isTrue, reason: '$agent/$scenario live');
        expect(replay.items.every((i) => !i.timed), isTrue, reason: '$agent/$scenario replay');
        expect(replay.items.length, live.items.length, reason: '$agent/$scenario same transcript');
        for (final i in live.items.whereType<TranscriptTool>()) {
          expect(i.finishedAt, isNotNull, reason: '$agent/$scenario ${i.key}');
        }
      }
    });
  });
}

class _NoHandler implements AcpClientHandler {
  @override
  Future<PermissionOutcome> requestPermission(PermissionRequest request, Future<void> cancelled) =>
      Completer<PermissionOutcome>().future;

  @override
  Future<ElicitationResponse> elicit(ElicitationRequest request, Future<void> cancelled) =>
      Completer<ElicitationResponse>().future;
}

class JsonRpcErrorStub implements Exception {
  @override
  String toString() => 'agent refused';
}
