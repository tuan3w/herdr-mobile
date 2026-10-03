import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
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

    expect(await cache.read('a'), _snapshot('1'));
    expect(await cache.read('b'), _snapshot('2', panes: 3));
    expect(await cache.read('c'), isNull);
  });

  test('a second instance (next app start) reads what the first wrote', () async {
    await PrefsSnapshotCache().write('a', _snapshot('1'));
    expect(await PrefsSnapshotCache().read('a'), _snapshot('1'));
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
      '{"workspaces": [{"no_id": true}]}',
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

    expect((await cache.read('a'))!.version, '1');
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
    expect((await cache.read('b'))!.version, '3');
  });
}

/// The prefs key `PrefsSnapshotCache` uses for [machineId], discovered by
/// writing through it so the test does not hard-code the layout.
Future<String> _keyFor(SharedPreferences prefs, String machineId) async {
  await PrefsSnapshotCache().write(machineId, _snapshot('probe'));
  return prefs.getKeys().single;
}
