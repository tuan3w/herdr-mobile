// Transfer benchmark, run by `autoresearch.sh`:
//
//   flutter test benchmark/transfer_bench.dart
//
// The real transport stack (IsolateTransport -> dartssh2 -> the remote mux
// script -> a unix socket) talking to a deterministic stand-in for herdr
// (`fake_herdr.py`), over SSH to this machine's own sshd. The workload is what
// a session asks for: snapshot refreshes, pane screen reads (300 ANSI rows),
// and the board's 24-row preview reads. It goes through HerdrApi, so the
// models' parsing is part of the cost.
//
// What is measured, per workload and in total:
//  * wire_kb: bytes the TCP connection carried, both directions (`ss -ti`),
//    SSH framing and encryption overhead included;
//  * cpu_ms: CPU time of this process (main isolate + transport isolate),
//    i.e. the phone's cost of cipher, decompression, JSON and models. Remote
//    CPU (python, sshd) is not counted;
//  * wall_ms: elapsed, requests issued one after another.
//
// transfer_ms is the headline: cpu_ms plus the time the wire bytes take on a
// modelled link (ASSUMPTION: 1.25 MB/s, i.e. 10 Mbit/s; round trips are not
// modelled because the request count does not change).
//
// Needs sshd on localhost accepting ~/.ssh/herdr-mobile for $USER, python3.
// Results go to $BENCH_OUT (METRIC lines): `flutter test` decorates stdout.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/transport_factory.dart';

const _linkBytesPerMs = 1250.0; // 10 Mbit/s

const _snapshots = 60;
const _screenReads = 60;
const _previewRounds = 3;
const _previewPanes = 40;

final _out = <String>[];

void _metric(String name, num value) =>
    _out.add('METRIC $name=${value is int ? value : value.toStringAsFixed(3)}');

/// utime + stime of every thread of this process, in ms.
double _cpuMs() {
  var ticks = 0;
  for (final t in Directory('/proc/self/task').listSync()) {
    final stat = File('${t.path}/stat').readAsStringSync();
    // Fields after the ")" that closes the command name; utime/stime are the
    // 12th and 13th of them.
    final f = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
    ticks += int.parse(f[11]) + int.parse(f[12]);
  }
  return ticks * 10.0; // CLK_TCK is 100
}

/// Bytes (sent, received) on this process's connection to an sshd.
Future<(int, int)> _wireBytes() async {
  final r = await Process.run('ss', ['-tinpH', 'state', 'established', '( dport = :22 )']);
  final lines = (r.stdout as String).split('\n');
  for (var i = 0; i < lines.length - 1; i++) {
    if (!lines[i].contains('pid=$pid,')) continue;
    final m = lines[i + 1];
    final sent = RegExp(r'bytes_sent:(\d+)').firstMatch(m);
    final got = RegExp(r'bytes_received:(\d+)').firstMatch(m);
    if (sent != null && got != null) {
      return (int.parse(sent.group(1)!), int.parse(got.group(1)!));
    }
  }
  throw StateError('no ssh connection of pid $pid in ss output:\n${r.stdout}');
}

typedef _Result = ({double cpu, double wall, int bytes, int up});

Future<_Result> _measure(Future<void> Function() work) async {
  final b0 = await _wireBytes();
  final c0 = _cpuMs();
  final w = Stopwatch()..start();
  await work();
  w.stop();
  final c1 = _cpuMs();
  final b1 = await _wireBytes();
  return (
    cpu: c1 - c0,
    wall: w.elapsedMicroseconds / 1000,
    bytes: (b1.$1 - b0.$1) + (b1.$2 - b0.$2),
    up: b1.$1 - b0.$1,
  );
}

void main() {
  test('transfer', () async {
    final home = Platform.environment['HOME']!;
    final user = Platform.environment['USER'] ?? Platform.environment['LOGNAME']!;
    final key = File('$home/.ssh/herdr-mobile').readAsStringSync();

    final dir = Directory.systemTemp.createTempSync('transfer_bench');
    final sock = '${dir.path}/herdr.sock';
    final fake = await Process.start('python3', ['benchmark/fake_herdr.py', sock]);
    addTearDown(() {
      fake.kill();
      dir.deleteSync(recursive: true);
    });
    final ready = Completer<void>();
    fake.stdout.transform(utf8.decoder).listen((s) {
      if (s.contains('READY') && !ready.isCompleted) ready.complete();
    });
    await ready.future.timeout(const Duration(seconds: 10));

    final transport = createSshTransport(
      MachineProfile(
        id: 'bench',
        label: 'bench',
        host: '127.0.0.1',
        username: user,
        socketPath: sock,
      ),
      MachineSecrets(privateKeyPem: key),
      (_) {},
      (_) {},
    );
    addTearDown(transport.close);
    final api = HerdrApi(transport);

    // Warm up: connect, start the mux, JIT the paths.
    await api.ping();
    for (var i = 0; i < 3; i++) {
      await api.snapshot();
    }
    final snap = await api.snapshot();
    final paneIds = [for (final p in snap.panes) p.id];
    expect(paneIds.length, _previewPanes);
    for (var i = 0; i < 3; i++) {
      await api.readPane(paneIds[0], lines: 300, ansi: true);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final snapshots = await _measure(() async {
      for (var i = 0; i < _snapshots; i++) {
        final s = await api.snapshot();
        if (s.panes.length != _previewPanes) throw StateError('bad snapshot');
      }
    });
    final screen = await _measure(() async {
      for (var i = 0; i < _screenReads; i++) {
        final r = await api.readPane(paneIds[1], lines: 300, ansi: true);
        if (r.text.length < 60000) throw StateError('short read ${r.text.length}');
      }
    });
    final previews = await _measure(() async {
      for (var round = 0; round < _previewRounds; round++) {
        for (final id in paneIds) {
          final r = await api.readPane(id, lines: 24);
          if (r.text.isEmpty) throw StateError('empty preview');
        }
      }
    });

    double ms(_Result r) => r.cpu + r.bytes / _linkBytesPerMs;
    void phase(String name, _Result r) {
      _metric('${name}_ms', ms(r));
      _metric('${name}_kb', r.bytes / 1024);
      _metric('${name}_up_kb', r.up / 1024);
      _metric('${name}_cpu_ms', r.cpu);
      _metric('${name}_wall_ms', r.wall);
    }

    final all = [snapshots, screen, previews];
    final total = (
      cpu: all.fold(0.0, (a, r) => a + r.cpu),
      wall: all.fold(0.0, (a, r) => a + r.wall),
      bytes: all.fold(0, (a, r) => a + r.bytes),
      up: all.fold(0, (a, r) => a + r.up),
    );
    _metric('transfer_ms', ms(total));
    _metric('wire_kb', total.bytes / 1024);
    _metric('up_kb', total.up / 1024);
    _metric('cpu_ms', total.cpu);
    _metric('wall_ms', total.wall);
    phase('snapshot', snapshots);
    phase('screen', screen);
    phase('preview', previews);

    File(Platform.environment['BENCH_OUT']!).writeAsStringSync('${_out.join('\n')}\n');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
