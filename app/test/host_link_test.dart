import 'dart:async';
import 'dart:convert';
import 'dart:io' show RawZLibFilter;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/host/host_channels.dart';
import 'package:herdr_mobile/data/host/host_link.dart';
import 'package:herdr_mobile/data/host/wire.dart';
import 'package:herdr_mobile/data/services/bridge_command.dart' show muxReadyLine;
import 'package:herdr_mobile/data/services/mux_client.dart';

import 'support/fake_host.dart';

// HostLink against a host played by the test: what the client writes, what it
// does with what the host writes. The real `herdr-host serve` is run by
// host_serve_test.dart.

Future<HostLink> connected(FakeHost host, {Map<String, Map<String, Object?>>? services, int window = 1 << 20}) async {
  final link = HostLink.connect(host, version: '0.1.68', helloTimeout: const Duration(seconds: 5));
  host.greet(services: services, window: window);
  return link;
}

void main() {
  group('connecting', () {
    test('says hello first, skips what a login shell printed, and reads the host\'s answer', () async {
      final host = FakeHost();
      final link = HostLink.connect(host, version: '0.1.68', herdrSession: 'work', herdrSocket: '/tmp/h.sock');
      host.sendBytes(utf8.encode('Last login: yesterday\r\n'));
      host.greet(
        services: {
          'herdr': {'available': true, 'reason': null, 'socket': '/tmp/h.sock'},
          'ports': {'available': false, 'reason': 'no lsof'},
        },
      );
      final l = await link;
      expect(l.hello.version, '9.9.9');
      expect(l.hello.home, '/home/u');
      expect(l.hello.limits.window, 1 << 20);
      expect(l.hello.has('herdr'), isTrue);
      expect(l.hello.services['herdr']!.extra['socket'], '/tmp/h.sock');
      expect(l.hello.has('ports'), isFalse);
      expect(l.hello.services['ports']!.reason, 'no lsof');
      final hello = host.received.first;
      expect(hello.kind, FrameKind.hello);
      expect(jsonDecode(utf8.decode(hello.payload)), {
        'proto': 1,
        'client': {'name': 'herdr-mobile', 'version': '0.1.68'},
        'herdr': {'session': 'work', 'socket': '/tmp/h.sock'},
      });
    });

    test('exit 65 means the helper is not installed, with what the command said', () async {
      final host = FakeHost();
      final link = expectLater(
        HostLink.connect(host, version: '1'),
        throwsA(isA<HostMissing>().having((e) => e.message, 'message', contains('not installed'))),
      );
      host.writeStderr('herdr-mobile: the keeper is not installed on this host\n');
      host.exit(65);
      await link;
    });

    test('another exit is a failure that carries stderr, and a dropped link is a lost link', () async {
      var host = FakeHost();
      var link = expectLater(
        HostLink.connect(host, version: '1'),
        throwsA(
          isA<HostException>()
              .having((e) => e.code, 'code', 'failed')
              .having((e) => e.message, 'message', contains('exec format error')),
        ),
      );
      host.writeStderr('exec format error\n');
      host.exit(126);
      await link;

      host = FakeHost();
      link = expectLater(HostLink.connect(host, version: '1'), throwsA(isA<HostLinkLost>()));
      host.exit(null);
      await link;
    });

    test('silence is a retryable timeout and the channel is closed', () async {
      final host = FakeHost();
      await expectLater(
        HostLink.connect(host, version: '1', helloTimeout: const Duration(milliseconds: 50)),
        throwsA(
          isA<HostException>().having((e) => e.code, 'code', 'timeout').having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
      expect(host.closedByClient, isTrue);
    });

    test('a protocol refusal from the host reaches the caller with its code', () async {
      final host = FakeHost();
      final link = expectLater(
        HostLink.connect(host, version: '1'),
        throwsA(
          isA<HostException>()
              .having((e) => e.code, 'code', 'proto_mismatch')
              .having((e) => e.message, 'message', contains('hostwire/2')),
        ),
      );
      host.sendBytes(hostMagic);
      host.sendJson(FrameKind.end, 0, {
        'error': {'code': 'proto_mismatch', 'message': 'this host speaks hostwire/2', 'retryable': false},
      });
      await link;
    });

    test('output that is not frames fails with what it was', () async {
      final host = FakeHost();
      final link = expectLater(HostLink.connect(host, version: '1'), throwsA(isA<HostException>()));
      host.sendBytes(hostMagic);
      host.sendBytes([0xFF, 0xFF, 0xFF, 0xFF, 1, 0, 0, 0, 0]);
      await link;
    });
  });

  group('calls and streams', () {
    test('a call opens an odd stream, returns the one result and survives an error on the next', () async {
      final host = FakeHost();
      final link = await connected(host);
      host.onFrame = (f) {
        if (f.kind != FrameKind.open) return;
        final open = jsonDecode(utf8.decode(f.payload)) as Map;
        if (open['method'] == 'stat') {
          host.sendJson(FrameKind.msg, f.stream, {'kind': 'file', 'size': 3});
          host.sendJson(FrameKind.end, f.stream, {});
        } else {
          host.sendJson(FrameKind.end, f.stream, {
            'error': {'code': 'not_found', 'message': 'no such file', 'retryable': false},
          });
        }
      };
      expect(await link.call('fs', 'stat', {'path': '/a'}), {'kind': 'file', 'size': 3});
      await expectLater(
        link.call('fs', 'other', {'path': '/b'}),
        throwsA(
          isA<HostException>()
              .having((e) => e.code, 'code', 'not_found')
              .having((e) => e.message, 'message', 'no such file'),
        ),
      );
      expect(host.opens.map((o) => o['stream']), [1, 3]);
      expect(host.opens.first, {
        'svc': 'fs',
        'method': 'stat',
        'args': {'path': '/a'},
        'zctx': false,
        'stream': 1,
      });
    });

    test('a call that is never answered times out, tells the host to stop and says it can be retried', () async {
      final host = FakeHost();
      final link = await connected(host);
      await expectLater(
        link.call('fs', 'stat', const {}, const Duration(milliseconds: 50)),
        throwsA(
          isA<HostException>().having((e) => e.code, 'code', 'timeout').having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
      expect(host.received.last.kind, FrameKind.reset);
    });

    test('messages arrive in order, as text and as JSON, and END ends them', () async {
      final host = FakeHost();
      final link = await connected(host);
      final s = link.open('herdr', 'events', const {}, true);
      final got = <String>[];
      final done = s.texts.listen(got.add).asFuture<void>();
      for (var i = 0; i < 3; i++) {
        host.sendJson(FrameKind.msg, s.id, {'i': i});
      }
      host.sendJson(FrameKind.end, s.id, {});
      await done;
      expect(got, ['{"i":0}', '{"i":1}', '{"i":2}']);
      expect((await s.done).error, isNull);
      expect(host.opens.single['zctx'], isTrue);
    });

    test('a zctx stream inflates the pieces of its one zlib stream, and a deflate frame stands alone', () async {
      final host = FakeHost();
      final link = await connected(host);
      final s = link.open('herdr', 'events', const {}, true);
      final got = <String>[];
      s.texts.listen(got.add);
      final tx = ZLibEncoder6();
      for (final text in ['{"event":"pane.updated","n":1}', '{"event":"pane.updated","n":2}']) {
        host.send(Frame(FrameKind.msg, s.id, tx.piece(utf8.encode(text)), flags: FrameFlags.deflateCtx));
      }
      host.send(Frame(FrameKind.msg, s.id, deflate(utf8.encode('{"alone":true}')), flags: FrameFlags.deflate));
      await until(() => got.length == 3);
      expect(got, ['{"event":"pane.updated","n":1}', '{"event":"pane.updated","n":2}', '{"alone":true}']);
    });

    test('frames for a stream that has ended are ignored', () async {
      final host = FakeHost();
      final link = await connected(host);
      final s = link.open('fs', 'read');
      host.sendJson(FrameKind.end, s.id, {});
      await s.done;
      host.sendJson(FrameKind.msg, s.id, {'late': true});
      host.send(Frame.credit(s.id, 10));
      host.send(Frame.credit(99, 10));
      expect(link.isOpen, isTrue);
      expect(
        await link.call('fs', 'x').timeout(const Duration(milliseconds: 50), onTimeout: () => 'still open'),
        'still open',
      );
    });

    test('a reset from the host fails the stream with its code; ours tells the host and stops delivery', () async {
      final host = FakeHost();
      final link = await connected(host);
      final a = link.open('fs', 'read');
      host.sendJson(FrameKind.reset, a.id, {'code': 'stalled', 'message': 'you stopped reading', 'retryable': true});
      final end = await a.done;
      expect(end.error!.code, 'stalled');
      expect(end.error!.retryable, isTrue);

      final b = link.open('fs', 'read');
      b.reset();
      expect((await b.done).error!.code, 'cancelled');
      await until(() => host.received.last.kind == FrameKind.reset);
      expect(host.received.last.stream, b.id);
    });
  });

  group('flow control', () {
    test('the host is given credit back as messages are delivered, in steps of half a window', () async {
      final host = FakeHost();
      final link = await connected(host, window: 100000);
      final s = link.open('herdr', 'events');
      final got = <String>[];
      s.texts.listen(got.add);
      final body = jsonEncode({'pad': 'x' * 9990});
      for (var i = 0; i < 12; i++) {
        host.send(Frame(FrameKind.msg, s.id, Uint8List.fromList(utf8.encode(body))));
      }
      await until(() => got.length == 12);
      final bytes = utf8.encode(body).length;
      // 12 messages consumed: credit goes back whenever half the window is due.
      expect(host.creditedOn(s.id), greaterThanOrEqualTo(50000));
      expect(host.creditedOn(s.id), lessThanOrEqualTo(12 * bytes));
      expect(host.creditedOn(s.id) % bytes, 0, reason: 'credit is the sum of whole messages');
    });

    test('data is credited when it is read, so a reader that does not read holds the host back', () async {
      final host = FakeHost();
      final link = await connected(host, window: 65536);
      final s = link.open('fs', 'read');
      for (var i = 0; i < 4; i++) {
        host.send(Frame(FrameKind.data, s.id, Uint8List(16384)));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(host.creditedOn(s.id), 0, reason: 'nothing was read');
      expect((await s.read())!.length, 16384);
      expect((await s.read())!.length, 16384);
      expect(host.creditedOn(s.id), 32768);
      // A read that waits is answered by the next chunk.
      await s.read();
      await s.read();
      final waiting = s.read();
      host.send(Frame(FrameKind.data, s.id, Uint8List(10)));
      expect((await waiting)!.length, 10);
      host.sendJson(FrameKind.end, s.id, {});
      expect(await s.read(), isNull);
    });

    test('writing stops when the host\'s credit is used up and goes on when it grants more', () async {
      final host = FakeHost();
      final link = await connected(host, window: 65536);
      final s = link.open('transfer', 'put');
      var written = false;
      final w = s.write(Uint8List(3 * 32768)).then((_) => written = true);
      await until(() => host.received.where((f) => f.kind == FrameKind.data).length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(written, isFalse);
      expect(host.received.where((f) => f.kind == FrameKind.data).length, 2, reason: 'a window is 64 KiB');
      host.send(Frame.credit(s.id, 32768));
      await w;
      expect(written, isTrue);
      await until(() => host.received.where((f) => f.kind == FrameKind.data).length == 3, what: 'the third frame');
      expect(host.received.where((f) => f.kind == FrameKind.data).fold(0, (n, f) => n + f.payload.length), 3 * 32768);
      expect(host.received.where((f) => f.kind == FrameKind.data).every((f) => f.payload.length <= maxData), isTrue);
    });

    test('a write that is waiting for credit fails when the stream is reset', () async {
      final host = FakeHost();
      final link = await connected(host, window: 32768);
      final s = link.open('transfer', 'put');
      final w = expectLater(
        s.write(Uint8List(100000)),
        throwsA(isA<HostException>().having((e) => e.code, 'code', 'cancelled')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      host.sendJson(FrameKind.reset, s.id, {'code': 'changed', 'message': 'the file changed'});
      await w;
    });
  });

  group('when the link dies', () {
    test('every open stream ends with a lost link, the link reports closed, and nothing opens afterwards', () async {
      final host = FakeHost();
      final link = await connected(host);
      final a = link.open('herdr', 'events');
      final errors = <Object>[];
      a.texts.listen((_) {}, onError: errors.add);
      final b = link.open('fs', 'read');
      host.exit(null);
      await link.closed;
      expect((await a.done).error, isA<HostLinkLost>());
      expect((await b.done).error!.retryable, isTrue);
      expect(errors.single, isA<HostLinkLost>());
      expect(link.isOpen, isFalse);
      expect(() => link.open('fs', 'stat'), throwsA(isA<HostLinkLost>()));
      expect(await b.read(), isNull);
    });

    test('closing the link closes the channel and ends its streams', () async {
      final host = FakeHost();
      final link = await connected(host);
      final a = link.open('herdr', 'events');
      a.texts.listen((_) {}, onError: (Object _) {});
      await link.close();
      expect(host.closedByClient, isTrue);
      expect((await a.done).error, isNotNull);
    });
  });

  group('what the client sends', () {
    test('on a zctx stream is one zlib stream: later requests of the same shape cost a fraction', () async {
      final host = FakeHost();
      final link = await connected(host);
      final s = link.open('herdr', 'mux', const {}, true);
      final requests = [
        for (var i = 0; i < 20; i++)
          '{"id":"m$i","method":"pane.read","params":{"pane_id":"w1:p1","lines":300},"mux_have":${1000 + i}}',
      ];
      for (final r in requests) {
        await s.sendText(r);
      }
      await until(() => host.received.where((f) => f.kind == FrameKind.msg).length == requests.length);
      final frames = host.received.where((f) => f.kind == FrameKind.msg).toList();
      expect(frames.every((f) => f.flags == FrameFlags.deflateCtx), isTrue);
      // The host inflates the pieces in order, with one inflater, and gets the requests back.
      final inflater = Inflater();
      expect([for (final f in frames) utf8.decode(inflater.inflate(f.payload))], requests);
      final plain = requests.fold(0, (n, r) => n + utf8.encode(r).length);
      final wire = frames.fold(0, (n, f) => n + f.payload.length);
      expect(
        wire * 3,
        lessThan(plain),
        reason: 'a stream that remembers the last request should cost under a third: $wire of $plain bytes',
      );
    });

    test('on a plain stream is not compressed', () async {
      final host = FakeHost();
      final link = await connected(host);
      final s = link.open('fs', 'stat');
      await s.sendText('{"path":"/a/long/enough/path/to/be/worth/a/second/look/but/this/stream/is/plain/${'x' * 80}"}');
      await until(() => host.received.any((f) => f.kind == FrameKind.msg));
      expect(host.received.firstWhere((f) => f.kind == FrameKind.msg).flags, FrameFlags.none);
    });

    test('goes out in the order it was sent, even when an earlier send had to wait for credit', () async {
      final host = FakeHost();
      final link = await connected(host, window: 40000);
      final s = link.open('keeper', 'attach');
      // 60000 bytes cannot all go at once (window 40000: the first 32 KiB frame
      // fits, the second does not); a one-line send that follows must not
      // overtake the rest of it, though 5 bytes would fit what is left.
      final big = Uint8List(60000);
      for (var i = 0; i < big.length; i++) {
        big[i] = 0x61 + i % 26;
      }
      final first = s.write(big);
      final second = s.write(Uint8List.fromList(utf8.encode('last\n')));
      await until(() => host.received.where((f) => f.kind == FrameKind.data).isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(host.received.where((f) => f.kind == FrameKind.data).fold(0, (n, f) => n + f.payload.length), maxData);
      host.send(Frame.credit(s.id, 40000));
      await Future.wait([first, second]);
      await until(
        () => host.received.where((f) => f.kind == FrameKind.data).fold(0, (n, f) => n + f.payload.length) == 60005,
      );
      final sent = BytesBuilder();
      for (final f in host.received.where((f) => f.kind == FrameKind.data)) {
        sent.add(f.payload);
      }
      final all = sent.takeBytes();
      expect(all.sublist(0, 60000), big);
      expect(utf8.decode(all.sublist(60000)), 'last\n');
    });

    test(
      'a write is split in 16 KiB pieces on a zctx stream so compression cannot push a frame over the limit',
      () async {
        final host = FakeHost();
        final link = await connected(host);
        final s = link.open('keeper', 'attach', const {}, true);
        // Incompressible bytes: a compressor adds a few to each piece.
        var x = 12345;
        final noise = Uint8List.fromList([
          for (var i = 0; i < 100000; i++) (x = (x * 1103515245 + 12345) & 0x7fffffff) >> 16 & 0xff,
        ]);
        await s.write(noise);
        await until(() => host.received.where((f) => f.kind == FrameKind.data).length >= 7);
        final frames = host.received.where((f) => f.kind == FrameKind.data).toList();
        expect(frames.every((f) => f.payload.length <= maxData), isTrue);
        final inflater = Inflater();
        final back = BytesBuilder();
        for (final f in frames) {
          back.add(f.flags == FrameFlags.deflateCtx ? inflater.inflate(f.payload) : f.payload);
        }
        expect(back.takeBytes(), noise);
      },
    );
  });

  group('started before the host has said HELLO', () {
    test('our HELLO and the OPENs are written at once, the host\'s HELLO then completes helloFuture', () async {
      final host = FakeHost();
      final link = HostLink.start(host, version: '0.1.68');
      final stream = link.open('herdr', 'mux', {'projections': <String, Object?>{}}, true);
      stream.sendText('{"id":"m0","method":"ping","params":{}}');
      var greeted = false;
      unawaited(link.helloFuture.then((_) => greeted = true));
      await until(() => host.received.length == 3, what: 'HELLO, OPEN and the request');

      expect(host.received.map((f) => f.kind), [FrameKind.hello, FrameKind.open, FrameKind.msg]);
      expect(host.opens.single['svc'], 'herdr');
      expect(host.opens.single['zctx'], isTrue);
      expect(host.messagesOn(stream.id), ['{"id":"m0","method":"ping","params":{}}']);
      expect(greeted, isFalse);
      expect(() => link.hello, throwsStateError);

      host.greet();
      final hello = await link.helloFuture;
      expect(link.hello, same(hello));
      expect(hello.version, '9.9.9');

      host.sendReady(stream.id);
      host.answer(stream.id, 'm0', {'type': 'pong'});
      final lines = await stream.texts.take(2).toList();
      expect(jsonDecode(lines.last), {
        'id': 'm0',
        'result': {'type': 'pong'},
      });
    });

    test('connect is start plus the wait: it does not return before the HELLO', () async {
      final host = FakeHost();
      HostLink? got;
      final connecting = HostLink.connect(host, version: '1').then((l) => got = l);
      await until(() => host.received.isNotEmpty, what: 'our HELLO');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(got, isNull);
      host.greet();
      expect((await connecting).hello.version, '9.9.9');
    });

    test('a stream opened before the HELLO fails with HostMissing when the command exits 65', () async {
      final host = FakeHost();
      final link = HostLink.start(host, version: '1');
      final stream = link.open('herdr', 'mux');
      final mux = HostMuxChannel(stream);
      final seen = <Object>[];
      mux.lines.listen((_) {}, onError: seen.add);
      host.writeStderr('herdr-mobile: agent helper 1 is not installed\n');
      host.exit(65);

      await expectLater(link.helloFuture, throwsA(isA<HostMissing>()));
      final end = await stream.done;
      expect(end.error, isA<HostMissing>().having((e) => e.message, 'message', contains('not installed')));
      expect(end.error, isNot(isA<HostLinkLost>()));
      expect(seen.single, isA<MuxUnavailable>().having((e) => e.helperMissing, 'helperMissing', isTrue));
      expect(link.isOpen, isFalse);
    });

    test(
      'a dropped link before the HELLO is HostLinkLost, never HostMissing, on the HELLO and on the streams',
      () async {
        final host = FakeHost();
        final link = HostLink.start(host, version: '1');
        final stream = link.open('herdr', 'events');
        host.exit(null);

        await expectLater(
          link.helloFuture,
          throwsA(isA<HostLinkLost>().having((e) => e.retryable, 'retryable', isTrue)),
        );
        expect((await stream.done).error, isA<HostLinkLost>());
      },
    );

    test('a failed start or a refusal reaches the streams with the host\'s own code', () async {
      final host = FakeHost();
      final link = HostLink.start(host, version: '1');
      final stream = link.open('herdr', 'mux');
      host.writeStderr('exec format error\n');
      host.exit(126);
      final error = (await stream.done).error!;
      expect(error.code, 'failed');
      expect(error.message, contains('exec format error'));
      await expectLater(link.helloFuture, throwsA(isA<HostException>()));

      final refused = FakeHost();
      final other = HostLink.start(refused, version: '1');
      final s = other.open('herdr', 'mux');
      refused.sendBytes(hostMagic);
      refused.sendJson(FrameKind.end, 0, {
        'error': {'code': 'proto_mismatch', 'message': 'this host speaks hostwire/2', 'retryable': false},
      });
      expect((await s.done).error?.code, 'proto_mismatch');
      expect(refused.closedByClient, isTrue);
    });

    test('silence is a retryable timeout for the HELLO and for the streams, and closes the channel', () async {
      final host = FakeHost();
      final link = HostLink.start(host, version: '1', helloTimeout: const Duration(milliseconds: 50));
      final stream = link.open('herdr', 'mux');
      await expectLater(
        link.helloFuture,
        throwsA(isA<HostException>().having((e) => e.code, 'code', 'timeout').having((e) => e.retryable, 'r', isTrue)),
      );
      expect((await stream.done).error?.code, 'timeout');
      expect(host.closedByClient, isTrue);
    });

    test('an unobserved helloFuture that fails is not an unhandled error', () async {
      final host = FakeHost();
      HostLink.start(host, version: '1');
      host.exit(65);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // The test fails by itself if the zone saw an uncaught error.
    });

    test('a call before the HELLO is answered after it', () async {
      final host = FakeHost();
      final link = HostLink.start(host, version: '1');
      final result = link.call('fs', 'stat', {'path': '/x'});
      await until(() => host.opens.isNotEmpty, what: 'the OPEN');
      // The host reads the OPEN behind our HELLO and answers after its own.
      host.greet();
      final stream = host.opens.single['stream']! as int;
      host.sendJson(FrameKind.msg, stream, {'kind': 'file'});
      host.sendJson(FrameKind.end, stream, {});
      expect(await result, {'kind': 'file'});
    });

    test('a window other than the default moves the credit of streams opened before the HELLO', () async {
      final host = FakeHost();
      final link = HostLink.start(host, version: '1');
      final stream = link.open('transfer', 'put');
      // A megabyte and 1000 bytes: the last 1000 wait for credit the default window lacks.
      final sent = stream.write(Uint8List(HostLink.defaultWindow + 1000));
      await until(
        () => host.received.where((f) => f.kind == FrameKind.data).length == 32,
        what: 'the credit-sized part',
      );
      var done = false;
      unawaited(sent.then((_) => done = true));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(done, isFalse);
      expect(host.received.where((f) => f.kind == FrameKind.data), hasLength(32));

      host.greet(window: HostLink.defaultWindow + 1000);
      await sent;
      expect(host.received.where((f) => f.kind == FrameKind.data), hasLength(33));
      expect((await link.helloFuture).limits.window, HostLink.defaultWindow + 1000);
    });

    test('and the credit the client gives back follows the window the host named', () async {
      final host = FakeHost();
      final link = HostLink.start(host, version: '1');
      final stream = link.open('herdr', 'events');
      host.greet(window: 2000);
      await link.helloFuture;
      final got = <String>[];
      stream.texts.listen(got.add);
      host.sendJson(FrameKind.msg, stream.id, {'pad': 'x' * 1100});
      await until(() => got.length == 1);
      expect(host.creditedOn(stream.id), greaterThanOrEqualTo(1000));
    });
  });

  group('the mux channel', () {
    test('ready, requests as messages and responses as lines', () async {
      final host = FakeHost();
      final link = await connected(host);
      final channel = HostMuxChannel(link.open('herdr', 'mux'));
      final lines = <String>[];
      channel.lines.listen(lines.add);
      host.sendJson(FrameKind.msg, 1, {'ready': true});
      host.sendJson(FrameKind.msg, 1, {
        'id': 'm0',
        'result': {'pong': true},
      });
      await until(() => lines.length == 2);
      expect(lines.first, muxReadyLine);
      channel.send('{"id":"m1","method":"ping","params":{}}');
      await until(() => host.messagesOn(1).isNotEmpty);
      expect(host.messagesOn(1), ['{"id":"m1","method":"ping","params":{}}']);
    });

    test('a host that cannot serve the mux right now is MuxUnavailable, not a lost link', () async {
      final host = FakeHost();
      final link = await connected(host);
      final channel = HostMuxChannel(link.open('herdr', 'mux'));
      final result = MuxClient.connect(channel, startupTimeout: const Duration(seconds: 2));
      host.sendJson(FrameKind.end, 1, {
        'error': {'code': 'unavailable', 'message': 'no herdr socket at /x for session default', 'retryable': true},
      });
      await expectLater(
        result,
        throwsA(
          isA<MuxUnavailable>()
              .having((e) => e.linkLost, 'linkLost', isFalse)
              .having((e) => e.message, 'message', contains('no herdr socket')),
        ),
      );
    });

    test('a link that drops while the mux starts is a lost link', () async {
      final host = FakeHost();
      final link = await connected(host);
      final channel = HostMuxChannel(link.open('herdr', 'mux'));
      final result = MuxClient.connect(channel, startupTimeout: const Duration(seconds: 2));
      host.exit(null);
      await expectLater(result, throwsA(isA<MuxUnavailable>().having((e) => e.linkLost, 'linkLost', isTrue)));
    });
  });
}

/// A continuous zlib stream for the test host: what `wire::ContinuousDeflater`
/// is on the real one (each piece sync-flushed so the client can inflate it at
/// once, later pieces referring back to earlier ones).
class ZLibEncoder6 {
  final _filter = RawZLibFilter.deflateFilter(level: 6);

  Uint8List piece(List<int> data) {
    _filter.process(data, 0, data.length);
    final out = BytesBuilder(copy: false);
    while (true) {
      final chunk = _filter.processed(flush: true);
      if (chunk == null || chunk.isEmpty) break;
      out.add(chunk);
    }
    return out.takeBytes();
  }
}
