import 'package:flutter/material.dart';

import 'app.dart';
import 'data/repositories/machine_repository.dart';
import 'data/services/network_monitor.dart';
import 'data/services/snapshot_cache.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final machines = MachineRepository(
    profiles: PrefsProfileStore(),
    secrets: KeychainSecretStore(),
  );
  await machines.load();
  runApp(HerdrMobileApp(
    machines: machines,
    network: ConnectivityNetworkMonitor(),
    snapshotCache: PrefsSnapshotCache(),
  ));
}
