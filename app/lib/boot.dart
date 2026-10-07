import 'package:flutter/services.dart';

import 'app.dart';
import 'data/repositories/agent_screens.dart';
import 'data/repositories/agent_session_repository.dart';
import 'data/repositories/agent_session_settings.dart';
import 'data/repositories/app_settings.dart';
import 'data/repositories/attention_notifier.dart';
import 'data/repositories/attention_set.dart';
import 'data/repositories/fleet_repository.dart';
import 'data/repositories/last_seen.dart';
import 'data/repositories/machine_repository.dart';
import 'data/repositories/notification_settings.dart';
import 'data/repositories/reviewed_state.dart';
import 'data/repositories/slash_usage.dart';
import 'data/repositories/quick_phrases.dart';
import 'data/repositories/sent_phrases.dart';
import 'data/services/dictation.dart';
import 'data/repositories/terminal_settings.dart';
import 'data/repositories/observed_sessions.dart';
import 'data/repositories/pane_answerer.dart';
import 'data/repositories/pane_previews.dart';
import 'data/observed/omp_log_mapper.dart';
import 'data/services/local_notifier.dart';
import 'data/services/network_monitor.dart';
import 'data/services/notifier.dart';
import 'data/services/snapshot_cache.dart';
import 'data/services/ssh_agent_host.dart';
import 'data/services/ssh_log_source.dart';
import 'data/services/transcript_cache.dart';
import 'ui/core/frame_flush.dart';
import 'ui/core/tokens.dart' show Ds;
import 'ui/features/agent_session/visible_text.dart' show visibleText;
import 'data/services/system_clipboard.dart';

/// How the app sits under the system bars. `main` and the keyboard benchmark
/// both call it, so the benchmark measures the window the app really has.
Future<void> configureSystemUi() =>
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

/// Loads what the first frame needs from the stores and builds the app around
/// it. `main` runs it before `runApp`; the arguments exist so tests and the
/// startup benchmark can run the same sequence without the platform plugins.
Future<HerdrMobileApp> bootApp({
  NetworkMonitor? network,
  SecretStore? secrets,
  SnapshotCache? snapshotCache,
  TranscriptCache? transcriptCache,
  ConnectionFactory? connect,
  Notifier? notifier,
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
  final slashUsage = SlashUsage(PrefsSlashUsageStore());
  await slashUsage.load();
  final quickPhrases = QuickPhrases(PrefsQuickPhrasesStore());
  await quickPhrases.load();
  final sentPhrases = SentPhrases(PrefsSentPhrasesStore());
  await sentPhrases.load();
  // Which language dictation listens in; the microphone is asked for on the
  // first tap of the mic, not here.
  final dictation = Dictation(PluginSpeechEngine(), PrefsDictationStore());
  await dictation.load();
  // Whether the system confirms a copy itself (Android 13+): the app then does
  // not say `Copied` a second time.
  await SystemClipboard.detect();
  // Before runApp, so the first frame is already in the chosen theme.
  final appSettings = AppSettings(PrefsAppSettingsStore());
  await appSettings.load();
  final agentSessionSettings = AgentSessionSettings(PrefsAgentSessionStore());
  await agentSessionSettings.load();
  // The agent screen the app was left on, before the first frame (the old
  // tabs' screen is carried over once).
  final agentScreens = AgentScreens(PrefsAgentScreensStore());
  await agentScreens.load();
  // Which finished agents were looked at, before the first frame: a reviewed
  // agent must not flash as Done while the board draws.
  final reviewed = ReviewedState(PrefsReviewedStore());
  await reviewed.load();
  // Where the person left each agent session, before the first frame: the
  // first session screen already knows what happened since.
  final lastSeen = LastSeen(PrefsLastSeenStore());
  await lastSeen.load();
  // Whether the person wants notifications, before the first frame: the
  // Settings switch and the first lifecycle change already depend on it.
  final notificationSettings = NotificationSettings(PrefsNotificationStore());
  await notificationSettings.load();
  // Fast, and never throws: a platform without notifications gets a no-op.
  final notify = notifier ?? await LocalNotifier.start(accent: Ds.paper.accent);
  final monitor = network ?? ConnectivityNetworkMonitor();
  final cache = snapshotCache ?? PrefsSnapshotCache();
  // The connections are made now, not when the first frame builds the app:
  // each one starts reading its cached snapshot and its transport starts
  // (worker isolate, SSH handshake) while that frame is being built.
  final fleet = FleetRepository(
    machines: machines,
    connect: connect ?? sshConnectionFactory(machines: machines, snapshotCache: cache),
    network: monitor,
    reviewed: reviewed,
    screens: agentScreens,
  );
  final previews = PanePreviews(changes: fleet, connection: fleet.connection);
  // Agent sessions (ACP) ride the same SSH connections, through keepers on the
  // hosts. A test connection factory has no host to run them on.
  final agentSessions = connect != null
      ? null
      : AgentSessionRepository(
          fleet: fleet,
          hostFor: (machine) => SshAgentHost(machine.api.transport),
          // Sessions notify at the start of the next frame, before build.
          flush: FrameFlush(),
          // What each session said last, in private files: a thread opens on
          // it at once, also after a restart (the directory is looked up on
          // first use, not here).
          cache: transcriptCache ?? FileTranscriptCache.inAppStorage(),
          // The board's one short `list` per machine (30 s while the Agents
          // tab is visible) is how it learns phases; only a few sessions hold
          // a channel (see AgentSessionRepository).
        );
  // Agents that run in a pane are followed through their own session log
  // (omp first), over the same connections.
  final observedSessions = connect != null
      ? null
      : ObservedSessions(
          fleet: fleet,
          previews: previews,
          sourceFor: (machine) => SshLogSource(SshAgentHost(machine.api.transport)),
          mappers: {'omp': OmpLogMapper.new},
        );
  // What needs the person, computed once per change of the fleet or the
  // sessions: built before the notifier, so it is current when that reads it.
  final attentionSet = AttentionSet(fleet: fleet, sessions: agentSessions);
  final attention = AttentionNotifier(
    fleet: fleet,
    sessions: agentSessions,
    attention: attentionSet,
    settings: notificationSettings,
    notifier: notify,
    // Buttons on a terminal agent's notification answer through its machine's
    // existing connection, after reading the pane's question again.
    answerer: PaneAnswerer(connection: fleet.connection),
    visibleText: visibleText,
  );
  return HerdrMobileApp(
    previews: previews,
    observedSessions: observedSessions,
    fleet: fleet,
    machines: machines,
    network: monitor,
    snapshotCache: cache,
    terminalSettings: terminalSettings,
    slashUsage: slashUsage,
    quickPhrases: quickPhrases,
    dictation: dictation,
    sentPhrases: sentPhrases,
    appSettings: appSettings,
    agentScreens: agentScreens,
    lastSeen: lastSeen,
    connect: connect,
    agentSessions: agentSessions,
    agentSessionSettings: agentSessionSettings,
    notificationSettings: notificationSettings,
    notifier: notify,
    attention: attention,
    attentionSet: attentionSet,
  );
}
