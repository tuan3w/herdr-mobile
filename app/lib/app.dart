import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'data/repositories/agent_screens.dart';
import 'data/repositories/app_settings.dart';
import 'data/repositories/agent_session.dart' show AgentSessions;
import 'data/repositories/agent_session_repository.dart';
import 'data/repositories/agent_session_settings.dart';
import 'data/repositories/attention_notifier.dart';
import 'data/repositories/attention_set.dart';
import 'data/repositories/fleet_repository.dart';
import 'data/repositories/last_seen.dart';
import 'data/repositories/machine_connection.dart';
import 'data/repositories/machine_repository.dart';
import 'data/repositories/notification_settings.dart';
import 'data/repositories/pane_previews.dart';
import 'data/repositories/quick_phrases.dart';
import 'data/repositories/sent_phrases.dart';
import 'data/services/dictation.dart';
import 'data/repositories/slash_usage.dart';
import 'data/repositories/observed_sessions.dart';
import 'data/repositories/terminal_settings.dart';
import 'data/services/herdr_api.dart';
import 'data/repositories/host_inbox.dart' show InboxJanitor, PrefsInboxCleanupLog;
import 'data/services/network_monitor.dart';
import 'data/services/notifier.dart';
import 'data/services/snapshot_cache.dart';
import 'data/services/task_mover.dart';
import 'data/services/transport_factory.dart';
import 'ui/core/deep_link.dart';
import 'ui/core/home_tabs.dart';
import 'ui/core/keyboard_frames.dart';
import 'ui/core/theme.dart';
import 'ui/core/toast.dart' show ToastRouteObserver;
import 'ui/features/agents/agent_navigation.dart' show openAgentFromLink, resumeAgent;
import 'ui/features/machines/machine_form_view_model.dart' show TransportFactory;
import 'ui/shell/home_shell.dart';

/// How the app opens a connection to a saved machine: over SSH, with the
/// credentials read from the keychain only when the transport starts.
ConnectionFactory sshConnectionFactory({
  required MachineRepository machines,
  required SnapshotCache snapshotCache,
}) {
  // Sweeps old phone uploads from each host's inbox once a day, in the
  // background, the first time that host is online in a run.
  final inboxJanitor = InboxJanitor(PrefsInboxCleanupLog());
  return (profile, secrets) {
    // The transport reports login banners; they belong to the connection it
    // serves, which only exists once the transport has been built.
    late final MachineConnection connection;
    connection = MachineConnection(
      profile: profile,
      cache: snapshotCache,
      api: HerdrApi(
        createSshTransportLater(
          // Asked at each worker start: a replaced worker gets the pin made since.
          () => machines.byId(profile.id) ?? profile,
          secrets,
          (fp) => machines.pinHostKey(profile.id, fp),
          (banner) => connection.onAuthNotice(banner),
        ),
      ),
    );
    inboxJanitor.watch(connection);
    return connection;
  };
}

class HerdrMobileApp extends StatefulWidget {
  const HerdrMobileApp({
    super.key,
    required this.machines,
    required this.network,
    required this.snapshotCache,
    required this.terminalSettings,
    required this.appSettings,
    required this.agentScreens,
    this.lastSeen,
    this.connect,
    this.slashUsage,
    this.quickPhrases,
    this.dictation,
    this.sentPhrases,
    this.fleet,
    this.agentSessions,
    this.agentSessionSettings,
    this.notificationSettings,
    this.notifier,
    this.attention,
    this.attentionSet,
    this.previews,
    this.observedSessions,
  });

  final MachineRepository machines;
  final NetworkMonitor network;
  final SnapshotCache snapshotCache;
  final TerminalSettings terminalSettings;

  /// Agent sessions (ACP) over the machines' SSH connections; null in tests
  /// that build their connections themselves (no host to run keepers on). The
  /// app takes it over and disposes it, before the fleet it reads.
  final AgentSessionRepository? agentSessions;

  /// The agent session form's last machine, agent and folder.
  final AgentSessionSettings? agentSessionSettings;

  /// Whether (and which) local notifications the person wants; already loaded.
  /// An in-memory default (off) when null, for tests.
  final NotificationSettings? notificationSettings;

  /// Posts the notifications and answers taps on them; [NullNotifier] when
  /// null. The Settings switch asks it for the permission.
  final Notifier? notifier;

  /// Decides when to notify and clear (see `bootApp`); null in tests. The app
  /// takes it over and disposes it, before the sessions and fleet it reads.
  final AttentionNotifier? attention;

  /// What needs the person, one set for every surface (see [AttentionSet]);
  /// built here from the fleet and [agentSessions] when null. The app takes
  /// it over and disposes it, after the notifier that reads it.
  final AttentionSet? attentionSet;

  /// What the slash palette remembers per agent; panes work without it (tests).
  final SlashUsage? slashUsage;

  /// The one-tap phrases above the composers; the chips are absent without it (tests).
  final QuickPhrases? quickPhrases;

  /// What the person sends most, offered beside the quick phrases; absent without it (tests).
  final SentPhrases? sentPhrases;

  /// Dictation into the message boxes; absent without a speech service (tests).
  final Dictation? dictation;

  /// Already loaded, so the first frame is in the chosen theme.
  final AppSettings appSettings;

  /// The agent screen in front and, for the app run, each agent's view and
  /// draft; already loaded, so the screen the app was left on comes back.
  final AgentScreens agentScreens;

  /// Where the person left each agent session ([LastSeen], already loaded);
  /// the session screen reads it and marks it. Null in tests that do not
  /// care: the session screen then remembers nothing.
  final LastSeen? lastSeen;

  /// Overrides how connections are built (tests); defaults to SSH.
  final ConnectionFactory? connect;

  /// A fleet that was built earlier (see `bootApp`), so its connections were
  /// already on their way before the first frame. The app takes it over and
  /// disposes it; built here, from [machines] and [network], when null.
  final FleetRepository? fleet;

  /// Live previews built earlier (see `bootApp`), shared with the observed
  /// sessions; the app takes them over and disposes them. Built here when null.
  final PanePreviews? previews;

  /// Agents that run in a pane, followed through their own log (null in tests
  /// that have no host to read logs from). The app takes it over and disposes
  /// it, before the previews and fleet it reads.
  final ObservedSessions? observedSessions;

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
        screens: widget.agentScreens,
      );

  /// Live terminal previews for the agent cards and the answer dock.
  late final PanePreviews _previews =
      widget.previews ?? PanePreviews(changes: _fleet, connection: _fleet.connection);

  /// What needs the person and what is to review, computed once per change
  /// for the badge, the board, the triage, the Machines tab and the cue.
  late final AttentionSet _attentionSet =
      widget.attentionSet ?? AttentionSet(fleet: _fleet, sessions: widget.agentSessions);

  /// Lets a toast step aside for a sheet or dialog.
  final _toastRoutes = ToastRouteObserver();

  /// Turns the home screen to a root tab from outside it (a link, a toast).
  final _tabs = HomeTabs();

  /// Follows `herdr://agent/...` links (alert taps), at launch and while running.
  late final DeepLinks _links = DeepLinks(
    machines: widget.machines,
    fleet: _fleet,
    tabs: _tabs,
    open: openAgentFromLink,
    sessions: widget.agentSessions,
  );

  late final NotificationSettings _notificationSettings =
      widget.notificationSettings ?? NotificationSettings(MemoryNotificationStore());

  late final Notifier _notifier = widget.notifier ?? const NullNotifier();

  /// Built once: the shell remembers its own tab, and a theme change must not
  /// hand it a new widget. It puts the agent screen the app was left on back
  /// in front (see [_ResumeAgent]).
  late final Widget _home = _ResumeAgent(
    screens: widget.agentScreens,
    child: HomeShell(
      initialTab: widget.appSettings.homeTab,
      onTabChanged: (tab) => unawaited(widget.appSettings.setHomeTab(tab)),
      moveToBackground: const PlatformTaskMover().moveToBack,
      tabs: _tabs,
    ),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _links.attach();
    _fleet.addListener(_syncObserved);
    // A tap that launched the app is delivered while the handler is being set:
    // that one is a cold start, the screens may still be settling.
    var registering = true;
    _notifier.onOpen((link) => unawaited(_links.follow(link, cold: registering)));
    registering = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _fleet.onLifecycleState(state);
    _previews.onLifecycleState(state);
    widget.observedSessions?.onLifecycleState(state);
    widget.agentSessions?.onLifecycleState(state);
    widget.attention?.onLifecycleState(state);
  }

  /// Observed sessions stay attached in the background exactly when the
  /// connections do (the person asked to be told about agents).
  void _syncObserved() => widget.observedSessions?.keepAliveInBackground = _fleet.keepAliveInBackground;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _links.dispose();
    _fleet.removeListener(_syncObserved);
    widget.observedSessions?.dispose();
    _previews.dispose();
    // The notifier reads the attention set, the fleet and the sessions: it
    // goes first, then the set.
    unawaited(widget.attention?.dispose());
    _attentionSet.dispose();
    widget.agentSessions?.dispose();
    _fleet.dispose();
    if (widget.notificationSettings == null) _notificationSettings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: widget.machines),
          ChangeNotifierProvider.value(value: _fleet),
          ChangeNotifierProvider.value(value: widget.terminalSettings),
          if (widget.slashUsage case final usage?) ChangeNotifierProvider.value(value: usage),
          if (widget.quickPhrases case final phrases?) ChangeNotifierProvider.value(value: phrases),
          if (widget.dictation case final dictation?) ChangeNotifierProvider.value(value: dictation),
          if (widget.sentPhrases case final sent?) ChangeNotifierProvider.value(value: sent),
          ChangeNotifierProvider.value(value: widget.appSettings),
          ChangeNotifierProvider.value(value: widget.agentScreens),
          if (widget.lastSeen case final seen?) Provider<LastSeen>.value(value: seen),
          Provider<PanePreviews>.value(value: _previews),
          if (widget.observedSessions case final observed?) Provider<ObservedSessions>.value(value: observed),
          Provider<TransportFactory>.value(value: createSshTransport),
          if (widget.agentSessions case final sessions?) ListenableProvider<AgentSessions>.value(value: sessions),
          ChangeNotifierProvider.value(value: _attentionSet),
          if (widget.agentSessionSettings case final settings?) ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: _notificationSettings),
          Provider<Notifier>.value(value: _notifier),
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
                  child: KeyboardFrames(
                    child: SafeArea(top: false, bottom: false, child: child!),
                  ),
                ),
            navigatorKey: _links.navigatorKey,
            navigatorObservers: [_toastRoutes],
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

/// Puts the agent screen the app was left on back in front, once (see
/// [resumeAgent]). It lives inside the home route because the navigator does
/// not exist on the first frame (state restoration holds the app's children
/// back until the platform answers), so a callback registered by the app
/// itself finds no navigator to push onto.
class _ResumeAgent extends StatefulWidget {
  const _ResumeAgent({required this.screens, required this.child});

  final AgentScreens screens;
  final Widget child;

  @override
  State<_ResumeAgent> createState() => _ResumeAgentState();
}

class _ResumeAgentState extends State<_ResumeAgent> {
  @override
  void initState() {
    super.initState();
    if (widget.screens.takeResume() case final front?) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(resumeAgent(Navigator.of(context), front));
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
