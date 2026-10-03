import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
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
  bool get supportsFiles => true;

  /// Paths pick the behaviour, so one probe covers the ways files can fail.
  Never _failFor(String path) => switch (path) {
        '/denied' =>
          throw RemoteFileException(RemoteFileErrorKind.permission, 'Permission denied', path: path),
        '/gone' => throw RemoteFileException(RemoteFileErrorKind.notFound, 'No such file', path: path),
        '/flaky' => throw RemoteFileException(RemoteFileErrorKind.network, 'link dropped', path: path),
        '/offline' => throw const HerdrTransportException('network down'),
        '/fatal' => throw const HerdrTransportException('bad key', fatal: true),
        '/die' => Isolate.exit(),
        _ => throw StateError('boom'),
      };

  @override
  Future<RemoteStat> statFile(String path) async {
    if (path.startsWith('/ok')) {
      return RemoteStat(
        path: path,
        kind: RemoteEntryKind.file,
        size: 12345678901,
        modified: DateTime.utc(2026, 1, 2, 3, 4, 5),
        mode: 0x81A4,
      );
    }
    _failFor(path);
  }

  @override
  Future<List<RemoteEntry>> listDirectory(String path) async {
    if (path == '/many') {
      return [
        for (var i = 0; i < 5000; i++)
          RemoteEntry(
            name: 'Tệp $i.txt',
            path: '/many/Tệp $i.txt',
            kind: i % 7 == 0 ? RemoteEntryKind.link : RemoteEntryKind.file,
            resolvedKind: i % 11 == 0 ? null : RemoteEntryKind.file,
            size: i,
            modified: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
            linkTarget: i % 7 == 0 ? '../x' : null,
          ),
      ];
    }
    _failFor(path);
  }

  @override
  Future<Uint8List> readFile(String path, {int offset = 0, int length = remoteReadCap}) async {
    if (path == '/bytes') {
      // Content depends on the position, so a lost or shifted byte shows.
      return Uint8List.fromList([for (var i = 0; i < length; i++) (offset + i) % 251]);
    }
    _failFor(path);
  }

  @override
  Future<String> realPath(String path) async => path == '.' ? '/home/probe' : '/real$path';

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

  group('files', () {
    test('stat comes back typed, with size beyond 32 bits and an exact UTC time', () async {
      t = _transport();

      final s = await t.statFile('/ok');

      expect(s.kind, RemoteEntryKind.file);
      expect(s.size, 12345678901);
      expect(s.modified, DateTime.utc(2026, 1, 2, 3, 4, 5));
      expect(s.modified!.isUtc, isTrue);
      expect(s.mode, 0x81A4);
      expect(t.supportsFiles, isTrue);
    });

    test('a 5,000-entry listing arrives whole with Unicode names and link details', () async {
      t = _transport();

      final entries = await t.listDirectory('/many');

      expect(entries, hasLength(5000));
      expect(entries[4999].name, 'Tệp 4999.txt');
      expect(entries[0].kind, RemoteEntryKind.link);
      expect(entries[0].linkTarget, '../x');
      expect(entries[0].isBrokenLink, isTrue, reason: 'a link with no resolved kind');
      expect(entries[7].kind, RemoteEntryKind.link);
      expect(entries[7].isBrokenLink, isFalse);
      expect(entries[7].isFile, isTrue);
      expect(entries[11].kind, RemoteEntryKind.file);
      expect(entries[11].resolvedKind, isNull, reason: 'null survives the trip');
      expect(entries[77].isBrokenLink, isTrue);
      expect(entries[3].modified, DateTime.utc(2026, 1, 1, 0, 3));
    });

    test('bytes cross intact: every position holds the right value', () async {
      t = _transport();

      final bytes = await t.readFile('/bytes', offset: 250, length: 3 * 1024 * 1024);

      expect(bytes, isA<Uint8List>());
      expect(bytes.length, 3 * 1024 * 1024);
      for (var i = 0; i < bytes.length; i += 4099) {
        expect(bytes[i], (250 + i) % 251, reason: 'byte $i');
      }
      expect(bytes.last, (250 + bytes.length - 1) % 251);
    });

    test('a read never asks the worker for more than the cap', () async {
      t = _transport();

      final bytes = await t.readFile('/bytes', length: 1 << 40);

      expect(bytes.length, remoteReadCap);
    });

    test('realPath is forwarded', () async {
      t = _transport();
      expect(await t.realPath('.'), '/home/probe');
      expect(await t.realPath('/a'), '/real/a');
    });

    test('typed file errors keep their kind, message, path and retryability', () async {
      t = _transport();
      final cases = {
        '/denied': (RemoteFileErrorKind.permission, true),
        '/gone': (RemoteFileErrorKind.notFound, true),
        '/flaky': (RemoteFileErrorKind.network, false),
      };
      for (final MapEntry(key: path, value: (kind, fatal)) in cases.entries) {
        await expectLater(
          t.statFile(path),
          throwsA(isA<RemoteFileException>()
              .having((e) => e.kind, 'kind', kind)
              .having((e) => e.fatal, 'fatal', fatal)
              .having((e) => e.path, 'path', path)),
          reason: path,
        );
      }
      await expectLater(
        t.listDirectory('/denied'),
        throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.permission)),
      );
      await expectLater(
        t.readFile('/gone'),
        throwsA(isA<RemoteFileException>().having((e) => e.message, 'message', 'No such file')),
      );
    });

    test('connection failures stay HerdrTransportExceptions with their fatal flag', () async {
      t = _transport();

      await expectLater(
        t.statFile('/offline'),
        throwsA(isA<HerdrTransportException>().having((e) => e.fatal, 'fatal', isFalse)),
      );
      await expectLater(
        t.listDirectory('/fatal'),
        throwsA(isA<HerdrTransportException>().having((e) => e.fatal, 'fatal', isTrue)),
      );
      await expectLater(t.readFile('/weird'), throwsA(isA<HerdrTransportException>()));
    });

    test('concurrent file calls are matched to their callers', () async {
      t = _transport();

      final results = await Future.wait([
        for (var i = 0; i < 12; i++) t.readFile('/bytes', offset: i * 10, length: 4),
      ]);

      expect([for (final r in results) r.first], [for (var i = 0; i < 12; i++) (i * 10) % 251]);
    });

    test('a worker that dies mid-operation fails the call as retryable, and the next call works', () async {
      t = _transport();
      await t.statFile('/ok');

      await expectLater(
        t.readFile('/die'),
        throwsA(isA<HerdrTransportException>().having((e) => e.fatal, 'fatal', isFalse)),
      );

      expect((await t.statFile('/ok')).size, 12345678901);
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
