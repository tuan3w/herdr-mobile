@TestOn('linux || mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/app_info.dart';
import 'package:herdr_mobile/data/host/host_link.dart';
import 'package:herdr_mobile/data/services/bridge_command.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart';

import 'support/keeper_harness.dart';
import 'support/process_host.dart';

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

Future<RunResult> _runUnder(String shell, String command, Directory home, String path, {String input = ''}) async {
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
    // Only what the wrapper and the binary install need: `sh`+`base64` decode
    // the command, `uname` names the platform. The keeper is a binary, so there
    // is no interpreter to be missing; curl/wget are absent, so the install script
    // dies at its own "needs curl or wget" (a code a shell parse failure never
    // gives).
    final bin = Directory('${home.path}/bin')..createSync();
    for (final tool in ['sh', 'base64', 'uname']) {
      Link('${bin.path}/$tool').createSync(_installed(tool)!);
    }
    bareBin = bin.path;
  });
  tearDown(() => home.deleteSync(recursive: true));

  for (final shell in ['fish', 'csh', 'tcsh', 'zsh', 'bash', 'dash', 'ksh']) {
    final where = _installed(shell);
    group('under $shell', skip: where == null ? '$shell is not installed' : false, () {
      test('every command is decoded, run, and its exit code comes back', () async {
        final path = where!;
        // The serve command execs the installed binary: 65 "not installed"
        // proves the wrapper decoded and ran it.
        final serve = await _runUnder(path, hostServeCommand(), home, bareBin);
        expect(serve.code, 65, reason: 'serve under $shell: ${serve.err}');
        expect(serve.err, contains('not installed'));
        // The install is the bootstrap: it runs `uname` (present) and then dies
        // at its own "needs curl or wget" (exit 1) — a code a shell parse
        // failure (127) never gives.
        final install = await _runUnder(path, keeperInstallCommand(), home, bareBin);
        expect(install.code, 1, reason: 'keeper install under $shell: ${install.err}');
        expect(install.err, contains('needs curl or wget'));
        // The bridge needs herdr's own bridge or socat: 78 says neither is there.
        final bridge = await _runUnder(path, buildBridgeCommand(session: 'default'), home, bareBin);
        expect(bridge.code, 78, reason: 'bridge under $shell: ${bridge.err}');
        expect(bridge.err, contains('socat'));
      });

      test('the binary install is self-contained, then serve answers a HELLO', () async {
        final path = where!;
        // The real release install needs curl and the network (a release that
        // carries herdr-host). The wrapper's decode-and-eval is already proven
        // by the test above; here we place the binary the way install-host.sh
        // does and check the serve command then reaches it: a link on it gets
        // the host's HELLO.
        await installHostBinary(home);
        final serve = await ProcessHostProcess.start(
          path,
          ['-c', hostServeCommand()],
          environment: {'HOME': home.path, 'PATH': bareBin},
          workingDirectory: home.path,
        );
        final link = await HostLink.connect(serve, version: appVersion, helloTimeout: const Duration(seconds: 30));
        addTearDown(link.close);
        expect(link.hello.version, isNotEmpty);
        expect(link.hello.home, home.path);
      });
    });
  }

  test('the command is one single-quoted word', () {
    // The login shell sees `sh -c '<word>'`; a quote inside would end the word
    // early, and whatever is outside it is parsed by fish or csh. The script
    // travels as base64 (A-Za-z0-9+/=). The session and socket path of the
    // bridge are the only strings that come from outside.
    final commands = [
      hostServeCommand(),
      keeperInstallCommand(),
      buildBridgeCommand(session: 'default'),
      buildBridgeCommand(session: 'work-1', socketPath: "/tmp/it's \$(touch pwned) `x` \"y\" !z.sock"),
    ];
    final shape = RegExp(
      r'''^sh -c 'eval "\$\(echo ([A-Za-z0-9+/=]+) \| \{ base64 -d 2>/dev/null \|\| base64 -D; \}\)"'$''',
    );
    for (final c in commands) {
      final m = shape.firstMatch(c);
      expect(m, isNotNull, reason: c);
      expect(c, isNot(contains('pwned')));
    }
  });
}
