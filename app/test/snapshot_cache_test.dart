import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/models/status_time.dart';
import 'package:herdr_mobile/data/services/snapshot_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_transport.dart';

Snapshot _snapshot(String version, {int panes = 1}) => Snapshot.fromJson(
      snapshotJson(
        version: version,
        panes: [
          for (var i = 0; i < panes; i++)
            (id: 'w1:p$i', ws: 'w1', agent: 'claude', status: 'working'),
        ],
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('round-trips a snapshot per machine', () async {
    final cache = PrefsSnapshotCache();
    await cache.write('a', _snapshot('1'));
    await cache.write('b', _snapshot('2', panes: 3));

    expect((await cache.read('a'))!.snapshot, _snapshot('1'));
    expect((await cache.read('b'))!.snapshot, _snapshot('2', panes: 3));
    expect(await cache.read('c'), isNull);
  });

  test('a second instance (next app start) reads what the first wrote', () async {
    await PrefsSnapshotCache().write('a', _snapshot('1'));
    expect((await PrefsSnapshotCache().read('a'))!.snapshot, _snapshot('1'));
  });

  test('delete removes only that machine', () async {
    final cache = PrefsSnapshotCache();
    await cache.write('a', _snapshot('1'));
    await cache.write('b', _snapshot('2'));

    await cache.delete('a');

    expect(await cache.read('a'), isNull);
    expect(await cache.read('b'), isNotNull);
  });

  test('corrupt or foreign data reads as null instead of throwing', () async {
    final prefs = await SharedPreferences.getInstance();
    final key = await _keyFor(prefs, 'a');
    for (final garbage in const [
      'not json {',
      '[1, 2, 3]',
      '"a string"',
      '{"panes": "not a list"}',
    ]) {
      await prefs.setString(key, garbage);
      expect(await PrefsSnapshotCache().read('a'), isNull, reason: garbage);
    }
  });

  test('snapshots over the size limit are not stored', () async {
    final cache = PrefsSnapshotCache(maxBytes: 1000);
    await cache.write('small', _snapshot('1', panes: 1));
    await cache.write('big', _snapshot('1', panes: 50));

    expect(await cache.read('small'), isNotNull);
    expect(await cache.read('big'), isNull);
  });

  test('an oversized update keeps the previous good entry', () async {
    final cache = PrefsSnapshotCache(maxBytes: 1000);
    await cache.write('a', _snapshot('1', panes: 1));
    await cache.write('a', _snapshot('2', panes: 50));

    expect((await cache.read('a'))!.snapshot.version, '1');
  });

  test('operations apply in call order even when not awaited', () async {
    final cache = PrefsSnapshotCache();
    final pending = [
      cache.write('a', _snapshot('1')),
      cache.write('a', _snapshot('2')),
      cache.delete('a'),
      cache.write('b', _snapshot('3')),
    ];
    await Future.wait(pending);

    expect(await cache.read('a'), isNull, reason: 'delete came last for a');
    expect((await cache.read('b'))!.snapshot.version, '3');
  });

  group('status times in the record', () {
    const key = 'herdr.snapshot.v1.m';
    final snapshot = _snapshot('1', panes: 2);

    /// Stores a record as an app of some version wrote it (the snapshot's own
    /// JSON plus [observed] when given) and reads it back through the cache.
    Future<CachedSnapshot?> readRecord({Object? observed, bool withObserved = true}) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        key,
        jsonEncode({...snapshot.toJson(), if (withObserved) 'observed': observed}),
      );
      return PrefsSnapshotCache().read('m');
    }

    test('a record from before times were kept reads as a snapshot with none', () async {
      final read = await readRecord(withObserved: false);

      expect(read!.snapshot, snapshot);
      expect(read.observed, isNull);
    });

    test('a 0.4.5 record (local time as ISO text, no offset) still reads', () async {
      final read = await readRecord(observed: {
        'seen': '2026-03-04T05:06:07.000',
        'panes': {
          'w1:p0': {
            's': 'blocked',
            't': {'at': '2026-03-04T05:00:00.000'},
          },
          'w1:p1': {
            's': 'working',
            't': {'at': '2026-03-04T05:01:00.000', 'bound': true},
          },
        },
      });

      final observed = read!.observed!;
      expect(observed.seenAt, DateTime(2026, 3, 4, 5, 6, 7), reason: 'no offset: local time');
      expect(observed.panes['w1:p0'],
          (status: AgentStatus.blocked, since: StatusTime.exact(DateTime(2026, 3, 4, 5))));
      expect(observed.panes['w1:p1'],
          (status: AgentStatus.working, since: StatusTime.after(DateTime(2026, 3, 4, 5, 1))));
    });

    test('ISO text that does carry an offset is the same moment whatever it is written in', () async {
      final read = await readRecord(observed: {
        'seen': '2026-03-04T05:06:07.000Z',
        'panes': {
          'w1:p0': {
            's': 'idle',
            't': {'at': '2026-03-04T07:06:07.000+02:00'},
          },
        },
      });

      final observed = read!.observed!;
      expect(observed.seenAt.isAtSameMomentAs(DateTime.utc(2026, 3, 4, 5, 6, 7)), isTrue);
      expect(observed.panes['w1:p0']!.since, StatusTime.exact(DateTime.utc(2026, 3, 4, 5, 6, 7)));
    });

    test('malformed times never cost the snapshot, and bad entries are skipped', () async {
      for (final bad in <Object?>[
        'text',
        7,
        <Object?>[],
        {'panes': {}},
        {'seen': true, 'panes': {}},
        {'seen': 'yesterday', 'panes': {}},
        {'seen': 1000, 'panes': <Object?>[]},
        {'seen': 1000},
      ]) {
        final read = await readRecord(observed: bad);
        expect(read!.snapshot, snapshot, reason: '$bad');
        expect(read.observed, isNull, reason: '$bad');
      }

      final read = await readRecord(observed: {
        'seen': 1000,
        'panes': {
          'w1:p0': {
            's': 'working',
            't': {'at': 'garbage'},
          },
          'w1:p1': 'not a map',
          'w1:p2': {
            's': 'blocked',
            't': {'at': true},
          },
          'w1:p3': {'s': 'dancing'},
        },
      });
      expect(read!.observed!.panes.keys, ['w1:p0', 'w1:p2', 'w1:p3'], reason: 'the non-map entry is dropped');
      expect(read.observed!.panes['w1:p0'], (status: AgentStatus.working, since: null));
      expect(read.observed!.panes['w1:p2'], (status: AgentStatus.blocked, since: null));
      expect(read.observed!.panes['w1:p3'], (status: AgentStatus.unknown, since: null));
    });

    test('the current format stores moments as epoch milliseconds and reads them back', () async {
      final seen = DateTime.utc(2026, 3, 4, 5, 6, 7);
      final began = DateTime.utc(2026, 3, 4, 4, 30);
      await PrefsSnapshotCache().write(
        'm',
        snapshot,
        observed: ObservedStatuses(seenAt: seen, panes: {
          'w1:p0': (status: AgentStatus.blocked, since: StatusTime.exact(began)),
          'w1:p1': (status: AgentStatus.working, since: StatusTime.after(began)),
          'w1:p2': (status: AgentStatus.idle, since: null),
        }),
      );

      final stored = jsonDecode((await SharedPreferences.getInstance()).getString(key)!) as Map<String, dynamic>;
      final times = stored['observed'] as Map<String, dynamic>;
      expect(times['seen'], seen.millisecondsSinceEpoch);
      expect(((times['panes'] as Map)['w1:p0'] as Map)['t'], {'at': began.millisecondsSinceEpoch});
      expect(((times['panes'] as Map)['w1:p1'] as Map)['t'], {'at': began.millisecondsSinceEpoch, 'bound': true});
      expect((times['panes'] as Map)['w1:p2'], {'s': 'idle'});

      final read = (await PrefsSnapshotCache().read('m'))!.observed!;
      expect(read.seenAt.isAtSameMomentAs(seen), isTrue);
      expect(read.panes['w1:p0'], (status: AgentStatus.blocked, since: StatusTime.exact(began)));
      expect(read.panes['w1:p1'], (status: AgentStatus.working, since: StatusTime.after(began)));
      expect(read.panes['w1:p2'], (status: AgentStatus.idle, since: null));
    });

    test('a restored time is the same moment as the saved one, in UTC or local, and hashes alike', () {
      final utc = DateTime.utc(2026, 3, 4, 5, 6, 7);
      final restored = StatusTime.fromJson(StatusTime.exact(utc).toJson())!;

      expect(restored.at.isUtc, isFalse, reason: 'restored as a local DateTime');
      expect(restored.at.millisecondsSinceEpoch, utc.millisecondsSinceEpoch);
      expect(restored, StatusTime.exact(utc));
      expect(restored.hashCode, StatusTime.exact(utc).hashCode);
      expect(restored, isNot(StatusTime.after(utc)), reason: 'exact and bound differ');
      expect(restored, isNot(StatusTime.exact(utc.add(const Duration(milliseconds: 1)))));
    });

    test('an epoch value reads the same moment wherever the phone is', () {
      // 2026-03-04 05:06:07 UTC, as milliseconds: no zone is involved.
      const ms = 1772600767000;
      final time = StatusTime.fromJson({'at': ms})!;

      expect(time.at.toUtc(), DateTime.utc(2026, 3, 4, 5, 6, 7));
      expect(StatusTime.fromJson(time.toJson()), time);
    });
  });
}

/// The prefs key `PrefsSnapshotCache` uses for [machineId], discovered by
/// writing through it so the test does not hard-code the layout.
Future<String> _keyFor(SharedPreferences prefs, String machineId) async {
  await PrefsSnapshotCache().write(machineId, _snapshot('probe'));
  return prefs.getKeys().single;
}
