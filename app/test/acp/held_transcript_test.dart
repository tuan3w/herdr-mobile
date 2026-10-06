import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_client.dart' show applyUpdateParams;
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';

// The keeper's log is bounded: a replay can be shorter than the transcript the
// phone holds (in memory, or its saved copy). `withHeld` puts what the replay
// lacks back above it, once, and says so only when it cannot tell the two
// apart. `withSetup` opens a replay with the line about the turns the host
// dropped.

Json _tool(String id, {String status = 'completed', Json? extra}) => {
  'sessionUpdate': 'tool_call',
  'toolCallId': id,
  'title': 'step $id',
  'kind': 'execute',
  'status': status,
  'rawInput': {'command': 'run $id'},
  ...?extra,
};

Json _chunk(String kind, String text, String id) => {
  'sessionUpdate': kind,
  'messageId': id,
  'content': {'type': 'text', 'text': text},
};

/// One turn the way a replay gives it: the question, a call, the answer.
List<Json> _turn(int i, {Json? tool}) => [
  _chunk('user_message_chunk', 'question $i', 'u$i'),
  tool ?? _tool('c$i'),
  _chunk('agent_message_chunk', 'answer $i', 'a$i'),
];

AcpSessionSetup _setup({int dropped = 0, int trimmed = 0}) => AcpSessionSetup.parse({
  'sessionId': 's',
  if (dropped > 0 || trimmed > 0)
    '_meta': {
      'herdr': {'droppedTurns': dropped, 'trimmedTurns': trimmed},
    },
});

/// What a `session/load` of [turns] gives, answered with [setup].
AgentSessionState _replay(Iterable<int> turns, {AcpSessionSetup? setup, Map<int, Json>? tools}) {
  var s = AgentSessionState('s', replaying: true);
  for (final i in turns) {
    for (final u in _turn(i, tool: tools?[i])) {
      s = applyUpdateParams(s, {'sessionId': 's', 'update': u});
    }
  }
  return s.withSetup(setup ?? _setup());
}

String _name(TranscriptItem i) => switch (i) {
  TranscriptMessage(:final role, :final text) => '${role.name}:$text',
  TranscriptTool(:final call) => 'tool:${call.toolCallId}',
  TranscriptNote(:final text) => 'note:$text',
  TranscriptStop() => 'stop',
};

List<String> _names(AgentSessionState s) => [for (final i in s.items) _name(i)];

List<String> _turnNames(Iterable<int> turns) => [
  for (final i in turns) ...['user:question $i', 'tool:c$i', 'agent:answer $i'],
];

void _expectUniqueKeys(AgentSessionState s) {
  final keys = [for (final i in s.items) i.key];
  expect(keys.toSet(), hasLength(keys.length), reason: 'duplicate keys in $keys');
}

const _earlierNote = 'note:Earlier, from this phone';

void main() {
  group('what the keeper reports in the answer to session/load', () {
    test('droppedTurns and trimmedTurns are read from _meta.herdr; anything else is zero', () {
      final s = _setup(dropped: 7, trimmed: 2);
      expect((s.droppedTurns, s.trimmedTurns), (7, 2));
      expect(AcpSessionSetup.parse({'sessionId': 's'}).droppedTurns, 0);
      expect(
        AcpSessionSetup.parse({
          '_meta': {
            'herdr': {'droppedTurns': -3, 'trimmedTurns': 'many'},
          },
        }).droppedTurns,
        0,
      );
      expect(AcpSessionSetup.parse({'_meta': 'x'}).trimmedTurns, 0);
    });

    test('the transcript opens with ONE quiet line when turns were dropped, and none otherwise', () {
      final plain = _replay([0, 1]);
      expect(plain.items.any((i) => i.key == hostDroppedKey), isFalse);

      final dropped = _replay([3, 4], setup: _setup(dropped: 3));
      expect(_names(dropped).first, 'note:Earlier messages are no longer kept on the host (3 turns).');
      expect(dropped.items.where((i) => i.key == hostDroppedKey), hasLength(1));
      expect(_names(dropped).skip(1), _turnNames([3, 4]));

      // The same answer applied again does not add a second line.
      expect(dropped.withSetup(_setup(dropped: 3)).items.where((i) => i.key == hostDroppedKey), hasLength(1));
      expect(_replay([5], setup: _setup(dropped: 1)).items.first, isA<TranscriptNote>().having((n) => n.text, 'text', contains('(1 turn)')));
    });

    test('the live message keeps its place under the line', () {
      final s = _replay([3, 4], setup: _setup(dropped: 2));
      expect(s.liveMessage?.text, 'answer 4');
    });
  });

  group('a replay shorter than what the phone holds', () {
    test('keeps the older part once, above the replay, with no divider when the overlap is proven', () {
      final held = _replay([0, 1, 2, 3, 4, 5]);
      final replay = _replay([3, 4, 5], setup: _setup(dropped: 3));
      final merged = replay.withHeld(held);

      expect(merged.older, 9);
      expect(_names(merged.state), [
        'note:Earlier messages are no longer kept on the host (3 turns).',
        ..._turnNames([0, 1, 2, 3, 4, 5]),
      ]);
      expect(_names(merged.state), isNot(contains(_earlierNote)));
      _expectUniqueKeys(merged.state);
      expect(merged.state.liveMessage?.text, 'answer 5', reason: 'the live slot moved with the rows');
    });

    test('a note the held transcript had is not kept: the replay says how many are gone now', () {
      final held = _replay([0, 1, 2, 3], setup: _setup(dropped: 1));
      final replay = _replay([2, 3], setup: _setup(dropped: 2));
      final merged = replay.withHeld(held).state;
      expect(merged.items.where((i) => i.key == hostDroppedKey), hasLength(1));
      expect(_name(merged.items.first), contains('(2 turns)'));
      expect(_names(merged).skip(1), _turnNames([0, 1, 2, 3]));
    });

    test('no duplicates when they overlap: the same replay changes nothing', () {
      final held = _replay([0, 1, 2, 3]);
      final replay = _replay([0, 1, 2, 3]);
      final merged = replay.withHeld(held);
      expect(identical(merged.state, replay), isTrue);
      expect(merged.older, 0);
      expect(_names(merged.state), _turnNames([0, 1, 2, 3]));
    });

    test('a replay that reaches further back than the phone adds nothing of the phone', () {
      final held = _replay([3, 4, 5]);
      final replay = _replay([0, 1, 2, 3, 4, 5]);
      final merged = replay.withHeld(held);
      expect(merged.older, 0);
      expect(_names(merged.state), _turnNames([0, 1, 2, 3, 4, 5]));
    });

    test('a replay with more at the end than the phone saw keeps the phone\'s older part and takes the rest', () {
      final held = _replay([0, 1, 2, 3]);
      final replay = _replay([2, 3, 4, 5], setup: _setup(dropped: 2));
      final merged = replay.withHeld(held).state;
      expect(_names(merged).skip(1), _turnNames([0, 1, 2, 3, 4, 5]));
      _expectUniqueKeys(merged);
    });

    test('an empty replay keeps what the phone has', () {
      final held = _replay([0, 1]);
      final replay = AgentSessionState('s').withSetup(_setup());
      final merged = replay.withHeld(held);
      expect(_names(merged.state), _turnNames([0, 1]));
      expect(_names(merged.state), isNot(contains(_earlierNote)), reason: 'nothing is below it');
    });

    test('merging twice keeps one copy, one note, and keys that never meet', () {
      final held = _replay([0, 1, 2, 3, 4, 5]);
      final first = _replay([3, 4, 5], setup: _setup(dropped: 3)).withHeld(held).state;
      // The keeper holds one more turn now, and still not the first three.
      final second = _replay([3, 4, 5, 6], setup: _setup(dropped: 3)).withHeld(first).state;
      expect(_names(second), [
        'note:Earlier messages are no longer kept on the host (3 turns).',
        ..._turnNames([0, 1, 2, 3, 4, 5, 6]),
      ]);
      _expectUniqueKeys(second);
      // And a third time, from the second.
      final third = _replay([4, 5, 6, 7], setup: _setup(dropped: 4)).withHeld(second).state;
      expect(_names(third).skip(1), _turnNames([0, 1, 2, 3, 4, 5, 6, 7]));
      _expectUniqueKeys(third);
    });
  });

  group('when the overlap cannot be proven', () {
    test('nothing in common: all of the phone\'s transcript stays above the divider', () {
      final held = _replay([0, 1, 2]);
      final replay = _replay([10, 11], setup: _setup(dropped: 10));
      final merged = replay.withHeld(held);
      expect(_names(merged.state), [
        'note:Earlier messages are no longer kept on the host (10 turns).',
        ..._turnNames([0, 1, 2]),
        _earlierNote,
        ..._turnNames([10, 11]),
      ]);
      expect(merged.older, 9, reason: 'the divider is not counted');
      _expectUniqueKeys(merged.state);
      expect(merged.state.items.where((i) => i.key == phoneEarlierKey), hasLength(1));
    });

    test('one item alike is not proof: the same first question, then something else', () {
      final held = _replay([0, 1]);
      var replay = AgentSessionState('s', replaying: true);
      for (final u in [
        _chunk('user_message_chunk', 'question 0', 'u0'),
        _tool('other'),
        _chunk('agent_message_chunk', 'a different answer', 'x9'),
      ]) {
        replay = applyUpdateParams(replay, {'sessionId': 's', 'update': u});
      }
      final merged = replay.withSetup(_setup()).withHeld(held).state;
      expect(_names(merged), contains(_earlierNote));
      expect(_names(merged).where((n) => n == 'user:question 0'), hasLength(2), reason: 'both are real: they differ after it');
    });

    test('the divider is not written again once the next replay overlaps what the first one brought', () {
      final held = _replay([0, 1, 2]);
      final first = _replay([10, 11], setup: _setup(dropped: 10)).withHeld(held).state;
      final second = _replay([10, 11, 12], setup: _setup(dropped: 10)).withHeld(first).state;
      expect(_names(second).where((n) => n == _earlierNote), hasLength(1));
      expect(_names(second).skip(1), [..._turnNames([0, 1, 2]), _earlierNote, ..._turnNames([10, 11, 12])]);
      _expectUniqueKeys(second);
    });
  });

  group('detail the host trimmed', () {
    Json trimmed(String id) => _tool(
      id,
      extra: {
        '_meta': {
          'herdr': {'trimmed': true},
        },
      },
    )..remove('rawInput');

    test('a call the replay holds trimmed keeps the phone\'s fuller copy', () {
      final held = _replay([0, 1, 2], tools: {1: _tool('c1', extra: {'rawOutput': 'the whole output'})});
      final replay = _replay([1, 2], tools: {1: trimmed('c1')}, setup: _setup(dropped: 1, trimmed: 1));
      final merged = replay.withHeld(held).state;
      final call = merged.toolCall('c1')!;
      expect(call.rawOutput, 'the whole output');
      expect(call.detailTrimmed, isFalse);
      expect(_names(merged).skip(1), _turnNames([0, 1, 2]));
    });

    test('a call the phone has no fuller copy of stays trimmed', () {
      final held = _replay([0]);
      final replay = _replay([1, 2], tools: {1: trimmed('c1')}, setup: _setup(dropped: 1, trimmed: 1));
      final merged = replay.withHeld(held).state;
      expect(merged.toolCall('c1')!.detailTrimmed, isTrue);
      expect(merged.toolCall('c0')!.detailTrimmed, isFalse);
    });

    test('_meta.herdr.trimmed reads from a call, and only when it is true', () {
      expect(ToolCall.parse(trimmed('t')).detailTrimmed, isTrue);
      expect(ToolCall.parse(_tool('t')).detailTrimmed, isFalse);
      expect(
        ToolCall.parse(_tool('t', extra: {
          '_meta': {
            'herdr': {'trimmed': 'yes'},
          },
        })).detailTrimmed,
        isFalse,
      );
    });
  });
}
