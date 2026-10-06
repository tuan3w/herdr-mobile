// The background profile of one connection: a status-only event subscription
// that is rebuilt as the agent panes change, the one refresh after every
// replacement, a slower safety-net poll and slower retries.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/aligned_ticker.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';

import 'support/fake_transport.dart';

final _t0 = DateTime.utc(2026, 3, 1, 12);

typedef _Pane = ({String id, String ws, String? agent, String status});

_Pane _agent(String id, String status) => (id: id, ws: 'w1', agent: 'claude', status: status);
_Pane _shell(String id) => (id: id, ws: 'w1', agent: null, status: 'idle');

const _structural = {
  'workspace.created',
  'workspace.updated',
  'workspace.closed',
  'workspace.renamed',
  'tab.created',
  'tab.closed',
  'tab.renamed',
  'pane.created',
  'pane.closed',
  'pane.exited',
  'pane.agent_detected',
  'layout.updated',
};

class _Rig {
  _Rig(this.async, List<_Pane> panes, {Duration backoff = const Duration(milliseconds: 10)})
      : transport = FakeTransport(snapshotJson(panes: panes)) {
    connection = MachineConnection(
      profile: const MachineProfile(id: 'm', label: 'Mac', host: 'm.local', username: 'u'),
      api: HerdrApi(transport),
      backoff: (_) => backoff,
      pollInterval: const Duration(seconds: 20),
      backgroundPollInterval: const Duration(minutes: 4),
      clock: () => _t0.add(async.elapsed),
    )..addListener(() => states.add(connection.state));
    connection.start();
    async.elapse(const Duration(seconds: 1));
    states.clear();
    expect(connection.isLive, isTrue, reason: 'set-up');
  }

  final FakeAsync async;
  final FakeTransport transport;
  late final MachineConnection connection;
  final states = <LinkState>[];

  /// The link was never anything but online since set-up.
  bool get stayedOnline => states.every((s) => s == LinkState.online);

  /// What herdr answers from now on.
  void herdr(List<_Pane> panes) => transport.snapshot = snapshotJson(panes: panes);

  void elapse(Duration d) => async.elapse(d);

  List<Map<String, dynamic>> get lastSubscription => transport.subscribed.last;

  Set<String> get named => {
        for (final s in lastSubscription)
          if (s['type'] == 'pane.agent_status_changed') s['pane_id'] as String,
      };

  Set<String> get types => {for (final s in lastSubscription) s['type'] as String};

  void dispose() => connection.dispose();
}

void _run(void Function(_Rig r) body, List<_Pane> panes, {Duration backoff = const Duration(milliseconds: 10)}) =>
    fakeAsync((async) {
      final r = _Rig(async, panes, backoff: backoff);
      body(r);
      r.dispose();
    });

void main() {
  const second = Duration(seconds: 1);

  group('the subscription', () {
    test('is the full one in the foreground: pane.updated, and no status entry', () {
      _run((r) {
        expect(r.types, {..._structural, 'pane.updated'});
        expect(r.named, isEmpty);
      }, [_agent('w1:p1', 'working')]);
    });

    test('in the background it is structure plus one status entry per agent pane, no pane.updated', () {
      _run((r) {
        r.connection.setBackground(true);
        r.elapse(second);

        expect(r.transport.subscribed, hasLength(2));
        expect(r.types, {..._structural, 'pane.agent_status_changed'});
        expect(r.types, isNot(contains('pane.updated')));
        expect(r.named, {'w1:p1', 'w1:p2'}, reason: 'a plain terminal has no agent to watch');
        // Every entry herdr must accept: only status entries carry a pane id.
        for (final s in r.lastSubscription) {
          expect(s.keys, s['type'] == 'pane.agent_status_changed' ? {'type', 'pane_id'} : {'type'});
        }
      }, [_agent('w1:p1', 'working'), _agent('w1:p2', 'blocked'), _shell('w1:p3')]);
    });

    test('replacing it is not an outage: no state change, one refresh, the same link', () {
      _run((r) {
        final calls = r.transport.snapshotCalls;
        r.connection.setBackground(true);
        r.elapse(second);
        expect(r.stayedOnline, isTrue, reason: 'online throughout');
        expect(r.transport.snapshotCalls, calls + 1, reason: 'one refresh to cover the gap');
        expect(r.transport.resets, 0);

        r.connection.setBackground(false);
        r.elapse(second);
        expect(r.stayedOnline, isTrue);
        expect(r.transport.snapshotCalls, calls + 2);
      }, [_agent('w1:p1', 'working')]);
    });

    test('what changed while the old one was being replaced is found by that refresh', () {
      _run((r) {
        expect(r.connection.paneById('w1:p1')!.status.name, 'working');
        r.herdr([_agent('w1:p1', 'blocked')]);
        r.connection.setBackground(true); // no event told us
        r.elapse(second);
        expect(r.connection.paneById('w1:p1')!.status.name, 'blocked');
      }, [_agent('w1:p1', 'working')]);
    });

    test('going back to the foreground restores the full one, with a refresh', () {
      _run((r) {
        r.connection.setBackground(true);
        r.elapse(second);
        final calls = r.transport.snapshotCalls;

        r.herdr([_agent('w1:p1', 'idle')]);
        r.connection.setBackground(false);
        r.elapse(second);
        expect(r.types, {..._structural, 'pane.updated'});
        expect(r.named, isEmpty);
        expect(r.transport.snapshotCalls, calls + 1);
        expect(r.connection.paneById('w1:p1')!.status.name, 'idle');
      }, [_agent('w1:p1', 'working')]);
    });

    test('setting the same profile again does nothing', () {
      _run((r) {
        r.connection.setBackground(false);
        r.elapse(second);
        expect(r.transport.subscribed, hasLength(1));
        r.connection.setBackground(true);
        r.connection.setBackground(true);
        r.elapse(second);
        expect(r.transport.subscribed, hasLength(2));
        expect(r.transport.backgroundCalls, [true]);
      }, [_agent('w1:p1', 'working')]);
    });

    test('a connection that is not watching yet starts in the profile it was given', () {
      fakeAsync((async) {
        final transport = FakeTransport(snapshotJson(panes: [_agent('w1:p1', 'working')]));
        final c = MachineConnection(
          profile: const MachineProfile(id: 'm', label: 'Mac', host: 'm.local', username: 'u'),
          api: HerdrApi(transport),
          backoff: (_) => const Duration(hours: 1),
        );
        c.setBackground(true);
        c.start();
        async.elapse(second);
        expect(transport.subscribed.single.map((s) => s['type']), contains('pane.agent_status_changed'));
        expect(transport.subscribed.single.map((s) => s['type']), isNot(contains('pane.updated')));
        c.dispose();
      });
    });
  });

  group('the panes it names follow the agent panes', () {
    test('an agent that appears is named at the next subscription, which is made at once', () {
      _run((r) {
        r.connection.setBackground(true);
        r.elapse(second);
        expect(r.named, {'w1:p1'});
        final subscriptions = r.transport.subscribed.length;

        r.herdr([_agent('w1:p1', 'working'), _shell('w1:p2')]);
        r.transport.emit({'event': 'pane_created'});
        r.elapse(second);
        expect(r.transport.subscribed, hasLength(subscriptions), reason: 'a plain terminal changes nothing to name');

        r.herdr([_agent('w1:p1', 'working'), _agent('w1:p2', 'working')]);
        r.transport.emit({'event': 'pane_agent_detected'});
        r.elapse(second);
        expect(r.named, {'w1:p1', 'w1:p2'});
        expect(r.transport.subscribed, hasLength(subscriptions + 1));
        expect(r.stayedOnline, isTrue);
      }, [_agent('w1:p1', 'working')]);
    });

    test('a pane that closes is gone from the list, and a closed pane is never named again', () {
      _run((r) {
        r.connection.setBackground(true);
        r.elapse(second);
        expect(r.named, {'w1:p1', 'w1:p2'});
        final before = r.transport.subscribed.length;

        r.herdr([_agent('w1:p1', 'working')]);
        r.transport.emit({'event': 'pane_closed'});
        r.elapse(second);

        expect(r.named, {'w1:p1'});
        for (final s in r.transport.subscribed.skip(before)) {
          expect(s.map((e) => e['pane_id']), isNot(contains('w1:p2')));
        }
      }, [_agent('w1:p1', 'working'), _agent('w1:p2', 'working')]);
    });

    test('a pane that closed after the snapshot and before the subscription is retaken at once', () {
      // herdr answers pane_not_found for the whole subscription then; the
      // back-off here is an hour, so only the quick path can recover.
      _run((r) {
        r.connection.setBackground(true);
        r.elapse(second);
        final subscriptions = r.transport.subscribed.length;
        r.herdr([_agent('w1:p1', 'working')]);
        r.transport.dropEvents(const HerdrApiException('pane_not_found', 'pane w1:p2 not found'));
        r.elapse(second);

        expect(r.connection.isLive, isTrue);
        expect(r.transport.subscribed, hasLength(subscriptions + 1));
        expect(r.named, {'w1:p1'});
      }, [_agent('w1:p1', 'working'), _agent('w1:p2', 'working')], backoff: const Duration(hours: 1));
    });

    test('a status event makes the normal urgent refresh', () {
      _run((r) {
        r.connection.setBackground(true);
        r.elapse(second);
        final calls = r.transport.snapshotCalls;

        r.herdr([_agent('w1:p1', 'blocked')]);
        r.transport.emit({'event': 'pane.agent_status_changed'});
        r.elapse(const Duration(milliseconds: 200));
        expect(r.transport.snapshotCalls, calls + 1);
        expect(r.connection.paneById('w1:p1')!.status.name, 'blocked');
      }, [_agent('w1:p1', 'working')]);
    });
  });

  group('what the background does not do', () {
    test('pane_updated never wakes a refresh, however many arrive', () {
      _run((r) {
        r.connection.setBackground(true);
        r.elapse(second);
        final calls = r.transport.snapshotCalls;

        r.herdr([_agent('w1:p1', 'working')]); // even a changed title
        for (var i = 0; i < 100; i++) {
          r.transport.emit({
            'event': 'pane_updated',
            'data': {
              'pane': {
                'pane_id': 'w1:p1',
                'workspace_id': 'w1',
                'tab_id': 'w1:t1',
                'agent': 'claude',
                'agent_status': 'blocked',
                'terminal_title': 'spin $i',
              },
            },
          });
          r.elapse(const Duration(milliseconds: 100));
        }
        expect(r.transport.snapshotCalls, calls, reason: 'no churn refresh, no status refresh from a pane_updated');
      }, [_agent('w1:p1', 'working')]);
    });

    test('the foreground still follows pane_updated', () {
      _run((r) {
        final calls = r.transport.snapshotCalls;
        r.transport.emit({
          'event': 'pane_updated',
          'data': {
            'pane': {
              'pane_id': 'w1:p1',
              'workspace_id': 'w1',
              'tab_id': 'w1:t1',
              'agent': 'claude',
              'agent_status': 'blocked',
            },
          },
        });
        r.elapse(second);
        expect(r.transport.snapshotCalls, greaterThan(calls));
      }, [_agent('w1:p1', 'working')]);
    });
  });

  group('the safety-net poll', () {
    int polls(_Rig r, Duration d) {
      final before = r.transport.snapshotCalls;
      r.elapse(d);
      return r.transport.snapshotCalls - before;
    }

    test('every 20 s in the foreground', () {
      _run((r) {
        expect(polls(r, const Duration(seconds: 19)), 0);
        expect(polls(r, const Duration(seconds: 2)), 1);
        expect(polls(r, const Duration(seconds: 40)), 2);
      }, [_agent('w1:p1', 'working')]);
    });

    test('every 4 minutes in the background, on the clock grid, and the 20 s timer is gone', () {
      _run((r) {
        r.connection.setBackground(true);
        r.elapse(second);
        // The grid is the clock's: a tick at every multiple of 4 minutes.
        final wait = AlignedTicker.untilNext(const Duration(minutes: 4), _t0.add(r.async.elapsed));
        expect(polls(r, wait - const Duration(seconds: 1)), 0);
        expect(polls(r, const Duration(seconds: 2)), 1);
        expect(polls(r, const Duration(minutes: 12)), 3);

        r.connection.setBackground(false);
        r.elapse(second);
        expect(polls(r, const Duration(minutes: 1)), 3, reason: 'back to 20 s');
      }, [_agent('w1:p1', 'working')]);
    });
  });

  group('retrying a machine that does not answer', () {
    /// Snapshot attempts in each of [windows] (after the link broke).
    List<int> attempts(_Rig r, List<Duration> windows) {
      r.transport.failure = const HerdrTransportException('no route');
      r.transport.dropEvents(const HerdrTransportException('no route'));
      final out = <int>[];
      for (final w in windows) {
        final before = r.transport.snapshotCalls;
        r.elapse(w);
        out.add(r.transport.snapshotCalls - before);
      }
      return out;
    }

    test('in the foreground by the ordinary back-off', () {
      _run((r) {
        final first = attempts(r, [const Duration(seconds: 10)]).single;
        expect(first, greaterThan(100), reason: 'every 10 ms in this rig');
      }, [_agent('w1:p1', 'working')]);
    });

    test('in the background after 30 s, 1, 2 and then every 5 minutes', () {
      _run((r) {
        r.connection.setBackground(true);
        r.elapse(second);
        // Retries at 30 s, then 60 s, 120 s, 300 s and 300 s after the last
        // one (t = 30, 90, 210, 510, 810); each window ends just past one.
        final counts = attempts(r, [
          const Duration(seconds: 29),
          const Duration(seconds: 2), // t = 31
          const Duration(seconds: 58),
          const Duration(seconds: 2), // t = 91
          const Duration(seconds: 118),
          const Duration(seconds: 2), // t = 211
          const Duration(seconds: 298),
          const Duration(seconds: 2), // t = 511
          const Duration(seconds: 298),
          const Duration(seconds: 2), // t = 811
        ]);
        expect(counts, [0, 1, 0, 1, 0, 1, 0, 1, 0, 1]);
        expect(r.connection.state, LinkState.reconnecting);
      }, [_agent('w1:p1', 'working')]);
    });

    test('a machine that answers again is back at once, whatever the delay', () {
      _run((r) {
        r.connection.setBackground(true);
        r.elapse(second);
        attempts(r, [const Duration(seconds: 100)]);
        r.transport.failure = null;
        r.connection.retry();
        r.elapse(second);
        expect(r.connection.isLive, isTrue);
      }, [_agent('w1:p1', 'working')]);
    });
  });
}
