@TestOn('linux || mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/bridge_command.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart';

import 'support/keeper_harness.dart';

// sshd hands the whole command string to the person's LOGIN shell
// (`$SHELL -c '<command>'`), so every command must survive any shell's own
// parsing, not just `sh`'s: fish refuses `{ ...; }` (exit 127) and csh/tcsh
// choke on `$( )` and `||` inside a double-quoted word.

String? _installed(String shell) {
  for (final d in ['/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin']) {
    if (File('$d/$shell').existsSync()) return '$d/$shell';
  }
  return null;
}

Future<RunResult> _runUnder(
  String shell,
  String command,
  Directory home,
  String path, {
  String input = '',
}) async {
  final p = await Process.start(
    shell,
    ['-c', command],
    environment: {'HOME': home.path, 'PATH': path},
    includeParentEnvironment: false,
    workingDirectory: home.path,
  );
  p.stdin.write(input);
  await p.stdin.close();
  final out = utf8.decodeStream(p.stdout);
  final err = utf8.decodeStream(p.stderr);
  final code = await p.exitCode.timeout(const Duration(seconds: 60));
  return (out: await out, err: await err, code: code);
}

void main() {
  late Directory home;
  late String bareBin;
  setUp(() {
    home = Directory.systemTemp.createTempSync('login_shell_');
    // Only what the wrapper itself needs, and no python3: the script answers 78.
    final bin = Directory('${home.path}/bin')..createSync();
    for (final tool in ['sh', 'base64']) {
      Link('${bin.path}/$tool').createSync(_installed(tool)!);
    }
    bareBin = bin.path;
  });
  tearDown(() => home.deleteSync(recursive: true));

  final py = pythonDir();

  for (final shell in ['fish', 'csh', 'tcsh', 'zsh', 'bash', 'dash', 'ksh']) {
    final path = _installed(shell);
    group('under $shell', skip: path == null ? '$shell is not installed' : false, () {
      test('every command reaches the script and its exit code comes back', () async {
        final commands = {
          'keeper list': keeperListCommand(),
          'keeper install': keeperInstallCommand(),
          'keeper attach': keeperAttachCommand('abc234'),
          'bridge': buildBridgeCommand(session: 'default'),
          'mux': buildMuxCommand(session: 'default'),
          'events': buildEventsCommand(session: 'default'),
        };
        for (final MapEntry(:key, :value) in commands.entries) {
          final r = await _runUnder(path!, value, home, bareBin);
          // 78 is the script's own "python3 is missing": the wrapper decoded and ran it.
          expect(r.code, 78, reason: '$key under $shell: ${r.err}');
          expect(r.err, contains('python3'), reason: key);
        }
      });

      test('stdin stays the data path: install, then list', () async {
        if (py == null) {
          markTestSkipped('python3 is not installed');
          return;
        }
        final withPython = '$bareBin:$py:/usr/bin:/bin';
        final install = await _runUnder(path!, keeperInstallCommand(), home, withPython, input: keeperInstallPayload());
        expect(install.code, 0, reason: install.err);
        expect(install.out.trim(), '{"ok":true}');
        final list = await _runUnder(path, keeperListCommand(), home, withPython);
        expect(list.code, 0, reason: list.err);
        expect(jsonDecode(list.out), isEmpty);
      });
    });
  }

  test('the command is one single-quoted word, whatever the remote strings hold', () {
    // The login shell sees `sh -c '<word>'`; a quote inside would end the word
    // early, and whatever is outside it is parsed by fish or csh. The script,
    // with every hostile path in it, travels as base64 (A-Za-z0-9+/=).
    const hostile = "it's \$(touch pwned) `x` \"y\" !z";
    final commands = [
      keeperListCommand(),
      keeperStartCommand(agent: 'omp', cwd: '/tmp/$hostile'),
      keeperHistoryCommand(agent: 'omp', cwd: '/tmp/$hostile'),
      keeperFollowCommand('/home/x/$hostile.jsonl'),
      keeperKillCommand('abc234'),
      buildBridgeCommand(session: 'default'),
      buildMuxCommand(session: 'default'),
      buildEventsCommand(session: 'default'),
    ];
    final shape = RegExp(r'''^sh -c 'eval "\$\(echo ([A-Za-z0-9+/=]+) \| \{ base64 -d 2>/dev/null \|\| base64 -D; \}\)"'$''');
    for (final c in commands) {
      final m = shape.firstMatch(c);
      expect(m, isNotNull, reason: c);
      expect(c, isNot(contains('pwned')));
    }
  });
}
