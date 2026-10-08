// What "needs you" means on this phone, without widgets: the reviewed state,
// the one status every screen reads, honest wait times, density, and the order
// inside a board section.
import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/status_time.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/attention_set.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/repositories/reviewed_state.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/snapshot_cache.dart';
import 'package:herdr_mobile/ui/features/agents/agents_grouping.dart';
import 'package:herdr_mobile/ui/features/agents/quick_reply_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_network.dart';
import 'support/fake_transport.dart';
import 'support/memory_app_settings_store.dart';
import 'support/memory_reviewed_store.dart';
import 'support/memory_snapshot_cache.dart';
import 'support/memory_stores.dart';
import 'support/test_transport.dart';

typedef _P = ({String id, String ws, String? agent, String status});

/// The panes of [ids] as the board orders its Working section.
List<String> _workingOrder(MachineConnection c, List<String> ids) => [
      for (final r in groupByStatus([
        for (final id in ids)
          agentRow(FleetAgent(machine: c, pane: c.paneById(id)!, workspace: null), showMachine: false),
      ])[AgentStatus.working]!)
        r.paneId,
    ];

_P _pane(String id, String status) => (id: id, ws: 'w1', agent: 'claude', status: status);

final _t0 = DateTime.utc(2026, 1, 1, 12);
const _min = Duration(minutes: 1);

/// One connection on a clock the test moves by hand.
class _Rig {
  _Rig(
    this.async,
    List<_P> panes, {
    this.cache,
    ReviewedState? reviewed,
    DateTime? start,
    Duration poll = const Duration(hours: 1),
    Map<String, int> seq = const {},
    FakeTransport? transport,
  })  : now = start ?? _t0,
        reviewed = reviewed ?? ReviewedState(),
        t = transport ?? FakeTransport(snapshotJson(panes: panes, completionSeq: seq)) {
    c = MachineConnection(
      profile: const MachineProfile(id: 'm', label: 'box', host: 'h', username: 'u'),
      api: HerdrApi(t),
      cache: cache,
      backoff: (_) => const Duration(hours: 1),
      pollInterval: poll,
      clock: () => now,
    )..attachReviewed(this.reviewed);
    c.start();
    async.flushMicrotasks();
  }

  final FakeAsync async;
  final FakeTransport t;
  final SnapshotCache? cache;
  final ReviewedState reviewed;
  late final MachineConnection c;
  DateTime now;

  /// Moves the clock and the fake timers together in 100 ms steps, so a timer
  /// (a poll, the refresh 150 ms after it) fires when the clock reads its time.
  void advance(Duration d) {
    const step = Duration(milliseconds: 100);
    var left = d;
    while (left > Duration.zero) {
      final s = left < step ? left : step;
      now = now.add(s);
      async.elapse(s);
      left -= s;
    }
  }

  /// [n] minutes in 20 second steps, then half a second more so the refresh
  /// of the poll that fell on the last step has run.
  void minutes(int n) {
    for (var i = 0; i < n * 3; i++) {
      advance(const Duration(seconds: 20));
    }
    advance(const Duration(milliseconds: 500));
  }

  /// The server now shows [panes]; the app fetches it.
  void server(List<_P> panes, {Map<String, int> seq = const {}}) {
    t.snapshot = snapshotJson(panes: panes, completionSeq: seq);
    c.refresh();
    async.flushMicrotasks();
  }

  /// Every workspace and tab roll-up says [status], as herdr's would.
  void rollup(String status) {
    for (final key in const ['workspaces', 'tabs']) {
      for (final item in t.snapshot[key] as List) {
        (item as Map<String, dynamic>)['agent_status'] = status;
      }
    }
    c.refresh();
    async.flushMicrotasks();
  }

  /// A `pane_updated` event identical to what the snapshot says of [id].
  Map<String, dynamic> event(String id) => {
        'event': 'pane_updated',
        'data': {
          'type': 'pane_updated',
          'pane': Map<String, dynamic>.of(
            (t.snapshot['panes'] as List)
                .cast<Map<String, dynamic>>()
                .firstWhere((p) => p['pane_id'] == id),
          ),
        },
      };

  AgentStatus status(String id) => c.paneById(id)!.status;
}

void _rig(
  String name,
  List<_P> panes,
  void Function(_Rig r) body, {
  Duration poll = const Duration(hours: 1),
  Map<String, int> seq = const {},
}) =>
    test(name, () {
      fakeAsync((async) {
        final r = _Rig(async, panes, poll: poll, seq: seq);
        body(r);
        r.c.dispose();
        async.flushMicrotasks();
      });
    });

/// Previews never read: these tests send typed text and keys, which go
/// without re-reading the pane.
class _NoReads extends Fake implements PanePreviews {}

/// Needs you plus to review, as every surface counts them now.
int _wanted(FleetRepository fleet) {
  final set = AttentionSet(fleet: fleet);
  final n = set.needsYou.length + set.toReview.length;
  set.dispose();
  return n;
}

void main() {
  group('reviewed state', () {
    test('a review survives a restart and names one finished state', () async {
      final store = MemoryReviewedStore();
      final state = ReviewedState(store);
      await state.load();

      expect(state.review('m', 'w1:p1', 'seq:3'), isTrue);
      expect(state.review('m', 'w1:p1', 'seq:3'), isFalse, reason: 'nothing new');
      expect(state.isReviewed('m', 'w1:p1', 'seq:3'), isTrue);
      expect(state.isReviewed('m', 'w1:p1', 'seq:4'), isFalse, reason: 'the next completion asks again');
      expect(state.isReviewed('other', 'w1:p1', 'seq:3'), isFalse, reason: 'ids are per machine');
      await pumpEventQueue();

      final reopened = ReviewedState(store);
      await reopened.load();
      expect(reopened.isReviewed('m', 'w1:p1', 'seq:3'), isTrue);
      expect(reopened.length, 1);
    });

    test('one key per pane: a newer review replaces the older, storage does not grow', () async {
      final store = MemoryReviewedStore();
      final state = ReviewedState(store);
      await state.load();

      for (var seq = 1; seq <= 50; seq++) {
        state.review('m', 'w1:p1', 'seq:$seq');
      }
      await pumpEventQueue();

      expect(state.length, 1);
      expect(store.saved, {
        'm': {'w1:p1': 'seq:50'},
      });
    });

    test('pruning drops panes herdr no longer has and keeps the rest, quietly', () async {
      final store = MemoryReviewedStore();
      final state = ReviewedState(store);
      await state.load();
      state
        ..review('m', 'w1:p1', 'seq:1')
        ..review('m', 'w1:p2', 'seq:1')
        ..review('n', 'w1:p1', 'seq:1');
      await pumpEventQueue();
      var notified = 0;
      state.addListener(() => notified++);
      final writes = store.writes;

      state.prune('m', {'w1:p2'});
      await pumpEventQueue();

      expect(state.isReviewed('m', 'w1:p1', 'seq:1'), isFalse);
      expect(state.isReviewed('m', 'w1:p2', 'seq:1'), isTrue);
      expect(state.isReviewed('n', 'w1:p1', 'seq:1'), isTrue, reason: 'another machine is not touched');
      expect(state.length, 2);
      expect(notified, 0, reason: 'nothing that is shown changed');
      expect(store.writes, writes + 1);

      state.prune('m', {'w1:p2'});
      state.prune('unknown', const {});
      await pumpEventQueue();
      expect(store.writes, writes + 1, reason: 'nothing to forget, nothing written');

      state.prune('m', const {});
      await pumpEventQueue();
      expect(store.saved, {
        'n': {'w1:p1': 'seq:1'},
      }, reason: 'a machine with nothing left is dropped');
    });

    test('forgetting a machine drops all of its reviews', () async {
      final store = MemoryReviewedStore();
      final state = ReviewedState(store);
      await state.load();
      state
        ..review('m', 'w1:p1', 'seq:1')
        ..review('n', 'w1:p1', 'seq:1');

      state.forgetMachine('m');
      await pumpEventQueue();

      expect(state.isReviewed('m', 'w1:p1', 'seq:1'), isFalse);
      expect(state.isReviewed('n', 'w1:p1', 'seq:1'), isTrue);
      expect(store.saved, {
        'n': {'w1:p1': 'seq:1'},
      });
    });

    test('a store that cannot be read or written does not stop reviewing', () async {
      final state = ReviewedState(_BrokenReviewedStore());
      await state.load();
      expect(state.review('m', 'w1:p1', 'seq:1'), isTrue);
      await pumpEventQueue();
      expect(state.isReviewed('m', 'w1:p1', 'seq:1'), isTrue, reason: 'kept for this launch');

      final disk = MemoryReviewedStore()..failing = true;
      final onDisk = ReviewedState(disk);
      await onDisk.load();
      onDisk.review('m', 'w1:p1', 'seq:1');
      await pumpEventQueue();
      expect(onDisk.isReviewed('m', 'w1:p1', 'seq:1'), isTrue);
    });

    test('reviews are not written before the saved ones were read', () async {
      final store = MemoryReviewedStore()
        ..saved = {
          'm': {'w1:p1': 'seq:1'},
        };
      final state = ReviewedState(store);

      state.review('n', 'w1:p9', 'seq:1');
      await pumpEventQueue();
      expect(store.writes, 0, reason: 'would overwrite what load has yet to read');

      await state.load();
      expect(state.isReviewed('m', 'w1:p1', 'seq:1'), isTrue);
      expect(state.isReviewed('n', 'w1:p9', 'seq:1'), isTrue);
    });

    test('preferences hold it as JSON; foreign or corrupt data reads as nothing', () async {
      SharedPreferences.resetStatic();
      SharedPreferences.setMockInitialValues({});
      final store = PrefsReviewedStore();
      expect(await store.read(), isNull);

      await store.write({
        'm': {'w1:p1': 'seq:3'},
      });
      expect(await PrefsReviewedStore().read(), {
        'm': {'w1:p1': 'seq:3'},
      });

      for (final garbage in const ['not json {', '[1,2]', '"text"']) {
        SharedPreferences.resetStatic();
        SharedPreferences.setMockInitialValues({'reviewed.v1': garbage});
        expect(await PrefsReviewedStore().read(), isNull, reason: garbage);
      }
      SharedPreferences.resetStatic();
      SharedPreferences.setMockInitialValues({
        'reviewed.v1': '{"m": {"w1:p1": "seq:1", "w1:p2": 7}, "n": "x"}',
      });
      expect(await PrefsReviewedStore().read(), {
        'm': {'w1:p1': 'seq:1'},
      }, reason: 'only well-formed entries survive');
    });
  });

  group('one effective status', () {
    _rig('a reviewed done shows as idle in panes and roll-ups, and herdr is told nothing', [
      _pane('w1:p1', 'done'),
      _pane('w1:p2', 'working'),
    ], (r) {
      r.rollup('done');
      expect(r.c.snapshot.workspaces.single.status, AgentStatus.done);

      expect(r.c.markReviewed('w1:p1'), isTrue);

      expect(r.status('w1:p1'), AgentStatus.idle);
      expect(r.status('w1:p2'), AgentStatus.working);
      expect(r.c.snapshot.agentPanes.map((p) => p.status), [AgentStatus.idle, AgentStatus.working]);
      expect(r.c.snapshot.workspaces.single.status, AgentStatus.working,
          reason: 'the roll-up is worked out again from what its panes show');
      expect(r.c.snapshot.tabs.single.status, AgentStatus.working);
      expect(r.t.calls.map((c) => c.$1).toSet(), {'session.snapshot'},
          reason: 'only reads: never a focus, which would move the desktop view');
    });

    _rig('unmarkReviewed takes back the review of the same finished state only', [
      _pane('w1:p1', 'done'),
      _pane('w1:p2', 'done'),
    ], seq: {'w1:p1': 3}, (r) {
      r.rollup('done');
      expect(r.c.unmarkReviewed('w1:p1'), isFalse, reason: 'nothing was reviewed');
      expect(r.c.unmarkReviewed('nope'), isFalse);

      r.c.markReviewed('w1:p1');
      r.c.markReviewed('w1:p2');
      expect(r.status('w1:p1'), AgentStatus.idle);

      expect(r.c.unmarkReviewed('w1:p1'), isTrue);
      expect(r.status('w1:p1'), AgentStatus.done, reason: 'shown as finished again, at once');
      expect(r.status('w1:p2'), AgentStatus.idle, reason: 'the other review stays');
      expect(r.reviewed.length, 1);
      expect(r.c.unmarkReviewed('w1:p1'), isFalse, reason: 'already taken back');

      // It finished anew since (another completion): the old review is not
      // the one on show, so an undo takes nothing back.
      r.c.markReviewed('w1:p1');
      r.server([_pane('w1:p1', 'done'), _pane('w1:p2', 'done')], seq: {'w1:p1': 4});
      expect(r.status('w1:p1'), AgentStatus.done);
      expect(r.c.unmarkReviewed('w1:p1'), isFalse);
    });

    _rig('a roll-up stays done while another finished agent is unreviewed', [
      _pane('w1:p1', 'done'),
      _pane('w1:p2', 'done'),
    ], (r) {
      r.rollup('done');
      r.c.markReviewed('w1:p1');
      expect(r.c.snapshot.workspaces.single.status, AgentStatus.done);

      r.c.markReviewed('w1:p2');
      expect(r.c.snapshot.workspaces.single.status, AgentStatus.idle);
    });

    _rig('only done can be reviewed, and only a pane that exists', [
      _pane('w1:p1', 'blocked'),
      _pane('w1:p2', 'working'),
      _pane('w1:p3', 'done'),
    ], (r) {
      expect(r.c.markReviewed('w1:p1'), isFalse);
      expect(r.c.markReviewed('w1:p2'), isFalse);
      expect(r.c.markReviewed('nope'), isFalse);
      expect(r.reviewed.length, 0);
      expect(r.status('w1:p1'), AgentStatus.blocked);

      // A review of a blocked pane must not linger and hide its next Done.
      r.server([_pane('w1:p1', 'done'), _pane('w1:p2', 'working'), _pane('w1:p3', 'done')]);
      expect(r.status('w1:p1'), AgentStatus.done);
    });

    _rig('the next completion asks again (herdr completion_seq)', [
      _pane('w1:p1', 'done'),
    ], seq: {'w1:p1': 5}, (r) {
      expect(r.c.paneById('w1:p1')!.completionSeq, 5, reason: 'from the snapshot agents list');
      r.c.markReviewed('w1:p1');
      expect(r.status('w1:p1'), AgentStatus.idle);

      r.server([_pane('w1:p1', 'done')], seq: {'w1:p1': 5});
      expect(r.status('w1:p1'), AgentStatus.idle, reason: 'same completion: still reviewed');

      r.server([_pane('w1:p1', 'working')]);
      r.server([_pane('w1:p1', 'done')], seq: {'w1:p1': 6});
      expect(r.status('w1:p1'), AgentStatus.done, reason: 'a new completion');
    });

    _rig('without completion_seq the observed start of Done is the key', [
      _pane('w1:p1', 'working'),
    ], (r) {
      r.advance(_min);
      r.server([_pane('w1:p1', 'done')]);
      expect(r.c.paneById('w1:p1')!.completionSeq, isNull);
      r.c.markReviewed('w1:p1');
      r.advance(_min);
      r.server([_pane('w1:p1', 'done')]);
      expect(r.status('w1:p1'), AgentStatus.idle);

      r.advance(_min);
      r.server([_pane('w1:p1', 'working')]);
      r.advance(_min);
      r.server([_pane('w1:p1', 'done')]);
      expect(r.status('w1:p1'), AgentStatus.done, reason: 'finished again, later');
    });

    _rig('a pane already done at first sight is keyed by a per-pane marker', [
      _pane('w1:p1', 'done'),
    ], (r) {
      expect(r.c.statusTime('w1:p1'), isNull);
      r.c.markReviewed('w1:p1');
      expect(r.status('w1:p1'), AgentStatus.idle);

      r.advance(_min);
      r.server([_pane('w1:p1', 'working')]);
      r.advance(_min);
      r.server([_pane('w1:p1', 'done')]);
      expect(r.status('w1:p1'), AgentStatus.done, reason: 'the finish was seen, so it has its own key');
    });

    _rig('events about a reviewed done pane do not cause refetches', [
      _pane('w1:p1', 'done'),
    ], seq: {'w1:p1': 2}, (r) {
      r.c.markReviewed('w1:p1');
      final before = r.t.snapshotCalls;

      for (var i = 0; i < 30; i++) {
        r.t.emit(r.event('w1:p1'));
      }
      r.async.elapse(const Duration(seconds: 10));

      expect(r.t.snapshotCalls, before,
          reason: 'compared with what herdr said (done, seq 2), not with the idle shown');
    });

    _rig('a pane herdr no longer has loses its review; the others keep theirs', [
      _pane('w1:p1', 'done'),
      _pane('w1:p2', 'done'),
    ], (r) {
      r.c.markReviewed('w1:p1');
      r.c.markReviewed('w1:p2');
      expect(r.reviewed.length, 2);

      r.server([_pane('w1:p2', 'done')]);
      expect(r.reviewed.length, 1);
      expect(r.status('w1:p2'), AgentStatus.idle);
    });

    test('an offline machine showing its cache does not prune what it cannot see', () {
      fakeAsync((async) {
        final reviewed = ReviewedState()..review('m', 'w1:p9', 'pane');
        final cache = MemorySnapshotCache({
          'm': Snapshot.fromJson(snapshotJson(panes: [_pane('w1:p1', 'done')])),
        });
        final c = MachineConnection(
          profile: const MachineProfile(id: 'm', label: 'box', host: 'h', username: 'u'),
          api: HerdrApi(FakeTransport()),
          cache: cache,
        )
          ..attachReviewed(reviewed)
          ..goOffline();
        async.flushMicrotasks();

        expect(c.snapshot.agentPanes, hasLength(1), reason: 'the cache is shown');
        expect(reviewed.isReviewed('m', 'w1:p9', 'pane'), isTrue);
        c.dispose();
      });
    });

    _rig('herdr restarting its sequence cannot revive a review', [
      _pane('w1:p1', 'done'),
    ], seq: {'w1:p1': 5}, (r) {
      r.c.markReviewed('w1:p1');
      expect(r.status('w1:p1'), AgentStatus.idle);

      // herdr restarts: the pane is idle again and finishes later, and its
      // counter has started over, so this completion is numbered 5 too.
      r.server([_pane('w1:p1', 'idle')]);
      expect(r.reviewed.length, 0, reason: 'a live snapshot saw it leave done');
      r.server([_pane('w1:p1', 'done')], seq: {'w1:p1': 5});
      expect(r.status('w1:p1'), AgentStatus.done, reason: 'a different completion with the same number');
    });

    _rig('without a sequence, a pane that finishes again is a new finish, with a key of its own', [
      _pane('w1:p1', 'done'),
    ], (r) {
      r.c.markReviewed('w1:p1');
      expect(r.reviewed.isReviewed('m', 'w1:p1', 'pane'), isTrue, reason: 'done at first sight: no start known');

      r.advance(_min);
      r.server([_pane('w1:p1', 'working')]);
      expect(r.reviewed.length, 0);
      r.advance(_min);
      r.server([_pane('w1:p1', 'done')]);
      expect(r.status('w1:p1'), AgentStatus.done);

      r.c.markReviewed('w1:p1');
      expect(r.status('w1:p1'), AgentStatus.idle);
      expect(r.reviewed.isReviewed('m', 'w1:p1', 'pane'), isFalse,
          reason: 'the second finish was seen to begin, so it is keyed by that');
    });

    _rig('a live snapshot drops the mark of a pane that is gone, with no event telling it so', [
      _pane('w1:p1', 'done'),
      _pane('w1:p2', 'done'),
    ], (r) {
      r.c.markReviewed('w1:p1');
      r.c.markReviewed('w1:p2');
      r.server([_pane('w1:p1', 'done')]);

      expect(r.reviewed.length, 1);
      expect(r.status('w1:p1'), AgentStatus.idle);
    });

    test('a cached snapshot never ends a review; the first live one does, and prunes too', () {
      fakeAsync((async) {
        final reviewed = ReviewedState()
          ..review('m', 'w1:p1', 'seq:3')
          ..review('m', 'w1:p9', 'seq:3');
        final cache = MemorySnapshotCache({
          'm': Snapshot.fromJson(snapshotJson(panes: [_pane('w1:p1', 'working')])),
        });
        final held = TestTransport(snapshotJson(panes: [_pane('w1:p1', 'working')]))
          ..gate = Completer<void>();
        final r = _Rig(async, const [], cache: cache, reviewed: reviewed, transport: held);

        expect(r.c.snapshot.agentPanes, hasLength(1), reason: 'the cache is shown');
        expect(reviewed.length, 2, reason: 'a seed proves nothing');

        held.gate!.complete();
        async.flushMicrotasks();
        expect(r.c.isLive, isTrue);
        expect(reviewed.length, 0, reason: 'p1 was seen working, p9 does not exist');
        r.c.dispose();
        async.flushMicrotasks();
      });
    });

    test('removing a machine forgets its reviews', () {
      fakeAsync((async) {
        final r = _Rig(async, [_pane('w1:p1', 'done')]);
        r.c.markReviewed('w1:p1');
        expect(r.reviewed.length, 1);

        r.c.forget();
        expect(r.reviewed.length, 0);
        r.c.dispose();
      });
    });

    test('a restart shows a reviewed agent as idle from the first frame (cache)', () {
      fakeAsync((async) {
        final reviewed = ReviewedState();
        final cache = MemorySnapshotCache();
        final first = _Rig(async, [_pane('w1:p1', 'done')],
            cache: cache, reviewed: reviewed, seq: {'w1:p1': 8});
        first.c.markReviewed('w1:p1');
        first.c.dispose();
        async.flushMicrotasks();

        // The same state on disk, a new process, the network still pending.
        final held = TestTransport(snapshotJson(panes: [_pane('w1:p1', 'done')], completionSeq: {'w1:p1': 8}))
          ..gate = Completer<void>();
        final second = _Rig(async, const [],
            cache: cache, reviewed: reviewed, transport: held);

        expect(second.c.isLive, isFalse);
        expect(second.status('w1:p1'), AgentStatus.idle, reason: 'the cached pane, already reviewed');
        held.gate!.complete();
        async.flushMicrotasks();
        expect(second.status('w1:p1'), AgentStatus.idle);
        second.c.dispose();
      });
    });

    test('answering a finished agent reviews it; moving through a menu does not', () {
      fakeAsync((async) {
        final r = _Rig(async, [_pane('w1:p1', 'done')]);
        final reply = QuickReplyController(machine: r.c, paneId: 'w1:p1', previews: _NoReads(), haptic: false);

        unawaited(reply.sendKey('down'));
        async.flushMicrotasks();
        expect(r.status('w1:p1'), AgentStatus.done, reason: 'a key press is not an answer');

        unawaited(reply.sendLine('carry on'));
        async.flushMicrotasks();
        expect(r.status('w1:p1'), AgentStatus.idle);
        reply.dispose();
        r.c.dispose();
      });
    });

    test('a failed send does not count as answering', () {
      fakeAsync((async) {
        final r = _Rig(async, [_pane('w1:p1', 'done')]);
        final reply = QuickReplyController(machine: r.c, paneId: 'w1:p1', previews: _NoReads(), haptic: false);
        r.t.failure = const HerdrTransportException('unreachable');

        unawaited(reply.sendLine('carry on'));
        async.flushMicrotasks();
        expect(r.status('w1:p1'), AgentStatus.done);
        r.t.failure = null;
        reply.dispose();
        r.c.dispose();
      });
    });
  });

  group('the fleet and the agent screen in front', () {
    late _Fleet f;
    setUp(() => f = _Fleet());
    tearDown(() => f.dispose());

    test('what wants a look is reachable blocked plus unreviewed done; offline counts as neither', () async {
      await f.add('a', [
        _pane('w1:p1', 'blocked'),
        _pane('w1:p2', 'done'),
        _pane('w1:p3', 'done'),
        _pane('w1:p4', 'working'),
        _pane('w1:p5', 'idle'),
      ]);
      final set = AttentionSet(fleet: f.fleet);
      expect(set.needsYou.map((i) => i.key), ['a/w1:p1']);
      expect(set.toReview, hasLength(2));

      f.fleet.markReviewed('a', 'w1:p2');
      expect(set.toReview.map((i) => i.key), ['a/w1:p3']);

      f.network.goOffline();
      await pumpEventQueue(times: 20);
      expect(set.needsYou, isEmpty, reason: 'an offline machine\'s "needs you" cannot be answered from here');
      expect(set.toReview, isEmpty, reason: 'nor can its finished agent be marked reviewed');
      expect(set.offlineNeedsYou.map((i) => i.key), ['a/w1:p1']);
      expect(set.offlineToReview.map((i) => i.key), ['a/w1:p3']);
      set.dispose();
    });

    test('markReviewed on an unknown machine is harmless', () async {
      f.fleet.markReviewed('nope', 'w1:p1');
      expect(_wanted(f.fleet), 0);
    });

    test('opening a pane\'s terminal reviews the agent, and nothing is sent to herdr', () async {
      await f.add('a', [_pane('w1:p1', 'done'), _pane('w1:p2', 'done')]);

      f.screens.shown(Object(), const PaneAgent('a', 'w1:p1'), AgentView.terminal);
      await pumpEventQueue();

      expect(f.fleet.connection('a')!.paneById('w1:p1')!.status, AgentStatus.idle);
      expect(f.fleet.connection('a')!.paneById('w1:p2')!.status, AgentStatus.done);
      expect(f.transports['a']!.calls.map((c) => c.$1).toSet(), {'session.snapshot'});
    });

    test('going to another agent\'s terminal reviews the agent you land on', () async {
      await f.add('a', [_pane('w1:p1', 'done'), _pane('w1:p2', 'working')]);
      final c = f.fleet.connection('a')!;
      final first = Object();
      f.screens.shown(first, const PaneAgent('a', 'w1:p1'), AgentView.terminal);
      await pumpEventQueue();

      f.transports['a']!.snapshot = snapshotJson(panes: [_pane('w1:p1', 'done'), _pane('w1:p2', 'done')]);
      await c.refresh();
      expect(c.paneById('w1:p2')!.status, AgentStatus.done, reason: 'p1 is in front, not p2');

      // A swipe: the next screen comes in, the one it replaces goes.
      f.screens
        ..shown(Object(), const PaneAgent('a', 'w1:p2'), AgentView.terminal)
        ..left(first, leaving: true);
      await pumpEventQueue();
      expect(c.paneById('w1:p2')!.status, AgentStatus.idle);
    });

    test('an agent that finishes while its terminal is in front is reviewed; another is not', () async {
      await f.add('a', [_pane('w1:p1', 'working'), _pane('w1:p2', 'working')]);
      f.screens.shown(Object(), const PaneAgent('a', 'w1:p1'), AgentView.terminal);
      await pumpEventQueue();

      f.transports['a']!.snapshot = snapshotJson(panes: [_pane('w1:p1', 'done'), _pane('w1:p2', 'done')]);
      await f.fleet.connection('a')!.refresh();

      final c = f.fleet.connection('a')!;
      expect(c.paneById('w1:p1')!.status, AgentStatus.idle, reason: 'in front: being read');
      expect(c.paneById('w1:p2')!.status, AgentStatus.done, reason: 'nobody is looking at it');
      expect(_wanted(f.fleet), 1);
    });

    test('back on the board, a finish is not read', () async {
      await f.add('a', [_pane('w1:p1', 'working')]);
      final screen = Object();
      f.screens
        ..shown(screen, const PaneAgent('a', 'w1:p1'), AgentView.terminal)
        ..left(screen, leaving: true);
      await pumpEventQueue();

      f.transports['a']!.snapshot = snapshotJson(panes: [_pane('w1:p1', 'done')]);
      await f.fleet.connection('a')!.refresh();

      expect(f.fleet.connection('a')!.paneById('w1:p1')!.status, AgentStatus.done);
    });

    test('a pane in front in its chat is not marked by the fleet (the chat marks what it has shown)', () async {
      await f.add('a', [_pane('w1:p1', 'done'), _pane('w1:p2', 'working')]);
      f.screens.shown(Object(), const PaneAgent('a', 'w1:p1'), AgentView.chat);
      await pumpEventQueue();
      expect(f.fleet.connection('a')!.paneById('w1:p1')!.status, AgentStatus.done);

      f.screens.shown(Object(), const PaneAgent('a', 'w1:p2'), AgentView.chat);
      await pumpEventQueue();
      f.transports['a']!.snapshot = snapshotJson(panes: [_pane('w1:p1', 'done'), _pane('w1:p2', 'done')]);
      await f.fleet.connection('a')!.refresh();
      expect(f.fleet.connection('a')!.paneById('w1:p2')!.status, AgentStatus.done, reason: 'finished under its chat');
      expect(_wanted(f.fleet), 2);
    });

    test('nothing is reviewed while the app is in the background', () async {
      await f.add('a', [_pane('w1:p1', 'done')]);
      f.fleet.onLifecycleState(AppLifecycleState.paused);

      f.screens.shown(Object(), const PaneAgent('a', 'w1:p1'), AgentView.terminal);
      await pumpEventQueue();
      expect(f.fleet.connection('a')!.paneById('w1:p1')!.status, AgentStatus.done,
          reason: 'the phone is in a pocket');

      f.fleet.onLifecycleState(AppLifecycleState.resumed);
      f.transports['a']!.snapshot = snapshotJson(panes: [_pane('w1:p1', 'done'), _pane('w1:p2', 'working')]);
      await f.fleet.connection('a')!.refresh();
      expect(f.fleet.connection('a')!.paneById('w1:p1')!.status, AgentStatus.idle,
          reason: 'back in front, the next change on the machine reads it');
    });

    test('a reviewed state with a store comes back with the fleet', () async {
      final store = MemoryReviewedStore();
      final state = ReviewedState(store);
      await state.load();
      final first = _Fleet(reviewed: state);
      await first.add('a', [_pane('w1:p1', 'done')], seq: {'w1:p1': 4});
      first.fleet.markReviewed('a', 'w1:p1');
      await pumpEventQueue();
      first.dispose();

      final next = ReviewedState(store);
      await next.load();
      final second = _Fleet(reviewed: next);
      await second.add('a', [_pane('w1:p1', 'done')], seq: {'w1:p1': 4});
      addTearDown(second.dispose);

      expect(_wanted(second.fleet), 0);
      expect(second.fleet.connection('a')!.paneById('w1:p1')!.status, AgentStatus.idle);
    });
  });

  group('honest wait time', () {
    _rig('a change found after a 30-minute gap reads ≤ 30m, never <1m', [
      _pane('w1:p1', 'working'),
    ], (r) {
      final lastSeen = r.now;
      r.c.goOffline();
      r.t.snapshot = snapshotJson(panes: [_pane('w1:p1', 'blocked')]);
      r.advance(const Duration(minutes: 30));
      r.c.reconnect();
      r.async.flushMicrotasks();

      final time = r.c.statusTime('w1:p1')!;
      expect(time, StatusTime.after(lastSeen));
      expect(time.exact, isFalse);
      expect(timeInState(AgentStatus.blocked, time.since(r.now), exact: time.exact),
          'needs you ≤ 30m');
    });

    _rig('suspended in the background for 25 minutes is a gap too', [
      _pane('w1:p1', 'working'),
    ], (r) {
      r.c.suspend();
      r.t.snapshot = snapshotJson(panes: [_pane('w1:p1', 'blocked')]);
      r.advance(const Duration(minutes: 25));
      r.c.reconnect();
      r.async.flushMicrotasks();

      final time = r.c.statusTime('w1:p1')!;
      expect(timeInState(AgentStatus.blocked, time.since(r.now), exact: time.exact),
          'needs you ≤ 25m');
    });

    _rig('a short blip is dated as it happened: under the observation gap the error is invisible', [
      _pane('w1:p1', 'working'),
    ], (r) {
      r.c.goOffline();
      r.t.snapshot = snapshotJson(panes: [_pane('w1:p1', 'blocked')]);
      r.advance(const Duration(seconds: 20));
      r.c.reconnect();
      r.async.flushMicrotasks();

      expect(r.c.statusTime('w1:p1'), StatusTime.exact(r.now));
    });

    _rig('a change seen on the live stream is exact, however long the quiet before it', [
      _pane('w1:p1', 'working'),
    ], (r) {
      r.advance(const Duration(minutes: 40));
      r.server([_pane('w1:p1', 'blocked')]);

      final time = r.c.statusTime('w1:p1')!;
      expect(time, StatusTime.exact(r.now));
      expect(timeInState(AgentStatus.blocked, time.since(r.now), exact: time.exact), 'needs you <1m');
      r.advance(const Duration(minutes: 12));
      expect(timeInState(AgentStatus.blocked, time.since(r.now)), 'needs you 12m');
    });

    _rig('panes already there at the very first sight have no known start', [
      _pane('w1:p1', 'blocked'),
    ], (r) {
      expect(r.c.statusTime('w1:p1'), isNull);
      expect(timeInState(AgentStatus.unknown, _min), '');
    });

    test('the label says what a bound is: at most that old, and never less than a minute', () {
      expect(timeInState(AgentStatus.blocked, const Duration(minutes: 25), exact: false), 'needs you ≤ 25m');
      expect(timeInState(AgentStatus.working, const Duration(minutes: 12)), 'working 12m');
      expect(timeInState(AgentStatus.done, const Duration(hours: 2), exact: false), 'done ≤ 2h');
      expect(timeInState(AgentStatus.blocked, const Duration(seconds: 5), exact: false), 'needs you ≤ 1m');
      expect(timeInState(AgentStatus.unknown, _min, exact: false), '');
    });

    test('an unchanged state keeps its time across a restart; changed ones are bounds', () {
      fakeAsync((async) {
        final cache = MemorySnapshotCache();
        final first = _Rig(async, [
          _pane('w1:p1', 'working'),
          _pane('w1:p2', 'working'),
          _pane('w1:p3', 'idle'),
        ], cache: cache);
        first.advance(const Duration(minutes: 2));
        first.server([
          _pane('w1:p1', 'blocked'),
          _pane('w1:p2', 'working'),
          _pane('w1:p3', 'idle'),
        ]);
        final blockedAt = first.now;
        expect(first.c.statusTime('w1:p1'), StatusTime.exact(blockedAt));
        first.c.dispose();
        async.flushMicrotasks();
        expect(cache.observed['m']!.seenAt, blockedAt);

        // 40 minutes later, a new process. While it was away p3 started
        // working and a new pane showed up.
        final held = TestTransport(snapshotJson(panes: [
          _pane('w1:p1', 'blocked'),
          _pane('w1:p2', 'working'),
          _pane('w1:p3', 'working'),
          _pane('w1:p4', 'blocked'),
        ]))
          ..gate = Completer<void>();
        final second = _Rig(async, const [],
            cache: cache, start: blockedAt.add(const Duration(minutes: 40)), transport: held);
        held.gate!.complete();
        async.flushMicrotasks();
        held.gate = null;

        expect(second.c.isLive, isTrue);
        expect(second.c.statusTime('w1:p1'), StatusTime.exact(blockedAt),
            reason: 'still blocked: the time carries over');
        expect(timeInState(AgentStatus.blocked, second.c.statusTime('w1:p1')!.since(second.now)),
            'needs you 40m');
        expect(second.c.statusTime('w1:p2'), isNull, reason: 'its start was never known, and is not made up');
        expect(second.c.statusTime('w1:p3'), StatusTime.after(blockedAt),
            reason: 'changed while the app was away');
        expect(second.c.statusTime('w1:p4'), StatusTime.after(blockedAt),
            reason: 'appeared while the app was away');
        second.c.dispose();
        async.flushMicrotasks();
      });
    });

    test('a cache written before times were kept still reads (no times, no crash)', () {
      fakeAsync((async) {
        final cache = MemorySnapshotCache({
          'm': Snapshot.fromJson(snapshotJson(panes: [_pane('w1:p1', 'blocked')])),
        });
        final held = TestTransport(snapshotJson(panes: [_pane('w1:p1', 'blocked')]))
          ..gate = Completer<void>();
        final r = _Rig(async, const [], cache: cache, transport: held);
        expect(r.c.snapshot.agentPanes, hasLength(1));
        held.gate!.complete();
        async.flushMicrotasks();

        expect(r.c.statusTime('w1:p1'), isNull);
        r.c.dispose();
      });
    });

    test('the record in preferences carries the times and stays readable without them', () async {
      SharedPreferences.resetStatic();
      SharedPreferences.setMockInitialValues({});
      final cache = PrefsSnapshotCache();
      final snapshot = Snapshot.fromJson(snapshotJson(panes: [
        _pane('w1:p1', 'blocked'),
        _pane('w1:p2', 'working'),
        _pane('w1:p3', 'idle'),
      ], completionSeq: {'w1:p1': 9}));
      final seen = DateTime.utc(2026, 3, 4, 5, 6, 7);
      await cache.write(
        'm',
        snapshot,
        observed: ObservedStatuses(seenAt: seen, panes: {
          'w1:p1': (status: AgentStatus.blocked, since: StatusTime.exact(seen)),
          'w1:p2': (status: AgentStatus.working, since: StatusTime.after(seen)),
          'w1:p3': (status: AgentStatus.idle, since: null),
        }),
      );

      final read = (await PrefsSnapshotCache().read('m'))!;
      expect(read.snapshot, snapshot);
      expect(read.snapshot.agentPanes.first.completionSeq, 9, reason: 'completion_seq round-trips');
      expect(read.observed!.seenAt.isAtSameMomentAs(seen), isTrue);
      expect(read.observed!.panes['w1:p1'], (status: AgentStatus.blocked, since: StatusTime.exact(seen)));
      expect(read.observed!.panes['w1:p2'], (status: AgentStatus.working, since: StatusTime.after(seen)));
      expect(read.observed!.panes['w1:p3'], (status: AgentStatus.idle, since: null));

      await cache.write('old', snapshot);
      expect((await cache.read('old'))!.observed, isNull, reason: 'as an older app wrote it');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'herdr.snapshot.v1.broken',
        '{"version":"1","workspaces":[],"tabs":[],"panes":[],"observed":{"seen":"nope","panes":3}}',
      );
      final broken = await PrefsSnapshotCache().read('broken');
      expect(broken, isNotNull, reason: 'bad times never cost the snapshot');
      expect(broken!.observed, isNull);
    });

    test('quiet polls rewrite the cache only every two minutes, to keep "last seen" honest', () {
      fakeAsync((async) {
        final cache = MemorySnapshotCache();
        final r = _Rig(async, [_pane('w1:p1', 'working')],
            cache: cache, poll: const Duration(seconds: 20));
        expect(cache.writes, hasLength(1));
        final first = cache.observed['m']!.seenAt;

        r.minutes(1);
        expect(cache.writes, hasLength(1), reason: 'nothing changed in the first minute');

        r.minutes(2);
        expect(cache.writes.length, greaterThan(1));
        expect(cache.observed['m']!.seenAt.isAfter(first), isTrue);
        expect(cache.writes.length, lessThanOrEqualTo(3), reason: 'not one write per 20 s poll');
        r.c.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('quiet', () {
    _rig('a working agent is quiet after five minutes without an event, in whole minutes', [
      _pane('w1:p1', 'working'),
      _pane('w1:p2', 'blocked'),
    ], poll: const Duration(seconds: 20), (r) {
      r.minutes(4);
      expect(r.c.quietMinutes('w1:p1'), 0, reason: 'under five minutes');

      r.minutes(1);
      expect(r.c.quietMinutes('w1:p1'), 5);
      r.minutes(2);
      expect(r.c.quietMinutes('w1:p1'), 7);
      expect(r.c.lastActivity('w1:p1'), _t0, reason: 'since the stream went live');
      expect(r.c.quietMinutes('w1:p2'), 0, reason: 'only a working agent can be quiet');
    });

    _rig('a burst of events moves nothing: no notification, the order waits for the next poll', [
      _pane('w1:p1', 'working'),
      _pane('w1:p2', 'working'),
    ], poll: const Duration(seconds: 20), (r) {
      // p1 is heard from every step; p2 never.
      for (var i = 0; i < 18; i++) {
        r.t.emit(r.event('w1:p1'));
        r.advance(const Duration(seconds: 20));
      }
      r.advance(const Duration(milliseconds: 500));
      List<String> order() => groupByStatus([
            for (final p in ['w1:p1', 'w1:p2'])
              agentRow(
                FleetAgent(machine: r.c, pane: r.c.paneById(p)!, workspace: null),
                showMachine: false,
              ),
          ])[AgentStatus.working]!
              .map((a) => a.paneId)
              .toList();

      expect(r.c.quietMinutes('w1:p2'), 6);
      expect(r.c.quietMinutes('w1:p1'), 0);
      expect(order(), ['w1:p2', 'w1:p1'], reason: 'the quiet one first, whatever the pane ids say');

      var notified = 0;
      r.c.addListener(() => notified++);
      final burstAt = r.now;
      for (var i = 0; i < 500; i++) {
        r.t.emit(r.event('w1:p2'));
      }
      r.async.flushMicrotasks();
      r.advance(const Duration(seconds: 5));

      expect(r.c.lastActivity('w1:p2'), burstAt, reason: 'the event was noted, cheaply');
      expect(r.c.quietMinutes('w1:p2'), 6, reason: 'but nothing re-evaluated it');
      expect(notified, 0, reason: 'no listener is woken per event');
      expect(order(), ['w1:p2', 'w1:p1'], reason: 'no reshuffle under the burst');

      r.advance(const Duration(seconds: 20));
      expect(r.c.quietMinutes('w1:p2'), 0, reason: 'the next poll takes it into account');
      expect(notified, 1, reason: 'one notification, from that refresh');
      expect(order(), ['w1:p1', 'w1:p2'], reason: 'both quiet for no time: machine, then pane');
    });

    _rig('the order changes only when a poll moves a minute count, not between', [
      _pane('w1:p1', 'working'),
      _pane('w1:p2', 'working'),
    ], poll: const Duration(seconds: 20), (r) {
      var notified = 0;
      r.c.addListener(() => notified++);

      r.minutes(5);
      final afterFive = notified;
      expect(afterFive, 1, reason: 'both crossed five minutes at one poll');

      r.advance(const Duration(seconds: 20));
      r.advance(const Duration(seconds: 20));
      expect(notified, afterFive, reason: 'the whole-minute number did not move');
      r.advance(const Duration(seconds: 20));
      expect(notified, afterFive + 1, reason: 'six minutes');
    });

    _rig('an agent that just started working is not quiet because the app has been watching a while', [
      _pane('w1:p1', 'idle'),
    ], poll: const Duration(seconds: 20), (r) {
      r.minutes(10);
      r.server([_pane('w1:p1', 'working')]);
      r.advance(const Duration(seconds: 20));

      expect(r.c.quietMinutes('w1:p1'), 0);
      expect(r.c.lastActivity('w1:p1'), isNot(_t0));
      expect(r.c.lastActivity('w1:p1'), r.c.statusTime('w1:p1')!.at, reason: 'it began working then');
    });

    _rig('an agent that stops working has no quiet to report', [
      _pane('w1:p1', 'working'),
    ], poll: const Duration(seconds: 20), (r) {
      r.minutes(6);
      expect(r.c.quietMinutes('w1:p1'), 6);

      r.server([_pane('w1:p1', 'idle')]);
      expect(r.c.quietMinutes('w1:p1'), 0);
    });

    test('a restart with an old cached start claims no quiet until the stream has proven itself', () {
      fakeAsync((async) {
        final longAgo = _t0.subtract(const Duration(hours: 2));
        final working = [_pane('w1:p1', 'working'), _pane('w1:p2', 'working')];
        final cache = MemorySnapshotCache(
          {'m': Snapshot.fromJson(snapshotJson(panes: working))},
          {
            'm': ObservedStatuses(seenAt: longAgo, panes: {
              'w1:p1': (status: AgentStatus.working, since: StatusTime.exact(longAgo)),
              'w1:p2': (status: AgentStatus.working, since: StatusTime.exact(longAgo)),
            }),
          },
        );
        final held = TestTransport(snapshotJson(panes: working))..gate = Completer<void>();
        final r = _Rig(async, const [], cache: cache, transport: held, poll: const Duration(seconds: 20));

        expect(r.c.snapshot.agentPanes, hasLength(2), reason: 'the cache is shown');
        expect(r.c.lastActivity('w1:p1'), isNull, reason: 'nobody has listened yet');
        expect(r.c.quietMinutes('w1:p1'), 0);

        held.gate!.complete();
        async.flushMicrotasks();
        held.gate = null;
        expect(r.c.isLive, isTrue);
        expect(r.c.statusTime('w1:p1'), StatusTime.exact(longAgo), reason: 'the cached start is kept');
        expect(r.c.quietMinutes('w1:p1'), 0, reason: 'a 2 h old start is not 2 h of silence');
        expect(r.c.quietMinutes('w1:p2'), 0);
        expect(r.c.lastActivity('w1:p1'), r.now, reason: 'the stream has just gone live');
        expect(_workingOrder(r.c, ['w1:p1', 'w1:p2']), ['w1:p1', 'w1:p2']);

        // p1 keeps talking for the next minutes; p2 never does.
        for (var i = 0; i < 4; i++) {
          held.emit(r.event('w1:p1'));
          r.minutes(1);
        }
        expect(r.c.quietMinutes('w1:p2'), 0, reason: 'not live for five minutes yet');
        expect(_workingOrder(r.c, ['w1:p1', 'w1:p2']), ['w1:p1', 'w1:p2']);

        held.emit(r.event('w1:p1'));
        r.minutes(1);
        expect(r.c.quietMinutes('w1:p2'), greaterThanOrEqualTo(5), reason: 'now it has been listened to');
        expect(r.c.quietMinutes('w1:p1'), 0);
        expect(_workingOrder(r.c, ['w1:p1', 'w1:p2']), ['w1:p2', 'w1:p1']);
        r.c.dispose();
        async.flushMicrotasks();
      });
    });

    _rig('after a reconnect nothing is quiet until the new stream has proven itself', [
      _pane('w1:p1', 'working'),
    ], poll: const Duration(seconds: 20), (r) {
      r.minutes(6);
      expect(r.c.quietMinutes('w1:p1'), 6);

      r.c.goOffline();
      expect(r.c.lastActivity('w1:p1'), isNull, reason: 'no stream, no claim');
      r.advance(const Duration(minutes: 30));
      r.c.reconnect();
      r.async.flushMicrotasks();
      expect(r.c.isLive, isTrue);
      expect(r.c.quietMinutes('w1:p1'), 0, reason: 'the 6 minutes before the gap do not carry over');
      expect(r.c.lastActivity('w1:p1'), r.now);

      r.minutes(4);
      expect(r.c.quietMinutes('w1:p1'), 0);
      r.minutes(1);
      expect(r.c.quietMinutes('w1:p1'), 5);
    });
  });

  group('ordering inside a section', () {
    late List<MachineConnection> machines;
    MachineConnection machine(String label) {
      final c = MachineConnection(
        profile: MachineProfile(id: label, label: label, host: 'h', username: 'u'),
        api: HerdrApi(FakeTransport()),
      );
      machines.add(c);
      return c;
    }

    setUp(() => machines = []);
    tearDown(() {
      for (final c in machines) {
        c.dispose();
      }
    });

    AgentRowData row(
      MachineConnection m,
      String pane,
      AgentStatus status, {
      StatusTime? since,
      int quiet = 0,
    }) =>
        (
          key: '${m.profile.id}/$pane',
          machine: m,
          paneId: pane,
          status: status,
          title: pane,
          subtitle: '',
          stale: false,
          since: since,
          quietMinutes: quiet,
        );

    final noon = DateTime.utc(2026, 1, 1, 12);
    List<String> keys(Map<AgentStatus, List<AgentRowData>> g, AgentStatus s) =>
        [for (final r in g[s]!) r.key];

    test('Needs you and Done: longest waiting first, a bound counts from when it begins', () {
      final a = machine('a');
      final g = groupByStatus([
        row(a, 'p1', AgentStatus.blocked, since: StatusTime.exact(noon.add(const Duration(minutes: 5)))),
        row(a, 'p2', AgentStatus.blocked, since: StatusTime.after(noon.subtract(const Duration(hours: 3)))),
        row(a, 'p3', AgentStatus.blocked),
        row(a, 'p4', AgentStatus.blocked, since: StatusTime.exact(noon)),
        row(a, 'p5', AgentStatus.done, since: StatusTime.exact(noon)),
        row(a, 'p6', AgentStatus.done, since: StatusTime.exact(noon.subtract(_min))),
      ]);

      expect(keys(g, AgentStatus.blocked), ['a/p2', 'a/p4', 'a/p1', 'a/p3'],
          reason: 'bound (3 h) first, then exact oldest to newest, unknown last');
      expect(keys(g, AgentStatus.done), ['a/p6', 'a/p5']);
    });

    test('equal waits fall back to machine label, then pane id', () {
      final a = machine('a');
      final b = machine('b');
      final since = StatusTime.exact(noon);
      final g = groupByStatus([
        row(b, 'p1', AgentStatus.done, since: since),
        row(a, 'p2', AgentStatus.done, since: since),
        row(a, 'p10', AgentStatus.done, since: since),
        row(b, 'p0', AgentStatus.done),
        row(a, 'p3', AgentStatus.done),
      ]);

      expect(keys(g, AgentStatus.done), ['a/p10', 'a/p2', 'b/p1', 'a/p3', 'b/p0']);
    });

    test('Working: quietest first; below the threshold they are equal', () {
      final a = machine('a');
      final g = groupByStatus([
        row(a, 'p1', AgentStatus.working),
        row(a, 'p2', AgentStatus.working, quiet: 9),
        row(a, 'p3', AgentStatus.working),
        row(a, 'p4', AgentStatus.working, quiet: 6),
      ]);

      expect(keys(g, AgentStatus.working), ['a/p2', 'a/p4', 'a/p1', 'a/p3']);
    });

    test('Idle: stopped within a day newest first, then no known time, then older (newest first)', () {
      final a = machine('a');
      final b = machine('b');
      final g = groupByStatus(now: noon, [
        row(a, 'p1', AgentStatus.idle, since: StatusTime.exact(noon.subtract(const Duration(days: 3)))),
        row(b, 'p1', AgentStatus.idle, since: StatusTime.exact(noon.subtract(const Duration(minutes: 12)))),
        row(a, 'p2', AgentStatus.idle),
        row(a, 'p3', AgentStatus.idle, since: StatusTime.after(noon.subtract(const Duration(hours: 5)))),
        row(a, 'p4', AgentStatus.idle, since: StatusTime.exact(noon.subtract(const Duration(minutes: 47)))),
        row(b, 'p2', AgentStatus.idle, since: StatusTime.exact(noon.subtract(const Duration(days: 9)))),
      ]);

      expect(keys(g, AgentStatus.idle), ['b/p1', 'a/p4', 'a/p3', 'a/p2', 'a/p1', 'b/p2'],
          reason: '12 min, 47 min, at most 5 h; then the one nobody dated, '
              'which may be an hour old or a month, so it is not put under 3 days; then 3 days, 9 days');
    });

    test('Idle with equal or unknown times, and Unknown, keep machine then pane', () {
      final a = machine('a');
      final b = machine('b');
      final same = StatusTime.exact(noon);
      final g = groupByStatus(now: noon, [
        row(b, 'p1', AgentStatus.idle, since: same),
        row(a, 'p9', AgentStatus.idle, since: same),
        row(b, 'p0', AgentStatus.idle),
        row(a, 'p8', AgentStatus.idle),
        row(a, 'p2', AgentStatus.unknown, since: same),
        row(a, 'p1', AgentStatus.unknown),
      ]);
      expect(keys(g, AgentStatus.idle), ['a/p9', 'b/p1', 'a/p8', 'b/p0']);
      expect(keys(g, AgentStatus.unknown), ['a/p1', 'a/p2'],
          reason: 'Unknown has no state to date: machine, then pane');
    });

    test('how recent is recent: the day is measured from now', () {
      final a = machine('a');
      final stopped = StatusTime.exact(noon.subtract(const Duration(hours: 23, minutes: 59)));
      expect(keys(groupByStatus(now: noon, [row(a, 'p1', AgentStatus.idle), row(a, 'p2', AgentStatus.idle, since: stopped)]), AgentStatus.idle),
          ['a/p2', 'a/p1'], reason: 'just inside the day: above the undated one');
      final later = noon.add(const Duration(minutes: 2));
      expect(keys(groupByStatus(now: later, [row(a, 'p1', AgentStatus.idle), row(a, 'p2', AgentStatus.idle, since: stopped)]), AgentStatus.idle),
          ['a/p1', 'a/p2'], reason: 'two minutes on it is a day old: below it');
    });

    test('the sections: Needs you, Done, Working, Idle, Unknown; the enum is not reordered', () {
      final a = machine('a');
      final g = groupByStatus([
        for (final s in AgentStatus.values.reversed) row(a, s.name, s),
      ]);

      expect(g.keys, [
        AgentStatus.blocked,
        AgentStatus.done,
        AgentStatus.working,
        AgentStatus.idle,
        AgentStatus.unknown,
      ]);
      expect(filterableStatuses, [
        AgentStatus.blocked,
        AgentStatus.done,
        AgentStatus.working,
        AgentStatus.idle,
      ]);
      // Collapsed sections are stored as bits of this index.
      expect(AgentStatus.values, [
        AgentStatus.blocked,
        AgentStatus.working,
        AgentStatus.done,
        AgentStatus.idle,
        AgentStatus.unknown,
      ]);
    });

    test('the same rows give the same order every time', () {
      final a = machine('a');
      final rows = [
        for (var i = 0; i < 12; i++)
          row(a, 'p$i', AgentStatus.blocked, since: StatusTime.exact(noon.add(Duration(minutes: i % 4)))),
      ];
      final first = keys(groupByStatus(rows), AgentStatus.blocked);
      expect(keys(groupByStatus(rows.reversed), AgentStatus.blocked), first);
    });

    test('the quiet label reads whole minutes', () {
      expect(quietLabel(const Duration(minutes: 14, seconds: 59)), 'quiet 14m');
      expect(quietLabel(const Duration(hours: 1, minutes: 5)), 'quiet 1h 05m');
    });
  });

  group('board density', () {
    test('is auto until chosen: cards up to four agents, compact from five', () async {
      final settings = AppSettings(MemoryAppSettingsStore());
      await settings.load();

      expect(settings.density, BoardDensity.auto);
      expect(AppSettings.autoCompactFrom, 5);
      expect([for (var n = 0; n <= 6; n++) settings.cardsFor(n)],
          [true, true, true, true, true, false, false]);
    });

    test('a choice wins over the count, both ways', () async {
      final settings = AppSettings(MemoryAppSettingsStore());
      await settings.setDensity(BoardDensity.cards);
      expect(settings.cardsFor(10), isTrue);

      await settings.setDensity(BoardDensity.compact);
      expect(settings.cardsFor(1), isFalse);
      expect(settings.cardsFor(0), isFalse);
    });

    test('is saved, restored, and notifies once per change', () async {
      final store = MemoryAppSettingsStore();
      final settings = AppSettings(store);
      var notified = 0;
      settings.addListener(() => notified++);

      await settings.setDensity(BoardDensity.compact);
      await settings.setDensity(BoardDensity.compact);
      expect(notified, 1);
      expect(store.writes, ['density compact', 'density compact']);

      final reopened = AppSettings(store);
      await reopened.load();
      expect(reopened.density, BoardDensity.compact);
    });

    test('preferences keep it; an unknown value is auto', () async {
      SharedPreferences.resetStatic();
      SharedPreferences.setMockInitialValues({});
      final first = AppSettings(PrefsAppSettingsStore());
      await first.setDensity(BoardDensity.cards);

      final second = AppSettings(PrefsAppSettingsStore());
      await second.load();
      expect(second.density, BoardDensity.cards);

      SharedPreferences.resetStatic();
      SharedPreferences.setMockInitialValues({'app.density.v1': 'tiles'});
      final third = AppSettings(PrefsAppSettingsStore());
      await third.load();
      expect(third.density, BoardDensity.auto);
    });
  });

  group('snapshot wire', () {
    test('completion_seq comes from the agents list, and an older herdr sends none', () {
      final withSeq = Snapshot.fromJson(snapshotJson(
        panes: [_pane('w1:p1', 'done'), _pane('w1:p2', 'done')],
        completionSeq: {'w1:p1': 12},
      ));
      expect(withSeq.panes.map((p) => p.completionSeq), [12, null]);

      final older = Snapshot.fromJson(snapshotJson(panes: [_pane('w1:p1', 'done')]));
      expect(older.panes.single.completionSeq, isNull);
    });

    test('a pane that carries completion_seq itself keeps it', () {
      final pane = Pane.fromJson({
        'pane_id': 'p',
        'workspace_id': 'w',
        'tab_id': 't',
        'completion_seq': 4,
      });
      expect(pane.completionSeq, 4);
      expect(Pane.fromJson(pane.toJson()), pane);
      expect(pane.withCompletionSeq(5), isNot(pane));
    });
  });
}

/// A fleet of fake machines with the reviewed state and the agent screens
/// wired in as the app wires them.
class _Fleet {
  _Fleet({ReviewedState? reviewed}) : reviewed = reviewed ?? ReviewedState() {
    machines = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
    fleet = FleetRepository(
      machines: machines,
      network: network,
      reviewed: this.reviewed,
      screens: screens,
      connect: (profile, secrets) => MachineConnection(
        profile: profile,
        api: HerdrApi(transports.putIfAbsent(profile.id, FakeTransport.new)),
        backoff: (_) => const Duration(hours: 1),
        pollInterval: const Duration(hours: 1),
      ),
    );
  }

  final ReviewedState reviewed;
  final network = FakeNetwork();
  final screens = AgentScreens();
  final transports = <String, FakeTransport>{};
  late final MachineRepository machines;
  late final FleetRepository fleet;

  Future<void> add(String id, List<_P> panes, {Map<String, int> seq = const {}}) async {
    transports[id] = FakeTransport(snapshotJson(panes: panes, completionSeq: seq));
    await machines.save(
      MachineProfile(id: id, label: id, host: '$id.local', username: 'u'),
      secrets: const MachineSecrets(password: 'x'),
    );
    await fleet.settled();
    await eventually(() => fleet.connection(id)!.isLive);
  }

  void dispose() {
    fleet.dispose();
    screens.dispose();
  }
}

class _BrokenReviewedStore implements ReviewedStore {
  @override
  Future<ReviewedMap?> read() async => throw StateError('disk gone');

  @override
  Future<void> write(ReviewedMap reviewed) async => throw StateError('disk gone');
}
