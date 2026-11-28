@TestOn('linux || mac-os')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/app_info.dart';
import 'package:herdr_mobile/data/host/host_channels.dart';
import 'package:herdr_mobile/data/host/host_link.dart';
import 'package:herdr_mobile/data/observed/omp_log_mapper.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart';
import 'package:herdr_mobile/data/services/ssh_agent_host.dart';

import 'support/keeper_harness.dart';
import 'support/process_host.dart';
import 'support/transcript_fingerprint.dart';

// Runs the real `herdr-host` binary's `keeper.follow`/`keeper.blob` against files in a temp HOME the way the
// app does: `herdr-host serve` under the app's command (`sh -c`), a `HostLink` on it and the real `SshAgentHost`
// (options the app does not use, `poll_ms` and `idle_exit`, open the stream directly). The follower's own
// timing (poll, back-off) is the Rust suite's: it runs on the real clock, which a test here must not wait on.

const _tail = 192 * 1024;

/// One output record of `follow`.
class _Rec {
  _Rec(this.text) : at = DateTime.now();

  /// When the test read it off the pipe: a gap between two records is timed
  /// from these, not from when the test happened to act.
  final DateTime at;

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
  _Follow(this.channel) {
    channel.lines.listen(
      (l) {
        final r = _Rec(l);
        // The caught-up and head records are notes about the stream, not
        // records of the log.
        (r.isCaughtUp
                ? caughtUp
                : r.isHead
                ? heads
                : _records)
            .add(r);
        _wake();
      },
      onError: (Object _) {},
      onDone: () {
        _done = true;
        _wake();
      },
    );
  }

  final ExecChannel channel;
  final _records = <_Rec>[];

  /// The `C` records, in order (the follower sends one, after its first read to the end).
  final caughtUp = <_Rec>[];

  /// The `S` records, in order: where each tail read starts.
  final heads = <_Rec>[];
  var _done = false;
  Completer<void>? _waiting;
  var _taken = 0;

  /// The host's message of the error that ended the stream (empty for a clean end).
  String get stderr => channel.stderrTail;

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

  /// Every record of the follower's first read to the end of the file. It says
  /// when that read is over (the `C` note, sent after the last record), so a
  /// slow start on a busy machine cannot end the wait early the way a quiet
  /// period of a few hundred milliseconds does.
  Future<List<_Rec>> firstRead({Duration timeout = const Duration(seconds: 30)}) async {
    final end = DateTime.now().add(timeout);
    while (caughtUp.isEmpty) {
      if (_done) fail('output ended before the first read was over; stderr: $stderr');
      final left = end.difference(DateTime.now());
      if (left <= Duration.zero) fail('the first read was not over within $timeout');
      final w = _waiting = Completer<void>();
      await w.future.timeout(left, onTimeout: () {});
    }
    final out = _records.sublist(_taken);
    _taken = _records.length;
    return out;
  }

  /// Every record up to the one that ends at [offset], for a read that is not
  /// the first (no `C` note says when it is over) and whose end the test knows.
  Future<List<_Rec>> until(int offset) async {
    final out = <_Rec>[];
    while (true) {
      final r = await next(timeout: const Duration(seconds: 30));
      out.add(r);
      if (!r.isReset && r.offset == offset) return out;
    }
  }

  Future<void> expectQuiet([Duration d = const Duration(milliseconds: 500)]) async {
    await Future<void>.delayed(d);
    expect(_records.length, _taken, reason: 'unexpected output: ${_records.sublist(_taken)}');
  }

  /// Ends the input (what the app's closing of the channel does) and returns
  /// the exit status: 0 for a follow that ended quietly.
  Future<int?> stop() async {
    await channel.closeInput();
    return channel.exitCode.timeout(const Duration(seconds: 10));
  }

  Future<int?> get exitCode => channel.exitCode;
}

/// What a stream that ends by itself said: its status (0 ok, the keeper's 64
/// bad request / 66 not found / 70 failed, null when the link dropped), its
/// lines, and the host's message of the error that ended it.
typedef _Ended = ({int? code, List<String> lines, String err});

class _Host {
  _Host(this.home, this._env);

  final Directory home;
  final Map<String, String> _env;
  var _n = 0;
  final _channels = <ExecChannel>[];
  final _serves = <ProcessHostProcess>[];
  final _links = <HostLink>[];
  HostLink? _shared;
  Future<HostLink>? _linking;

  static Future<_Host> create() async {
    final home = Directory.systemTemp.createTempSync('follow_test_');
    final host = _Host(home, {'HOME': home.path, 'PATH': '/usr/bin:/bin'});
    // The binary keeper: what `follow`/`blob` reach through the link, the
    // way the phone does.
    await installHostBinary(home);
    return host;
  }

  /// A new path for a log file in the home folder.
  String path([String name = 'log']) => '${home.path}/${name}_${_n++}.jsonl';

  /// A new `herdr-host serve` as an SSH server would run the app's command,
  /// with a link on it (its own channel, like another phone).
  Future<HostLink> openLink() async {
    final serve = await ProcessHostProcess.start(
      '/bin/sh',
      ['-c', hostServeCommand()],
      environment: _env,
      workingDirectory: home.path,
    );
    _serves.add(serve);
    final link = await HostLink.connect(serve, version: appVersion, helloTimeout: const Duration(seconds: 30));
    _links.add(link);
    return link;
  }

  /// The shared link, opened on first use and again after it died.
  Future<HostLink> link() {
    final live = _shared;
    if (live != null && live.isOpen) return Future.value(live);
    return _linking ??= openLink().then((l) => _shared = l).whenComplete(() => _linking = null);
  }

  /// What the app has of this machine: the real [SshAgentHost] over [link].
  late final LinkTransport transport = LinkTransport(link);
  late final SshAgentHost agentHost = SshAgentHost(transport, quickTimeout: const Duration(seconds: 30));

  /// `keeper.[method]` opened as a stream on the shared link (or [on]) with
  /// exactly [args]: for what the app does not send.
  Future<ExecChannel> open(String method, Map<String, Object?> args, {HostLink? on}) async {
    final channel = HostLineChannel((on ?? await link()).open('keeper', method, args, true));
    _channels.add(channel);
    return channel;
  }

  /// A follow of [path]. Through the app's `SshAgentHost.follow` unless a
  /// [pollMs] or [idleExit] is given (the app uses neither): then the stream
  /// is opened with those arguments.
  Future<_Follow> follow(String path, {int? from, int? pollMs, int? idleExit, int? tailBytes}) async {
    final channel = pollMs == null && idleExit == null
        ? await agentHost.follow(path, from: from, tailBytes: tailBytes)
        : await open('follow', {
            'path': path,
            'from': ?from,
            'poll_ms': ?pollMs,
            'idle_exit': ?idleExit,
            'tail_bytes': ?tailBytes,
          });
    _channels.add(channel);
    return _Follow(channel);
  }

  /// Reads a stream that is expected to end by itself (a bounded follow, a
  /// blob, a refusal) to its end.
  Future<_Ended> collect(ExecChannel channel) async {
    _channels.add(channel);
    final lines = <String>[];
    final ended = Completer<void>();
    channel.lines.listen(lines.add, onError: (Object _) {}, onDone: ended.complete);
    final code = await channel.exitCode.timeout(const Duration(seconds: 20));
    await ended.future.timeout(const Duration(seconds: 20));
    return (code: code, lines: lines, err: channel.stderrTail);
  }

  Future<void> dispose() async {
    for (final c in _channels) {
      unawaited(c.close());
    }
    for (final l in _links) {
      try {
        await l.close();
      } on Object {
        // already gone
      }
    }
    for (final p in _serves) {
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
  late _Host host;
  late Directory outside;

  setUpAll(() async {
    host = await _Host.create();
    outside = Directory.systemTemp.createTempSync('follow_outside_');
  });

  tearDownAll(() async {
    await host.dispose();
    outside.deleteSync(recursive: true);
  });

  group('follow', () {
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
      final got = await run.firstRead();
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
      expect(await run.firstRead(), hasLength(3));
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
        final got = await run.firstRead();
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

    test('tail_bytes is clamped to 16 KB..64 MB', () async {
      Future<int> lineCount(int tailBytes) async {
        final f = File(host.path());
        _write(f, [for (var i = 0; i < 10000; i++) _json(i, pad: 'y' * (48 - '$i'.length))]);
        final run = await host.follow(f.path, tailBytes: tailBytes);
        final got = await run.firstRead();
        await run.stop();
        return got.length;
      }

      expect(await lineCount(1), 256, reason: 'never below 16 KB');
      expect(await lineCount(0), 256, reason: 'a size of 0 is the least too');
      expect(await lineCount(16384), 256);
      expect(await lineCount(1 << 40), 10000, reason: 'never above 64 MB: the 640 KB file comes whole');
    });

    test('from wins over tail_bytes, and a reset uses the tail size too', () async {
      final f = File(host.path());
      final offsets = _write(f, [for (var i = 0; i < 10000; i++) _json(i, pad: 'y' * (48 - '$i'.length))]);
      final resumed = await host.follow(f.path, from: offsets[9996], tailBytes: 16384);
      expect([for (final r in await resumed.take(3)) r.json['n']], [9997, 9998, 9999]);
      await resumed.stop();

      final stale = await host.follow(f.path, from: offsets.last + 5, tailBytes: 16384);
      expect((await stale.next()).isReset, isTrue);
      expect(await stale.firstRead(), hasLength(256));
      expect(stale.heads, hasLength(1), reason: 'the reset tail says where it starts too');
      await stale.stop();
    });

    test('one line longer than the window: nothing before its end, then it follows', () async {
      final f = File(host.path());
      f.writeAsStringSync('${'z' * (_tail + 100)}\n{"n":1}\n');
      final run = await host.follow(f.path);
      final got = await run.firstRead();
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
      // Starting fast is reading only the tail: what comes over is the window, not 30 MB.
      final run = await host.follow(f.path);
      final firstRecord = await run.next();
      final rest = await run.firstRead();
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

    test('a follow started the way the app starts it delivers every append, in order', () async {
      final f = File(host.path());
      _write(f, [_json(1)]);
      final run = await host.follow(f.path);
      await run.next();
      for (var i = 0; i < 4; i++) {
        _write(f, [_json(2 + i)], mode: FileMode.append);
        expect((await run.next(timeout: const Duration(seconds: 30))).json['n'], 2 + i);
      }
      await run.stop();
    });

    test('a poll interval can be given', () async {
      // A real process given it delivers a line appended after its first read.
      final f = File(host.path());
      _write(f, [_json(1)]);
      final run = await host.follow(f.path, pollMs: 2000);
      await run.next();
      _write(f, [_json(2)], mode: FileMode.append);
      expect((await run.next(timeout: const Duration(seconds: 30))).json['n'], 2);
      await run.stop();
    });

    test('without idle_exit a quiet file keeps it running', () async {
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

    test('idle_exit ends the follow by itself after that long without growth', () async {
      final f = File(host.path());
      _write(f, [_json(1)]);
      final run = await host.follow(f.path, idleExit: 1, pollMs: 20);
      await run.next();
      expect(await run.exitCode.timeout(const Duration(seconds: 20)), 0);
      expect(run.stderr, isEmpty);
    });

    test('a poll interval of 0 is the shortest one, not an error', () async {
      final f = File(host.path());
      _write(f, [_json(1)]);
      final run = await host.follow(f.path, pollMs: 0);
      expect((await run.next()).json['n'], 1);
      _write(f, [_json(2)], mode: FileMode.append);
      expect((await run.next()).json['n'], 2);
      expect(await run.stop(), 0);
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
      // The reset is not a first read (no `C` note again): up to the file's end.
      final got = await run.until(offsets.last);
      final first = got.first.json['n']! as int;
      expect(reset.resetOffset, greaterThanOrEqualTo(offsets.last - _tail - 1));
      expect(got.last.offset, offsets.last);
      expect(first, greaterThan(0));
      await run.stop();
    });
  });

  group('follow from', () {
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
      final got = await run.firstRead();
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

  group('follow to and digest', () {
    /// The records of one run that ends by itself: `<offset>\t<json>` lines as
    /// (offset, json), and the other records (`R`, `C`) as text.
    Future<({List<(int, Map<String, dynamic>)> lines, List<String> notes, int? code})> bounded(
      File f, {
      int? from,
      required int until,
      bool digest = false,
    }) async {
      final r = await host.collect(await host.agentHost.follow(f.path, from: from, to: until, digest: digest));
      final lines = <(int, Map<String, dynamic>)>[];
      final notes = <String>[];
      for (final l in r.lines) {
        final tab = l.indexOf('\t');
        final offset = int.tryParse(l.substring(0, tab));
        if (offset == null) {
          notes.add(l);
        } else {
          lines.add((offset, jsonDecode(l.substring(tab + 1)) as Map<String, dynamic>));
        }
      }
      return (lines: lines, notes: notes, code: r.code);
    }

    test('reads [from, until) once, says where it stopped, and ends: it does not wait for the file to grow', () async {
      final f = File(host.path());
      final offsets = _write(f, [for (var i = 0; i < 8; i++) _json(i)]);
      final r = await bounded(f, from: offsets[1], until: offsets[4]);
      expect(r.code, 0);
      expect([for (final l in r.lines) l.$2['n']], [2, 3, 4]);
      expect(r.lines.last.$1, offsets[4]);
      expect(r.notes, ['C\t${offsets[4]}']);
    });

    test('an until inside a line sends that line whole: the tail of a log starts inside one, and it is in neither part otherwise', () async {
      final f = File(host.path());
      final offsets = _write(f, [for (var i = 0; i < 6; i++) _json(i, pad: 'p' * 40)]);
      final r = await bounded(f, from: offsets[1], until: offsets[2] + 5);
      expect([for (final l in r.lines) l.$2['n']], [2, 3], reason: 'line 3 starts before until and ends after it');
      expect(r.lines.last.$1, offsets[3]);
      expect(r.notes, ['C\t${offsets[3]}']);
      final exact = await bounded(f, from: offsets[1], until: offsets[2]);
      expect([for (final l in exact.lines) l.$2['n']], [2], reason: 'an until on a line start adds nothing');
    });

    test('without a from it starts at the start of the file', () async {
      final f = File(host.path());
      final offsets = _write(f, [for (var i = 0; i < 5; i++) _json(i)]);
      final r = await bounded(f, until: offsets[2]);
      expect([for (final l in r.lines) l.$2['n']], [0, 1, 2]);
    });

    test('a from that is not a line start of the file starts over at 0, with a reset', () async {
      final f = File(host.path());
      final offsets = _write(f, [for (var i = 0; i < 5; i++) _json(i)]);
      final r = await bounded(f, from: offsets[0] + 3, until: offsets[2]);
      expect(r.notes.first, 'R\t0');
      expect([for (final l in r.lines) l.$2['n']], [0, 1, 2]);
      final beyond = await bounded(f, from: 1 << 20, until: offsets[1]);
      expect(beyond.notes.first, 'R\t0');
      expect([for (final l in beyond.lines) l.$2['n']], [0, 1]);
    });

    test('an until past the end of the file reads to the end', () async {
      final f = File(host.path());
      final offsets = _write(f, [_json(0), _json(1)]);
      final r = await bounded(f, until: 1 << 30);
      expect(r.lines, hasLength(2));
      expect(r.notes, ['C\t${offsets.last}']);
    });

    test('a digest empties the model\'s thinking, cuts long strings to 8 KB and leaves bookkeeping entries out, but counts them in the offsets', () async {
      final f = File(host.path());
      final assistant = jsonEncode({
        'type': 'message',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'thinking', 'thinking': 'secret ' * 500, 'thinkingSignature': 'sig' * 300},
            {'type': 'text', 'text': 'Open http://localhost:8765/synth'},
            {
              'type': 'toolCall',
              'id': 'c1',
              'name': 'bash',
              'arguments': {'command': 'npm run dev', 'blob': 'y' * 30000},
            },
          ],
        },
      });
      final offsets = _write(f, [
        jsonEncode({'type': 'custom', 'customType': 'session_exit', 'data': 'z' * 100}),
        assistant,
        jsonEncode({'type': 'model_usage', 'n': 1}),
        _json(7),
      ]);
      final r = await bounded(f, until: offsets.last, digest: true);
      expect(r.lines.map((l) => l.$1), [
        offsets[1],
        offsets[3],
      ], reason: 'each kept line says where it ends in the file');
      final content = (r.lines.first.$2['message'] as Map)['content'] as List;
      expect(content[0], {'type': 'thinking', 'thinking': ''});
      expect(content[1]['text'], 'Open http://localhost:8765/synth');
      expect(content[2]['arguments']['command'], 'npm run dev');
      expect((content[2]['arguments']['blob'] as String).length, lessThan(9 * 1024));
      expect(r.lines.last.$2['n'], 7);
      expect(r.notes, ['C\t${offsets.last}']);

      final plain = await bounded(f, until: offsets.last);
      expect(plain.lines, hasLength(4), reason: 'without --digest every line comes');
      expect(((plain.lines[1].$2['message'] as Map)['content'] as List)[0]['thinking'], startsWith('secret'));
    });
  });

  group('follow refuses', () {
    Future<_Ended> asked(String path) async => host.collect(await host.agentHost.follow(path));

    Future<void> refused(String path, {String? why}) async {
      final r = await asked(path);
      expect(r.code, 66, reason: '$path: ${r.err}');
      expect(r.lines, isEmpty, reason: path);
      expect(r.err, isNotEmpty, reason: path);
      expect(r.err, isNot(startsWith('herdr-mobile')), reason: path);
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

    test('what cannot be a path, and arguments of the wrong kind, are bad requests', () async {
      for (final bad in ['', 'a\nb.jsonl', 'a\u0000b.jsonl', 'a\rb.jsonl', 'x' * 5000, 'a\u007fb']) {
        final r = await asked(bad);
        expect(r.code, 64, reason: bad.length > 50 ? 'long' : bad);
        expect(r.lines, isEmpty);
        expect(r.err, contains('path'));
      }
      // A negative offset is not an offset; a call without its path is not a call.
      for (final args in <Map<String, Object?>>[
        {'path': '/a.jsonl', 'from': -1},
        {'path': '/a.jsonl', 'to': 'x'},
        {'path': '/a.jsonl', 'tail_bytes': -5},
        {'path': '/a.jsonl', 'poll_ms': 1.5},
        {'path': '/a.jsonl', 'idle_exit': -1},
        {'from': 0},
        {'path': 42},
      ]) {
        final r = await host.collect(await host.open('follow', args));
        expect(r.code, 64, reason: '$args: ${r.err}');
        expect(r.lines, isEmpty, reason: '$args');
      }
    });
  });

  group('blob', () {
    final bytes = List.generate(150000, (i) => (i * 7) % 251);
    final b64 = base64.encode(bytes);

    /// The records of `follow` for [lines] as (start offset, ref) pairs of every
    /// dropped payload, found in the notes.
    Future<List<({int start, String hash})>> refs(File f, List<String> lines) async {
      _write(f, lines);
      final run = await host.follow(f.path, from: 0);
      final got = await run.take(lines.length);
      await run.stop();
      return [
        for (final r in got)
          for (final m in RegExp(r'ref=(\d+)\.([0-9a-f]{16})').allMatches(r.body))
            (start: int.parse(m[1]!), hash: m[2]!),
      ];
    }

    Future<List<int>> fetched(String path, int start, String hash) async {
      final r = await host.collect(await host.open('blob', {'path': path, 'start': start, 'hash': hash}));
      expect(r.code, 0, reason: r.err);
      final records = r.lines;
      expect(records.last, startsWith('D\t'));
      final text = [for (final l in records.where((l) => l.startsWith('B\t'))) l.substring(2)].join();
      expect(int.parse(records.last.substring(2)), text.length);
      expect(records.where((l) => l.startsWith('B\t')).every((l) => l.length <= 2 + 48 * 1024), isTrue);
      return base64.decode(text);
    }

    test(
      'the bytes of a Claude picture, an omp-style one and a data URI come back whole, whatever lines come before',
      () async {
        final f = File(host.path());
        final lines = [
          _json(1, pad: 'héllo 日本語 ' * 30),
          jsonEncode({
            'type': 'user',
            'message': {
              'content': [
                {
                  'type': 'image',
                  'source': {'type': 'base64', 'media_type': 'image/png', 'data': b64},
                },
                {'type': 'text', 'text': 'look'},
              ],
            },
          }),
          jsonEncode({
            'message': {
              'content': [
                {'type': 'image', 'mimeType': 'image/jpeg', 'data': b64},
              ],
            },
          }),
          jsonEncode({'type': 'image', 'image_url': 'data:image/png;base64,$b64'}),
          jsonEncode({
            'details': {'blob': 'data:image/png;base64,$b64'},
          }),
        ];
        final found = await refs(f, lines);
        expect(found, hasLength(4));
        final offsets = _write(f, lines);
        expect([for (final r in found) r.start], [offsets[0], offsets[1], offsets[2], offsets[3]]);
        for (final r in found) {
          expect(await fetched(f.path, r.start, r.hash), bytes);
        }
        // ...and the app's own call gives the same bytes.
        final first = found.first;
        expect(await host.agentHost.blob(f.path, start: first.start, hash: first.hash), bytes);
      },
    );

    test('two pictures in one line are told apart by their hash', () async {
      final f = File(host.path());
      final other = base64.encode(List.generate(2000, (i) => (i * 3) % 251));
      final found = await refs(f, [
        jsonEncode({
          'content': [
            {'type': 'image', 'data': b64},
            {'type': 'image', 'data': other},
          ],
        }),
      ]);
      expect(found, hasLength(2));
      expect(await fetched(f.path, found[0].start, found[0].hash), bytes);
      expect(await fetched(f.path, found[1].start, found[1].hash), base64.decode(other));
    });

    test('a payload with line breaks does not break the records', () async {
      final f = File(host.path());
      final wrapped = [
        for (var i = 0; i < b64.length; i += 76) b64.substring(i, i + 76 > b64.length ? b64.length : i + 76),
      ].join('\n');
      final found = await refs(f, [
        jsonEncode({'type': 'image', 'data': wrapped}),
      ]);
      expect(await fetched(f.path, found.single.start, found.single.hash), bytes);
    });

    Future<void> gone(String path, int start, String hash, {String? why}) async {
      final r = await host.collect(await host.open('blob', {'path': path, 'start': start, 'hash': hash}));
      expect(r.code, 66, reason: r.err);
      expect(r.lines, isEmpty);
      expect(r.err, isNot(startsWith('herdr-mobile')));
      if (why != null) expect(r.err, contains(why));
    }

    test('a wrong hash, a start that is not a line start and a start past the end are gone', () async {
      final f = File(host.path());
      final found = await refs(f, [
        _json(1),
        jsonEncode({'type': 'image', 'data': b64}),
      ]);
      final ref = found.single;
      await gone(f.path, ref.start, '0123456789abcdef', why: 'not in the log');
      await gone(f.path, ref.start + 3, ref.hash, why: 'changed');
      await gone(f.path, ref.start - 1, ref.hash, why: 'changed');
      await gone(f.path, f.lengthSync() + 100, ref.hash, why: 'changed');
      await gone(f.path, f.lengthSync(), ref.hash, why: 'not in the log');
    });

    test('a log that was rewritten under the ref, and a line that is not JSON, are gone', () async {
      final f = File(host.path());
      final ref = (await refs(f, [
        jsonEncode({'type': 'image', 'data': b64}),
      ])).single;
      f.writeAsStringSync('not json at all\n');
      await gone(f.path, ref.start, ref.hash, why: 'not in the log');
      f.writeAsStringSync('${_json(1)}\n${jsonEncode({'type': 'image', 'data': b64.substring(0, 5000)})}\n');
      await gone(f.path, ref.start, ref.hash, why: 'not in the log');
    });

    test('a missing file, a path outside the home folder and a path that is not a log are refused', () async {
      final far = File('${outside.path}/far.jsonl')..writeAsStringSync('{}\n');
      for (final path in ['${host.home.path}/nope.jsonl', far.path, '/etc/passwd', 'relative.jsonl']) {
        await gone(path, 0, '0123456789abcdef', why: 'not in the log');
      }
    });

    test('what the person reads for a log that is gone has no host path in it', () async {
      final f = File(host.path());
      final ref = (await refs(f, [
        jsonEncode({'type': 'image', 'data': b64}),
      ])).single;
      f.deleteSync();
      final r = await host.collect(await host.open('blob', {'path': f.path, 'start': ref.start, 'hash': ref.hash}));
      expect(r.code, 66);
      expect(r.err, isNot(contains(host.home.path)));
      // ...and in the app's words.
      await expectLater(
        host.agentHost.blob(f.path, start: ref.start, hash: ref.hash),
        throwsA(
          isA<AgentHostException>()
              .having((e) => e.fatal, 'fatal', isTrue)
              .having((e) => e.message, 'message', allOf(contains('not in the log'), isNot(contains(host.home.path)))),
        ),
      );
    });

    test('a start or hash that is not what it should be is a bad request, not a crash', () async {
      for (final args in <Map<String, Object?>>[
        {'path': '/x.jsonl', 'start': '\u00b2', 'hash': '0123456789abcdef'},
        {'path': '/x.jsonl', 'start': -1, 'hash': '0123456789abcdef'},
        {'path': '/x.jsonl', 'start': 0, 'hash': 'not hex at all!!'},
        {'path': '/x.jsonl', 'start': 0, 'hash': '0123456789abcde'},
        {'path': 'a\nb.jsonl', 'start': 0, 'hash': '0123456789abcdef'},
        {'path': '/x.jsonl'},
      ]) {
        final r = await host.collect(await host.open('blob', args));
        expect(r.code, 64, reason: '$args: ${r.err}');
        expect(r.err, isNot(contains('Traceback')));
        expect(r.lines, isEmpty, reason: '$args');
      }
    });

    test('a picture in a line longer than follow sends has no ref at all, so none is fetched', () async {
      final f = File(host.path());
      final huge = base64.encode(List.filled(5 * 1024 * 1024, 7));
      _write(f, [
        jsonEncode({'type': 'image', 'data': huge}),
        _json(2),
      ]);
      final run = await host.follow(f.path, from: 0);
      final got = await run.take(2);
      await run.stop();
      expect(got.first.body, isNot(contains('ref=')));
      expect(got.first.json['raw'], contains('not sent'));
    });

    test('a data URI keeps its type in the note, in a typed part and in a plain field', () async {
      final f = File(host.path());
      final found = await refs(f, [
        jsonEncode({'type': 'image', 'image_url': 'data:image/png;base64,$b64'}),
        jsonEncode({
          'details': {'blob': 'data:image/jpeg;base64,$b64'},
        }),
      ]);
      expect(found, hasLength(2));
      final run = await host.follow(f.path, from: 0);
      final got = await run.take(2);
      await run.stop();
      expect(
        got[0].body,
        contains('data:image/png;base64,[${'data:image/png;base64,'.length + b64.length} bytes of data not sent; ref='),
      );
      expect(got[1].body, contains('data:image/jpeg;base64,['));
    });

    test('a payload that is not text a picture can be made of is refused', () async {
      final f = File(host.path());
      final odd = 'é' * 400;
      final ref = (await refs(f, [
        jsonEncode({'type': 'image', 'data': odd}),
      ])).single;
      await gone(f.path, ref.start, ref.hash, why: 'not a picture');
    });

    test('a path with quotes, spaces, \$() and backticks is passed as one word, never run', () async {
      final marker = '${host.home.path}/blob_pwned';
      final dir = Directory('${host.home.path}/it\'s a "dir" \$(touch blob_pwned) `touch blob_pwned`; x')..createSync();
      final f = File('${dir.path}/we ird\\ \$HOME.jsonl');
      final found = await refs(f, [
        jsonEncode({'type': 'image', 'data': b64}),
      ]);
      expect(await fetched(f.path, found.single.start, found.single.hash), bytes);
      for (final evil in ["x'; touch $marker; '.jsonl", '\$(touch $marker).jsonl', '`touch $marker`.jsonl']) {
        await gone('${host.home.path}/$evil', 0, '0123456789abcdef');
      }
      expect(File(marker).existsSync(), isFalse);
    });
  });

  group('follow cuts heavy fields on the host', () {
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
      final got = (await follow([
        jsonEncode({'type': 'message', 'text': big, 'short': 'ok'}),
      ])).single;
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
      final got = (await follow([
        jsonEncode({'t': '日' * 20000}),
      ])).single; // 60000 bytes
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
              {
                'type': 'toolCall',
                'arguments': {'cmd': big, 'n': 3, 'ok': true, 'none': null, 'f': 1.5},
              },
              {'type': 'text', 'text': big},
            ],
          },
          big: 1,
        }),
      ])).single;
      final root = got.json;
      final content = ((root['message']! as Map)['content']! as List).cast<Map>();
      expect((content[0]['arguments'] as Map)['cmd'], endsWith('... [33616 bytes cut]'));
      expect(((content[0]['arguments'] as Map)).entries.where((e) => e.key != 'cmd').map((e) => e.value), [
        3,
        true,
        null,
        1.5,
      ]);
      expect(content[1]['text'], endsWith('bytes cut]'));
      expect(root.keys.where((k) => k.length > 17000), isEmpty);
      expect(got.body.length, lessThan(5 * 16384));
    });

    test('an image keeps its metadata and loses the payload, and says where to fetch it', () async {
      final b64 = base64.encode(List.generate(300000, (i) => i % 251));
      final lines = [
        jsonEncode({
          'message': {
            'content': [
              {'type': 'image', 'mimeType': 'image/png', 'data': b64, 'width': 640},
              {
                'type': 'image',
                'source': {'type': 'base64', 'media_type': 'image/jpeg', 'data': b64},
              },
              {'type': 'text', 'text': 'see'},
            ],
          },
        }),
        jsonEncode({
          'details': {'blob': 'data:image/png;base64,$b64'},
          'data': b64,
        }),
      ];
      final got = await follow(lines);
      final content = (((got[0].json['message']! as Map)['content']!) as List).cast<Map>();
      expect(content[0]['type'], 'image');
      expect(content[0]['mimeType'], 'image/png');
      expect(content[0]['width'], 640);
      expect(
        content[0]['data'],
        matches(RegExp('^\\[${b64.length} bytes of data not sent; ref=0\\.[0-9a-f]{16}\\]\$')),
      );
      expect((content[1]['source'] as Map)['media_type'], 'image/jpeg');
      expect(
        (content[1]['source'] as Map)['data'],
        matches(RegExp('^\\[${b64.length} bytes of data not sent; ref=0\\.[0-9a-f]{16}\\]\$')),
      );
      expect(content[2]['text'], 'see');
      expect(got[0].body.length, lessThan(700));
      final second = got[1].json;
      final secondStart = got[0].offset;
      expect(
        second['data'],
        matches(RegExp('^\\[${b64.length} bytes of data not sent; ref=$secondStart\\.[0-9a-f]{16}\\]\$')),
      );
      expect(
        ((second['details']! as Map)['blob']! as String),
        matches(
          RegExp(
            '^data:image/png;base64,\\[${'data:image/png;base64,'.length + b64.length} bytes of data not sent; ref=$secondStart\\.[0-9a-f]{16}\\]\$',
          ),
        ),
      );
    });

    test('a picture\'s ref points at its line: the first record of a tail read starts where the tail does', () async {
      final f = File(host.path());
      final b64 = base64.encode(List.generate(5000, (i) => i % 251));
      final lines = [
        for (var i = 0; i < 6; i++) i == 4 ? jsonEncode({'type': 'image', 'data': b64}) : _json(i, pad: 'x' * 200),
      ];
      final offsets = _write(f, lines);
      // A tail that starts inside line 2: the follower skips the rest of it.
      final run = await host.follow(f.path, tailBytes: offsets.last - offsets[1] + 20);
      final got = await run.firstRead();
      final image = got.firstWhere((r) => r.json['type'] == 'image');
      expect(image.json['data'], contains('ref=${offsets[3]}.'));
      await run.stop();
    });

    test('a small data field and ordinary text named data are left alone', () async {
      final got = (await follow([
        jsonEncode({'data': 'QUJD', 'bytes': 'hello world ' * 200, 'type': 'text'}),
      ])).single;
      expect(got.json['data'], 'QUJD');
      expect((got.json['bytes']! as String).startsWith('hello world'), isTrue);
    });

    test('whatever is not JSON arrives as {"raw": first 2 KB}', () async {
      final longRaw = 'not json ' * 1000;
      final f = File(host.path());
      f.writeAsBytesSync([
        ...utf8.encode('plain words\n$longRaw\n{"broken":\n'),
        0xff,
        0xfe,
        ...utf8.encode(' bad utf8 {"a":1}\n'),
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

  group('follow ends', () {
    test('quietly when the input ends, even if the file never changes', () async {
      final f = File(host.path());
      _write(f, [_json(1)]);
      // A poll of a minute: a follower that only noticed the closed input at its
      // next look would not end within the 10 s `stop` allows.
      final run = await host.follow(f.path, pollMs: 60000);
      await run.next();
      expect(await run.stop(), 0);
      expect(run.stderr, isEmpty);
    });

    test('an ended input ends a running follow with status 0, a reset leaves no status', () async {
      final f = File(host.path());
      _write(f, [for (var i = 0; i < 6000; i++) _json(i, pad: 'e' * 80)]);
      final ended = await host.follow(f.path);
      await ended.firstRead();
      await ended.channel.closeInput();
      expect(await ended.exitCode.timeout(const Duration(seconds: 10)), 0);

      final reset = await host.follow(f.path);
      await reset.next();
      await reset.channel.close();
      expect(await reset.exitCode.timeout(const Duration(seconds: 10)), isNull);
    });

    test('a reset frees the place of a follow that waits on a reader that never reads', () async {
      final rnd = Random(7);
      final big = File(host.path());
      // Lines that do not compress: 2 MB, more than the host sends before the reader has read any of it.
      _write(big, [
        for (var i = 0; i < 2000; i++) _json(i, pad: base64.encode(List.generate(768, (_) => rnd.nextInt(256)))),
      ]);
      final small = File(host.path());
      _write(small, [_json(1)]);
      final link = await host.openLink();
      final places = link.hello.limits.maxStreams;
      HostLineChannel follow(File f, Map<String, Object?> more) =>
          HostLineChannel(link.open('keeper', 'follow', {'path': f.path, ...more}, true));
      final held = <HostLineChannel>[];
      try {
        // Every place but one taken by quiet follows; the last one by a follow nobody reads.
        for (var i = 0; i < places - 1; i++) {
          held.add(follow(small, const {}));
        }
        final blocked = follow(big, const {'from': 0});
        held.add(blocked);
        final full = await host.collect(follow(small, const {}));
        expect(full.code, isNot(0), reason: 'the host has no place left');
        expect(full.err, contains('too many'));

        await blocked.close();
        await eventually(
          () async => (await host.collect(follow(small, const {'to': 1}))).code == 0,
          what: 'a place for a new follow after the reset',
        );
      } finally {
        for (final c in held) {
          unawaited(c.close());
        }
        await link.close();
      }
    });
  });

  group('follow says it is up to date', () {
    test('once, with the offset it has reached: an empty file, a tail, and a resume at the end', () async {
      final empty = File(host.path())..writeAsStringSync('');
      final a = await host.follow(empty.path);
      await a.firstRead();
      expect([for (final c in a.caughtUp) c.text], ['C\t0']);
      await a.stop();

      final f = File(host.path());
      final offsets = _write(f, [_json(1), _json(2)]);
      final b = await host.follow(f.path);
      expect([for (final r in await b.take(2)) r.offset], offsets);
      await b.firstRead();
      expect([for (final c in b.caughtUp) c.text], ['C\t${offsets.last}']);
      _write(f, [_json(3)], mode: FileMode.append);
      expect((await b.next()).json['n'], 3);
      await b.expectQuiet();
      expect(b.caughtUp, hasLength(1), reason: 'said once, not after every line');
      await b.stop();

      final c = await host.follow(f.path, from: offsets.first);
      expect((await c.next()).json['n'], 2);
      await c.firstRead();
      expect(c.caughtUp.single.text, 'C\t${f.lengthSync()}', reason: 'the offset of the end it has sent up to');
      await c.stop();

      final d = await host.follow(f.path, from: f.lengthSync());
      await d.firstRead();
      expect(d.caughtUp.single.text, 'C\t${f.lengthSync()}', reason: 'a resume at the end has no record to say it by');
      await d.stop();
    });
  });

  group('a long transcript through the link', () {
    String row(int i) => jsonEncode({'n': i, 'text': 'line $i of the log, with words that repeat ${i % 7}'});

    test('a big tail comes whole as plain text records, the same as a bounded read of it', () async {
      final f = File(host.path());
      final offsets = _write(f, [for (var i = 0; i < 3000; i++) row(i)]);
      final run = await host.follow(f.path, from: 0);
      final got = await run.firstRead();
      await run.stop();
      expect(got, hasLength(3000));
      expect([for (final r in got) r.offset], offsets);
      for (var i = 0; i < got.length; i++) {
        expect(got[i].json, jsonDecode(row(i)), reason: 'record $i');
        expect(got[i].text, matches(RegExp(r'^\d+\t\{')), reason: 'plain text, not an encoded line');
      }

      final bounded = await host.collect(await host.agentHost.follow(f.path, from: 0, to: offsets.last));
      expect(bounded.code, 0, reason: bounded.err);
      expect(bounded.lines.where((l) => !l.startsWith('C\t')), [for (final r in got) r.text]);
    });

    test('later batches arrive in order after the first read', () async {
      final f = File(host.path());
      _write(f, [for (var i = 0; i < 300; i++) row(i)]);
      final run = await host.follow(f.path);
      expect(await run.firstRead(), hasLength(300));
      for (var batch = 0; batch < 3; batch++) {
        final from = 300 + batch * 40;
        _write(f, [for (var i = from; i < from + 40; i++) row(i)], mode: FileMode.append);
        final got = await run.take(40);
        expect([for (final r in got) r.json['n']], [for (var i = from; i < from + 40; i++) i]);
      }
      expect(await run.stop(), 0);
    });
  });

  group('follow leaves out what omp keeps for itself', () {
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
      final foreign = {
        'type': 'assistant',
        'usage': {'input': 3},
        'message': {'usage': 1},
      };
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
      final fixtures = Directory('test/fixtures/omp_logs')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.jsonl'))
          .toList();
      expect(fixtures, isNotEmpty);
      for (final fixture in fixtures) {
        final name = fixture.uri.pathSegments.last;
        final raw = fixture.readAsLinesSync().where((l) => l.isNotEmpty).toList();
        final f = File(host.path())..writeAsStringSync('${raw.join('\n')}\n');
        final run = await host.follow(f.path, tailBytes: 8 * 1024 * 1024);
        final got = await run.firstRead();
        await run.stop();
        final sent = [for (final r in got) r.body];

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
