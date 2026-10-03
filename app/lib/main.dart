import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'data/repositories/machine_repository.dart';
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
  runApp(HerdrMobileApp(
    machines: machines,
    network: ConnectivityNetworkMonitor(),
    snapshotCache: PrefsSnapshotCache(),
    terminalSettings: terminalSettings,
    newSessionSettings: newSessionSettings,
  ));
}
