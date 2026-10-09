@TestOn('linux || mac-os')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/acp/zipped_lines.dart';
import 'package:herdr_mobile/data/observed/omp_log_mapper.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart';

import 'support/transcript_fingerprint.dart';


// Runs the real keeper script (python3) `follow` against files in a temp HOME,
// the way an SSH server would run it (`sh -c`).

const _tail = 192 * 1024;

// Loads the script without running `main` (its `__main__` guard), then runs a `Follower` whose clock
// is a number the (replaced) `wait` advances, so minutes of back-off take no
// time. Modes: backoff (quiet 1100 waits, a line appended during wait 800),
// idle (--idle-exit 300, quiet), idle-grow (the same, a line during wait 100).
const _harness = r'''
import json, os, sys
script, log, mode = sys.argv[1:4]
src = open(script).read()
g = {"__name__": "keeper_under_test"}
exec(compile(src, script, "exec"), g)
now = [0.0]
waits = []
reads = []
count = [0]
real_pread = os.pread
def pread(*a):
    count[0] += 1
    return real_pread(*a)
os.pread = pread
append_at = {"backoff": 800, "idle-grow": 100}.get(mode)
class F(g["Follower"]):
    def wait(self, seconds):
        waits.append(seconds)
        now[0] += seconds
        n = len(waits)
        if mode == "backoff" and n in (1, 799, 1100):
            reads.append(count[0])
        if n == append_at:
            with open(log, "ab") as f:
                f.write(b'{"n":99}\n')
        return mode != "backoff" or n < 1100
F(log, None, 0.25, 300 if mode.startswith("idle") else 0, lambda: now[0]).run()
print(json.dumps({"waits": waits, "reads": reads, "total": sum(waits)}))
''';

String? _pythonDir() {
  for (final d in ['/usr/bin', '/bin', '/usr/local/bin', '/opt/homebrew/bin']) {
    if (File('$d/python3').existsSync()) return d;
  }
  return null;
}

/// One output record of `follow`.
class _Rec {
  _Rec(this.text);

  final String text;

  bool get isReset => text.startsWith('R\t');
  bool get isCaughtUp => text.startsWith('C\t');
  bool get isHead => text.startsWith('S\t');
  bool get isError => text.startsWith('E\t');
  int get offset => int.parse(text.substring(0, text.indexOf('\t')));
  int get resetOffset => int.parse(text.substring(2));
  String get body => text.substring(text.indexOf('\t') + 1);
  Map<String, Object?> get json => (jsonDecode(body) as Map).cast<String, Object?>();

  @override
  String toString() => text.length > 200 ? '${text.substring(0, 200)}…' : text;
}

class _Follow {
  _Follow(this.process) {
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (l) {
        final r = _Rec(l);
        // The caught-up and head records are notes about the stream, not
        // records of the log.
        (r.isCaughtUp ? caughtUp : r.isHead ? heads : _records).add(r);
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
    );
    process.stderr.transform(utf8.decoder).listen(_err.write);
  }

  final Process process;
  final _records = <_Rec>[];

  /// The `C` records, in order (the follower sends one, after its first read to the end).
  final caughtUp = <_Rec>[];

  /// The `S` records, in order: where each tail read starts.
  final heads = <_Rec>[];
  final _err = StringBuffer();
  var _done = false;
  Completer<void>? _waiting;
  var _taken = 0;

  String get stderr => _err.toString();

  void _wake() {
    final w = _waiting;
    _waiting = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  /// The next record; fails when none comes within [timeout].
  Future<_Rec> next({Duration timeout = const Duration(seconds: 10)}) async {
    final end = DateTime.now().add(timeout);
    while (_taken >= _records.length) {
      if (_done) fail('output ended after $_taken records; stderr: $stderr');
      final left = end.difference(DateTime.now());
      if (left <= Duration.zero) fail('no record within $timeout (got $_taken)');
      final w = _waiting = Completer<void>();
      await w.future.timeout(left, onTimeout: () {});
    }
    return _records[_taken++];
  }

  Future<List<_Rec>> take(int n) async => [for (var i = 0; i < n; i++) await next()];

  /// Every record until the output has been quiet for [quiet].
  Future<List<_Rec>> settle({Duration quiet = const Duration(milliseconds: 400)}) async {
    var seen = -1;
    while (seen != _records.length) {
      seen = _records.length;
      await Future<void>.delayed(quiet);
    }
    final out = _records.sublist(_taken);
    _taken = _records.length;
    return out;
  }

  Future<void> expectQuiet([Duration d = const Duration(milliseconds: 500)]) async {
    await Future<void>.delayed(d);
    expect(_records.length, _taken, reason: 'unexpected output: ${_records.sublist(_taken)}');
  }

  /// Closes stdin (what the SSH channel closing does) and returns the exit code.
  Future<int> stop() async {
    await process.stdin.close();
    return process.exitCode.timeout(const Duration(seconds: 10));
  }

  Future<int> get exitCode => process.exitCode;
}

class _Host {
  _Host(this.home, this._env);

  final Directory home;
  final Map<String, String> _env;
  var _n = 0;
  final _started = <Process>[];

  static Future<_Host> create() async {
    final home = Directory.systemTemp.createTempSync('follow_test_');
    final host = _Host(home, {
      'HOME': home.path,
      'PATH': '${_pythonDir()}:/usr/bin:/bin',
    });
    final p = await Process.start('/bin/sh', ['-c', keeperInstallCommand()],
        environment: host._env, includeParentEnvironment: false);
    p.stdin.write(keeperInstallPayload());
    await p.stdin.close();
    final out = await utf8.decodeStream(p.stdout);
    expect(await p.exitCode, 0);
    expect(out.trim(), '{"ok":true}');
    return host;
  }

  /// A new path for a log file in the home folder.
  String path([String name = 'log']) => '${home.path}/${name}_${_n++}.jsonl';

  Future<_Follow> follow(String path, {int? from, int? pollMs = 40, int? idleExit, int? tailBytes}) =>
      startCommand(keeperFollowCommand(path, from: from, pollMs: pollMs, idleExit: idleExit, tailBytes: tailBytes));

  /// A command that runs the installed script's `Follower` on [log] in a
  /// harness whose clock and sleep are fake (see [_harness]), and prints a
  /// JSON summary on its last line.
  String harness(String log, String mode) {
    final file = File('${home.path}/harness.py')..writeAsStringSync(_harness);
    final script = '${home.path}/.herdr-mobile/keeper-${keeperScriptVersion(keeperScript())}.py';
    return "python3 '${file.path}' '$script' '$log' $mode";
  }

  Future<_Follow> startCommand(String command, {Map<String, String> env = const {}}) async {
    final p = await Process.start('/bin/sh', ['-c', command],
        environment: {..._env, ...env}, includeParentEnvironment: false, workingDirectory: home.path);
    _started.add(p);
    return _Follow(p);
  }

  /// Runs a follow that is expected to end by itself.
  Future<({int code, String out, String err})> runToEnd(String command) async {
    final p = await Process.start('/bin/sh', ['-c', command],
        environment: _env, includeParentEnvironment: false, workingDirectory: home.path);
    await p.stdin.close();
    final out = utf8.decodeStream(p.stdout);
    final err = utf8.decodeStream(p.stderr);
    final code = await p.exitCode.timeout(const Duration(seconds: 20));
    return (code: code, out: await out, err: await err);
  }

  void dispose() {
    for (final p in _started) {
      p.kill();
    }
    home.deleteSync(recursive: true);
  }
}

/// Writes [lines] (each plus `\n`) and returns the byte offset after each.
List<int> _write(File f, List<String> lines, {FileMode mode = FileMode.write}) {
  final offsets = <int>[];
  var at = mode == FileMode.append && f.existsSync() ? f.lengthSync() : 0;
  final b = BytesBuilder();
  for (final l in lines) {
    final bytes = utf8.encode('$l\n');
    b.add(bytes);
    at += bytes.length;
    offsets.add(at);
  }
  f.writeAsBytesSync(b.takeBytes(), mode: mode, flush: true);
  return offsets;
}

String _json(int i, {String pad = ''}) => jsonEncode({'n': i, 'pad': pad});

void main() {
  final hasPython = _pythonDir() != null;
  late _Host host;
  late Directory outside;

  setUpAll(() async {
    if (!hasPython) return;
    host = await _Host.create();
    outside = Directory.systemTemp.createTempSync('follow_outside_');
  });

  tearDownAll(() {
    if (!hasPython) return;
    host.dispose();
    outside.deleteSync(recursive: true);
  });

  group('follow', skip: hasPython ? false : 'python3 is not installed', () {
    test('a small file comes whole, with the byte offset after every line', () async {
      final f = File(host.path());
      final lines = [_json(1), '{"text":"héllo 日本語 🚀"}', _json(3)];
      final offsets = _write(f, lines);
      final run = await host.follow(f.path);
      final got = await run.take(3);
      expect([for (final r in got) r.offset], offsets);
      expect(got[1].json['text'], 'héllo 日本語 🚀');
      expect(offsets.last, f.lengthSync());
      expect(await run.stop(), 0);
    });

    test('an empty file prints nothing and then follows', () async {
      final f = File(host.path())..writeAsStringSync('');
      final run = await host.follow(f.path);
      await run.expectQuiet();
      _write(f, [_json(1)], mode: FileMode.append);
      expect((await run.next()).json['n'], 1);
      expect(await run.stop(), 0);
    });

    test('blank lines and CRLF are skipped but counted in the offsets', () async {
      final f = File(host.path())..writeAsStringSync('{"n":1}\r\n\n  \n{"n":2}\n');
      final run = await host.follow(f.path);
      final got = await run.take(2);
      expect([for (final r in got) r.json['n']], [1, 2]);
      expect(got[0].offset, 9);
      expect(got[1].offset, f.lengthSync());
      await run.expectQuiet();
      await run.stop();
    });

    test('a big file starts at a line boundary inside the last 192 KB (the default)', () async {
      final f = File(host.path());
      // Lines of about 100 bytes: the cut falls inside one of them.
      final lines = [for (var i = 0; i < 20000; i++) _json(i, pad: 'x' * (86 - '$i'.length))];
      final offsets = _write(f, lines);
      final size = f.lengthSync();
      final run = await host.follow(f.path);
      final got = await run.settle();
      expect(got.every((r) => !r.isReset), isTrue);
      final first = got.first.json['n']! as int;
      final firstStart = first == 0 ? 0 : offsets[first - 1];
      expect(firstStart, greaterThanOrEqualTo(size - _tail));
      expect(firstStart, lessThan(size - _tail + 120));
      expect([for (final r in got) r.json['n']], [for (var i = first; i < 20000; i++) i]);
      expect(got.last.offset, size);
      // It says the tail is not the whole file: the phone offers what is before.
      expect([for (final h in run.heads) h.resetOffset], [size - _tail]);
      await run.stop();
    });

    test('a file inside the window comes whole, and says so', () async {
      final f = File(host.path());
      _write(f, [for (var i = 0; i < 3; i++) _json(i)]);
      final run = await host.follow(f.path);
      expect(await run.settle(), hasLength(3));
      expect([for (final h in run.heads) h.resetOffset], [0]);
      await run.stop();
    });

    test('a line that starts exactly at the window is kept, one byte earlier is not', () async {
      Future<List<_Rec>> tailOf(int skewBytes, {int? tailBytes}) async {
        final f = File(host.path());
        // 64-byte lines: 192 KB is exactly 3072 of them, 64 KB 1024, 16 KB 256.
        final lines = [for (var i = 0; i < 10000; i++) _json(i, pad: 'y' * (48 - '$i'.length))];
        for (final l in lines) {
          expect(utf8.encode(l).length, 63);
        }
        final shifted = skewBytes == 0 ? lines : [...lines, ''];
        _write(f, shifted);
        final run = await host.follow(f.path, tailBytes: tailBytes);
        final got = await run.settle();
        await run.stop();
        return got;
      }

      final exact = await tailOf(0);
      expect(exact, hasLength(3072));
      expect(exact.first.json['n'], 10000 - 3072);
      // A blank line behind them moves the window by one byte, into line 6928.
      final shifted = await tailOf(1);
      expect(shifted, hasLength(3071));
      expect(shifted.first.json['n'], 10000 - 3071);
      expect(await tailOf(0, tailBytes: 65536), hasLength(1024));
    });

    test('--tail-bytes is clamped to 16 KB..64 MB', () async {
      Future<int> lineCount(int tailBytes) async {
        final f = File(host.path());
        _write(f, [for (var i = 0; i < 10000; i++) _json(i, pad: 'y' * (48 - '$i'.length))]);
        final run = await host.follow(f.path, tailBytes: tailBytes);
        final got = await run.settle();
        await run.stop();
        return got.length;
      }

      expect(await lineCount(1), 256, reason: 'never below 16 KB');
      expect(await lineCount(16384), 256);
      expect(await lineCount(1 << 40), 10000, reason: 'never above 64 MB: the 640 KB file comes whole');
    });

    test('--from wins over --tail-bytes, and a reset uses the tail size too', () async {
      final f = File(host.path());
      final offsets = _write(f, [for (var i = 0; i < 10000; i++) _json(i, pad: 'y' * (48 - '$i'.length))]);
      final resumed = await host.follow(f.path, from: offsets[9996], tailBytes: 16384);
      expect([for (final r in await resumed.take(3)) r.json['n']], [9997, 9998, 9999]);
      await resumed.stop();

      final stale = await host.follow(f.path, from: offsets.last + 5, tailBytes: 16384);
      expect((await stale.next()).isReset, isTrue);
      expect(await stale.settle(), hasLength(256));
      expect(stale.heads, hasLength(1), reason: 'the reset tail says where it starts too');
      await stale.stop();
    });

    test('one line longer than the window: nothing before its end, then it follows', () async {
      final f = File(host.path());
      f.writeAsStringSync('${'z' * (_tail + 100)}\n{"n":1}\n');
      final run = await host.follow(f.path);
      final got = await run.settle();
      // The huge first line is not JSON and is not wholly inside the window.
      expect([for (final r in got) r.json['n']], [1]);
      await run.stop();
    });

    test('a 30 MB file starts fast and sends only its tail', () async {
      final f = File(host.path());
      final sink = f.openSync(mode: FileMode.write);
      final chunk = utf8.encode('${[for (var i = 0; i < 1000; i++) _json(i, pad: 'p' * 900)].join('\n')}\n');
      var written = 0;
      while (written < 30 * 1024 * 1024) {
        sink.writeFromSync(chunk);
        written += chunk.length;
      }
      sink.closeSync();
      final watch = Stopwatch()..start();
      final run = await host.follow(f.path);
      final firstRecord = await run.next();
      expect(watch.elapsedMilliseconds, lessThan(5000));
      final rest = await run.settle();
      final bytes = [firstRecord, ...rest].fold<int>(0, (n, r) => n + utf8.encode(r.body).length);
      expect(bytes, lessThanOrEqualTo(_tail));
      expect(rest.last.offset, f.lengthSync());
      await run.stop();
    });

    test('lines appended later arrive, in order, without a repeat', () async {
      final f = File(host.path());
      _write(f, [_json(1)]);
      final run = await host.follow(f.path);
      expect((await run.next()).json['n'], 1);
      await run.expectQuiet();
      final offsets = _write(f, [_json(2), _json(3)], mode: FileMode.append);
      final got = await run.take(2);
      expect([for (final r in got) r.offset], offsets);
      _write(f, [_json(4)], mode: FileMode.append);
      expect((await run.next()).json['n'], 4);
      await run.expectQuiet();
      await run.stop();
    });

    test('at the default polling rate a new line arrives within 250 ms plus the work', () async {
      final f = File(host.path());
      _write(f, [_json(1)]);
      final run = await host.follow(f.path, pollMs: null);
      await run.next();
      final latencies = <int>[];
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(Duration(milliseconds: 37 * i % 200)); // different phases of the poll
        final watch = Stopwatch()..start();
        _write(f, [_json(2 + i)], mode: FileMode.append);
        expect((await run.next(timeout: const Duration(seconds: 3))).json['n'], 2 + i);
        latencies.add(watch.elapsedMilliseconds);
      }
      // ignore: avoid_print
      print('append-to-emit latency at 250 ms polling (ms): ${(latencies..sort())}');
      // The median shows the poll rate; the slowest of 12 is scheduling noise
      // when the whole suite runs at once (it failed there, never alone). A
      // follower polling every second or slower would put the median past 500.
      expect(latencies[latencies.length ~/ 2], lessThan(450));
      expect(latencies.last, lessThan(2000), reason: 'no append waits for several polls');
      await run.stop();
    });

    test('a poll interval can be given', () async {
      final f = File(host.path());
      _write(f, [_json(1)]);
      final run = await host.follow(f.path, pollMs: 2000);
      await run.next();
      final watch = Stopwatch()..start();
      _write(f, [_json(2)], mode: FileMode.append);
      await run.next(timeout: const Duration(seconds: 5));
      expect(watch.elapsedMilliseconds, greaterThan(1000), reason: 'it only looks every 2 s');
      await run.stop();
    });

    test('--idle-exit ends the follower by itself after that long without growth; growth postpones it', () async {
      final f = File(host.path());
      _write(f, [_json(1)]);
      final run = await host.follow(f.path, idleExit: 2);
      await run.next();
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      _write(f, [_json(2)], mode: FileMode.append);
      await run.next();
      var exited = false;
      unawaited(run.exitCode.then((_) => exited = true));
      await Future<void>.delayed(const Duration(milliseconds: 1300)); // 2.7 s after the start, 1.3 s after growth
      expect(exited, isFalse, reason: 'the growth restarted the 2 s');
      expect(await run.exitCode.timeout(const Duration(seconds: 4)), 0);
      expect(run.stderr, isEmpty);
    });

    test('without --idle-exit a quiet file keeps it running', () async {
      final f = File(host.path());
      _write(f, [_json(1)]);
      final run = await host.follow(f.path);
      await run.next();
      var exited = false;
      unawaited(run.exitCode.then((_) => exited = true));
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(exited, isFalse);
      await run.stop();
    });

    test('the poll backs off to 1 s after 60 s and 2 s after 10 min without growth, and any growth resets it', () async {
      final f = File(host.path());
      _write(f, [_json(1)]);
      final r = await host.runToEnd(host.harness(f.path, 'backoff'));
      expect(r.code, 0, reason: r.err);
      final result = jsonDecode(r.out.trim().split('\n').last) as Map;
      final waits = (result['waits'] as List).cast<num>();
      expect(waits.take(240).toSet(), {0.25});
      expect(waits.skip(240).take(540).toSet(), {1.0});
      expect(waits[780], 2.0);
      expect(waits.skip(780).take(20).toSet(), {2.0}); // up to the append after wait 800
      expect(waits.skip(800).take(240).toSet(), {0.25}, reason: 'growth resets to the base interval');
      expect(waits[1040], 1.0);
      // A quiet file is one stat per wait, no read.
      final reads = (result['reads'] as List).cast<int>();
      expect(reads[1] - reads[0], 0, reason: 'no read between the first and the 799th quiet wait');
      expect(reads[2], greaterThan(reads[1]), reason: 'the append was read');
    });

    test('--idle-exit counts quiet time on the same clock, from the last growth', () async {
      final f = File(host.path());
      _write(f, [_json(1)]);
      final quiet = jsonDecode((await host.runToEnd(host.harness(f.path, 'idle'))).out.trim().split('\n').last) as Map;
      expect(quiet['total'], 300.0);
      final grew = jsonDecode((await host.runToEnd(host.harness(f.path, 'idle-grow'))).out.trim().split('\n').last) as Map;
      expect(grew['total'], 325.0);
    });

    test('a partial last line is held until its newline arrives', () async {
      final f = File(host.path());
      f.writeAsStringSync('{"n":1}\n{"n":2,"te');
      final run = await host.follow(f.path);
      expect((await run.next()).json['n'], 1);
      await run.expectQuiet();
      f.writeAsStringSync('xt":"ab', mode: FileMode.append, flush: true);
      await run.expectQuiet();
      f.writeAsStringSync('c"}\n{"n":3}', mode: FileMode.append, flush: true);
      final two = await run.next();
      expect(two.json, {'n': 2, 'text': 'abc'});
      expect(two.offset, utf8.encode('{"n":1}\n{"n":2,"text":"abc"}\n').length);
      await run.expectQuiet(); // {"n":3} has no newline yet
      f.writeAsStringSync('\n', mode: FileMode.append, flush: true);
      expect((await run.next()).json['n'], 3);
      await run.stop();
    });

    test('a multi-byte character split across two appends is not broken', () async {
      final f = File(host.path())..writeAsStringSync('');
      final run = await host.follow(f.path);
      final bytes = utf8.encode('{"t":"日本"}\n');
      f.writeAsBytesSync(bytes.sublist(0, 7), mode: FileMode.append, flush: true); // inside 日
      await run.expectQuiet();
      f.writeAsBytesSync(bytes.sublist(7), mode: FileMode.append, flush: true);
      expect((await run.next()).json['t'], '日本');
      await run.stop();
    });

    test('a truncated file starts over with a reset marker', () async {
      final f = File(host.path());
      _write(f, [_json(1), _json(2), _json(3)]);
      final run = await host.follow(f.path);
      await run.take(3);
      _write(f, [_json(9)]); // truncates, shorter than before
      final reset = await run.next();
      expect(reset.isReset, isTrue, reason: '$reset');
      expect(reset.text, 'R\t0');
      final line = await run.next();
      expect(line.json['n'], 9);
      expect(line.offset, f.lengthSync());
      await run.stop();
    });

    test('a replaced file starts over, even when it is longer', () async {
      final f = File(host.path());
      _write(f, [_json(1)]);
      final run = await host.follow(f.path);
      await run.next();
      final other = File('${f.path}.new');
      _write(other, [_json(7), _json(8), _json(9)]);
      other.renameSync(f.path);
      expect((await run.next()).isReset, isTrue);
      expect([for (final r in await run.take(3)) r.json['n']], [7, 8, 9]);
      // ...and the new file is the one followed.
      _write(f, [_json(10)], mode: FileMode.append);
      expect((await run.next()).json['n'], 10);
      await run.stop();
    });

    test('a file that is removed and comes back is a new file', () async {
      final f = File(host.path());
      _write(f, [_json(1)]);
      final run = await host.follow(f.path);
      await run.next();
      f.deleteSync();
      await run.expectQuiet();
      _write(f, [_json(5), _json(6)]);
      expect((await run.next()).isReset, isTrue);
      expect([for (final r in await run.take(2)) r.json['n']], [5, 6]);
      await run.stop();
    });

    test('a reset of a big file also starts at its tail', () async {
      final f = File(host.path());
      _write(f, [_json(1)]);
      final run = await host.follow(f.path);
      await run.next();
      final lines = [for (var i = 0; i < 12000; i++) _json(i, pad: 'q' * (86 - '$i'.length))];
      final offsets = _write(File('${f.path}.new'), lines);
      File('${f.path}.new').renameSync(f.path);
      final reset = await run.next();
      expect(reset.isReset, isTrue);
      final got = await run.settle();
      final first = got.first.json['n']! as int;
      expect(reset.resetOffset, greaterThanOrEqualTo(offsets.last - _tail - 1));
      expect(got.last.offset, offsets.last);
      expect(first, greaterThan(0));
      await run.stop();
    });
  });

  group('follow --from', skip: hasPython ? false : 'python3 is not installed', () {
    test('resumes strictly after the offset', () async {
      final f = File(host.path());
      final offsets = _write(f, [for (var i = 0; i < 6; i++) _json(i)]);
      final run = await host.follow(f.path, from: offsets[2]);
      final got = await run.take(3);
      expect([for (final r in got) r.json['n']], [3, 4, 5]);
      expect(got.last.offset, offsets.last);
      await run.stop();
    });

    test('at the end of the file it waits for what comes next', () async {
      final f = File(host.path());
      final offsets = _write(f, [_json(1), _json(2)]);
      final run = await host.follow(f.path, from: offsets.last);
      await run.expectQuiet();
      _write(f, [_json(3)], mode: FileMode.append);
      expect((await run.next()).json['n'], 3);
      await run.stop();
    });

    test('from 0 replays everything, even of a big file', () async {
      final f = File(host.path());
      final lines = [for (var i = 0; i < 8000; i++) _json(i, pad: 'k' * (86 - '$i'.length))];
      _write(f, lines);
      final run = await host.follow(f.path, from: 0);
      final got = await run.settle();
      expect(got, hasLength(8000));
      expect(got.first.json['n'], 0);
      await run.stop();
    });

    test('an offset beyond the file means it was replaced: reset, then its content', () async {
      final f = File(host.path());
      _write(f, [_json(1), _json(2)]);
      final run = await host.follow(f.path, from: 100000);
      final reset = await run.next();
      expect(reset.text, 'R\t0');
      expect([for (final r in await run.take(2)) r.json['n']], [1, 2]);
      await run.stop();
    });

    test('an offset that is not the end of a line means the same', () async {
      final f = File(host.path());
      final offsets = _write(f, [_json(1), _json(2)]);
      final run = await host.follow(f.path, from: offsets[0] + 3);
      expect((await run.next()).isReset, isTrue);
      expect([for (final r in await run.take(2)) r.json['n']], [1, 2]);
      await run.stop();
    });
  });

  group('follow refuses', skip: hasPython ? false : 'python3 is not installed', () {
    Future<void> refused(String path, {String? why}) async {
      final r = await host.runToEnd(keeperFollowCommand(path));
      expect(r.code, 66, reason: '$path: ${r.err}');
      expect(r.out, isEmpty, reason: path);
      expect(r.err, startsWith('herdr-mobile: '), reason: path);
      if (why != null) expect(r.err, contains(why), reason: path);
    }

    test('a relative path and a path that is not .jsonl', () async {
      File('${host.home.path}/a.jsonl').writeAsStringSync('{}\n');
      File('${host.home.path}/a.txt').writeAsStringSync('{}\n');
      File('${host.home.path}/a.jsonl.bak').writeAsStringSync('{}\n');
      await refused('a.jsonl', why: 'absolute');
      await refused('~/a.jsonl', why: 'absolute');
      await refused('${host.home.path}/a.txt', why: '.jsonl');
      await refused('${host.home.path}/a.jsonl.bak', why: '.jsonl');
    });

    test('a file outside the home folder, a ../ path to it, and a missing file', () async {
      final far = File('${outside.path}/far.jsonl')..writeAsStringSync('{}\n');
      await refused(far.path, why: 'home folder');
      await refused('${host.home.path}/../${far.path.substring(1)}', why: 'home folder');
      await refused('${host.home.path}/nope.jsonl', why: 'cannot read');
      await refused('/etc/passwd', why: '.jsonl');
    });

    test('a symlink that leaves the home folder, or leads to a file that is not a log', () async {
      final far = File('${outside.path}/linked.jsonl')..writeAsStringSync('{"secret":1}\n');
      Link('${host.home.path}/out.jsonl').createSync(far.path);
      await refused('${host.home.path}/out.jsonl', why: 'home folder');

      final dir = Directory('${host.home.path}/linkdir')..createSync();
      File('${dir.path}/real.jsonl').writeAsStringSync('{}\n');
      Link('${host.home.path}/viadir').createSync(outside.path);
      await refused('${host.home.path}/viadir/linked.jsonl', why: 'home folder');

      final key = File('${host.home.path}/id_key')..writeAsStringSync('PRIVATE KEY\n');
      Link('${host.home.path}/key.jsonl').createSync(key.path);
      await refused('${host.home.path}/key.jsonl', why: 'home folder');
    });

    test('a directory named like a log, and a file nobody may read', () async {
      Directory('${host.home.path}/dir.jsonl').createSync();
      await refused('${host.home.path}/dir.jsonl', why: 'not a readable file');
      final uid = (await Process.run('id', ['-u'])).stdout.toString().trim();
      if (uid != '0') {
        final f = File('${host.home.path}/locked.jsonl')..writeAsStringSync('{}\n');
        await Process.run('chmod', ['000', f.path]);
        await refused(f.path, why: 'not a readable file');
      }
    });

    test('a link inside the home folder to a log inside it is followed', () async {
      final real = File(host.path('real'));
      _write(real, [_json(1)]);
      final link = Link(host.path('link'))..createSync(real.path);
      final run = await host.follow(link.path);
      expect((await run.next()).json['n'], 1);
      await run.stop();
    });

    test('a name with quotes, spaces, \$() and backticks is followed, never run', () async {
      final marker = '${host.home.path}/pwned';
      final dir = Directory('${host.home.path}/it\'s a "dir" \$(touch pwned) `touch pwned`; x')..createSync();
      final f = File('${dir.path}/we ird\\ \$HOME.jsonl');
      _write(f, [_json(1)]);
      final run = await host.follow(f.path);
      expect((await run.next()).json['n'], 1);
      await run.stop();
      for (final evil in [
        "x'; touch $marker; '.jsonl",
        '\$(touch $marker).jsonl',
        '`touch $marker`.jsonl',
        'x"; touch $marker; ".jsonl',
        '-rf.jsonl',
      ]) {
        await refused('${host.home.path}/$evil');
        await refused(evil);
      }
      expect(File(marker).existsSync(), isFalse);
    });

    test('the command is short and rejects what cannot be a path', () {
      expect(keeperFollowCommand('/home/u/.omp/agent/sessions/${'x' * 200}/a.jsonl', from: 123456789).length, lessThan(1024));
      for (final bad in ['', 'a\nb.jsonl', 'a\u0000b.jsonl', 'a\rb.jsonl', 'x' * 5000, 'a\u007fb']) {
        expect(() => keeperFollowCommand(bad), throwsArgumentError, reason: bad.length > 50 ? 'long' : bad);
      }
      expect(() => keeperFollowCommand('/a.jsonl', from: -1), throwsArgumentError);
      for (final bad in [0, -5]) {
        expect(() => keeperFollowCommand('/a.jsonl', tailBytes: bad), throwsArgumentError);
      }
      expect(() => keeperFollowCommand('/a.jsonl', pollMs: 0), throwsArgumentError);
      expect(() => keeperFollowCommand('/a.jsonl', idleExit: -1), throwsArgumentError);
      expect(keeperFollowCommand('/a.jsonl', tailBytes: 4096), isNot(equals(keeperFollowCommand('/a.jsonl'))));
      expect(keeperFollowCommand('/a.jsonl', from: 0), isNot(equals(keeperFollowCommand('/a.jsonl'))));
    });
  });

  group('follow cuts heavy fields on the host', skip: hasPython ? false : 'python3 is not installed', () {
    Future<List<_Rec>> follow(List<String> lines) async {
      final f = File(host.path());
      _write(f, lines);
      final run = await host.follow(f.path, from: 0);
      final got = await run.take(lines.length);
      await run.stop();
      return got;
    }

    test('a long string keeps its first 16 KB and says how much was cut', () async {
      final big = 'a' * 100000;
      final got = (await follow([jsonEncode({'type': 'message', 'text': big, 'short': 'ok'})])).single;
      final text = got.json['text']! as String;
      expect(text.startsWith('a' * 16384), isTrue);
      expect(text.substring(16384), '... [83616 bytes cut]');
      expect(got.json['short'], 'ok');
      expect(got.body.length, lessThan(16384 + 200));
    });

    test('a string of exactly 16 KB is untouched, one byte more is cut', () async {
      final got = await follow([
        jsonEncode({'t': 'b' * 16384}),
        jsonEncode({'t': 'b' * 16385}),
      ]);
      expect(got[0].json['t'], 'b' * 16384);
      expect(got[1].json['t'], 'b' * 16384 + '... [1 bytes cut]');
    });

    test('the cut counts bytes and never splits a character', () async {
      final got = (await follow([jsonEncode({'t': '日' * 20000})])).single; // 60000 bytes
      final text = got.json['t']! as String;
      final kept = text.substring(0, text.indexOf('...'));
      expect(utf8.encode(kept).length, lessThanOrEqualTo(16384));
      expect(kept, '日' * (16384 ~/ 3));
      final cut = int.parse(RegExp(r'\[(\d+) bytes cut\]').firstMatch(text)!.group(1)!);
      expect(utf8.encode(kept).length + cut, 60000);
    });

    test('strings deep inside arrays, objects and keys are cut, the shape stays', () async {
      final big = 'c' * 50000;
      final got = (await follow([
        jsonEncode({
          'message': {
            'content': [
              {'type': 'toolCall', 'arguments': {'cmd': big, 'n': 3, 'ok': true, 'none': null, 'f': 1.5}},
              {'type': 'text', 'text': big},
            ],
          },
          big: 1,
        }),
      ])).single;
      final root = got.json;
      final content = ((root['message']! as Map)['content']! as List).cast<Map>();
      expect((content[0]['arguments'] as Map)['cmd'], endsWith('... [33616 bytes cut]'));
      expect(((content[0]['arguments'] as Map)).entries.where((e) => e.key != 'cmd').map((e) => e.value), [3, true, null, 1.5]);
      expect(content[1]['text'], endsWith('bytes cut]'));
      expect(root.keys.where((k) => k.length > 17000), isEmpty);
      expect(got.body.length, lessThan(5 * 16384));
    });

    test('an image keeps its metadata and loses the payload', () async {
      final b64 = base64.encode(List.generate(300000, (i) => i % 251));
      final got = await follow([
        jsonEncode({
          'message': {
            'content': [
              {'type': 'image', 'mimeType': 'image/png', 'data': b64, 'width': 640},
              {'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/jpeg', 'data': b64}},
              {'type': 'text', 'text': 'see'},
            ],
          },
        }),
        jsonEncode({'details': {'blob': 'data:image/png;base64,$b64'}, 'data': b64}),
      ]);
      final content = (((got[0].json['message']! as Map)['content']!) as List).cast<Map>();
      expect(content[0]['type'], 'image');
      expect(content[0]['mimeType'], 'image/png');
      expect(content[0]['width'], 640);
      expect(content[0]['data'], '[${b64.length} bytes of data not sent]');
      expect((content[1]['source'] as Map)['media_type'], 'image/jpeg');
      expect((content[1]['source'] as Map)['data'], '[${b64.length} bytes of data not sent]');
      expect(content[2]['text'], 'see');
      expect(got[0].body.length, lessThan(600));
      final second = got[1].json;
      expect(second['data'], '[${b64.length} bytes of data not sent]');
      expect(((second['details']! as Map)['blob']! as String),
          'data:image/png;base64,[${'data:image/png;base64,'.length + b64.length} bytes of data not sent]');
    });

    test('a small data field and ordinary text named data are left alone', () async {
      final got = (await follow([jsonEncode({'data': 'QUJD', 'bytes': 'hello world ' * 200, 'type': 'text'})])).single;
      expect(got.json['data'], 'QUJD');
      expect((got.json['bytes']! as String).startsWith('hello world'), isTrue);
    });

    test('whatever is not JSON arrives as {"raw": first 2 KB}', () async {
      final longRaw = 'not json ' * 1000;
      final f = File(host.path());
      f.writeAsBytesSync([
        ...utf8.encode('plain words\n$longRaw\n{"broken":\n'),
        0xff, 0xfe, ...utf8.encode(' bad utf8 {"a":1}\n'),
        ...utf8.encode('{"n":NaN}\n{"n":Infinity}\n{"n":1e999}\n{"ok":1}\n'),
      ]);
      final run = await host.follow(f.path);
      final got = await run.take(8);
      expect(got[0].json, {'raw': 'plain words'});
      expect((got[1].json['raw']! as String).length, 2048);
      expect(got[2].json, {'raw': '{"broken":'});
      expect((got[3].json['raw']! as String), contains('\u{fffd}'));
      expect(got[4].json.keys, ['raw']);
      expect(got[5].json.keys, ['raw']);
      expect(got[6].json.keys, ['raw']);
      expect(got[7].json, {'ok': 1});
      expect(got.last.offset, f.lengthSync());
      await run.stop();
    });

    test('a lone surrogate escape still gives valid UTF-8, and deep nesting does not crash', () async {
      final f = File(host.path());
      f.writeAsStringSync('{"t":"a\\ud800b"}\n${'[' * 30000}${']' * 30000}\n{"ok":2}\n');
      final run = await host.follow(f.path);
      final got = await run.take(3);
      expect(got[0].json['t'], startsWith('a'));
      expect(got[1].json.keys, ['raw']);
      expect(got[2].json, {'ok': 2});
      await run.stop();
    });

    test('a line over 4 MB is a stub, and the lines around it are exact', () async {
      final f = File(host.path());
      final huge = '{"t":"${'h' * (5 * 1024 * 1024)}"}';
      final offsets = _write(f, [_json(1), huge, _json(3)]);
      final run = await host.follow(f.path, from: 0);
      final got = await run.take(3);
      expect(got[0].json['n'], 1);
      expect(got[1].json['raw'], '[line of ${utf8.encode(huge).length} bytes not sent]');
      expect(got[2].json['n'], 3);
      expect([for (final r in got) r.offset], offsets);
      await run.stop();
    });

    test('a huge line that is still being written is not sent in pieces', () async {
      final f = File(host.path());
      _write(f, [_json(0)]);
      final run = await host.follow(f.path);
      await run.next(); // the follower is up before the line starts growing
      final sink = f.openSync(mode: FileMode.append);
      for (var i = 0; i < 5; i++) {
        sink.writeStringSync('h' * (1024 * 1024));
        sink.flushSync();
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      await run.expectQuiet();
      sink.writeStringSync('\n{"n":1}\n');
      sink.closeSync();
      final got = await run.take(2);
      expect(got[0].json['raw'], startsWith('[line of '));
      expect(got[1].json['n'], 1);
      await run.stop();
    });
  });

  group('follow ends', skip: hasPython ? false : 'python3 is not installed', () {
    test('quietly when stdin closes, even if the file never changes', () async {
      final f = File(host.path());
      _write(f, [_json(1)]);
      final run = await host.follow(f.path);
      await run.next();
      final watch = Stopwatch()..start();
      expect(await run.stop(), 0);
      expect(watch.elapsedMilliseconds, lessThan(3000));
      expect(run.stderr, isEmpty);
    });

    test('quietly when the reader of stdout goes away', () async {
      final f = File(host.path());
      // More than a pipe holds, so the write after `head` has gone fails.
      _write(f, [for (var i = 0; i < 6000; i++) _json(i, pad: 'e' * 80)]);
      // stdin stays open (an endless /dev/zero), so only the broken pipe can end it.
      final r = await host.runToEnd('${keeperFollowCommand(f.path)} < /dev/zero 2>err.txt | head -n 2');
      expect(r.code, 0);
      // The first line says where the tail starts; the second is a record.
      expect(r.out.trim().split('\n').last, contains('\t{'));
      expect(File('${host.home.path}/err.txt').readAsStringSync(), isEmpty);
    });

    test('with an exit status of 64 for arguments it was not given', () async {
      final r = await host.runToEnd('python3 ${host.home.path}/.herdr-mobile/keeper-${keeperScriptVersion(keeperScript())}.py follow');
      expect(r.code, 64);
      final bad = await host.runToEnd('python3 ${host.home.path}/.herdr-mobile/keeper-${keeperScriptVersion(keeperScript())}.py follow /x.jsonl --from x');
      expect(bad.code, 64);
    });
  });

  group('follow says it is up to date', skip: hasPython ? false : 'python3 is not installed', () {
    test('once, with the offset it has reached: an empty file, a tail, and a resume at the end', () async {
      final empty = File(host.path())..writeAsStringSync('');
      final a = await host.follow(empty.path);
      await a.settle();
      expect([for (final c in a.caughtUp) c.text], ['C\t0']);
      await a.stop();

      final f = File(host.path());
      final offsets = _write(f, [_json(1), _json(2)]);
      final b = await host.follow(f.path);
      expect([for (final r in await b.take(2)) r.offset], offsets);
      await b.settle();
      expect([for (final c in b.caughtUp) c.text], ['C\t${offsets.last}']);
      _write(f, [_json(3)], mode: FileMode.append);
      expect((await b.next()).json['n'], 3);
      await b.expectQuiet();
      expect(b.caughtUp, hasLength(1), reason: 'said once, not after every line');
      await b.stop();

      final c = await host.follow(f.path, from: offsets.first);
      expect((await c.next()).json['n'], 2);
      await c.settle();
      expect(c.caughtUp.single.text, 'C\t${f.lengthSync()}', reason: 'the offset of the end it has sent up to');
      await c.stop();

      final d = await host.follow(f.path, from: f.lengthSync());
      await d.settle();
      expect(d.caughtUp.single.text, 'C\t${f.lengthSync()}', reason: 'a resume at the end has no record to say it by');
      await d.stop();
    });
  });

  group('follow --z', skip: hasPython ? false : 'python3 is not installed', () {
    /// The lines `follow` prints for [f] until it has been quiet for a second, as the phone reads them.
    Future<({List<String> raw, List<String> read})> output(File f, {required bool zipped}) async {
      final r = await host.runToEnd(keeperFollowCommand(f.path, pollMs: 40, idleExit: 1, zipped: zipped));
      expect(r.code, 0, reason: r.err);
      final raw = const LineSplitter().convert(r.out);
      return (raw: raw, read: await zippedLines(Stream.fromIterable(raw)).toList());
    }

    test('a big tail travels as Z lines that read back to exactly the plain records', () async {
      final f = File(host.path());
      _write(f, [for (var i = 0; i < 3000; i++) jsonEncode({'n': i, 'text': 'line $i of the log, with words that repeat ${i % 7}'})]);
      final plain = await output(f, zipped: false);
      final zipped = await output(f, zipped: true);

      expect(zipped.read, plain.read);
      expect(zipped.raw.any((l) => l.startsWith('Z')), isTrue);
      final wire = zipped.raw.join('\n').length;
      expect(wire, lessThan(plain.raw.join('\n').length ~/ 3), reason: 'the wire shrinks');
    });

    test('a later batch continues the same zlib stream, and the phone reads both', () async {
      final f = File(host.path());
      String row(int i) => jsonEncode({'n': i, 'text': 'line $i with words that repeat ${i % 5}'});
      _write(f, [for (var i = 0; i < 300; i++) row(i)]);
      final run = await host.startCommand(keeperFollowCommand(f.path, pollMs: 40, zipped: true));
      final first = await run.settle();
      _write(f, [for (var i = 300; i < 340; i++) row(i)], mode: FileMode.append);
      final later = await run.settle();

      expect(first.single.text, startsWith('Z'));
      expect(later.single.text, startsWith('Z'), reason: 'its own line, not part of the first');
      final read = await zippedLines(Stream.fromIterable([for (final r in [...first, ...later]) r.text])).toList();
      expect([for (final l in read) jsonDecode(l.substring(l.indexOf('\t') + 1))['n']], [for (var i = 0; i < 340; i++) i]);
      await run.stop();
    });
  });

  group('follow leaves out what omp keeps for itself', skip: hasPython ? false : 'python3 is not installed', () {
    test('token accounting, the envelope, signatures and the copy of a file read are not sent; a credential_pin is skipped', () async {
      final f = File(host.path());
      final assistant = {
        'type': 'message',
        'id': 'a1',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'thinking', 'thinking': 'hm', 'thinkingSignature': 'x' * 900},
            {'type': 'text', 'text': 'done'},
          ],
          'usage': {'input': 3},
          'contextSnapshot': {'promptTokens': 9},
          'responseId': 'msg_1',
          'api': 'anthropic-messages',
          'provider': 'anthropic',
          'model': 'claude',
          'stopReason': 'stop',
          'timestamp': 5,
        },
      };
      final result = {
        'type': 'message',
        'id': 'r1',
        'message': {
          'role': 'toolResult',
          'toolCallId': 'c1',
          'content': [
            {'type': 'text', 'text': '1:alpha'},
          ],
          'details': {
            'totalLines': 1,
            'displayContent': {'text': 'alpha'},
          },
        },
      };
      final foreign = {'type': 'assistant', 'usage': {'input': 3}, 'message': {'usage': 1}};
      final offsets = _write(f, [
        jsonEncode(assistant),
        jsonEncode({'type': 'credential_pin', 'id': 'p1', 'hash': '0' * 64}),
        jsonEncode(result),
        jsonEncode(foreign),
      ]);
      final run = await host.follow(f.path);
      final got = await run.take(3);

      final m = got[0].json['message']! as Map;
      expect(m.keys.toSet(), {'role', 'content', 'model', 'stopReason', 'timestamp'});
      expect((m['content']! as List).first, {'type': 'thinking', 'thinking': 'hm'});
      expect(got[0].offset, offsets[0]);
      final d = ((got[1].json['message']! as Map)['details']! as Map);
      expect(d, {'totalLines': 1});
      expect(got[1].offset, offsets[2], reason: 'the skipped entry is still counted in the offsets');
      expect(got[2].json, foreign, reason: 'what is not shaped like an omp message is left alone');
      await run.expectQuiet();
      await run.stop();
    });

    test('every fixture log reads the same on the phone with and without it', () async {
      final fixtures = Directory('test/fixtures/omp_logs').listSync().whereType<File>().where((f) => f.path.endsWith('.jsonl')).toList();
      expect(fixtures, isNotEmpty);
      for (final fixture in fixtures) {
        final name = fixture.uri.pathSegments.last;
        final raw = fixture.readAsLinesSync().where((l) => l.isNotEmpty).toList();
        final f = File(host.path())..writeAsStringSync('${raw.join('\n')}\n');
        final r = await host.runToEnd(keeperFollowCommand(f.path, pollMs: 40, idleExit: 1, tailBytes: 8 * 1024 * 1024));
        expect(r.code, 0, reason: '$name: ${r.err}');
        final sent = [
          for (final l in const LineSplitter().convert(r.out))
            if (!l.startsWith('C\t')) l.substring(l.indexOf('\t') + 1),
        ];

        String read(List<String> lines) {
          final mapper = OmpLogMapper();
          var s = const AgentSessionState('s');
          for (final line in lines) {
            for (final u in mapper.map(line)) {
              s = s.apply(u);
            }
          }
          return transcriptFingerprint(s);
        }

        expect(read(sent), read(raw), reason: name);
      }
    });
  });
}
