import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'data/models/machine_profile.dart';
import 'data/repositories/fleet_repository.dart';
import 'data/repositories/machine_connection.dart';
import 'data/repositories/machine_repository.dart';
import 'data/repositories/new_session_settings.dart';
import 'data/repositories/terminal_settings.dart';
import 'data/services/herdr_api.dart';
import 'data/services/network_monitor.dart';
import 'data/services/snapshot_cache.dart';
import 'data/services/transport_factory.dart';
import 'ui/core/theme.dart';
import 'ui/features/machines/machine_form_view_model.dart' show TransportFactory;
import 'ui/shell/home_shell.dart';

class HerdrMobileApp extends StatefulWidget {
  const HerdrMobileApp({
    super.key,
    required this.machines,
    required this.network,
    required this.snapshotCache,
    required this.terminalSettings,
    required this.newSessionSettings,
    this.connect,
  });

  final MachineRepository machines;
  final NetworkMonitor network;
  final SnapshotCache snapshotCache;
  final TerminalSettings terminalSettings;
  final NewSessionSettings newSessionSettings;

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

  MachineConnection _sshConnection(MachineProfile profile, MachineSecrets secrets) {
    // The transport reports login banners; they belong to the connection it
    // serves, which only exists once the transport has been built.
    late final MachineConnection connection;
    connection = MachineConnection(
      profile: profile,
      cache: widget.snapshotCache,
      api: HerdrApi(
        createSshTransport(
          profile,
          secrets,
          (fp) => widget.machines.pinHostKey(profile.id, fp),
          (banner) => connection.onAuthNotice(banner),
        ),
      ),
    );
    return connection;
  }

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
          ChangeNotifierProvider.value(value: widget.terminalSettings),
          ChangeNotifierProvider.value(value: widget.newSessionSettings),
          Provider<TransportFactory>.value(value: createSshTransport),
        ],
        child: MaterialApp(
          title: 'herdr',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: ThemeMode.system,
          // Lets the navigator and screens that opt in (non-secret form text,
          // the selected tab) survive Android reclaiming the process.
          restorationScopeId: 'herdr',
          // One region for every screen, including ones without an AppBar
          // (the empty state), so the bars never fall back to OEM defaults.
          builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
                value: AppTheme.systemBars(Theme.of(context).brightness),
                // Edge to edge draws under the bars; screens handle top and
                // bottom themselves, but nothing else clears the side insets
                // (landscape 3-button bar, camera cutout).
                child: SafeArea(top: false, bottom: false, child: child!),
              ),
          home: const HomeShell(),
        ),
      );
}
