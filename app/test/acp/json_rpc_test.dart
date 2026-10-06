import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/json_rpc.dart';

import 'support/fake_agent.dart';

Map<String, Object?> _decode(String line) => (jsonDecode(line) as Map).cast<String, Object?>();

void main() {
  group('splitLines', () {
    Future<(List<String>, List<Object>)> run(List<List<int>> chunks, {int? maxLine}) async {
      final out = <String>[];
      final errors = <Object>[];
      final done = Completer<void>();
      final controller = StreamController<List<int>>();
      final stream = maxLine == null ? splitLines(controller.stream) : splitLines(controller.stream, maxLine: maxLine);
      stream.listen(out.add, onError: errors.add, onDone: done.complete);
      for (final c in chunks) {
        controller.add(c);
      }
      await controller.close();
      await done.future;
      return (out, errors);
    }

    test('joins a line cut at any byte and drops CR and blank lines', () async {
      final bytes = utf8.encode('{"a":1}\r\n\n{"b":2}\n');
      for (var cut = 1; cut < bytes.length; cut++) {
        final (lines, errors) = await run([bytes.sublist(0, cut), bytes.sublist(cut)]);
        expect(lines, ['{"a":1}', '{"b":2}'], reason: 'cut at $cut');
        expect(errors, isEmpty);
      }
    });

    test('a multi-byte character split across chunks survives', () async {
      final bytes = utf8.encode('{"t":"é🙂ệ"}\n');
      for (var cut = 1; cut < bytes.length; cut++) {
        final (lines, _) = await run([bytes.sublist(0, cut), bytes.sublist(cut)]);
        expect(lines, ['{"t":"é🙂ệ"}'], reason: 'cut at $cut');
      }
    });

    test('a last line without a newline is delivered at the end', () async {
      final (lines, _) = await run([utf8.encode('one\ntwo')]);
      expect(lines, ['one', 'two']);
    });

    test('delivers synchronously: no event-loop turn between chunk and line', () {
      final controller = StreamController<List<int>>(sync: true);
      final seen = <String>[];
      splitLines(controller.stream).listen(seen.add);
      controller.add(utf8.encode('a\nb\nc'));
      expect(seen, ['a', 'b'], reason: 'the lines are out before add() returned');
    });

    test('a line over the cap is reported and skipped, the next line is fine', () async {
      final (lines, errors) = await run([
        utf8.encode('a' * 20),
        utf8.encode('bbb\nok\n'),
        utf8.encode('${'c' * 30}\nfine\n'),
      ], maxLine: 10);
      expect(lines, ['ok', 'fine']);
      expect(errors, hasLength(2));
    });

    test('a big line arriving in many small chunks is kept whole', () async {
      final big = 'x' * 100000;
      final bytes = utf8.encode('$big\n');
      final chunks = [for (var i = 0; i < bytes.length; i += 777) bytes.sublist(i, i + 777 > bytes.length ? bytes.length : i + 777)];
      final (lines, _) = await run(chunks);
      expect(lines, [big]);
    });
  });

  group('JsonRpcConnection', () {
    late MemoryLink link;
    late List<String> problems;

    JsonRpcConnection client({IncomingRequestHandler? onRequest, IncomingNotificationHandler? onNotification, Duration? timeout}) =>
        JsonRpcConnection(
          link.client,
          onRequest: onRequest,
          onNotification: onNotification,
          onProblem: (m, {line}) => problems.add(m),
          defaultTimeout: timeout,
        );

    setUp(() {
      link = MemoryLink();
      problems = [];
    });

    test('answers are matched by id, whatever the order', () async {
      final rpc = client();
      final a = rpc.request('a');
      final b = rpc.request('b');
      final sent = link.client.sent.map(_decode).toList();
      expect(sent.map((m) => m['method']), ['a', 'b']);
      link.agent.send(line({'jsonrpc': '2.0', 'id': sent[1]['id'], 'result': 'for-b'}));
      link.agent.send(line({'jsonrpc': '2.0', 'id': sent[0]['id'], 'result': 'for-a'}));
      expect(await a, 'for-a');
      expect(await b, 'for-b');
    });

    test('an error answer becomes a JsonRpcException with code and data', () async {
      final rpc = client();
      final f = rpc.request('x');
      final id = _decode(link.client.sent.single)['id'];
      link.agent.send(line({'jsonrpc': '2.0', 'id': id, 'error': {'code': -32602, 'message': 'bad', 'data': {'k': 1}}}));
      await expectLater(
        f,
        throwsA(isA<JsonRpcException>().having((e) => e.code, 'code', -32602).having((e) => e.data, 'data', {'k': 1})),
      );
    });

    test('a request times out, and the late answer is ignored', () async {
      final rpc = client();
      final f = rpc.request('slow', null, const Duration(milliseconds: 20));
      await expectLater(f, throwsA(isA<TimeoutException>()));
      final id = _decode(link.client.sent.single)['id'];
      link.agent.send(line({'jsonrpc': '2.0', 'id': id, 'result': 1}));
      expect(problems.single, contains('nobody waits'));
    });

    test('the default timeout applies, Duration.zero turns it off', () async {
      final rpc = client(timeout: const Duration(milliseconds: 20));
      final timed = rpc.request('a');
      final unlimited = rpc.request('b', null, Duration.zero);
      await expectLater(timed, throwsA(isA<TimeoutException>()));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final id = _decode(link.client.sent.last)['id'];
      link.agent.send(line({'jsonrpc': '2.0', 'id': id, 'result': 'late but fine'}));
      expect(await unlimited, 'late but fine');
    });

    test('EOF fails everything pending, completes done and refuses new work', () async {
      final rpc = client();
      final a = rpc.request('a');
      final b = rpc.request('b', null, const Duration(seconds: 30));
      final errors = [expectLater(a, throwsA(isA<JsonRpcClosedException>())), expectLater(b, throwsA(isA<JsonRpcClosedException>()))];
      await link.agent.close();
      await Future.wait(errors);
      await rpc.done;
      expect(rpc.isClosed, isTrue);
      await expectLater(rpc.request('c'), throwsA(isA<JsonRpcClosedException>()));
      expect(() => rpc.notify('n'), throwsA(isA<JsonRpcClosedException>()));
    });

    test('close() fails pending requests and hangs up on the peer', () async {
      final rpc = client();
      final a = rpc.request('a');
      final failed = expectLater(a, throwsA(isA<JsonRpcClosedException>()));
      var peerSawEof = false;
      link.agent.lines.listen((_) {}, onDone: () => peerSawEof = true);
      await rpc.close();
      await failed;
      expect(peerSawEof, isTrue);
    });

    test('a send that throws fails that request only, the connection lives on', () async {
      final rpc = client();
      link.agent.peerDied(); // the pipe towards the agent is broken; the agent can still talk
      await expectLater(rpc.request('a'), throwsA(isA<JsonRpcClosedException>()));
      expect(rpc.isClosed, isFalse);
      expect(() => rpc.notify('n'), throwsA(isA<JsonRpcClosedException>()));
    });

    test('malformed and unusable lines are reported and skipped', () async {
      final rpc = client();
      final f = rpc.request('ping');
      final id = _decode(link.client.sent.single)['id'];
      for (final bad in ['not json', '{"jsonrpc":', '[1,2]', '42', '"s"', '{}', '{"id":3}', '{"id":{"x":1},"method":"m"}']) {
        link.agent.send(bad);
      }
      link.agent.send(line({'jsonrpc': '2.0', 'id': 4242, 'result': 1})); // answers nothing
      link.agent.send(line({'jsonrpc': '2.0', 'id': id, 'result': 'pong'}));
      expect(await f, 'pong');
      expect(problems, hasLength(9));
    });

    test('a transport error event is reported, not fatal', () async {
      final rpc = client();
      final f = rpc.request('ping');
      final id = _decode(link.client.sent.single)['id'];
      link.client.injectError('corrupt frame');
      link.agent.send(line({'jsonrpc': '2.0', 'id': id, 'result': 'ok'}));
      expect(await f, 'ok');
      expect(problems.single, contains('corrupt frame'));
    });

    test('notifications reach the handler; a throwing handler is contained', () async {
      final seen = <(String, Object?)>[];
      client(onNotification: (m, p) {
        seen.add((m, p));
        throw StateError('handler bug');
      });
      link.agent.send(line({'jsonrpc': '2.0', 'method': 'session/update', 'params': {'a': 1}}));
      link.agent.send(line({'jsonrpc': '2.0', 'method': 'again'}));
      expect(seen.map((e) => e.$1), ['session/update', 'again']);
      expect(seen.first.$2, {'a': 1});
      expect(seen.last.$2, isNull);
      expect(problems, hasLength(2));
    });

    test('the raw line of every notification (and only those) goes to the line tap first; a tap that throws costs nothing', () async {
      final order = <String>[];
      final lines = <(String, String)>[];
      JsonRpcConnection(
        link.client,
        onNotification: (m, p) => order.add('handler $m'),
        onNotificationLine: (m, l) {
          order.add('line $m');
          lines.add((m, l));
          throw StateError('a log must not cost the stream a message');
        },
        onProblem: (m, {line}) => problems.add(m),
      );
      final first = line({'jsonrpc': '2.0', 'method': 'session/update', 'params': {'a': 1}});
      link.agent.send(first);
      link.agent.send(line({'jsonrpc': '2.0', 'id': 7, 'method': 'session/request_permission', 'params': {}}));
      link.agent.send(line({'jsonrpc': '2.0', 'method': 'again'}));
      expect(lines, [('session/update', first), ('again', line({'jsonrpc': '2.0', 'method': 'again'}))]);
      expect(order, ['line session/update', 'handler session/update', 'line again', 'handler again']);
      expect(problems, isEmpty);
    });

    test('a request for an unsupported method gets method-not-found', () async {
      client(onRequest: (r) async => throw JsonRpcException.methodNotFound(r.method));
      link.agent.send(line({'jsonrpc': '2.0', 'id': 'abc', 'method': 'fs/read_text_file', 'params': {'path': '/x'}}));
      await settle();
      final answer = _decode(link.client.sent.single);
      expect(answer['id'], 'abc', reason: 'string ids are echoed untouched');
      expect((answer['error'] as Map)['code'], JsonRpcCode.methodNotFound);
    });

    test('without any handler every request is method-not-found', () async {
      client();
      link.agent.send(line({'jsonrpc': '2.0', 'id': 7, 'method': 'terminal/create'}));
      final answer = _decode(link.client.sent.single);
      expect((answer['error'] as Map)['code'], JsonRpcCode.methodNotFound);
    });

    test('a handler result is the answer; a plain exception is an internal error', () async {
      client(onRequest: (r) async {
        if (r.method == 'ok') return {'v': 1};
        if (r.method == 'void') return null;
        if (r.method == 'rpc') throw const JsonRpcException(-32001, 'nope', {'why': 'x'});
        throw StateError('boom');
      });
      for (final (id, method) in [(1, 'ok'), (2, 'void'), (3, 'rpc'), (4, 'bug')]) {
        link.agent.send(line({'jsonrpc': '2.0', 'id': id, 'method': method}));
      }
      await settle();
      final answers = {for (final l in link.client.sent) _decode(l)['id']: _decode(l)};
      expect(answers[1]!['result'], {'v': 1});
      expect(answers[2]!.containsKey('result'), isTrue);
      expect(answers[2]!['result'], isNull);
      expect(answers[3]!['error'], {'code': -32001, 'message': 'nope', 'data': {'why': 'x'}});
      expect((answers[4]!['error'] as Map)['code'], JsonRpcCode.internalError);
      expect(problems.single, contains('bug'));
    });

    test(r'$/cancel_request from the peer answers -32800 once and wakes the handler', () async {
      final release = Completer<Object?>();
      var sawCancel = false;
      client(onRequest: (r) {
        r.cancelled.then((_) => sawCancel = true);
        return release.future;
      });
      link.agent.send(line({'jsonrpc': '2.0', 'id': 7, 'method': 'session/request_permission'}));
      expect(link.client.sent, isEmpty);
      link.agent.send(line({'jsonrpc': '2.0', 'method': r'$/cancel_request', 'params': {'requestId': 7}}));
      await settle();
      expect(sawCancel, isTrue);
      final answer = _decode(link.client.sent.single);
      expect(answer['id'], 7);
      expect((answer['error'] as Map)['code'], JsonRpcCode.requestCancelled);
      release.complete({'outcome': 'late'});
      await settle();
      expect(link.client.sent, hasLength(1), reason: 'the late result is dropped');
      // Cancelling something already finished is ignored.
      link.agent.send(line({'jsonrpc': '2.0', 'method': r'$/cancel_request', 'params': {'requestId': 7}}));
      link.agent.send(line({'jsonrpc': '2.0', 'method': r'$/cancel_request', 'params': {'requestId': 999}}));
      await settle();
      expect(link.client.sent, hasLength(1));
      expect(problems, isEmpty);
    });

    test(r'call.cancel() sends $/cancel_request for that id, once it is still pending', () async {
      final rpc = client();
      final call = rpc.call('session/prompt', {'x': 1});
      call.cancel();
      final cancel = _decode(link.client.sent.last);
      expect(cancel['method'], r'$/cancel_request');
      expect(cancel['params'], {'requestId': call.id});
      expect(cancel.containsKey('id'), isFalse, reason: 'a notification');
      // The peer answers; the call finishes with the answer.
      link.agent.send(line({'jsonrpc': '2.0', 'id': call.id, 'error': {'code': -32800, 'message': 'Request cancelled'}}));
      await expectLater(call.response, throwsA(isA<JsonRpcException>().having((e) => e.isCancelled, 'isCancelled', isTrue)));
      final before = link.client.sent.length;
      call.cancel();
      expect(link.client.sent, hasLength(before), reason: 'nothing pending: nothing sent');
    });

    test('a request id already in flight is refused', () async {
      final release = Completer<Object?>();
      client(onRequest: (r) => release.future);
      link.agent.send(line({'jsonrpc': '2.0', 'id': 5, 'method': 'a'}));
      link.agent.send(line({'jsonrpc': '2.0', 'id': 5, 'method': 'b'}));
      final answer = _decode(link.client.sent.single);
      expect((answer['error'] as Map)['code'], JsonRpcCode.invalidRequest);
      release.complete(1);
    });

    test('params are omitted when null and ids count up from 1', () {
      final rpc = client();
      unawaited(rpc.request('a').then<void>((_) {}, onError: (Object _) {}));
      rpc.notify('n');
      final sent = link.client.sent.map(_decode).toList();
      expect(sent[0], {'jsonrpc': '2.0', 'id': 1, 'method': 'a'});
      expect(sent[1], {'jsonrpc': '2.0', 'method': 'n'});
    });
  });
}
