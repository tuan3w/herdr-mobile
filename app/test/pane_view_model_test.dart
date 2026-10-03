import 'dart:async';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/features/pane/pane_view_model.dart';

const _pane = 'w1:p1';

Duration _ms(int ms) => Duration(milliseconds: ms);

/// Scriptable read/send functions and an activity stream, on a [FakeAsync]
/// clock so every timestamp is exact.
class _Fake {
  _Fake(this.async);

  final FakeAsync async;
  final activity = StreamController<String>.broadcast();

  String text = 'one';
  Duration latency = Duration.zero;
  Object? readFailure;
  Object? sendFailure;

  /// Elapsed time at the start of each read.
  final reads = <Duration>[];
  final sent = <String>[];
  var running = 0;
  var maxRunning = 0;

  Future<PaneRead> read() async {
    reads.add(async.elapsed);
    running++;
    maxRunning = max(maxRunning, running);
    try {
      if (latency > Duration.zero) await Future<void>.delayed(latency);
      final failure = readFailure;
      if (failure != null) throw failure;
      return PaneRead(text: text, truncated: false);
    } finally {
      running--;
    }
  }

  Future<void> _send(String what) async {
    final failure = sendFailure;
    if (failure != null) throw failure;
    sent.add(what);
  }

  PaneViewModel vm({
    Duration minReadInterval = const Duration(milliseconds: 120),
    Duration fallbackInterval = const Duration(seconds: 4),
  }) =>
      PaneViewModel(
        activity: activity.stream,
        paneId: _pane,
        read: read,
        sendLine: _send,
        sendKeys: (keys) => _send(keys.join('+')),
        minReadInterval: minReadInterval,
        fallbackInterval: fallbackInterval,
      );

  /// Emits [count] events for the pane, one every [every].
  void flood(int count, Duration every) {
    for (var i = 0; i < count; i++) {
      activity.add(_pane);
      async.elapse(every);
    }
  }
}

void _scenario(
  String name,
  void Function(FakeAsync async, _Fake fake) body,
) =>
    test(name, () => fakeAsync((async) => body(async, _Fake(async))));

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  group('reads', () {
    _scenario('the first read happens immediately', (async, f) {
      final vm = f.vm();
      async.flushMicrotasks();

      expect(f.reads, [Duration.zero]);
      expect(vm.text, 'one');
      expect(vm.isStale, isFalse);
      vm.dispose();
    });

    _scenario('activity after the cooldown reads on the leading edge', (async, f) {
      final vm = f.vm();
      async.elapse(_ms(200));
      f.text = 'two';

      f.activity.add(_pane);
      async.flushMicrotasks();

      expect(f.reads, hasLength(2));
      expect(f.reads.last, _ms(200), reason: 'no waiting for a timer');
      expect(vm.text, 'two');
      vm.dispose();
    });

    _scenario('other panes\' activity is ignored', (async, f) {
      final vm = f.vm();
      async.elapse(_ms(200));

      f.activity
        ..add('w1:p2')
        ..add('w2:p1')
        ..add('');
      async.elapse(_ms(1000));

      expect(f.reads, hasLength(1));
      vm.dispose();
    });

    _scenario('a burst at one instant costs one leading and one trailing read',
        (async, f) {
      final vm = f.vm();
      async.elapse(_ms(200));

      for (var i = 0; i < 100; i++) {
        f.activity.add(_pane);
      }
      async.elapse(_ms(500));

      expect(f.reads, [Duration.zero, _ms(200), _ms(320)]);
      vm.dispose();
    });

    _scenario('a flood is throttled, not debounced', (async, f) {
      final vm = f.vm();
      async.elapse(_ms(200));
      final before = f.reads.length;

      f.flood(100, _ms(10)); // events keep coming for a full second
      final lastEvent = async.elapsed - _ms(10);
      final duringFlood = f.reads.where((t) => t < lastEvent).length - before;
      async.elapse(_ms(500));

      // A debounce would have read nothing until the flood ended.
      expect(duringFlood, greaterThanOrEqualTo(7));
      expect(f.reads.length - before, inInclusiveRange(9, 11),
          reason: '~one per 120 ms, not one per event');
      for (var i = 1; i < f.reads.length; i++) {
        expect(f.reads[i] - f.reads[i - 1], greaterThanOrEqualTo(_ms(120)),
            reason: 'read $i');
      }
      expect(f.reads.last, greaterThanOrEqualTo(lastEvent),
          reason: 'one trailing read after the last event');

      final settled = f.reads.length;
      async.elapse(_ms(2000));
      expect(f.reads, hasLength(settled), reason: 'nothing more until the poll');
      vm.dispose();
    });

    _scenario('reads never overlap, and the trailing read is coalesced', (async, f) {
      f.latency = _ms(300);
      final vm = f.vm();
      async.elapse(_ms(400));
      f.flood(200, _ms(10));
      async.elapse(_ms(2000));

      expect(f.maxRunning, 1);
      // Two seconds of events at 300 ms per read: one read at a time, back to
      // back, never a queue of pending ones.
      for (var i = 1; i < f.reads.length; i++) {
        expect(f.reads[i] - f.reads[i - 1], greaterThanOrEqualTo(_ms(300)));
      }
      expect(f.reads.length, lessThanOrEqualTo(10));
      vm.dispose();
    });

    _scenario('a read slower than the interval still fires the trailing read at once',
        (async, f) {
      f.latency = _ms(300);
      final vm = f.vm();
      async.elapse(_ms(400)); // initial read done
      f.activity.add(_pane);
      async.elapse(_ms(100)); // second read in flight
      f.activity.add(_pane);
      async.elapse(_ms(1)); // pending, read still running

      expect(f.reads, [Duration.zero, _ms(400)]);
      async.elapse(_ms(199)); // second read finishes at 700
      expect(f.reads, [Duration.zero, _ms(400), _ms(700)]);
      vm.dispose();
    });

    _scenario('polls every 4 s when no events arrive', (async, f) {
      final vm = f.vm();
      async.elapse(const Duration(seconds: 12));

      expect(f.reads, [
        Duration.zero,
        const Duration(seconds: 4),
        const Duration(seconds: 8),
        const Duration(seconds: 12),
      ]);
      vm.dispose();
    });

    _scenario('the poll counts from the last read, not from the start', (async, f) {
      final vm = f.vm();
      async.elapse(_ms(3900));
      f.activity.add(_pane);
      async.elapse(_ms(200)); // 4100: the old poll time has passed

      expect(f.reads, hasLength(2));
      async.elapse(_ms(3700)); // 7800
      expect(f.reads, hasLength(2));
      async.elapse(_ms(100)); // 7900 = 3900 + 4 s
      expect(f.reads, hasLength(3));
      vm.dispose();
    });
  });

  group('lifecycle', () {
    _scenario('nothing is read while the app is not resumed', (async, f) {
      final vm = f.vm();
      async.elapse(_ms(200));

      vm.didChangeAppLifecycleState(AppLifecycleState.paused);
      f.flood(50, _ms(10));
      async.elapse(const Duration(minutes: 1));

      expect(f.reads, hasLength(1));
      expect(async.pendingTimers, isEmpty);
      vm.dispose();
    });

    _scenario('resuming reads immediately, once, and polling restarts', (async, f) {
      final vm = f.vm();
      async.elapse(_ms(200));
      vm.didChangeAppLifecycleState(AppLifecycleState.paused);
      f.flood(50, _ms(10));
      async.elapse(const Duration(seconds: 30));
      final resumedAt = async.elapsed;
      f.text = 'later';

      vm.didChangeAppLifecycleState(AppLifecycleState.resumed);
      async.flushMicrotasks();

      expect(f.reads, [Duration.zero, resumedAt],
          reason: 'events during the pause are not replayed');
      expect(vm.text, 'later');
      async.elapse(const Duration(seconds: 4));
      expect(f.reads, hasLength(3));
      vm.dispose();
    });

    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      _scenario('$state pauses reads', (async, f) {
        final vm = f.vm();
        async.elapse(_ms(200));
        vm.didChangeAppLifecycleState(state);
        async.elapse(const Duration(seconds: 20));
        expect(f.reads, hasLength(1));
        vm.dispose();
      });
    }

    _scenario('a read in flight when the app pauses still lands, then stays quiet',
        (async, f) {
      f.latency = _ms(100);
      final vm = f.vm();
      async.elapse(_ms(10));

      vm.didChangeAppLifecycleState(AppLifecycleState.paused);
      f.text = 'landed';
      async.elapse(const Duration(seconds: 30));

      expect(f.reads, hasLength(1));
      expect(vm.text, 'landed');
      expect(async.pendingTimers, isEmpty);
      vm.dispose();
    });

    _scenario('resuming during a read queues exactly one follow-up', (async, f) {
      f.latency = _ms(100);
      final vm = f.vm();
      async.elapse(_ms(10));
      vm.didChangeAppLifecycleState(AppLifecycleState.paused);
      async.elapse(_ms(10));

      vm.didChangeAppLifecycleState(AppLifecycleState.resumed);
      vm.didChangeAppLifecycleState(AppLifecycleState.inactive);
      vm.didChangeAppLifecycleState(AppLifecycleState.resumed);
      async.elapse(_ms(500));

      expect(f.maxRunning, 1);
      expect(f.reads, hasLength(2));
      vm.dispose();
    });

    test('follows the binding\'s lifecycle and unregisters on dispose', () {
      fakeAsync((async) {
        final f = _Fake(async);
        final vm = f.vm();
        async.elapse(_ms(200));

        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        async.elapse(const Duration(seconds: 20));
        expect(f.reads, hasLength(1));

        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        async.flushMicrotasks();
        expect(f.reads, hasLength(2));

        vm.dispose();
        async.elapse(const Duration(seconds: 20));
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        async.elapse(const Duration(seconds: 20));
        expect(f.reads, hasLength(2));
      });
    });
  });

  group('state', () {
    _scenario('identical text does not notify', (async, f) {
      final vm = f.vm();
      var notifications = 0;
      vm.addListener(() => notifications++);
      async.elapse(_ms(200));
      expect(notifications, 1, reason: 'first text');

      f.flood(5, _ms(150));
      async.elapse(const Duration(seconds: 10));
      expect(f.reads.length, greaterThan(5));
      expect(notifications, 1, reason: 'same text, same state');

      f.text = 'two';
      f.activity.add(_pane);
      async.flushMicrotasks();
      expect(notifications, 2);
      expect(vm.text, 'two');
      vm.dispose();
    });

    _scenario('a failed read keeps the text, marks it stale, and recovers', (async, f) {
      final vm = f.vm();
      var notifications = 0;
      vm.addListener(() => notifications++);
      async.elapse(_ms(200));
      expect(vm.isStale, isFalse);
      expect(notifications, 1);

      f.readFailure = const HerdrTransportException('connection lost');
      f.activity.add(_pane);
      async.elapse(_ms(200));
      expect(vm.text, 'one');
      expect(vm.error, 'connection lost');
      expect(vm.isStale, isTrue);
      expect(notifications, 2);

      f.activity.add(_pane);
      async.elapse(_ms(200));
      expect(notifications, 2, reason: 'the same failure again is not news');

      f.readFailure = null;
      f.text = 'two';
      f.activity.add(_pane);
      async.elapse(_ms(200));
      expect(vm.error, isNull);
      expect(vm.isStale, isFalse);
      expect(vm.text, 'two');
      expect(notifications, 3);
      vm.dispose();
    });

    _scenario('an API error is stale with its code', (async, f) {
      f.readFailure = const HerdrApiException('pane_not_found', 'no such pane');
      final vm = f.vm();
      async.flushMicrotasks();

      expect(vm.error, 'pane_not_found: no such pane');
      expect(vm.isStale, isTrue);
      vm.dispose();
    });

    _scenario('a fatal failure stops all reading until refresh()', (async, f) {
      f.readFailure = const HerdrTransportException('bad key', fatal: true);
      final vm = f.vm();
      async.elapse(_ms(200));

      f.flood(20, _ms(150));
      async.elapse(const Duration(minutes: 1));
      expect(f.reads, hasLength(1));
      expect(async.pendingTimers, isEmpty);

      f.readFailure = null;
      vm.refresh();
      async.flushMicrotasks();
      expect(f.reads, hasLength(2));
      expect(vm.error, isNull);
      async.elapse(const Duration(seconds: 4));
      expect(f.reads, hasLength(3), reason: 'polling is back');
      vm.dispose();
    });

    _scenario('a non-fatal failure keeps polling', (async, f) {
      f.readFailure = const HerdrTransportException('timeout');
      final vm = f.vm();
      async.elapse(const Duration(seconds: 9));

      expect(f.reads, hasLength(3));
      vm.dispose();
    });
  });

  group('sending', () {
    _scenario('sendLine reads right away instead of waiting for an event', (async, f) {
      final vm = f.vm();
      async.elapse(_ms(500));
      f.text = 'echo';

      bool? ok;
      vm.sendLine('hello').then((v) => ok = v);
      async.flushMicrotasks();

      expect(ok, isTrue);
      expect(f.sent, ['hello']);
      expect(f.reads, hasLength(2));
      expect(f.reads.last, _ms(500));
      expect(vm.text, 'echo');
      expect(vm.sending, isFalse);
      vm.dispose();
    });

    _scenario('sendKeys reads right away too', (async, f) {
      final vm = f.vm();
      async.elapse(_ms(500));

      bool? ok;
      vm.sendKeys(const ['ctrl+c', 'enter']).then((v) => ok = v);
      async.flushMicrotasks();

      expect(ok, isTrue);
      expect(f.sent, ['ctrl+c+enter']);
      expect(f.reads, hasLength(2));
      vm.dispose();
    });

    _scenario('a send during a read is followed by another read', (async, f) {
      f.latency = _ms(100);
      final vm = f.vm();
      async.elapse(_ms(50)); // first read still running

      vm.sendLine('hi');
      async.elapse(_ms(500));

      expect(f.maxRunning, 1);
      expect(f.reads, hasLength(2),
          reason: 'the first read may predate the send');
      expect(f.reads.last, greaterThanOrEqualTo(_ms(100)));
      vm.dispose();
    });

    _scenario('sending is visible while in flight', (async, f) {
      final vm = f.vm();
      final seen = <bool>[];
      vm.addListener(() => seen.add(vm.sending));
      async.elapse(_ms(500));
      seen.clear();

      vm.sendLine('x');
      expect(seen, [true]);
      async.flushMicrotasks();
      expect(seen.last, isFalse);
      vm.dispose();
    });

    _scenario('a failed send reports the error and does not read', (async, f) {
      final vm = f.vm();
      async.elapse(_ms(500));
      f.sendFailure = const HerdrTransportException('write failed');

      bool? ok;
      vm.sendLine('hello').then((v) => ok = v);
      async.flushMicrotasks();

      expect(ok, isFalse);
      expect(vm.error, 'write failed');
      expect(vm.sending, isFalse);
      expect(f.reads, hasLength(1));
      vm.dispose();
    });

    _scenario('a failed send with an API error carries the code', (async, f) {
      final vm = f.vm();
      async.elapse(_ms(500));
      f.sendFailure = const HerdrApiException('pane_closed', 'gone');

      vm.sendKeys(const ['esc']);
      async.flushMicrotasks();

      expect(vm.error, 'pane_closed: gone');
      vm.dispose();
    });
  });

  group('dispose', () {
    _scenario('leaves no timers, no listener, and no further reads', (async, f) {
      final vm = f.vm();
      async.elapse(_ms(50)); // mid-cooldown, fallback armed
      f.activity.add(_pane); // pending trailing read

      vm.dispose();

      expect(async.pendingTimers, isEmpty);
      expect(f.activity.hasListener, isFalse);
      f.flood(20, _ms(50));
      async.elapse(const Duration(minutes: 1));
      expect(f.reads, hasLength(1));
    });

    _scenario('a read finishing after dispose is dropped quietly', (async, f) {
      f.latency = _ms(100);
      final vm = f.vm();
      async.elapse(_ms(10));

      vm.dispose();
      async.elapse(const Duration(seconds: 10));

      expect(f.reads, hasLength(1));
      expect(async.pendingTimers, isEmpty);
    });

    _scenario('a send finishing after dispose does not notify or read', (async, f) {
      final vm = f.vm();
      async.elapse(_ms(500));

      vm.sendLine('x');
      vm.dispose();
      async.elapse(const Duration(seconds: 10));

      expect(f.reads, hasLength(1));
      expect(async.pendingTimers, isEmpty);
    });
  });
}
