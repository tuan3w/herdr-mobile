import 'package:flutter/material.dart';

import 'app.dart';
import 'data/repositories/machine_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final machines = MachineRepository(
    profiles: PrefsProfileStore(),
    secrets: KeychainSecretStore(),
  );
  await machines.load();
  runApp(HerdrMobileApp(machines: machines));
}
