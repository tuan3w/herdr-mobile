import 'dart:async';
import 'dart:convert';
import 'dart:io' show zlib;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/mux_client.dart';

const _ready = 'herdr-mux-v1';

class _FakeChannel implements MuxChannel {
  final _controller = StreamController<String>();
  final _exit = Completer<int?>();
  final sent = <Map<String, dynamic>>[];
  var closed = false;
  var failSend = false;

  @override
  Stream<String> get lines => _controller.stream;

  @override
  Future<int?> get exitCode => _exit.future;

  @override
  void send(String line) {
    if (failSend) throw StateError('channel is gone');
    sent.add(jsonDecode(line) as Map<String, dynamic>);
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_exit.isCompleted) _exit.complete(null);
    if (!_controller.isClosed) unawaited(_controller.close());
  }

  /// The remote side ends the channel with [code] (null = link dropped).
  void remoteExit(int? code) {
    if (!_exit.isCompleted) _exit.complete(code);
    _controller.close();
  }

  void emit(String line) {
    if (!_controller.isClosed) _controller.add(line);
  }

  void reply(Object? id, [Map<String, dynamic> result = const {}]) =>
      emit(jsonEncode({'id': id, 'result': result}));

  void replyError(Object? id, String code, String message) => emit(jsonEncode({
        'id': id,
        'error': {'code': code, 'message': message},
      }));

  String idOf(int sentIndex) => sent[sentIndex]['id'] as String;
}

/// Captures a future's outcome so tests can inspect it synchronously.
class _Outcome<T> {
  _Outcome(Future<T> future) {
    future.then((v) {
      value = v;
      done = true;
    }, onError: (Object e) {
      error = e;
      done = true;
    });
  }

  T? value;
  Object? error;
  var done = false;
}

const _heartbeat = Duration(seconds: 8);
const _heartbeatTimeout = Duration(seconds: 5);

MuxClient _start(
  FakeAsync async,
  _FakeChannel channel, {
  // Effectively off unless a test is about the heartbeat.
  Duration heartbeatInterval = const Duration(hours: 1),
}) {
  final started = _Outcome(MuxClient.connect(
    channel,
    requestTimeout: const Duration(seconds: 20),
    heartbeatInterval: heartbeatInterval,
    heartbeatTimeout: _heartbeatTimeout,
  ));
  channel.emit(_ready);
  async.flushMicrotasks();
  expect(started.error, isNull);
  return started.value!;
}

void main() {
  group('startup', () {
    test('waits for the ready line and ignores noise before it', () {
      fakeAsync((async) {
        final ch = _FakeChannel();
        final started = _Outcome(MuxClient.connect(ch));
        ch.emit('Last login: today');
        async.flushMicrotasks();
        expect(started.done, isFalse);

        ch.emit(_ready);
        async.flushMicrotasks();

        expect(started.value?.isAlive, isTrue);
      });
    });

    test('a remote exit before ready is MuxUnavailable with the exit status', () {
      fakeAsync((async) {
        final ch = _FakeChannel();
        final started = _Outcome(MuxClient.connect(ch));

        ch.remoteExit(78);
        async.flushMicrotasks();

        final e = started.error as MuxUnavailable;
        expect(e.linkLost, isFalse);
        expect(e.message, contains('78'));
        expect(ch.closed, isTrue);
      });
    });

    test('a channel dropped before ready (no exit status) is flagged linkLost',
        () {
      fakeAsync((async) {
        final ch = _FakeChannel();
        final started = _Outcome(MuxClient.connect(ch));

        ch.remoteExit(null);
        async.flushMicrotasks();

        expect((started.error as MuxUnavailable).linkLost, isTrue);
      });
    });

    test('never becoming ready within the startup timeout is MuxUnavailable',
        () {
      fakeAsync((async) {
        final ch = _FakeChannel();
        final started = _Outcome(
            MuxClient.connect(ch, startupTimeout: const Duration(seconds: 5)));

        async.elapse(const Duration(seconds: 4, milliseconds: 900));
        expect(started.done, isFalse);
        async.elapse(const Duration(milliseconds: 200));

        final e = started.error as MuxUnavailable;
        expect(e.linkLost, isFalse);
        expect(ch.closed, isTrue);
      });
    });
  });

  group('requests', () {
    test('responses are routed by id even when they arrive out of order', () {
      fakeAsync((async) {
        final ch = _FakeChannel();
        final client = _start(async, ch);

        final a = _Outcome(client.request('session.snapshot'));
        final b = _Outcome(client.request('pane.read', {'pane_id': 'w1:p1'}));
        expect(ch.sent.map((r) => r['method']), ['session.snapshot', 'pane.read']);
        expect(ch.idOf(0), isNot(ch.idOf(1)));

        ch.reply(ch.idOf(1), {'which': 'b'});
        async.flushMicrotasks();
        expect(b.value, {'which': 'b'});
        expect(a.done, isFalse);

        ch.reply(ch.idOf(0), {'which': 'a'});
        async.flushMicrotasks();
        expect(a.value, {'which': 'a'});
      });
    });

    test('forwards params in the request line', () {
      fakeAsync((async) {
        final ch = _FakeChannel();
        final client = _start(async, ch);

        _Outcome(client.request('pane.read', {'pane_id': 'w1:p1', 'lines': 5}));

        expect(ch.sent.single['params'], {'pane_id': 'w1:p1', 'lines': 5});
      });
    });

    test('an API error response becomes HerdrApiException', () {
      fakeAsync((async) {
        final ch = _FakeChannel();
        final client = _start(async, ch);
        final r = _Outcome(client.request('pane.read'));

        ch.replyError(ch.idOf(0), 'pane_not_found', 'no such pane');
        async.flushMicrotasks();

        final e = r.error as HerdrApiException;
        expect(e.code, 'pane_not_found');
        expect(e.message, 'no such pane');
        expect(client.isAlive, isTrue);
      });
    });

    test('a request herdr never answers times out without killing the client',
        () {
      fakeAsync((async) {
        final ch = _FakeChannel();
        final client = _start(async, ch);
        final slow = _Outcome(client.request('session.snapshot'));

        async.elapse(const Duration(seconds: 20));

        final e = slow.error as HerdrTransportException;
        expect(e.message, 'herdr did not answer session.snapshot in time');
        expect(e.fatal, isFalse);
        expect(client.isAlive, isTrue);

        // The late answer is dropped; the next request is unaffected.
        ch.reply(ch.idOf(0), {'late': true});
        final next = _Outcome(client.request('ping'));
        ch.reply(ch.idOf(1), {'type': 'pong'});
        async.flushMicrotasks();
        expect(next.value, {'type': 'pong'});
      });
    });

    group('pane.read deltas', () {
      Map<String, dynamic> whole(String id, int seq, String text) => {
            'id': id,
            'seq': seq,
            'result': {
              'type': 'pane_read',
              'read': {'text': text, 'truncated': false},
            },
          };

      Map<String, dynamic> delta(
        String id,
        int seq,
        int base, {
        required int s,
        required int k,
        required int x,
        required List<String> t,
      }) =>
          {
            'id': id,
            'seq': seq,
            'result': {
              'type': 'pane_read',
              'read': {
                'delta': {'base': base, 's': s, 'k': k, 'x': x, 't': t},
                'truncated': true,
              },
            },
          };

      test('a delta is rebuilt from the answer the request named', () {
        fakeAsync((async) {
          final ch = _FakeChannel();
          final client = _start(async, ch);
          final a = _Outcome(client.request('pane.read', {'pane_id': 'p'}));
          expect(ch.sent[0].containsKey('mux_have'), isFalse);
          ch.emit(jsonEncode(whole(ch.idOf(0), 7, 'a\r\nb\r\nc\r\nd\r\n')));
          async.flushMicrotasks();
          expect((a.value!['read'] as Map)['text'], 'a\r\nb\r\nc\r\nd\r\n');

          final b = _Outcome(client.request('pane.read', {'pane_id': 'p'}));
          expect(ch.sent[1]['mux_have'], 7);
          // Rows were [a, b, c, d, '']: keep b c (s=1, k=2), add e, keep the
          // trailing '' (x=1).
          ch.emit(jsonEncode(delta(ch.idOf(1), 8, 7, s: 1, k: 2, x: 1, t: ['e\r'])));
          async.flushMicrotasks();
          final read = b.value!['read'] as Map;
          expect(read['text'], 'b\r\nc\r\ne\r\n');
          expect(read.containsKey('delta'), isFalse);
          expect(read['truncated'], isTrue);

          // The rebuilt answer is what the next request names.
          _Outcome(client.request('pane.read', {'pane_id': 'p'}));
          expect(ch.sent[2]['mux_have'], 8);
          // Other parameters are another read.
          _Outcome(client.request('pane.read', {'pane_id': 'q'}));
          expect(ch.sent[3].containsKey('mux_have'), isFalse);
        });
      });

      test('only one request at a time names the answer held', () {
        fakeAsync((async) {
          final ch = _FakeChannel();
          final client = _start(async, ch);
          _Outcome(client.request('pane.read', {'pane_id': 'p'}));
          ch.emit(jsonEncode(whole(ch.idOf(0), 1, 'a\r\n')));
          async.flushMicrotasks();

          _Outcome(client.request('pane.read', {'pane_id': 'p'}));
          _Outcome(client.request('pane.read', {'pane_id': 'p'}));

          expect(ch.sent[1]['mux_have'], 1);
          expect(ch.sent[2].containsKey('mux_have'), isFalse);
        });
      });

      test('a delta against an answer we do not hold fails the request, not the link',
          () {
        fakeAsync((async) {
          final ch = _FakeChannel();
          final client = _start(async, ch);
          _Outcome(client.request('pane.read', {'pane_id': 'p'}));
          ch.emit(jsonEncode(whole(ch.idOf(0), 1, 'a\r\nb\r\n')));
          async.flushMicrotasks();

          for (final bad in [
            delta('x', 3, 99, s: 0, k: 1, x: 0, t: []), // another base
            delta('x', 3, 1, s: 2, k: 2, x: 0, t: []), // past the rows held
            delta('x', 3, 1, s: 0, k: 1, x: 9, t: []), // suffix longer than held
            delta('x', 3, 1, s: -1, k: 1, x: 0, t: []),
          ]) {
            final r = _Outcome(client.request('pane.read', {'pane_id': 'p'}));
            final sentAt = ch.sent.length - 1;
            ch.emit(jsonEncode({...bad, 'id': ch.idOf(sentAt)}));
            async.flushMicrotasks();

            final e = r.error;
            expect(e, isA<HerdrTransportException>(), reason: '$bad');
            expect((e! as HerdrTransportException).fatal, isFalse);
            expect(client.isAlive, isTrue);

            // Nothing is held any more: the next request asks for the whole.
            _Outcome(client.request('pane.read', {'pane_id': 'p'}));
            expect(ch.sent.last.containsKey('mux_have'), isFalse);
            ch.emit(jsonEncode(whole(ch.idOf(ch.sent.length - 1), 1, 'a\r\nb\r\n')));
            async.flushMicrotasks();
          }
        });
      });

      test('an error answer leaves the answer held in place', () {
        fakeAsync((async) {
          final ch = _FakeChannel();
          final client = _start(async, ch);
          _Outcome(client.request('pane.read', {'pane_id': 'p'}));
          ch.emit(jsonEncode(whole(ch.idOf(0), 4, 'a\r\n')));
          async.flushMicrotasks();

          final r = _Outcome(client.request('pane.read', {'pane_id': 'p'}));
          ch.replyError(ch.idOf(1), 'pane_not_found', 'gone');
          async.flushMicrotasks();
          expect(r.error, isA<HerdrApiException>());

          _Outcome(client.request('pane.read', {'pane_id': 'p'}));
          expect(ch.sent[2]['mux_have'], 4);
        });
      });
    });

    test('malformed and unmatched lines are ignored', () {
      fakeAsync((async) {
        final ch = _FakeChannel();
        final client = _start(async, ch);
        final r = _Outcome(client.request('ping'));

        ch.emit('not json');
        ch.emit('[1,2]');
        ch.reply('nobody-asked');
        ch.emit(jsonEncode({'result': {}}));
        async.flushMicrotasks();
        expect(r.done, isFalse);

        ch.reply(ch.idOf(0), {'type': 'pong'});
        async.flushMicrotasks();
        expect(r.value, {'type': 'pong'});
      });
    });

    test('a channel that closes fails every pending request, non-fatally', () {
      fakeAsync((async) {
        final ch = _FakeChannel();
        final client = _start(async, ch);
        final a = _Outcome(client.request('session.snapshot'));
        final b = _Outcome(client.request('pane.read'));
        final death = _Outcome(client.onDead);

        ch.remoteExit(null);
        async.flushMicrotasks();

        for (final o in [a, b]) {
          final e = o.error as HerdrTransportException;
          expect(e.fatal, isFalse);
        }
        expect(client.isAlive, isFalse);
        expect(death.value, MuxDeath.closed);
        expect(ch.closed, isTrue);
      });
    });

    test('a dead client rejects new requests without touching the channel', () {
      fakeAsync((async) {
        final ch = _FakeChannel();
        final client = _start(async, ch);
        ch.remoteExit(null);
        async.flushMicrotasks();
        final sentBefore = ch.sent.length;

        final r = _Outcome(client.request('ping'));
        async.flushMicrotasks();

        expect((r.error as HerdrTransportException).fatal, isFalse);
        expect(ch.sent, hasLength(sentBefore));
        // No zombie: it stays dead, even if the remote sends more.
        ch.emit(jsonEncode({'id': 'm0', 'result': {}}));
        async.flushMicrotasks();
        expect(client.isAlive, isFalse);
      });
    });

    test('a failing send kills the client and fails the request', () {
      fakeAsync((async) {
        final ch = _FakeChannel();
        final client = _start(async, ch);
        final other = _Outcome(client.request('session.snapshot'));
        ch.failSend = true;

        final r = _Outcome(client.request('ping'));
        async.flushMicrotasks();

        expect(r.error, isA<HerdrTransportException>());
        expect(other.error, isA<HerdrTransportException>());
        expect(client.isAlive, isFalse);
        expect(ch.closed, isTrue);
      });
    });

    test('close() fails in-flight requests and closes the channel', () {
      fakeAsync((async) {
        final ch = _FakeChannel();
        final client = _start(async, ch);
        final r = _Outcome(client.request('session.snapshot'));

        client.close();
        async.flushMicrotasks();

        expect((r.error as HerdrTransportException).fatal, isFalse);
        expect(ch.closed, isTrue);
        expect(client.isAlive, isFalse);
      });
    });
  });

  group('heartbeat', () {
    test('pings through the mux at the interval while replies keep coming', () {
      fakeAsync((async) {
        final ch = _FakeChannel();
        final client = _start(async, ch, heartbeatInterval: _heartbeat);

        async.elapse(_heartbeat - const Duration(milliseconds: 1));
        expect(ch.sent, isEmpty);
        async.elapse(const Duration(milliseconds: 1));

        for (var round = 1; round <= 5; round++) {
          expect(ch.sent, hasLength(round));
          expect(ch.sent.last['method'], 'ping');
          ch.reply(ch.idOf(round - 1), {'type': 'pong'});
          async.elapse(_heartbeat);
        }

        expect(client.isAlive, isTrue);
      });
    });

    test('a missing reply kills the client after the timeout and fails pendings',
        () {
      fakeAsync((async) {
        final ch = _FakeChannel();
        final client = _start(async, ch, heartbeatInterval: _heartbeat);
        final death = _Outcome(client.onDead);
        final user = _Outcome(client.request('session.snapshot'));

        async.elapse(_heartbeat); // ping goes out, nobody answers
        async.elapse(_heartbeatTimeout - const Duration(milliseconds: 1));
        expect(client.isAlive, isTrue);
        async.elapse(const Duration(milliseconds: 1));

        expect(client.isAlive, isFalse);
        expect(death.value, MuxDeath.unresponsive);
        expect(ch.closed, isTrue);
        final e = user.error as HerdrTransportException;
        expect(e.fatal, isFalse);
        expect(e.message, contains('stopped responding'));
      });
    });

    test('a late heartbeat reply within the timeout keeps the client alive', () {
      fakeAsync((async) {
        final ch = _FakeChannel();
        final client = _start(async, ch, heartbeatInterval: _heartbeat);

        async.elapse(_heartbeat);
        async.elapse(_heartbeatTimeout - const Duration(milliseconds: 1));
        ch.reply(ch.idOf(0), {'type': 'pong'});
        async.elapse(const Duration(seconds: 3));
        expect(client.isAlive, isTrue);
        expect(ch.sent, hasLength(1));

        // The next heartbeat goes out on schedule.
        async.elapse(const Duration(seconds: 1));
        expect(ch.sent, hasLength(2));
      });
    });

    test('an API error reply to the heartbeat still proves the link is alive',
        () {
      fakeAsync((async) {
        final ch = _FakeChannel();
        final client = _start(async, ch, heartbeatInterval: _heartbeat);

        async.elapse(_heartbeat);
        ch.replyError(ch.idOf(0), 'unknown_method', 'nope');
        async.elapse(_heartbeatTimeout * 2);

        expect(client.isAlive, isTrue);
      });
    });

    test('does not ping again while a heartbeat is still outstanding', () {
      fakeAsync((async) {
        // Interval shorter than the timeout: pings must not stack up.
        final ch = _FakeChannel();
        final started = _Outcome(MuxClient.connect(
          ch,
          heartbeatInterval: const Duration(seconds: 2),
          heartbeatTimeout: const Duration(seconds: 5),
        ));
        ch.emit(_ready);
        async.flushMicrotasks();
        final client = started.value!;

        async.elapse(const Duration(seconds: 4, milliseconds: 500));

        expect(ch.sent, hasLength(1));
        expect(client.isAlive, isTrue);
      });
    });

    test('stops pinging once dead', () {
      fakeAsync((async) {
        final ch = _FakeChannel();
        _start(async, ch, heartbeatInterval: _heartbeat);
        async.elapse(_heartbeat + _heartbeatTimeout);
        final sent = ch.sent.length;

        async.elapse(_heartbeat * 5);

        expect(ch.sent, hasLength(sent));
      });
    });
  });

  group('muxMessages', () {
    final text = 'Xin chào \u001b[1mđường dẫn\u001b[0m\r\n' * 50;
    final big = jsonEncode({'id': 'a', 'result': {'text': text}});
    final stream = [
      ...utf8.encode('herdr-mux-v1\n'),
      ...utf8.encode('{"id":"p","result":{"type":"pong"}}\n'),
      ..._frame(big),
      ...utf8.encode('{"id":"q","result":{"text":"đường"}}\n'),
      ..._frame(big),
    ];
    final expected = [
      'herdr-mux-v1',
      '{"id":"p","result":{"type":"pong"}}',
      big,
      '{"id":"q","result":{"text":"đường"}}',
      big,
    ];

    test('plain lines and deflated frames come out in order, however the bytes are cut',
        () async {
      for (final size in [1, 2, 3, 7, 64, 1000, stream.length]) {
        expect(
          await muxMessages(Stream.fromIterable(_chunks(stream, size))).toList(),
          expected,
          reason: 'chunks of $size bytes',
        );
      }
    });

    test('a message of several MB crosses the buffer intact', () async {
      final rows = List.generate(120000, (i) => 'row $i ${i * 7919 % 1000003}');
      final huge = jsonEncode({'id': 'h', 'result': {'text': rows.join('\r\n')}});
      expect(huge.length, greaterThan(2 * 1024 * 1024));

      final got = await muxMessages(
        Stream.fromIterable(_chunks([..._frame(huge), ...utf8.encode('{"id":"z"}\n')], 16384)),
      ).toList();

      expect(got, [huge, '{"id":"z"}']);
    });

    test('a frame that does not inflate, or a bad header, costs only that message', () async {
      final junk = [
        ...ascii.encode('Z5\n'),
        1, 2, 3, 4, 5, // not zlib data
        ...ascii.encode('Zxyz\n'), // no length
        ...ascii.encode('Z-3\n'),
        ...ascii.encode('Z999999999999\n'),
      ];
      final got = await muxMessages(
        Stream.fromIterable(_chunks([...junk, ...utf8.encode('{"id":"ok"}\n')], 3)),
      ).toList();

      expect(got, ['{"id":"ok"}']);
    });
  });
}

/// A deflated frame as the mux script writes it.
List<int> _frame(String json) {
  final z = zlib.encode(utf8.encode(json));
  return [...ascii.encode('Z${z.length}\n'), ...z];
}

List<List<int>> _chunks(List<int> bytes, int size) => [
      for (var i = 0; i < bytes.length; i += size)
        bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size),
    ];
