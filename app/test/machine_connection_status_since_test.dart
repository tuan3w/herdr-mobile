import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/status_time.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import 'support/fake_transport.dart';
import 'support/memory_snapshot_cache.dart';

typedef _P = ({String id, String ws, String? agent, String status});

_P _pane(String id, String status) =>
    (id: id, ws: 'w1', agent: 'claude', status: status);

/// A connection on a clock the test moves by hand.
class _Rig {
  _Rig(this.async, List<_P> panes, {MemorySnapshotCache? cache})
      : t = FakeTransport(snapshotJson(panes: panes)) {
    c = MachineConnection(
      profile: const MachineProfile(id: 'm', label: 'box', host: 'h', username: 'u'),
      api: HerdrApi(t),
      cache: cache,
      backoff: (_) => const Duration(hours: 1),
      pollInterval: const Duration(hours: 1),
      clock: () => now,
    );
    c.start();
    async.flushMicrotasks();
  }

  final FakeAsync async;
  final FakeTransport t;
  late final MachineConnection c;
  DateTime now = DateTime.utc(2026, 1, 1, 12);

  void advance(Duration d) {
    now = now.add(d);
    async.elapse(d);
  }

  /// The server now shows [panes]; the app fetches it.
  void server(List<_P> panes) {
    t.snapshot = snapshotJson(panes: panes);
    c.refresh();
    async.flushMicrotasks();
  }
}

void _rig(String name, List<_P> panes, void Function(_Rig r) body) =>
    test(name, () => fakeAsync((async) {
          final r = _Rig(async, panes);
          body(r);
          r.c.dispose();
          async.flushMicrotasks();
        }));

void main() {
  group('statusSince', () {
    _rig('panes already there at first sight have no known start', [
      _pane('w1:p1', 'working'),
    ], (r) {
      expect(r.c.statusSince('w1:p1'), isNull);
      expect(r.c.timeInStatus('w1:p1'), isNull);
    });

    _rig('an unknown pane has none either', [_pane('w1:p1', 'idle')], (r) {
      expect(r.c.statusSince('nope'), isNull);
      expect(r.c.timeInStatus('nope'), isNull);
    });

    _rig('a status change is stamped with when we saw it', [
      _pane('w1:p1', 'working'),
    ], (r) {
      r.advance(const Duration(minutes: 5));
      r.server([_pane('w1:p1', 'blocked')]);
      final seen = r.now;
      expect(r.c.statusSince('w1:p1'), seen);

      r.advance(const Duration(minutes: 3));
      expect(r.c.timeInStatus('w1:p1'), const Duration(minutes: 3));
    });

    _rig('unchanged snapshots keep the original stamp', [
      _pane('w1:p1', 'working'),
    ], (r) {
      r.server([_pane('w1:p1', 'blocked')]);
      final seen = r.c.statusSince('w1:p1');
      expect(seen, isNotNull);
      for (var i = 0; i < 5; i++) {
        r.advance(const Duration(minutes: 1));
        r.server([_pane('w1:p1', 'blocked')]);
      }
      expect(r.c.statusSince('w1:p1'), seen);
    });

    _rig('every flip resets the clock, including flipping back', [
      _pane('w1:p1', 'working'),
    ], (r) {
      r.advance(const Duration(minutes: 1));
      r.server([_pane('w1:p1', 'blocked')]);
      final first = r.c.statusSince('w1:p1');
      r.advance(const Duration(minutes: 2));
      r.server([_pane('w1:p1', 'working')]);
      final second = r.c.statusSince('w1:p1');
      expect(second!.isAfter(first!), isTrue);
      expect(r.c.timeInStatus('w1:p1'), Duration.zero);
    });

    _rig('a pane that appears later starts now; its neighbour is unaffected', [
      _pane('w1:p1', 'working'),
    ], (r) {
      r.advance(const Duration(minutes: 10));
      r.server([_pane('w1:p1', 'working'), _pane('w1:p2', 'working')]);
      expect(r.c.statusSince('w1:p2'), r.now);
      expect(r.c.statusSince('w1:p1'), isNull, reason: 'still unknown, not reset');
    });

    _rig('a closed pane is forgotten and starts fresh if it returns', [
      _pane('w1:p1', 'working'),
      _pane('w1:p2', 'working'),
    ], (r) {
      r.server([_pane('w1:p1', 'working'), _pane('w1:p2', 'blocked')]);
      expect(r.c.statusSince('w1:p2'), isNotNull);

      r.server([_pane('w1:p1', 'working')]);
      expect(r.c.statusSince('w1:p2'), isNull);

      r.advance(const Duration(minutes: 4));
      r.server([_pane('w1:p1', 'working'), _pane('w1:p2', 'blocked')]);
      expect(r.c.statusSince('w1:p2'), r.now);
    });

    _rig('a change that happened while disconnected is a bound, not "just now"', [
      _pane('w1:p1', 'working'),
    ], (r) {
      final lastSeen = r.now;
      r.c.goOffline();
      r.t.snapshot = snapshotJson(panes: [_pane('w1:p1', 'blocked')]);
      r.advance(const Duration(minutes: 30));
      r.c.reconnect();
      r.async.flushMicrotasks();
      expect(r.c.isLive, isTrue);
      expect(r.c.statusTime('w1:p1'), StatusTime.after(lastSeen));
      expect(r.c.timeInStatus('w1:p1'), const Duration(minutes: 30));
    });

    test('a snapshot restored from the cache does not count as first sight', () {
      fakeAsync((async) {
        final cache = MemorySnapshotCache({
          'm': Snapshot.fromJson(snapshotJson(panes: [_pane('w1:p1', 'blocked')])),
        });
        final r = _Rig(async, [_pane('w1:p1', 'blocked')], cache: cache);
        // The live snapshot equals the cached one, yet tracking began.
        expect(r.c.statusSince('w1:p1'), isNull, reason: 'first live sight');
        r.advance(const Duration(minutes: 2));
        r.server([_pane('w1:p1', 'working')]);
        expect(r.c.statusSince('w1:p1'), r.now);
        r.c.dispose();
        async.flushMicrotasks();
      });
    });
  });
}
