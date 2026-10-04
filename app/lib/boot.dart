import 'app.dart';
import 'data/repositories/app_settings.dart';
import 'data/repositories/fleet_repository.dart' show ConnectionFactory;
import 'data/repositories/machine_repository.dart';
import 'data/repositories/new_session_settings.dart';
import 'data/repositories/open_tabs.dart';
import 'data/repositories/terminal_settings.dart';
import 'data/services/network_monitor.dart';
import 'data/services/snapshot_cache.dart';

/// Loads what the first frame needs from the stores and builds the app around
/// it. `main` runs it before `runApp`; the arguments exist so tests and the
/// startup benchmark can run the same sequence without the platform plugins.
Future<HerdrMobileApp> bootApp({
  NetworkMonitor? network,
  SecretStore? secrets,
  SnapshotCache? snapshotCache,
  ConnectionFactory? connect,
}) async {
  final machines = MachineRepository(
    profiles: PrefsProfileStore(),
    secrets: secrets ?? KeychainSecretStore(),
  );
  await machines.load();
  // The keychain starts on every machine's secrets now, while the rest of the
  // stores load and the first frame is built; connections pick them up later.
  machines.warmSecrets();
  final terminalSettings = TerminalSettings(PrefsTerminalSettingsStore());
  await terminalSettings.load();
  final newSessionSettings = NewSessionSettings(PrefsNewSessionStore());
  await newSessionSettings.load();
  // Before runApp, so the first frame is already in the chosen theme.
  final appSettings = AppSettings(PrefsAppSettingsStore());
  await appSettings.load();
  // The tabs of the last launch, before the first frame.
  final openTabs = OpenTabs(store: PrefsOpenTabsStore());
  await openTabs.load();
  return HerdrMobileApp(
    machines: machines,
    network: network ?? ConnectivityNetworkMonitor(),
    snapshotCache: snapshotCache ?? PrefsSnapshotCache(),
    terminalSettings: terminalSettings,
    newSessionSettings: newSessionSettings,
    appSettings: appSettings,
    openTabs: openTabs,
    connect: connect,
  );
}
