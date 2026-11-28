// A status event is shown the moment it arrives, before the snapshot that
// confirms it has made its round trip (`MachineConnection._patchStatus`); the
// snapshot is still taken, once, and has the last word.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import 'support/fake_transport.dart';
import 'support/memory_snapshot_cache.dart';

const _profile = MachineProfile(id: 'm', label: 'box', host: 'h', username: 'u');

const _structural = Duration(milliseconds: 150);

/// herdr whose snapshot answers can be held back. An answer is the state at
/// the time the request was made, as a real round trip's is.
class _Held extends FakeTransport {
  _Held(super.snapshot);

  Completer<void>? hold;

  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) async {
    final gate = method == 'session.snapshot' ? hold : null;
    final answer = super.request(method, params);
    if (gate != null) await gate.future;
    return answer;
  }
}

MachineConnection _connection(_Held t, {FakeAsync? async, MemorySnapshotCache? cache}) => MachineConnection(
  profile: _profile,
  api: HerdrApi(t),
  cache: cache,
  backoff: (_) => const Duration(seconds: 30),
  pollInterval: const Duration(hours: 1),
  clock: async == null ? DateTime.now : () => DateTime(2026).add(async.elapsed),
);

({String id, String ws, String? agent, String status}) _pane(String id, String status, {String? agent = 'claude'}) =>
    (id: id, ws: 'w1', agent: agent, status: status);

/// A snapshot the way herdr sends it: its workspace and tab say what their
/// panes roll up to (blocked, done, working, idle).
Map<String, dynamic> _snap(Map<String, String> statuses, {List<String> shells = const []}) {
  final json = snapshotJson(
    panes: [
      for (final e in statuses.entries) _pane(e.key, e.value),
      for (final s in shells) _pane(s, 'idle', agent: null),
    ],
  );
  const rank = ['unknown', 'idle', 'working', 'done', 'blocked'];
  final best = [for (final p in json['panes'] as List) p['agent_status'] as String]
      .reduce((a, b) => rank.indexOf(a) >= rank.indexOf(b) ? a : b);
  for (final w in json['workspaces'] as List) {
    (w as Map<String, dynamic>)['agent_status'] = best;
  }
  for (final t in json['tabs'] as List) {
    (t as Map<String, dynamic>)['agent_status'] = best;
  }
  return json;
}

/// The background profile's carrier of a status change: flat data, no pane.
Map<String, dynamic> _statusEvent(
  String id,
  String status, {
  Object? agent = 'claude',
  Object? ws = 'w1',
  bool full = true,
}) => {
  'event': 'pane_agent_status_changed',
  'data': {'pane_id': id, 'agent_status': status, if (full) 'agent': agent, if (full) 'workspace_id': ws},
};

/// The foreground profile's carrier: the whole pane.
Map<String, dynamic> _paneUpdated(String id, String status, {String agent = 'claude', String ws = 'w1'}) => {
  'event': 'pane_updated',
  'data': {
    'pane': {
      'pane_id': id,
      'workspace_id': ws,
      'tab_id': '$ws:t1',
      'focused': false,
      'cwd': '/work/$ws',
      'terminal_title_stripped': 'title $id',
      'agent': agent,
      'agent_status': status,
    },
  },
};

/// The event reaches the connection (microtasks only: no time passes).
void _emit(FakeAsync async, _Held t, Map<String, dynamic> event) {
  t.emit(event);
  async.flushMicrotasks();
}

AgentStatus _statusOf(MachineConnection c, String id) => c.paneById(id)!.status;

/// Online, with the event stream live and the background profile on or off.
MachineConnection _online(FakeAsync async, _Held t, {bool background = false, MemorySnapshotCache? cache}) {
  final c = _connection(t, async: async, cache: cache)..start();
  async.flushMicrotasks();
  expect(c.isLive, isTrue);
  if (background) {
    c.setBackground(true);
    async.elapse(const Duration(seconds: 1));
  }
  async.elapse(const Duration(seconds: 1));
  return c;
}

void main() {
  group('a status event is shown before the snapshot answers', () {
    for (final background in [true, false]) {
      test('${background ? 'background' : 'foreground'}: blocked is on the board, the snapshot comes once', () {
        fakeAsync((async) {
          final t = _Held(_snap({'w1:p1': 'working', 'w1:p2': 'working'}));
          final c = _online(async, t, background: background);
          var notified = 0;
          c.addListener(() => notified++);
          final calls = t.snapshotCalls;

          // What herdr will answer, and its answer held on the way.
          t.snapshot = _snap({'w1:p1': 'blocked', 'w1:p2': 'working'});
          t.hold = Completer();
          _emit(async, t, background ? _statusEvent('w1:p1', 'blocked') : _paneUpdated('w1:p1', 'blocked'));

          expect(_statusOf(c, 'w1:p1'), AgentStatus.blocked, reason: 'shown at once, no time has passed');
          expect(_statusOf(c, 'w1:p2'), AgentStatus.working);
          expect(c.snapshot.workspaces.single.status, AgentStatus.blocked, reason: 'the roll-up follows');
          expect(c.snapshot.tabs.single.status, AgentStatus.blocked);
          expect(notified, 1);
          expect(t.snapshotCalls, calls, reason: 'nothing asked yet');

          async.elapse(_structural);
          expect(t.snapshotCalls, calls + 1, reason: 'the verifying snapshot goes out after the usual delay');
          expect(_statusOf(c, 'w1:p1'), AgentStatus.blocked, reason: 'still shown while it is out');

          t.hold!.complete();
          t.hold = null;
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 10));
          expect(t.snapshotCalls, calls + 1, reason: 'once');
          expect(_statusOf(c, 'w1:p1'), AgentStatus.blocked);
          expect(notified, 1, reason: 'the snapshot agreed: nothing more to show');
          c.dispose();
        });
      });
    }

    test('the change is dated when the event arrived, not when the snapshot did', () {
      fakeAsync((async) {
        final t = _Held(_snap({'w1:p1': 'working'}));
        final c = _online(async, t);
        t.snapshot = _snap({'w1:p1': 'blocked'});
        t.hold = Completer();
        _emit(async, t, _statusEvent('w1:p1', 'blocked'));
        final at = c.statusTime('w1:p1')!.at;
        expect(at, DateTime(2026).add(async.elapsed));

        async.elapse(const Duration(seconds: 3)); // the answer is slow
        t.hold!.complete();
        t.hold = null;
        async.flushMicrotasks();
        expect(c.statusTime('w1:p1')!.at, at);
        expect(c.statusTime('w1:p1')!.exact, isTrue);
        c.dispose();
      });
    });

    test('an event without agent or workspace (only pane and status) is enough', () {
      fakeAsync((async) {
        final t = _Held(_snap({'w1:p1': 'working'}));
        final c = _online(async, t);
        t.hold = Completer();
        _emit(async, t, _statusEvent('w1:p1', 'blocked', full: false));
        expect(_statusOf(c, 'w1:p1'), AgentStatus.blocked);
        t.hold!.complete();
        t.hold = null;
        c.dispose();
      });
    });

    test('blocked back to working and to idle are patched too', () {
      fakeAsync((async) {
        final t = _Held(_snap({'w1:p1': 'blocked', 'w1:p2': 'blocked'}));
        final c = _online(async, t);
        t.hold = Completer();
        _emit(async, t, _statusEvent('w1:p1', 'working'));
        _emit(async, t, _statusEvent('w1:p2', 'idle'));
        expect(_statusOf(c, 'w1:p1'), AgentStatus.working);
        expect(_statusOf(c, 'w1:p2'), AgentStatus.idle);
        t.hold!.complete();
        t.hold = null;
        c.dispose();
      });
    });

    test('a burst of identical events asks for one snapshot', () {
      fakeAsync((async) {
        final t = _Held(_snap({'w1:p1': 'working'}));
        final c = _online(async, t);
        var notified = 0;
        c.addListener(() => notified++);
        final calls = t.snapshotCalls;

        t.snapshot = _snap({'w1:p1': 'blocked'});
        for (var i = 0; i < 6; i++) {
          _emit(async, t, _statusEvent('w1:p1', 'blocked'));
          async.elapse(const Duration(milliseconds: 10));
        }
        async.elapse(const Duration(seconds: 10));

        expect(t.snapshotCalls, calls + 1);
        expect(notified, 1);
        c.dispose();
      });
    });

    test('the verified state reaches the cache although the snapshot agreed with the patch', () {
      fakeAsync((async) {
        final cache = MemorySnapshotCache();
        final t = _Held(_snap({'w1:p1': 'working'}));
        final c = _online(async, t, cache: cache);
        t.snapshot = _snap({'w1:p1': 'blocked'});
        _emit(async, t, _statusEvent('w1:p1', 'blocked'));
        async.elapse(const Duration(seconds: 30));

        expect(cache.entries['m']!.panes.single.status, AgentStatus.blocked);
        c.dispose();
      });
    });
  });

  group('the snapshot has the last word', () {
    test('an event the snapshot does not bear out is taken back, with one snapshot', () {
      fakeAsync((async) {
        final t = _Held(_snap({'w1:p1': 'working'}));
        final c = _online(async, t);
        var notified = 0;
        c.addListener(() => notified++);
        final calls = t.snapshotCalls;

        // The event was stale: herdr's answer says the agent is still working.
        t.hold = Completer();
        _emit(async, t, _statusEvent('w1:p1', 'blocked'));
        expect(_statusOf(c, 'w1:p1'), AgentStatus.blocked);
        async.elapse(_structural);
        t.hold!.complete();
        t.hold = null;
        async.flushMicrotasks();

        expect(_statusOf(c, 'w1:p1'), AgentStatus.working);
        expect(c.snapshot.workspaces.single.status, AgentStatus.working, reason: 'herdr\'s own roll-up is back');
        expect(notified, 2, reason: 'patched, then corrected');
        expect(t.snapshotCalls, calls + 1);
        c.dispose();
      });
    });

    test('a snapshot taken before the event does not take the patch back', () {
      fakeAsync((async) {
        final t = _Held(_snap({'w1:p1': 'working'}));
        final c = _online(async, t);
        var notified = 0;
        c.addListener(() => notified++);
        final calls = t.snapshotCalls;

        // A refresh is out (herdr answers `working`, as it was when asked) ...
        t.hold = Completer();
        _emit(async, t, {'event': 'tab_created'});
        async.elapse(_structural);
        expect(t.snapshotCalls, calls + 1);
        final stale = t.hold!;

        // ... the agent blocks, and the event arrives before that answer does.
        t.snapshot = _snap({'w1:p1': 'blocked'});
        t.hold = null;
        _emit(async, t, _statusEvent('w1:p1', 'blocked'));
        expect(_statusOf(c, 'w1:p1'), AgentStatus.blocked);

        stale.complete();
        async.flushMicrotasks();
        expect(_statusOf(c, 'w1:p1'), AgentStatus.blocked, reason: 'the old answer must not undo it');
        expect(notified, 1, reason: 'no flicker back to working');

        async.elapse(const Duration(seconds: 10));
        expect(t.snapshotCalls, calls + 2, reason: 'one more, the verifying one');
        expect(_statusOf(c, 'w1:p1'), AgentStatus.blocked);
        expect(notified, 1);
        c.dispose();
      });
    });

    test('a patch the next snapshot corrects stays corrected', () {
      fakeAsync((async) {
        final t = _Held(_snap({'w1:p1': 'working'}));
        final c = _online(async, t);

        // Reversed: herdr's answer to the first snapshot is `working`, then the
        // agent really blocks and the next event is true.
        _emit(async, t, _statusEvent('w1:p1', 'blocked'));
        async.elapse(const Duration(seconds: 10));
        expect(_statusOf(c, 'w1:p1'), AgentStatus.working);

        t.snapshot = _snap({'w1:p1': 'blocked'});
        _emit(async, t, _statusEvent('w1:p1', 'blocked'));
        expect(_statusOf(c, 'w1:p1'), AgentStatus.blocked);
        async.elapse(const Duration(seconds: 10));
        expect(_statusOf(c, 'w1:p1'), AgentStatus.blocked);
        c.dispose();
      });
    });
  });

  group('what an event does not carry takes the old path: refresh only', () {
    // [event] must change nothing until the snapshot answers; the answer
    // [then] is what the board shows afterwards.
    void expectRefreshOnly(
      String name,
      Map<String, String> before,
      Map<String, dynamic> event,
      Map<String, String> then, {
      List<String> shells = const [],
      bool background = true,
    }) {
      test(name, () {
        fakeAsync((async) {
          final t = _Held(_snap(before, shells: shells));
          final c = _online(async, t, background: background);
          final shown = c.snapshot;
          var notified = 0;
          c.addListener(() => notified++);
          final calls = t.snapshotCalls;

          t.snapshot = _snap(then, shells: shells);
          _emit(async, t, event);
          expect(c.snapshot, shown, reason: 'nothing shown before the snapshot');
          expect(notified, 0);

          async.elapse(const Duration(seconds: 10));
          expect(t.snapshotCalls, calls + 1);
          expect({for (final p in c.snapshot.agentPanes) p.id: p.status.name}, then);
          c.dispose();
        });
      });
    }

    expectRefreshOnly(
      'a pane we do not know',
      {'w1:p1': 'working'},
      _statusEvent('w1:p9', 'blocked'),
      {'w1:p1': 'working', 'w1:p9': 'blocked'},
      background: false,
    );
    expectRefreshOnly(
      'working to done (what done means rests on completion_seq)',
      {'w1:p1': 'working'},
      _statusEvent('w1:p1', 'done'),
      {'w1:p1': 'done'},
    );
    expectRefreshOnly('done to working', {'w1:p1': 'done'}, _statusEvent('w1:p1', 'working'), {'w1:p1': 'working'});
    expectRefreshOnly('blocked to done', {'w1:p1': 'blocked'}, _statusEvent('w1:p1', 'done'), {'w1:p1': 'done'});
    expectRefreshOnly('unknown status', {'w1:p1': 'working'}, _statusEvent('w1:p1', 'unknown'), {'w1:p1': 'unknown'});
    expectRefreshOnly(
      'a status word this app does not know',
      {'w1:p1': 'working'},
      _statusEvent('w1:p1', 'brooding'),
      {'w1:p1': 'working'},
    );
    expectRefreshOnly(
      'the agent changed with it',
      {'w1:p1': 'working'},
      _statusEvent('w1:p1', 'blocked', agent: 'omp'),
      {'w1:p1': 'blocked'},
    );
    expectRefreshOnly(
      'the agent went away with it',
      {'w1:p1': 'working'},
      _statusEvent('w1:p1', 'idle', agent: null),
      {'w1:p1': 'idle'},
    );
    expectRefreshOnly(
      'another workspace',
      {'w1:p1': 'working'},
      _statusEvent('w1:p1', 'blocked', ws: 'w2'),
      {'w1:p1': 'blocked'},
    );
    expectRefreshOnly('no data at all', {'w1:p1': 'working'}, const {'event': 'pane_agent_status_changed'}, {
      'w1:p1': 'blocked',
    });
    expectRefreshOnly(
      'a pane with no agent',
      {'w1:p1': 'working'},
      _statusEvent('w1:s1', 'blocked', agent: null),
      {'w1:p1': 'working'},
      shells: ['w1:s1'],
    );
    expectRefreshOnly(
      'foreground: a pane in another tab',
      {'w1:p1': 'working'},
      {
        'event': 'pane_updated',
        'data': {
          'pane': {
            'pane_id': 'w1:p1',
            'workspace_id': 'w1',
            'tab_id': 'w1:t2',
            'agent': 'claude',
            'agent_status': 'blocked',
          },
        },
      },
      {'w1:p1': 'blocked'},
      background: false,
    );
    expectRefreshOnly(
      'foreground: done',
      {'w1:p1': 'working'},
      _paneUpdated('w1:p1', 'done'),
      {'w1:p1': 'done'},
      background: false,
    );
    expectRefreshOnly(
      'foreground: a pane we do not know',
      {'w1:p1': 'working'},
      _paneUpdated('w1:p9', 'blocked'),
      {'w1:p1': 'working', 'w1:p9': 'blocked'},
      background: false,
    );
    expectRefreshOnly(
      'a pane created',
      {'w1:p1': 'working'},
      {
        'event': 'pane_created',
        'data': {
          'pane': {'pane_id': 'w1:p9', 'workspace_id': 'w1', 'tab_id': 'w1:t1'},
        },
      },
      {'w1:p1': 'working', 'w1:p9': 'working'},
      background: false,
    );
    expectRefreshOnly(
      'an agent detected',
      {'w1:p1': 'working'},
      {
        'event': 'pane_agent_detected',
        'data': {'pane_id': 'w1:s1', 'agent': 'claude'},
      },
      {'w1:p1': 'working', 'w1:s1': 'blocked'},
      background: false,
    );

    test('a pane_updated that arrives in the background is still ignored', () {
      fakeAsync((async) {
        final t = _Held(_snap({'w1:p1': 'working'}));
        final c = _online(async, t, background: true);
        final calls = t.snapshotCalls;

        _emit(async, t, _paneUpdated('w1:p1', 'blocked'));
        async.elapse(const Duration(seconds: 10));

        expect(_statusOf(c, 'w1:p1'), AgentStatus.working);
        expect(t.snapshotCalls, calls);
        c.dispose();
      });
    });
  });
}
