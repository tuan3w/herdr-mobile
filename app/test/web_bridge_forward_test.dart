@Tags(['timing'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart' show SSHSocket;
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/web_bridge.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/web_bridge.dart';
import 'package:herdr_mobile/data/repositories/web_preview.dart';

import 'support/fake_fs.dart';
import 'support/raw_http.dart';
import 'support/custom_tab.dart';
import 'support/fake_transport.dart';

/// A server on the "machine" that sends back every byte it gets and keeps them.
class _Echo {
  late ServerSocket server;
  final received = BytesBuilder(copy: false);

  Future<void> start() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) => s.listen((d) {
          received.add(d);
          s.add(d);
        }, onError: (Object _) {}));
    addTearDown(server.close);
  }

  int get port => server.port;
}

/// The machine end of a forward that takes bytes only when told to, like an
/// SSH channel whose window is full: the sink is a plain controller, so a
/// source added to it is paused while the reader is.
class _SlowMachine implements SSHSocket {
  _SlowMachine() {
    _reader = _inbound.stream.listen(
      (d) => received += d.length,
      onDone: _ended.complete,
    );
    _reader.pause();
  }

  final _inbound = StreamController<List<int>>();
  final _outbound = StreamController<Uint8List>();
  final _ended = Completer<void>();
  final _gone = Completer<void>();
  late final StreamSubscription<List<int>> _reader;
  var received = 0;

  /// The browser's end of the request reached the machine.
  Future<void> get ended => _ended.future;

  void drain() => _reader.resume();

  @override
  Stream<Uint8List> get stream => _outbound.stream;

  @override
  StreamSink<List<int>> get sink => _inbound.sink;

  @override
  Future<void> get done => _gone.future;

  @override
  Future<void> close() async {}

  @override
  void destroy() {
    if (!_gone.isCompleted) _gone.complete();
  }

  @override
  Future<void> flush() async {}
}

class _Rig {
  _Rig(this.host, this.dials);

  final WebBridgeHost host;

  /// `host:port` of every dial, in order.
  final List<String> dials;
}

/// A machine whose pages are opened by a real [WebBridgeHost].
class _Bridged extends FakeTransport {
  _Bridged(this.host);

  final WebBridgeHost host;

  @override
  Future<WebBridgeInfo> openWebBridge(WebBridgeSpec spec) => host.open(spec);
}

_Rig _rig({
  required int Function() targetPort,
  Duration idle = const Duration(minutes: 10),
  Object? Function(int call)? failDial,

  /// Dials after the first (the probe made when the listener opens) wait for this.
  Future<void>? dialWait,
}) {
  final dials = <String>[];
  final fs = FakeFs();
  final host = WebBridgeHost(
    stat: fs.stat,
    read: fs.read,
    idle: idle,
    dial: (h, p) async {
      dials.add('$h:$p');
      final fail = failDial?.call(dials.length);
      if (fail != null) throw fail;
      if (dials.length > 1) await dialWait;
      return SSHSocket.connect('127.0.0.1', targetPort());
    },
  );
  addTearDown(host.close);
  return _Rig(host, dials);
}

Future<String> _signIn(WebBridgeInfo info) async => cookieFrom(
      await rawRequest(info.entryPort, target: '/__herdr/open?t=${info.token}&to=%2F'),
    );

/// A browser connection to the listener that keeps what comes back.
class _Conn {
  _Conn(this.socket) {
    socket.listen(
      (d) {
        got.add(d);
        _check();
      },
      onDone: () {
        closed = true;
        _check();
      },
      onError: (Object _) => closed = true,
    );
  }

  final Socket socket;
  final got = BytesBuilder(copy: false);
  var closed = false;
  final _waiters = <(int, Completer<void>)>[];

  static Future<_Conn> open(int port) async =>
      _Conn(await Socket.connect(InternetAddress.loopbackIPv4, port));

  void _check() {
    for (final w in _waiters.toList()) {
      if (got.length >= w.$1 || closed) {
        _waiters.remove(w);
        w.$2.complete();
      }
    }
  }

  /// Waits until [n] bytes arrived in all (or the connection closed).
  Future<Uint8List> waitFor(int n) async {
    if (got.length < n && !closed) {
      final c = Completer<void>();
      _waiters.add((n, c));
      await c.future.timeout(const Duration(seconds: 5));
    }
    return got.toBytes();
  }
}

String _head(int port, String cookie, {String path = '/x', Map<String, String> extra = const {}}) =>
    'GET $path HTTP/1.1\r\nHost: localhost:$port\r\nCookie: $cookie\r\n'
    '${[for (final e in extra.entries) '${e.key}: ${e.value}\r\n'].join()}\r\n';

/// What the machine receives of [head]: the listener's own cookie stays here.
String _arrives(String head, String cookie) => head.replaceFirst('Cookie: $cookie\r\n', '');

void main() {
  const spec = PortForward('localhost', 3000, machineName: 'build-box');

  group('the gate: nothing reaches the machine without the token', () {
    test('no cookie, the entry URL and a foreign Host are answered here and never dial', () async {
      final echo = _Echo();
      await echo.start();
      final rig = _rig(targetPort: () => echo.port);
      final info = await rig.host.open(PortForward('127.0.0.1', echo.port, machineName: 'build-box'));
      rig.dials.clear();

      final bare = await rawRequest(info.port, target: '/api');
      expect(bare.status, 403);

      // The entry URL is answered on its own port, and hands the cookie the
      // forward's port checks (cookies ignore ports) before sending the browser there.
      final entry = await rawRequest(info.entryPort, target: '/__herdr/open?t=${info.token}&to=%2Fapp%3Fa%3D1');
      expect(entry.status, 200);
      expect(sendsTo(entry), 'http://localhost:${info.port}/app?a=1');
      expect(entry.headers['set-cookie'], contains('herdr_${info.port}=${info.token}'));
      expect((await rawRequest(info.entryPort, target: '/__herdr/open?t=bad&to=%2F')).status, 403);
      for (final to in [
        '%2F%2Fevil.example',
        '%2F%09%2Fevil.example',
        '%2F%0A%2Fevil.example',
        '%2F%0D%2Fevil.example',
        '%2F%20%2Fevil.example',
        '%2F%C3%A9',
      ]) {
        final r = await rawRequest(info.entryPort, target: '/__herdr/open?t=${info.token}&to=$to');
        expect(r.status, 200, reason: to);
        expect(sendsTo(r), 'http://localhost:${info.port}/', reason: to);
      }
      final foreignEntry = await rawRequest(
        info.entryPort,
        target: '/__herdr/open?t=${info.token}&to=%2F',
        host: 'evil.example:${info.entryPort}',
      );
      expect(foreignEntry.status, 403);
      expect(foreignEntry.headers.containsKey('set-cookie'), isFalse);

      final cookie = cookieFrom(entry);
      final rebound = await rawRequest(
        info.port,
        target: '/api',
        host: 'evil.example:${info.port}',
        headers: {'Cookie': cookie},
      );
      expect(rebound.status, 403);
      expect(rig.dials, isEmpty);
      expect(echo.received.length, 0);
    });

    test('a page of another open listener may call without a cookie, a page from anywhere else may not', () async {
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => http.close(force: true));
      http.listen((r) {
        r.response.write('ok');
        r.response.close();
      });
      final rig = _rig(targetPort: () => http.port);
      final api = await rig.host.open(PortForward('127.0.0.1', http.port, machineName: 'build-box'));
      final front = await rig.host.open(const StaticSite('/site', machineName: 'build-box'));
      rig.dials.clear();

      Future<RawReply> call(Map<String, String> headers) =>
          rawRequest(api.port, target: '/api', headers: headers, timeout: const Duration(seconds: 1));

      final sibling = await call({'Sec-Fetch-Site': 'same-site', 'Origin': 'http://localhost:${front.port}'});
      expect(sibling.status, 200);
      expect(sibling.text, contains('ok'));
      expect(rig.dials, hasLength(1));
      rig.dials.clear();

      expect((await call({'Sec-Fetch-Site': 'cross-site', 'Origin': 'http://localhost:${front.port}'})).status, 403);
      expect((await call({'Sec-Fetch-Site': 'same-site', 'Origin': 'http://localhost:1'})).status, 403);
      expect((await call({'Sec-Fetch-Site': 'same-site', 'Origin': 'http://127.0.0.1:${front.port}'})).status, 403);
      expect((await call({'Origin': 'http://localhost:${front.port}'})).status, 403);
      expect(rig.dials, isEmpty);
    });

    test('a page of the listener itself is no sibling: a same-origin request carries the cookie anyway', () async {
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => http.close(force: true));
      var served = 0;
      http.listen((r) {
        served++;
        r.response.write('ok');
        r.response.close();
      });
      final rig = _rig(targetPort: () => http.port);
      final api = await rig.host.open(PortForward('127.0.0.1', http.port, machineName: 'build-box'));
      final front = await rig.host.open(const StaticSite('/site', machineName: 'build-box'));
      rig.dials.clear();
      Future<RawReply> call(int origin) => rawRequest(
            api.port,
            target: '/api',
            headers: {'Sec-Fetch-Site': 'same-site', 'Origin': 'http://localhost:$origin'},
            timeout: const Duration(seconds: 1),
          );
      expect((await call(api.port)).status, 403);
      expect(rig.dials, isEmpty);
      expect(served, 0);
      // Another listener's page still gets through.
      expect((await call(front.port)).status, 200);
      expect(rig.dials, hasLength(1));
    });

    test('an invalid escape in the token, the destination or the path never takes the listener down', () async {
      final echo = _Echo();
      await echo.start();
      final rig = _rig(targetPort: () => echo.port);
      final info = await rig.host.open(PortForward('127.0.0.1', echo.port, machineName: 'build-box'));
      final cookie = await _signIn(info);
      rig.dials.clear();

      for (final t in ['%ff', '%', '%zz', '%c0%af']) {
        final r = await rawRequest(info.entryPort, target: '/__herdr/open?t=$t&to=%2F');
        expect(r.status, 403, reason: t);
        expect(r.timedOut, isFalse, reason: t);
      }
      for (final to in ['%ff', '%', '%zz']) {
        final r = await rawRequest(info.entryPort, target: '/__herdr/open?t=${info.token}&to=$to');
        expect(r.status, 200, reason: to);
        expect(sendsTo(r), 'http://localhost:${info.port}/', reason: to);
      }
      expect((await rawRequest(info.port, target: '/%ff/x')).status, 403, reason: 'no cookie');
      expect(rig.dials, isEmpty, reason: 'none of these is let through');

      // With the cookie the path is the machine's business, byte for byte.
      final conn = await _Conn.open(info.port);
      final head = _head(info.port, cookie, path: '/%ff/x');
      conn.socket.add(latin1.encode(head));
      final arrived = _arrives(head, cookie);
      expect(latin1.decode(await conn.waitFor(arrived.length)), arrived);
      await conn.socket.close();

      // And the listener answers a good request afterwards.
      expect(sendsTo(await rawRequest(info.entryPort, target: '/__herdr/open?t=${info.token}&to=%2Fok')), 'http://localhost:${info.port}/ok');
    });
  });

  group('after the gate it is the machine\'s bytes, unchanged', () {
    test('a request, a second one on the same connection and upgrade bytes reach the machine exactly', () async {
      final echo = _Echo();
      await echo.start();
      final rig = _rig(targetPort: () => echo.port);
      final info = await rig.host.open(PortForward('localhost', echo.port, machineName: 'build-box'));
      final cookie = await _signIn(info);
      final conn = await _Conn.open(info.port);

      final first = _arrives(_head(info.port, cookie, extra: {'X-A': 'one'}), cookie);
      conn.socket.add(latin1.encode(_head(info.port, cookie, extra: {'X-A': 'one'})));
      expect(latin1.decode(await conn.waitFor(first.length)), first);

      // Keep-alive: the same connection, no new dial.
      final dials = rig.dials.length;
      // Later requests on the connection are the machine's bytes as they are:
      // only the first head is looked at.
      final second = _head(info.port, cookie, path: '/second');
      conn.socket.add(latin1.encode(second));
      // A WebSocket frame after an upgrade is not text at all.
      final frame = Uint8List.fromList(List.generate(300, (i) => i % 256));
      conn.socket.add(frame);
      final all = await conn.waitFor(first.length + second.length + frame.length);
      expect(all.sublist(first.length), [...latin1.encode(second), ...frame]);
      expect(rig.dials.length, dials);
      expect(echo.received.length, all.length);

      await conn.socket.close();
    });

    test('the listener cookies stay here, every other cookie and byte goes through as it was', () async {
      final echo = _Echo();
      await echo.start();
      final rig = _rig(targetPort: () => echo.port);
      final info = await rig.host.open(PortForward('127.0.0.1', echo.port, machineName: 'build-box'));
      final p = info.port;
      final token = info.token;
      // The browser holds the token of every listener it was sent to, this one
      // and another machine's on a colliding port number.
      String sent(String cookies) =>
          'POST /x HTTP/1.1\r\nHost: localhost:$p\r\nX-Before: 1\r\n$cookies'
          'X-After: 2\r\nContent-Length: 5\r\n\r\nhello';
      final request = sent(
        'cookie: herdr_9=zzz\r\n'
        'Cookie: theme=dark; herdr_$p=$token; sid=a=b;c; herdr_41234=other\r\n',
      );
      final expected = sent('Cookie: theme=dark; sid=a=b;c\r\n');
      final conn = await _Conn.open(p);
      conn.socket.add(latin1.encode(request));
      expect(latin1.decode(await conn.waitFor(expected.length)), expected);
      await conn.socket.close();
      expect(latin1.decode(echo.received.toBytes()), expected);
    });

    test('a Cookie header with only listener cookies is dropped, and a request without one is untouched', () async {
      final echo = _Echo();
      await echo.start();
      final rig = _rig(targetPort: () => echo.port);
      final info = await rig.host.open(PortForward('127.0.0.1', echo.port, machineName: 'build-box'));
      final front = await rig.host.open(const StaticSite('/site', machineName: 'build-box'));
      final cookie = await _signIn(info);

      final only = _head(info.port, cookie, extra: {'X-A': 'one'});
      var conn = await _Conn.open(info.port);
      conn.socket.add(latin1.encode(only));
      final withoutCookie = 'GET /x HTTP/1.1\r\nHost: localhost:${info.port}\r\nX-A: one\r\n\r\n';
      expect(latin1.decode(await conn.waitFor(withoutCookie.length)), withoutCookie);
      await conn.socket.close();

      // No Cookie at all (a page of the other listener, let through by origin).
      final bare = 'GET /y HTTP/1.1\r\nHost: localhost:${info.port}\r\n'
          'Sec-Fetch-Site: same-site\r\nOrigin: http://localhost:${front.port}\r\n\r\n';
      conn = await _Conn.open(info.port);
      conn.socket.add(latin1.encode(bare));
      expect(latin1.decode(await conn.waitFor(bare.length)), bare);
      await conn.socket.close();
    });

    test('a server that closes ends the browser connection, and the browser closing ends it for the server', () async {
      final target = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(target.close);
      // The probe made when the listener opens is the first connection; the browser's is the second.
      final connections = <Completer<void>>[];
      target.listen((s) {
        final closed = Completer<void>();
        connections.add(closed);
        s.listen((_) => s.add(utf8.encode('bye')), onDone: closed.complete);
      });
      final rig = _rig(targetPort: () => target.port);
      final info = await rig.host.open(PortForward('127.0.0.1', target.port, machineName: 'build-box'));
      final cookie = await _signIn(info);
      final conn = await _Conn.open(info.port);
      conn.socket.add(latin1.encode(_head(info.port, cookie)));
      expect(utf8.decode(await conn.waitFor(3)), 'bye');
      await conn.socket.close();
      expect(connections, hasLength(2));
      await connections.last.future.timeout(const Duration(seconds: 5));
    });
  });

  group('when the machine cannot be reached', () {
    test('the browser gets a page that names the port and the machine', () async {
      final rig = _rig(
        targetPort: () => 1,
        // The probe made when the listener opens is let through; the page's request is the one that fails.
        failDial: (call) => call == 1 ? null : const HerdrTransportException('connect failed'),
      );
      final info = await rig.host.open(const PortForward('localhost', 3000, machineName: 'build-box'));
      final cookie = await _signIn(info);
      final r = await rawRequest(info.port, target: '/', headers: {'Cookie': cookie});
      expect(r.status, 502);
      expect(r.text, allOf(contains('localhost:3000'), contains('build-box'), contains('Reload')));
    });

    test('a host that forbids forwarding is said so when the link is opened, not in a page', () async {
      final rig = _rig(
        targetPort: () => 1,
        failDial: (_) => const HerdrTransportException('the machine does not allow port forwarding', fatal: true),
      );
      await expectLater(
        rig.host.open(spec),
        throwsA(isA<HerdrTransportException>().having((e) => e.message, 'message', contains('does not allow port forwarding'))),
      );
      expect(rig.host.livePorts, isEmpty);
    });

    test('a target that is not up yet still opens: the page explains, and a later start works', () async {
      final rig = _rig(targetPort: () => 1, failDial: (call) => call == 1 ? const HerdrTransportException('refused') : null);
      final info = await rig.host.open(spec);
      expect(info.port, greaterThan(0));
    });
  });

  group('the local port', () {
    test('a page written for localhost:N gets the same port number when it is free', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final free = probe.port;
      await probe.close();
      final rig = _rig(targetPort: () => 1);
      final info = await rig.host.open(PortForward('localhost', free, machineName: 'm'));
      expect(info.port, free);
    });

    test('a taken port number falls back to another one instead of failing', () async {
      final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(taken.close);
      final rig = _rig(targetPort: () => 1);
      final info = await rig.host.open(PortForward('localhost', taken.port, machineName: 'm'));
      expect(info.port, isNot(taken.port));
      expect(info.port, greaterThan(0));
    });

    test('the same spec is one port and one token; another port is another listener', () async {
      final rig = _rig(targetPort: () => 1);
      final a = await rig.host.open(spec);
      expect(await rig.host.open(spec), a);
      final b = await rig.host.open(const PortForward('localhost', 3001, machineName: 'build-box'));
      expect(b.port, isNot(a.port));
      expect(b.token, isNot(a.token));
      expect(a.token, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('an idle listener closes, and a relaunch gets the same port and token', () async {
      final echo = _Echo();
      await echo.start();
      final rig = _rig(targetPort: () => echo.port, idle: const Duration(milliseconds: 150));
      final info = await rig.host.open(const PortForward('localhost', 4999, machineName: 'm'));
      await Future<void>.delayed(const Duration(milliseconds: 450));
      await expectLater(Socket.connect(InternetAddress.loopbackIPv4, info.port), throwsA(isA<SocketException>()));
      expect(rig.host.livePorts, isEmpty);
      final back = await rig.host.open(const PortForward('localhost', 4999, machineName: 'm'));
      expect((back.port, back.token), (info.port, info.token));
    });

    test('a browser that leaves while the machine is still being dialed does not hold the listener up', () async {
      final echo = _Echo();
      await echo.start();
      final never = Completer<void>(); // a dial on a bad link: it takes its 15 s
      final rig = _rig(targetPort: () => echo.port, idle: const Duration(milliseconds: 150), dialWait: never.future);
      final info = await rig.host.open(PortForward('localhost', echo.port, machineName: 'm'));
      final cookie = await _signIn(info);
      final conn = await _Conn.open(info.port);
      conn.socket.add(latin1.encode(_head(info.port, cookie)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(rig.dials, hasLength(2), reason: 'the probe, and the one the browser asked for');
      await conn.socket.close();
      conn.socket.destroy();

      await Future<void>.delayed(const Duration(milliseconds: 700));
      await expectLater(Socket.connect(InternetAddress.loopbackIPv4, info.port), throwsA(isA<SocketException>()));
      never.complete();
    });

    test('an open connection keeps the listener up past the idle time', () async {
      final echo = _Echo();
      await echo.start();
      final rig = _rig(targetPort: () => echo.port, idle: const Duration(milliseconds: 150));
      final info = await rig.host.open(PortForward('localhost', echo.port, machineName: 'm'));
      final cookie = await _signIn(info);
      final conn = await _Conn.open(info.port);
      final head = _head(info.port, cookie);
      conn.socket.add(latin1.encode(head));
      final arrived = _arrives(head, cookie).length;
      await conn.waitFor(arrived);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      conn.socket.add(latin1.encode('later'));
      expect(latin1.decode((await conn.waitFor(arrived + 5)).sublist(arrived)), 'later');
      await conn.socket.close();
    });
  });

  group('the entry URL is answered on its own port', () {
    test('it never goes down a connection that belongs to the dev server', () async {
      final echo = _Echo();
      await echo.start();
      final rig = _rig(targetPort: () => echo.port);
      final info = await rig.host.open(PortForward('127.0.0.1', echo.port, machineName: 'build-box'));
      expect(info.entryPort, isNot(info.port));
      final cookie = await _signIn(info);

      // A tab already holds a kept connection to the dev server's port.
      final kept = await _Conn.open(info.port);
      final head = _head(info.port, cookie);
      kept.socket.add(latin1.encode(head));
      await kept.waitFor(_arrives(head, cookie).length);

      // The person opens a link again. The entry URL names the entry port, so
      // the browser cannot put it on that connection; on its own connection
      // the entry listener answers two in a row, as a browser keeping it alive does.
      final entry = await _Conn.open(info.entryPort);
      final ask = 'GET /__herdr/open?t=${info.token}&to=%2Fagain HTTP/1.1\r\nHost: localhost:${info.entryPort}\r\n\r\n';
      entry.socket.add(latin1.encode(ask));
      entry.socket.add(latin1.encode(ask));
      for (var i = 0; i < 100 && '</html>'.allMatches(latin1.decode(entry.got.toBytes())).length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final answers = latin1.decode(entry.got.toBytes());
      final lower = answers.toLowerCase();
      expect('refresh: 0; url=http://localhost:${info.port}/again'.allMatches(lower).length, 2);
      expect('herdr_${info.port}=${info.token}'.allMatches(answers).length, 2);

      // Asked for by hand on the dev server's own port, it is refused here.
      final direct = await rawRequest(info.port, target: '/__herdr/open?t=${info.token}&to=%2F', headers: {'Cookie': cookie});
      expect(direct.status, 404);

      final seen = latin1.decode(echo.received.toBytes());
      expect(seen, isNot(contains('__herdr/open')));
      expect(seen, isNot(contains(info.token)));
      await kept.socket.close();
      await entry.socket.close();
    });

    test('the token names the forward it opens, a static site is not one, and the listener goes with the last forward', () async {
      final echo = _Echo();
      await echo.start();
      final rig = _rig(targetPort: () => echo.port, idle: const Duration(milliseconds: 400));
      final site = await rig.host.open(const StaticSite('/site', machineName: 'm'));
      expect(site.entryPort, site.port, reason: 'a static site answers its own entry URL');
      final a = await rig.host.open(const PortForward('localhost', 4998, machineName: 'm'));
      final b = await rig.host.open(const PortForward('localhost', 4999, machineName: 'm'));
      expect(b.entryPort, a.entryPort, reason: 'one entry listener serves every forward');

      Future<RawReply> entry(String token) =>
          rawRequest(a.entryPort, target: '/__herdr/open?t=$token&to=%2Fx');
      final forB = await entry(b.token);
      expect(sendsTo(forB), 'http://localhost:${b.port}/x');
      expect(forB.headers['set-cookie'], contains('herdr_${b.port}=${b.token}'));
      expect((await entry(site.token)).status, 403, reason: 'the static site opens at its own port');
      expect((await entry('0' * 32)).status, 403);

      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(rig.host.livePorts, isEmpty);
      await expectLater(Socket.connect(InternetAddress.loopbackIPv4, a.entryPort), throwsA(isA<SocketException>()));

      final back = await rig.host.open(const PortForward('localhost', 4998, machineName: 'm'));
      expect((back.port, back.token), (a.port, a.token), reason: 'a tab left open still works');
      expect((await rawRequest(back.entryPort, target: '/__herdr/open?t=${back.token}&to=%2F')).status, 200);
    });
  });

  group('opened in a Custom Tab', () {
    test('a link the agent wrote opens the server\'s page, not the listener\'s refusal', () async {
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => http.close(force: true));
      final asked = <String>[];
      http.listen((r) {
        asked.add('${r.uri}');
        r.response.write('served ${r.uri}');
        r.response.close();
      });
      final rig = _rig(targetPort: () => http.port);
      final web = WebPreview(_Bridged(rig.host), machineName: 'build-box');
      final entry = await web.forwardUrl(Uri.parse('http://127.0.0.1:${http.port}/docs?a=1'));

      final visit = await openInCustomTab(entry);
      expect(visit.page.status, 200, reason: visit.page.text);
      expect(visit.page.text, contains('served /docs?a=1'));
      expect(asked, ['/docs?a=1'], reason: 'the dev server never sees the entry URL');

      // The person taps Continue rather than waiting: the same page.
      final clicked = await openInCustomTab(entry, clickContinue: true);
      expect(clicked.page.text, contains('served /docs?a=1'), reason: clicked.page.text);

      // Opened again, the cookie already set: straight from the entry URL to the page.
      final CookieJar jar = {};
      await openInCustomTab(entry, jar: jar);
      final again = await openInCustomTab(entry, jar: jar);
      expect(again.page.text, contains('served /docs?a=1'), reason: again.page.text);
      expect(again.steps, hasLength(2), reason: '${again.steps}');
    });
  });

  group('a browser that sends faster than the machine takes', () {
    test('is not read faster than the machine takes, and all of it arrives once the machine drains', () async {
      final machines = <_SlowMachine>[];
      final host = WebBridgeHost(
        stat: FakeFs().stat,
        read: FakeFs().read,
        dial: (h, p) async {
          final machine = _SlowMachine();
          machines.add(machine);
          return machine;
        },
      );
      addTearDown(host.close);
      final info = await host.open(const PortForward('localhost', 3000, machineName: 'm'));
      final cookie = await _signIn(info);

      const total = 32 * 1024 * 1024;
      final head = latin1.encode(
        'POST /up HTTP/1.1\r\nHost: localhost:${info.port}\r\nCookie: $cookie\r\nContent-Length: $total\r\n\r\n',
      );
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, info.port);
      socket.listen((_) {}, onError: (Object _) {});
      addTearDown(socket.destroy);
      final chunk = Uint8List.fromList(List.generate(64 * 1024, (i) => (i * 31) % 256));
      var written = 0;
      final upload = () async {
        socket.add(head);
        while (written < total) {
          socket.add(chunk);
          await socket.flush();
          written += chunk.length;
        }
      }();

      // The machine takes nothing: the browser's writes must stall well short
      // of everything instead of being swallowed into memory.
      await Future<void>.delayed(const Duration(seconds: 1));
      final stalledAt = written;
      var done = false;
      unawaited(upload.then((_) => done = true));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(done, isFalse);
      expect(stalledAt, lessThan(total * 3 ~/ 4), reason: 'the kernel holds a few MiB, not everything');
      expect(written, stalledAt, reason: 'still stalled');
      expect(machines[1].received, 0);

      machines[1].drain();
      await upload.timeout(const Duration(seconds: 30));
      // The listener's own cookie is dropped from the head the machine gets.
      final dropped = head.length - 'Cookie: $cookie\r\n'.length;
      for (var i = 0; i < 200 && machines[1].received < dropped + total; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(machines[1].received, dropped + total);

      // The browser closing its side still reaches the machine as the end of the request.
      await socket.close();
      await machines[1].ended.timeout(const Duration(seconds: 5));
    });
  });

  group('a request that repeats a header', () {
    test('Cookie lines are one list, and two Host lines are not a name the listener knows', () async {
      final echo = _Echo();
      await echo.start();
      final rig = _rig(targetPort: () => echo.port);
      final info = await rig.host.open(PortForward('127.0.0.1', echo.port, machineName: 'build-box'));
      final cookie = await _signIn(info);
      rig.dials.clear();

      // The listener's cookie on the second line must still open the gate.
      final conn = await _Conn.open(info.port);
      conn.socket.add(latin1.encode('GET /x HTTP/1.1\r\nHost: localhost:${info.port}\r\nCookie: theme=dark\r\nCookie: $cookie\r\n\r\n'));
      final arrived = 'GET /x HTTP/1.1\r\nHost: localhost:${info.port}\r\nCookie: theme=dark\r\n\r\n';
      expect(latin1.decode(await conn.waitFor(arrived.length)), arrived);
      await conn.socket.close();

      // A second Host line is no way around the allowlist, in either order.
      for (final host in ['evil.example\r\nHost: localhost:${info.port}', 'localhost:${info.port}\r\nHost: evil.example']) {
        rig.dials.clear();
        final r = await rawRequest(info.port, target: '/x', host: host, headers: {'Cookie': cookie});
        expect(r.status, 403, reason: host);
        expect(rig.dials, isEmpty, reason: host);
      }
    });
  });
}
