// ignore_for_file: invalid_use_of_visible_for_testing_member
//
// Deterministic benchmark of what the app's own code does between process
// start and a populated board, run by `autoresearch.sh`:
//
//   flutter test benchmark/startup_bench.dart
//
// It runs the real `bootApp` (the stores, the loads, the repositories) over
// seeded preferences: six machines, each with a cached snapshot of 40 panes,
// and saved tabs. Then it mounts the app and pumps until every machine's
// cached agents are on the Agents board (the network never answers: a cold
// start on a slow link).
//
// TIME IS VIRTUAL. CPU work is real and measured (a pump takes as long as it
// takes), and the clock the app sees advances by that much, so code that waits
// while other code runs overlaps as it would on a phone. Platform plugins are
// modelled: the keychain lives on one worker thread, where the first read pays
// for the cipher set-up and later ones are cheap (see [_Keychain]). THE
// CONSTANTS ARE ASSUMPTIONS, not measurements of any phone; what the
// benchmark checks is the structure (what waits for what), so a change must
// win across plausible values. Ground truth is `adb shell am start -W` and
// logcat "Fully drawn" on a device.
//
// What it cannot see at all: engine and Dart VM start, the preferences first
// load, fonts and shaders.
//
// Results go to the file named by $BENCH_OUT (METRIC lines), because
// `flutter test` decorates stdout.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:herdr_mobile/app.dart' show HerdrMobileApp;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/boot.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/snapshot_cache.dart';
import 'package:herdr_mobile/ui/features/agents/agent_card.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/support/fake_network.dart';
import '../test/support/fake_transport.dart';
import '../test/support/shot.dart' show loadAppFonts;

const _machines = 6;
const _workspaces = 8;
const _panesPerWorkspace = 5;
const _runs = 15;
const _discard = 3; // JIT warm-up: the first runs are not what a phone does

// Modelled platform latencies (assumptions, see the header).
const _keychainFirstRead = Duration(milliseconds: 40); // cipher set-up
const _keychainRead = Duration(milliseconds: 2); // each read after it

final _out = <String>[];

void _metric(String name, num value) =>
    _out.add('METRIC $name=${value is int ? value : value.toStringAsFixed(3)}');

double _median(List<double> v) {
  final s = [...v]..sort();
  return s[s.length ~/ 2];
}

/// A machine's snapshot as herdr would give it: [_workspaces] workspaces of
/// [_panesPerWorkspace] panes, most running an agent in some state.
Map<String, dynamic> _snapshot(int machine) {
  final rng = math.Random(machine * 31 + 7);
  const statuses = ['working', 'idle', 'blocked', 'done', 'idle', 'working'];
  final panes = <({String id, String ws, String? agent, String status})>[
    for (var w = 0; w < _workspaces; w++)
      for (var p = 0; p < _panesPerWorkspace; p++)
        (
          id: 'm$machine-w$w-p$p',
          ws: 'm$machine-w$w',
          agent: rng.nextInt(5) == 0 ? null : (rng.nextBool() ? 'claude' : 'codex'),
          status: statuses[rng.nextInt(statuses.length)],
        ),
  ];
  return snapshotJson(
    workspaces: [
      for (var w = 0; w < _workspaces; w++)
        (id: 'm$machine-w$w', label: 'project-$machine-$w'),
    ],
    panes: panes,
  );
}

/// Answers nothing: the first paint has to come from the cache.
class _SilentTransport extends FakeTransport {
  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) => Completer<Map<String, dynamic>>().future;
}

/// The platform keychain: one worker thread, so reads queue behind each other;
/// the first pays for the cipher set-up. Answers come after virtual time.
class _Keychain implements SecretStore {
  Future<void> _tail = Future.value();
  var _warm = false;
  int reads = 0;

  Future<T> _onWorker<T>(T value) {
    final cost = _warm ? _keychainRead : _keychainFirstRead;
    _warm = true;
    reads++;
    final done = _tail.then((_) => Future<void>.delayed(cost));
    _tail = done;
    return done.then((_) => value);
  }

  @override
  Future<MachineSecrets> read(String id) async {
    // As KeychainSecretStore does: key, passphrase, password.
    final key = await _onWorker<String?>(null);
    final passphrase = await _onWorker<String?>(null);
    final password = await _onWorker<String?>('x');
    return MachineSecrets(
      privateKeyPem: key,
      passphrase: passphrase,
      password: password,
    );
  }

  @override
  Future<void> write(String id, MachineSecrets secrets) async {}

  @override
  Future<void> delete(String id) async {}
}

({Map<String, Object> values, int agents}) _seed() {
  final profiles = [
    for (var m = 0; m < _machines; m++)
      {
        'id': 'm$m',
        'label': 'machine $m',
        'host': 'host$m.example',
        'port': 22,
        'username': 'fatman',
        'auth': 'password',
        'session': 'default',
        'enabled': true,
      },
  ];
  var bytes = 0;
  var agents = 0;
  final values = <String, Object>{'machines.v1': jsonEncode(profiles)};
  for (var m = 0; m < _machines; m++) {
    final snapshot = Snapshot.fromJson(_snapshot(m));
    agents += snapshot.agentPanes.length;
    final raw = jsonEncode(snapshot.toJson());
    bytes += raw.length;
    values['herdr.snapshot.v1.m$m'] = raw;
  }
  values['openTabs.v1'] = jsonEncode({
    'v': 1,
    'tabs': [
      ['m0', 'm0-w0-p0'],
      ['m1', 'm1-w1-p1'],
      ['m2', 'm2-w2-p2'],
    ],
    'active': 'm1-w1-p1',
    'host': false,
  });
  values['app.homeTab'] = 0;
  _metric('seed_snapshot_kb', bytes / 1024);
  return (values: values, agents: agents);
}

void main() {
  final outPath = Platform.environment['BENCH_OUT'];

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadAppFonts();
  });

  tearDownAll(() {
    final text = '${_out.join('\n')}\n';
    if (outPath != null) {
      File(outPath).writeAsStringSync(text);
    } else {
      stdout.write(text);
    }
  });

  testWidgets('cold start to a populated board', semanticsEnabled: false, (tester) async {
    tester.view
      ..physicalSize = const Size(392 * 2.75, 760 * 2.75)
      ..devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final seed = _seed();

    final total = <double>[];
    final firstCard = <double>[];
    final booted = <double>[];
    final cpu = <double>[];
    final firstFrame = <double>[];
    final worst = <double>[];
    var keychainReads = 0;

    for (var run = 0; run < _runs; run++) {
      // A clean process: nothing of the previous run is left in the tree or in
      // the preferences cache.
      await tester.pumpWidget(const SizedBox());
      SharedPreferences.resetStatic();
      SharedPreferences.setMockInitialValues(Map<String, Object>.of(seed.values));

      var virtualUs = 0; // the clock the app sees
      var cpuUs = 0; // work actually done
      var slowest = 0;
      final watch = Stopwatch();

      /// Lets [step] of virtual time pass (at least as long as the last thing
      /// took), running whatever is due.
      Future<void> pump(int stepUs) async {
        watch
          ..reset()
          ..start();
        await tester.pump(Duration(microseconds: stepUs));
        watch.stop();
        virtualUs += stepUs;
        cpuUs += watch.elapsedMicroseconds;
        slowest = math.max(slowest, watch.elapsedMicroseconds);
      }

      final keychain = _Keychain();
      final cache = PrefsSnapshotCache();
      HerdrMobileApp? app;
      unawaited(
        bootApp(
          network: FakeNetwork(),
          secrets: keychain,
          snapshotCache: cache,
          connect: (profile, secrets) => MachineConnection(
            profile: profile,
            cache: cache,
            api: HerdrApi(_SilentTransport()),
            backoff: (_) => const Duration(hours: 1),
            pollInterval: const Duration(hours: 1),
          ),
        ).then((a) => app = a),
      );

      var step = 1000;
      while (app == null) {
        await pump(step);
      }
      final bootUs = virtualUs;

      // main() hands the booted app to runApp: the first frame.
      watch
        ..reset()
        ..start();
      await tester.pumpWidget(app!);
      watch.stop();
      virtualUs += watch.elapsedMicroseconds;
      cpuUs += watch.elapsedMicroseconds;
      slowest = math.max(slowest, watch.elapsedMicroseconds);
      final firstFrameUs = watch.elapsedMicroseconds;

      FleetRepository fleet() => Provider.of<FleetRepository>(
            tester.element(find.byType(Scaffold).first),
            listen: false,
          );
      bool cards() =>
          find.byType(AgentCard).evaluate().isNotEmpty ||
          find.byType(AgentCompactRow).evaluate().isNotEmpty;

      int? firstCardUs;
      var guard = 0;
      while (fleet().agents.length < seed.agents && guard++ < 4000) {
        step = math.max(1000, watch.elapsedMicroseconds);
        await pump(step);
        if (firstCardUs == null && cards()) firstCardUs = virtualUs;
      }
      expect(fleet().agents.length, seed.agents, reason: 'run $run: not all agents arrived');
      // One more frame so the last machine's cards are painted, not just known.
      await pump(16000);
      expect(cards(), isTrue, reason: 'run $run: no cards painted');
      firstCardUs ??= virtualUs;
      keychainReads = keychain.reads;

      if (run < _discard) continue;
      total.add(virtualUs / 1000);
      firstCard.add(firstCardUs / 1000);
      booted.add(bootUs / 1000);
      cpu.add(cpuUs / 1000);
      firstFrame.add(firstFrameUs / 1000);
      worst.add(slowest / 1000);
    }

    _metric('startup_total_ms', _median(total));
    _metric('first_card_ms', _median(firstCard));
    _metric('boot_ms', _median(booted));
    _metric('first_frame_cpu_ms', _median(firstFrame));
    _metric('cpu_total_ms', _median(cpu));
    _metric('worst_frame_ms', _median(worst));
    _metric('keychain_reads', keychainReads);
  });
}
