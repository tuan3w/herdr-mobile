import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import 'support/fake_transport.dart';

const _profile = MachineProfile(id: 'm', label: 'box', host: 'h', username: 'u');

/// One event stream's life: how long it stays up, and whether it delivers an
/// event before it ends.
typedef _Life = ({Duration up, bool event});

const _diesAtOnce = (up: Duration.zero, event: false);

/// A machine that answers every snapshot but whose event streams end as
/// scripted (the last entry repeats), and that can send a snapshot the app
/// cannot read.
class _Machine extends FakeTransport {
  _Machine(this.lives, this.now);

  final List<_Life> lives;
  final DateTime Function() now;

  /// When each snapshot was asked for.
  final asked = <DateTime>[];

  /// The next snapshot answers this many times with something unreadable.
  int unreadable = 0;

  /// Gaps between consecutive snapshot requests, in whole seconds.
  List<int> get gaps => [
        for (var i = 1; i < asked.length; i++) asked[i].difference(asked[i - 1]).inSeconds,
      ];

  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) {
    if (method == 'session.snapshot') {
      asked.add(now());
      if (unreadable > 0) {
        unreadable--;
        return Future.value({'type': 'session_snapshot', 'snapshot': 'not a snapshot'});
      }
    }
    return super.request(method, params);
  }

  int _streams = 0;

  @override
  Stream<Map<String, dynamic>> events(List<Map<String, dynamic>> subscriptions) {
    final life = lives[_streams < lives.length ? _streams : lives.length - 1];
    _streams++;
    final c = StreamController<Map<String, dynamic>>(onCancel: () => Future<void>.value());
    if (life.event) c.add(const {'event': 'workspace_created'});
    Timer(life.up, c.close);
    return c.stream;
  }
}

/// The connection's clock and the machine's are the fake one: `fakeAsync`
/// does not move `DateTime.now`.
DateTime Function() _fakeNow(FakeAsync async) => async.getClock(DateTime(2026)).now;

MachineConnection _connection(FakeTransport t, FakeAsync async) => MachineConnection(
      profile: _profile,
      api: HerdrApi(t),
      clock: _fakeNow(async),
      // The real retry delays and stream timing.
      pollInterval: const Duration(hours: 1),
    );

void main() {
  test('a stream that dies at once backs off 1, 2, 4, 8 seconds, not 1 second for ever', () {
    fakeAsync((async) {
      final t = _Machine([_diesAtOnce], _fakeNow(async));
      final c = _connection(t, async)..start();
      async.elapse(const Duration(seconds: 40));
      c.dispose();

      expect(t.gaps.take(5), [1, 2, 4, 8, 15]);
    });
  });

  test('a stream that delivered an event counts as having worked: the delays start over', () {
    fakeAsync((async) {
      final t = _Machine([
        _diesAtOnce,
        _diesAtOnce,
        (up: Duration.zero, event: true),
        _diesAtOnce,
      ], _fakeNow(async));
      final c = _connection(t, async)..start();
      async.elapse(const Duration(seconds: 20));
      c.dispose();

      expect(t.gaps.take(4), [1, 2, 1, 2]);
    });
  });

  test('a stream that stayed up for a while counts as having worked', () {
    fakeAsync((async) {
      final t = _Machine([
        _diesAtOnce,
        (up: const Duration(seconds: 31), event: false),
        _diesAtOnce,
      ], _fakeNow(async));
      final c = _connection(t, async)..start();
      async.elapse(const Duration(seconds: 60));
      c.dispose();

      // 1 s wait, 31 s up and 1 s wait (the second wait would have been 2 s), then 2 s.
      expect(t.gaps.take(3), [1, 32, 2]);
    });
  });

  test('a reply the app cannot read is a failed attempt that is retried', () {
    fakeAsync((async) {
      final t = _Machine([
        (up: const Duration(hours: 1), event: false),
      ], _fakeNow(async))..unreadable = 2;
      final c = _connection(t, async)..start();
      async.elapse(const Duration(milliseconds: 10));

      expect(c.state, LinkState.reconnecting);
      expect(c.error, isNotNull);

      async.elapse(const Duration(seconds: 4));

      expect(c.state, LinkState.online, reason: 'the third attempt was readable');
      expect(t.gaps, [1, 2]);
      c.dispose();
    });
  });
}
