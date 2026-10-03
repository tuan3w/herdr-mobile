import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'data/models/machine_profile.dart';
import 'data/repositories/fleet_repository.dart';
import 'data/repositories/machine_connection.dart';
import 'data/repositories/machine_repository.dart';
import 'data/services/herdr_api.dart';
import 'data/services/network_monitor.dart';
import 'data/services/snapshot_cache.dart';
import 'data/services/ssh_transport.dart';
import 'ui/core/theme.dart';
import 'ui/shell/home_shell.dart';

class HerdrMobileApp extends StatefulWidget {
  const HerdrMobileApp({
    super.key,
    required this.machines,
    required this.network,
    required this.snapshotCache,
    this.connect,
  });

  final MachineRepository machines;
  final NetworkMonitor network;
  final SnapshotCache snapshotCache;

  /// Overrides how connections are built (tests); defaults to SSH.
  final ConnectionFactory? connect;

  @override
  State<HerdrMobileApp> createState() => _HerdrMobileAppState();
}

class _HerdrMobileAppState extends State<HerdrMobileApp>
    with WidgetsBindingObserver {
  late final FleetRepository _fleet = FleetRepository(
    machines: widget.machines,
    connect: widget.connect ?? _sshConnection,
    network: widget.network,
  );

  MachineConnection _sshConnection(MachineProfile profile, MachineSecrets secrets) =>
      MachineConnection(
        profile: profile,
        cache: widget.snapshotCache,
        api: HerdrApi(
          SshTransport(
            profile: profile,
            secrets: secrets,
            onPinHostKey: (fp) => widget.machines.pinHostKey(profile.id, fp),
          ),
        ),
      );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _fleet.onLifecycleState(state);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fleet.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: widget.machines),
          ChangeNotifierProvider.value(value: _fleet),
        ],
        child: MaterialApp(
          title: 'herdr',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: ThemeMode.system,
          home: const HomeShell(),
        ),
      );
}
