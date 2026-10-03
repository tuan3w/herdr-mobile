@TestOn('linux || mac-os')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/bridge_command.dart';

/// Runs [command] the way an SSH server would (`sh -c`) with a controlled
/// $HOME and a minimal PATH, so the host's real herdr cannot interfere.
Future<({String out, String err, int code})> _run(
  String command,
  Directory home, {
  String input = '',
  Map<String, String> env = const {},
}) async {
  final p = await Process.start(
    '/bin/sh',
    ['-c', command],
    environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin', ...env},
    includeParentEnvironment: false,
  );
  p.stdin.write(input);
  await p.stdin.close();
  final out = utf8.decodeStream(p.stdout);
  final err = utf8.decodeStream(p.stderr);
  final code = await p.exitCode.timeout(const Duration(seconds: 10));
  return (out: await out, err: await err, code: code);
}

bool _has(String bin) =>
    ['/usr/bin', '/bin'].any((d) => File('$d/$bin').existsSync());

void main() {
  late Directory home;
  setUp(() => home = Directory.systemTemp.createTempSync('bridge_test'));
  tearDown(() => home.deleteSync(recursive: true));

  group('fallback relay to the unix socket (older herdr)', () {
    late ServerSocket server;
    late String socketPath;
    final received = <String>[];

    setUp(() async {
      Directory('${home.path}/.config/herdr').createSync(recursive: true);
      socketPath = '${home.path}/.config/herdr/herdr.sock';
      received.clear();
      server = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      server.listen((client) {
        // One request per connection, like herdr.
        utf8.decoder.bind(client).transform(const LineSplitter()).first.then((line) {
          received.add(line);
          client.write('{"id":"1","result":{"type":"pong"}}\n');
          return client.close();
        });
      });
    });
    tearDown(() => server.close());

    test('relays a request line to the socket and the response back', () async {
      final r = await _run(
        buildBridgeCommand(session: 'default'),
        home,
        input: '{"id":"1","method":"ping","params":{}}\n',
      );

      expect(r.err, isEmpty);
      expect(r.out.trim(), '{"id":"1","result":{"type":"pong"}}');
      expect(received, ['{"id":"1","method":"ping","params":{}}']);
    }, skip: _has('socat') || _has('python3') ? false : 'needs socat or python3');

    test('honours an explicit socket path for non-default sessions', () async {
      final r = await _run(
        buildBridgeCommand(session: 'work', socketPath: socketPath),
        home,
        input: '{"id":"1","method":"ping","params":{}}\n',
      );

      expect(r.out.trim(), contains('pong'));
    }, skip: _has('socat') || _has('python3') ? false : 'needs socat or python3');

    test('python relay works when socat is absent', () async {
      // Hide socat by pointing PATH at a dir containing only python3.
      final bin = Directory('${home.path}/bin')..createSync();
      final py = ['/usr/bin/python3', '/bin/python3'].firstWhere(
          (p) => File(p).existsSync(),
          orElse: () => '');
      if (py.isEmpty) return;
      Link('${bin.path}/python3').createSync(py);
      for (final tool in ['sh', 'base64', 'echo']) {
        for (final d in ['/usr/bin', '/bin']) {
          if (File('$d/$tool').existsSync()) {
            Link('${bin.path}/$tool').createSync('$d/$tool');
            break;
          }
        }
      }
      final p = await Process.start(
        '/bin/sh',
        ['-c', buildBridgeCommand(session: 'default')],
        environment: {'HOME': home.path, 'PATH': bin.path},
        includeParentEnvironment: false,
      );
      p.stdin.write('{"id":"1","method":"ping","params":{}}\n');
      await p.stdin.close();
      final out = await utf8.decodeStream(p.stdout);
      await p.exitCode;

      expect(out.trim(), contains('pong'));
    });
  });

  group('herdr remote-api-bridge preference (herdr >= 0.9)', () {
    File stubHerdr({required bool hasBridge}) {
      final dir = Directory('${home.path}/.local/bin')..createSync(recursive: true);
      return File('${dir.path}/herdr')
        ..writeAsStringSync('''#!/bin/sh
# args: [--session NAME] remote-api-bridge [--check]
case "\$*" in
  *--check*) [ "$hasBridge" = true ] && echo herdr-api-bridge-v1 || echo "unknown command" ;;
  *remote-api-bridge*) echo "BRIDGE:\$*" ;;
esac
''')
        ..setLastModifiedSync(DateTime.now());
    }

    Future<void> chmodX(File f) async => Process.run('chmod', ['+x', f.path]);

    test('uses the bridge and passes the session name when supported', () async {
      await chmodX(stubHerdr(hasBridge: true));

      final r = await _run(buildBridgeCommand(session: 'agents'), home);

      expect(r.out.trim(), 'BRIDGE:--session agents remote-api-bridge');
    });

    test('ignores a herdr that prints something else for --check', () async {
      await chmodX(stubHerdr(hasBridge: false));
      // No socket exists, so the fallback must be reached and fail visibly.
      final r = await _run(buildBridgeCommand(session: 'default'), home);

      expect(r.out, isNot(contains('BRIDGE')));
      expect(r.code, isNot(0));
    });
  });

  test('a named session without a socket path fails with exit 78 and a hint',
      () async {
    final r = await _run(buildBridgeCommand(session: 'work'), home);

    expect(r.code, 78);
    expect(r.err, contains('work'));
  });

  test('rejects session names that could inject shell', () {
    for (final bad in ['a b', r'x;rm -rf /', r'$(id)', "a'b", '', '../x']) {
      expect(() => buildBridgeCommand(session: bad), throwsArgumentError,
          reason: bad);
    }
  });

  test('a socket path with quotes cannot break out of the command', () async {
    final evil = "x'; touch ${home.path}/pwned; '";
    final r = await _run(
        buildBridgeCommand(session: 'work', socketPath: evil), home);

    expect(File('${home.path}/pwned').existsSync(), isFalse);
    expect(r.code, isNot(0));
  });

  group('multiplexed request channel', () {
    late String xdg;
    setUp(() => xdg = Directory('${home.path}/xdg').path);

    Future<_MuxProc> start({
      String session = 'default',
      String? socketPath,
      Map<String, String>? env,
    }) =>
        _MuxProc.start(
          buildMuxCommand(session: session, socketPath: socketPath),
          home,
          env ?? {'XDG_CONFIG_HOME': xdg},
        );

    String pong(Object? id) => jsonEncode({'id': id, 'result': {'type': 'pong'}});

    Future<_FakeHerdr> serve(
      String path, [
      Future<String?> Function(Map<String, dynamic>)? handler,
    ]) =>
        _FakeHerdr.bind(path, handler ?? (req) async => pong(req['id']));

    test('prints the ready line before anything else', () async {
      final herdr = await serve('$xdg/herdr/herdr.sock');
      final mux = await start();
      addTearDown(() async {
        await mux.stop();
        await herdr.close();
      });

      expect(await mux.next(), muxReadyLine);
    });

    test('answers pipelined requests and matches them by id out of order',
        () async {
      final fastSeen = Completer<void>();
      final herdr = await serve('$xdg/herdr/herdr.sock', (req) async {
        if (req['id'] == 'slow') {
          await fastSeen.future; // replies only after 'fast' was served
          // Let the fast response reach the wire first; without a real delay the
          // continuation races ahead of the fast handler's own write.
          await Future<void>.delayed(const Duration(milliseconds: 100));
        } else if (!fastSeen.isCompleted) {
          fastSeen.complete();
        }
        return pong(req['id']);
      });
      final mux = await start();
      addTearDown(() async {
        await mux.stop();
        await herdr.close();
      });
      await mux.next();

      mux.send({'id': 'slow', 'method': 'ping', 'params': {}});
      mux.send({'id': 'fast', 'method': 'ping', 'params': {}});

      expect(jsonDecode(await mux.next())['id'], 'fast');
      expect(jsonDecode(await mux.next())['id'], 'slow');
    });

    test('relays a response larger than 1 MB intact', () async {
      final blob = List.filled(1500000, 'x').join();
      final herdr = await serve('$xdg/herdr/herdr.sock', (req) async =>
          jsonEncode({'id': req['id'], 'result': {'blob': blob}}));
      final mux = await start();
      addTearDown(() async {
        await mux.stop();
        await herdr.close();
      });
      await mux.next();

      mux.send({'id': 'big', 'method': 'pane.read', 'params': {}});

      final reply = jsonDecode(await mux.next()) as Map<String, dynamic>;
      expect(reply['id'], 'big');
      expect((reply['result'] as Map)['blob'], blob);
    });

    test('an error herdr could not correlate (id "") comes back under the id it was sent with',
        () async {
      // herdr answers a method it does not know like this (seen on 0.8.2).
      final herdr = await serve(
        '$xdg/herdr/herdr.sock',
        (req) async => req['method'] == 'bogus.method'
            ? '{"id":"","error":{"code":"invalid_request","message":"invalid request: unknown variant `bogus.method`"}}'
            : pong(req['id']),
      );
      final mux = await start();
      addTearDown(() async {
        await mux.stop();
        await herdr.close();
      });
      await mux.next();

      mux.send({'id': 'm7', 'method': 'bogus.method', 'params': {}});
      final reply = jsonDecode(await mux.next()) as Map<String, dynamic>;

      expect(reply['id'], 'm7');
      expect((reply['error'] as Map)['code'], 'invalid_request');
    });
    test('a server that closes without replying yields an error with that id',
        () async {
      final herdr = await serve('$xdg/herdr/herdr.sock', (req) async =>
          req['id'] == 'mute' ? null : pong(req['id']));
      final mux = await start();
      addTearDown(() async {
        await mux.stop();
        await herdr.close();
      });
      await mux.next();

      mux.send({'id': 'mute', 'method': 'ping', 'params': {}});
      final reply = jsonDecode(await mux.next()) as Map<String, dynamic>;

      expect(reply['id'], 'mute');
      expect((reply['error'] as Map)['code'], 'bridge_error');
      // The channel keeps serving afterwards.
      mux.send({'id': 'next', 'method': 'ping', 'params': {}});
      expect(jsonDecode(await mux.next())['id'], 'next');
    });

    test('an unreachable socket yields an error with that id', () async {
      // The path exists as a socket at start, but nothing listens any more.
      final herdr = await serve('$xdg/herdr/herdr.sock');
      final mux = await start();
      addTearDown(mux.stop);
      await mux.next();
      await herdr.close();

      mux.send({'id': 'gone', 'method': 'ping', 'params': {}});
      final reply = jsonDecode(await mux.next()) as Map<String, dynamic>;

      expect(reply['id'], 'gone');
      expect((reply['error'] as Map)['code'], 'bridge_error');
    });

    test('still delivers pending responses after stdin closes, then exits 0',
        () async {
      final herdr = await serve('$xdg/herdr/herdr.sock');
      final mux = await start();
      addTearDown(herdr.close);
      await mux.next();

      mux.send({'id': 'last', 'method': 'ping', 'params': {}});
      await mux.process.stdin.close();

      expect(jsonDecode(await mux.next())['id'], 'last');
      expect(await mux.process.exitCode.timeout(const Duration(seconds: 10)), 0);
    });

    test('default session resolves to \$XDG_CONFIG_HOME/herdr/herdr.sock',
        () async {
      final herdr = await serve('$xdg/herdr/herdr.sock');
      final mux = await start();
      addTearDown(() async {
        await mux.stop();
        await herdr.close();
      });
      await mux.next();

      mux.send({'id': 'a', 'method': 'ping', 'params': {}});

      expect(jsonDecode(await mux.next())['id'], 'a');
    });

    test('without XDG_CONFIG_HOME the default session uses \$HOME/.config',
        () async {
      final herdr = await serve('${home.path}/.config/herdr/herdr.sock');
      final mux = await start(env: {});
      addTearDown(() async {
        await mux.stop();
        await herdr.close();
      });
      await mux.next();

      mux.send({'id': 'a', 'method': 'ping', 'params': {}});

      expect(jsonDecode(await mux.next())['id'], 'a');
    });

    test('a named session resolves to sessions/<name>/herdr.sock', () async {
      final herdr = await serve('$xdg/herdr/sessions/work/herdr.sock', (req) async =>
          jsonEncode({'id': req['id'], 'result': {'type': 'work'}}));
      // A default-session server must not be picked for a named session.
      final other = await serve('$xdg/herdr/herdr.sock', (req) async =>
          jsonEncode({'id': req['id'], 'result': {'type': 'default'}}));
      final mux = await start(session: 'work');
      addTearDown(() async {
        await mux.stop();
        await herdr.close();
        await other.close();
      });
      await mux.next();

      mux.send({'id': 'a', 'method': 'ping', 'params': {}});

      expect(jsonDecode(await mux.next())['result']['type'], 'work');
    });

    test('an explicit socket path wins over the session-derived one', () async {
      final herdr = await serve('${home.path}/custom.sock');
      final mux = await start(session: 'work', socketPath: '${home.path}/custom.sock');
      addTearDown(() async {
        await mux.stop();
        await herdr.close();
      });
      await mux.next();

      mux.send({'id': 'a', 'method': 'ping', 'params': {}});

      expect(jsonDecode(await mux.next())['id'], 'a');
    });

    test('a missing socket exits 78 with a hint and no ready line', () async {
      final r = await _run(
        buildMuxCommand(session: 'work'),
        home,
        env: {'XDG_CONFIG_HOME': xdg},
      );

      expect(r.code, 78);
      expect(r.out, isEmpty);
      expect(r.err, contains('no herdr socket'));
      expect(r.err, contains('$xdg/herdr/sessions/work/herdr.sock'));
    });

    test('missing python3 exits 78 with a hint', () async {
      final bin = Directory('${home.path}/bin')..createSync();
      for (final tool in ['sh', 'base64']) {
        for (final d in ['/usr/bin', '/bin']) {
          if (File('$d/$tool').existsSync()) {
            Link('${bin.path}/$tool').createSync('$d/$tool');
            break;
          }
        }
      }
      final p = await Process.start(
        '/bin/sh',
        ['-c', buildMuxCommand(session: 'default')],
        environment: {'HOME': home.path, 'PATH': bin.path},
        includeParentEnvironment: false,
      );
      await p.stdin.close();
      final err = await utf8.decodeStream(p.stderr);

      expect(await p.exitCode, 78);
      expect(err, contains('python3'));
    });

    test('shell metacharacters in a socket path are never executed', () async {
      for (final evil in [
        "x'; touch ${home.path}/pwned; '",
        '\$(touch ${home.path}/pwned)',
        '`touch ${home.path}/pwned`',
        'x"; touch ${home.path}/pwned; "',
      ]) {
        final r = await _run(
            buildMuxCommand(session: 'work', socketPath: evil), home);

        expect(File('${home.path}/pwned').existsSync(), isFalse, reason: evil);
        expect(r.code, 78, reason: evil);
      }
    });

    test('rejects session names that could inject shell', () {
      for (final bad in ['a b', r'x;rm -rf /', r'$(id)', "a'b", '', '../x']) {
        expect(() => buildMuxCommand(session: bad), throwsArgumentError,
            reason: bad);
      }
    });
  }, skip: _has('python3') ? false : 'needs python3');
}

/// A running mux command with line-oriented access to its stdout.
class _MuxProc {
  _MuxProc._(this.process)
      : _lines = StreamIterator(
            utf8.decoder.bind(process.stdout).transform(const LineSplitter()));

  static Future<_MuxProc> start(
    String command,
    Directory home,
    Map<String, String> env,
  ) async {
    final p = await Process.start(
      '/bin/sh',
      ['-c', command],
      environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin', ...env},
      includeParentEnvironment: false,
    );
    unawaited(p.stderr.drain<void>());
    return _MuxProc._(p);
  }

  final Process process;
  final StreamIterator<String> _lines;

  void send(Map<String, dynamic> request) =>
      process.stdin.writeln(jsonEncode(request));

  Future<String> next() async {
    if (!await _lines.moveNext().timeout(const Duration(seconds: 10))) {
      throw StateError('mux closed its stdout');
    }
    return _lines.current;
  }

  Future<void> stop() async {
    process.kill();
    await process.exitCode;
  }
}

/// Stands in for herdr's socket: one request per connection. [handler]
/// returns the response line, or null to hang up without answering.
class _FakeHerdr {
  _FakeHerdr._(this._server);

  static Future<_FakeHerdr> bind(
    String path,
    Future<String?> Function(Map<String, dynamic> request) handler,
  ) async {
    Directory(File(path).parent.path).createSync(recursive: true);
    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    server.listen((client) async {
      final line = await utf8.decoder
          .bind(client)
          .transform(const LineSplitter())
          .first;
      final reply = await handler(jsonDecode(line) as Map<String, dynamic>);
      if (reply != null) client.write('$reply\n');
      await client.close();
    });
    return _FakeHerdr._(server);
  }

  final ServerSocket _server;

  Future<void> close() async {
    await _server.close();
  }
}
