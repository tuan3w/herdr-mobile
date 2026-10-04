import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'data/repositories/app_settings.dart';
import 'data/repositories/fleet_repository.dart';
import 'data/repositories/machine_connection.dart';
import 'data/repositories/machine_repository.dart';
import 'data/repositories/new_session_settings.dart';
import 'data/repositories/open_tabs.dart';
import 'data/repositories/pane_previews.dart';
import 'data/repositories/terminal_settings.dart';
import 'data/services/herdr_api.dart';
import 'data/services/network_monitor.dart';
import 'data/services/snapshot_cache.dart';
import 'data/services/transport_factory.dart';
import 'ui/core/theme.dart';
import 'ui/features/machines/machine_form_view_model.dart' show TransportFactory;
import 'ui/features/pane/pane_navigation.dart' show resumePaneTabs;
import 'ui/shell/home_shell.dart';

/// How the app opens a connection to a saved machine: over SSH, with the
/// credentials read from the keychain only when the transport starts.
ConnectionFactory sshConnectionFactory({
  required MachineRepository machines,
  required SnapshotCache snapshotCache,
}) =>
    (profile, secrets) {
      // The transport reports login banners; they belong to the connection it
      // serves, which only exists once the transport has been built.
      late final MachineConnection connection;
      connection = MachineConnection(
        profile: profile,
        cache: snapshotCache,
        api: HerdrApi(
          createSshTransportLater(
            profile,
            secrets,
            (fp) => machines.pinHostKey(profile.id, fp),
            (banner) => connection.onAuthNotice(banner),
          ),
        ),
      );
      return connection;
    };

class HerdrMobileApp extends StatefulWidget {
  const HerdrMobileApp({
    super.key,
    required this.machines,
    required this.network,
    required this.snapshotCache,
    required this.terminalSettings,
    required this.newSessionSettings,
    required this.appSettings,
    required this.openTabs,
    this.connect,
    this.fleet,
  });

  final MachineRepository machines;
  final NetworkMonitor network;
  final SnapshotCache snapshotCache;
  final TerminalSettings terminalSettings;
  final NewSessionSettings newSessionSettings;

  /// Already loaded, so the first frame is in the chosen theme.
  final AppSettings appSettings;

  /// The agents opened as tabs in the pane screen; already loaded, so the tabs
  /// of the last launch are back.
  final OpenTabs openTabs;

  /// Overrides how connections are built (tests); defaults to SSH.
  final ConnectionFactory? connect;

  /// A fleet that was built earlier (see `bootApp`), so its connections were
  /// already on their way before the first frame. The app takes it over and
  /// disposes it; built here, from [machines] and [network], when null.
  final FleetRepository? fleet;

  @override
  State<HerdrMobileApp> createState() => _HerdrMobileAppState();
}

class _HerdrMobileAppState extends State<HerdrMobileApp>
    with WidgetsBindingObserver {
  late final FleetRepository _fleet = widget.fleet ??
      FleetRepository(
        machines: widget.machines,
        connect: widget.connect ??
            sshConnectionFactory(
              machines: widget.machines,
              snapshotCache: widget.snapshotCache,
            ),
        network: widget.network,
      );

  /// Live terminal previews for the agent cards and pane tabs on screen.
  late final PanePreviews _previews =
      PanePreviews(changes: _fleet, connection: _fleet.connection);

  /// Built once: the shell remembers its own tab, and a theme change must not
  /// hand it a new widget. It puts the tab screen back in front when the app
  /// was left there (see [_ResumeTabs]).
  late final Widget _home = _ResumeTabs(
    openTabs: widget.openTabs,
    child: HomeShell(
      initialTab: widget.appSettings.homeTab,
      onTabChanged: (tab) => unawaited(widget.appSettings.setHomeTab(tab)),
    ),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _fleet.onLifecycleState(state);
    _previews.onLifecycleState(state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _previews.dispose();
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
          ChangeNotifierProvider.value(value: widget.appSettings),
          ChangeNotifierProvider.value(value: widget.openTabs),
          Provider<PanePreviews>.value(value: _previews),
          Provider<TransportFactory>.value(value: createSshTransport),
        ],
        child: ListenableBuilder(
          listenable: widget.appSettings,
          builder: (context, _) => MaterialApp(
            title: 'herdr',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(
              terminal: widget.appSettings.darkTerminal ? TerminalPalette.dark : null,
            ),
            darkTheme: AppTheme.dark(),
            themeMode: themeModeOf(widget.appSettings.theme),
            // A switch is instant: a cross-fade would lerp ThemeData on every
            // frame and rebuild every mounted screen with it, including the
            // hidden Agents board and a live pane.
            themeAnimationDuration: Duration.zero,
            // Lets the navigator and screens that opt in (non-secret form text,
            // the selected tab) survive Android reclaiming the process.
            restorationScopeId: 'herdr',
            // One region for every screen, including ones without an AppBar
            // (the empty state), so the bars never fall back to OEM defaults.
            // The theme here is the resolved one, so `system` follows the phone.
            builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
                  value: AppTheme.systemBars(Theme.of(context).brightness),
                  // Edge to edge draws under the bars; screens handle top and
                  // bottom themselves, but nothing else clears the side insets
                  // (landscape 3-button bar, camera cutout).
                  child: SafeArea(top: false, bottom: false, child: child!),
                ),
            home: _home,
          ),
        ),
      );
}

/// How a saved [ThemeChoice] maps onto the app's [ThemeMode].
ThemeMode themeModeOf(ThemeChoice choice) => switch (choice) {
      ThemeChoice.light => ThemeMode.light,
      ThemeChoice.dark => ThemeMode.dark,
      ThemeChoice.system => ThemeMode.system,
    };

/// Puts the tab screen back in front, once, when the app was left on it. It
/// lives inside the home route because the navigator does not exist on the
/// first frame (state restoration holds the app's children back until the
/// platform answers), so a callback registered by the app itself finds no
/// navigator to push onto.
class _ResumeTabs extends StatefulWidget {
  const _ResumeTabs({required this.openTabs, required this.child});

  final OpenTabs openTabs;
  final Widget child;

  @override
  State<_ResumeTabs> createState() => _ResumeTabsState();
}

class _ResumeTabsState extends State<_ResumeTabs> {
  @override
  void initState() {
    super.initState();
    if (widget.openTabs.takeResume()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) resumePaneTabs(Navigator.of(context));
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
