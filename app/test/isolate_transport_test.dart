import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/isolate_transport.dart';

import 'support/fake_transport.dart' show eventually;

/// Runs inside the worker isolate: a transport that can fail in every way the
/// network can, and reports what the worker saw.
class _Probe implements HerdrTransport {
  _Probe(this.onPin, this.onNotice);

  final void Function(String) onPin;
  final void Function(String) onNotice;
  var resets = 0;
  var closed = false;
  var liveStreams = 0;

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    switch (method) {
      case 'echo':
        return {'params': params};
      case 'big':
        return {'text': 'x' * 1000000};
      case 'api_error':
        throw const HerdrApiException('pane_not_found', 'no such pane');
      case 'fatal':
        throw const HerdrTransportException('bad key', fatal: true);
      case 'retryable':
        throw const HerdrTransportException('network down');
      case 'weird':
        throw StateError('boom');
      case 'pin':
        onPin('SHA256:abc');
        return {};
      case 'notice':
        onNotice('# Tailscale SSH requires an additional check.\n# To authenticate, visit: https://login.tailscale.com/a/abc');
        return {};
      case 'probe':
        return {'resets': resets, 'liveStreams': liveStreams, 'closed': closed};
      case 'die':
        Isolate.exit();
    }
    throw HerdrApiException('unknown', method);
  }

  @override
  Stream<Map<String, dynamic>> events(List<Map<String, dynamic>> subscriptions) {
    final fails = subscriptions.any((s) => s['type'] == 'fail');
    late final StreamController<Map<String, dynamic>> out;
    Timer? timer;
    var n = 0;
    out = StreamController<Map<String, dynamic>>(
      onListen: () {
        liveStreams++;
        timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
          out.add({'n': n++});
          if (fails && n == 3) {
            out.addError(const HerdrTransportException('channel dropped'));
            out.close();
          }
        });
      },
      onCancel: () {
        liveStreams--;
        timer?.cancel();
      },
    );
    return out.stream;
  }

  @override
  void reset() => resets++;

  @override
  Future<void> close() async => closed = true;
}

HerdrTransport _buildProbe(
  Object? config,
  void Function(String) onPin,
  void Function(String) onNotice,
) {
  if (config == 'throw') throw ArgumentError('invalid session name');
  return _Probe(onPin, onNotice);
}

IsolateTransport _transport({
  Object? config,
  void Function(String)? onPin,
  void Function(String)? onNotice,
}) =>
    IsolateTransport(
      builder: _buildProbe,
      config: config,
      onPin: onPin ?? (_) {},
      onNotice: onNotice,
    );

void main() {
  late IsolateTransport t;
  tearDown(() => t.close());

  test('results cross the isolate with their types intact', () async {
    t = _transport();

    final r = await t.request('echo', {
      'nested': {'list': [1, 'two', {'three': 3.0}]},
    });

    final nested = (r['params'] as Map<String, dynamic>)['nested'] as Map<String, dynamic>;
    expect(nested['list'], [1, 'two', {'three': 3.0}]);
  });

  test('a megabyte of text arrives whole', () async {
    t = _transport();

    final r = await t.request('big');

    expect((r['text'] as String).length, 1000000);
  });

  test('concurrent requests are matched to their own callers', () async {
    t = _transport();

    final results = await Future.wait([
      for (var i = 0; i < 25; i++) t.request('echo', {'i': i}),
    ]);

    expect([for (final r in results) (r['params'] as Map)['i']],
        [for (var i = 0; i < 25; i++) i]);
  });

  group('errors keep their meaning', () {
    setUp(() => t = _transport());

    test('API errors stay API errors with code and message', () async {
      await expectLater(
        t.request('api_error'),
        throwsA(isA<HerdrApiException>()
            .having((e) => e.code, 'code', 'pane_not_found')
            .having((e) => e.message, 'message', 'no such pane')),
      );
    });

    test('fatal transport errors stay fatal', () async {
      await expectLater(
        t.request('fatal'),
        throwsA(isA<HerdrTransportException>()
            .having((e) => e.fatal, 'fatal', isTrue)
            .having((e) => e.message, 'message', 'bad key')),
      );
    });

    test('retryable transport errors stay retryable', () async {
      await expectLater(
        t.request('retryable'),
        throwsA(isA<HerdrTransportException>().having((e) => e.fatal, 'fatal', isFalse)),
      );
    });

    test('an unexpected exception becomes a retryable transport error', () async {
      await expectLater(
        t.request('weird'),
        throwsA(isA<HerdrTransportException>()
            .having((e) => e.fatal, 'fatal', isFalse)
            .having((e) => e.message, 'message', contains('boom'))),
      );
    });

    test('an error does not poison the worker', () async {
      await expectLater(t.request('fatal'), throwsA(anything));
      expect((await t.request('echo', {'ok': true}))['params'], {'ok': true});
    });
  });

  test('a host key trusted in the worker is reported to the main isolate', () async {
    final pins = <String>[];
    t = _transport(onPin: pins.add);

    await t.request('pin');
    await eventually(() => pins.isNotEmpty, reason: 'pin delivered');

    expect(pins, ['SHA256:abc']);
  });

  test('a login banner shown in the worker reaches the main isolate', () async {
    final notices = <String>[];
    t = _transport(onNotice: notices.add);

    await t.request('notice');
    await eventually(() => notices.isNotEmpty, reason: 'banner delivered');

    expect(notices.single, contains('https://login.tailscale.com/a/abc'));
  });

  group('events', () {
    setUp(() => t = _transport());

    test('are forwarded in order', () async {
      final got = await t.events(const [{'type': 'x'}]).take(3).toList();

      expect([for (final e in got) e['n']], [0, 1, 2]);
    });

    test('cancelling releases the stream inside the worker', () async {
      final sub = t.events(const [{'type': 'x'}]).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect((await t.request('probe'))['liveStreams'], 1);

      await sub.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect((await t.request('probe'))['liveStreams'], 0);
    });

    test('a channel error reaches the listener, then the stream ends', () async {
      final seen = <Object>[];
      final done = Completer<void>();
      t.events(const [{'type': 'fail'}]).listen(
        (_) {},
        onError: seen.add,
        onDone: done.complete,
      );

      await done.future.timeout(const Duration(seconds: 5));

      expect(seen.single, isA<HerdrTransportException>()
          .having((e) => e.message, 'message', 'channel dropped'));
    });
  });

  test('reset reaches the transport inside the worker', () async {
    t = _transport();
    await t.request('echo');

    t.reset();

    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect((await t.request('probe'))['resets'], 1);
  });

  group('when the worker dies', () {
    test('the request in flight fails as retryable', () async {
      t = _transport();
      await t.request('echo');

      await expectLater(
        t.request('die'),
        throwsA(isA<HerdrTransportException>().having((e) => e.fatal, 'fatal', isFalse)),
      );
    });

    test('the next request starts a fresh worker', () async {
      t = _transport();
      await t.request('echo');
      t.reset();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect((await t.request('probe'))['resets'], 1);
      await expectLater(t.request('die'), throwsA(anything));

      final after = await t.request('probe');

      expect(after['resets'], 0, reason: 'state of the old worker is gone');
    });

    test('an open event stream is told', () async {
      t = _transport();
      final errors = <Object>[];
      final done = Completer<void>();
      t.events(const [{'type': 'x'}]).listen((_) {}, onError: errors.add, onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      await expectLater(t.request('die'), throwsA(anything));
      await done.future.timeout(const Duration(seconds: 5));

      expect(errors.single, isA<HerdrTransportException>()
          .having((e) => e.fatal, 'fatal', isFalse));
    });
  });

  group('building the transport fails', () {
    test('is a fatal error carrying the reason, and is retried next time', () async {
      t = _transport(config: 'throw');

      for (var i = 0; i < 2; i++) {
        await expectLater(
          t.request('echo'),
          throwsA(isA<HerdrTransportException>()
              .having((e) => e.fatal, 'fatal', isTrue)
              .having((e) => e.message, 'message', contains('invalid session name'))),
        );
      }
    });

    test('an event stream reports it too', () async {
      t = _transport(config: 'throw');

      await expectLater(t.events(const [{'type': 'x'}]).first, throwsA(isA<HerdrTransportException>()));
    });
  });

  test('close is final and stops the worker', () async {
    t = _transport();
    await t.request('echo');

    await t.close();

    await expectLater(
      t.request('echo'),
      throwsA(isA<HerdrTransportException>()
          .having((e) => e.message, 'message', 'Transport closed')),
    );
  });

  test('closing a transport that never started is harmless', () async {
    t = _transport();

    await t.close();
    await t.close();
  });
}
