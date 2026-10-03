@TestOn('linux || mac-os')
library;

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
}) async {
  final p = await Process.start(
    '/bin/sh',
    ['-c', command],
    environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin'},
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
}
