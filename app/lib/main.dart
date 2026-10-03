import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'data/repositories/app_settings.dart';
import 'data/repositories/machine_repository.dart';
import 'data/repositories/open_tabs.dart';
import 'data/repositories/new_session_settings.dart';
import 'data/repositories/terminal_settings.dart';
import 'data/services/network_monitor.dart';
import 'data/services/snapshot_cache.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final machines = MachineRepository(
    profiles: PrefsProfileStore(),
    secrets: KeychainSecretStore(),
  );
  await machines.load();
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
  runApp(HerdrMobileApp(
    machines: machines,
    network: ConnectivityNetworkMonitor(),
    snapshotCache: PrefsSnapshotCache(),
    terminalSettings: terminalSettings,
    newSessionSettings: newSessionSettings,
    appSettings: appSettings,
    openTabs: openTabs,
  ));
}
