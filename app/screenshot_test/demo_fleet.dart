// The demo fleet behind the store screenshots: three invented machines with
// their agents, terminals and files, wired like the app wires real ones.
//
// All names below are invented.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/repositories/new_session_settings.dart';
import 'package:herdr_mobile/data/repositories/open_tabs.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_view_model.dart' show TransportFactory;
import 'package:provider/provider.dart';

import '../test/support/fake_fs.dart';
import '../test/support/fake_network.dart';
import '../test/support/fake_transport.dart' show eventually;
import '../test/support/memory_app_settings_store.dart';
import '../test/support/memory_stores.dart';
import '../test/support/memory_terminal_settings_store.dart';
import '../test/ui/ui_harness.dart' show Pane, UiTransport, snapshotWith;
import 'demo_terminal.dart';

const studioHome = '/Users/maya';
const projectDir = '$studioHome/code/payments-api';
const chartPath = '$projectDir/docs/checkout-latency.png';

/// Pane id -> (status, minutes in that status). Panes not listed here are idle
/// from the start, for as long as the app has watched them.
const _states = {
  'a1:p1': ('blocked', 4),
  'a1:p2': ('working', 18),
  'a2:p1': ('working', 6),
  'b1:p1': ('working', 9),
  'b1:p2': ('done', 25),
  'c1:p1': ('working', 65),
  'e1:p1': ('done', 40),
};

const _titles = {
  'a1:p1': 'Approve migration for payments ledger',
  'a1:p2': 'Fix flaky retry test in checkout',
  'a2:p1': 'Upgrade Flutter and fix analyzer warnings',
  'b1:p1': 'Remove unused feature flags',
  'b1:p2': 'Rotate staging TLS certificates',
  'b1:p3': 'Triage overnight CI failures',
  'c1:p1': 'Profile training step and tune the optimizer',
  'c1:p2': 'Summarise eval results for the weekly report',
  'd1:p1': 'Verify the weekly backup integrity',
  'e1:p1': 'Calibrate the temperature sensors',
};

MachineProfile _machine(String id, String label, String host, String user,
        {SshAuth auth = SshAuth.key}) =>
    MachineProfile(id: id, label: label, host: host, username: user, auth: auth);

/// What studio-mac's file browser can reach.
FakeFs _studioFs(Uint8List chart) {
  final now = DateTime.now();
  final fs = FakeFs(home: studioHome);
  void dir(String path, Duration age) {
    fs.addDir(path);
    fs.nodes[path] = FakeNode.dir(modified: now.subtract(age));
  }

  void file(String path, int size, Duration age) =>
      fs.addFile(path, Uint8List(size), modified: now.subtract(age));

  dir('$projectDir/cmd', const Duration(days: 12));
  dir('$projectDir/db', const Duration(hours: 2));
  dir('$projectDir/db/migrations', const Duration(hours: 2));
  dir('$projectDir/docs', const Duration(minutes: 6));
  dir('$projectDir/internal', const Duration(days: 3));
  dir('$projectDir/scripts', const Duration(days: 21));
  dir('$projectDir/services', const Duration(hours: 2));
  dir('$projectDir/services/ledger', const Duration(hours: 2));
  dir('$projectDir/.git', const Duration(minutes: 40));
  dir('$projectDir/.github', const Duration(days: 30));
  file('$projectDir/README.md', 2400, const Duration(days: 9));
  file('$projectDir/Makefile', 1100, const Duration(days: 4));
  file('$projectDir/Dockerfile', 640, const Duration(days: 18));
  file('$projectDir/docker-compose.yml', 1800, const Duration(days: 18));
  file('$projectDir/go.mod', 1500, const Duration(hours: 5));
  file('$projectDir/go.sum', 61000, const Duration(hours: 5));
  file('$projectDir/.env.example', 320, const Duration(days: 40));
  file('$projectDir/.gitignore', 120, const Duration(days: 40));
  file('$projectDir/db/migrations/0041_accounts.sql', 900, const Duration(days: 8));
  file('$projectDir/db/migrations/0042_ledger.sql', 1300, const Duration(hours: 2));
  fs.addFile('$projectDir/docs/checkout-latency.png', chart, modified: now.subtract(const Duration(minutes: 6)));
  file('$projectDir/docs/architecture.md', 5200, const Duration(days: 15));
  fs.addFile(
    '$projectDir/services/ledger/repository.go',
    repositoryGo,
    modified: now.subtract(const Duration(hours: 2)),
  );
  file('$projectDir/services/ledger/repository_test.go', 4100, const Duration(hours: 2));
  file('$studioHome/code/mobile-app/lib/ui/core/chrome.dart', 9100, const Duration(minutes: 20));
  return fs;
}

/// The three demo machines on fake transports, wired like the app wires real
/// ones. Every machine has a file system, so the Files button shows.
class DemoFleet {
  DemoFleet._(this.machines, this.fleet, this.transports, this._skew)
      : previews = PanePreviews(changes: fleet, connection: fleet.connection);

  final MachineRepository machines;
  final FleetRepository fleet;
  final Map<String, UiTransport> transports;
  final _Skew _skew;

  final terminalSettings = TerminalSettings(MemoryTerminalSettingsStore());
  final appSettings = AppSettings(MemoryAppSettingsStore());
  final openTabs = OpenTabs();
  final PanePreviews previews;

  /// With [timed], every agent starts idle and [ageStatuses] moves them to
  /// their real states, so the board can say how long each has been there. The
  /// app only knows how long a state lasted if it saw it begin.
  static Future<DemoFleet> create({Uint8List? chart, bool timed = false}) async {
    String status(String id) => timed ? 'idle' : (_states[id]?.$1 ?? 'idle');
    Pane pane(String id, String ws, String agent) => (id: id, ws: ws, agent: agent, status: status(id));

    final specs = [
      (
        profile: _machine('a', 'studio-mac', 'studio-mac.tail1a2b.ts.net', 'maya', auth: SshAuth.none),
        snapshot: snapshotWith(
          [pane('a1:p1', 'a1', 'claude'), pane('a1:p2', 'a1', 'omp'), pane('a2:p1', 'a2', 'codex')],
          workspaces: const [(id: 'a1', label: 'payments-api'), (id: 'a2', label: 'mobile-app')],
          title: (id) => _titles[id] ?? '',
          cwd: (id) => id.startsWith('a1') ? projectDir : '$studioHome/code/mobile-app',
        ),
      ),
      (
        profile: _machine('b', 'build-server', '10.0.4.21', 'deploy'),
        snapshot: snapshotWith(
          [pane('b1:p1', 'b1', 'omp'), pane('b1:p2', 'b1', 'claude'), pane('b1:p3', 'b1', 'omp')],
          workspaces: const [(id: 'b1', label: 'infra')],
          title: (id) => _titles[id] ?? '',
          cwd: (_) => '/srv/infra',
        ),
      ),
      (
        profile: _machine('c', 'gpu-box', 'gpu-box.lab.local', 'maya'),
        snapshot: snapshotWith(
          [pane('c1:p1', 'c1', 'omp'), pane('c1:p2', 'c1', 'claude')],
          workspaces: const [(id: 'c1', label: 'research')],
          title: (id) => _titles[id] ?? '',
          cwd: (_) => '/home/maya/research',
        ),
      ),
      (
        profile: _machine('d', 'home-nas', 'home-nas.local', 'maya'),
        snapshot: snapshotWith(
          [pane('d1:p1', 'd1', 'claude')],
          workspaces: const [(id: 'd1', label: 'backups')],
          title: (id) => _titles[id] ?? '',
          cwd: (_) => '/volume1/backups',
        ),
      ),
      (
        profile: _machine('e', 'raspi-lab', 'raspi-lab.local', 'pi'),
        snapshot: snapshotWith(
          [pane('e1:p1', 'e1', 'omp')],
          workspaces: const [(id: 'e1', label: 'sensors')],
          title: (id) => _titles[id] ?? '',
          cwd: (_) => '/home/pi/sensors',
        ),
      ),
    ];

    final machines = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
    await machines.load();
    final skew = _Skew();
    final transports = {for (final s in specs) s.profile.id: UiTransport(s.snapshot)};
    final fleet = FleetRepository(
      machines: machines,
      network: FakeNetwork(),
      connect: (profile, secrets) => MachineConnection(
        profile: profile,
        api: HerdrApi(transports[profile.id]!),
        backoff: (_) => const Duration(hours: 1),
        clock: skew.now,
      ),
    );
    for (final s in specs) {
      await machines.save(s.profile, secrets: const MachineSecrets(password: 'x'));
    }
    await fleet.settled();

    transports['a']!
      ..fs = _studioFs(chart ?? Uint8List(0))
      ..paneTexts.addAll({
        'a1:p1': claudeMigrationSession(),
        'a1:p2': ompFlakyTestSession(),
        'a2:p1': codexFlutterSession(),
      });
    transports['b']!
      ..fs = FakeFs(home: '/home/deploy')
      ..paneTexts.addAll({
        'b1:p1': ompFlagsSession(),
        'b1:p2': claudeCertsSession(),
        'b1:p3': idleSession('Triage done: 3 failures, all in flaky e2e specs.'),
      });
    transports['c']!
      ..fs = FakeFs(home: '/home/maya')
      ..paneTexts.addAll({
        'c1:p1': ompProfileSession(),
        'c1:p2': idleSession('Summary written to reports/eval-week-41.md.'),
      });
    transports['d']!
      ..fs = FakeFs(home: '/home/maya')
      ..paneTexts['d1:p1'] = idleSession('Checked 214 archives. All checksums match.');
    transports['e']!
      ..fs = FakeFs(home: '/home/pi')
      ..paneTexts['e1:p1'] = ompSensorsSession();
    return DemoFleet._(machines, fleet, transports, skew);
  }

  /// Waits until every machine is online and listening for events.
  Future<void> online(WidgetTester tester) async {
    await tester.runAsync(
      () => eventually(() =>
          fleet.connections.every((c) => c.isLive) && transports.values.every((t) => t.subscriptions > 0)),
    );
  }

  /// Moves the agents of a [create]d `timed` fleet to their real states, each
  /// seen entering it the right number of minutes ago.
  Future<void> ageStatuses(WidgetTester tester) async {
    await online(tester);
    for (final MapEntry(key: id, value: (status, minutes)) in _states.entries) {
      final transport = transports[id.substring(0, 1)]!;
      _skew.ago = Duration(minutes: minutes);
      for (final p in transport.snapshot['panes'] as List) {
        final pane = p as Map<String, dynamic>;
        if (pane['pane_id'] == id) pane['agent_status'] = status;
      }
      transport.emit({'event': 'pane.agent_status_changed'});
      await tester.pump(const Duration(milliseconds: 350));
    }
    _skew.ago = Duration.zero;
  }

  /// Changes one agent's state now, as it would while the app is open.
  Future<void> setStatus(WidgetTester tester, String paneId, String status, {String? text}) async {
    final transport = transports[paneId.substring(0, 1)]!;
    for (final p in transport.snapshot['panes'] as List) {
      final pane = p as Map<String, dynamic>;
      if (pane['pane_id'] == paneId) pane['agent_status'] = status;
    }
    if (text != null) transport.paneTexts[paneId] = text;
    transport.emit({'event': 'pane.agent_status_changed'});
    await tester.pump(const Duration(milliseconds: 350));
  }

  void dispose() {
    previews.dispose();
    openTabs.dispose();
    fleet.dispose();
  }
}

/// A clock that can run behind by [ago]: the app stamps "entered this state at"
/// with it.
class _Skew {
  Duration ago = Duration.zero;
  DateTime now() => DateTime.now().subtract(ago);
}

/// The providers the app shell and its screens read, around [app].
Widget Function(Widget) demoProviders(
  DemoFleet h, {
  TransportFactory? factory,
  NewSessionSettings? newSession,
}) =>
    (app) => MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: h.machines),
            ChangeNotifierProvider.value(value: h.fleet),
            ChangeNotifierProvider.value(value: h.terminalSettings),
            ChangeNotifierProvider.value(value: h.appSettings),
            ChangeNotifierProvider.value(value: h.openTabs),
            Provider<PanePreviews>.value(value: h.previews),
            if (newSession != null) ChangeNotifierProvider.value(value: newSession),
            Provider<TransportFactory>.value(
              value: factory ?? (profile, secrets, onPin, onNotice) => UiTransport(snapshotWith(const [])),
            ),
          ],
          child: app,
        );
