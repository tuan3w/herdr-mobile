import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/network_monitor.dart';

class _FakeConnectivity implements Connectivity {
  _FakeConnectivity(this.initial);

  List<ConnectivityResult> initial;
  Object? checkError;
  final _controller =
      StreamController<List<ConnectivityResult>>.broadcast(sync: true);

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      _controller.stream;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async {
    if (checkError != null) throw checkError!;
    return initial;
  }

  void emit(List<ConnectivityResult> results) => _controller.add(results);
}

const _wifi = [ConnectivityResult.wifi];
const _mobile = [ConnectivityResult.mobile];
const _none = [ConnectivityResult.none];

void main() {
  late List<NetworkState> seen;

  ConnectivityNetworkMonitor monitor(_FakeConnectivity c) {
    final m = ConnectivityNetworkMonitor(connectivity: c);
    seen = [];
    m.changes.listen(seen.add);
    return m;
  }

  test('is optimistically online until primed, then learns the interfaces '
      'without announcing a change', () {
    fakeAsync((async) {
      final m = monitor(_FakeConnectivity(_wifi));
      expect(m.current, const NetworkState(online: true, signature: ''));

      async.flushMicrotasks();

      expect(m.current, const NetworkState(online: true, signature: 'wifi'));
      expect(seen, isEmpty, reason: 'startup is not a network change');
    });
  });

  test('starting offline is announced', () {
    fakeAsync((async) {
      final m = monitor(_FakeConnectivity(_none));
      async.flushMicrotasks();

      expect(m.current.online, isFalse);
      expect(seen, [m.current]);
    });
  });

  test('a failing initial check leaves it optimistic and still follows events',
      () {
    fakeAsync((async) {
      final c = _FakeConnectivity(_wifi)..checkError = StateError('platform');
      final m = monitor(c);
      async.flushMicrotasks();
      expect(m.current.online, isTrue);

      c.emit(_none);
      async.elapse(const Duration(milliseconds: 300));
      expect(m.current.online, isFalse);
    });
  });

  test('going offline is announced after the settle time, not before', () {
    fakeAsync((async) {
      final c = _FakeConnectivity(_wifi);
      final m = monitor(c);
      async.flushMicrotasks();

      c.emit(_none);
      async.elapse(const Duration(milliseconds: 299));
      expect(seen, isEmpty);
      expect(m.current.online, isTrue);

      async.elapse(const Duration(milliseconds: 1));
      expect(seen.single.online, isFalse);
      expect(m.current, seen.single);
    });
  });

  test('Wi-Fi to cellular while online is a change', () {
    fakeAsync((async) {
      final c = _FakeConnectivity(_wifi);
      final m = monitor(c);
      async.flushMicrotasks();

      c.emit(_mobile);
      async.elapse(const Duration(milliseconds: 300));

      expect(seen, [const NetworkState(online: true, signature: 'mobile')]);
      expect(m.current.signature, 'mobile');
    });
  });

  test('a switch reported as a burst settles into one announcement', () {
    fakeAsync((async) {
      final c = _FakeConnectivity(_wifi);
      monitor(c);
      async.flushMicrotasks();

      c.emit(_none); // radio drops...
      async.elapse(const Duration(milliseconds: 100));
      c.emit(_mobile); // ...and the new interface comes up
      async.elapse(const Duration(milliseconds: 299));
      expect(seen, isEmpty, reason: 'still settling');
      async.elapse(const Duration(milliseconds: 1));

      expect(seen, [const NetworkState(online: true, signature: 'mobile')],
          reason: 'one change, and never a spurious offline');
    });
  });

  test('a dip that returns to the same interfaces announces nothing', () {
    fakeAsync((async) {
      final c = _FakeConnectivity(_wifi);
      monitor(c);
      async.flushMicrotasks();

      c.emit(_none);
      async.elapse(const Duration(milliseconds: 100));
      c.emit(_wifi);
      async.elapse(const Duration(seconds: 1));

      expect(seen, isEmpty);
    });
  });

  test('repeating the current state announces nothing', () {
    fakeAsync((async) {
      final c = _FakeConnectivity(_wifi);
      monitor(c);
      async.flushMicrotasks();

      c.emit(_wifi);
      async.elapse(const Duration(seconds: 1));

      expect(seen, isEmpty);
    });
  });

  test('the signature is the sorted set of active types, ignoring none', () {
    fakeAsync((async) {
      final c = _FakeConnectivity(_wifi);
      final m = monitor(c);
      async.flushMicrotasks();

      c.emit(const [
        ConnectivityResult.wifi,
        ConnectivityResult.vpn,
        ConnectivityResult.none,
        ConnectivityResult.wifi,
      ]);
      async.elapse(const Duration(milliseconds: 300));
      expect(m.current, const NetworkState(online: true, signature: 'vpn+wifi'));

      c.emit(const [ConnectivityResult.vpn, ConnectivityResult.wifi]);
      async.elapse(const Duration(milliseconds: 300));
      expect(seen, hasLength(1), reason: 'same set in another order');
    });
  });

  test('a change event before priming completes wins over the stale check', () {
    fakeAsync((async) {
      final c = _FakeConnectivity(_wifi);
      final m = monitor(c);

      c.emit(_mobile); // before the checkConnectivity() future resolves
      async.elapse(const Duration(milliseconds: 300));

      expect(m.current.signature, 'mobile');
    });
  });

  test('dispose stops announcements', () {
    fakeAsync((async) {
      final c = _FakeConnectivity(_wifi);
      final m = monitor(c);
      async.flushMicrotasks();

      c.emit(_none);
      m.dispose();
      async.elapse(const Duration(seconds: 1));

      expect(seen, isEmpty);
    });
  });
}
