// A page from a machine held open keeps that machine's connection, and
// nothing more: the agents' session logs (observed sessions) follow only the
// notifier's choice, as wired in the app (`app.dart`, `watchingAgents`).
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/app.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/observed/claude_kind.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/repositories/observed_sessions.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import '../support/fake_log_source.dart';
import '../support/fake_network.dart';
import '../support/fake_transport.dart';
import '../support/memory_app_settings_store.dart';
import '../support/memory_snapshot_cache.dart';
import '../support/memory_stores.dart';
import '../support/memory_terminal_settings_store.dart';

void main() {
  testWidgets('a page held open with its notice up keeps the connection, not the observed sessions', (tester) async {
    final machines = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
    await machines.load();
    await machines.save(
      const MachineProfile(id: 'm', label: 'build-box', host: 'h', username: 'u'),
      secrets: const MachineSecrets(password: 'x'),
    );
    final network = FakeNetwork();
    final screens = AgentScreens();
    addTearDown(screens.dispose);
    final fleet = FleetRepository(
      machines: machines,
      network: network,
      screens: screens,
      connect: (profile, secrets) => MachineConnection(
        profile: profile,
        api: HerdrApi(FakeTransport()),
        backoff: (_) => const Duration(hours: 1),
        pollInterval: const Duration(hours: 1),
      ),
    );
    await fleet.settled();
    final previews = PanePreviews(changes: fleet, connection: fleet.connection);
    final observed = ObservedSessions(
      fleet: fleet,
      previews: previews,
      sourceFor: (_) => FakeLogSource(),
      kinds: {'claude': claudeKind},
    );
    final app = AppSettings(MemoryAppSettingsStore());
    await app.load();
    await tester.pumpWidget(
      HerdrMobileApp(
        machines: machines,
        network: network,
        snapshotCache: MemorySnapshotCache(),
        terminalSettings: TerminalSettings(MemoryTerminalSettingsStore()),
        appSettings: app,
        agentScreens: screens,
        fleet: fleet,
        previews: previews,
        observedSessions: observed,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    // A debug build keeps the provider type check on, so starting the app with
    // observed sessions must not trip it.
    expect(tester.takeException(), isNull);

    final release = fleet.holdAlive('m', page: 'localhost:3000 on build-box');
    fleet.pageNotice = true;
    await tester.pump();
    expect(fleet.keeps('m'), isTrue);
    expect(observed.keepAliveInBackground, isFalse, reason: 'a page needs the connection, not the agents\' logs');

    fleet.keepAliveInBackground = true; // the notifier watches agents
    await tester.pump();
    expect(observed.keepAliveInBackground, isTrue);

    fleet.keepAliveInBackground = false;
    release();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));
  });
}
