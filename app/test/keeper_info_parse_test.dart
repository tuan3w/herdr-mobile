import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';

void main() {
  group('a list of keepers from a host', () {
    test('a row without a text id is left out, the others stay', () {
      final keepers = KeeperInfo.listFromJson([
        {'id': 'a1', 'agent': 'omp', 'state': 'running'},
        {'agent': 'omp'},
        {'id': null},
        {'id': 7},
        {'id': ''},
        'not an object',
        null,
        {'id': 'b2', 'state': 'exited', 'exit_code': 1},
      ]);

      expect(keepers.map((k) => k.id), ['a1', 'b2']);
    });

    test('a field of the wrong type is a missing field, not a failed list', () {
      final keepers = KeeperInfo.listFromJson([
        {
          'id': 'a1',
          'agent': 5,
          'cwd': ['x'],
          'pid': 'forty-two',
          'pending': '3',
          'session_id': 9,
          'title': {},
          'exit_code': true,
          'exit_reason': 1,
          'pane_id': 4,
          'clients': 'two',
          'started_at': {},
          'last_event_at': false,
        },
        {'id': 'b2', 'pid': 42},
      ]);

      expect(keepers.map((k) => k.id), ['a1', 'b2']);
      final odd = keepers.first;
      expect(odd.agent, '');
      expect(odd.cwd, '');
      expect(odd.pid, isNull);
      expect(odd.pending, 0);
      expect(odd.sessionId, isNull);
      expect(odd.title, isNull);
      expect(odd.exitCode, isNull);
      expect(odd.paneId, isNull);
      expect(odd.clients, 0);
      expect(odd.startedAt, isNull);
      expect(odd.lastEventAt, isNull);
      expect(keepers.last.pid, 42);
    });

    test('numbers that are not numbers or not times do not throw', () {
      final keepers = KeeperInfo.listFromJson([
        {'id': 'a1', 'pid': double.nan, 'started_at': double.infinity, 'last_event_at': 1e300},
        {'id': 'b2', 'started_at': 'not a time'},
      ]);

      expect(keepers, hasLength(2));
      expect(keepers.first.pid, isNull);
      expect(keepers.first.startedAt, isNull);
      expect(keepers.first.lastEventAt, isNull);
      expect(keepers.last.startedAt, isNull);
    });
  });

  group('one keeper', () {
    test('a keeper with no id is refused, not given the id "null"', () {
      expect(() => KeeperInfo.fromJson({'agent': 'omp'}), throwsFormatException);
      expect(() => KeeperInfo.fromJson({'id': 12}), throwsFormatException);
    });

    test('starting, running and exited are told apart', () {
      KeeperState of(String? state) => KeeperInfo.fromJson({'id': 'a', 'state': state}).state;

      expect(of('starting'), KeeperState.starting);
      expect(of('running'), KeeperState.running);
      expect(of('exited'), KeeperState.exited);
    });

    test('times are epoch milliseconds or ISO text; a missing start is unknown, not 1970', () {
      final info = KeeperInfo.fromJson({
        'id': 'a',
        'started_at': 1791107532538,
        'last_event_at': '2026-10-09T10:00:00Z',
      });
      expect(info.startedAt, DateTime.fromMillisecondsSinceEpoch(1791107532538));
      expect(info.lastEventAt, DateTime.utc(2026, 10, 9, 10));

      final none = KeeperInfo.fromJson({'id': 'a'});
      expect(none.startedAt, isNull);
      expect(KeeperInfo.fromJson(none.toJson()).startedAt, isNull);
    });
  });
}
