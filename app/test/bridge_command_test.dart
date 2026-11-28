@TestOn('linux || mac-os')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/bridge_command.dart';

/// Runs [command] the way an SSH server would (`sh -c`) with a controlled
/// $HOME and a minimal PATH, so the host's real herdr cannot interfere.
///
/// With [untilAnswered] stdin stays open until the command has printed a whole
/// line, the way the phone's channel does: `socat` stops 0.5 s after it sees
/// stdin end (its default `-t`), so on a busy machine a slow server would be
/// cut off and then write to a socket nobody reads (a broken pipe).
Future<({String out, String err, int code})> _run(
  String command,
  Directory home, {
  String input = '',
  Map<String, String> env = const {},
  bool untilAnswered = false,
}) async {
  final p = await Process.start(
    '/bin/sh',
    ['-c', command],
    environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin', ...env},
    includeParentEnvironment: false,
  );
  p.stdin.write(input);
  final text = StringBuffer();
  final answered = Completer<void>();
  final out = utf8.decoder.bind(p.stdout).forEach((s) {
    text.write(s);
    if (s.contains('\n') && !answered.isCompleted) answered.complete();
  });
  final err = utf8.decodeStream(p.stderr);
  if (untilAnswered) await Future.any([answered.future, p.exitCode]);
  await p.stdin.close();
  final code = await p.exitCode.timeout(const Duration(seconds: 10));
  await out;
  return (out: text.toString(), err: await err, code: code);
}

bool _has(String bin) => ['/usr/bin', '/bin'].any((d) => File('$d/$bin').existsSync());

// The bridge is what carries a herdr request on a host that has no agent
// helper (herdr's own `remote-api-bridge`, else `socat`). The mux and the
// events stream are the helper's (`herdr.mux`, `herdr.events`); their tests are
// in rust/crates/host/tests (mux_golden, serve_herdr).
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
      server = await ServerSocket.bind(InternetAddress(socketPath, type: InternetAddressType.unix), 0);
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
        untilAnswered: true,
      );

      expect(r.err, isEmpty);
      expect(r.out.trim(), '{"id":"1","result":{"type":"pong"}}');
      expect(received, ['{"id":"1","method":"ping","params":{}}']);
    }, skip: _has('socat') ? false : 'needs socat');

    test('honours an explicit socket path for non-default sessions', () async {
      final r = await _run(
        buildBridgeCommand(session: 'work', socketPath: socketPath),
        home,
        input: '{"id":"1","method":"ping","params":{}}\n',
        untilAnswered: true,
      );

      expect(r.out.trim(), contains('pong'));
    }, skip: _has('socat') ? false : 'needs socat');

    test('a host with neither herdr >= 0.9 nor socat exits 78 and says so', () async {
      // A PATH with nothing on it but the shell tools the wrapper needs.
      final bin = Directory('${home.path}/bin')..createSync();
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
      await p.stdin.close();
      final err = await utf8.decodeStream(p.stderr);

      expect(await p.exitCode, 78);
      expect(err, contains('herdr'));
      expect(err, isNot(contains('python')));
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

  test('a named session without a socket path fails with exit 78 and a hint', () async {
    final r = await _run(buildBridgeCommand(session: 'work'), home);

    expect(r.code, 78);
    expect(r.err, contains('work'));
  });

  test('rejects session names that could inject shell', () {
    for (final bad in ['a b', r'x;rm -rf /', r'$(id)', "a'b", '', '../x']) {
      expect(() => buildBridgeCommand(session: bad), throwsArgumentError, reason: bad);
    }
  });

  test('a socket path with quotes cannot break out of the command', () async {
    final evil = "x'; touch ${home.path}/pwned; '";
    final r = await _run(buildBridgeCommand(session: 'work', socketPath: evil), home);

    expect(File('${home.path}/pwned').existsSync(), isFalse);
    expect(r.code, isNot(0));
  });
}
