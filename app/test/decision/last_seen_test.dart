import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/repositories/last_seen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/trace_session.dart';

final _t0 = DateTime(2026, 10, 5, 14, 2);

TranscriptMessage _msg(String key, MessageRole role) =>
    TranscriptMessage(key: key, role: role, blocks: [TextBlock(key)]);

TranscriptTool _tool(String id) => TranscriptTool(ToolCall(toolCallId: id, title: id));

AgentSessionState _state(List<TranscriptItem> items, {List<PendingRequest> pending = const [], bool replaying = false}) =>
    AgentSessionState('s', items: items, pending: pending, replaying: replaying);

PendingRequest _ask(Object id) => PendingPermission(id, PermissionRequest.parse(const {}));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('sinceLeft', () {
    test('no marker, no divider: the first visit is not news', () async {
      final seen = LastSeen();
      final s = replayTrace('claude/tools').finalState;
      expect(s.items, isNotEmpty);
      expect(await seen.sinceLeft('k', s), isNull);
    });

    test('counts what came after the marker, from a real trace', () async {
      final s = replayTrace('claude/tools').finalState;
      final at = s.items.length ~/ 2;
      final seen = LastSeen()..markSeen('k', _t0, at);
      final r = (await seen.sinceLeft('k', s))!;
      final rest = s.items.sublist(at);
      expect(r.tools, rest.whereType<TranscriptTool>().length);
      expect(r.messages, rest.whereType<TranscriptMessage>().where((m) => m.role == MessageRole.agent).length);
      expect(r.steps, r.tools + r.messages + r.stops + r.notes);
      expect(r.steps, greaterThan(0));
      expect(r.since, _t0);
      expect(r.firstUnseenKey, s.items[at].key);
      expect(r.needsYou, 0);
    });

    test('nothing new and nothing waiting is null', () async {
      final s = replayTrace('omp/tools').finalState;
      final seen = LastSeen()..markSeen('k', _t0, s.items.length);
      expect(await seen.sinceLeft('k', s), isNull);
    });

    test('a request that was waiting when the person left still needs them', () async {
      final s = _state([_msg('m0', MessageRole.user), _tool('a')], pending: [_ask(1)]);
      final seen = LastSeen()..markSeen('k', _t0, 2);
      final r = (await seen.sinceLeft('k', s))!;
      expect((r.steps, r.needsYou, r.firstUnseenKey), (0, 1, null));
    });

    test('steps and a waiting request together: "2 steps since 14:02 · 1 needs you"', () async {
      final s = _state([_msg('m0', MessageRole.user), _tool('a'), _tool('b'), _msg('m1', MessageRole.agent)], pending: [_ask(7)]);
      final seen = LastSeen()..markSeen('k', _t0, 2);
      final r = (await seen.sinceLeft('k', s))!;
      expect((r.steps, r.tools, r.messages, r.needsYou, r.firstUnseenKey), (2, 1, 1, 1, 'tool:b'));
    });

    test('the user\'s own messages and the agent\'s thoughts are news but not steps', () async {
      final seen = LastSeen()..markSeen('k', _t0, 1);
      final quiet = _state([_msg('m0', MessageRole.user), _msg('m1', MessageRole.thought), _msg('m2', MessageRole.user)]);
      expect(await seen.sinceLeft('k', quiet), isNull);
      final busy = _state([_msg('m0', MessageRole.user), _msg('m1', MessageRole.thought), _tool('t')]);
      final r = (await seen.sinceLeft('k', busy))!;
      expect((r.steps, r.firstUnseenKey), (1, 'm1'), reason: 'the divider sits above the first new item, a thought included');
    });

    test('stop rows and notes are steps', () async {
      final seen = LastSeen()..markSeen('k', _t0, 0);
      final s = _state([
        const TranscriptStop(key: 'n1', reason: StopReason.refusal),
        const TranscriptNote(key: 'n2', text: 'Mode changed to Full access', modeId: 'agent-full-access'),
      ]);
      final r = (await seen.sinceLeft('k', s))!;
      expect((r.steps, r.stops, r.notes, r.tools, r.messages), (2, 1, 1, 0, 0));
    });

    test('a transcript shorter than the marker is a replay in progress: no news', () async {
      final seen = LastSeen()..markSeen('k', _t0, 10);
      expect(await seen.sinceLeft('k', _state([_msg('m0', MessageRole.user), _tool('a')])), isNull);
      expect(await seen.sinceLeft('k', _state(const [])), isNull);
    });

    test('while the history replays, nothing is news, whatever is in the list', () async {
      final seen = LastSeen()..markSeen('k', _t0, 1);
      final s = _state([_msg('m0', MessageRole.user), _tool('a'), _tool('b')], replaying: true);
      expect(await seen.sinceLeft('k', s), isNull);
      expect(await seen.sinceLeft('k', _state(s.items)), isNotNull, reason: 'the same list once the replay is over');
    });

    test('the same history replayed after a restart is not news', () async {
      final store = MemoryLastSeenStore();
      final first = LastSeen(store);
      await first.load();
      final before = replayTrace('claude/tools').finalState;
      first.markSeen('k', _t0, before.items.length);
      await Future<void>.delayed(Duration.zero);

      final second = LastSeen(store);
      final replayed = replayTrace('claude/tools').finalState;
      expect(await second.sinceLeft('k', replayed), isNull);
      // Then the agent does one more thing while the app was away.
      final more = _state([...replayed.items, _tool('late')]);
      final r = (await second.sinceLeft('k', more))!;
      expect((r.steps, r.firstUnseenKey), (1, 'tool:late'));
    });

    test('a live message at the marker is seen; its later growth is not counted', () async {
      final live = [
        {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'Hello'}},
      ].fold(const AgentSessionState('s'), (s, u) => s.apply(SessionUpdate.parse(u)));
      final seen = LastSeen()..markSeen('k', _t0, live.items.length);
      final grown = live.apply(SessionUpdate.parse({'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': ' world'}}));
      expect(await seen.sinceLeft('k', grown), isNull);
    });
  });

  group('the store', () {
    test('markers survive a restart through the store', () async {
      final store = MemoryLastSeenStore();
      final a = LastSeen(store);
      await a.load();
      a.markSeen('one', _t0, 5);
      a.markSeen('two', _t0.add(const Duration(minutes: 1)), 9);
      await Future<void>.delayed(Duration.zero);
      expect(store.writes, 2);

      final b = LastSeen(store);
      await b.load();
      expect(b.markerOf('one')!.itemCount, 5);
      expect(b.markerOf('one')!.at, _t0);
      expect(b.markerOf('two')!.itemCount, 9);
      expect(b.length, 2);
    });

    test('markSeen overwrites, clamps a negative count and ignores an empty key', () async {
      final seen = LastSeen()
        ..markSeen('k', _t0, 5)
        ..markSeen('k', _t0.add(const Duration(hours: 1)), -3)
        ..markSeen('', _t0, 1);
      expect(seen.markerOf('k')!.itemCount, 0);
      expect(seen.markerOf('k')!.at, _t0.add(const Duration(hours: 1)));
      expect(seen.length, 1);
    });

    test('a store that cannot be read leaves nothing marked; one that cannot write still remembers', () async {
      final store = MemoryLastSeenStore()..unreadable = true;
      final seen = LastSeen(store);
      await seen.load();
      expect(seen.length, 0);
      store.failing = true;
      seen.markSeen('k', _t0, 3);
      await Future<void>.delayed(Duration.zero);
      expect(seen.markerOf('k')!.itemCount, 3);
      expect(store.saved, isNull);
    });

    test('a marker set before the load finished wins over the saved one', () async {
      final store = MemoryLastSeenStore()..saved = {'k': SeenMarker(_t0, 1), 'other': SeenMarker(_t0, 2)};
      final seen = LastSeen(store)..markSeen('k', _t0.add(const Duration(minutes: 5)), 8);
      await seen.load();
      expect(seen.markerOf('k')!.itemCount, 8);
      expect(seen.markerOf('other')!.itemCount, 2);
      await Future<void>.delayed(Duration.zero);
      expect(store.saved!['k']!.itemCount, 8, reason: 'what was marked early is saved after the load');
    });

    test('at most 200 sessions: the least recently marked go first', () async {
      final seen = LastSeen();
      for (var i = 0; i < 250; i++) {
        seen.markSeen('s$i', _t0.add(Duration(minutes: i)), i);
        if (i == 100) seen.markSeen('s0', _t0, 0); // marked again: no longer the oldest
      }
      expect(seen.length, LastSeen.maxSessions);
      expect(seen.markerOf('s249'), isNotNull);
      expect(seen.markerOf('s0'), isNotNull, reason: 're-marking moved it to the front');
      expect(seen.markerOf('s1'), isNull);
      expect(seen.markerOf('s50'), isNull);
    });

    test('a store holding more than 200 loads the newest 200', () async {
      final store = MemoryLastSeenStore()
        ..saved = {for (var i = 0; i < 300; i++) 's$i': SeenMarker(_t0.add(Duration(minutes: i)), i)};
      final seen = LastSeen(store);
      await seen.load();
      expect(seen.length, 200);
      expect(seen.markerOf('s299'), isNotNull);
      expect(seen.markerOf('s100'), isNotNull);
      expect(seen.markerOf('s99'), isNull);
    });

    test('forget drops the marker and saves', () async {
      final store = MemoryLastSeenStore();
      final seen = LastSeen(store);
      await seen.load();
      seen.markSeen('k', _t0, 1);
      seen.forget('k');
      seen.forget('never');
      await Future<void>.delayed(Duration.zero);
      expect(seen.markerOf('k'), isNull);
      expect(store.saved, isEmpty);
    });
  });

  group('PrefsLastSeenStore', () {
    test('round-trips under lastSeen.v1', () async {
      SharedPreferences.setMockInitialValues({});
      final store = PrefsLastSeenStore();
      expect(await store.read(), isNull);
      await store.write({'a|1|s': SeenMarker(_t0, 12)});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lastSeen.v1'), isNotNull);
      final back = (await store.read())!;
      expect(back['a|1|s']!.itemCount, 12);
      expect(back['a|1|s']!.at, _t0);
    });

    test('garbage reads as nothing; bad entries are skipped, good ones kept', () async {
      SharedPreferences.setMockInitialValues({'lastSeen.v1': 'not json {'});
      expect(await PrefsLastSeenStore().read(), isNull);
      SharedPreferences.setMockInitialValues({'lastSeen.v1': '[1,2]'});
      expect(await PrefsLastSeenStore().read(), isNull);
      SharedPreferences.setMockInitialValues({
        'lastSeen.v1':
            '{"ok":{"at":1000,"n":3},"neg":{"at":1000,"n":-1},"str":{"at":"x","n":1},"flat":5,"missing":{"at":1}}',
      });
      final back = (await PrefsLastSeenStore().read())!;
      expect(back.keys, ['ok']);
      expect(back['ok']!.itemCount, 3);
    });

    test('LastSeen with the real store keeps a marker across instances', () async {
      SharedPreferences.setMockInitialValues({});
      final a = LastSeen(PrefsLastSeenStore());
      await a.load();
      a.markSeen('k', _t0, 4);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final b = LastSeen(PrefsLastSeenStore());
      await b.load();
      expect(b.markerOf('k')!.itemCount, 4);
    });
  });
}
